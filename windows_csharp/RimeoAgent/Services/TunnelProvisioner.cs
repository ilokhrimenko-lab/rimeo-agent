using System.Net.Http;
using System.Text.Json;
using RimeoAgent.Config;
using RimeoAgent.Models;

namespace RimeoAgent.Services;

/// Fetches a per-user named cloudflared tunnel from the server and writes the local
/// cloudflared config so TunnelManager switches off the (server-rejected) quick
/// tunnel onto "<hash>.rimeo.app". 1:1 port of the macOS TunnelProvisioner.
///
/// No-op when already on a named tunnel, when the agent isn't linked, or when the
/// server declines. Transient declines are retried (bounded) honouring retry_after.
public sealed class TunnelProvisioner
{
    public static readonly TunnelProvisioner Shared = new();
    private TunnelProvisioner() { }

    private readonly object _lock = new();
    private bool _inFlight;
    private const int MaxAttempts = 5;
    private static readonly HashSet<string> RetryReasons = new() { "throttled", "cloudflare_error", "db_error" };

    public void ProvisionIfNeeded()
    {
        lock (_lock) { if (_inFlight) return; _inFlight = true; }
        Task.Run(async () =>
        {
            try { await Attempt(1); }
            catch (Exception ex) { Log.Error($"Tunnel provision failed: {ex.Message}"); }
            finally { lock (_lock) { _inFlight = false; } }
        });
    }

    private async Task Attempt(int n)
    {
        if (TunnelManager.Shared.HasNamedTunnelConfig())
        {
            Log.Info("Tunnel provision: already on a named tunnel, skipping");
            return;
        }

        var d = DataStore.Shared.Data;
        if (string.IsNullOrEmpty(d.CloudUrl) || string.IsNullOrEmpty(d.CloudToken))
        {
            Log.Debug("Tunnel provision: agent not linked, skipping");
            return;
        }

        var result = await Fetch(d.CloudUrl, d.CloudToken);
        if (result == null)
        {
            if (n < MaxAttempts)
            {
                Log.Debug($"Tunnel provision: network error, retry {n + 1}/{MaxAttempts} in 30s");
                await Task.Delay(30_000);
                await Attempt(n + 1);
            }
            return;
        }

        if (result.TryGetValue("provisioned", out var pv) && pv.ValueKind == JsonValueKind.True)
        {
            Apply(result);
            return;
        }

        var reason     = result.TryGetValue("reason", out var rEl) ? rEl.GetString() ?? "unknown" : "unknown";
        var retryAfter = result.TryGetValue("retry_after", out var raEl) ? GetDouble(raEl) : 0;
        var retryable  = RetryReasons.Contains(reason);
        Log.Info($"Tunnel provision declined: reason={reason}{(retryable ? ", will retry" : "")}");
        if (retryable && n < MaxAttempts && retryAfter > 0)
        {
            await Task.Delay((int)(Math.Min(retryAfter, 300) * 1000));
            await Attempt(n + 1);
        }
    }

    private static async Task<Dictionary<string, JsonElement>?> Fetch(string cloudUrl, string token)
    {
        try
        {
            var agentId = AppConfig.Shared.AgentId;
            var build   = Uri.EscapeDataString(AppConfig.Shared.BuildNumber);
            var url     = $"{cloudUrl}/api/agent/tunnel_provision?agent_id={agentId}&token={token}&build={build}";
            using var http = new HttpClient { Timeout = TimeSpan.FromSeconds(30) };
            http.DefaultRequestHeaders.TryAddWithoutValidation("User-Agent", $"RimeoAgentWin/{AppConfig.Shared.Version}");
            var json = await http.GetStringAsync(url);
            return JsonSerializer.Deserialize<Dictionary<string, JsonElement>>(json);
        }
        catch (Exception ex)
        {
            Log.Warn($"Tunnel provision fetch failed: {ex.Message}");
            return null;
        }
    }

    private void Apply(Dictionary<string, JsonElement> r)
    {
        var tunnelId = r.TryGetValue("tunnel_id",       out var t) ? t.GetString() ?? "" : "";
        var hostname = r.TryGetValue("hostname",        out var h) ? h.GetString() ?? "" : "";
        var credsB64 = r.TryGetValue("credentials_b64", out var c) ? c.GetString() ?? "" : "";
        if (tunnelId.Length == 0 || hostname.Length == 0 || credsB64.Length == 0)
        {
            Log.Warn("Tunnel provision: malformed payload, cannot apply");
            return;
        }

        byte[] creds;
        try { creds = Convert.FromBase64String(credsB64); }
        catch { Log.Warn("Tunnel provision: bad credentials_b64"); return; }

        var dir = AppConfig.Shared.CloudflaredDir;
        try { Directory.CreateDirectory(dir); }
        catch (Exception ex) { Log.Warn($"Tunnel provision: cannot create {dir}: {ex.Message}"); return; }

        var credsPath = Path.Combine(dir, $"{tunnelId}.json");
        try { File.WriteAllBytes(credsPath, creds); }
        catch (Exception ex) { Log.Warn($"Tunnel provision: cannot write credentials: {ex.Message}"); return; }

        // config_src=local — ingress lives here. cloudflared is launched as
        // `tunnel --config <this> run <uuid>` by TunnelManager. Forward slashes
        // keep cloudflared/YAML happy with the Windows path.
        var credsYaml  = credsPath.Replace("\\", "/");
        var configPath = Path.Combine(dir, "config.yml");
        var yaml =
            $"tunnel: {tunnelId}\n" +
            $"credentials-file: {credsYaml}\n" +
            "ingress:\n" +
            $"  - hostname: {hostname}\n" +
            $"    service: http://127.0.0.1:{AppConfig.Port}\n" +
            "  - service: http_status:404\n";
        try { File.WriteAllText(configPath, yaml); }
        catch (Exception ex) { Log.Warn($"Tunnel provision: cannot write config.yml: {ex.Message}"); return; }

        var reused = r.TryGetValue("reused", out var ru) && ru.ValueKind == JsonValueKind.True;
        Log.Info($"Tunnel provisioned ({(reused ? "reused" : "new")}): hostname={hostname}, uuid={tunnelId} — switching tunnel");
        TunnelManager.Shared.ReloadAfterConfigChange();
    }

    private static double GetDouble(JsonElement e) => e.ValueKind switch
    {
        JsonValueKind.Number => e.GetDouble(),
        JsonValueKind.String => double.TryParse(e.GetString(), out var d) ? d : 0,
        _ => 0
    };
}
