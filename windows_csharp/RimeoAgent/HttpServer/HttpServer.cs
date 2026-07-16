using System.Diagnostics;
using System.Net;
using System.Net.Sockets;
using RimeoAgent.Config;
using RimeoAgent.Services;   // RelayMarker — процессная метка запросов от CloudRelay

namespace RimeoAgent.HttpServer;

public sealed class AgentHttpServer
{
    private HttpListener? _listener;
    private bool          _running;
    private readonly ApiRouter _router = new();

    public void Start()
    {
        // M4: prefer binding ALL interfaces so the app is reachable directly on the
        // LAN. That needs a urlacl reservation (added by the installer); if it's
        // missing the bind throws, so we fall back to localhost-only — the tunnel/
        // relay (remote) path still works, just no direct LAN.
        _listener = new HttpListener();
        _listener.Prefixes.Add($"http://+:{AppConfig.Port}/");
        try
        {
            _listener.Start();
            _running = true;
            Log.Info($"HTTP server listening on all interfaces :{AppConfig.Port} (LAN enabled)");
            Task.Run(AcceptLoop);
            return;
        }
        catch (Exception ex)
        {
            Log.Warn($"Bind http://+:{AppConfig.Port}/ failed ({ex.Message}) — falling back to localhost (no LAN). " +
                     $"Installer should reserve: netsh http add urlacl url=http://+:{AppConfig.Port}/ sddl=D:(A;;GX;;;WD)");
            try { _listener.Close(); } catch { /* ignore */ }
        }

        _listener = new HttpListener();
        _listener.Prefixes.Add($"http://127.0.0.1:{AppConfig.Port}/");
        _listener.Prefixes.Add($"http://localhost:{AppConfig.Port}/");
        try { _listener.Start(); }
        catch (Exception ex)
        {
            Log.Error($"HTTP server failed to start: {ex.Message}");
            return;
        }
        _running = true;
        Log.Info($"HTTP server listening on localhost :{AppConfig.Port} (LAN disabled — no urlacl)");
        Task.Run(AcceptLoop);
    }

    public void Stop()
    {
        _running = false;
        _listener?.Stop();
        _listener?.Close();
    }

    private async Task AcceptLoop()
    {
        while (_running && _listener != null)
        {
            try
            {
                var ctx = await _listener.GetContextAsync();
                _ = Task.Run(() => HandleRequest(ctx));
            }
            catch when (!_running) { break; }
            catch (Exception ex) { Log.Warn($"HTTP accept error: {ex.Message}"); }
        }
    }

