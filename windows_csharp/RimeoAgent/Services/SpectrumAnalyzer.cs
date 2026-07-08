using MathNet.Numerics.IntegralTransforms;
using NAudio.Wave;
using NAudio.Wave.SampleProviders;
using RimeoAgent.Config;   // Log

namespace RimeoAgent.Services;

/// <summary>
/// "Check spek" — desktop spectral analysis of any audio file, a native replacement
/// for Spek (Intel-only, dies with Rosetta). 1:1 port of the macOS SpectrumAnalyzer.swift
/// (github.com/alexkay/spek pipeline): decode via ffmpeg → whole-file STFT → Spek-style
/// spectrogram + fidelity verdict from the effective high-frequency cut-off. Audio bytes
/// are never modified — analysis only.
///
/// Parity note vs macOS: Apple's vDSP real FFT is scaled ×2 vs the textbook DFT, so the
/// Swift path divides magnitude² by 4·nfft². MathNet's full FFT (FourierOptions.Matlab,
/// unnormalized like FFTW/Spek) has no such factor → normDiv = nfft². A constant
/// normalization offset shifts overall brightness only; the cut-off/verdict are relative
/// (refDB − 50) and unaffected.
/// </summary>
public enum SpekVerdict { Genuine, Limited, Unknown }

public sealed class SpectrumResult
{
    public byte[] PixelsBgra = Array.Empty<byte>();   // Width*Height*4, BGRA (WriteableBitmap order)
    public int    Width;
    public int    Height;
    public double SampleRate;
    public double Nyquist;        // sr/2
    public double CeilingHz;      // Y-axis display ceiling (≥24 kHz; black above Nyquist)
    public double CutoffHz;       // highest frequency still carrying real energy
    public int?   BitDepth;       // PCM bit depth for lossless containers; null for lossy
    public double DurationSec;
    public string FormatLabel = "";
    public SpekVerdict Verdict;
}

public static class SpectrumAnalyzer
{
    // Cut-off detection (calibrated on known lossless / 320 / 128 files).
    private const double FloorDropDB = 50;      // energy below ref−50 dB is noise floor
    private const double GenuineHz   = 18_500;  // cut-off at/above this ⇒ full-range

    // DSP / rendering.
    private const int    FftSize    = 2048;     // Spek's default window (W:2048)
    private const double MaxSeconds = 1200.0;   // memory cap; whole file if shorter
    private const int    ImgCols    = 900;      // time resolution (X)
    private const int    ImgRows    = 384;      // frequency resolution (Y)

    // Spek colour range: values clamped to [DbFloor … DbCeil] then mapped 0…1.
    private const double DbFloor = -120;        // Spek LRANGE
    private const double DbCeil  = 0;           // Spek URANGE (0 dBFS)

