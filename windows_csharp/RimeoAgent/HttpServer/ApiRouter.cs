using System.Net;
using System.Text;
using System.Text.Json;
using RimeoAgent.Config;
using RimeoAgent.Models;
using RimeoAgent.Services;

namespace RimeoAgent.HttpServer;

public sealed class ApiRouter
{
    // A track counts as "hi-res" when its Rekordbox bitrate exceeds this (kbps).
    // Such tracks (≈24-bit PCM) overrun the sustained tunnel bandwidth and stall the
    // web/stream player, so /stream serves them a 16-bit WAV down-convert. Bitrate
    // 0/unknown → NOT hi-res. Parity with macOS APIRouter. raw=1 bypasses this.
    private const int HiResBitrateThreshold = 2000;

    // Protected endpoints (data + mutating/control) live in AccessControl
    // (SecurityGates.cs): AccessControl.DataProtectedPaths + ControlProtectedPaths.

    // PSK-or-JWT (mirrors macOS authGate). Policy lives in AccessControl.Decide.
    //  • A valid per-device LAN PSK authorises a local client (no JWT needed).
    //  • 6001 fix: when there is neither a PSK nor a named tunnel, DENY (was allow
    //    = fail-open). Without a named tunnel the server signs no JWT, so the PSK is
    //    the only trusted remote credential.
    // Returns true when the request was rejected (a 401 has been written to resp).
    private static async Task<bool> AuthGate(AgentRequest req, HttpListenerResponse resp)
    {
        var secret   = DataStore.Shared.Data.LanSecret;
        var provided = req.QueryParams.GetValueOrDefault("lan_token", "");
        if (string.IsNullOrEmpty(provided)) provided = BearerToken(req) ?? "";
        var aud      = TunnelManager.Shared.NamedHostname;
        var jwtToken = JwtValidator.ExtractToken(req);

        var decision = AccessControl.Decide(secret, provided, aud, jwtToken, SafeValidate);
        if (decision == AccessDecision.Allow)
        {
            // Основание допуска пишем в запрос — его подхватит одна строка [REQ] в
            // access-логе (auth=psk / auth=jwt). Отдельной INFO-строки здесь больше нет:
            // она дублировала бы [REQ] на КАЖДЫЙ запрос (а /stream их шлёт десятками).
            var byPsk = !string.IsNullOrEmpty(secret) && !string.IsNullOrEmpty(provided)
                        && AccessControl.ConstantTimeEquals(provided, secret);
            req.Auth = byPsk ? "psk" : "jwt";
            return false;
        }

        string reason;
        if (string.IsNullOrEmpty(aud))
            reason = string.IsNullOrEmpty(provided) ? "no_credentials" : "psk_invalid_no_tunnel";
        else
        {
            var f = SafeValidate(jwtToken, aud);
            reason = f.HasValue ? JwtValidator.FailureReason(f.Value) : "unauthorized";
        }
        // Причина отказа тоже уезжает в access-лог (auth=deny:<reason>): без неё в
        // баг-репорте видно «401», но не видно, чего именно не хватило.
        req.Auth = $"deny:{reason}";
        Log.Warn($"Auth rejected: path={req.Path}, reason={reason}, aud={aud}, token_present={jwtToken != null}, psk_present={!string.IsNullOrEmpty(provided)}");

        var bytes = Encoding.UTF8.GetBytes(
            JsonSerializer.Serialize(new { error = "unauthorized", reason }));
        resp.StatusCode      = 401;
        resp.ContentType     = "application/json";
        resp.Headers["WWW-Authenticate"] = $"Bearer realm=\"rimeo-agent\", error=\"{reason}\"";
        resp.ContentLength64 = bytes.Length;
        await resp.OutputStream.WriteAsync(bytes);
        resp.Close();
        return true;
    }

    // A validator that never throws: an unexpected crypto/parse bug maps to an
    // InvalidSignature failure (fail-CLOSED), not to "allow".
    private static JwtValidator.Failure? SafeValidate(string? token, string audience)
    {
        try { return JwtValidator.Validate(token, audience); }
        catch (Exception ex)
        {
            Log.Warn($"JWT validator exception: {ex.Message} — treating as invalid (fail-closed)");
            return JwtValidator.Failure.InvalidSignature;
        }
    }

    private static string? BearerToken(AgentRequest req)
    {
        if (req.Headers.TryGetValue("authorization", out var auth) &&
            auth.StartsWith("Bearer ", StringComparison.OrdinalIgnoreCase))
            return auth.Substring("Bearer ".Length);
        return null;
    }

    public async Task RouteAsync(AgentRequest req, HttpListenerResponse resp)
    {
        try
        {
            // HEAD probes (cloudflared health checks, the cloud relay, and tunnel
            // readiness checks all hit /api/status) must NOT run a body-writing
            // handler: HttpListener throws "Bytes to be written to the stream
            // exceed the Content-Length bytes size specified" the moment you write
            // a body to a HEAD response, which spammed agent.log every ~2s and
            // then cascaded into "operation cannot be performed after the response
            // has been submitted" from the 500 fallback. A probe only checks the
            // status code, so answer HEAD with headers-only 200.
            if (req.Method == "HEAD")
            {
                resp.StatusCode      = 200;
                resp.ContentType     = "application/json";
                resp.ContentLength64 = 0;
                resp.Close();
                return;
            }

            // Auth gate for data-exposing (6001) and mutating/control (6004)
            // endpoints. Returns true (and writes 401) when rejected. The WinUI UI
            // authenticates its own /127.0.0.1 control calls with the LAN PSK.
            if (AccessControl.RequiresAuth(req.Path) && await AuthGate(req, resp))
                return;

            switch ((req.Method, req.Path))
            {
                case ("GET",  "/stream"):                  await StreamAudio(req, resp); break;
                case ("GET",  "/waveform"):                await Waveform(req, resp); break;
                case ("GET",  "/artwork"):                 await Artwork(req, resp); break;
                case ("GET",  "/reveal"):                  await Reveal(req, resp); break;
                case ("GET",  "/api/data"):                await GetData(req, resp); break;
                case ("GET",  "/api/logs"):                await GetLogs(req, resp); break;
                case ("GET",  "/api/pairing_info"):        await PairingInfo(req, resp); break;
                case ("GET",  "/api/check_pairing"):       await CheckPairing(req, resp); break;
                case ("POST", "/api/save_note"):           await SaveNote(req, resp); break;
                case ("POST", "/api/save_exclusions"):     await SaveExclusions(req, resp); break;
                case ("POST", "/api/rename_history"):      await RenameHistory(req, resp); break;

                // Плейлисты (Фаза 0 — плейлисты из iOS). Overlay-only CRUD: ни один из этих
                // роутов не трогает master.db. Мутации закрыты авторизацией (SecurityGates);
                // read-only рекомендации — ПУБЛИЧНЫЕ, как /api/similar.
                case ("POST", "/api/playlist/create"):          await CreatePlaylist(req, resp); break;
                case ("POST", "/api/playlist/create_folder"):   await CreateFolder(req, resp); break;
                case ("POST", "/api/playlist/add"):             await PlaylistAdd(req, resp); break;
                case ("POST", "/api/playlist/remove"):          await PlaylistRemove(req, resp); break;
                case ("POST", "/api/playlist/reorder"):         await PlaylistReorder(req, resp); break;
                case ("POST", "/api/playlist/rename"):          await PlaylistRename(req, resp); break;
                case ("POST", "/api/playlist/delete"):          await PlaylistDelete(req, resp); break;
                case ("POST", "/api/playlist/recommendations"): await PlaylistRecommendations(req, resp); break;

                // Фаза 6 — запись оверлеев в master.db (RekordboxWriter + frozen-хелпер).
                // Единственные роуты, которые трогают ЧУЖУЮ базу Rekordbox.
                case ("POST", "/api/playlist/sync"):           await PlaylistSync(req, resp); break;
                case ("GET",  "/api/playlist/sync/status"):    await PlaylistSyncStatus(req, resp); break;

                case ("POST", "/api/send_tg"):             await SendTelegram(req, resp); break;
                case ("GET",  "/api/analysis"):            await GetAnalysis(req, resp); break;
                case ("GET",  "/api/analysis/status"):     await GetAnalysisStatus(req, resp); break;
                case ("POST", "/api/analysis/start"):      await StartAnalysis(req, resp); break;
                case ("POST", "/api/analysis/stop"):       await StopAnalysis(req, resp); break;
                case ("POST", "/api/analysis/recheck"):    await RecheckAnalysis(req, resp); break;
                case ("GET",  "/api/analysis/track_list"): await GetAnalyzedIds(req, resp); break;
                case ("GET",  "/api/similar"):             await GetSimilar(req, resp); break;
                case ("GET",  "/api/status"):              await GetStatus(req, resp); break;
                case ("GET",  "/api/account"):             await GetAccount(req, resp); break;
                case ("POST", "/api/link_account"):        await LinkAccount(req, resp); break;
                case ("POST", "/api/agent_login"):         await AgentAuth(req, resp, "/api/agent/login"); break;
                case ("POST", "/api/agent_signup"):        await AgentAuth(req, resp, "/api/agent/signup"); break;
                case ("POST", "/api/unlink_account"):      await UnlinkAccount(req, resp); break;
                case ("GET",  "/api/tunnel/status"):       await TunnelStatus(req, resp); break;
                case ("POST", "/api/tunnel/start"):        await TunnelStart(req, resp); break;
                case ("POST", "/api/tunnel/stop"):         await TunnelStop(req, resp); break;
                case ("POST", "/api/report_bug"):          await ReportBug(req, resp); break;
                case ("POST", "/api/agent/update"):        await StartAgentUpdate(req, resp); break;
                case ("GET",  "/api/agent/update/status"): await AgentUpdateStatus(req, resp); break;
                default:                                   await WriteJson(resp, 404, new { error = "Not found" }); break;
            }
        }
        catch (Exception ex)
        {
            Log.Error($"Router error {req.Path}: {ex.Message}");
            // The handler may have already started/submitted the response (e.g. a
            // partial stream write). Writing a 500 on top of that throws "operation
            // cannot be performed after the response has been submitted" — swallow
            // it so one failure doesn't produce a second cascaded error line.
            try { await WriteJson(resp, 500, new { error = ex.Message }); }
            catch (Exception inner) { Log.Warn($"Could not write 500 for {req.Path}: {inner.Message}"); }
        }
    }

    // ── /stream ─────────────────────────────────────────────────────────────

    // Returns the drive/volume root (e.g. "D:\" or "\\server\share\") for a path, or "" when
    // it can't be determined. Used to tell "drive disconnected" (410) apart from "file deleted" (404).
    private static string RemovableVolumeRoot(string path)
    {
        try
        {
            var root = Path.GetPathRoot(Path.GetFullPath(path));
            return root ?? "";
        }
        catch { return ""; }
    }

