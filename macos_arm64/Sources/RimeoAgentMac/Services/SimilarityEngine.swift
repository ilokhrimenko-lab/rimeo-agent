import Foundation

// Metadata-based similar-tracks scoring — pure Swift, no audio analysis.
// Candidate pool = hard filter on BPM tolerance + harmonic key compatibility.
// Ranking inside the pool = weighted bonuses for matching label / genre / artist.
// All numeric parameters live in similarity_config.json (bundled at build time).

struct SimilarityConfig: Codable {
    var bpm_tolerance_pct:      Double
    var key_max_steps:          Int
    var duration_tolerance_pct: Double
    var result_limit:           Int
    var weights:                Weights

    struct Weights: Codable {
        var label:    Double
        var genre:    Double
        var artist:   Double
        var duration: Double

        // Allow older configs without the duration weight to decode.
        init(label: Double, genre: Double, artist: Double, duration: Double) {
            self.label = label; self.genre = genre; self.artist = artist; self.duration = duration
        }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            label    = try c.decodeIfPresent(Double.self, forKey: .label)    ?? 2.0
            genre    = try c.decodeIfPresent(Double.self, forKey: .genre)    ?? 1.0
            artist   = try c.decodeIfPresent(Double.self, forKey: .artist)   ?? 0.5
            duration = try c.decodeIfPresent(Double.self, forKey: .duration) ?? 1.5
        }
    }

    // Allow older configs without duration_tolerance_pct to decode.
    init(bpm_tolerance_pct: Double, key_max_steps: Int, duration_tolerance_pct: Double,
         result_limit: Int, weights: Weights) {
        self.bpm_tolerance_pct = bpm_tolerance_pct
        self.key_max_steps = key_max_steps
        self.duration_tolerance_pct = duration_tolerance_pct
        self.result_limit = result_limit
        self.weights = weights
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        bpm_tolerance_pct      = try c.decodeIfPresent(Double.self, forKey: .bpm_tolerance_pct)      ?? 1.6
        key_max_steps          = try c.decodeIfPresent(Int.self,    forKey: .key_max_steps)          ?? 1
        duration_tolerance_pct = try c.decodeIfPresent(Double.self, forKey: .duration_tolerance_pct) ?? 10.0
        result_limit           = try c.decodeIfPresent(Int.self,    forKey: .result_limit)           ?? 50
        weights                = try c.decodeIfPresent(Weights.self, forKey: .weights)
            ?? Weights(label: 2.0, genre: 1.0, artist: 0.5, duration: 1.5)
    }

    static let `default` = SimilarityConfig(
        bpm_tolerance_pct:      1.6,
        key_max_steps:          1,
        duration_tolerance_pct: 10.0,
        result_limit:           50,
        weights:                Weights(label: 2.0, genre: 1.0, artist: 0.5, duration: 1.5)
    )
}

final class SimilarityEngine {
    static let shared = SimilarityEngine()
    private init() { self._config = SimilarityEngine.loadConfig() }

    // Config is mutable: it starts from the cached/bundled file and is then
    // refreshed from the cloud (admin-managed) at startup + on a timer, so
    // tuning the algorithm never requires shipping a new agent build.
    private let configLock = NSLock()
    private var _config: SimilarityConfig
    private var refreshTimer: DispatchSourceTimer?
    private let refreshInterval: TimeInterval = 600   // 10 minutes

    var config: SimilarityConfig {
        configLock.lock(); defer { configLock.unlock() }
        return _config
    }

    private func setConfig(_ cfg: SimilarityConfig) {
        configLock.lock(); _config = cfg; configLock.unlock()
    }

    // Persisted copy of the last-known-good cloud config — preferred source on
    // the next launch so offline starts keep the latest admin-tuned values.
    private static var cachedConfigURL: URL {
        AppConfig.shared.baseDir.appendingPathComponent("similarity_config.json")
    }

    struct MatchScore: Codable {
        let total:          Double   // sum of weighted bonuses (label/genre/artist/duration)
        let bpm_delta:      Double   // |bpmA - bpmB|
        let key_relation:   String   // "exact" | "relative" | "compatible" | "—"
        let label_match:    Bool
        let genre_match:    Bool
        let artist_match:   Bool
        let duration_match: Bool
    }

