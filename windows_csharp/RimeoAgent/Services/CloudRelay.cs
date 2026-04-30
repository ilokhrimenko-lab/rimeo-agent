using System.Text;
using System.Text.Json;
using RimeoAgent.Config;
using RimeoAgent.Models;

namespace RimeoAgent.Services;

public sealed class CloudRelay
{
    public static readonly CloudRelay Shared = new();

    private readonly object _lock = new();
    private bool _running;
    private string? _lastAdvertisedTunnel;

    public void StartIfLinked()
    {
        var d = DataStore.Shared.Data;
        if (string.IsNullOrEmpty(d.CloudUrl) || string.IsNullOrEmpty(d.CloudToken)) return;
        Start(d.CloudUrl, d.CloudToken);
    }

    public void Start(string cloudUrl, string token)
    {
        lock (_lock)
        {
            if (_running) return;
            _running = true;
        }
        Task.Run(() => Loop(cloudUrl, token));
    }

    public void Stop() { lock (_lock) { _running = false; } }
    private bool IsRunning() { lock (_lock) { return _running; } }

    private async Task Loop(string initialCloudUrl, string initialToken)
    {
        int backoffSec = 1;
        using var http = new HttpClient();

        while (IsRunning())
        {
            var d = DataStore.Shared.Data;
            var cloudUrl  = string.IsNullOrEmpty(d.CloudUrl)   ? initialCloudUrl  : d.CloudUrl;
            var cloudToken = string.IsNullOrEmpty(d.CloudToken) ? initialToken     : d.CloudToken;

            if (string.IsNullOrEmpty(cloudUrl) || string.IsNullOrEmpty(cloudToken))
            {
                await Task.Delay(30_000);
                continue;
            }

            var tunnel    = TunnelManager.Shared.ActiveUrl;
            var pollUrl   = $"{cloudUrl}/api/relay/poll/{AppConfig.Shared.AgentId}?token={cloudToken}";
            if (!string.IsNullOrEmpty(tunnel))
                pollUrl += $"&tunnel={Uri.EscapeDataString(tunnel)}";

            LogTunnelIfChanged(tunnel);

            try
            {
                Log.Info($"Cloud relay connecting: {cloudUrl}");
                using var cts = new CancellationTokenSource(TimeSpan.FromSeconds(30));
                var req = new HttpRequestMessage(HttpMethod.Get, pollUrl);
                req.Headers.TryAddWithoutValidation("User-Agent",
                    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36");
                req.Headers.Accept.ParseAdd("application/json");

                var resp = await http.SendAsync(req, cts.Token);
                var body = await resp.Content.ReadAsStringAsync();

                if (resp.StatusCode == System.Net.HttpStatusCode.Forbidden)
                {
                    Log.Warn("Cloud relay: unauthorized (bad token), retry in 60s");
                    await Task.Delay(60_000);
                    backoffSec = 1;
                    continue;
                }

                if (!resp.IsSuccessStatusCode)
                {
                    Log.Warn($"Cloud relay poll: HTTP {(int)resp.StatusCode}, retry in {backoffSec}s");
                    await Task.Delay(backoffSec * 1000);
                    backoffSec = Math.Min(backoffSec * 2, 30);
                    continue;
                }

                var msg = JsonSerializer.Deserialize<Dictionary<string, JsonElement>>(body);
                if (msg == null)
                {
                    await Task.Delay(backoffSec * 1000);
                    backoffSec = Math.Min(backoffSec * 2, 30);
                    continue;
                }

                backoffSec = 1;

                if (msg.TryGetValue("type", out var typeEl) && typeEl.GetString() == "ping")
                    continue;

                // Handle command on a separate task
                _ = Task.Run(() => HandleCommand(msg, cloudUrl));
            }
            catch (Exception ex) when (!IsRunning())
            {
                _ = ex;
                return;
            }
            catch (Exception ex)
            {
                Log.Warn($"Cloud relay error: {ex.Message}, retry in {backoffSec}s");
                await Task.Delay(backoffSec * 1000);
                backoffSec = Math.Min(backoffSec * 2, 30);
            }
        }
    }

    public void NoteTunnelChanged(string tunnelUrl) =>
        Log.Info($"Cloud relay tunnel changed: {(string.IsNullOrEmpty(tunnelUrl) ? "(none)" : tunnelUrl)}");

    public async void PushTunnelUpdate(string tunnelUrl)
    {
        var d = DataStore.Shared.Data;
        if (string.IsNullOrEmpty(d.CloudUrl) || string.IsNullOrEmpty(d.CloudToken)) return;
        try
        {
            using var http = new HttpClient();
            var url = $"{d.CloudUrl}/api/relay/poll/{AppConfig.Shared.AgentId}" +
                      $"?token={d.CloudToken}&tunnel={Uri.EscapeDataString(tunnelUrl)}";
            using var cts = new CancellationTokenSource(TimeSpan.FromSeconds(5));
            await http.GetAsync(url, cts.Token);
            Log.Info($"Tunnel URL pushed to cloud: {tunnelUrl}");
        }
        catch { }
    }

    private void LogTunnelIfChanged(string tunnel)
    {
        lock (_lock)
        {
            if (_lastAdvertisedTunnel == tunnel) return;
            _lastAdvertisedTunnel = tunnel;
        }
        if (string.IsNullOrEmpty(tunnel))
            Log.Warn("Cloud relay advertising no tunnel URL.");
        else
            Log.Info($"Cloud relay advertising tunnel URL: {tunnel}");
    }

    private static async Task HandleCommand(Dictionary<string, JsonElement> cmd, string cloudUrl)
    {
        var reqId  = cmd.TryGetValue("req_id",  out var r) ? r.GetString() ?? "" : "";
        var method = cmd.TryGetValue("method",  out var m) ? m.GetString() ?? "GET" : "GET";
        var path   = cmd.TryGetValue("path",    out var p) ? p.GetString() ?? "/" : "/";
        var bodyB64 = cmd.TryGetValue("body",   out var bEl) ? bEl.GetString() : null;
        var body   = bodyB64 != null ? Convert.FromBase64String(bodyB64) : null;

        Dictionary<string, string> headers = new();
        if (cmd.TryGetValue("headers", out var hEl) && hEl.ValueKind == JsonValueKind.Object)
        {
            foreach (var prop in hEl.EnumerateObject())
                headers[prop.Name] = prop.Value.GetString() ?? "";
        }

        Log.Info($"Relay local request: req={reqId}, method={method}, path={path}");

        var localUrl = $"http://127.0.0.1:{AppConfig.Port}{path}";
        string resultBodyB64;
        int resultStatus;
        Dictionary<string, string> resultHeaders = new();

        try
        {
            using var http = new HttpClient();
            using var req  = new HttpRequestMessage(new HttpMethod(method), localUrl);
            if (body != null) req.Content = new ByteArrayContent(body);

            foreach (var (k, v) in headers)
            {
                if (k.ToLower() == "host") continue;
                if (!req.Headers.TryAddWithoutValidation(k, v))
                    req.Content?.Headers.TryAddWithoutValidation(k, v);
            }

            using var cts  = new CancellationTokenSource(TimeSpan.FromSeconds(30));
            var sw   = System.Diagnostics.Stopwatch.StartNew();
            using var resp = await http.SendAsync(req, cts.Token);
            var respBytes  = await resp.Content.ReadAsByteArrayAsync();
            sw.Stop();

            resultStatus  = (int)resp.StatusCode;
            resultBodyB64 = Convert.ToBase64String(respBytes);
            foreach (var h in resp.Headers) resultHeaders[h.Key] = string.Join(", ", h.Value);
            foreach (var h in resp.Content.Headers) resultHeaders[h.Key] = string.Join(", ", h.Value);

            Log.Info($"Relay local response: req={reqId}, status={resultStatus}, body_bytes={respBytes.Length}, elapsed={sw.Elapsed.TotalSeconds:F2}s");
        }
        catch (Exception ex)
        {
            Log.Error($"Relay error req={reqId}: {ex.Message}");
            resultStatus  = 502;
            resultBodyB64 = Convert.ToBase64String(Encoding.UTF8.GetBytes(ex.Message));
        }

        // POST result back to cloud
        var result = new Dictionary<string, object>
        {
            ["req_id"]  = reqId,
            ["status"]  = resultStatus,
            ["headers"] = resultHeaders,
            ["body_b64"] = resultBodyB64,
        };

        try
        {
            using var http2  = new HttpClient();
            using var cts2   = new CancellationTokenSource(TimeSpan.FromSeconds(30));
            var postBody     = new StringContent(JsonSerializer.Serialize(result),
                                                  Encoding.UTF8, "application/json");
            var postResp     = await http2.PostAsync($"{cloudUrl}/api/relay/result", postBody, cts2.Token);
            var code         = (int)postResp.StatusCode;
            if (code != 200) Log.Error($"Relay result POST failed req={reqId}: HTTP {code}");
            else             Log.Debug($"Relay result POST ok req={reqId}");
        }
        catch (Exception ex) { Log.Error($"Relay result POST failed req={reqId}: {ex.Message}"); }
    }
}