    private static async Task StreamAudio(AgentRequest req, HttpListenerResponse resp)
    {
        if (!req.QueryParams.TryGetValue("path", out var rawPath) || string.IsNullOrEmpty(rawPath))
        { await WriteJson(resp, 400, new { error = "path required" }); return; }

        var path    = rawPath;
        // 6002: only serve files that live inside the library's own directories.
        // Blocks ?path=C:\Users\<u>\.ssh\id_rsa, ..\ traversal and junction escapes.
        if (!LibraryPathGuard.IsAllowed(path))
        { await WriteJson(resp, 403, new { error = "Forbidden" }); return; }
        var trackId = req.QueryParams.GetValueOrDefault("id", "");
        var preload = req.QueryParams.GetValueOrDefault("preload", "") is "1" or "true";
        // raw=1 → byte-for-byte ORIGINAL (download / offline must stay lossless):
        // no 16-bit down-convert and no AIFF→WAV.
        var raw     = req.QueryParams.GetValueOrDefault("raw", "") is "1" or "true";
        var ext     = Path.GetExtension(path).TrimStart('.').ToLower();

        Log.Info($"Stream request: track={trackId}, preload={preload}, raw={raw}, path={path}");

        if (!File.Exists(path))
        {
            // Drive unmounted vs file genuinely missing — distinct codes so the web
            // client can show a specific message instead of blaming the tunnel.
            var volRoot = RemovableVolumeRoot(path);
            if (!string.IsNullOrEmpty(volRoot) && !Directory.Exists(volRoot))
            { await WriteJson(resp, 410, new { error = "Music drive is not connected" }); return; }
            await WriteJson(resp, 404, new { error = "File not found" }); return;
        }

        // File present but the OS denies reads (permissions) — 403, not 404.
        try { using var _probe = File.Open(path, FileMode.Open, FileAccess.Read, FileShare.Read); }
        catch (UnauthorizedAccessException)
        { await WriteJson(resp, 403, new { error = "File access denied" }); return; }
        catch (IOException) { /* sharing/transient lock — let the normal flow handle it */ }

        string finalPath = path;
        // Hi-res discriminator: Rekordbox bitrate > 2000 kbps. raw=1 forces the lossless
        // original, so skip the lookup/down-convert entirely in that case.
        var bitrate = raw ? 0 : (RekordboxParser.Shared.TrackById(trackId)?.Bitrate ?? 0);
        var isHiRes = !raw && bitrate > HiResBitrateThreshold;

        if (raw)
        {
            // Lossless original — no conversion. A preload probe has nothing to warm.
            if (preload) { await WriteJson(resp, 200, new { status = "preloading" }); return; }
        }
        else if (isHiRes)
        {
            // Hi-res → 16-bit/44.1kHz/stereo WAV for ALL clients. ffmpeg auto-detects the
            // container, so this covers both 24-bit WAV and 24-bit AIFF sources.
            if (preload)
            {
                _ = Task.Run(() => AudioService.Shared.Ensure16BitWav(path, trackId));
                await WriteJson(resp, 200, new { status = "preloading" }); return;
            }
            finalPath = await AudioService.Shared.Ensure16BitWav(path, trackId);
        }
        else if (ext is "aif" or "aiff")
        {
            if (preload)
            {
                _ = Task.Run(() => AudioService.Shared.EnsureWav(path, trackId));
                await WriteJson(resp, 200, new { status = "preloading" }); return;
            }
            finalPath = await AudioService.Shared.EnsureWav(path, trackId);
        }
        else if (preload)
        { await WriteJson(resp, 200, new { status = "preloading" }); return; }

        var mime = MimeType(finalPath);
        var info = new FileInfo(finalPath);
        if (!info.Exists || info.Length == 0)
        { await WriteJson(resp, 404, new { error = "File empty" }); return; }

        long size  = info.Length;
        long start = 0, end = size - 1;

        // A media element that wants the whole resource sends NO Range header.
        // Answering that with a 206 + whole-file Content-Range is illegal and makes
        // Chrome drain the ENTIRE body before playback starts — the "first play of a
        // freshly-converted hi-res/AIFF track downloads the whole file" bug. Serve a
        // no-Range request as 200 + Accept-Ranges (the file on disk is already a
        // complete, seekable WAV), so the browser then range-fetches and streams
        // progressively. Real Range requests (iOS AVPlayer, Cast, download) still 206.
        // Mirrors the macOS APIRouter.streamAudio fix shipped in build 233.
        bool hasRange = req.Headers.TryGetValue("Range", out var rangeHeader) && !string.IsNullOrEmpty(rangeHeader);
        if (hasRange)
        {
            var cleaned = rangeHeader.Replace("bytes=", "");
            var parts   = cleaned.Split('-');
            if (parts.Length == 2)
            {
                start = long.TryParse(parts[0], out var s) ? s : 0;
                end   = !string.IsNullOrEmpty(parts[1]) && long.TryParse(parts[1], out var e) ? e : size - 1;
            }
        }

        if (start > end || start >= size) { resp.StatusCode = 416; resp.Headers.Add("Content-Range", $"bytes */{size}"); resp.Close(); return; }
        end = Math.Min(end, size - 1);
        long length = end - start + 1;

        resp.StatusCode  = hasRange ? 206 : 200;
        resp.ContentType = mime;
        resp.Headers.Add("Accept-Ranges",  "bytes");
        if (hasRange) resp.Headers.Add("Content-Range",  $"bytes {start}-{end}/{size}");
        resp.ContentLength64 = length;

        try
        {
            using var fs = new FileStream(finalPath, FileMode.Open, FileAccess.Read, FileShare.Read);
            fs.Seek(start, SeekOrigin.Begin);
            var buf = new byte[256 * 1024];
            long remaining = length;
            while (remaining > 0)
            {
                int toRead = (int)Math.Min(buf.Length, remaining);
                int read   = await fs.ReadAsync(buf, 0, toRead);
                if (read == 0) break;
                await resp.OutputStream.WriteAsync(buf, 0, read);
                remaining -= read;
            }
        }
        catch (Exception ex) { Log.Warn($"Stream write error: {ex.Message}"); }
        finally { resp.Close(); }
    }

    // ── /waveform ────────────────────────────────────────────────────────────

    private static async Task Waveform(AgentRequest req, HttpListenerResponse resp)
    {
        if (!req.QueryParams.TryGetValue("path", out var path) || !req.QueryParams.TryGetValue("id", out var id))
        { await WriteJson(resp, 400, new { error = "path and id required" }); return; }
        if (!LibraryPathGuard.IsAllowed(path))   // 6002
        { await WriteJson(resp, 403, new { error = "Forbidden" }); return; }

        var preload = req.QueryParams.GetValueOrDefault("preload", "") is "1" or "true";
        if (preload)
        {
            _ = Task.Run(() => AudioService.Shared.Waveform(path, id));
            await WriteJson(resp, 200, new { status = "preloading" }); return;
        }
        var result = AudioService.Shared.Waveform(path, id);
        await WriteJson(resp, 200, result);
    }

    // ── /artwork ─────────────────────────────────────────────────────────────

    private static async Task Artwork(AgentRequest req, HttpListenerResponse resp)
    {
        if (!req.QueryParams.TryGetValue("path", out var path) || !req.QueryParams.TryGetValue("id", out var id))
        { await WriteJson(resp, 400, new { error = "path and id required" }); return; }
        if (!LibraryPathGuard.IsAllowed(path))   // 6002
        { await WriteJson(resp, 403, new { error = "Forbidden" }); return; }

        var preload = req.QueryParams.GetValueOrDefault("preload", "") is "1" or "true";
        if (preload)
        {
            _ = Task.Run(() => AudioService.Shared.Artwork(path, id));
            await WriteJson(resp, 200, new { status = "preloading" }); return;
        }

        var artPath = AudioService.Shared.Artwork(path, id);
        if (artPath == null) { resp.StatusCode = 204; resp.Close(); return; }

        var data = await File.ReadAllBytesAsync(artPath);
        resp.StatusCode    = 200;
        resp.ContentType   = "image/jpeg";
        resp.ContentLength64 = data.Length;
        await resp.OutputStream.WriteAsync(data);
        resp.Close();
    }

    // ── /reveal ──────────────────────────────────────────────────────────────

    private static async Task Reveal(AgentRequest req, HttpListenerResponse resp)
    {
        if (!req.QueryParams.TryGetValue("path", out var path) || !File.Exists(path))
        { await WriteJson(resp, 404, new { error = "File not found" }); return; }
        if (!LibraryPathGuard.IsAllowed(path))   // 6002 + 6004
        { await WriteJson(resp, 403, new { error = "Forbidden" }); return; }

        System.Diagnostics.Process.Start("explorer.exe", $"/select,\"{path}\"");
        await WriteJson(resp, 200, new { status = "ok" });
    }

    // ── /api/data ─────────────────────────────────────────────────────────────

    private static async Task GetData(AgentRequest req, HttpListenerResponse resp)
    {
        var lib  = RekordboxParser.Shared.Parse();
        var data = DataStore.Shared.Data;

        // ⚠️ Parse() отдаёт ЖИВОЙ закэшированный объект, а Track/Playlist здесь — классы
        // (на macOS это struct'ы, и `var tracks = lib.tracks` копировал их бесплатно).
        // Поэтому НИ ОДНО поле модели тут не трогаем: подмешивание оверлеев считается
        // «сбоку» — в отдельных структурах, а членство собирается уже при сериализации.
        // Иначе первая же правка плейлиста навсегда испортила бы кэш парсера.
        var playlists = new List<Playlist>(lib.Playlists);

        // path → оверлей, ВЛАДЕЮЩИЙ составом (чисто-Rimeo или dirty-правка RB-плейлиста):
        // его значения перекрывают разобранные.
        var overlayByPath  = new Dictionary<string, PlaylistOverlay>(StringComparer.Ordinal);
        // Синканные оверлеи (Dirty == false): состав живёт в master.db, подмешивать его
        // нельзя — но базовый плейлист обязан нести их rimeo_id (иначе iOS-оверлей,
        // который ключуется по rimeo_id, не найдёт настоящий плейлист и нарисует рядом
        // фантомного близнеца, риск 7).
        var identityByPath = new Dictionary<string, PlaylistOverlay>(StringComparer.Ordinal);

        // Пути, чьё членство перекрыто оверлеем: снимаются с ВСЕХ треков.
        var strippedPaths = new HashSet<string>(StringComparer.Ordinal);
        // trackId → [(path, позиция)] — членство, добавляемое оверлеями.
        var injected = new Dictionary<string, List<KeyValuePair<string, int>>>(StringComparer.Ordinal);

        if (data.Playlists.Count > 0)
        {
            var trackIds = new HashSet<string>(lib.Tracks.Select(t => t.Id), StringComparer.Ordinal);

            // Дедуп базовых плейлистов по rekordbox_id (цель перекрытия).
            var indexByRbId = new Dictionary<string, int>(StringComparer.Ordinal);
            for (var i = 0; i < playlists.Count; i++)
            {
                var rb = playlists[i].RekordboxId;
                if (!string.IsNullOrEmpty(rb)) indexByRbId[rb!] = i;
            }

            void Inject(string path, List<string> ids)
            {
                for (var pos = 0; pos < ids.Count; pos++)
                {
                    var tid = ids[pos];
                    if (!trackIds.Contains(tid)) continue;
                    if (!injected.TryGetValue(tid, out var list))
                    {
                        list = new List<KeyValuePair<string, int>>(1);
                        injected[tid] = list;
                    }
                    list.Add(new KeyValuePair<string, int>(path, pos + 1));   // позиции с 1, как в парсере
                }
            }

            var now = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds() / 1000.0;
            var removedRbIds = new HashSet<string>(StringComparer.Ordinal);

            foreach (var ov in data.Playlists)
            {
                if (ov.Deleted)
                {
                    // Tombstone: снять членство и выкинуть правленый RB-плейлист из разбора;
                    // чисто-Rimeo просто никогда не отдаётся.
                    if (!string.IsNullOrEmpty(ov.RekordboxId) && indexByRbId.TryGetValue(ov.RekordboxId!, out var di))
                    {
                        var dpath = playlists[di].Path;
                        if (!string.IsNullOrEmpty(dpath)) strippedPaths.Add(dpath);
                        removedRbIds.Add(ov.RekordboxId!);
                    }
                    continue;
                }

                if (!string.IsNullOrEmpty(ov.RekordboxId))
                {
                    // Правленый Rekordbox-плейлист: перекрываем ПО ID, и только когда dirty.
                    if (!indexByRbId.TryGetValue(ov.RekordboxId!, out var idx)) continue;   // неизвестный id → пропускаем
                    var path = playlists[idx].Path;
                    if (string.IsNullOrEmpty(path)) continue;
                    if (!ov.Dirty)
                    {
                        identityByPath[path] = ov;    // состав — за master.db, штампуем только личность
                        continue;
                    }
                    strippedPaths.Add(path);          // оверлей авторитетнее разбора
                    Inject(path, ov.TrackIds);
                    overlayByPath[path] = ov;
                }
                else
                {
                    // Чисто-Rimeo плейлист: синтетический путь в своём пространстве имён —
                    // с реальным путём Rekordbox он не столкнётся никогда (finding-21).
                    if (string.IsNullOrEmpty(ov.RimeoId)) continue;
                    var path = $"rmo:{ov.RimeoId}";
                    Inject(path, ov.TrackIds);
                    overlayByPath[path] = ov;
                    playlists.Add(new Playlist
                    {
                        Path        = path,
                        Date        = now,
                        Smart       = false,
                        Updated     = now,
                        History     = null,
                        HistoryId   = null,
                        Name        = string.IsNullOrEmpty(ov.Name) ? null : ov.Name,
                        RekordboxId = null,
                        Parent      = ov.Parent,
                        IsFolder    = ov.IsFolder,
                        IsSmart     = false,
                    });
                }
            }

            if (removedRbIds.Count > 0)
                playlists.RemoveAll(p => !string.IsNullOrEmpty(p.RekordboxId) && removedRbIds.Contains(p.RekordboxId!));
        }

        // Тот же предикат, что и у писателя (DataStore.PendingSyncOverlays) — один источник
        // правды, иначе кнопка Sync либо предлагает пустой прогон, либо прячет нужный.
        var pendingSync = DataStore.Shared.PendingSyncOverlays().Count;

        Log.Info($"GET /api/data -> {lib.Tracks.Count} tracks, {playlists.Count} playlists " +
                 $"({overlayByPath.Count} overlay), pending_sync={pendingSync}, source={lib.Source ?? "unknown"}");

        var obj = new Dictionary<string, object?>
        {
            ["tracks"]            = lib.Tracks.Select(t => EncodableTrack(t, strippedPaths, injected)).ToList(),
            ["playlists"]         = playlists.Select(p => EncodablePlaylist(
                                        p,
                                        overlayByPath.GetValueOrDefault(p.Path),
                                        identityByPath.GetValueOrDefault(p.Path))).ToList(),
            ["notes"]             = data.Notes,
            ["global_exclusions"] = data.GlobalExclusions,
            ["library_date"]      = lib.XmlDate,
            ["xml_date"]          = lib.XmlDate,
            // Фаза 6. На этих двух ключах клиенты гейтят своё UI редактирования и Sync.
            ["capabilities"]      = AgentCapabilities(),
            ["pending_sync"]      = pendingSync,
        };
        await WriteJson(resp, 200, obj);
    }