    private async Task HandleRequest(HttpListenerContext ctx)
    {
        var req  = ctx.Request;
        var resp = ctx.Response;

        // Засечка ДО всего остального: в access-лог должна попасть длительность
        // запроса целиком, включая парсинг и чтение тела, а не только время роутера.
        var startedAt = Stopwatch.GetTimestamp();

        // Разбор запроса вынесен ИЗ try: ни одна из этих строк бросить не может, зато
        // теперь method/path/headers видны в finally. Иначе запрос, упавший внутри
        // роутера, писался бы в лог как "path=?" — то есть ровно в тот момент, когда
        // путь нужнее всего.
        var method = req.HttpMethod;
        var rawUrl = req.RawUrl ?? "/";
        var qIdx   = rawUrl.IndexOf('?');
        var path   = qIdx >= 0 ? rawUrl[..qIdx] : rawUrl;
        var query  = qIdx >= 0 ? rawUrl[(qIdx + 1)..] : "";

        var headers = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        foreach (string? key in req.Headers.AllKeys)
        {
            if (key != null) headers[key] = req.Headers[key] ?? "";
        }

        // Префлайты в access-лог не пишем — чистый шум (паритет с macOS HTTPServer).
        var isPreflight = method == "OPTIONS";

        AgentRequest? agentReq = null;
        string?       failure  = null;

        try
        {
            // 6003: reflect an allow-listed Origin only, never "*". A wildcard let
            // ANY page the user opened fetch /api/data and /stream.
            foreach (var kv in CorsPolicy.Headers(req.Headers["Origin"]))
                resp.Headers[kv.Key] = kv.Value;

            if (isPreflight)
            {
                resp.StatusCode = 204;
                resp.Close();
                return;
            }

            var queryParams = ParseQuery(query);

            byte[] body = Array.Empty<byte>();
            if (req.HasEntityBody)
            {
                using var ms = new MemoryStream();
                await req.InputStream.CopyToAsync(ms);
                body = ms.ToArray();
            }

            agentReq = new AgentRequest(method, path, queryParams, headers, body);
            await _router.RouteAsync(agentReq, resp);
        }
        catch (Exception ex)
        {
            failure = ex.Message;
            Log.Error($"Request handling error: {ex.Message}");
            try
            {
                resp.StatusCode = 500;
                var bytes = System.Text.Encoding.UTF8.GetBytes("{\"error\":\"Internal Server Error\"}");
                resp.ContentType   = "application/json";
                resp.ContentLength64 = bytes.Length;
                await resp.OutputStream.WriteAsync(bytes);
            }
            catch { }
            finally { resp.Close(); }
        }
        finally
        {
            // Одна строка на запрос — ПОСЛЕ того как ответ отправлен (роутер закрывает
            // resp сам), поэтому статус и Content-Length уже финальные.
            if (!isPreflight)
                AccessLog.Write(resp, method, path, headers, PeerAddress(req),
                                agentReq?.Auth ?? "-", startedAt, failure);
        }
    }

    /// Адрес пира из ядра — единственный НЕПОДДЕЛЫВАЕМЫЙ сигнал о том, откуда пришёл
    /// запрос (заголовки клиент пишет какие захочет).
    ///
    /// ⚠️ Windows-нюанс, которого нет на macOS: тамошний сокет-сервер слушает AF_INET,
    /// поэтому в Swift IPv4 гарантирован. HttpListener на `http://+:port/` принимает и
    /// IPv6, и клиент из IPv4-локалки приезжает как `::ffff:192.168.1.5`. Без
    /// разворачивания в IPv4 такой адрес не попал бы ни в один приватный диапазон, и
    /// телефон, стоящий рядом по Wi-Fi, уехал бы в лог как transport=wan.
    private static IPAddress? PeerAddress(HttpListenerRequest req)
    {
        try
        {
            var ip = req.RemoteEndPoint?.Address;
            if (ip == null) return null;
            return ip.IsIPv4MappedToIPv6 ? ip.MapToIPv4() : ip;
        }
        catch { return null; }
    }

    private static Dictionary<string, string> ParseQuery(string query)
    {
        var result = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        if (string.IsNullOrEmpty(query)) return result;
        foreach (var part in query.Split('&'))
        {
            var eq  = part.IndexOf('=');
            var key = eq >= 0 ? Uri.UnescapeDataString(part[..eq]) : Uri.UnescapeDataString(part);
            var val = eq >= 0 ? Uri.UnescapeDataString(part[(eq + 1)..]) : "";
            result[key] = val;
        }
        return result;
    }
}

/// Канал, по которому пришёл запрос. Раньше на Windows не различался вообще — и это
/// делало вопрос «телефон ходил по локалке или через Cloudflare» неразрешимым по логам.
public static class Transport
{
    // ⚠️ Имена корзин — РОВНО как на macOS (Transport.rawValue в HTTPServer.swift).
    // Раньше здесь были свои "lan"/"tunnel"/"wan": строка [REQ] печаталась, но
    // `grep 'transport=TUNNEL'` по диагностическому бандлу с Windows не находил
    // НИЧЕГО, а `transport=EXTERNAL` не находил нигде. Общий разбор логов двух
    // платформ был невозможен — при том что бандл собирает и читает один и тот же
    // человек.
    public const string Lan      = "LAN";       // прямой коннект из приватной сети (быстрый путь)
    public const string Tunnel   = "TUNNEL";    // через Cloudflare (cloudflared → loopback)
    public const string Relay    = "RELAY";     // наш собственный CloudRelay (облачный путь)
    public const string Local    = "LOCAL";     // loopback без метки — локальный браузер
    public const string External = "EXTERNAL";  // прямой коннект с публичного IP — тревожный сигнал
    public const string Ui       = "UI";        // ядро не отдало адрес пира / внутрипроцессный вызов

