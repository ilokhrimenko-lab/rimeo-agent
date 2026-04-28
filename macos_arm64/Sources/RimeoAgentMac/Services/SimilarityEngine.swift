import Foundation

// Port of similarity.py — pure Swift, no external dependencies

final class SimilarityEngine {
    static let shared = SimilarityEngine()
    private init() {}

    struct MatchScore: Codable {
        let total:    Double
        let vibe:     Double
        let key:      Double
        let harmony:  Double   // alias for iOS client
        let tempo:    Double
        let metadata: Double
        let clap:     Bool
    }

    struct SimilarResult: Codable {
        let track: Track
        let score: MatchScore
    }

    func findSimilar(trackID: String, allTracks: [Track],
                     analysisData: [String: TrackFeatures],
                     topN: Int = 10, useKey: Bool = true) -> [SimilarResult] {
        guard let featA  = analysisData[trackID],
              let trackA = allTracks.first(where: { $0.id == trackID }) else { return [] }

        var results = [SimilarResult]()
        for trackB in allTracks {
            guard trackB.id != trackID,
                  let featB = analysisData[trackB.id] else { continue }
            guard let score = computeMatch(trackA: trackA, trackB: trackB,
                                           featA: featA, featB: featB,
                                           useKey: useKey) else { continue }
            results.append(SimilarResult(track: trackB, score: score))
        }
        results.sort { $0.score.total > $1.score.total }
        return Array(results.prefix(topN))
    }

    func computeMatch(trackA: Track, trackB: Track,
                      featA: TrackFeatures, featB: TrackFeatures,
                      useKey: Bool) -> MatchScore? {
        guard let ts = tempoScore(bpmA: trackA.bpm, bpmB: trackB.bpm) else { return nil }

        let vs = vibeScore(featA: featA, featB: featB)
        let ks = camelotScore(keyA: trackA.key, keyB: trackB.key)
        let ms = metadataScore(trackA: trackA, trackB: trackB)

        let total: Double
        if useKey {
            total = (vs * 0.45 + ks * 0.25 + ts * 0.20 + ms * 0.10) * 100
        } else {
            total = (vs * 0.60 + ts * 0.25 + ms * 0.15) * 100
        }

        let keyVal = round(ks * 100 * 10) / 10
        return MatchScore(
            total:    round(total * 10) / 10,
            vibe:     round(vs * 100 * 10) / 10,
            key:      keyVal,
            harmony:  keyVal,
            tempo:    round(ts * 100 * 10) / 10,
            metadata: round(ms * 100 * 10) / 10,
            clap:     false
        )
    }

    // BPM delta filter: >8 → nil (hard exclude), 0–8 → 0.25–1.0
    private func tempoScore(bpmA: Double, bpmB: Double) -> Double? {
        guard bpmA > 0, bpmB > 0 else { return 0.5 }
        let delta = abs(bpmA - bpmB)
        if delta > 8   { return nil }
        if delta <= 2  { return 1.0 }
        return round((1.0 - (delta - 2.0) / 6.0 * 0.75) * 10000) / 10000
    }

    // Camelot wheel harmonic compatibility
    private func camelotScore(keyA: String, keyB: String) -> Double {
        guard let (numA, letA) = parseCamelot(keyA),
              let (numB, letB) = parseCamelot(keyB) else { return 0.5 }

        let diff    = abs(numA - numB)
        let numDiff = min(diff, 12 - diff)
        let sameNum = (numA == numB)
        let sameLet = (letA == letB)

        if sameNum && sameLet  { return 1.0  }
        if sameNum && !sameLet { return 0.85 }
        if numDiff == 1 && sameLet  { return 0.85 }
        if numDiff == 2 && sameLet  { return 0.50 }
        if numDiff == 1 && !sameLet { return 0.35 }
        return 0.0
    }

    private func parseCamelot(_ key: String) -> (Int, Character)? {
        let k = key.trimmingCharacters(in: .whitespaces)
        guard !k.isEmpty, k != "—" else { return nil }
        let letters = k.prefix(while: { $0.isNumber })
        let rest    = k.dropFirst(letters.count)
        guard let num = Int(letters), num >= 1, num <= 12,
              let letter = rest.first, letter == "A" || letter == "B" else { return nil }
        return (num, letter)
    }

    // Acoustic similarity: timbre (MFCC cosine) + energy + happiness + groove
    private func vibeScore(featA: TrackFeatures, featB: TrackFeatures) -> Double {
        var score  = 0.0
        var weight = 0.0

        // Timbre (MFCC cosine, skip coeff-0)
        let a = Array(featA.timbre.dropFirst())
        let b = Array(featB.timbre.dropFirst())
        if !a.isEmpty, a.count == b.count {
            let dot = zip(a, b).map(*).reduce(0, +)
            let na  = sqrt(a.map { $0 * $0 }.reduce(0, +))
            let nb  = sqrt(b.map { $0 * $0 }.reduce(0, +))
            if na > 0, nb > 0 {
                let cos = dot / (na * nb)
                score  += ((cos + 1.0) / 2.0) * 0.50
                weight += 0.50
            }
        }

        // Energy (RMS)
        let eDiff = abs(featA.energy - featB.energy)
        score  += (1.0 - min(1.0, eDiff * 3.5)) * 0.25
        weight += 0.25

        // Happiness
        let hDiff = abs(featA.happiness - featB.happiness)
        score  += (1.0 - min(1.0, hDiff * 2.5)) * 0.15
        weight += 0.15

        // Groove
        let gDiff = abs(featA.groove - featB.groove)
        score  += (1.0 - min(1.0, gDiff * 3.0)) * 0.10
        weight += 0.10

        return weight > 0 ? (round(score / weight * 10000) / 10000) : 0.0
    }

    // Metadata: same label + playlist Jaccard
    private func metadataScore(trackA: Track, trackB: Track) -> Double {
        var score = 0.0
        let la = trackA.label.trimmingCharacters(in: .whitespaces).lowercased()
        let lb = trackB.label.trimmingCharacters(in: .whitespaces).lowercased()
        if !la.isEmpty, !lb.isEmpty, la == lb { score += 0.6 }

        let pa = Set(trackA.playlist_indices.keys)
        let pb = Set(trackB.playlist_indices.keys)
        if !pa.isEmpty, !pb.isEmpty {
            let union = Double(pa.union(pb).count)
            if union > 0 { score += (Double(pa.intersection(pb).count) / union) * 0.4 }
        }

        return min(1.0, round(score * 10000) / 10000)
    }
}