    /// Анонс возможностей агента (/api/data → "capabilities"). iOS декодит его в
    /// `AgentCapabilities` и гейтит на нём редактирование плейлистов и кнопку Sync. БЕЗ
    /// этого блока iOS выводит поддержку из формы payload'а и жёстко ставит
    /// syncSupported = false, а редактирование плейлистов не показывает вовсе.
    ///
    /// `playlist_sync` — НАСТОЯЩАЯ способность, а не health-check: «этот билд умеет POST
    /// /api/playlist/sync И настроен на master.db, в которую способен писать». В
    /// XML-режиме Rekordbox-ID не существует вовсе, синк не заработает никогда — кнопки
    /// быть не должно. Транзиентные сбои (открытый Rekordbox, занятая база) тут НАМЕРЕННО
    /// остаются true: они возвращаются из самого вызова синка внятной ошибкой («Закройте
    /// Rekordbox и повторите»), что лучше кнопки, которая молча исчезает.
    private static Dictionary<string, object?> AgentCapabilities()
    {
        var cfg = AppConfig.Shared;

        // DbExists = путь непустой И файл на месте. Без DbSourceEnabled база может быть
        // прописана, но не использоваться — писать в неё тогда нельзя.
        var canWriteDB = cfg.DbSourceEnabled && cfg.DbExists;
        // Наличия базы МАЛО: запись делает frozen-бинарь rbdb_sync_helper, и если он не
        // забандлен (или сборка его потеряла / положила не ту арку), Sync упадёт с 500
        // helper_unavailable. Без этой проверки юзер видел бы активную кнопку, жал — и
        // получал ошибку. Capability обязана отражать РЕАЛЬНУЮ способность, а не намерение.
        //
        // ⚠️ try/catch обязателен. Проба читает файл и разбирает PE-заголовок, то есть
        // может бросить (антивирус держит хэндл, диск отвалился, файл битый). А зовётся
        // она из /api/data — САМОЙ ГОРЯЧЕЙ ручки, которой телефон грузит всю библиотеку.
        // Без перехвата сбой ПРОБЫ ХЕЛПЕРА ронял бы /api/data в 500 — то есть у человека
        // пропадала бы вся библиотека из-за недоступной кнопки Sync. Не смогли проверить —
        // честно говорим «синк недоступен» и отдаём библиотеку.
        bool hasHelper;
        try { hasHelper = RekordboxWriter.BundledSyncHelperPath() != null; }
        catch (Exception ex)
        {
            Log.Warn($"capabilities: sync helper probe failed — {ex.Message}; playlist_sync=false");
            hasHelper = false;
        }

        // Кэш «последнего билда» освежаем в ФОНЕ: /api/data — горячая ручка, ждать GitHub
        // она не имеет права. Поэтому latest_build здесь всегда из кэша.
        RefreshLatestBuildInBackgroundIfStale();
        var current = UpdateChecker.ParseBuild(cfg.BuildNumber);
        var latest  = Volatile.Read(ref _latestKnownBuild);

        return new Dictionary<string, object?>
        {
            ["playlists"]       = true,
            ["playlist_sync"]   = canWriteDB && hasHelper,
            ["recommendations"] = true,
            ["platform"]        = "windows",
            // iOS парсит это в Int (номер сборки) — строка, как и на macOS.
            ["agent_version"]   = cfg.BuildNumber,
            // Аддитивно: iOS сравнивает билды и предлагает обновление через
            // POST /api/agent/update.
            // ⚠️ latest_build == 0 значит «агент ещё НЕ спрашивал GitHub», а НЕ
            // «обновлений нет» — поэтому update_available в этом случае false.
            ["current_build"]    = current,
            ["latest_build"]     = latest,
            ["update_available"] = latest > current,
            ["self_update"]      = true,
        };
    }

    // Кэш последнего известного билда с GitHub. 0 = ещё не спрашивали.
    private static int      _latestKnownBuild;
    private static DateTime _latestCheckedAt = DateTime.MinValue;
    private static int      _latestRefreshing;                        // 0/1, страж через Interlocked
    private static readonly TimeSpan LatestBuildTtl = TimeSpan.FromMinutes(15);

    /// Освежает кэш последнего билда не чаще раза в 15 минут и только в фоне — /api/data
    /// отвечает СРАЗУ, из кэша. Страж `_latestRefreshing` не даёт нескольким параллельным
    /// запросам поднять пачку одинаковых обращений к GitHub.
    private static void RefreshLatestBuildInBackgroundIfStale()
    {
        if (DateTime.UtcNow - _latestCheckedAt < LatestBuildTtl) return;
        // Во время установки в GitHub не ходим: UpdateChecker там уже занят своим
        // ForceCheck/скачиванием, и параллельный опрос только перетёр бы ему
        // LastCheckError (по нему POST /api/agent/update отличает сетевой сбой от
        // «у вас последняя версия»).
        if (AgentUpdateService.Shared.Status().Stage
            is AgentUpdateService.StageDownloading or "verifying" or "installing"
            or AgentUpdateService.StageRestarting) return;
        if (Interlocked.Exchange(ref _latestRefreshing, 1) == 1) return;
        _latestCheckedAt = DateTime.UtcNow;   // отметка ДО запроса: при недоступном GitHub не долбимся каждые /api/data

        _ = Task.Run(() =>
        {
            try
            {
                var info = UpdateChecker.Shared.ForceCheck();
                if (info != null)
                    Volatile.Write(ref _latestKnownBuild, UpdateChecker.ParseBuild(info.Version));
                else if (UpdateChecker.Shared.LastCheckError == null)
                    // Проверка прошла и более нового билда нет ⇒ последний = текущий.
                    // (Сетевая ошибка сюда не попадает: там кэш остаётся прежним, чтобы
                    // не соврать «обновлений нет».)
                    Volatile.Write(ref _latestKnownBuild, UpdateChecker.ParseBuild(AppConfig.Shared.BuildNumber));
            }
            catch (Exception ex) { Log.Warn($"latest_build refresh failed: {ex.Message}"); }
            finally { Interlocked.Exchange(ref _latestRefreshing, 0); }
        });
    }

    /// "synced" ⟺ то, что лежит в master.db, совпадает с оверлеем ПРЯМО СЕЙЧАС. Сравнение
    /// НАМЕРЕННО то же, что в DataStore.PendingSyncOverlays (signature vs last_synced_hash),
    /// иначе бейдж на плейлисте и счётчик pending_sync могли бы противоречить друг другу.
    private static string SyncState(PlaylistOverlay ov) =>
        ov.LastSyncedHash == ov.SyncSignature ? "synced" : "pending";

    /// ⚠️ Словарь собирается ВРУЧНУЮ (как encodableTrack на macOS), а не сериализацией
    /// модели: набор ключей — часть контракта с iOS, и «новое поле модели уехало в API само»
    /// — это не фича, а разъезд контракта. `image_path` не отдаётся вовсе (обложка — через
    /// /artwork), `duration` — только когда есть.
    private static Dictionary<string, object?> EncodableTrack(
        Track t,
        HashSet<string> strippedPaths,
        Dictionary<string, List<KeyValuePair<string, int>>> injected)
    {
        // Членство: базовое минус перекрытые оверлеем пути плюс то, что оверлей добавил.
        List<string> plists;
        Dictionary<string, int> pindices;
        var extra = injected.GetValueOrDefault(t.Id);

        if (strippedPaths.Count == 0 && extra == null)
        {
            plists   = t.Playlists;
            pindices = t.PlaylistIndices;
        }
        else
        {
            plists   = t.Playlists.Where(p => !strippedPaths.Contains(p)).ToList();
            pindices = t.PlaylistIndices.Where(kv => !strippedPaths.Contains(kv.Key))
                                        .ToDictionary(kv => kv.Key, kv => kv.Value, StringComparer.Ordinal);
            if (extra != null)
            {
                foreach (var kv in extra)
                {
                    pindices[kv.Key] = kv.Value;
                    if (!plists.Contains(kv.Key)) plists.Add(kv.Key);
                }
            }
        }

        var dict = new Dictionary<string, object?>
        {
            ["id"] = t.Id, ["artist"] = t.Artist, ["title"] = t.Title,
            ["genre"] = t.Genre, ["label"] = t.Label, ["rel_date"] = t.RelDate,
            ["key"] = t.Key, ["bpm"] = t.Bpm, ["bitrate"] = t.Bitrate,
            ["play_count"] = t.PlayCount, ["location"] = t.Location,
            ["timestamp"] = t.Timestamp, ["date_str"] = t.DateStr,
            ["playlists"] = plists, ["playlist_indices"] = pindices,
            ["histories"] = t.Histories, ["history_indices"] = t.HistoryIndices,
        };
        if (t.Duration.HasValue) dict["duration"] = t.Duration.Value;
        return dict;
    }

    /// `overlay` — оверлей, ВЛАДЕЮЩИЙ составом (чисто-Rimeo или dirty-правка RB-плейлиста):
    /// его значения бьют разобранные. `identity` — уже синканный оверлей (Фаза 6): состав
    /// авторитетен в master.db, поэтому штампуем ТОЛЬКО личность и состояние, а `track_ids`
    /// намеренно НЕ отдаём (они могли устареть, если после синка плейлист правили в самом
    /// Rekordbox). Взаимоисключающие.
    private static Dictionary<string, object?> EncodablePlaylist(
        Playlist p, PlaylistOverlay? overlay = null, PlaylistOverlay? identity = null)
    {
        var dict = new Dictionary<string, object?>
        {
            ["path"]  = p.Path,
            ["date"]  = p.Date,
            ["smart"] = p.Smart ?? false,
            // «Recently changed» на клиенте: реальный updated_at, иначе fallback на date.
            ["updated"]   = p.Updated ?? p.Date,
            ["is_folder"] = p.IsFolder ?? false,
            ["is_smart"]  = p.IsSmart ?? (p.Smart ?? false),
        };
        if (!string.IsNullOrEmpty(p.RekordboxId)) dict["rekordbox_id"] = p.RekordboxId;
        if (!string.IsNullOrEmpty(p.Parent))      dict["parent"]       = p.Parent;
        if (!string.IsNullOrEmpty(p.Name))        dict["name"]         = p.Name;
        // ⚠️ Словарь ручной — новое поле модели сюда само не попадёт. Именно так на macOS
        // молча терялся `seq` (порядок Rekordbox), хотя парсер и модель его уже отдавали.
        if (p.Seq.HasValue) dict["seq"] = p.Seq.Value;
        if (p.History == true)
        {
            dict["history"]    = true;
            dict["history_id"] = p.HistoryId ?? "";
            dict["name"]       = p.Name ?? "";
        }
        if (overlay is { } ov)
        {
            dict["rimeo_id"]     = ov.RimeoId;
            dict["track_ids"]    = ov.TrackIds;
            dict["state"]        = ov.State;
            dict["content_hash"] = ov.ContentHash ?? PlaylistHash.ContentHash(ov.TrackIds);
            dict["is_folder"]    = ov.IsFolder;
            // Фаза 6: "pending" = ещё не записано в master.db. Это бейдж «not synced»;
            // `state` выше — жизненный цикл оверлея Фазы 0, другое измерение.
            dict["sync_state"]   = SyncState(ov);
            if (!string.IsNullOrEmpty(ov.RekordboxId)) dict["rekordbox_id"] = ov.RekordboxId;
            if (!string.IsNullOrEmpty(ov.Parent))      dict["parent"]       = ov.Parent;
            if (!string.IsNullOrEmpty(ov.Name))        dict["name"]         = ov.Name;
        }
        else if (identity is { } id)
        {
            // Синкан: правда — в разобранном плейлисте. Штампуем только «кто он», чтобы
            // iOS-оверлей смэтчился по rimeo_id и не нарисовал рядом фантомный дубль.
            dict["rimeo_id"]   = id.RimeoId;
            dict["sync_state"] = SyncState(id);
        }
        return dict;
    }

