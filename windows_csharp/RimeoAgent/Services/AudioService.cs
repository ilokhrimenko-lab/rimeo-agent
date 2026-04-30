using RimeoAgent.Config;

namespace RimeoAgent.Services;

public sealed class AudioService
{
    public static readonly AudioService Shared = new();

    private readonly Dictionary<string, SemaphoreSlim> _convLocks = new();
    private readonly object _lockGuard = new();

    private SemaphoreSlim ConvLock(string id)
    {
        lock (_lockGuard)
        {
            if (!_convLocks.TryGetValue(id, out var sem))
            {
                sem = new SemaphoreSlim(1, 1);
                _convLocks[id] = sem;
            }
            return sem;
        }
    }

    public async Task<string> EnsureWav(string path, string trackId)
    {
        var cached = Path.Combine(AppConfig.Shared.CacheDir, $"conv_{trackId}.wav");
        if (File.Exists(cached)) return cached;

        var sem = ConvLock(trackId);
        await sem.WaitAsync();
        try
        {
            if (File.Exists(cached)) return cached;

            Log.Info($"Converting AIFF → WAV: {trackId}");
            var result = RunProcess("ffmpeg", new[] { "-i", path, "-f", "wav", cached, "-y" }, 120);
            if (!result.Success || !File.Exists(cached))
                throw new Exception($"AIFF conversion failed: {result.Stderr}");

            Log.Info($"AIFF conversion complete: track={trackId}, wav={cached}");
            return cached;
        }
        finally { sem.Release(); }
    }

    public Dictionary<string, object> Waveform(string path, string trackId)
    {
        var cacheFile = Path.Combine(AppConfig.Shared.CacheDir, $"wave_{trackId}.json");
        if (File.Exists(cacheFile))
        {
            try
            {
                var cached = System.Text.Json.JsonSerializer.Deserialize<Dictionary<string, object>>(
                    File.ReadAllText(cacheFile));
                if (cached != null) return cached;
            }
            catch { }
        }

        if (!File.Exists(path))
            return new Dictionary<string, object> { ["duration"] = 0.0, ["peaks"] = Array.Empty<double>() };

        var probe = RunProcess("ffprobe", new[]
        {
            "-v", "error",
            "-show_entries", "format=duration",
            "-of", "default=noprint_wrappers=1:nokey=1",
            path
        }, 12);
        var duration = double.TryParse(probe.Stdout.Trim(), System.Globalization.NumberStyles.Float,
            System.Globalization.CultureInfo.InvariantCulture, out var d) ? d : 0.0;

        var cmd = new[] { "-v", "error", "-i", path, "-ac", "1", "-filter:a", "aresample=100", "-f", "s8", "-" };
        var result = RunProcess("ffmpeg", cmd, 60);
        if (!result.Success || result.RawOutput.Length == 0)
        {
            Log.Warn($"Waveform failed: track={trackId}, stderr={result.Stderr}");
            return new Dictionary<string, object> { ["duration"] = duration, ["peaks"] = Array.Empty<double>() };
        }

        var bytes = result.RawOutput;
        var samples = bytes.Select(b => Math.Abs(b < 128 ? (int)b : (int)b - 256) / 128.0).ToArray();
        var step = Math.Max(1, samples.Length / 8000);
        var peaks = new List<double>();
        for (int i = 0; i < samples.Length; i += step)
        {
            var chunk = samples.Skip(i).Take(step).ToArray();
            var avg   = chunk.Average();
            peaks.Add(Math.Min(1.0, Math.Round(avg * 2.5 * 1000) / 1000));
        }

        var out_ = new Dictionary<string, object> { ["duration"] = duration, ["peaks"] = peaks.ToArray() };
        try
        {
            File.WriteAllText(cacheFile, System.Text.Json.JsonSerializer.Serialize(out_));
        }
        catch { }
        return out_;
    }

    public string? Artwork(string path, string trackId)
    {
        var cacheFile = Path.Combine(AppConfig.Shared.CacheDir, $"art_{trackId}.jpg");
        if (File.Exists(cacheFile)) return cacheFile;
        if (!File.Exists(path)) return null;

        var probe = RunProcess("ffprobe", new[]
        {
            "-v", "error", "-select_streams", "v:0",
            "-show_entries", "stream=index", "-of", "csv=p=0", path
        }, 12);
        if (string.IsNullOrWhiteSpace(probe.Stdout.Trim())) return null;

        var result = RunProcess("ffmpeg", new[]
        {
            "-v", "error", "-i", path, "-map", "0:v:0", "-an",
            "-vcodec", "mjpeg", "-vframes", "1", "-s", "512x512",
            cacheFile, "-y"
        }, 45);
        var ok = result.Success && File.Exists(cacheFile);
        if (!ok) Log.Warn($"Artwork extraction failed: track={trackId}");
        return ok ? cacheFile : null;
    }

