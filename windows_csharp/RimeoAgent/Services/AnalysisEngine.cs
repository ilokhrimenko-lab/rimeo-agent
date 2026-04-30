using System.Text.Json;
using System.Text.Json.Serialization;
using MathNet.Numerics;
using MathNet.Numerics.IntegralTransforms;
using NAudio.Wave;
using NAudio.Wave.SampleProviders;
using RimeoAgent.Config;

namespace RimeoAgent.Services;

public sealed class TrackFeatures
{
    [JsonPropertyName("track_id")]      public string   TrackId      { get; set; } = "";
    [JsonPropertyName("segment_start")] public double   SegmentStart { get; set; }
    [JsonPropertyName("segment_end")]   public double   SegmentEnd   { get; set; }
    [JsonPropertyName("analyzed_at")]   public long     AnalyzedAt   { get; set; }
    [JsonPropertyName("energy")]        public double   Energy       { get; set; }
    [JsonPropertyName("brightness")]    public double   Brightness   { get; set; }
    [JsonPropertyName("zcr")]           public double   Zcr          { get; set; }
    [JsonPropertyName("timbre")]        public double[] Timbre       { get; set; } = Array.Empty<double>();
    [JsonPropertyName("groove")]        public double   Groove       { get; set; }
    [JsonPropertyName("happiness")]     public double   Happiness    { get; set; }
    [JsonPropertyName("clap")]          public double[]? Clap        { get; set; }
}

public sealed class AnalysisEngine
{
    public static readonly AnalysisEngine Shared = new();

    private readonly object _storeLock  = new();
    private readonly object _cancelLock = new();
    private Dictionary<string, TrackFeatures> _store = new();
    private bool _cancelRequested;

    private AnalysisEngine() { _store = LoadStore(); }

    public Dictionary<string, TrackFeatures> LoadStore()
    {
        try
        {
            if (!File.Exists(AppConfig.Shared.AnalysisFile)) return new();
            var json = File.ReadAllText(AppConfig.Shared.AnalysisFile);
            return JsonSerializer.Deserialize<Dictionary<string, TrackFeatures>>(json) ?? new();
        }
        catch { return new(); }
    }

    public void SaveStore(Dictionary<string, TrackFeatures>? s = null)
    {
        Dictionary<string, TrackFeatures> toSave;
        lock (_storeLock) { toSave = s ?? new Dictionary<string, TrackFeatures>(_store); }
        try
        {
            var json = JsonSerializer.Serialize(toSave, new JsonSerializerOptions { WriteIndented = false });
            File.WriteAllText(AppConfig.Shared.AnalysisFile, json);
        }
        catch (Exception ex) { Log.Error($"Analysis store save failed: {ex.Message}"); }
    }

    public TrackFeatures? GetFeatures(string id) { lock (_storeLock) { return _store.GetValueOrDefault(id); } }
    public void SetFeatures(string id, TrackFeatures f) { lock (_storeLock) { _store[id] = f; } }
    public List<string> AllIds() { lock (_storeLock) { return _store.Keys.ToList(); } }
    public Dictionary<string, TrackFeatures> StoreSnapshot() { lock (_storeLock) { return new(_store); } }

    public void ResetCancellation() { lock (_cancelLock) { _cancelRequested = false; } }
    public void RequestCancel()     { lock (_cancelLock) { _cancelRequested = true;  } }
    public bool ShouldCancel()      { lock (_cancelLock) { return _cancelRequested;  } }

    public TrackFeatures? AnalyzeTrack(Models.Track track)
    {
        if (!File.Exists(track.Location))
        {
            Log.Warn($"Analysis skipped missing file: {track.Id} {track.Location}");
            return null;
        }

        // Load waveform cache for segment selection
        var cacheFile = Path.Combine(AppConfig.Shared.CacheDir, $"wave_{track.Id}.json");
        double[] peaks = Array.Empty<double>();
        double duration = 0;
        if (File.Exists(cacheFile))
        {
            try
            {
                var obj = JsonSerializer.Deserialize<Dictionary<string, JsonElement>>(File.ReadAllText(cacheFile));
                if (obj != null)
                {
                    if (obj.TryGetValue("peaks", out var p))
                        peaks = p.Deserialize<double[]>() ?? Array.Empty<double>();
                    if (obj.TryGetValue("duration", out var dur))
                        duration = dur.GetDouble();
                }
            }
            catch { }
        }
        if (duration <= 0) duration = AudioService.Shared.ProbeDuration(track.Location);
        if (duration <= 0) return null;

        var (segStart, segEnd) = FindAnalysisSegment(peaks, duration);
        var segDur = segEnd - segStart;

        var tmpPath = AudioService.Shared.ExtractSegment(track.Location, segStart, segDur);
        if (tmpPath == null) return null;
        try
        {
            var feats = ComputeFeatures(tmpPath);
            if (feats == null) return null;

            return new TrackFeatures
            {
                TrackId      = track.Id,
                SegmentStart = segStart,
                SegmentEnd   = segEnd,
                AnalyzedAt   = DateTimeOffset.UtcNow.ToUnixTimeSeconds(),
                Energy       = feats.Energy,
                Brightness   = feats.Brightness,
                Zcr          = feats.Zcr,
                Timbre       = feats.Timbre,
                Groove       = feats.Groove,
                Happiness    = feats.Happiness,
            };
        }
        finally { try { File.Delete(tmpPath); } catch { } }
    }