    // ── /api/pairing_info ────────────────────────────────────────────────────

    /// Персистентный PSK агента для LAN-авторизации. Выпускается один раз и живёт в
    /// rimo_data.json. Порт macOS-ового `ensureLANSecret()`.
    ///
    /// ⚠️ ГРАБЛИ (на macOS их уже наступали, на Windows они всё ещё лежали): секрет
    /// рождался ТОЛЬКО внутри PairingInfo, то есть при показе QR-кода. У всех, кто
    /// связал агент и телефон по email/паролю, а не сканом QR, `lan_secret` оставался
    /// пустым — и весь LAN-путь был мёртв: AccessControl.Decide пропускает PSK-ветку
    /// при пустом секрете, остаётся только JWT, которого в локальной сети никто не
    /// подставляет → 401. Телефон молча уходил в облако и тянул музыку через
    /// Cloudflare, стоя в одной комнате с ПК. Поэтому PSK выпускается и при логине.
    internal static string EnsureLanSecret()
    {
        var existing = DataStore.Shared.Data.LanSecret;
        if (!string.IsNullOrEmpty(existing)) return existing;

        var raw = new byte[32];
        System.Security.Cryptography.RandomNumberGenerator.Fill(raw);
        var psk = Convert.ToBase64String(raw).Replace("+", "-").Replace("/", "_").Replace("=", "");
        DataStore.Shared.Update(d => { if (string.IsNullOrEmpty(d.LanSecret)) d.LanSecret = psk; });
        return DataStore.Shared.Data.LanSecret;
    }

    private static async Task PairingInfo(AgentRequest req, HttpListenerResponse resp)
    {
        const string chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789";
        var rng  = new Random();
        var code = new string(Enumerable.Range(0, 5).Select(_ => chars[rng.Next(chars.Length)]).ToArray());

        var psk = EnsureLanSecret();
        DataStore.Shared.Update(d => d.PairingCode = code);

        var localIp  = AppConfig.Shared.GetLocalIp();
        var port     = AppConfig.Port;
        var localUrl = $"http://{localIp}:{port}";
        var d2       = DataStore.Shared.Data;
        var tunnel   = TunnelManager.Shared.ActiveUrl;
        var url      = string.IsNullOrEmpty(tunnel)
                        ? (string.IsNullOrEmpty(d2.TunnelUrl) ? localUrl : d2.TunnelUrl)
                        : tunnel;
        var hostname = Environment.MachineName;

        // v2 payload + optional dual-mode cloud fields → one scan = LAN (PSK) + remote (cloud).
        var qr = new Dictionary<string, object>
        {
            ["v"]        = 2,
            ["url"]      = url,
            ["code"]     = code,
            ["agent_id"] = AppConfig.Shared.AgentId,
            ["secret"]   = psk,
            ["hostname"] = hostname,
            ["lan_ip"]   = localIp,
            ["lan_port"] = port,
        };
        var cloud = await FetchCloudPairing();
        if (cloud != null)
        {
            qr["type"]         = "rimeo_cloud";
            qr["cloud_url"]    = cloud.Value.cloudUrl;
            qr["mobile_token"] = cloud.Value.mobileToken;
        }

        var qrData  = JsonSerializer.Serialize(qr);
        var encoded = Uri.EscapeDataString(qrData);
        var qrUrl   = $"https://api.qrserver.com/v1/create-qr-code/?size=300x300&data={encoded}";

        var respObj = new Dictionary<string, object>(qr) { ["qr_url"] = qrUrl, ["local_url"] = url };
        await WriteJson(resp, 200, respObj);
    }

    // Best-effort: ask rimeo.app for a one-time mobile pairing token so the QR can
    // also carry a cloud session (remote). null if not cloud-linked or it fails.
    private static async Task<(string cloudUrl, string mobileToken)?> FetchCloudPairing()
    {
        var d = DataStore.Shared.Data;
        if (string.IsNullOrEmpty(d.CloudUrl) || string.IsNullOrEmpty(d.CloudToken)) return null;
        try
        {
            var url = $"{d.CloudUrl}/api/agents/mobile_token" +
                      $"?agent_id={Uri.EscapeDataString(AppConfig.Shared.AgentId)}" +
                      $"&token={Uri.EscapeDataString(d.CloudToken)}";
            using var http = new HttpClient { Timeout = TimeSpan.FromSeconds(6) };
            var body = await http.GetStringAsync(url);
            var obj  = JsonSerializer.Deserialize<Dictionary<string, JsonElement>>(body);
            if (obj != null
                && obj.TryGetValue("mobile_token", out var mt) && mt.GetString() is string mts && mts.Length > 0
                && obj.TryGetValue("cloud_url",    out var cu) && cu.GetString() is string cus && cus.Length > 0)
                return (cus, mts);
        }
        catch (Exception ex) { Log.Warn($"FetchCloudPairing failed: {ex.Message}"); }
        return null;
    }

    // ── /api/check_pairing ───────────────────────────────────────────────────

    private static async Task CheckPairing(AgentRequest req, HttpListenerResponse resp)
    {
        var code   = req.QueryParams.GetValueOrDefault("code", "");
        var stored = DataStore.Shared.Data.PairingCode;
        if (string.IsNullOrEmpty(code)) { await WriteJson(resp, 400, new { error = "code required" }); return; }
        if (stored == code.ToUpper() || stored == code) await WriteJson(resp, 200, new { status = "ok" });
        else await WriteJson(resp, 403, new { error = "Invalid pairing code" });
    }

    // ── /api/save_note ───────────────────────────────────────────────────────

    private static async Task SaveNote(AgentRequest req, HttpListenerResponse resp)
    {
        var body = ParseJsonBody<Dictionary<string, string>>(req.Body);
        if (body == null || !body.TryGetValue("id", out var tid))
        { await WriteJson(resp, 400, new { error = "Bad request" }); return; }

        body.TryGetValue("note", out var note);
        note = (note ?? "").Trim();
        DataStore.Shared.Update(d =>
        {
            if (string.IsNullOrEmpty(note)) d.Notes.Remove(tid);
            else                            d.Notes[tid] = note;
        });
        await WriteJson(resp, 200, new { status = "ok" });
    }

    // ── /api/rename_history ──────────────────────────────────────────────────

    // Sets (or clears, when name is empty) the custom display name for a Rekordbox
    // play-history session. Stored in DataStore.HistoryNames, applied to /api/data.
    private static async Task RenameHistory(AgentRequest req, HttpListenerResponse resp)
    {
        var body = ParseJsonBody<Dictionary<string, string>>(req.Body);
        if (body == null || !body.TryGetValue("history_id", out var hid) || string.IsNullOrEmpty(hid))
        { await WriteJson(resp, 400, new { error = "history_id required" }); return; }

        body.TryGetValue("name", out var name);
        name = (name ?? "").Trim();
        DataStore.Shared.Update(d =>
        {
            if (string.IsNullOrEmpty(name)) d.HistoryNames.Remove(hid);
            else                            d.HistoryNames[hid] = name;
        });
        await WriteJson(resp, 200, new { status = "ok" });
    }

    // ── /api/save_exclusions ─────────────────────────────────────────────────

    private static async Task SaveExclusions(AgentRequest req, HttpListenerResponse resp)
    {
        var list = ParseJsonBody<List<string>>(req.Body);
        if (list == null) { await WriteJson(resp, 400, new { error = "Expected array of strings" }); return; }
        DataStore.Shared.Update(d => d.GlobalExclusions = list);
        await WriteJson(resp, 200, new { status = "ok" });
    }

    // ── Плейлисты: overlay-CRUD (Фаза 0) ─────────────────────────────────────
    //
    // Ни один роут ниже не пишет в master.db — только в собственный оверлей
    // (rimo_data.json), который подмешивается в /api/data на чтении. Порт macOS
    // APIRouter.swift; расхождение в кодах/полях здесь = баг, который видит юзер, потому
    // что iOS ходит к обеим платформам ОДНИМ клиентом.

    /// Тело запроса как JSON-объект. null — тело пустое/не объект/битое (→ 400).
    private static JsonElement? JsonBody(AgentRequest req)
    {
        try
        {
            if (req.Body.Length == 0) return null;
            using var doc = JsonDocument.Parse(req.Body);
            if (doc.RootElement.ValueKind != JsonValueKind.Object) return null;
            // Clone обязателен: сам JsonDocument владеет буфером и умрёт на выходе из using.
            return doc.RootElement.Clone();
        }
        catch { return null; }
    }

    private static JsonElement? Field(JsonElement body, string key) =>
        body.TryGetProperty(key, out var v) ? v : null;

    /// Скаляр в строку. Число приводится к своей текстовой форме: id треков в модели —
    /// строки, но клиент вправе прислать их числами (в macOS это NSNumber.stringValue).
    private static string? Scalar(JsonElement el) => el.ValueKind switch
    {
        JsonValueKind.String => el.GetString(),
        JsonValueKind.Number => el.GetRawText(),
        _                    => null,
    };

    /// Массив строк, но терпимый: одиночное значение → массив из одного, числа → строки.
    private static List<string> CoerceStringArray(JsonElement? value)
    {
        var result = new List<string>();
        if (value is not { } el) return result;
        if (el.ValueKind == JsonValueKind.Array)
        {
            foreach (var item in el.EnumerateArray())
                if (Scalar(item) is { } s) result.Add(s);
        }
        else if (Scalar(el) is { } single) result.Add(single);
        return result;
    }

    /// Дедуп С СОХРАНЕНИЕМ ПОРЯДКА (порядок здесь — часть данных: это порядок треков в
    /// плейлисте), пустые выбрасываются.
    private static List<string> DedupOrdered(IEnumerable<string> ids)
    {
        var seen = new HashSet<string>(StringComparer.Ordinal);
        var outList = new List<string>();
        foreach (var id in ids)
        {
            if (string.IsNullOrEmpty(id)) continue;
            if (seen.Add(id)) outList.Add(id);
        }
        return outList;
    }

    /// `track_id` (одиночный) + `track_ids` (массив), слитые и дедуплицированные по порядку.
    private static List<string> BodyTrackIds(JsonElement body)
    {
        var ids = CoerceStringArray(Field(body, "track_id"));
        ids.AddRange(CoerceStringArray(Field(body, "track_ids")));
        return DedupOrdered(ids);
    }

    /// Адресация СТРОГО по id (finding-5): rimeo_id (чисто-Rimeo / синтезированное
    /// перекрытие) либо rekordbox_id (настоящий плейлист). Пустые строки → null.
    /// По `path` не адресуем никогда: у одноимённых плейлистов он совпадает.
    private static (string? Rimeo, string? Rekordbox) Addressing(JsonElement body)
    {
        string? rimeo = Field(body, "rimeo_id") is { ValueKind: JsonValueKind.String } r
            ? r.GetString() : null;
        if (string.IsNullOrEmpty(rimeo)) rimeo = null;

        var rb = CoerceStringArray(Field(body, "rekordbox_id")).FirstOrDefault();
        if (string.IsNullOrEmpty(rb)) rb = null;

        return (rimeo, rb);
    }

