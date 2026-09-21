using System.Text;
using System.Text.Json;
using RimeoAgent.Config;
using RimeoAgent.Models;

namespace RimeoAgent.Services;

/// Метка «этот запрос породил наш собственный CloudRelay».
///
/// Релей переигрывает облачные запросы на 127.0.0.1 — с точки зрения HTTP-сервера он
/// неотличим ни от cloudflared, ни от локального браузера: у всех троих пир loopback.
/// Ключ генерится ОДИН раз на процесс и наружу не уходит, поэтому подделать метку из
/// браузера или из локальной сети невозможно. Порт macOS-овского RelayMarker.
public static class RelayMarker
{
    public const string HeaderName = "X-Rimeo-Relay-Key";
    public static readonly string Key = Convert.ToHexString(
        System.Security.Cryptography.RandomNumberGenerator.GetBytes(16));
}

public sealed class CloudRelay
{
    public static readonly CloudRelay Shared = new();

    /// Что этот агент умеет — то же значение, что и на macOS (CloudRelay.swift:46).
    /// Облако сейчас его не читает, но контракт обязан совпадать: разъедется здесь —
    /// разъедется молча, и найдут это уже по жалобе.
    public const string Capabilities = "playlists_v1";

    private readonly object _lock = new();
    private bool _running;
    private string? _lastAdvertisedTunnel;
    private string? _lastAdvertisedLan;
    private bool    _lanLogged;

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
        // Consecutive non-definitive 403s (token_mismatch / unknown). A single 403
        // is no longer treated as proof of "signed in elsewhere" — it can be a
        // transient race (a quick re-login, server blip). Only a definitive
        // `evicted` reason, or N consecutive non-definitive 403s, signs us out.
        int consecutive403 = 0;
        // Ошибок транспорта подряд (таймаут, обрыв). См. NewPollClient: после
        // RecreateClientAfterErrors клиент пересоздаётся — то, что раньше делал только
        // ручной рестарт агента.
        int consecutiveErrors = 0;
        var http = NewPollClient();
        try
        {
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

                // Билд — телеметрия облака (и исторически гейт на именованный туннель).
                pollUrl += $"&build={Uri.EscapeDataString(AppConfig.Shared.BuildNumber)}";
                pollUrl += $"&caps={Uri.EscapeDataString(Capabilities)}";

                // ⚠️ LAN-PSK ПО HEARTBEAT — САМЫЙ ВАЖНЫЙ ИЗ ТРЁХ.
                //
                // Уже связанный агент повторно /api/agent/login НЕ дёргает, поэтому линковка
                // секрет не донесёт: канал только этот. Облако принимает его здесь
                // (app.py: `request.args.get('lan_secret')`) и отдаёт телефону того же
                // аккаунта, после чего телефон идёт к агенту НАПРЯМУЮ по локальной сети.
                //
                // Windows не слал его вообще. Следствие: у Windows-пользователей LAN-путь не
                // включался НИКОГДА — телефон стримил через Cloudflare, стоя в одной комнате
                // с ПК (на маке замеряли: 98 мс и 37 МБ/с по локалке против 1–7 с через
                // туннель). Паритет с macOS (CloudRelay.swift:120).
                pollUrl += $"&lan_secret={Uri.EscapeDataString(HttpServer.ApiRouter.EnsureLanSecret())}";

                // LAN-адрес по heartbeat: облако (relay_poll, v1.34.3+) обновляет по нему
                // подсказку lan_ip для телефона. У Windows нет mDNS, эта подсказка —
                // единственный путь телефона к агенту по локалке, а писалась она только
                // при логине и протухала после смены IP (DHCP, Parallels NAT→Bridged).
                var lan = LanHint(AppConfig.Shared.GetLocalIp(), AppConfig.Port, HttpServer.AgentHttpServer.LanEnabled);
                if (lan != null) pollUrl += $"&lan={Uri.EscapeDataString(lan)}";

                LogTunnelIfChanged(tunnel);
                LogLanIfChanged(lan);

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
                        var reason = AppReason403(body);
                        // 403 без JSON-ответа приложения (HTML-страница WAF, прокси, пустое тело) —
                        // это не отказ нашего облака, и считать его к разлогину нельзя: одно новое
                        // WAF-правило разлогинило бы весь парк агентов. Просто ждём и повторяем.
                        if (reason == null)
                        {
                            Log.Warn($"Cloud relay: 403 without app reason (WAF/proxy?) — not counted toward sign-out, retry in {backoffSec}s");
                            await Task.Delay(backoffSec * 1000);
                            backoffSec = Math.Min(backoffSec * 2, 30);
                            continue;
                        }

                        // `evicted` = the binding is gone → the account signed in on
                        // another computer (single active agent per account). Definitive:
                        // sign out.
                        if (reason == "evicted")
                        {
                            Log.Warn("Cloud relay: 403 evicted — signed in elsewhere. Clearing session.");
                            // Keep CloudUserId (email): the account is de-authed but we
                            // prefill the sign-in gate with the email so reconnecting is a
                            // one-tap password re-entry, not a blank cold gate. An explicit
                            // Sign out still clears the email (UnlinkAccount).
                            DataStore.Shared.Update(dd => { dd.CloudUrl = ""; dd.CloudToken = ""; });
                            AppState.Shared.RefreshFromData();
                            Stop();
                            return;
                        }
                        // `token_mismatch` / unknown: token superseded — usually a transient
                        // race (a quick re-login). Retry; only sign out if it persists, so
                        // a single racy 403 no longer kicks the user out.
                        consecutive403++;
                        if (consecutive403 >= 3)
                        {
                            Log.Warn($"Cloud relay: 403 ({reason}) persisted x{consecutive403} — clearing session.");
                            // Keep CloudUserId (email): the account is de-authed but we
                            // prefill the sign-in gate with the email so reconnecting is a
                            // one-tap password re-entry, not a blank cold gate. An explicit
                            // Sign out still clears the email (UnlinkAccount).
                            DataStore.Shared.Update(dd => { dd.CloudUrl = ""; dd.CloudToken = ""; });
                            AppState.Shared.RefreshFromData();
                            Stop();
                            return;
                        }
                        Log.Warn($"Cloud relay: 403 ({reason}) — retry {consecutive403}/3 in {backoffSec}s");
                        await Task.Delay(backoffSec * 1000);
                        backoffSec = Math.Min(backoffSec * 2, 30);
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
                    consecutive403 = 0;
                    consecutiveErrors = 0;

                    if (msg.TryGetValue("type", out var typeEl) && typeEl.GetString() == "ping")
                    {
                        // The cloud piggybacks whether a phone is signed in to this
                        // account on the idle heartbeat, for the Devices tab status.
                        if (msg.TryGetValue("phone", out var phoneEl) &&
                            (phoneEl.ValueKind == JsonValueKind.True || phoneEl.ValueKind == JsonValueKind.False))
                            AppState.Shared.PhoneConnected = phoneEl.GetBoolean();
                        continue;
                    }

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
                    consecutiveErrors++;
                    if (consecutiveErrors >= RecreateClientAfterErrors)
                    {
                        Log.Warn($"Cloud relay: {consecutiveErrors} errors in a row — recreating HTTP client");
                        http.Dispose();
                        http = NewPollClient();
                        consecutiveErrors = 0;
                    }
                    await Task.Delay(backoffSec * 1000);
                    backoffSec = Math.Min(backoffSec * 2, 30);
                }
            }
        }
        finally { http.Dispose(); }
    }

    private const int RecreateClientAfterErrors = 3;

    /// HTTP-клиент long-poll'а. Раньше был один `new HttpClient()` на всю жизнь агента
    /// с бессрочным пулом соединений: после сна/смены сети/тихого обрыва соединение в
    /// пуле оставалось мёртвым, каждый опрос упирался в 30-секундный таймаут («A task
    /// was canceled»), и так 17 часов подряд до ручного рестарта (агент 260, 23–24.07).
    /// Теперь соединения живут не дольше PooledConnectionLifetime (заодно заново
    /// резолвится DNS), а после серии ошибок клиент пересоздаётся целиком.
    /// macOS этим не страдает: URLSession.shared сам переподключается при смене сети.
    private static HttpClient NewPollClient() => new HttpClient(new SocketsHttpHandler
    {
        PooledConnectionLifetime    = TimeSpan.FromMinutes(2),
        PooledConnectionIdleTimeout = TimeSpan.FromSeconds(30),
        ConnectTimeout              = TimeSpan.FromSeconds(15),
    });

    public void NoteTunnelChanged(string tunnelUrl) =>
        Log.Info($"Cloud relay tunnel changed: {(string.IsNullOrEmpty(tunnelUrl) ? "(none)" : tunnelUrl)}");

    public async void PushTunnelUpdate(string tunnelUrl)
    {
        var d = DataStore.Shared.Data;
        if (string.IsNullOrEmpty(d.CloudUrl) || string.IsNullOrEmpty(d.CloudToken)) return;
        try
        {
            using var http = new HttpClient();
            // Тот же набор параметров, что и в основном heartbeat: build + caps. Иначе
            // внеочередной пуш при смене туннеля «омолаживал» бы запись агента в облаке
            // БЕЗ билда, и телеметрия платформы разъезжалась бы с реальностью.
            var url = $"{d.CloudUrl}/api/relay/poll/{AppConfig.Shared.AgentId}" +
                      $"?token={d.CloudToken}&tunnel={Uri.EscapeDataString(tunnelUrl)}" +
                      $"&build={Uri.EscapeDataString(AppConfig.Shared.BuildNumber)}" +
                      $"&caps={Uri.EscapeDataString(Capabilities)}";
            using var cts = new CancellationTokenSource(TimeSpan.FromSeconds(5));
            await http.GetAsync(url, cts.Token);
            Log.Info($"Tunnel URL pushed to cloud: {tunnelUrl}");
        }
        catch { }
    }

    /// `reason` из JSON-ответа облака на отказ опроса или null, если тело — не ответ нашего
    /// приложения (HTML от WAF/прокси, пустое, JSON без строкового `reason`). Облако на
    /// отказ опроса всегда отвечает {"error":"unauthorized","reason":"evicted"|"token_mismatch"}.
    /// Паритет: CloudRelay.appReason403 на macOS.
    public static string? AppReason403(string? body)
    {
        if (string.IsNullOrWhiteSpace(body)) return null;
        try
        {
            var obj = JsonSerializer.Deserialize<Dictionary<string, JsonElement>>(body);
            if (obj != null && obj.TryGetValue("reason", out var r) && r.ValueKind == JsonValueKind.String)
            {
                var s = r.GetString();
                return string.IsNullOrEmpty(s) ? null : s;
            }
        }
        catch { /* не JSON — не ответ приложения */ }
        return null;
    }

    /// `ip:port` для параметра `lan` или null. Схему не добавляем: `http://` в query —
    /// классический триггер WAF-правил (RFI), а 403 от WAF агент считает отказом токена.
    /// Отсекаем только очевидно бесполезное (нет сети → loopback; сервер слушает только
    /// localhost); какие адреса принимать (RFC1918) — решает облако. Паритет:
    /// CloudRelay.lanHint на macOS.
    public static string? LanHint(string ip, int port, bool lanEnabled)
    {
        ip = (ip ?? "").Trim();
        if (!lanEnabled || ip.Length == 0 || ip.StartsWith("127.") || ip == "0.0.0.0" || port <= 0)
            return null;
        return $"{ip}:{port}";
    }

    private void LogLanIfChanged(string? lan)
    {
        lock (_lock)
        {
            if (_lanLogged && _lastAdvertisedLan == lan) return;
            _lastAdvertisedLan = lan;
            _lanLogged = true;
        }
        Log.Info($"Cloud relay advertising LAN address: {lan ?? "(none — no LAN route)"}");
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

    /// Replays a cloud-relayed request against the local HTTP server (127.0.0.1).
    /// THREAT MODEL (6006): the cloud signs its own JWT, so a relayed request clears
    /// AuthGate. This is now BOUNDED by 6002 (LibraryPathGuard): the file endpoints
    /// only serve files inside the library's own directories, so even a hostile
    /// relay cannot read arbitrary host files. See README "Threat model".
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

            // Метим запрос процессным секретом: для HTTP-сервера релей приходит с
            // 127.0.0.1 — ровно как локальный браузер и как cloudflared. Без метки все
            // три сливаются в один «local», и access-лог не может ответить на главный
            // диагностический вопрос: телефон пришёл по локалке или через облако.
            // Подделать метку из браузера нельзя — ключ рождается в этом процессе и
            // никуда не уезжает. Паритет с macOS (RelayMarker в CloudRelay.swift).
            req.Headers.TryAddWithoutValidation(RelayMarker.HeaderName, RelayMarker.Key);

            foreach (var (k, v) in headers)
            {
                if (k.ToLower() == "host") continue;
                // Метку из ОБЛАКА не пропускаем: иначе её мог бы прислать кто угодно
                // снаружи и выдать свой запрос за релейный. Ставим её только сами, выше.
                if (k.Equals(RelayMarker.HeaderName, StringComparison.OrdinalIgnoreCase)) continue;
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
