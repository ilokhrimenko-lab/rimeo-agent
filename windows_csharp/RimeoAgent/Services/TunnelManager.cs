using System.Diagnostics;
using System.Text.RegularExpressions;
using RimeoAgent.Config;
using RimeoAgent.Models;

namespace RimeoAgent.Services;

public sealed class TunnelManager
{
    public static readonly TunnelManager Shared = new();

    private readonly object _lock = new();
    private Process?  _proc;
    private string    _tunnelUrl  = "";
    private bool      _shouldRun;
    private bool      _loopRunning;

    private const int NormalRestartDelaySec   = 5;
    private const int MaxRestartDelaySec      = 300;
    private const int RateLimitRestartDelaySec = 15 * 60;

    public string ActiveUrl  { get { lock (_lock) return _tunnelUrl;           } }
    public bool   IsRunning  { get { lock (_lock) return _proc?.HasExited == false; } }

    public void AutoStartIfAvailable()
    {
        if (FindCloudflared() != null) Start();
        else
        {
            Log.Warn("Tunnel auto-start skipped: cloudflared not found");
            DataStore.Shared.Update(d => d.TunnelUrl = "");
        }
    }

    public void Start()
    {
        lock (_lock)
        {
            if (_loopRunning) return;
            _shouldRun   = true;
            _loopRunning = true;
            _tunnelUrl   = "";
        }
        Task.Run(RunTunnel);
    }

    public void Stop()
    {
        lock (_lock)
        {
            _shouldRun = false;
            try { _proc?.Kill(true); } catch { }
            _proc      = null;
            _tunnelUrl = "";
        }
        DataStore.Shared.Update(d => d.TunnelUrl = "");
        AppState.Shared.RefreshFromData();
    }

    public string? FindCloudflared()
    {
        // Bundled alongside the executable
        var bundled = Path.Combine(AppContext.BaseDirectory, "cloudflared.exe");
        if (File.Exists(bundled)) return bundled;

        var bundledNoExt = Path.Combine(AppContext.BaseDirectory, "cloudflared");
        if (File.Exists(bundledNoExt)) return bundledNoExt;

        // Data directory download
        var dataPath = Path.Combine(AppConfig.Shared.BaseDir, "cloudflared.exe");
        if (File.Exists(dataPath)) return dataPath;

        // PATH search
        var pathEnv = Environment.GetEnvironmentVariable("PATH") ?? "";
        foreach (var dir in pathEnv.Split(Path.PathSeparator))
        {
            var full = Path.Combine(dir, "cloudflared.exe");
            if (File.Exists(full)) return full;
        }

        return null;
    }

    private bool ShouldKeepRunning() { lock (_lock) return _shouldRun; }

    private async Task RunTunnel()
    {
        try
        {
            int failures = 0;
            var urlRegex = new Regex(@"https://[a-zA-Z0-9\-]+\.trycloudflare\.com");

            while (ShouldKeepRunning())
            {
                var cmd = FindCloudflared();
                if (cmd == null)
                {
                    Log.Error("cloudflared not found");
                    return;
                }

                var psi = new ProcessStartInfo(cmd)
                {
                    UseShellExecute        = false,
                    RedirectStandardOutput = true,
                    RedirectStandardError  = true,
                    CreateNoWindow         = true,
                };
                psi.ArgumentList.Add("tunnel");
                psi.ArgumentList.Add("--url");
                psi.ArgumentList.Add($"http://127.0.0.1:{AppConfig.Port}");
                psi.ArgumentList.Add("--no-autoupdate");
                psi.ArgumentList.Add("--protocol");
                psi.ArgumentList.Add("http2");

                var p = new Process { StartInfo = psi, EnableRaisingEvents = true };
                bool sawUrl       = false;
                bool sawRateLimit = false;

                p.OutputDataReceived += (_, e) =>
                {
                    if (e.Data == null) return;
                    Log.Debug($"cloudflared: {e.Data}");
                    if (e.Data.Contains("429") || e.Data.Contains("1015")) sawRateLimit = true;
                    var m = urlRegex.Match(e.Data);
                    if (m.Success)
                    {
                        sawUrl     = true;
                        failures   = 0;
                        var url    = m.Value;
                        lock (_lock) { _tunnelUrl = url; }
                        Log.Info($"Tunnel active: {url}");
                        DataStore.Shared.Update(d => d.TunnelUrl = url);
                        AppState.Shared.TunnelUrl    = url;
                        AppState.Shared.TunnelActive = true;
                        CloudRelay.Shared.NoteTunnelChanged(url);
                        CloudRelay.Shared.PushTunnelUpdate(url);
                    }
                };
                p.ErrorDataReceived += (_, e) =>
                {
                    if (e.Data == null) return;
                    Log.Debug($"cloudflared: {e.Data}");
                    if (e.Data.Contains("429") || e.Data.Contains("1015")) sawRateLimit = true;
                    var m = urlRegex.Match(e.Data);
                    if (m.Success)
                    {
                        sawUrl = true; failures = 0;
                        var url = m.Value;
                        lock (_lock) { _tunnelUrl = url; }
                        Log.Info($"Tunnel active: {url}");
                        DataStore.Shared.Update(d => d.TunnelUrl = url);
                        AppState.Shared.TunnelUrl = url; AppState.Shared.TunnelActive = true;
                        CloudRelay.Shared.NoteTunnelChanged(url);
                        CloudRelay.Shared.PushTunnelUpdate(url);
                    }
                };

                try { p.Start(); }
                catch (Exception ex)
                {
                    Log.Error($"cloudflared launch failed: {ex.Message}");
                    failures++;
                    await SleepWhileRunning(RestartDelay(failures));
                    continue;
                }

                lock (_lock) { _proc = p; }
                Log.Info($"cloudflared started (path: {cmd})");
                p.BeginOutputReadLine();
                p.BeginErrorReadLine();
                await p.WaitForExitAsync();

                lock (_lock) { _tunnelUrl = ""; _proc = null; }
                DataStore.Shared.Update(d => d.TunnelUrl = "");
                AppState.Shared.TunnelUrl = ""; AppState.Shared.TunnelActive = false;
                CloudRelay.Shared.NoteTunnelChanged("");
                Log.Info("cloudflared stopped");

                if (!ShouldKeepRunning()) break;

                int delaySec;
                if (sawRateLimit)
                {
                    failures++;
                    delaySec = RateLimitRestartDelaySec;
                    Log.Warn($"cloudflared rate limited; pausing {delaySec}s");
                }
                else if (sawUrl)
                {
                    failures = 0;
                    delaySec = NormalRestartDelaySec;
                    Log.Info($"cloudflared restarting in {delaySec}s");
                }
                else
                {
                    failures++;
                    delaySec = RestartDelay(failures);
                    Log.Info($"cloudflared restarting in {delaySec}s after {failures} failed attempt(s)");
                }
                await SleepWhileRunning(delaySec);
            }
        }
        finally
        {
            lock (_lock) { _loopRunning = false; }
            Log.Info("Tunnel loop exited");
        }
    }

    private static int RestartDelay(int failures)
    {
        int exp   = Math.Max(0, Math.Min(failures - 1, 6));
        double d  = NormalRestartDelaySec * Math.Pow(2, exp);
        return (int)Math.Min(d, MaxRestartDelaySec);
    }

    private async Task SleepWhileRunning(int seconds)
    {
        var deadline = DateTime.UtcNow.AddSeconds(seconds);
        while (ShouldKeepRunning() && DateTime.UtcNow < deadline)
            await Task.Delay(1000);
    }
}