    private static int GetInt(JsonElement body, string key, int fallback)
    {
        if (Field(body, key) is not { } el) return fallback;
        if (el.ValueKind == JsonValueKind.Number && el.TryGetDouble(out var d)) return (int)d;
        if (el.ValueKind == JsonValueKind.String && int.TryParse(el.GetString(), out var s)) return s;
        return fallback;
    }

    private static bool GetBool(JsonElement body, string key, bool fallback) =>
        Field(body, key) is { } el
            ? el.ValueKind switch
            {
                JsonValueKind.True  => true,
                JsonValueKind.False => false,
                _                   => fallback,
            }
            : fallback;

    private static string? GetString(JsonElement body, string key) =>
        Field(body, key) is { ValueKind: JsonValueKind.String } el ? el.GetString() : null;

    /// Упорядоченный РАЗОБРАННЫЙ состав плейлиста (по playlist_indices треков). Нужен как
    /// SEED при ПЕРВОЙ правке существующего Rekordbox-плейлиста: оверлей ЗАМЕЩАЕТ состав,
    /// поэтому старт с пустого списка обнулил бы плейлист целиком.
    private static List<string> ParsedMembership(string path, List<Track> tracks)
    {
        if (string.IsNullOrEmpty(path)) return new List<string>();
        return tracks
            .Where(t => t.PlaylistIndices.ContainsKey(path))
            .OrderBy(t => t.PlaylistIndices[path])
            .Select(t => t.Id)
            .ToList();
    }

    private static List<string> SeedMembership(string? rekordboxId, LibraryData lib)
    {
        if (string.IsNullOrEmpty(rekordboxId)) return new List<string>();
        var pl = lib.Playlists.FirstOrDefault(p => p.RekordboxId == rekordboxId);
        return pl == null ? new List<string>() : ParsedMembership(pl.Path, lib.Tracks);
    }

    /// Барьер 409 для add/remove/reorder по НАСТОЯЩЕМУ Rekordbox-плейлисту: папку, smart и
    /// историю треками не правят, а коллизию display-пути (одноимённые плейлисты) отвергаем,
    /// иначе составы слились бы в один (finding-19/5). null ⇒ можно.
    private static string? RekordboxPlaylistBarrier(string? rekordboxId, LibraryData lib)
    {
        if (string.IsNullOrEmpty(rekordboxId)) return null;
        var pl = lib.Playlists.FirstOrDefault(p => p.RekordboxId == rekordboxId);
        if (pl == null) return null;
        if (pl.IsFolder == true || pl.IsSmart == true || pl.Smart == true || pl.History == true)
            return "not_editable";
        if (!string.IsNullOrEmpty(pl.Path) && lib.Playlists.Count(p => p.Path == pl.Path) > 1)
            return "ambiguous_path";
        return null;
    }

    /// Папка-оверлей (чисто-Rimeo) тоже не может держать треки.
    private static string? OverlayFolderBarrier(string? rimeoId)
    {
        if (string.IsNullOrEmpty(rimeoId)) return null;
        var ov = DataStore.Shared.Data.Playlists.FirstOrDefault(o => o.RimeoId == rimeoId);
        return ov is { IsFolder: true } ? "not_editable" : null;
    }

    /// Find-or-create оверлея + применение `transform` к его составу. `seed` используется
    /// ТОЛЬКО при СОЗДАНИИ перекрытия существующего Rekordbox-плейлиста — чтобы сохранить
    /// базовый состав. Каждая мутация пересчитывает content_hash и ставит dirty/pending
    /// (finding-7). Вызывается ВНУТРИ DataStore.Update (d — уже приватная копия).
    private static (string Hash, string RimeoId, string State) UpsertOverlay(
        RimoData d, string? rimeoId, string? rekordboxId,
        Func<List<string>, IEnumerable<string>> transform,
        List<string>? seed = null, string? name = null, bool? isFolder = null,
        string? parent = null, bool deleted = false)
    {
        var idx = -1;
        if (!string.IsNullOrEmpty(rimeoId))
            idx = d.Playlists.FindIndex(o => o.RimeoId == rimeoId);
        if (idx < 0 && !string.IsNullOrEmpty(rekordboxId))
            idx = d.Playlists.FindIndex(o => o.RekordboxId == rekordboxId);

        PlaylistOverlay ov;
        if (idx >= 0)
        {
            ov = d.Playlists[idx];
            ov.TrackIds = DedupOrdered(transform(ov.TrackIds));
        }
        else
        {
            // id держим в том же виде, что и iOS/macOS: "rmo_" + 12 hex-символов.
            var newId = "rmo_" + Guid.NewGuid().ToString("N")[..12];
            ov = new PlaylistOverlay
            {
                RimeoId     = !string.IsNullOrEmpty(rimeoId) ? rimeoId! : newId,
                RekordboxId = !string.IsNullOrEmpty(rekordboxId) ? rekordboxId : null,
                TrackIds    = DedupOrdered(transform(seed ?? new List<string>())),
            };
        }

        if (name     != null) ov.Name     = name;
        if (isFolder != null) ov.IsFolder = isFolder.Value;
        if (parent   != null) ov.Parent   = parent;
        ov.Deleted     = deleted;
        ov.Dirty       = true;
        ov.State       = "pending";
        ov.ContentHash = PlaylistHash.ContentHash(ov.TrackIds);

        if (idx >= 0) d.Playlists[idx] = ov; else d.Playlists.Add(ov);
        return (ov.ContentHash ?? "", ov.RimeoId, ov.State);
    }

    /// Сколько оверлеев ещё не записано в master.db. Тот же источник, что и `pending_sync`
    /// в /api/data — они НЕ имеют права разойтись.
    private static int PendingSyncCount() => DataStore.Shared.PendingSyncOverlays().Count;

    // POST /api/playlist/create {rimeo_id?, name, parent?, is_folder, track_ids[]}
    private static async Task CreatePlaylist(AgentRequest req, HttpListenerResponse resp)
    {
        if (JsonBody(req) is not { } body) { await WriteJson(resp, 400, new { error = "Bad request" }); return; }
        var (rimeo, rb) = Addressing(body);
        var name     = GetString(body, "name") ?? "";
        var parent   = GetString(body, "parent");
        if (string.IsNullOrEmpty(parent)) parent = null;
        var isFolder = GetBool(body, "is_folder", false);
        var incoming = isFolder ? new List<string>() : BodyTrackIds(body);

        var hash = ""; var rid = ""; var state = "pending";
        DataStore.Shared.Update(d =>
        {
            var r = UpsertOverlay(d, rimeo, rb, cur => cur.Concat(incoming),
                                  name: name, isFolder: isFolder, parent: parent);
            hash = r.Hash; rid = r.RimeoId; state = r.State;
        });
        await WriteJson(resp, 200, new
        {
            status = "ok", rimeo_id = rid, content_hash = hash, state,
            pending_sync = PendingSyncCount(),
        });
    }

    // POST /api/playlist/create_folder {rimeo_id?, name, parent?}
    private static async Task CreateFolder(AgentRequest req, HttpListenerResponse resp)
    {
        if (JsonBody(req) is not { } body) { await WriteJson(resp, 400, new { error = "Bad request" }); return; }
        var (rimeo, rb) = Addressing(body);
        var name   = GetString(body, "name") ?? "";
        var parent = GetString(body, "parent");
        if (string.IsNullOrEmpty(parent)) parent = null;

        DataStore.Shared.Update(d =>
            UpsertOverlay(d, rimeo, rb, _ => new List<string>(),
                          name: name, isFolder: true, parent: parent));
        await WriteJson(resp, 200, new { status = "ok", pending_sync = PendingSyncCount() });
    }

    // POST /api/playlist/add {rimeo_id?|rekordbox_id?, track_id|track_ids[]}
    private static async Task PlaylistAdd(AgentRequest req, HttpListenerResponse resp)
    {
        if (JsonBody(req) is not { } body) { await WriteJson(resp, 400, new { error = "Bad request" }); return; }
        var (rimeo, rb) = Addressing(body);
        if (rimeo == null && rb == null)
        { await WriteJson(resp, 400, new { error = "rimeo_id or rekordbox_id required" }); return; }
        var newIds = BodyTrackIds(body);

        var lib = RekordboxParser.Shared.Parse();
        if (OverlayFolderBarrier(rimeo) is { } fb) { await WriteJson(resp, 409, new { error = fb }); return; }
        if (RekordboxPlaylistBarrier(rb, lib) is { } pb) { await WriteJson(resp, 409, new { error = pb }); return; }

        var seed = SeedMembership(rb, lib);
        var hash = ""; var state = "pending";
        DataStore.Shared.Update(d =>
        {
            var r = UpsertOverlay(d, rimeo, rb, cur => cur.Concat(newIds), seed: seed);
            hash = r.Hash; state = r.State;
        });
        await WriteJson(resp, 200, new
        {
            status = "ok", content_hash = hash, state, pending_sync = PendingSyncCount(),
        });
    }

    // POST /api/playlist/remove {rimeo_id?|rekordbox_id?, track_id|track_ids[]}
    private static async Task PlaylistRemove(AgentRequest req, HttpListenerResponse resp)
    {
        if (JsonBody(req) is not { } body) { await WriteJson(resp, 400, new { error = "Bad request" }); return; }
        var (rimeo, rb) = Addressing(body);
        if (rimeo == null && rb == null)
        { await WriteJson(resp, 400, new { error = "rimeo_id or rekordbox_id required" }); return; }
        var removeIds = new HashSet<string>(BodyTrackIds(body), StringComparer.Ordinal);

        var lib = RekordboxParser.Shared.Parse();
        if (RekordboxPlaylistBarrier(rb, lib) is { } pb) { await WriteJson(resp, 409, new { error = pb }); return; }

        var seed = SeedMembership(rb, lib);
        var hash = "";
        DataStore.Shared.Update(d =>
        {
            var r = UpsertOverlay(d, rimeo, rb, cur => cur.Where(x => !removeIds.Contains(x)), seed: seed);
            hash = r.Hash;
        });
        await WriteJson(resp, 200, new
        {
            status = "ok", content_hash = hash, pending_sync = PendingSyncCount(),
        });
    }

    // POST /api/playlist/reorder {rimeo_id?|rekordbox_id?, track_ids[]}
    private static async Task PlaylistReorder(AgentRequest req, HttpListenerResponse resp)
    {
        if (JsonBody(req) is not { } body) { await WriteJson(resp, 400, new { error = "Bad request" }); return; }
        var (rimeo, rb) = Addressing(body);
        var ordered = DedupOrdered(CoerceStringArray(Field(body, "track_ids")));

        var lib = RekordboxParser.Shared.Parse();
        if (RekordboxPlaylistBarrier(rb, lib) is { } pb) { await WriteJson(resp, 409, new { error = pb }); return; }

        // Оверлей вслепую не создаём: reorder требует существующей цели, и только наличие
        // rimeo_id разрешает create-if-missing (finding-19).
        var overlays   = DataStore.Shared.Data.Playlists;
        var hasOverlay = (rimeo != null && overlays.Any(o => o.RimeoId == rimeo))
                      || (rb    != null && overlays.Any(o => o.RekordboxId == rb));
        var hasParsed  = rb != null && lib.Playlists.Any(p => p.RekordboxId == rb);
        if (!hasOverlay && !hasParsed && rimeo == null)
        { await WriteJson(resp, 409, new { error = "playlist_not_found" }); return; }

        var hash = ""; var state = "pending";
        DataStore.Shared.Update(d =>
        {
            var r = UpsertOverlay(d, rimeo, rb, _ => ordered, seed: ordered);
            hash = r.Hash; state = r.State;
        });
        await WriteJson(resp, 200, new
        {
            status = "ok", content_hash = hash, state, pending_sync = PendingSyncCount(),
        });
    }

    // POST /api/playlist/rename {rimeo_id?|rekordbox_id?, name}
    private static async Task PlaylistRename(AgentRequest req, HttpListenerResponse resp)
    {
        if (JsonBody(req) is not { } body) { await WriteJson(resp, 400, new { error = "Bad request" }); return; }
        var (rimeo, rb) = Addressing(body);
        if (rimeo == null && rb == null)
        { await WriteJson(resp, 400, new { error = "rimeo_id or rekordbox_id required" }); return; }
        var name = (GetString(body, "name") ?? "").Trim();
        if (string.IsNullOrEmpty(name)) { await WriteJson(resp, 400, new { error = "name required" }); return; }

        var lib  = RekordboxParser.Shared.Parse();
        var seed = SeedMembership(rb, lib);   // сохранить состав при первом перекрытии
        DataStore.Shared.Update(d => UpsertOverlay(d, rimeo, rb, cur => cur, seed: seed, name: name));
        await WriteJson(resp, 200, new { status = "ok", pending_sync = PendingSyncCount() });
    }