    struct SimilarResult: Codable {
        let track: Track
        let score: MatchScore
    }

    // MARK: - Config loading

    // Startup source priority: cached cloud config → bundled file → built-in default.
    private static func loadConfig() -> SimilarityConfig {
        if let data = try? Data(contentsOf: cachedConfigURL),
           let cfg  = try? JSONDecoder().decode(SimilarityConfig.self, from: data) {
            return cfg
        }
        if let url = Bundle.main.url(forResource: "similarity_config", withExtension: "json"),
           let data = try? Data(contentsOf: url),
           let cfg  = try? JSONDecoder().decode(SimilarityConfig.self, from: data) {
            return cfg
        }
        return .default
    }

    // MARK: - Cloud sync

    /// Kick off cloud config syncing: one immediate fetch + a repeating timer.
    /// Safe to call once at app launch.
    func startCloudSync() {
        refreshFromCloud()
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        timer.schedule(deadline: .now() + refreshInterval, repeating: refreshInterval)
        timer.setEventHandler { [weak self] in self?.refreshFromCloud() }
        timer.resume()
        refreshTimer = timer
    }

    /// Fetch the admin-managed config from the cloud; on success update the live
    /// config and persist it for the next launch. Failures are silently ignored
    /// (we keep whatever config we already have).
    func refreshFromCloud() {
        guard let url = URL(string: "\(AppConfig.shared.rimeoAppURL)/api/similarity_config") else { return }
        var req = URLRequest(url: url)
        req.setValue("RimeoAgentMac/\(AppConfig.shared.version)", forHTTPHeaderField: "User-Agent")
        req.cachePolicy = .reloadIgnoringLocalCacheData
        req.timeoutInterval = 10

        URLSession.shared.dataTask(with: req) { [weak self] data, _, _ in
            guard let self = self,
                  let data = data,
                  let cfg = try? JSONDecoder().decode(SimilarityConfig.self, from: data) else { return }
            self.setConfig(cfg)
            try? data.write(to: SimilarityEngine.cachedConfigURL, options: .atomic)
        }.resume()
    }

    // MARK: - Playlist recommendation tuning (frozen cross-platform, finding-24)

    private static let maxSeeds    = 40     // deterministic seed cap per request
    private static let perSeedPool = 30     // candidates pulled per seed before merge
    private static let freqBonus   = 0.75   // rank bonus per additional seed hit

    // MARK: - Public API

    func findSimilar(trackID: String, allTracks: [Track],
                     topN: Int? = nil, useKey: Bool = true) -> [SimilarResult] {
        findSimilarCore(trackID: trackID, allTracks: allTracks,
                        topN: topN, useKey: useKey, excludeIDs: [], cfg: config)
    }

    /// Exclude-aware variant (finding-30): candidates in `excludeIDs` are dropped
    /// INSIDE the pool BEFORE the topN cut, so already-present playlist members
    /// don't crowd the best matches out of the per-seed pool.
    func findSimilar(trackID: String, allTracks: [Track],
                     topN: Int? = nil, useKey: Bool = true,
                     excludeIDs: Set<String>) -> [SimilarResult] {
        findSimilarCore(trackID: trackID, allTracks: allTracks,
                        topN: topN, useKey: useKey, excludeIDs: excludeIDs, cfg: config)
    }