    // Port of analyzer.py / AnalysisEngine.swift
    public static (double start, double end) FindAnalysisSegment(double[] peaks, double duration)
    {
        const double seg = 60.0;
        if (peaks.Length == 0 || duration <= 0)
        {
            var s = duration * 0.40;
            return (Math.Round(s, 1), Math.Round(Math.Min(s + seg, duration), 1));
        }

        int n       = peaks.Length;
        int lo      = (int)(n * 0.35);
        int hi      = (int)(n * 0.65);
        int win     = Math.Max(1, Math.Min((int)(n * seg / duration), hi - lo));
        int bestIdx = lo;
        double best = -1;

        for (int i = lo; i < Math.Max(lo + 1, hi - win + 1); i++)
        {
            double sum = 0;
            int count  = 0;
            for (int j = i; j < Math.Min(i + win, n); j++) { sum += peaks[j]; count++; }
            double avg = count > 0 ? sum / count : 0;
            if (avg > best) { best = avg; bestIdx = i; }
        }

        var start = Math.Round(duration * bestIdx / n, 1);
        var end   = Math.Round(Math.Min(start + seg, duration), 1);
        return (start, end);
    }

    private record Features(double Energy, double Brightness, double Zcr,
                             double Groove, double Happiness, double[] Timbre);

    private static Features? ComputeFeatures(string wavPath)
    {
        float[]? samples = LoadMonoSamples(wavPath);
        if (samples == null || samples.Length < 512) return null;

        const double sr = 22050.0;
        int n = samples.Length;

        // RMS energy
        double sumSq = 0;
        foreach (var s in samples) sumSq += s * s;
        double energy = Math.Sqrt(sumSq / n);

        // FFT power spectrum
        int fftLen = NextPow2(n);
        var padded = new float[fftLen];
        Array.Copy(samples, padded, Math.Min(n, fftLen));

        // Hann window
        for (int i = 0; i < fftLen; i++)
            padded[i] *= (float)(0.5 * (1 - Math.Cos(2 * Math.PI * i / (fftLen - 1))));

        // MathNet FFT
        var complex = padded.Select(s => new System.Numerics.Complex(s, 0)).ToArray();
        Fourier.Forward(complex, FourierOptions.Matlab);
        var power = complex.Take(fftLen / 2).Select(c => (float)(c.Real * c.Real + c.Imaginary * c.Imaginary)).ToArray();

        // Spectral centroid → brightness
        double freqBinWidth = sr / fftLen;
        double weightedSum = 0, totalPower = 0;
        for (int i = 0; i < power.Length; i++)
        {
            double freq = i * freqBinWidth;
            weightedSum += freq * power[i];
            totalPower  += power[i];
        }
        double centroid   = totalPower > 0 ? weightedSum / totalPower : 0;
        double brightness = Math.Min(1.0, centroid / 4000.0);

        // ZCR
        int crossings = 0;
        for (int i = 1; i < n; i++)
            if ((samples[i - 1] >= 0) != (samples[i] >= 0)) crossings++;
        double zcr = (double)crossings / n;

        // MFCC
        var timbre = ComputeMfcc(power, sr, fftLen);

        // Groove
        double groove = ComputeGroove(samples, sr);

        // Happiness
        double happiness = ComputeHappiness(power, sr, fftLen);

        return new Features(energy, brightness, zcr, groove, happiness, timbre);
    }