    // POST /api/playlist/delete {rimeo_id?|rekordbox_id?} — tombstone в оверлее (не удаление
    // записи: без неё синк не узнал бы, что в master.db надо что-то СНЕСТИ).
    private static async Task PlaylistDelete(AgentRequest req, HttpListenerResponse resp)
    {
        if (JsonBody(req) is not { } body) { await WriteJson(resp, 400, new { error = "Bad request" }); return; }
        var (rimeo, rb) = Addressing(body);
        if (rimeo == null && rb == null)
        { await WriteJson(resp, 400, new { error = "rimeo_id or rekordbox_id required" }); return; }

        DataStore.Shared.Update(d =>
            UpsertOverlay(d, rimeo, rb, _ => new List<string>(), deleted: true));
        await WriteJson(resp, 200, new { status = "ok", pending_sync = PendingSyncCount() });
    }

    // POST /api/playlist/recommendations {playlist_id?, track_ids[], limit, use_key, exclude_ids[], offset?}
    // ПУБЛИЧНЫЙ (как /api/similar) — только читает. Ответ той же формы: {results:[{track,score}]}.
    //
    // `offset` — страница ранжированного списка. Кнопка Refresh в iOS при неизменном составе
    // шлёт offset += limit и получает СЛЕДУЮЩИЙ срез вместо того же самого топа; ранжирование
    // при этом детерминировано (рандома нет). Старый клиент поле не шлёт → offset 0.
    private static async Task PlaylistRecommendations(AgentRequest req, HttpListenerResponse resp)
    {
        if (JsonBody(req) is not { } body) { await WriteJson(resp, 400, new { error = "Bad request" }); return; }

        var trackIds = DedupOrdered(CoerceStringArray(Field(body, "track_ids")));
        // Пустой сид — это не ошибка клиента, а пустой плейлист: рекомендовать не от чего.
        if (trackIds.Count == 0) { await WriteJson(resp, 200, new { results = Array.Empty<object>() }); return; }

        var limit   = Math.Clamp(GetInt(body, "limit", 50), 1, 50);
        var useKey  = GetBool(body, "use_key", true);
        var exclude = new HashSet<string>(CoerceStringArray(Field(body, "exclude_ids")), StringComparer.Ordinal);
        var offset  = Math.Clamp(GetInt(body, "offset", 0), 0, 5000);   // защита от мусора в теле

        var lib     = RekordboxParser.Shared.Parse();                   // переиспользуем кэш парсера
        var results = SimilarityEngine.Shared.RecommendForPlaylist(
            trackIds, lib, limit, useKey, exclude, offset);

        await WriteJson(resp, 200, new { results });
    }

    // ── Плейлисты: синк в Rekordbox (Фаза 6) ──────────────────────────────────

    // GET /api/playlist/sync/status — честный прогресс идущего Sync.
    //
    // Синк — блокирующий POST на десятки секунд, поэтому стадии телефон забирает ОТДЕЛЬНЫМ
    // опросом. Стадии реальные (checking → backup → writing → verifying), счётчик треков
    // приходит из stdout хелпера. Декоративного прогресса тут нет: если бы агент их не слал,
    // экран мог бы только крутить спиннер и врать.
    //
    // Ключ ответа — "playlist" (а НЕ "playlist_name"): набор ключей — часть контракта с iOS,
    // и он обязан совпадать с macOS до буквы, иначе экран синка на Windows не покажет имя.
    private static async Task PlaylistSyncStatus(AgentRequest req, HttpListenerResponse resp)
    {
        var p = RekordboxWriter.Shared.Progress;
        // ⚠️ stage и playlist — ГАРАНТИРОВАННО не-null. На macOS это даёт сам тип (Swift
        // String не опционален), а в C# `string` спокойно примет null — и тогда в JSON
        // уедет `"playlist": null`. iOS декодит эти поля как НЕопциональный String
        // (SyncProgressSheet), то есть на null он падает DecodingError'ом — и экран синка
        // перестаёт обновляться ровно в тот момент, когда пользователь на него смотрит.
        var body = new Dictionary<string, object?>
        {
            ["active"]       = p.Active,
            ["stage"]        = p.Stage ?? "idle",
            ["stage_index"]  = p.StageIndex,
            ["stage_total"]  = p.StageTotal,
            ["tracks_done"]  = p.TracksDone,
            ["tracks_total"] = p.TracksTotal,
            ["playlist"]     = p.PlaylistName ?? "",
        };
        // error отдаём ТОЛЬКО когда он есть: постоянный "error": null телефон показал бы
        // как сбой прошлого прогона поверх нового.
        if (!string.IsNullOrEmpty(p.Error)) body["error"] = p.Error;
        await WriteJson(resp, 200, body);
    }

    // POST /api/playlist/sync {rimeo_ids?: [String]} — Фаза 6. Пишет pending-оверлеи в
    // НАСТОЯЩУЮ master.db юзера. Закрыт авторизацией (SecurityGates).
    //
    // Роут НАМЕРЕННО тонкий: всё опасное (барьер «Rekordbox запущен», бэкап трёх файлов,
    // план, запуск frozen-хелпера, проверка USN, verify перечитыванием, write-back)
    // живёт в RekordboxWriter, который сериализует прогоны на своей очереди. Синхронный,
    // как SendTelegram: вызывающий получает РЕАЛЬНЫЙ исход, а не fire-and-forget «ok»,
    // который потом пришлось бы допрашивать опросом.
    //
    //   200 {status:"ok", synced:[{rimeo_id,rekordbox_id,sync_state}], failed:[], counts:{…}}
    //   200 {status:"ok", synced:[], nothing:true}    — синкать нечего (идемпотентно)
    //   409 sync_in_progress | rekordbox_running | ambiguous_path | db_unavailable
    //   500 write_failed | helper_unavailable | backup_failed | usn_not_advanced |
    //       write_verify_failed
    private static async Task PlaylistSync(AgentRequest req, HttpListenerResponse resp)
    {
        // Тело ОПЦИОНАЛЬНО: пустой POST = «синкать всё pending» — именно это шлёт кнопка
        // Sync в iOS. Поэтому никакого 400 на отсутствующее/не-объектное тело: сужает
        // прогон только явный НЕПУСТОЙ rimeo_ids. Ответь мы тут 400 — кнопка не работала бы
        // вообще ни у кого.
        var requested = JsonBody(req) is { } body
            ? DedupOrdered(CoerceStringArray(Field(body, "rimeo_ids")))
            : new List<string>();

        var result = RekordboxWriter.Shared.Sync(requested.Count == 0 ? null : requested);

        if (result.Ok)
        {
            // Счётчики в логе — НЕ украшение. Это единственная операция агента, которая
            // ПИШЕТ в чужую библиотеку, и когда придёт жалоба «после синка что-то не так»,
            // по логу нужно уметь восстановить, что именно прогон сделал с базой. Без
            // counts в строке остаётся только «ok» — и разбираться не с чем. Паритет с
            // macOS (APIRouter.playlistSync).
            var c = result.Counts;
            Log.Info($"POST /api/playlist/sync -> ok, synced={SyncedCount(result)} nothing={result.Nothing} "
                   + $"created={c.Created} updated={c.Updated} deleted={c.Deleted} "
                   + $"added={c.Added} removed={c.Removed} reordered={c.Reordered}");
        }
        else
            Log.Warn($"POST /api/playlist/sync -> {result.Status} {result.Error ?? "?"} {result.Detail ?? ""}");

        await WriteJson(resp, result.Status, result.Body);
    }

    /// Сколько плейлистов реально уехало в базу — только для строки лога. Читаем из уже
    /// собранного result.Body (а не из отдельного поля), чтобы у лога и у ответа клиенту был
    /// ОДИН источник: разъехавшись, они превратили бы разбор бага в гадание, кому верить.
    private static int SyncedCount(SyncResult result) =>
        result.Body.TryGetValue("synced", out var v) && v is System.Collections.ICollection c
            ? c.Count : 0;

    // ── /api/send_tg ─────────────────────────────────────────────────────────

    private static async Task SendTelegram(AgentRequest req, HttpListenerResponse resp)
    {
        var token  = Environment.GetEnvironmentVariable("RIMEO_TG_TOKEN")   ?? "";
        var chatId = Environment.GetEnvironmentVariable("RIMEO_TG_CHAT_ID") ?? "";
        if (string.IsNullOrEmpty(token) || string.IsNullOrEmpty(chatId))
        { await WriteJson(resp, 503, new { error = "Telegram not configured" }); return; }

        var body = ParseJsonBody<Dictionary<string, string>>(req.Body);
        if (body == null) { await WriteJson(resp, 400, new { error = "Bad request" }); return; }

        var text = $"🎵 {body.GetValueOrDefault("artist", "")} — {body.GetValueOrDefault("title", "")}";
        try
        {
            using var http = new HttpClient();
            await http.PostAsync($"https://api.telegram.org/bot{token}/sendMessage",
                new StringContent(JsonSerializer.Serialize(new { chat_id = chatId, text }),
                    Encoding.UTF8, "application/json"));
        }
        catch { }
        await WriteJson(resp, 200, new { status = "ok" });
    }

    // ── /api/analysis ────────────────────────────────────────────────────────

    private static async Task GetAnalysis(AgentRequest req, HttpListenerResponse resp)
    {
        var id = req.QueryParams.GetValueOrDefault("id", "");
        if (string.IsNullOrEmpty(id)) { await WriteJson(resp, 400, new { error = "id required" }); return; }
        var feat = AnalysisEngine.Shared.GetFeatures(id);
        if (feat == null) { await WriteJson(resp, 404, new { error = "Track not analysed yet" }); return; }
        await WriteJson(resp, 200, feat);
    }

    private static async Task GetAnalysisStatus(AgentRequest req, HttpListenerResponse resp)
    {
        var s       = AppState.Shared;
        var summary = AnalysisSummary();
        await WriteJson(resp, 200, new
        {
            running        = s.AnalysisRunning,
            total          = s.AnalysisRunning ? s.AnalysisTotal : summary.available,
            done           = s.AnalysisDone,
            current        = s.AnalysisCurrent,
            errors         = s.AnalysisErrors,
            unavailable    = s.AnalysisRunning ? s.AnalysisUnavailable : summary.unavailable,
            analyzed_count = summary.analyzed,
            not_analyzed   = summary.notAnalyzed,
            available_count= summary.available,
            library_count  = summary.library,
            all_analyzed   = summary.notAnalyzed == 0 && summary.available > 0,
        });
    }

    private static async Task StartAnalysis(AgentRequest req, HttpListenerResponse resp)
    {
        var s = AppState.Shared;
        if (s.AnalysisRunning) { await WriteJson(resp, 200, new { status = "already_running" }); return; }
        AnalysisEngine.Shared.ResetCancellation();
        s.AnalysisRunning = true; s.AnalysisDone = 0; s.AnalysisErrors = 0;
        s.AnalysisUnavailable = 0; s.AnalysisCurrent = "";
        _ = Task.Run(RunAnalysisJob);
        await WriteJson(resp, 200, new { status = "started" });
    }

    private static async Task StopAnalysis(AgentRequest req, HttpListenerResponse resp)
    {
        AnalysisEngine.Shared.RequestCancel();
        AppState.Shared.AnalysisRunning = false;
        AppState.Shared.AnalysisCurrent = "Stopping...";
        await WriteJson(resp, 200, new { status = "stopping" });
    }

    private static async Task RecheckAnalysis(AgentRequest req, HttpListenerResponse resp)
    {
        var s = AppState.Shared;
        if (s.AnalysisRunning) { await WriteJson(resp, 200, new { status = "already_running" }); return; }
        AnalysisEngine.Shared.ResetCancellation();
        s.AnalysisRunning = true; s.AnalysisDone = 0; s.AnalysisErrors = 0;
        s.AnalysisUnavailable = 0; s.AnalysisCurrent = "";
        _ = Task.Run(RunAnalysisJob);
        await WriteJson(resp, 200, new { status = "started" });
    }