    /// Spotify-style "recommended to add" for a whole playlist (spec 3.2, variant (a)
    /// with limiters). Seed = deterministic sample of the playlist; per-seed pools are
    /// merged by track id and re-ranked by aggregate score + hit frequency. Uses ONE
    /// atomic config snapshot for the whole request (finding-29) and the cached parse
    /// supplied by the caller (finding-23). Empty seed → [] with no library scan.
    func recommendForPlaylist(trackIDs: [String], allTracks: [Track],
                              topN: Int? = nil, useKey: Bool = true,
                              excludeIDs: Set<String> = []) -> [SimilarResult] {
        // Dedup seeds, preserve order (stable sampling between requests).
        var seenSeed = Set<String>()
        let orderedSeeds = trackIDs.filter { !$0.isEmpty && seenSeed.insert($0).inserted }
        guard !orderedSeeds.isEmpty else { return [] }

        let cfg   = config                       // atomic snapshot for the whole request
        let limit = topN ?? cfg.result_limit
        // Members (all of them, not just the sampled seeds) plus caller excludes are
        // filtered out of every pool so nothing already in the playlist is recommended.
        let exclude = Set(orderedSeeds).union(excludeIDs)
        let seeds   = sampleSeeds(orderedSeeds, max: SimilarityEngine.maxSeeds)

        struct Agg {
            var track:       Track
            var total:       Double
            var hits:        Int
            var bestScore:   MatchScore
            var minBpmDelta: Double
        }
        var agg: [String: Agg] = [:]

        for seedID in seeds {
            let pool = findSimilarCore(trackID: seedID, allTracks: allTracks,
                                       topN: SimilarityEngine.perSeedPool, useKey: useKey,
                                       excludeIDs: exclude, cfg: cfg)
            for r in pool {
                let tid = r.track.id
                if var a = agg[tid] {
                    a.total += r.score.total
                    a.hits  += 1
                    if r.score.total > a.bestScore.total { a.bestScore = r.score }
                    if r.score.bpm_delta < a.minBpmDelta { a.minBpmDelta = r.score.bpm_delta }
                    agg[tid] = a
                } else {
                    agg[tid] = Agg(track: r.track, total: r.score.total, hits: 1,
                                   bestScore: r.score, minBpmDelta: r.score.bpm_delta)
                }
            }
        }

        let ranked = agg.values
            .map { a in (agg: a, rank: a.total + SimilarityEngine.freqBonus * Double(a.hits)) }
            .sorted { l, r in
                if l.rank != r.rank { return l.rank > r.rank }                       // rank ↓
                if l.agg.minBpmDelta != r.agg.minBpmDelta {
                    return l.agg.minBpmDelta < r.agg.minBpmDelta                      // bpm Δ ↑
                }
                return keyRank(l.agg.bestScore.key_relation)
                     > keyRank(r.agg.bestScore.key_relation)                          // key ↓
            }

        return ranked.prefix(limit).map { SimilarResult(track: $0.agg.track, score: $0.agg.bestScore) }
    }

    /// Deterministic every-⌈n/max⌉-th sample so every cluster of a large playlist is
    /// represented and the seed set is stable between requests (finding-29).
    private func sampleSeeds(_ ids: [String], max: Int) -> [String] {
        guard ids.count > max, max > 0 else { return ids }
        let step = Int(ceil(Double(ids.count) / Double(max)))
        var out: [String] = []
        var i = 0
        while i < ids.count { out.append(ids[i]); i += step }
        return out
    }

    // Shared filter+score core. `cfg` is passed explicitly so a multi-pool request
    // (recommendForPlaylist) uses one consistent snapshot even if the 600s refresh
    // timer swaps the live config mid-request.
    private func findSimilarCore(trackID: String, allTracks: [Track],
                                 topN: Int?, useKey: Bool,
                                 excludeIDs: Set<String>, cfg: SimilarityConfig) -> [SimilarResult] {
        guard let trackA = allTracks.first(where: { $0.id == trackID }) else { return [] }

        var results = [SimilarResult]()
        for trackB in allTracks {
            guard trackB.id != trackID else { continue }
            if excludeIDs.contains(trackB.id) { continue }   // exclude BEFORE the topN cut

            // Hard filter 1: BPM tolerance
            guard bpmWithinTolerance(trackA.bpm, trackB.bpm, cfg: cfg) else { continue }

            // Hard filter 2: harmonic key compatibility (only when useKey)
            let rel = keyRelation(trackA.key, trackB.key, cfg: cfg)
            if useKey && rel == .incompatible { continue }

            results.append(SimilarResult(
                track: trackB,
                score: buildScore(trackA: trackA, trackB: trackB, rel: rel, cfg: cfg)
            ))
        }

        results.sort { a, b in
            if a.score.total != b.score.total { return a.score.total > b.score.total }
            if a.score.bpm_delta != b.score.bpm_delta { return a.score.bpm_delta < b.score.bpm_delta }
            return keyRank(a.score.key_relation) > keyRank(b.score.key_relation)
        }

        let limit = topN ?? cfg.result_limit
        return Array(results.prefix(limit))
    }

