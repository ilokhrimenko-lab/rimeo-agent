using System.Diagnostics;
using System.Net.Http;
using System.Text.RegularExpressions;
using RimeoAgent.Config;
using RimeoAgent.Models;

namespace RimeoAgent.Services;

public sealed class TunnelManager
{
    public static readonly TunnelManager Shared = new();

    private readonly object _lock = new();
    private Process?  _proc;
    private string    _tunnelUrl     = "";
    private string    _pendingUrl    = "";
    private string    _namedHostname = "";
    private bool      _shouldRun;
    private bool      _loopRunning;

    private const int NormalRestartDelaySec    = 5;
    private const int MaxRestartDelaySec       = 300;
    private const int RateLimitRestartDelaySec = 15 * 60;
    private const int ReadinessMaxAttempts     = 30;
    private const int ReadinessIntervalMs      = 2000;

    public string ActiveUrl     { get { lock (_lock) return _tunnelUrl; } }
    // Hostname of the named tunnel (e.g. "<hash>.rimeo.app"); empty in quick mode.
    public string NamedHostname { get { lock (_lock) return _namedHostname; } }
    public bool   IsRunning     { get { lock (_lock) return _proc?.HasExited == false; } }

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
            _pendingUrl  = "";
        }
        Task.Run(RunTunnel);
    }

    public void Stop()
    {
        lock (_lock)
        {
            _shouldRun = false;
            try { _proc?.Kill(true); } catch { }
            _proc       = null;
            _tunnelUrl  = "";
            _pendingUrl = "";
        }
        DataStore.Shared.Update(d => d.TunnelUrl = "");
        AppState.Shared.RefreshFromData();
    }

    /// <summary>True when a valid named-tunnel config.yml (uuid + hostname) exists.</summary>
    public bool HasNamedTunnelConfig() => ParseNamedTunnelConfig() != null;

    /// <summary>Recycle cloudflared so a freshly-written config.yml takes effect
    /// (the run loop re-reads the config each iteration). Starts the loop if idle.</summary>
    public void ReloadAfterConfigChange()
    {
        Process? p; bool running;
        lock (_lock) { running = _loopRunning; p = _proc; }
        if (running)
        {
            Log.Info("Tunnel config changed — recycling cloudflared to apply named tunnel");
            try { p?.Kill(true); } catch { }
        }
        else
        {
            Log.Info("Tunnel config changed — starting tunnel to apply named tunnel");
            Start();
        }
    }

    public string? FindCloudflared()
    {
        var bundled = Path.Combine(AppContext.BaseDirectory, "cloudflared.exe");
        if (File.Exists(bundled)) return bundled;

        var bundledNoExt = Path.Combine(AppContext.BaseDirectory, "cloudflared");
        if (File.Exists(bundledNoExt)) return bundledNoExt;

        // Downloaded via ComponentManager (id "tunnel-runtime" = cloudflared)
        var component = ComponentManager.Shared.FindComponent("tunnel-runtime");
        if (component != null) return component;

        var pathEnv = Environment.GetEnvironmentVariable("PATH") ?? "";
        foreach (var dir in pathEnv.Split(Path.PathSeparator))
        {
            var full = Path.Combine(dir, "cloudflared.exe");
            if (File.Exists(full)) return full;
        }
        return null;
    }

    private bool ShouldKeepRunning() { lock (_lock) return _shouldRun; }

    private (string uuid, string hostname, string configPath)? ParseNamedTunnelConfig()
    {
        var path = Path.Combine(AppConfig.Shared.CloudflaredDir, "config.yml");
        if (!File.Exists(path)) return null;
        string? uuid = null, hostname = null;
        try
        {
            foreach (var raw in File.ReadLines(path))
            {
                var line = raw.Trim();
                if (line.Length == 0 || line.StartsWith("#")) continue;
                if (uuid == null && line.StartsWith("tunnel:"))
                {
                    var v = line.Substring("tunnel:".Length).Trim();
                    if (v.Length > 0) uuid = v;
                }
                if (hostname == null)
                {
                    var idx = line.IndexOf("hostname:", StringComparison.Ordinal);
                    if (idx >= 0)
                    {
                        var v = line.Substring(idx + "hostname:".Length).Trim();
                        if (v.Length > 0) hostname = v;
                    }
                }
                if (uuid != null && hostname != null) break;
            }
        }
        catch { return null; }
        if (uuid == null || hostname == null) return null;
        return (uuid, hostname, path);
    }

    private async Task RunTunnel()
    {
        try
        {
            int failures = 0;
            var urlRegex = new Regex(@"https://[a-zA-Z0-9\-]+\.trycloudflare\.com");

            while (ShouldKeepRunning())
            {
                var cmd = FindCloudflared();
                if (cmd == null) { Log.Error("cloudflared not found"); return; }

                var named = ParseNamedTunnelConfig();

                var psi = new ProcessStartInfo(cmd)
                {
                    UseShellExecute        = false,
                    RedirectStandardOutput = true,
                    RedirectStandardError  = true,
                    CreateNoWindow         = true,
                };
                if (named != null)
                {
                    psi.ArgumentList.Add("tunnel");
                    psi.ArgumentList.Add("--config"); psi.ArgumentList.Add(named.Value.configPath);
                    psi.ArgumentList.Add("--no-autoupdate");
                    psi.ArgumentList.Add("--protocol"); psi.ArgumentList.Add("http2");
                    psi.ArgumentList.Add("run"); psi.ArgumentList.Add(named.Value.uuid);
                    lock (_lock) { _namedHostname = named.Value.hostname; }
                    Log.Info($"Tunnel mode: named (uuid={named.Value.uuid}, hostname={named.Value.hostname})");
                }
                else
                {
                    psi.ArgumentList.Add("tunnel");
                    psi.ArgumentList.Add("--url"); psi.ArgumentList.Add($"http://127.0.0.1:{AppConfig.Port}");
                    psi.ArgumentList.Add("--no-autoupdate");
                    psi.ArgumentList.Add("--protocol"); psi.ArgumentList.Add("http2");
                    lock (_lock) { _namedHostname = ""; }
                }

                var p = new Process { StartInfo = psi, EnableRaisingEvents = true };
                bool sawUrl = false, sawRateLimit = false;

                void HandleLine(string? data)
                {
                    if (data == null) return;
                    Log.Debug($"cloudflared: {data}");
                    if (data.Contains("429") || data.Contains("1015")) sawRateLimit = true;
                    if (named != null) return;   // named hostname is known up-front
                    bool already; lock (_lock) already = _pendingUrl.Length > 0 || _tunnelUrl.Length > 0;
                    if (already) return;
                    var m = urlRegex.Match(data);
                    if (m.Success) { sawUrl = true; failures = 0; StartReadinessProbe(m.Value); }
                }
                p.OutputDataReceived += (_, e) => HandleLine(e.Data);
                p.ErrorDataReceived  += (_, e) => HandleLine(e.Data);

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

                if (named != null)
                {
                    sawUrl = true; failures = 0;
                    StartReadinessProbe($"https://{named.Value.hostname}");
                }

                await p.WaitForExitAsync();

                lock (_lock) { _tunnelUrl = ""; _pendingUrl = ""; _proc = null; }
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

    // cloudflared prints the URL (quick) / connects (named) ~seconds before it
    // actually proxies. Stage the candidate, probe /api/status through it, and
    // only publish (promote) once it answers — so we never advertise a dead URL.
    private void StartReadinessProbe(string candidate)
    {
        lock (_lock)
        {
            if (_pendingUrl == candidate || _tunnelUrl == candidate) return;
            _pendingUrl = candidate;
        }
        Log.Info($"Tunnel URL pending readiness probe: {candidate}");
        _ = Task.Run(async () =>
        {
            for (int attempt = 1; attempt <= ReadinessMaxAttempts; attempt++)
            {
                bool stillPending;
                lock (_lock) stillPending = _pendingUrl == candidate && _tunnelUrl.Length == 0 && _shouldRun;
                if (!stillPending) return;
                if (await ProbeOnce(candidate))
                {
                    Log.Info($"Tunnel ready after {attempt} probe(s): {candidate}");
                    Promote(candidate);
                    return;
                }
                await Task.Delay(ReadinessIntervalMs);
            }
            Log.Warn($"Tunnel readiness probe exhausted; promoting anyway: {candidate}");
            Promote(candidate);
        });
    }

    private static async Task<bool> ProbeOnce(string url)
    {
        try
        {
            using var http = new HttpClient { Timeout = TimeSpan.FromSeconds(5) };
            using var req  = new HttpRequestMessage(HttpMethod.Head, $"{url}/api/status");
            using var resp = await http.SendAsync(req);
            return (int)resp.StatusCode < 400;
        }
        catch { return false; }
    }

    private void Promote(string candidate)
    {
        lock (_lock)
        {
            if (_pendingUrl != candidate || _tunnelUrl.Length > 0) return;
            _tunnelUrl  = candidate;
            _pendingUrl = "";
        }
        Log.Info($"Tunnel active: {candidate}");
        DataStore.Shared.Update(d => d.TunnelUrl = candidate);
        AppState.Shared.TunnelUrl    = candidate;
        AppState.Shared.TunnelActive = true;
        CloudRelay.Shared.NoteTunnelChanged(candidate);
        CloudRelay.Shared.PushTunnelUpdate(candidate);
    }

    private static int RestartDelay(int failures)
    {
        int exp  = Math.Max(0, Math.Min(failures - 1, 6));
        double d = NormalRestartDelaySec * Math.Pow(2, exp);
        return (int)Math.Min(d, MaxRestartDelaySec);
    }

    private async Task SleepWhileRunning(int seconds)
    {
        var deadline = DateTime.UtcNow.AddSeconds(seconds);
        while (ShouldKeepRunning() && DateTime.UtcNow < deadline)
            await Task.Delay(1000);
    }
}