    private static async Task GetAnalyzedIds(AgentRequest req, HttpListenerResponse resp)
    {
        var ids = AnalysisEngine.Shared.AllIds();
        await WriteJson(resp, 200, new { ids, count = ids.Count });
    }

    private static void RunAnalysisJob()
    {
        var lib     = RekordboxParser.Shared.Parse();
        var tracks  = lib.Tracks.DistinctBy(t => t.Id).ToList();
        var avail   = tracks.Where(t => File.Exists(t.Location)).ToList();
        var unavail = tracks.Count - avail.Count;
        var s       = AppState.Shared;
        s.AnalysisTotal       = avail.Count;
        s.AnalysisUnavailable = unavail;

        var initial = AnalysisEngine.Shared.StoreSnapshot();
        int success = 0, errors = 0;

        for (int i = 0; i < avail.Count; i++)
        {
            if (AnalysisEngine.Shared.ShouldCancel()) break;
            var track = avail[i];
            s.AnalysisCurrent = $"{track.Artist} — {track.Title}";
            s.AnalysisDone    = i;

            if (initial.TryGetValue(track.Id, out var ex) &&
                ex.Energy > 0 && ex.Timbre.Length > 0 && ex.Groove > 0)
            { success++; s.AnalysisDone = i + 1; continue; }

            var result = AnalysisEngine.Shared.AnalyzeTrack(track);
            if (result != null)
            {
                AnalysisEngine.Shared.SetFeatures(track.Id, result);
                AnalysisEngine.Shared.SaveStore();
                success++;
            }
            else
            {
                errors++;
                s.AnalysisErrors = errors;
            }
            s.AnalysisDone = i + 1;
        }

        AnalysisEngine.Shared.SaveStore();
        s.AnalysisRunning = false;
        s.AnalysisCurrent = "";
        Log.Info($"Analysis complete: analyzed={success}, errors={errors}, unavailable={unavail}");
    }

    private static (int library, int available, int unavailable, int analyzed, int notAnalyzed) AnalysisSummary()
    {
        var lib     = RekordboxParser.Shared.Parse();
        var tracks  = lib.Tracks.DistinctBy(t => t.Id).ToList();
        var availIds = new HashSet<string>(tracks.Where(t => File.Exists(t.Location)).Select(t => t.Id));
        var store   = AnalysisEngine.Shared.StoreSnapshot();
        int analyzed = store.Count(kv => availIds.Contains(kv.Key) && kv.Value.Timbre.Length > 0 && kv.Value.Energy > 0);
        return (tracks.Count, availIds.Count, tracks.Count - availIds.Count, analyzed, Math.Max(0, availIds.Count - analyzed));
    }

    // ── /api/similar ─────────────────────────────────────────────────────────

    /// «Похожие треки». НИКАКОЙ зависимости от аудио-анализа: движок работает на метаданных
    /// и графе совместности, поэтому 404 «Track not analysed» здесь больше нет — раньше на
    /// непроанализированной библиотеке (а это состояние по умолчанию) ручка не отвечала
    /// вообще, тогда как macOS на тех же данных выдаёт список.
    ///
    /// Форма ответа — ровно как у macOS getSimilar: {results:[{track, score}]}, где score =
    /// {total, bpm_delta, key_relation, label_match, genre_match, artist_match, duration_match}.
    /// Старые поля (vibe/key/harmony/tempo/metadata/clap) выброшены вместе со старым движком:
    /// iOS декодит именно новый набор.
    private static async Task GetSimilar(AgentRequest req, HttpListenerResponse resp)
    {
        var id      = req.QueryParams.GetValueOrDefault("id", "");
        var limit   = int.TryParse(req.QueryParams.GetValueOrDefault("limit", "20"), out var l) ? l : 20;
        var useKey  = req.QueryParams.GetValueOrDefault("use_key", "1") != "0";

        if (string.IsNullOrEmpty(id)) { await WriteJson(resp, 400, new { error = "id required" }); return; }

        var lib     = RekordboxParser.Shared.Parse();
        var results = SimilarityEngine.Shared.FindSimilar(id, lib, Math.Min(limit, 50), useKey);

        // SimilarResult/MatchScore несут [JsonPropertyName] со snake_case — сериализуем как есть,
        // без ручного маппинга: так ключи не разъедутся при правке движка.
        await WriteJson(resp, 200, new { results });
    }

    // ── /api/status ───────────────────────────────────────────────────────────

    private static async Task GetStatus(AgentRequest req, HttpListenerResponse resp)
    {
        var cfg    = AppConfig.Shared;
        var data   = DataStore.Shared.Data;
        var tunnel = CurrentTunnelInfo();
        await WriteJson(resp, 200, new
        {
            agent_id         = cfg.AgentId,
            version          = cfg.DisplayVersion,
            xml_path         = cfg.XmlPath,
            xml_exists       = File.Exists(cfg.XmlPath),
            db_path          = cfg.DbPath,
            db_exists        = File.Exists(cfg.DbPath),
            library_source   = File.Exists(cfg.DbPath) ? "db" : "xml",
            cloud_url        = data.CloudUrl,
            is_linked        = !string.IsNullOrEmpty(data.CloudUrl),
            agent_url        = cfg.LocalAgentUrl(),
            tunnel_url       = tunnel.url,
            tunnel_active    = tunnel.active,
            cloudflared_found = tunnel.cloudflaredFound,
            stream_transport = string.IsNullOrEmpty(tunnel.url) ? "relay_only" : "tunnel",
        });
    }

    // ── /api/account ─────────────────────────────────────────────────────────

    private static async Task GetAccount(AgentRequest req, HttpListenerResponse resp)
    {
        var cfg    = AppConfig.Shared;
        var data   = DataStore.Shared.Data;
        var tunnel = CurrentTunnelInfo();
        await WriteJson(resp, 200, new
        {
            cloud_url         = data.CloudUrl,
            cloud_user_id     = data.CloudUserId,
            is_linked         = !string.IsNullOrEmpty(data.CloudUrl),
            agent_id          = cfg.AgentId,
            agent_url         = cfg.LocalAgentUrl(),
            tunnel_url        = tunnel.url,
            tunnel_active     = tunnel.active,
            cloudflared_found  = tunnel.cloudflaredFound,
            stream_transport  = string.IsNullOrEmpty(tunnel.url) ? "relay_only" : "tunnel",
        });
    }

    // ── /api/link_account ────────────────────────────────────────────────────

    private static async Task LinkAccount(AgentRequest req, HttpListenerResponse resp)
    {
        var body = ParseJsonBody<Dictionary<string, object>>(req.Body);
        if (body == null || !body.TryGetValue("token", out var tokenObj) ||
            tokenObj?.ToString()?.Trim() is not { Length: > 0 } token)
        { await WriteJson(resp, 400, new { error = "token required" }); return; }

        var cloudUrl = body.TryGetValue("cloud_url", out var cu) ? cu?.ToString()?.Trim() ?? "" : "";
        var rawToken = token;

        // Try compound token {url, t}
        try
        {
            var decoded = Convert.FromBase64String(token + "==");
            var compound = JsonSerializer.Deserialize<Dictionary<string, string>>(decoded);
            if (compound != null && compound.TryGetValue("t", out var t))
            {
                rawToken = t;
                if (compound.TryGetValue("url", out var u) && !string.IsNullOrEmpty(u))
                    cloudUrl = u.Trim();
            }
        }
        catch { }

        if (string.IsNullOrEmpty(cloudUrl)) cloudUrl = AppConfig.RimeoAppUrl;
        cloudUrl = cloudUrl.TrimEnd('/');

        var cfg     = AppConfig.Shared;
        var d       = DataStore.Shared.Data;
        var tunnel  = string.IsNullOrEmpty(TunnelManager.Shared.ActiveUrl) ? d.TunnelUrl : TunnelManager.Shared.ActiveUrl;
        var payload = JsonSerializer.Serialize(new
        {
            token      = rawToken,
            agent_id   = cfg.AgentId,
            agent_url  = cfg.LocalAgentUrl(),
            tunnel_url = tunnel,
            agent_name = AppConfig.AppName,
            // Облако передаст PSK телефону того же аккаунта — тот же уровень доверия,
            // что и QR (который печатает секрет прямо на экране), но работает и при
            // входе по email. Без этого поля LAN-путь у Windows-агента НЕ включается
            // никогда: телефон уходит в Cloudflare даже в одной комнате с ПК. macOS
            // шлёт его с build 242 (APIRouter.swift:1503).
            lan_secret = EnsureLanSecret(),
        });

        try
        {
            using var http = new HttpClient();
            using var cts  = new CancellationTokenSource(TimeSpan.FromSeconds(15));
            var content    = new StringContent(payload, Encoding.UTF8, "application/json");
            var httpResp   = await http.PostAsync($"{cloudUrl}/api/agents/link", content, cts.Token);
            var resultStr  = await httpResp.Content.ReadAsStringAsync();

            if (!httpResp.IsSuccessStatusCode)
            { await WriteJson(resp, (int)httpResp.StatusCode, new { error = $"Cloud rejected link: {resultStr}" }); return; }

            var result = JsonSerializer.Deserialize<Dictionary<string, JsonElement>>(resultStr);
            DataStore.Shared.Update(dd =>
            {
                dd.CloudUrl     = cloudUrl;
                dd.CloudUserId  = result?.TryGetValue("email", out var eEl) == true ? eEl.GetString() : null;
                if (result?.TryGetValue("cloud_token", out var ctEl) == true) dd.CloudToken = ctEl.GetString() ?? "";
            });
            AppState.Shared.RefreshFromData();
            CloudRelay.Shared.Start(cloudUrl, DataStore.Shared.Data.CloudToken);

            await WriteJson(resp, 200, new { status = "linked", cloud_url = cloudUrl, result });
        }
        catch (Exception ex) { await WriteJson(resp, 502, new { error = ex.Message }); }
    }

    // ── /api/agent_login & /api/agent_signup (login-model) ─────────────────────

    /// <summary>
    /// Shared email+password flow for sign-in and sign-up. Posts the credentials
    /// to the cloud, stores the returned cloud_token and starts the relay. The
    /// cloud enforces a single active agent per account (others are evicted).
    /// </summary>
    private static async Task AgentAuth(AgentRequest req, HttpListenerResponse resp, string cloudPath)
    {
        var body = ParseJsonBody<Dictionary<string, object>>(req.Body);
        var email = body != null && body.TryGetValue("email", out var eo) ? eo?.ToString()?.Trim() ?? "" : "";
        var password = body != null && body.TryGetValue("password", out var po) ? po?.ToString() ?? "" : "";
        if (string.IsNullOrEmpty(email) || string.IsNullOrEmpty(password))
        { await WriteJson(resp, 400, new { error = "email and password required" }); return; }

        var cloudUrl = AppConfig.RimeoAppUrl.TrimEnd('/');
        var cfg     = AppConfig.Shared;
        var d       = DataStore.Shared.Data;
        var tunnel  = string.IsNullOrEmpty(TunnelManager.Shared.ActiveUrl) ? d.TunnelUrl : TunnelManager.Shared.ActiveUrl;
        var payload = JsonSerializer.Serialize(new
        {
            email,
            password,
            agent_id   = cfg.AgentId,
            agent_url  = cfg.LocalAgentUrl(),
            tunnel_url = tunnel,
            agent_name = AppConfig.AppName,
            // См. EnsureLanSecret(): без этого поля вход по email не включает LAN, и
            // телефон стримит через Cloudflare, стоя рядом с ПК. Паритет с macOS
            // (APIRouter.swift:1585).
            lan_secret = EnsureLanSecret(),
        });

        try
        {
            using var http = new HttpClient();
            using var cts  = new CancellationTokenSource(TimeSpan.FromSeconds(15));
            var content    = new StringContent(payload, Encoding.UTF8, "application/json");
            var httpResp   = await http.PostAsync($"{cloudUrl}{cloudPath}", content, cts.Token);
            var resultStr  = await httpResp.Content.ReadAsStringAsync();

            if (!httpResp.IsSuccessStatusCode)
            {
                var msg = "Sign-in failed";
                try
                {
                    var err = JsonSerializer.Deserialize<Dictionary<string, JsonElement>>(resultStr);
                    if (err?.TryGetValue("error", out var errEl) == true) msg = errEl.GetString() ?? msg;
                }
                catch { if (!string.IsNullOrEmpty(resultStr)) msg = resultStr; }
                await WriteJson(resp, (int)httpResp.StatusCode, new { error = msg });
                return;
            }

            var result = JsonSerializer.Deserialize<Dictionary<string, JsonElement>>(resultStr);
            var cloudToken = result?.TryGetValue("cloud_token", out var ctEl) == true ? ctEl.GetString() ?? "" : "";
            if (string.IsNullOrEmpty(cloudToken))
            { await WriteJson(resp, 502, new { error = "Sign-in failed" }); return; }

            DataStore.Shared.Update(dd =>
            {
                dd.CloudUrl    = cloudUrl;
                dd.CloudUserId = result?.TryGetValue("email", out var eEl) == true ? eEl.GetString() : null;
                dd.CloudToken  = cloudToken;
            });
            AppState.Shared.RefreshFromData();
            CloudRelay.Shared.Start(cloudUrl, cloudToken);

            await WriteJson(resp, 200, new { status = "ok", cloud_url = cloudUrl, result });
        }
        catch (Exception ex) { await WriteJson(resp, 502, new { error = ex.Message }); }
    }