    /// <summary>Heavy — call off the UI thread. Returns null on decode/analysis failure.</summary>
    public static SpectrumResult? Analyze(string path)
    {
        var formatLabel = Path.GetExtension(path).TrimStart('.').ToUpperInvariant();

        // Decode the whole file to a temp WAV at its native sample rate (pcm_s16le keeps
        // the rate → preserves the true Nyquist for the frequency ceiling). ffmpeg covers
        // every container (WAV / AIFF / MP3 / m4a / FLAC / …), same as the macOS path.
        var temp = Path.Combine(Path.GetTempPath(), $"rimeo_spec_{Guid.NewGuid():N}.wav");
        try
        {
            var dec = AudioService.RunProcess("ffmpeg",
                new[] { "-v", "error", "-i", path, "-c:a", "pcm_s16le", temp, "-y" }, 180);
            if (!dec.Success || !File.Exists(temp))
            {
                Log.Warn($"Spectrum ffmpeg decode failed: {dec.Stderr}");
                return null;
            }

            var (mono, sr) = ReadMono(temp);
            if (mono == null || sr <= 0 || mono.Length < FftSize) return null;

            int bins = FftSize / 2;
            double binHz = sr / FftSize;

            double durationSec = AudioService.Shared.ProbeDuration(path);
            if (durationSec <= 0) durationSec = mono.Length / sr;

            // Hann window (plain 0.5(1−cos), like Spek).
            var window = new double[FftSize];
            for (int i = 0; i < FftSize; i++)
                window[i] = 0.5 * (1 - Math.Cos(2 * Math.PI * i / (FftSize - 1)));

            double normDiv = (double)FftSize * FftSize;
            var complex = new System.Numerics.Complex[FftSize];
            var frameDB = new float[bins];

            // Fill frameDB with the dB spectrum of the FFT frame starting at `start`.
            void ComputeFrameDB(int start)
            {
                for (int i = 0; i < FftSize; i++)
                    complex[i] = new System.Numerics.Complex(mono[start + i] * window[i], 0);
                Fourier.Forward(complex, FourierOptions.Matlab);
                for (int b = 0; b < bins; b++)
                {
                    double re = complex[b].Real, im = complex[b].Imaginary;
                    double p = (re * re + im * im) / normDiv + 1e-13;   // referenced to 0 dBFS
                    frameDB[b] = (float)(10.0 * Math.Log10(p));
                }
            }

            // Per-column dB (averaged over the frames in that column) + per-bin peak dB
            // over the whole file (for cut-off detection).
            var colDB  = new float[ImgCols][];
            for (int c = 0; c < ImgCols; c++)
            {
                colDB[c] = new float[bins];
                for (int b = 0; b < bins; b++) colDB[c][b] = (float)DbFloor;
            }
            var peakDB = new float[bins];
            for (int b = 0; b < bins; b++) peakDB[b] = -200f;

            var accum = new double[bins];
            double samplesPerCol = (double)mono.Length / ImgCols;
            int lastStart = mono.Length - FftSize;

            for (int col = 0; col < ImgCols; col++)
            {
                int colStart = (int)(col * samplesPerCol);
                int colEnd   = (int)((col + 1) * samplesPerCol);
                Array.Clear(accum, 0, bins);
                int n = 0;
                int pos = colStart;
                do
                {
                    if (pos >= 0 && pos + FftSize <= mono.Length)
                    {
                        ComputeFrameDB(pos);
                        for (int b = 0; b < bins; b++)
                        {
                            accum[b] += frameDB[b];
                            if (frameDB[b] > peakDB[b]) peakDB[b] = frameDB[b];
                        }
                        n++;
                    }
                    pos += FftSize;
                } while (pos < colEnd);

                // Column shorter than one FFT: take a single clamped frame so no column is blank.
                if (n == 0)
                {
                    int p = Math.Min(Math.Max(0, colStart), lastStart);
                    if (p >= 0)
                    {
                        ComputeFrameDB(p);
                        for (int b = 0; b < bins; b++)
                        {
                            accum[b] += frameDB[b];
                            if (frameDB[b] > peakDB[b]) peakDB[b] = frameDB[b];
                        }
                        n = 1;
                    }
                }

                if (n > 0)
                {
                    float inv = 1f / n;
                    for (int b = 0; b < bins; b++) colDB[col][b] = (float)(accum[b] * inv);
                }
            }

            double cutoffHz  = DetectCutoff(peakDB, binHz, bins, sr);
            double nyquist   = sr / 2;
            double ceilingHz = Math.Max(nyquist, 24_000);   // fixed 24 kHz floor so all files share a scale
            var verdict = cutoffHz >= Math.Min(GenuineHz, nyquist - 1500) ? SpekVerdict.Genuine : SpekVerdict.Limited;

            var px = RenderPixels(colDB, bins, nyquist, ceilingHz);
            int? bitDepth = ProbeBitDepth(path);

            return new SpectrumResult
            {
                PixelsBgra  = px,
                Width       = ImgCols,
                Height      = ImgRows,
                SampleRate  = sr,
                Nyquist     = nyquist,
                CeilingHz   = ceilingHz,
                CutoffHz    = cutoffHz,
                BitDepth    = bitDepth,
                DurationSec = durationSec,
                FormatLabel = formatLabel,
                Verdict     = verdict,
            };
        }
        catch (Exception ex)
        {
            Log.Warn($"Spectrum analyze failed: {ex.Message}");
            return null;
        }
        finally { try { File.Delete(temp); } catch { } }
    }

    // MARK: - Decode to mono float at the native sample rate (no resample → keeps Nyquist)

    private static (float[]? mono, double sr) ReadMono(string wav)
    {
        try
        {
            using var reader = new AudioFileReader(wav);
            double sr = reader.WaveFormat.SampleRate;
            ISampleProvider provider = reader;
            if (reader.WaveFormat.Channels > 1)
                provider = new StereoToMonoSampleProvider(reader) { LeftVolume = 0.5f, RightVolume = 0.5f };

            long cap = (long)Math.Min(int.MaxValue, MaxSeconds * sr);
            var list = new List<float>((int)Math.Min(cap, 1 << 22));
            var buf = new float[1 << 16];
            int read;
            while ((read = provider.Read(buf, 0, buf.Length)) > 0)
            {
                for (int i = 0; i < read; i++) list.Add(buf[i]);
                if (list.Count >= cap) break;
            }
            return (list.Count >= FftSize ? list.ToArray() : null, sr);
        }
        catch (Exception ex) { Log.Warn($"ReadMono failed: {ex.Message}"); return (null, 0); }
    }

    // MARK: - Cut-off detection (operates on per-bin peak dB)

