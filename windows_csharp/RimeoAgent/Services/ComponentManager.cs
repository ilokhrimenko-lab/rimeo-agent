using System.Net.Http;
using System.Security.Cryptography;
using System.Text.Json;
using RimeoAgent.Config;

namespace RimeoAgent.Services;

public sealed class ComponentManager
{
    public static readonly ComponentManager Shared = new();

    private static readonly string[] RequiredIds = ["tunnel-runtime", "ffmpeg", "ffprobe"];
    private readonly string _componentsDir;

    private ComponentManager()
    {
        _componentsDir = Path.Combine(AppConfig.Shared.BaseDir, "components");
        Directory.CreateDirectory(_componentsDir);
    }

    public string? FindComponent(string id)
    {
        // 1. Next to the exe (bundled)
        var bundled = Path.Combine(AppContext.BaseDirectory, $"{id}.exe");
        if (File.Exists(bundled)) return bundled;

        // 2. Downloaded components folder
        var downloaded = Path.Combine(_componentsDir, $"{id}.exe");
        if (File.Exists(downloaded)) return downloaded;

        return null;
    }

    public bool AllPresent() => RequiredIds.All(id => FindComponent(id) != null);

    public async Task EnsureAllAsync(Action<string> onProgress)
    {
        if (AllPresent()) return;

        onProgress("Fetching component manifest…");
        RuntimeManifest manifest;
        try
        {
            manifest = await FetchManifestAsync();
        }
        catch (Exception ex)
        {
            Log.Error($"Component manifest fetch failed: {ex.Message}");
            onProgress($"Could not fetch manifest: {ex.Message}");
            return;
        }

        foreach (var comp in manifest.Components)
        {
            if (!RequiredIds.Contains(comp.Id)) continue;
            if (FindComponent(comp.Id) != null) continue;

            onProgress($"Downloading {comp.Id} ({comp.Size / 1_048_576} MB)…");
            try
            {
                await DownloadComponentAsync(comp, onProgress);
                onProgress($"{comp.Id} ready.");
            }
            catch (Exception ex)
            {
                Log.Error($"Failed to download {comp.Id}: {ex.Message}");
                onProgress($"Download failed for {comp.Id}: {ex.Message}");
            }
        }
    }

    private async Task DownloadComponentAsync(ComponentInfo comp, Action<string> onProgress)
    {
        var dest = Path.Combine(_componentsDir, $"{comp.Id}.exe");
        var tmp  = dest + ".tmp";

        using var http   = new HttpClient();
        using var resp   = await http.GetAsync(comp.Url, HttpCompletionOption.ResponseHeadersRead);
        resp.EnsureSuccessStatusCode();

        await using var src     = await resp.Content.ReadAsStreamAsync();
        await using var fileOut = File.Create(tmp);

        var buf       = new byte[81920];
        long received = 0;
        int  read;
        int  lastPct  = -1;

        while ((read = await src.ReadAsync(buf)) > 0)
        {
            await fileOut.WriteAsync(buf.AsMemory(0, read));
            received += read;
            if (comp.Size > 0)
            {
                var pct = (int)(received * 100 / comp.Size);
                if (pct / 10 != lastPct / 10)
                {
                    lastPct = pct;
                    onProgress($"  {comp.Id}: {pct}%");
                }
            }
        }

        fileOut.Close();

        Log.Info($"Download complete for {comp.Id}, verifying checksum…");
        var actual = ComputeSha256(tmp);
        if (!string.Equals(actual, comp.Sha256, StringComparison.OrdinalIgnoreCase))
        {
            File.Delete(tmp);
            throw new Exception($"Checksum mismatch for {comp.Id}: expected {comp.Sha256}, got {actual}");
        }

        Log.Info($"Checksum OK for {comp.Id}, installing…");
        // If "About to move" appears in the log but "Component installed" never does,
        // the process was killed writing the final exe → Windows Defender (ClickUp 4003, hyp. C).
        Log.Info($"About to move {tmp} -> {dest}");
        File.Move(tmp, dest, overwrite: true);
        Log.Info($"Component installed: {comp.Id} → {dest}");
    }

    private static async Task<RuntimeManifest> FetchManifestAsync()
    {
        using var http = new HttpClient();
        http.DefaultRequestHeaders.TryAddWithoutValidation("User-Agent",
            $"RimeoAgentWin/{AppConfig.Shared.Version}");
        var url  = $"{AppConfig.RimeoAppUrl}/api/agent/runtime?platform=win-x64";
        var json = await http.GetStringAsync(url);
        return JsonSerializer.Deserialize<RuntimeManifest>(json,
            new JsonSerializerOptions { PropertyNameCaseInsensitive = true })
            ?? throw new Exception("Empty manifest");
    }

    private static string ComputeSha256(string path)
    {
        using var sha  = SHA256.Create();
        using var file = File.OpenRead(path);
        var hash = sha.ComputeHash(file);
        return Convert.ToHexString(hash).ToLowerInvariant();
    }

    private sealed class RuntimeManifest
    {
        public string Version { get; set; } = "";
        public List<ComponentInfo> Components { get; set; } = [];
    }

    private sealed class ComponentInfo
    {
        public string Id     { get; set; } = "";
        public string Url    { get; set; } = "";
        public string Sha256 { get; set; } = "";
        public long   Size   { get; set; }
    }
}