    // ── /api/unlink_account ──────────────────────────────────────────────────

    private static async Task UnlinkAccount(AgentRequest req, HttpListenerResponse resp)
    {
        var d = DataStore.Shared.Data;
        if (!string.IsNullOrEmpty(d.CloudUrl))
        {
            try
            {
                using var http = new HttpClient();
                using var cts  = new CancellationTokenSource(TimeSpan.FromSeconds(5));
                await http.PostAsync($"{d.CloudUrl}/api/agents/unlink_by_agent",
                    new StringContent(JsonSerializer.Serialize(new { agent_id = AppConfig.Shared.AgentId }),
                        Encoding.UTF8, "application/json"), cts.Token);
            }
            catch { }
        }
        CloudRelay.Shared.Stop();
        DataStore.Shared.Update(dd => { dd.CloudUrl = ""; dd.CloudUserId = null; dd.CloudToken = ""; });
        AppState.Shared.RefreshFromData();
        await WriteJson(resp, 200, new { status = "unlinked" });
    }

    // ── Tunnel ───────────────────────────────────────────────────────────────

    private static async Task TunnelStatus(AgentRequest req, HttpListenerResponse resp)
    {
        var t = CurrentTunnelInfo();
        await WriteJson(resp, 200, new { active = t.active, url = t.url, stored_url = t.storedUrl, cloudflared_found = t.cloudflaredFound });
    }

    private static async Task TunnelStart(AgentRequest req, HttpListenerResponse resp)
    {
        TunnelManager.Shared.Start();
        var deadline = DateTime.UtcNow.AddSeconds(20);
        while (DateTime.UtcNow < deadline && string.IsNullOrEmpty(TunnelManager.Shared.ActiveUrl))
            await Task.Delay(500);
        var url = TunnelManager.Shared.ActiveUrl;
        await WriteJson(resp, 200, new { status = string.IsNullOrEmpty(url) ? "starting" : "started", url });
    }

    private static async Task TunnelStop(AgentRequest req, HttpListenerResponse resp)
    {
        TunnelManager.Shared.Stop();
        await WriteJson(resp, 200, new { status = "stopped" });
    }

    // ── /api/logs ──────────────────────────────────────────────────────────────

    /// Tail of the agent log + host/OS/version, pulled by the cloud relay when a
    /// user submits "Report a problem" from iOS/web.
    ///
    /// Хвост берём из ФАЙЛА (256 КБ, как logger.tail на macOS), а не из кольца в памяти:
    /// кольцо не переживает рестарт агента — то есть ровно в том случае, ради которого
    /// бандл и собирают («агент упал и перезапустился»), улик в нём уже нет.
    private static async Task GetLogs(AgentRequest req, HttpListenerResponse resp)
    {
        await WriteJson(resp, 200, new
        {
            platform      = "windows",
            os            = System.Runtime.InteropServices.RuntimeInformation.OSDescription,
            agent_version = AppConfig.Shared.DisplayVersion,
            agent_id      = AppConfig.Shared.AgentId,
            log           = AgentLogger.Shared.Tail(256 * 1024),
        });
    }

    // ── /api/report_bug ──────────────────────────────────────────────────────

    private static async Task ReportBug(AgentRequest req, HttpListenerResponse resp)
    {
        var body = ParseJsonBody<Dictionary<string, string>>(req.Body);
        var desc = body?.GetValueOrDefault("description", "")?.Trim() ?? "";
        if (string.IsNullOrEmpty(desc)) { await WriteJson(resp, 400, new { error = "description required" }); return; }

        var d = DataStore.Shared.Data;
        if (string.IsNullOrEmpty(d.CloudUrl)) { await WriteJson(resp, 503, new { error = "Agent not linked" }); return; }

        var payload = new
        {
            agent_id    = AppConfig.Shared.AgentId,
            user_email  = d.CloudUserId ?? "",
            description = desc,
            log_excerpt = AgentLogger.Shared.LastLines(80),
        };

        try
        {
            using var http = new HttpClient();
            using var cts  = new CancellationTokenSource(TimeSpan.FromSeconds(15));
            var content    = new StringContent(JsonSerializer.Serialize(payload), Encoding.UTF8, "application/json");
            var httpResp   = await http.PostAsync($"{d.CloudUrl}/api/report_bug", content, cts.Token);
            if (!httpResp.IsSuccessStatusCode)
            { await WriteJson(resp, (int)httpResp.StatusCode, new { error = $"Cloud returned {(int)httpResp.StatusCode}" }); return; }
        }
        catch (Exception ex) { await WriteJson(resp, 502, new { error = ex.Message }); return; }
        await WriteJson(resp, 200, new { status = "ok" });
    }

    // ── /api/agent/update ────────────────────────────────────────────────────

    /// Обновление агента по запросу с телефона. HTTP-ответ пишется ДО старта задачи:
    /// установка завершает процесс (Environment.Exit в ApplyZip), и клиент иначе
    /// получил бы оборванное соединение вместо 202.
    ///
    /// Контракт приведён к macOS (agentUpdateStart) АДДИТИВНО — поля macOS добавлены,
    /// исторические windows-поля (stage/progress/current_version/target_version) оставлены:
    /// их может читать уже установленный iOS-клиент.
    ///   200 {status:"started",    target, target_build, current_build, notes, …}
    ///   200 {status:"up_to_date", current_build, latest_build, …}
    ///   409 update_in_progress   — установка уже идёт (было 200 "in_progress")
    ///   503 update_check_failed  — GitHub недоступен (было 502). Отдельный код нужен, чтобы
    ///                              НЕ соврать «у вас последняя версия» при сетевой ошибке.
    private static async Task StartAgentUpdate(AgentRequest req, HttpListenerResponse resp)
    {
        var cfg     = AppConfig.Shared;
        var current = UpdateChecker.ParseBuild(cfg.BuildNumber);
        var r       = AgentUpdateService.Shared.Start();

        if (r.AlreadyRunning)
        {
            var running = AgentUpdateService.Shared.Status();
            await WriteJson(resp, 409, new
            {
                error           = "update_in_progress",
                status          = "in_progress",
                stage           = running.Stage,
                progress        = running.Progress,
                current_version = cfg.DisplayVersion,
                current_build   = current,
                target_version  = running.TargetVersion,
                target          = running.TargetVersion,
                target_build    = UpdateChecker.ParseBuild(running.TargetVersion),
            });
            return;
        }

        // Проверка сорвалась (нет сети / GitHub недоступен) — это НЕ "up to date".
        // Сырое сообщение остаётся в detail: `error` теперь несёт КОД (как на macOS).
        if (r.Error != null)
        {
            await WriteJson(resp, 503, new
            {
                error           = "update_check_failed",
                detail          = r.Error,
                status          = "error",
                stage           = "error",
                current_version = cfg.DisplayVersion,
                current_build   = current,
            });
            return;
        }

        if (r.Info == null)
        {
            await WriteJson(resp, 200, new
            {
                status          = "up_to_date",
                stage           = "idle",
                progress        = 0.0,
                current_version = cfg.DisplayVersion,
                current_build   = current,
                latest_build    = current,   // проверка прошла и новее ничего нет
            });
            return;
        }

        Log.Info($"Remote update accepted: build {cfg.BuildNumber} → {r.Info.Version}");
        await WriteJson(resp, 202, new
        {
            // "started" — как на macOS (был windows-only "updating"). Значение поля не
            // читает ни один клиент (iOS смотрит только на HTTP-код), а вот РАСХОЖДЕНИЕ
            // строк между платформами — ровно то, что потом ловится в проде.
            status          = "started",
            stage           = "downloading",
            progress        = 0.0,
            current_version = cfg.DisplayVersion,
            current_build   = current,
            target          = r.Info.Version,
            target_build    = UpdateChecker.ParseBuild(r.Info.Version),
            target_version  = r.Info.Version,
            notes           = r.Info.Notes,
        });
    }

    /// Poll-эндпоинт для попапа в iOS. Стадии: idle / downloading / verifying /
    /// installing / restarting / done / error. На "restarting" процесс умирает —
    /// соединение рвётся, и клиент должен перезапрашивать статус, пока агент не
    /// поднимется снова: тогда он ответит "done" (по маркеру на диске).
    private static async Task AgentUpdateStatus(AgentRequest req, HttpListenerResponse resp)
    {
        var cfg     = AppConfig.Shared;
        var st      = AgentUpdateService.Shared.Status();
        var current = UpdateChecker.ParseBuild(cfg.BuildNumber);

        // Поля macOS (active/agent_version/target/target_build) добавлены АДДИТИВНО;
        // исторические windows-поля (current_version/target_version/platform/supported)
        // оставлены — их читает уже установленный клиент.
        var body = new Dictionary<string, object?>
        {
            ["stage"]           = st.Stage,
            ["active"]          = st.Stage is AgentUpdateService.StageDownloading
                                           or "verifying" or "installing"
                                           or AgentUpdateService.StageRestarting,
            ["progress"]        = st.Progress,
            ["error"]           = st.Error,
            ["current_build"]   = current,
            ["agent_version"]   = cfg.BuildNumber,
            ["current_version"] = cfg.DisplayVersion,
            ["platform"]        = "windows",
            ["supported"]       = true,
        };
        if (!string.IsNullOrEmpty(st.TargetVersion))
        {
            body["target"]         = st.TargetVersion;
            body["target_build"]   = UpdateChecker.ParseBuild(st.TargetVersion);
            body["target_version"] = st.TargetVersion;
        }
        await WriteJson(resp, 200, body);
    }

    // ── Helpers ───────────────────────────────────────────────────────────────

    private static async Task WriteJson(HttpListenerResponse resp, int status, object obj)
    {
        var json  = JsonSerializer.Serialize(obj);
        var bytes = Encoding.UTF8.GetBytes(json);
        resp.StatusCode      = status;
        resp.ContentType     = "application/json";
        resp.ContentLength64 = bytes.Length;
        await resp.OutputStream.WriteAsync(bytes);
        resp.Close();
    }

    private static T? ParseJsonBody<T>(byte[] body)
    {
        try { return JsonSerializer.Deserialize<T>(body); }
        catch { return default; }
    }

    private static (bool active, string url, string storedUrl, bool cloudflaredFound) CurrentTunnelInfo()
    {
        var active    = TunnelManager.Shared.IsRunning;
        var activeUrl = TunnelManager.Shared.ActiveUrl;
        var stored    = DataStore.Shared.Data.TunnelUrl;
        return (
            active:            active && !string.IsNullOrEmpty(activeUrl),
            url:               !string.IsNullOrEmpty(activeUrl) ? activeUrl : stored,
            storedUrl:         stored,
            cloudflaredFound:  TunnelManager.Shared.FindCloudflared() != null
        );
    }

    private static string MimeType(string path) => Path.GetExtension(path).ToLower() switch
    {
        ".mp3"  => "audio/mpeg",
        ".wav"  => "audio/wav",
        ".m4a"  => "audio/mp4",
        ".aac"  => "audio/aac",
        ".ogg"  => "audio/ogg",
        ".flac" => "audio/flac",
        _       => "audio/mpeg",
    };
}
