import Foundation

// Metadata-based similar-tracks scoring — pure Swift, no audio analysis.
// Candidate pool = hard filter on BPM tolerance + harmonic key compatibility.
// Ranking inside the pool = weighted bonuses for matching label / genre / artist.
// All numeric parameters live in similarity_config.json (bundled at build time).

struct SimilarityConfig: Codable {
    var bpm_tolerance_pct: Double
    var key_max_steps:     Int
    var result_limit:      Int
    var weights:           Weights

    struct Weights: Codable {
        var label:  Double
        var genre:  Double
        var artist: Double
    }

    static let `default` = SimilarityConfig(
        bpm_tolerance_pct: 1.6,
        key_max_steps:     2,
        result_limit:      20,
        weights:           Weights(label: 2.0, genre: 1.0, artist: 0.5)
    )
}

final class SimilarityEngine {
    static let shared = SimilarityEngine()
    private init() { self.config = SimilarityEngine.loadConfig() }

    let config: SimilarityConfig

    struct MatchScore: Codable {
        let total:        Double   // sum of weighted bonuses (label/genre/artist)
        let bpm_delta:    Double   // |bpmA - bpmB|
        let key_relation: String   // "exact" | "relative" | "compatible" | "—"
        let label_match:  Bool
        let genre_match:  Bool
        let artist_match: Bool
    }

    struct SimilarResult: Codable {
        let track: Track
        let score: MatchScore
    }

    // MARK: - Config loading

    private static func loadConfig() -> SimilarityConfig {
        if let url = Bundle.main.url(forResource: "similarity_config", withExtension: "json"),
           let data = try? Data(contentsOf: url),
           let cfg  = try? JSONDecoder().decode(SimilarityConfig.self, from: data) {
            return cfg
        }
        return .default
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
        let labelMatch  = matches(trackA.label,  trackB.label)
        let genreMatch  = matches(trackA.genre,  trackB.genre)
        let artistMatch = matches(trackA.artist, trackB.artist)

        var total = 0.0
        if labelMatch  { total += config.weights.label  }
        if genreMatch  { total += config.weights.genre  }
        if artistMatch { total += config.weights.artist }

        return MatchScore(
            total:        round(total * 100) / 100,
            bpm_delta:    round(abs(trackA.bpm - trackB.bpm) * 10) / 10,
            key_relation: rel.label,
            label_match:  labelMatch,
            genre_match:  genreMatch,
            artist_match: artistMatch
        )
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
