using System.Net;
using RimeoAgent.Config;

namespace RimeoAgent.HttpServer;

public sealed class AgentHttpServer
{
    private HttpListener? _listener;
    private bool          _running;
    private readonly ApiRouter _router = new();

    public void Start()
    {
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
        Log.Info($"HTTP server listening on port {AppConfig.Port}");
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

        try
        {
            // CORS for browser requests
            resp.Headers.Add("Access-Control-Allow-Origin", "*");
            resp.Headers.Add("Access-Control-Allow-Methods", "GET, POST, OPTIONS");
            resp.Headers.Add("Access-Control-Allow-Headers", "Content-Type, Range");

            if (req.HttpMethod == "OPTIONS")
            {
                resp.StatusCode = 204;
                resp.Close();
                return;
            }

            var method = req.HttpMethod;
            var rawUrl = req.RawUrl ?? "/";
            var qIdx   = rawUrl.IndexOf('?');
            var path   = qIdx >= 0 ? rawUrl[..qIdx] : rawUrl;
            var query  = qIdx >= 0 ? rawUrl[(qIdx + 1)..] : "";

            var queryParams = ParseQuery(query);
            var headers     = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
            foreach (string? key in req.Headers.AllKeys)
            {
                if (key != null) headers[key] = req.Headers[key] ?? "";
            }

            byte[] body = Array.Empty<byte>();
            if (req.HasEntityBody)
            {
                using var ms = new MemoryStream();
                await req.InputStream.CopyToAsync(ms);
                body = ms.ToArray();
            }

            var agentReq = new AgentRequest(method, path, queryParams, headers, body);
            await _router.RouteAsync(agentReq, resp);
        }
        catch (Exception ex)
        {
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

public record AgentRequest(
    string Method,
    string Path,
    Dictionary<string, string> QueryParams,
    Dictionary<string, string> Headers,
    byte[] Body
);