    /// ⚠️ Порядок проверок принципиален, иначе лог начнёт ВРАТЬ.
    ///
    /// peer из accept() — единственный НЕПОДДЕЛЫВАЕМЫЙ сигнал (его ставит ядро).
    /// Поэтому он и решает, смотрим ли мы вообще на заголовки: по локальной сети любой
    /// клиент может прислать себе CF-Ray и притвориться туннелем.
    ///
    /// И только ВНУТРИ loopback — куда стучатся ТРИ разных источника (cloudflared,
    /// наш CloudRelay и локальный браузер) — заголовки решают, кто именно это был.
    ///
    /// ⚠️ X-Forwarded-For в детекторе туннеля НЕТ, и это не упущение. Его ставит кто
    /// угодно, а loopback — это в том числе локальный браузер и любой процесс на
    /// машине: с XFF в списке они могли бы нарисовать себе `transport=TUNNEL` и
    /// произвольный `ip=` в access-логе, то есть отравить именно те записи, по которым
    /// потом расследуют инцидент. Настоящий cloudflared ВСЕГДА шлёт CF-Connecting-IP
    /// и CF-Ray. Swift по той же причине смотрит только на них.
    public static string Classify(IPAddress? peer, IReadOnlyDictionary<string, string> headers)
    {
        if (peer == null) return Ui;

        if (!IPAddress.IsLoopback(peer))
        {
            // Пир не loopback ⇒ CF-заголовок (если он есть) — подделка: настоящий
            // cloudflared никогда не приходит с чужого адреса.
            return IsPrivate(peer) ? Lan : External;
        }

        // Процессный секрет — из браузера подделать невозможно (см. RelayMarker).
        var marker = Header(headers, RelayMarker.HeaderName);
        if (!string.IsNullOrEmpty(marker) && marker == RelayMarker.Key) return Relay;

        if (HasCloudflareHeader(headers)) return Tunnel;
        return Local;
    }

    public static bool HasCloudflareHeader(IReadOnlyDictionary<string, string> headers) =>
        !string.IsNullOrEmpty(Header(headers, "CF-Connecting-IP")) ||
        !string.IsNullOrEmpty(Header(headers, "CF-Ray"));

    /// Реальный клиент. CF-Connecting-IP доверяем ТОЛЬКО для TUNNEL — то есть после
    /// того, как Classify уже убедился, что пир loopback и заголовок поставил
    /// cloudflared, а не сосед по Wi-Fi.
    ///
    /// ⚠️ X-Forwarded-For как запасной источник УБРАН (в Swift его тоже нет). Иначе
    /// локальный процесс, приславший CF-Ray без CF-Connecting-IP, получал бы
    /// transport=TUNNEL и произвольный ip= в access-логе — то есть мог бы вписать в
    /// журнал агента чужой адрес.
    public static string ClientIp(string transport, IPAddress? peer,
                                 IReadOnlyDictionary<string, string> headers)
    {
        var peerStr = peer?.ToString() ?? "?";
        if (transport != Tunnel) return peerStr;

        var cf = Header(headers, "CF-Connecting-IP");
        return string.IsNullOrEmpty(cf) ? peerStr : cf;
    }

