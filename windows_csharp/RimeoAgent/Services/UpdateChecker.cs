using System.Diagnostics;
using System.IO.Compression;
using System.Runtime.InteropServices;
using System.Text.Json;
using RimeoAgent.Config;

namespace RimeoAgent.Services;

public record UpdateInfo(string Version, string DownloadUrl, string Notes);

public sealed class UpdateChecker
{
    public static readonly UpdateChecker Shared = new();

    private readonly string _stampFile = Path.Combine(AppConfig.Shared.BaseDir, "last_update_check");

    public void CheckAsync(Action<UpdateInfo?> callback) =>
        Task.Run(() => callback(Check()));

    // Manual "Check for Updates" from the Settings UI — bypasses the 24h throttle.
    public void ForceCheckAsync(Action<UpdateInfo?> callback) =>
        Task.Run(() => callback(ForceCheck()));

    public UpdateInfo? ForceCheck()
    {
        Stamp();
        return QueryLatest();
    }

    public UpdateInfo? Check()
    {
        if (!IsDue) return null;
        Stamp();
        return QueryLatest();
    }

    private UpdateInfo? QueryLatest()
    {
        var repo = AppConfig.GithubRepo;
        var url  = $"https://api.github.com/repos/{repo}/releases/latest";
        try
        {
            using var http = new HttpClient();
            http.DefaultRequestHeaders.TryAddWithoutValidation("User-Agent",
                $"RimeoAgentWin/{AppConfig.Shared.Version}");
            using var cts = new CancellationTokenSource(TimeSpan.FromSeconds(10));
            var json = http.GetStringAsync(url, cts.Token).GetAwaiter().GetResult();
            var obj  = JsonSerializer.Deserialize<Dictionary<string, JsonElement>>(json);
            if (obj == null) return null;

            var tag = obj.TryGetValue("tag_name", out var t) ? t.GetString() ?? "" : "";
            if (string.IsNullOrEmpty(tag) || tag == AppConfig.Shared.ReleaseTag) return null;

            // arm64 build ships its own zip; x64 keeps the historical name.
            var assetName = RuntimeInformation.ProcessArchitecture == Architecture.Arm64
                ? "RimeoAgent_win-arm64.zip"
                : "RimeoAgent_win.zip";
            string dlUrl = "";
            if (obj.TryGetValue("assets", out var assets))
            {
                foreach (var asset in assets.EnumerateArray())
                {
                    var name = asset.TryGetProperty("name", out var n) ? n.GetString() : null;
                    if (name == assetName)
                    {
                        dlUrl = asset.TryGetProperty("browser_download_url", out var u) ? u.GetString() ?? "" : "";
                        break;
                    }
                }
            }
            if (string.IsNullOrEmpty(dlUrl)) return null;

            var notes = obj.TryGetValue("body", out var bodyEl) ? bodyEl.GetString() ?? "" : "";
            if (notes.Length > 400) notes = notes[..400];
            Log.Info($"Update available: {AppConfig.Shared.ReleaseTag} → {tag}");
            return new UpdateInfo(tag, dlUrl, notes);
        }
        catch { return null; }
    }

    public void DownloadAndApply(UpdateInfo info, Action<double> progress)
    {
        var tmp = Path.Combine(Path.GetTempPath(), $"rimeo_upd_{Guid.NewGuid():N}");
        Directory.CreateDirectory(tmp);
        try
        {
            var zipPath = Path.Combine(tmp, "update.zip");
            using var http = new HttpClient();
            http.DefaultRequestHeaders.TryAddWithoutValidation("User-Agent",
                $"RimeoAgentWin/{AppConfig.Shared.Version}");
            using var cts = new CancellationTokenSource(TimeSpan.FromMinutes(5));

            // Stream the download so the UI can show real progress (0 .. 0.85).
            using (var resp = http.GetAsync(info.DownloadUrl, HttpCompletionOption.ResponseHeadersRead, cts.Token).GetAwaiter().GetResult())
            {
                resp.EnsureSuccessStatusCode();
                var total = resp.Content.Headers.ContentLength ?? -1L;
                using var src = resp.Content.ReadAsStreamAsync(cts.Token).GetAwaiter().GetResult();
                using var fileOut = File.Create(zipPath);
                var buf = new byte[81920];
                long received = 0;
                int read;
                while ((read = src.Read(buf, 0, buf.Length)) > 0)
                {
                    fileOut.Write(buf, 0, read);
                    received += read;
                    if (total > 0) progress(Math.Min(0.85, received / (double)total * 0.85));
                }
            }
            progress(0.9);

            var extDir = Path.Combine(tmp, "ext");
            ZipFile.ExtractToDirectory(zipPath, extDir);
            progress(0.97);

            // Find the new executable
            var exeFiles = Directory.GetFiles(extDir, "RimeoAgent.exe", SearchOption.AllDirectories);
            if (exeFiles.Length == 0) throw new Exception("RimeoAgent.exe not found in archive");

            var newExe = exeFiles[0];
            var newDir = Path.GetDirectoryName(newExe)!;

            // Create a bat that replaces files and restarts
            var script = Path.Combine(tmp, "update.bat");
            var current = AppContext.BaseDirectory.TrimEnd('\\');
            var newDirEsc = newDir.TrimEnd('\\');
            File.WriteAllText(script, $@"@echo off
timeout /t 2 /nobreak > nul
xcopy /E /Y /I ""{newDirEsc}\*"" ""{current}\""
start """" ""{Path.Combine(current, "RimeoAgent.exe")}""
");
            progress(1.0);
            // Launch the updater hidden — no console window flashes for the user.
            Process.Start(new ProcessStartInfo("cmd.exe", $"/c \"{script}\"")
            {
                UseShellExecute = false,
                CreateNoWindow = true,
                WindowStyle = ProcessWindowStyle.Hidden
            });
            Environment.Exit(0);
        }
        catch
        {
            try { Directory.Delete(tmp, true); } catch { }
            throw;
        }
    }

    private bool IsDue
    {
        get
        {
            try
            {
                if (!File.Exists(_stampFile)) return true;
                var stamp = DateTime.Parse(File.ReadAllText(_stampFile).Trim());
                return (DateTime.UtcNow - stamp).TotalHours > 24;
            }
            catch { return true; }
        }
    }

    private void Stamp() =>
        File.WriteAllText(_stampFile, DateTime.UtcNow.ToString("O"));
}
