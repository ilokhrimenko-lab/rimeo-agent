using RimeoAgent.Models;

namespace RimeoAgent.Services;

public sealed class SimilarityEngine
{
    public static readonly SimilarityEngine Shared = new();

    public record MatchScore(double Total, double Vibe, double Key, double Harmony,
                              double Tempo, double Metadata, bool Clap);
    public record SimilarResult(Track Track, MatchScore Score);

    public List<SimilarResult> FindSimilar(string trackId, List<Track> allTracks,
        Dictionary<string, TrackFeatures> analysisData, int topN = 10, bool useKey = true)
    {
        if (!analysisData.TryGetValue(trackId, out var featA)) return new();
        var trackA = allTracks.FirstOrDefault(t => t.Id == trackId);
        if (trackA == null) return new();

        var results = new List<SimilarResult>();
        foreach (var trackB in allTracks)
        {
            if (trackB.Id == trackId) continue;
            if (!analysisData.TryGetValue(trackB.Id, out var featB)) continue;
            var score = ComputeMatch(trackA, trackB, featA, featB, useKey);
            if (score != null) results.Add(new SimilarResult(trackB, score));
        }
        results.Sort((a, b) => b.Score.Total.CompareTo(a.Score.Total));
        return results.Take(topN).ToList();
    }

    public MatchScore? ComputeMatch(Track trackA, Track trackB,
        TrackFeatures featA, TrackFeatures featB, bool useKey)
    {
        var ts = TempoScore(trackA.Bpm, trackB.Bpm);
        if (ts == null) return null;

        var cs    = ClapScore(featA, featB);
        double vs = cs ?? VibeScore(featA, featB);
        double ks = CamelotScore(trackA.Key, trackB.Key);
        double ms = MetadataScore(trackA, trackB);
        double t  = ts.Value;

        double total;
        if (cs != null)
        {
            total = useKey
                ? (vs * 0.80 + ks * 0.12 + t * 0.08) * 100
                : (vs * 0.90 + t * 0.10) * 100;
        }
        else
        {
            total = useKey
                ? (vs * 0.45 + ks * 0.25 + t * 0.20 + ms * 0.10) * 100
                : (vs * 0.60 + t * 0.25 + ms * 0.15) * 100;
        }

        double keyVal = Math.Round(ks * 100 * 10) / 10;
        return new MatchScore(
            Total:    Math.Round(total * 10) / 10,
            Vibe:     Math.Round(vs * 100 * 10) / 10,
            Key:      keyVal,
            Harmony:  keyVal,
            Tempo:    Math.Round(t * 100 * 10) / 10,
            Metadata: Math.Round(ms * 100 * 10) / 10,
            Clap:     cs != null
        );
    }

    private static double? ClapScore(TrackFeatures a, TrackFeatures b)
    {
        if (a.Clap == null || b.Clap == null || a.Clap.Length == 0 || a.Clap.Length != b.Clap.Length)
            return null;
        double dot = a.Clap.Zip(b.Clap, (x, y) => x * y).Sum();
        return Math.Round((dot + 1.0) / 2.0 * 10000) / 10000;
    }

    private static double? TempoScore(double bpmA, double bpmB)
    {
        if (bpmA <= 0 || bpmB <= 0) return 0.5;
        double delta = Math.Abs(bpmA - bpmB);
        if (delta > 8)   return null;
        if (delta <= 2)  return 1.0;
        return Math.Round((1.0 - (delta - 2.0) / 6.0 * 0.75) * 10000) / 10000;
    }

    private static double CamelotScore(string keyA, string keyB)
    {
        if (!ParseCamelot(keyA, out int numA, out char letA)) return 0.5;
        if (!ParseCamelot(keyB, out int numB, out char letB)) return 0.5;

        int diff    = Math.Abs(numA - numB);
        int numDiff = Math.Min(diff, 12 - diff);
        bool sameNum = numA == numB;
        bool sameLet = letA == letB;

        if (sameNum && sameLet)            return 1.00;
        if (sameNum && !sameLet)           return 0.85;
        if (numDiff == 1 && sameLet)       return 0.85;
        if (numDiff == 2 && sameLet)       return 0.50;
        if (numDiff == 1 && !sameLet)      return 0.35;
        return 0.0;
    }

    private static bool ParseCamelot(string key, out int num, out char let)
    {
        num = 0; let = ' ';
        var k = key.Trim();
        if (string.IsNullOrEmpty(k) || k == "—") return false;
        int i = 0;
        while (i < k.Length && char.IsDigit(k[i])) i++;
        if (i == 0 || i >= k.Length) return false;
        num = int.Parse(k[..i]);
        let = k[i];
        return num >= 1 && num <= 12 && (let == 'A' || let == 'B');
    }

    private static double VibeScore(TrackFeatures a, TrackFeatures b)
    {
        double score = 0, weight = 0;

        // Timbre: MFCC cosine (skip coeff-0)
        var ta = a.Timbre.Skip(1).ToArray();
        var tb = b.Timbre.Skip(1).ToArray();
        if (ta.Length > 0 && ta.Length == tb.Length)
        {
            double dot = ta.Zip(tb, (x, y) => x * y).Sum();
            double na  = Math.Sqrt(ta.Sum(x => x * x));
            double nb  = Math.Sqrt(tb.Sum(x => x * x));
            if (na > 0 && nb > 0)
            {
                score  += ((dot / (na * nb) + 1.0) / 2.0) * 0.50;
                weight += 0.50;
            }
        }

        score  += (1.0 - Math.Min(1.0, Math.Abs(a.Energy - b.Energy) * 3.5)) * 0.25;
        weight += 0.25;
        score  += (1.0 - Math.Min(1.0, Math.Abs(a.Happiness - b.Happiness) * 2.5)) * 0.15;
        weight += 0.15;
        score  += (1.0 - Math.Min(1.0, Math.Abs(a.Groove - b.Groove) * 3.0)) * 0.10;
        weight += 0.10;

        return weight > 0 ? Math.Round(score / weight * 10000) / 10000 : 0.0;
    }

    private static double MetadataScore(Track a, Track b)
    {
        double score = 0;
        var la = a.Label.Trim().ToLower();
        var lb = b.Label.Trim().ToLower();
        if (!string.IsNullOrEmpty(la) && la == lb) score += 0.6;

        var pa    = new HashSet<string>(a.PlaylistIndices.Keys);
        var pb    = new HashSet<string>(b.PlaylistIndices.Keys);
        if (pa.Count > 0 && pb.Count > 0)
        {
            double union = pa.Union(pb).Count();
            if (union > 0) score += (pa.Intersect(pb).Count() / union) * 0.4;
        }
        return Math.Min(1.0, Math.Round(score * 10000) / 10000);
    }
}