    private static double DetectCutoff(float[] peakDB, double binHz, int bins, double sr)
    {
        // reference level: median of peak energy across a solid mid band (1–6 kHz)
        int lo = Math.Max(1, (int)(1000 / binHz));
        int hi = Math.Min(bins - 1, (int)(6000 / binHz));
        if (hi <= lo) return sr / 2;

        var refSlice = new List<float>();
        for (int i = lo; i <= hi; i++) refSlice.Add(peakDB[i]);
        refSlice.Sort();
        double refDB = refSlice[refSlice.Count / 2];
        double threshold = refDB - FloorDropDB;

        // scan from the top down; first run of 3 consecutive bins above threshold = real top
        const int need = 3;
        int run = 0;
        for (int b = bins - 1; b >= 1; b--)
        {
            if (peakDB[b] > threshold)
            {
                run++;
                if (run >= need) return (b + need - 1) * binHz;
            }
            else run = 0;
        }
        return 0;
    }

    // MARK: - Spectrogram pixels (BGRA for WriteableBitmap)

    private static byte[] RenderPixels(float[][] colDB, int bins, double nyquist, double ceilingHz)
    {
        int W = ImgCols, H = ImgRows;
        double range = DbCeil - DbFloor;
        var px = new byte[W * H * 4];
        var (kr, kg, kb) = Sox(0);   // level 0 = −120 dB = black "no data" cap above Nyquist

        for (int y = 0; y < H; y++)
        {
            double fTopHz = (1.0 - (double)y       / H) * ceilingHz;
            double fBotHz = (1.0 - (double)(y + 1) / H) * ceilingHz;

            if (fBotHz >= nyquist)
            {
                for (int x = 0; x < W; x++)
                {
                    int o = (y * W + x) * 4;
                    px[o] = kb; px[o + 1] = kg; px[o + 2] = kr; px[o + 3] = 255;
                }
                continue;
            }

            double hiHz = Math.Min(fTopHz, nyquist);
            int bLo = (int)(fBotHz / nyquist * (bins - 1));
            int bHi = (int)(hiHz   / nyquist * (bins - 1));
            if (bLo < 0) bLo = 0;
            if (bHi > bins - 1) bHi = bins - 1;
            if (bHi < bLo) bHi = bLo;
            float cnt = bHi - bLo + 1;

            for (int x = 0; x < W; x++)
            {
                var col = colDB[x];
                float s = 0;
                for (int b = bLo; b <= bHi; b++) s += col[b];
                double dB = s / cnt;
                double level = Math.Min(1, Math.Max(0, (dB - DbFloor) / range));
                var (r, g, b2) = Sox(level);
                int o = (y * W + x) * 4;
                px[o] = b2; px[o + 1] = g; px[o + 2] = r; px[o + 3] = 255;   // BGRA
            }
        }
        return px;
    }

    // MARK: - SoX palette

    /// <summary>Spek's SoX palette (level 0…1 silence→loud → RGB 0…1). Shared source of
    /// truth for the spectrogram render and the dB legend swatch in the UI.</summary>
    public static (double r, double g, double b) SpekPalette(double level)
    {
        double l = Math.Min(1, Math.Max(0, level));
        double r = 0, g = 0, b = 0;
        if (l >= 0.13 && l < 0.73) r = Math.Sin((l - 0.13) / 0.60 * Math.PI / 2.0);
        else if (l >= 0.73) r = 1.0;
        if (l >= 0.60 && l < 0.91) g = Math.Sin((l - 0.60) / 0.31 * Math.PI / 2.0);
        else if (l >= 0.91) g = 1.0;
        if (l < 0.60) b = 0.5 * Math.Sin(l / 0.6 * Math.PI);
        else if (l >= 0.78) b = (l - 0.78) / 0.22;
        return (r, g, b);
    }

    private static (byte r, byte g, byte b) Sox(double level)
    {
        var (r, g, b) = SpekPalette(level);
        return ((byte)Math.Max(0, Math.Min(255, r * 255)),
                (byte)Math.Max(0, Math.Min(255, g * 255)),
                (byte)Math.Max(0, Math.Min(255, b * 255)));
    }

    // MARK: - Bit depth (lossless containers only; lossy → null, like macOS)

    private static int? ProbeBitDepth(string path)
    {
        foreach (var entry in new[] { "bits_per_raw_sample", "bits_per_sample" })
        {
            var r = AudioService.RunProcess("ffprobe", new[]
            {
                "-v", "error", "-select_streams", "a:0",
                "-show_entries", $"stream={entry}",
                "-of", "default=noprint_wrappers=1:nokey=1", path
            }, 12);
            if (int.TryParse(r.Stdout.Trim(), out var b) && b > 0) return b;
        }
        return null;
    }
}