    // MARK: - Scoring

    private func buildScore(trackA: Track, trackB: Track, rel: KeyRel, cfg: SimilarityConfig) -> MatchScore {
        let labelMatch    = matches(trackA.label,  trackB.label)
        let genreMatch    = matches(trackA.genre,  trackB.genre)
        let artistMatch   = matches(trackA.artist, trackB.artist)
        let durationMatch = durationWithinTolerance(trackA.duration, trackB.duration, cfg: cfg)

        var total = 0.0
        if labelMatch    { total += cfg.weights.label    }
        if genreMatch    { total += cfg.weights.genre    }
        if artistMatch   { total += cfg.weights.artist   }
        if durationMatch { total += cfg.weights.duration }

        return MatchScore(
            total:          round(total * 100) / 100,
            bpm_delta:      round(abs(trackA.bpm - trackB.bpm) * 10) / 10,
            key_relation:   rel.label,
            label_match:    labelMatch,
            genre_match:    genreMatch,
            artist_match:   artistMatch,
            duration_match: durationMatch
        )
    }

    // Bonus when track lengths are within duration_tolerance_pct of each other.
    // Missing duration on either side → no bonus.
    private func durationWithinTolerance(_ a: Double?, _ b: Double?, cfg: SimilarityConfig) -> Bool {
        guard let a = a, let b = b, a > 0, b > 0 else { return false }
        return abs(a - b) / a <= cfg.duration_tolerance_pct / 100.0
    }

    private func matches(_ a: String, _ b: String) -> Bool {
        let x = a.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let y = b.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return !x.isEmpty && x == y
    }

    // MARK: - BPM filter

    // Candidate passes when |bpmB - bpmA| / bpmA <= tolerance%. Missing BPM → excluded.
    private func bpmWithinTolerance(_ a: Double, _ b: Double, cfg: SimilarityConfig) -> Bool {
        guard a > 0, b > 0 else { return false }
        return abs(a - b) / a <= cfg.bpm_tolerance_pct / 100.0
    }

    // MARK: - Camelot key relation

    enum KeyRel {
        case exact        // same number + letter
        case relative     // same number, different letter (relative major/minor)
        case compatible   // same letter, within key_max_steps on the wheel
        case incompatible // valid keys but outside the harmonic window
        case unknown      // one or both keys unparseable — not a hard exclude

        var label: String {
            switch self {
            case .exact:        return "exact"
            case .relative:     return "relative"
            case .compatible:   return "compatible"
            case .incompatible: return "incompatible"
            case .unknown:      return "—"
            }
        }
    }

    private func keyRelation(_ keyA: String, _ keyB: String, cfg: SimilarityConfig) -> KeyRel {
        guard let (numA, letA) = parseCamelot(keyA),
              let (numB, letB) = parseCamelot(keyB) else { return .unknown }

        let diff  = abs(numA - numB)
        let steps = min(diff, 12 - diff)

        if numA == numB && letA == letB { return .exact }
        if numA == numB && letA != letB { return .relative }
        if letA == letB && steps <= cfg.key_max_steps { return .compatible }
        return .incompatible
    }

    private func keyRank(_ relation: String) -> Int {
        switch relation {
        case "exact":      return 4
        case "relative":   return 3
        case "compatible": return 2
        case "—":          return 1
        default:           return 0
        }
    }

    private func parseCamelot(_ key: String) -> (Int, Character)? {
        let k = key.trimmingCharacters(in: .whitespaces)
        guard !k.isEmpty, k != "—" else { return nil }
        let digits = k.prefix(while: { $0.isNumber })
        let rest   = k.dropFirst(digits.count)
        guard let num = Int(digits), num >= 1, num <= 12,
              let letter = rest.first, letter == "A" || letter == "B" else { return nil }
        return (num, letter)
    }
}