    /// RFC1918 + loopback + link-local. IPv6 обрабатываем ЯВНО: на Windows он не
    /// экзотика — система предпочитает IPv6, и по домашней сети запрос вполне приезжает
    /// с fe80::/10 (link-local) или fd00::/8 (ULA). На macOS этой ветки нет вовсе, там
    /// слушающий сокет AF_INET, и в лог всегда попадал IPv4.
    private static bool IsPrivate(IPAddress ip)
    {
        if (ip.AddressFamily == AddressFamily.InterNetwork)
        {
            var b = ip.GetAddressBytes();
            if (b[0] == 10) return true;                                // 10/8
            if (b[0] == 172 && b[1] >= 16 && b[1] <= 31) return true;   // 172.16/12
            if (b[0] == 192 && b[1] == 168) return true;                // 192.168/16
            if (b[0] == 127) return true;                               // 127/8
            if (b[0] == 169 && b[1] == 254) return true;                // 169.254/16 APIPA
            return false;
        }

        if (ip.AddressFamily == AddressFamily.InterNetworkV6)
        {
            if (IPAddress.IsLoopback(ip)) return true;   // ::1
            if (ip.IsIPv6LinkLocal)       return true;   // fe80::/10
            if (ip.IsIPv6SiteLocal)       return true;   // fec0::/10 (deprecated, но встречается)
            var b = ip.GetAddressBytes();
            if ((b[0] & 0xFE) == 0xFC)    return true;   // fc00::/7 unique-local
            return false;
        }

        return false;
    }

    private static string Header(IReadOnlyDictionary<string, string> headers, string name) =>
        headers.TryGetValue(name, out var v) ? v : "";
}

/// Access-лог: одна строка на запрос. До этого на Windows его не было ВООБЩЕ — при
/// жалобе «не грузится библиотека» в бандле «Report a problem» не было ни строчки о том,
/// дошёл ли запрос до агента, откуда он пришёл и чем кончился.
///
/// Формат намеренно совпадает с macOS ([REQ] key=value), чтобы саппорт грепал обе
/// платформы одним выражением.
public static class AccessLog
{
    /// HEAD — это health-check cloudflared (каждые ~2 с) и проба готовности туннеля.
    /// В Info они бы за сутки вытеснили из лога всё осмысленное.
    ///
    /// ⚠️ И их НЕДОСТАТОЧНО просто перевести в Log.Debug: на macOS у логгера есть
    /// отсечка по уровню (minLevel = .info), а Windows-овый AgentLogger пишет Debug в
    /// тот же 500-строчный ring, который уезжает в баг-репорт. То есть проба каждые 2 с
    /// вычистила бы весь буфер примерно за 17 минут — ровно тот debug-спам, от которого
    /// на macOS уже отгородились отсечкой. Поэтому отсечка сделана здесь, на входе:
    /// без флага строка пробы не создаётся вовсе.
    ///
    /// Включить (Windows-аналог `defaults write ... rimeo_verbose_logging`):
    ///   setx RIMEO_VERBOSE_LOGGING 1     + перезапуск агента.
    // Свой разбор флага здесь БЫЛ и расходился с логгеровским ("yes" включал генерацию
    // debug-строк, а логгер их выбрасывал по MinLevel). Один источник правды.
    private static bool Verbose => AgentLogger.VerboseEnabled;