    private static double[] ComputeMfcc(float[] power, double sr, int fftLen)
    {
        const int nFilters = 40;
        const int nCoeffs  = 13;
        const double fLow  = 20.0;
        double fHigh = Math.Min(sr / 2, 8000.0);

        static double HzToMel(double hz) => 2595 * Math.Log10(1 + hz / 700);
        static double MelToHz(double mel) => 700 * (Math.Pow(10, mel / 2595) - 1);

        double melLow  = HzToMel(fLow);
        double melHigh = HzToMel(fHigh);
        var melPts  = Enumerable.Range(0, nFilters + 2)
                        .Select(i => melLow + (melHigh - melLow) * i / (nFilters + 1)).ToArray();
        var freqPts = melPts.Select(MelToHz).ToArray();
        double binWidth = sr / fftLen;

        var melEnergies = new double[nFilters];
        for (int m = 0; m < nFilters; m++)
        {
            double f0 = freqPts[m], f1 = freqPts[m + 1], f2 = freqPts[m + 2];
            for (int k = 0; k < power.Length; k++)
            {
                double freq = k * binWidth;
                double w = 0;
                if      (freq >= f0 && freq <= f1) w = (freq - f0) / (f1 - f0);
                else if (freq > f1  && freq <= f2) w = (f2 - freq) / (f2 - f1);
                melEnergies[m] += w * power[k];
            }
            melEnergies[m] = Math.Log(Math.Max(melEnergies[m], 1e-10));
        }

        var mfcc = new double[nCoeffs];
        for (int nc = 0; nc < nCoeffs; nc++)
        {
            double sum = 0;
            for (int m = 0; m < nFilters; m++)
                sum += melEnergies[m] * Math.Cos(Math.PI * nc * (m + 0.5) / nFilters);
            mfcc[nc] = Math.Round(sum * 10000) / 10000;
        }
        return mfcc;
    }

    private static double ComputeGroove(float[] samples, double sr)
    {
        const int frameLen = 512;
        const int hopLen   = 256;
        if (samples.Length <= frameLen * 4) return 0.5;

        var prevFrame = new float[frameLen / 2];
        var onsets    = new List<double>();
        for (int pos = 0; pos + frameLen < samples.Length; pos += hopLen)
        {
            float flux = 0;
            for (int i = 0; i < frameLen / 2; i++)
            {
                float diff = Math.Abs(samples[pos + i]) - prevFrame[i];
                if (diff > 0) flux += diff;
            }
            if (flux > 0.01f) onsets.Add((double)pos / sr);
            Array.Copy(samples, pos, prevFrame, 0, frameLen / 2);
        }

        if (onsets.Count <= 3) return 0.5;

        var intervals = Enumerable.Range(1, onsets.Count - 1)
                          .Select(i => onsets[i] - onsets[i - 1]).ToArray();
        double mean   = intervals.Average();
        double stddev = Math.Sqrt(intervals.Select(x => Math.Pow(x - mean, 2)).Average());
        double groove = Math.Max(0, Math.Min(1.0, 1.0 - stddev / (mean + 1e-6)));
        return Math.Round(groove * 10000) / 10000;
    }

    private static double ComputeHappiness(float[] power, double sr, int fftLen)
    {
        var chroma = new double[12];
        double binWidth = sr / fftLen;
        const double a4Hz = 440.0;

        for (int k = 1; k < power.Length; k++)
        {
            double freq = k * binWidth;
            if (freq <= 20) continue;
            double midi  = 69.0 + 12.0 * Math.Log2(freq / a4Hz);
            int pitchCl  = ((int)Math.Round(midi) % 12 + 12) % 12;
            chroma[pitchCl] += power[k];
        }
        double maxC = chroma.Max();
        if (maxC > 0) for (int i = 0; i < 12; i++) chroma[i] /= maxC;

        int[] major = { 0, 2, 4, 5, 7, 9, 11 };
        int[] minor = { 0, 2, 3, 5, 7, 8, 10 };
        double bestMaj = 0, bestMin = 0;
        for (int root = 0; root < 12; root++)
        {
            double maj = major.Sum(i => chroma[(i + root) % 12]);
            double min = minor.Sum(i => chroma[(i + root) % 12]);
            bestMaj = Math.Max(bestMaj, maj);
            bestMin = Math.Max(bestMin, min);
        }
        double total = bestMaj + bestMin + 1e-8;
        return Math.Round(bestMaj / total * 10000) / 10000;
    }

    private static float[]? LoadMonoSamples(string wavPath)
    {
        try
        {
            using var reader = new AudioFileReader(wavPath);
            ISampleProvider provider = reader;
            if (reader.WaveFormat.Channels > 1)
                provider = new StereoToMonoSampleProvider(reader);
            if (reader.WaveFormat.SampleRate != 22050)
                provider = new WdlResamplingSampleProvider(provider, 22050);

            int maxSamples = 22050 * 70;
            var buffer = new float[maxSamples];
            int read   = provider.Read(buffer, 0, maxSamples);
            return read >= 512 ? buffer[..read] : null;
        }
        catch (Exception ex) { Log.Warn($"LoadMonoSamples failed: {ex.Message}"); return null; }
    }

    private static int NextPow2(int n)
    {
        int p = 1;
        while (p < n) p <<= 1;
        return p;
    }
}