    public double ProbeDuration(string path)
    {
        var r = RunProcess("ffprobe", new[]
        {
            "-v", "error", "-show_entries", "format=duration",
            "-of", "default=noprint_wrappers=1:nokey=1", path
        }, 12);
        return double.TryParse(r.Stdout.Trim(), System.Globalization.NumberStyles.Float,
            System.Globalization.CultureInfo.InvariantCulture, out var d) ? d : 300.0;
    }

    public string? ExtractSegment(string path, double start, double duration)
    {
        var tmp = Path.Combine(Path.GetTempPath(), $"rimeo_seg_{Guid.NewGuid():N}.wav");
        var result = RunProcess("ffmpeg", new[]
        {
            "-v", "error",
            "-ss", start.ToString("F1", System.Globalization.CultureInfo.InvariantCulture),
            "-t",  duration.ToString("F1", System.Globalization.CultureInfo.InvariantCulture),
            "-i", path,
            "-ac", "1", "-ar", "22050",
            "-f", "wav", "-y", tmp
        }, 45);
        if (!result.Success || !File.Exists(tmp)) return null;
        return tmp;
    }

    public static string? FindBinary(string name)
    {
        var bundleDir = AppContext.BaseDirectory;
        var bundled   = Path.Combine(bundleDir, $"{name}.exe");
        if (File.Exists(bundled)) return bundled;

        var plain = Path.Combine(bundleDir, name);
        if (File.Exists(plain)) return plain;

        // Search PATH
        var pathEnv = Environment.GetEnvironmentVariable("PATH") ?? "";
        foreach (var dir in pathEnv.Split(Path.PathSeparator))
        {
            var full = Path.Combine(dir, $"{name}.exe");
            if (File.Exists(full)) return full;
            var noExt = Path.Combine(dir, name);
            if (File.Exists(noExt)) return noExt;
        }

        // Common install locations
        var commonPaths = new[]
        {
            @"C:\ffmpeg\bin",
            @"C:\Program Files\ffmpeg\bin",
            Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles), "ffmpeg", "bin"),
        };
        foreach (var dir in commonPaths)
        {
            var full = Path.Combine(dir, $"{name}.exe");
            if (File.Exists(full)) return full;
        }

        return null;
    }

    public static ProcessResult RunProcess(string binary, string[] args, int timeoutSec)
    {
        var bin = FindBinary(binary);
        if (bin == null)
        {
            Log.Warn($"{binary} not found");
            return new ProcessResult(false, "", $"{binary} not found", Array.Empty<byte>());
        }

        var psi = new System.Diagnostics.ProcessStartInfo(bin)
        {
            UseShellExecute        = false,
            RedirectStandardOutput = true,
            RedirectStandardError  = true,
            CreateNoWindow         = true,
        };
        foreach (var arg in args) psi.ArgumentList.Add(arg);

        using var proc = new System.Diagnostics.Process { StartInfo = psi };
        var stdoutData = new System.Collections.Concurrent.ConcurrentBag<byte[]>();
        var stderrData = new System.Collections.Concurrent.ConcurrentBag<byte[]>();

        proc.OutputDataReceived += (_, e) => { if (e.Data != null) stdoutData.Add(System.Text.Encoding.UTF8.GetBytes(e.Data + "\n")); };
        proc.ErrorDataReceived  += (_, e) => { if (e.Data != null) stderrData.Add(System.Text.Encoding.UTF8.GetBytes(e.Data + "\n")); };

        try { proc.Start(); } catch (Exception ex) { return new ProcessResult(false, "", ex.Message, Array.Empty<byte>()); }

        // For binary stdout (waveform), don't use async reading
        byte[] rawOut;
        if (args.Length > 0 && args[^1] == "-")
        {
            // Raw binary output to stdout
            using var ms = new MemoryStream();
            proc.StandardOutput.BaseStream.CopyTo(ms);
            rawOut = ms.ToArray();
        }
        else
        {
            proc.BeginOutputReadLine();
            proc.BeginErrorReadLine();
            rawOut = Array.Empty<byte>();
        }

        var finished = proc.WaitForExit(timeoutSec * 1000);
        if (!finished) { proc.Kill(true); return new ProcessResult(false, "", $"{binary} timed out", Array.Empty<byte>()); }

        var stdout = rawOut.Length > 0
            ? System.Text.Encoding.UTF8.GetString(rawOut)
            : string.Concat(stdoutData.Select(b => System.Text.Encoding.UTF8.GetString(b)));
        var stderr = string.Concat(stderrData.Select(b => System.Text.Encoding.UTF8.GetString(b)));

        return new ProcessResult(proc.ExitCode == 0, stdout, stderr, rawOut);
    }
}

public record ProcessResult(bool Success, string Stdout, string Stderr, byte[] RawOutput);