    public static void Write(HttpListenerResponse resp, string method, string path,
                             IReadOnlyDictionary<string, string> headers, IPAddress? peer,
                             string auth, long startedAt, string? failure)
    {
        try
        {
            var status = SafeStatus(resp);
            var bytes  = SafeContentLength(resp);
            var ms     = (long)Stopwatch.GetElapsedTime(startedAt).TotalMilliseconds;

            var t = Transport.Classify(peer, headers);
            var f = new List<string>(12)
            {
                $"[REQ] transport={t}",
                $"ip={Transport.ClientIp(t, peer, headers)}",
            };

            if (t == Transport.Tunnel)
            {
                // Пир печатаем отдельным полем: для туннеля ip= — это адрес из заголовка,
                // и без via= непонятно, что физически коннект был локальный.
                var peerStr = peer?.ToString() ?? "?";
                f.Add($"via={peerStr}");
                var ray = Header(headers, "CF-Ray");
                if (ray.Length > 0) f.Add($"cf_ray={ray}");
            }

            var reqId = Header(headers, "X-Rimeo-Req-Id");
            if (reqId.Length > 0) f.Add($"req_id={reqId}");

            f.Add($"method={method}");
            // ⚠️ ТОЛЬКО путь, без query: в query едет ?lan_token=<PSK устройства>, а этот
            // лог автоматически уезжает в облако вместе с баг-репортом (/api/logs).
            f.Add($"path={path}");

            // Range — не секрет и живёт в заголовке: без него по логу не отличить
            // «отдали кусок и клиент ушёл» от «отдали весь файл».
            var range = Header(headers, "Range");
            if (range.Length > 0) f.Add($"range={range}");

            f.Add($"status={status}");
            f.Add($"bytes={bytes}");
            f.Add($"ms={ms}");
            f.Add($"auth={auth}");

            if (failure != null) f.Add($"err=\"{Truncate(failure, 80)}\"");

            var ua = Header(headers, "User-Agent");
            if (ua.Length > 0) f.Add($"ua=\"{Truncate(ua, 60)}\"");

            var line = string.Join(" ", f);

            // Проба, ответившая ошибкой, — уже не шум: её видно в Warn независимо от флага.
            if (method == "HEAD" && status < 400)
            {
                if (Verbose) Log.Debug(line);
                return;
            }
            if (status >= 400 || failure != null) Log.Warn(line);
            else                                  Log.Info(line);
        }
        catch (Exception ex)
        {
            // Лог не имеет права уронить запрос: ответ клиенту уже отправлен.
            Log.Warn($"AccessLog failed: {ex.Message}");
        }
    }

    /// resp уже закрыт роутером. Геттеры HttpListenerResponse — обычное чтение полей и
    /// после Close() не бросают, но ловим на всякий случай: строка лога не стоит того,
    /// чтобы из-за неё в AcceptLoop прилетело исключение.
    private static int SafeStatus(HttpListenerResponse resp)
    {
        try { return resp.StatusCode; } catch { return 0; }
    }

    /// Обещанный Content-Length. НЕ равен «реально долитому в сокет»: HttpListener
    /// владеет сокетом сам и счётчика записанных байт не отдаёт, поэтому macOS-ные
    /// `bytes=sent/declared` + `abort=client` (клиент оборвал закачку) на Windows
    /// невоспроизводимы. Обрыв посреди /stream виден косвенно — по строке
    /// "Stream write error" из ApiRouter рядом в логе.
    /// Content-Length может быть не выставлен (например 416) — тогда −1, печатаем 0.
    private static long SafeContentLength(HttpListenerResponse resp)
    {
        try { return Math.Max(0, resp.ContentLength64); } catch { return 0; }
    }

    private static string Header(IReadOnlyDictionary<string, string> headers, string name) =>
        headers.TryGetValue(name, out var v) ? v : "";

    private static string Truncate(string s, int max) =>
        s.Length <= max ? s : s[..max] + "…";
}

public record AgentRequest(
    string Method,
    string Path,
    Dictionary<string, string> QueryParams,
    Dictionary<string, string> Headers,
    byte[] Body
)
{
    /// Основание допуска: psk | jwt | public | deny:&lt;причина&gt;. Заполняется в
    /// ApiRouter.AuthGate, читается access-логом уже ПОСЛЕ возврата роутера — иначе
    /// решение «пустили/не пустили и почему» остаётся внутри AuthGate и в баг-репорт
    /// не попадает.
    ///
    /// Свойство с инициализатором, а не позиционный параметр: добавление в
    /// primary constructor сломало бы все существующие вызовы `new AgentRequest(...)`.
    /// "public" по умолчанию — путь, не требующий авторизации (AccessControl.RequiresAuth).
    public string Auth { get; set; } = "public";
}
