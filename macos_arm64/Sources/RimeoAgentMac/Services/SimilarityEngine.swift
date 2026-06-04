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

    // MARK: - Public API

    func findSimilar(trackID: String, allTracks: [Track],
                     topN: Int? = nil, useKey: Bool = true) -> [SimilarResult] {
        guard let trackA = allTracks.first(where: { $0.id == trackID }) else { return [] }

        var results = [SimilarResult]()
        for trackB in allTracks {
            guard trackB.id != trackID else { continue }

            // Hard filter 1: BPM tolerance
            guard bpmWithinTolerance(trackA.bpm, trackB.bpm) else { continue }

            // Hard filter 2: harmonic key compatibility (only when useKey)
            let rel = keyRelation(trackA.key, trackB.key)
            if useKey && rel == .incompatible { continue }

            results.append(SimilarResult(
                track: trackB,
                score: buildScore(trackA: trackA, trackB: trackB, rel: rel)
            ))
        }

        results.sort { a, b in
            if a.score.total != b.score.total { return a.score.total > b.score.total }
            if a.score.bpm_delta != b.score.bpm_delta { return a.score.bpm_delta < b.score.bpm_delta }
            return keyRank(a.score.key_relation) > keyRank(b.score.key_relation)
        }

        let limit = topN ?? config.result_limit
        return Array(results.prefix(limit))
    }

    // MARK: - Scoring

    private func buildScore(trackA: Track, trackB: Track, rel: KeyRel) -> MatchScore {
        let labelMatch    = matches(trackA.label,  trackB.label)
        let genreMatch    = matches(trackA.genre,  trackB.genre)
        let artistMatch   = matches(trackA.artist, trackB.artist)
        let durationMatch = durationWithinTolerance(trackA.duration, trackB.duration)

        var total = 0.0
        if labelMatch    { total += config.weights.label    }
        if genreMatch    { total += config.weights.genre    }
        if artistMatch   { total += config.weights.artist   }
        if durationMatch { total += config.weights.duration }

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
    private func durationWithinTolerance(_ a: Double?, _ b: Double?) -> Bool {
        guard let a = a, let b = b, a > 0, b > 0 else { return false }
        return abs(a - b) / a <= config.duration_tolerance_pct / 100.0
    }

    private func matches(_ a: String, _ b: String) -> Bool {
        let x = a.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let y = b.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return !x.isEmpty && x == y
    }

    // MARK: - BPM filter

    // Candidate passes when |bpmB - bpmA| / bpmA <= tolerance%. Missing BPM → excluded.
    private func bpmWithinTolerance(_ a: Double, _ b: Double) -> Bool {
        guard a > 0, b > 0 else { return false }
        return abs(a - b) / a <= config.bpm_tolerance_pct / 100.0
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

    private func keyRelation(_ keyA: String, _ keyB: String) -> KeyRel {
        guard let (numA, letA) = parseCamelot(keyA),
              let (numB, letB) = parseCamelot(keyB) else { return .unknown }

        let diff  = abs(numA - numB)
        let steps = min(diff, 12 - diff)

        if numA == numB && letA == letB { return .exact }
        if numA == numB && letA != letB { return .relative }
        if letA == letB && steps <= config.key_max_steps { return .compatible }
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
