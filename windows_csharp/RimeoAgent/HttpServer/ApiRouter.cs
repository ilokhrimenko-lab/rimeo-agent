using System.Net;
using System.Text;
using System.Text.Json;
using RimeoAgent.Config;
using RimeoAgent.Models;
using RimeoAgent.Services;

namespace RimeoAgent.HttpServer;

public sealed class ApiRouter
{
    public async Task RouteAsync(AgentRequest req, HttpListenerResponse resp)
    {
        try
        {
            switch ((req.Method, req.Path))
            {
                case ("GET",  "/stream"):                  await StreamAudio(req, resp); break;
                case ("GET",  "/waveform"):                await Waveform(req, resp); break;
                case ("GET",  "/artwork"):                 await Artwork(req, resp); break;
                case ("GET",  "/reveal"):                  await Reveal(req, resp); break;
                case ("GET",  "/api/data"):                await GetData(req, resp); break;
                case ("GET",  "/api/pairing_info"):        await PairingInfo(req, resp); break;
                case ("GET",  "/api/check_pairing"):       await CheckPairing(req, resp); break;
                case ("POST", "/api/save_note"):           await SaveNote(req, resp); break;
                case ("POST", "/api/save_exclusions"):     await SaveExclusions(req, resp); break;
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
                case ("POST", "/api/unlink_account"):      await UnlinkAccount(req, resp); break;
                case ("GET",  "/api/tunnel/status"):       await TunnelStatus(req, resp); break;
                case ("POST", "/api/tunnel/start"):        await TunnelStart(req, resp); break;
                case ("POST", "/api/tunnel/stop"):         await TunnelStop(req, resp); break;
                case ("POST", "/api/report_bug"):          await ReportBug(req, resp); break;
                default:                                   await WriteJson(resp, 404, new { error = "Not found" }); break;
            }
        }
        catch (Exception ex)
        {
            Log.Error($"Router error {req.Path}: {ex.Message}");
            await WriteJson(resp, 500, new { error = ex.Message });
        }
    }

    // ── /stream ─────────────────────────────────────────────────────────────

    private static async Task StreamAudio(AgentRequest req, HttpListenerResponse resp)
    {
        if (!req.QueryParams.TryGetValue("path", out var rawPath) || string.IsNullOrEmpty(rawPath))
        { await WriteJson(resp, 400, new { error = "path required" }); return; }

        var path    = rawPath;
        var trackId = req.QueryParams.GetValueOrDefault("id", "");
        var preload = req.QueryParams.GetValueOrDefault("preload", "") is "1" or "true";
        var ext     = Path.GetExtension(path).TrimStart('.').ToLower();

        Log.Info($"Stream request: track={trackId}, preload={preload}, path={path}");

        if (!File.Exists(path)) { await WriteJson(resp, 404, new { error = "File not found" }); return; }

        string finalPath = path;
        if (ext is "aif" or "aiff")
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

        if (req.Headers.TryGetValue("Range", out var rangeHeader) && !string.IsNullOrEmpty(rangeHeader))
        {
            var cleaned = rangeHeader.Replace("bytes=", "");
            var parts   = cleaned.Split('-');
            if (parts.Length == 2)
            {
                start = long.TryParse(parts[0], out var s) ? s : 0;
                end   = !string.IsNullOrEmpty(parts[1]) && long.TryParse(parts[1], out var e) ? e : size - 1;
            }
        }

        if (start > end || start >= size) { resp.StatusCode = 416; resp.Close(); return; }
        end = Math.Min(end, size - 1);
        long length = end - start + 1;

        resp.StatusCode  = 206;
        resp.ContentType = mime;
        resp.Headers.Add("Accept-Ranges",  "bytes");
        resp.Headers.Add("Content-Range",  $"bytes {start}-{end}/{size}");
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

        System.Diagnostics.Process.Start("explorer.exe", $"/select,\"{path}\"");
        await WriteJson(resp, 200, new { status = "ok" });
    }

    // ── /api/data ─────────────────────────────────────────────────────────────

    private static async Task GetData(AgentRequest req, HttpListenerResponse resp)
    {
        var lib  = RekordboxParser.Shared.Parse();
        var data = DataStore.Shared.Data;
        Log.Info($"GET /api/data -> {lib.Tracks.Count} tracks, {lib.Playlists.Count} playlists");
        var obj = new
        {
            tracks            = lib.Tracks,
            playlists         = lib.Playlists,
            notes             = data.Notes,
            global_exclusions = data.GlobalExclusions,
            library_date      = lib.XmlDate,
            xml_date          = lib.XmlDate,
        };
        await WriteJson(resp, 200, obj);
    }

    // ── /api/pairing_info ────────────────────────────────────────────────────

    private static async Task PairingInfo(AgentRequest req, HttpListenerResponse resp)
    {
        const string chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789";
        var rng  = new Random();
        var code = new string(Enumerable.Range(0, 5).Select(_ => chars[rng.Next(chars.Length)]).ToArray());
        DataStore.Shared.Update(d => d.PairingCode = code);

        var localIp  = AppConfig.Shared.GetLocalIp();
        var localUrl = $"http://{localIp}:{AppConfig.Port}";
        var d2       = DataStore.Shared.Data;
        var tunnel   = TunnelManager.Shared.ActiveUrl;
        var url      = string.IsNullOrEmpty(tunnel)
                        ? (string.IsNullOrEmpty(d2.TunnelUrl) ? localUrl : d2.TunnelUrl)
                        : tunnel;

        var qrData    = $"{{\"url\":\"{url}\",\"code\":\"{code}\",\"agent_id\":\"{AppConfig.Shared.AgentId}\"}}";
        var encoded   = Uri.EscapeDataString(qrData);
        var qrUrl     = $"https://api.qrserver.com/v1/create-qr-code/?size=300x300&data={encoded}";

        await WriteJson(resp, 200, new { code, qr_url = qrUrl, local_url = url, agent_id = AppConfig.Shared.AgentId });
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

    // ── /api/save_exclusions ─────────────────────────────────────────────────

    private static async Task SaveExclusions(AgentRequest req, HttpListenerResponse resp)
    {
        var list = ParseJsonBody<List<string>>(req.Body);
        if (list == null) { await WriteJson(resp, 400, new { error = "Expected array of strings" }); return; }
        DataStore.Shared.Update(d => d.GlobalExclusions = list);
        await WriteJson(resp, 200, new { status = "ok" });
    }

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

    private static async Task GetSimilar(AgentRequest req, HttpListenerResponse resp)
    {
        var id     = req.QueryParams.GetValueOrDefault("id", "");
        int limit  = int.TryParse(req.QueryParams.GetValueOrDefault("limit", "10"), out var l) ? l : 10;
        bool useKey = req.QueryParams.GetValueOrDefault("use_key", "1") != "0";

        if (string.IsNullOrEmpty(id)) { await WriteJson(resp, 400, new { error = "id required" }); return; }
        if (AnalysisEngine.Shared.GetFeatures(id) == null)
        { await WriteJson(resp, 404, new { error = "Track not analysed" }); return; }

        var lib     = RekordboxParser.Shared.Parse();
        var store   = AnalysisEngine.Shared.StoreSnapshot();
        var results = SimilarityEngine.Shared.FindSimilar(id, lib.Tracks, store, Math.Min(limit, 50), useKey);

        await WriteJson(resp, 200, new
        {
            results        = results.Select(r => new
            {
                track = r.Track,
                score = new
                {
                    total    = r.Score.Total,
                    vibe     = r.Score.Vibe,
                    key      = r.Score.Key,
                    harmony  = r.Score.Harmony,
                    tempo    = r.Score.Tempo,
                    metadata = r.Score.Metadata,
                    clap     = r.Score.Clap,
                }
            }),
            source_features = store.GetValueOrDefault(id),
            analyzed_count  = store.Count,
        });
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
