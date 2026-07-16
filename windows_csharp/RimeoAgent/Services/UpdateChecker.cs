using System.Diagnostics;
using System.IO.Compression;
using System.Runtime.InteropServices;
using System.Runtime.Versioning;
using System.Security.Cryptography.X509Certificates;
using System.Text.Json;
using RimeoAgent.Config;
using RimeoAgent.HttpServer;
using RimeoAgent.Models;

namespace RimeoAgent.Services;

public record UpdateInfo(string Version, string DownloadUrl, string Notes);

public sealed class UpdateChecker
{
    public static readonly UpdateChecker Shared = new();

    private readonly string _stampFile = Path.Combine(AppConfig.Shared.BaseDir, "last_update_check");

    // Причина последней сорвавшейся проверки (сеть / парсинг ответа GitHub). null —
    // проверка прошла (в т.ч. когда обновлений просто нет). Нужна, чтобы HTTP-ручка
    // не выдавала сетевой сбой за "up to date": QueryLatest глотает исключения.
    public string? LastCheckError { get; private set; }

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

    // Trailing run of digits: "win-v1.0-build183" -> 183, "183" -> 183, "dev" -> 0.
    internal static int ParseBuild(string? s)
    {
        if (string.IsNullOrEmpty(s)) return 0;
        int i = s.Length;
        while (i > 0 && char.IsDigit(s[i - 1])) i--;
        return int.TryParse(s[i..], out var n) ? n : 0;
    }

    private UpdateInfo? QueryLatest()
    {
        var repo = AppConfig.GithubRepo;
        // Iterate ALL releases and pick the highest BUILD NUMBER that ships a
        // Windows asset. GitHub's /releases/latest is ordered by publish date and
        // is unreliable when mac/win release tags interleave — it once advertised
        // an OLDER build (lower number) as "latest" and prompted a downgrade.
        var url = $"https://api.github.com/repos/{repo}/releases?per_page=50";
        LastCheckError = null;
        try
        {
            using var http = new HttpClient();
            http.DefaultRequestHeaders.TryAddWithoutValidation("User-Agent",
                $"RimeoAgentWin/{AppConfig.Shared.Version}");
            using var cts = new CancellationTokenSource(TimeSpan.FromSeconds(10));
            var json = http.GetStringAsync(url, cts.Token).GetAwaiter().GetResult();
            var releases = JsonSerializer.Deserialize<List<Dictionary<string, JsonElement>>>(json);
            if (releases == null) return null;

            // arm64 build ships its own zip; x64 keeps the historical name.
            var assetName = RuntimeInformation.ProcessArchitecture == Architecture.Arm64
                ? "RimeoAgent_win-arm64.zip"
                : "RimeoAgent_win.zip";

            int currentBuild = ParseBuild(AppConfig.Shared.BuildNumber);
            int bestBuild = currentBuild;
            string bestTag = "", bestUrl = "", bestNotes = "";

            foreach (var rel in releases)
            {
                if (rel.TryGetValue("draft", out var d) && d.ValueKind == JsonValueKind.True) continue;
                if (rel.TryGetValue("prerelease", out var p) && p.ValueKind == JsonValueKind.True) continue;
                var tag = rel.TryGetValue("tag_name", out var t) ? t.GetString() ?? "" : "";
                int b = ParseBuild(tag);
                if (b <= bestBuild) continue;   // only ever offer a strictly newer build

                string dlUrl = "";
                if (rel.TryGetValue("assets", out var assets) && assets.ValueKind == JsonValueKind.Array)
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
                if (string.IsNullOrEmpty(dlUrl)) continue;   // mac releases lack a win asset → skip

                bestBuild = b;
                bestTag = tag;
                bestUrl = dlUrl;
                bestNotes = rel.TryGetValue("body", out var bodyEl) ? bodyEl.GetString() ?? "" : "";
            }

            if (string.IsNullOrEmpty(bestTag) || bestBuild <= currentBuild) return null;
            if (bestNotes.Length > 400) bestNotes = bestNotes[..400];
            Log.Info($"Update available: build{currentBuild} → build{bestBuild} ({bestTag})");
            return new UpdateInfo(bestTag, bestUrl, bestNotes);
        }
        catch (Exception ex)
        {
            LastCheckError = ex.Message;
            return null;
        }
    }

    // ── Silent staging (hourly check downloads in background; apply on next launch) ──

    private static string StagedZipPath => Path.Combine(AppConfig.Shared.BaseDir, "staged_update.zip");

    // Hourly background check: if a strictly-newer build is available, download its
    // zip to a staging file and record the tag. No UI — installed on next launch.
    public void CheckAndStageSilently()
    {
        try
        {
            var info = QueryLatest();
            if (info == null) return;
            if (DataStore.Shared.Data.StagedUpdateTag == info.Version && File.Exists(StagedZipPath)) return;
            DownloadZip(info, StagedZipPath, _ => { });
            DataStore.Shared.Update(d => d.StagedUpdateTag = info.Version);
            Log.Info($"Staged silent update: {info.Version}");
        }
        catch (Exception ex) { Log.Warn($"Silent update staging failed: {ex.Message}"); }
    }

    // Called at launch before the UI: if a staged build is ready and strictly newer
    // than the running one, install it (xcopy+restart). Returns true when applying.
    public bool ApplyStagedUpdateIfPresent()
    {
        var tag = DataStore.Shared.Data.StagedUpdateTag;
        if (string.IsNullOrEmpty(tag)) return false;
        if (ParseBuild(tag) <= ParseBuild(AppConfig.Shared.BuildNumber) || !File.Exists(StagedZipPath))
        {
            DataStore.Shared.Update(d => d.StagedUpdateTag = "");
            try { if (File.Exists(StagedZipPath)) File.Delete(StagedZipPath); } catch { }
            return false;
        }
        try
        {
            Log.Info($"Applying staged update {tag} at launch");
            DataStore.Shared.Update(d => d.StagedUpdateTag = "");
            ApplyZip(StagedZipPath);   // xcopy+restart → Environment.Exit(0)
            return true;
        }
        catch (Exception ex)
        {
            Log.Warn($"Applying staged update failed: {ex.Message}");
            try { File.Delete(StagedZipPath); } catch { }
            return false;
        }
    }

    // Manual "Update now" flow: download + apply immediately.
    // `stage` (optional) reports the coarse phase — verifying / installing / restarting —
    // for the HTTP status endpoint; the UI button passes only `progress`.
    public void DownloadAndApply(UpdateInfo info, Action<double> progress, Action<string>? stage = null)
    {
        var tmp = Path.Combine(Path.GetTempPath(), $"rimeo_upd_{Guid.NewGuid():N}");
        Directory.CreateDirectory(tmp);
        try
        {
            var zipPath = Path.Combine(tmp, "update.zip");
            DownloadZip(info, zipPath, p => progress(Math.Min(0.85, p * 0.85)));
            progress(0.9);
            ApplyZip(zipPath, stage);   // restarts → Environment.Exit(0)
        }
        catch
        {
            try { Directory.Delete(tmp, true); } catch { }
            throw;
        }
    }

    private static void DownloadZip(UpdateInfo info, string dest, Action<double> progress)
    {
        using var http = new HttpClient();
        http.DefaultRequestHeaders.TryAddWithoutValidation("User-Agent",
            $"RimeoAgentWin/{AppConfig.Shared.Version}");
        using var cts = new CancellationTokenSource(TimeSpan.FromMinutes(5));
        Directory.CreateDirectory(Path.GetDirectoryName(dest)!);
        using var resp = http.GetAsync(info.DownloadUrl, HttpCompletionOption.ResponseHeadersRead, cts.Token).GetAwaiter().GetResult();
        resp.EnsureSuccessStatusCode();
        var total = resp.Content.Headers.ContentLength ?? -1L;
        using var src = resp.Content.ReadAsStreamAsync(cts.Token).GetAwaiter().GetResult();
        using var fileOut = File.Create(dest);
        var buf = new byte[81920];
        long received = 0;
        int read;
        while ((read = src.Read(buf, 0, buf.Length)) > 0)
        {
            fileOut.Write(buf, 0, read);
            received += read;
            if (total > 0) progress(received / (double)total);
        }
        fileOut.Flush();

        // 6005: fetch the detached signature next to the archive. Best-effort — a
        // missing .sig makes ApplyZip's fail-closed check reject the update.
        DownloadSignatureBestEffort(info.DownloadUrl + ".sig", dest + ".sig");
    }

    private static void DownloadSignatureBestEffort(string sigUrl, string sigDest)
    {
        try
        {
            using var http = new HttpClient();
            http.DefaultRequestHeaders.TryAddWithoutValidation("User-Agent",
                $"RimeoAgentWin/{AppConfig.Shared.Version}");
            using var cts = new CancellationTokenSource(TimeSpan.FromSeconds(60));
            using var resp = http.GetAsync(sigUrl, cts.Token).GetAwaiter().GetResult();
            if (!resp.IsSuccessStatusCode) return;
            var bytes = resp.Content.ReadAsByteArrayAsync(cts.Token).GetAwaiter().GetResult();
            File.WriteAllBytes(sigDest, bytes);
        }
        catch (Exception ex) { Log.Warn($"Update signature download failed: {ex.Message}"); }
    }

    // Extract zip → xcopy over the install dir + restart via a detached hidden bat → exit.
    private static void ApplyZip(string zipPath, Action<string>? stage = null)
    {
        // Стадия «verifying» держится, пока идут ОБЕ проверки подписи (detached ES256
        // на архив + Authenticode на распакованный бинарь), и снимается только после
        // них — ровно как на macOS. Распаковка тоже внутри «verifying»: проверять
        // подпись exe можно только после того, как он оказался на диске, но до того,
        // как мы тронули установленный агент.
        stage?.Invoke("verifying");

        // 6005: verify the archive's detached ECDSA-P256/SHA-256 signature with the
        // baked update public key BEFORE extracting. Fail-closed — a missing or
        // invalid .sig aborts the update. Identical check runs on macOS.
        UpdateSignatureVerifier.VerifyZipSignature(zipPath, zipPath + ".sig");
        Log.Info("Update archive signature verified (detached ES256)");

        var tmp = Path.Combine(Path.GetTempPath(), $"rimeo_apply_{Guid.NewGuid():N}");
        var extDir = Path.Combine(tmp, "ext");
        Directory.CreateDirectory(extDir);
        ZipFile.ExtractToDirectory(zipPath, extDir);

        var exeFiles = Directory.GetFiles(extDir, "RimeoAgent.exe", SearchOption.AllDirectories);
        if (exeFiles.Length == 0) throw new Exception("RimeoAgent.exe not found in archive");
        var newDir = Path.GetDirectoryName(exeFiles[0])!;

        // 6005, вторая линия обороны: Authenticode на РАСПАКОВАННОМ бинаре, аналог
        // macOS-ветки (codesign --verify --deep --strict + сверка TeamID MM3Q8TJL85).
        // Подпись архива защищает от подмены на GitHub, но не от компрометации самого
        // ключа релиза; подпись бинаря — вторым, независимым ключом — защищает и от неё.
        // Бросает → xcopy ниже не выполняется, установленный агент остаётся жив.
        AuthenticodeGate.VerifyExtractedBuild(newDir);

        stage?.Invoke("installing");
        var script = Path.Combine(tmp, "update.bat");
        var current = AppContext.BaseDirectory.TrimEnd('\\');
        var newDirEsc = newDir.TrimEnd('\\');
        // Перезапуск в том же режиме: агент, поднятый автозапуском (--background),
        // после обновления не должен вылезти окном на передний план.
        var relaunchArgs = AgentSettings.LaunchedInBackground ? $" {AgentSettings.BackgroundFlag}" : "";
        File.WriteAllText(script, $@"@echo off
timeout /t 2 /nobreak > nul
xcopy /E /Y /I ""{newDirEsc}\*"" ""{current}\""
start """" ""{Path.Combine(current, "RimeoAgent.exe")}""{relaunchArgs}
");
        try { if (File.Exists(StagedZipPath)) File.Delete(StagedZipPath); } catch { }
        // Launch the updater hidden — no console window flashes for the user.
        // Всё, что должно пережить обновление, надо записать ДО этого момента:
        // сразу после Process.Start процесс умирает.
        stage?.Invoke("restarting");
        Process.Start(new ProcessStartInfo("cmd.exe", $"/c \"{script}\"")
        {
            UseShellExecute = false,
            CreateNoWindow = true,
            WindowStyle = ProcessWindowStyle.Hidden
        });
        Environment.Exit(0);
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

/// <summary>
/// 6005, вторая линия обороны: Authenticode-проверка распакованного бинаря перед тем,
/// как он перезатрёт установленного агента. Windows-аналог macOS-связки
/// `codesign --verify --deep --strict` (целостность) + `TeamIdentifier == MM3Q8TJL85`
/// (издатель) из UpdateSignatureVerifier.verify(appPath:).
/// </summary>
///
/// ⚠️ ЧЕСТНО ПРО ТЕКУЩЕЕ СОСТОЯНИЕ CI. На момент написания Windows-.exe НЕ подписывается
/// вообще: в .github/workflows/build.yml джоба build-windows — это publish →
/// Compress-Archive → NSIS, и ни signtool, ни какого-либо Authenticode-сертификата там
/// нет (codesign есть только у macOS-джобы). Поэтому безусловная fail-closed проверка
/// МГНОВЕННО убила бы автообновление у всех уже установленных Windows-агентов: свежий
/// релиз приезжал бы неподписанным и отвергался.
///
/// Отсюда САМО-ЯКОРНАЯ (trust-on-current-install) схема: проверка включается пофайлово и
/// только тогда, когда УЖЕ УСТАНОВЛЕННЫЙ файл сам подписан. Правило: «если мы подписаны —
/// новый обязан быть подписан тем же издателем». Пока CI не подписывает, якоря нет и гейт
/// молчит (единственным анкором остаётся ES256-подпись архива). В тот день, когда в CI
/// появится signtool, первый подписанный билд приедет ещё под молчащим гейтом, а начиная
/// со следующего гейт включится сам — без правок кода и без окна, в котором он ломает
/// апдейт. Хотите зафиксировать издателя жёстко и раньше — впишите его DN в
/// <see cref="ExpectedSubjectPin"/>: непустой пин делает проверку безусловной.
internal static class AuthenticodeGate
{
    // Жёсткий пин издателя (Subject DN сертификата подписи, например
    // "CN=Rimeo, O=Rimeo, L=..., C=..."). Пусто = якорь берём с установленного файла
    // (см. блок выше). Пинить имеет смысл именно Subject, а не Thumbprint: отпечаток
    // меняется при плановом перевыпуске сертификата и убил бы апдейт на ровном месте,
    // тогда как DN переживает перевыпуск — это и есть аналог стабильного TeamID.
    public const string ExpectedSubjectPin = "";

    // В self-contained .NET-публикации RimeoAgent.exe — лишь apphost-шим, а ВЕСЬ наш код
    // лежит в RimeoAgent.dll. Проверять только .exe значит проверять обёртку, поэтому в
    // списке оба. Само-якорь пофайловый: если CI начнёт подписывать (как обычно и бывает)
    // сначала только .exe — dll просто останется без якоря и не свалит апдейт.
    private static readonly string[] GuardedFiles = { "RimeoAgent.exe", "RimeoAgent.dll" };

    /// <summary>Бросает <see cref="UpdateSignatureException"/>, если распакованный билд
    /// не проходит проверку. Молчит (no-op), пока якоря нет — см. блок выше.</summary>
    public static void VerifyExtractedBuild(string newDir)
    {
        // Агент существует только под Windows, но чистая логика этого проекта headless-ом
        // компилируется и на macOS. wintrust.dll / CreateFromSignedFile там просто нет,
        // поэтому гард обязателен (заодно он гасит CA1416 для аннотаций ниже).
        if (!OperatingSystem.IsWindows()) return;

        var installDir = AppContext.BaseDirectory;   // ровно та папка, которую перезатрёт xcopy
        bool hardPin = ExpectedSubjectPin.Length > 0;

        foreach (var name in GuardedFiles)
        {
            var newFile = Path.Combine(newDir, name);
            var curFile = Path.Combine(installDir, name);

            string? expected = ExpectedSubjectPin;
            if (!hardPin)
            {
                expected = File.Exists(curFile) ? SignerSubject(curFile) : null;
                if (expected is null)
                {
                    Log.Info($"Authenticode gate inactive for {name}: the installed copy is unsigned " +
                             "(CI does not run signtool on Windows builds yet) — the archive's ES256 " +
                             "signature stays the only anchor");
                    continue;
                }
            }

            if (!File.Exists(newFile))
            {
                // Мы подписаны, а в архиве этого файла нет — либо архив битый, либо кто-то
                // выкинул подписанный бинарь. Fail-closed: молча ставить такое нельзя.
                throw new UpdateSignatureException(
                    $"Update archive is missing {name}, which is signed in the current install");
            }

            VerifyFile(newFile, expected!);
            Log.Info($"Update binary signature verified: {name} (publisher {expected})");
        }
    }

    [SupportedOSPlatform("windows")]
    private static void VerifyFile(string path, string expectedSubject)
    {
        var name = Path.GetFileName(path);

        // 1) Целостность + доверие к цепочке — аналог `codesign --verify --strict`.
        //    Обязательно ДО сверки издателя: CreateFromSignedFile ниже достаёт сертификат
        //    из Authenticode-блока, но САМА НИЧЕГО НЕ ПРОВЕРЯЕТ — ни хэш PE, ни цепочку.
        //    Без WinVerifyTrust можно было бы приклеить валидный блок подписи от honest-
        //    билда к произвольному exe, и сверка Subject это проглотила бы.
        int rc = WinVerifyTrustFile(path);
        if (rc != 0)
        {
            throw new UpdateSignatureException(
                $"Update binary failed Authenticode verification: {name} " +
                $"(WinVerifyTrust 0x{rc:X8} — {DescribeTrustError(rc)})");
        }

        // 2) Издатель — аналог сверки TeamIdentifier == MM3Q8TJL85. Доверенной цепочки мало:
        //    валидный сертификат может купить кто угодно, поэтому нужен именно НАШ издатель.
        var subject = SignerSubject(path);
        if (subject is null)
            throw new UpdateSignatureException($"Update binary is not signed: {name}");

        if (!string.Equals(subject, expectedSubject, StringComparison.Ordinal))
        {
            throw new UpdateSignatureException(
                $"Update binary signed by an untrusted publisher: {name} " +
                $"(got \"{subject}\", expected \"{expectedSubject}\")");
        }
    }

    /// <summary>Subject DN сертификата подписанта, либо null — если файл не подписан.</summary>
    [SupportedOSPlatform("windows")]
    private static string? SignerSubject(string path)
    {
        try
        {
            // CreateFromSignedFile бросает, если Authenticode-блока нет вовсе.
            using var cert = X509Certificate.CreateFromSignedFile(path);
            var subject = cert.Subject?.Trim();
            return string.IsNullOrEmpty(subject) ? null : subject;
        }
        catch
        {
            // Не подписан / блок не разбирается. Для якоря это «нет якоря», для проверяемого
            // файла VerifyFile всё равно уже упал бы на WinVerifyTrust — так что null безопасен.
            return null;
        }
    }

    // ── WinVerifyTrust (wintrust.dll) ────────────────────────────────────────────────

    private static readonly Guid WinTrustActionGenericVerifyV2 =
        new("00AAC56B-CD44-11D0-8CC2-00C04FC295EE");

    private const uint WTD_UI_NONE                 = 2;
    private const uint WTD_REVOKE_NONE             = 0;
    private const uint WTD_CHOICE_FILE             = 1;
    private const uint WTD_STATEACTION_VERIFY      = 1;
    private const uint WTD_STATEACTION_CLOSE       = 2;
    private const uint WTD_SAFER_FLAG              = 0x00000100;
    private const uint WTD_CACHE_ONLY_URL_RETRIEVAL = 0x00001000;

    [SupportedOSPlatform("windows")]
    private static int WinVerifyTrustFile(string path)
    {
        var fileInfo = new WINTRUST_FILE_INFO
        {
            cbStruct      = (uint)Marshal.SizeOf<WINTRUST_FILE_INFO>(),
            pcwszFilePath = Marshal.StringToHGlobalUni(path),
            hFile         = IntPtr.Zero,
            pgKnownSubject = IntPtr.Zero,
        };
        IntPtr pFile = Marshal.AllocHGlobal(Marshal.SizeOf<WINTRUST_FILE_INFO>());

        try
        {
            Marshal.StructureToPtr(fileInfo, pFile, false);

            var data = new WINTRUST_DATA
            {
                cbStruct       = (uint)Marshal.SizeOf<WINTRUST_DATA>(),
                dwUIChoice     = WTD_UI_NONE,
                // Отзыв не проверяем: агент обновляется в том числе на машинах без
                // интернета к CRL/OCSP, а поход в сеть за списком отзыва либо висел бы
                // таймаутом, либо (fail-open по природе CRL) всё равно ничего не гарантировал.
                // macOS-ветка codesign --verify тоже не ходит в сеть за отзывом.
                fdwRevocationChecks = WTD_REVOKE_NONE,
                dwUnionChoice  = WTD_CHOICE_FILE,
                pFile          = pFile,
                dwStateAction  = WTD_STATEACTION_VERIFY,
                dwProvFlags    = WTD_SAFER_FLAG | WTD_CACHE_ONLY_URL_RETRIEVAL,
                dwUIContext    = 0,
            };

            var action = WinTrustActionGenericVerifyV2;
            // hwnd = INVALID_HANDLE_VALUE (-1) — канонический «никакого UI»; агент часто
            // обновляется в фоне (--background), диалог доверия там показать некому.
            var noUi = new IntPtr(-1);

            int rc;
            try
            {
                rc = WinVerifyTrust(noUi, ref action, ref data);
            }
            finally
            {
                // Состояние закрываем всегда, иначе wintrust течёт хэндлами на каждой проверке.
                data.dwStateAction = WTD_STATEACTION_CLOSE;
                try { WinVerifyTrust(noUi, ref action, ref data); } catch { }
            }
            return rc;
        }
        catch (Exception ex) when (ex is DllNotFoundException or EntryPointNotFoundException)
        {
            // wintrust.dll есть на любой живой Windows. Если его нет — среда сломана или
            // подменена; проверку в таком случае НЕ пропускаем (fail-closed).
            throw new UpdateSignatureException($"Authenticode verification unavailable: {ex.Message}");
        }
        finally
        {
            Marshal.FreeHGlobal(fileInfo.pcwszFilePath);
            Marshal.FreeHGlobal(pFile);
        }
    }

    private static string DescribeTrustError(int rc) => (uint)rc switch
    {
        0x800B0100 => "no Authenticode signature",
        0x800B0101 => "signing certificate expired",
        0x800B0109 => "untrusted root",
        0x800B010C => "signing certificate revoked",
        0x80096010 => "bad digest — the binary was modified after signing",
        0x800B0004 => "subject not trusted for this action",
        _          => "signature is invalid or untrusted",
    };

    [StructLayout(LayoutKind.Sequential)]
    private struct WINTRUST_FILE_INFO
    {
        public uint   cbStruct;
        public IntPtr pcwszFilePath;   // LPCWSTR; маршалим руками, чтобы владеть временем жизни
        public IntPtr hFile;
        public IntPtr pgKnownSubject;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct WINTRUST_DATA
    {
        public uint   cbStruct;
        public IntPtr pPolicyCallbackData;
        public IntPtr pSIPClientData;
        public uint   dwUIChoice;
        public uint   fdwRevocationChecks;
        public uint   dwUnionChoice;
        public IntPtr pFile;           // объединение; при WTD_CHOICE_FILE — WINTRUST_FILE_INFO*
        public uint   dwStateAction;
        public IntPtr hWVTStateData;
        public IntPtr pwszURLReference;
        public uint   dwProvFlags;
        public uint   dwUIContext;
        public IntPtr pSignatureSettings;
    }

    [DllImport("wintrust.dll", CharSet = CharSet.Unicode, ExactSpelling = true)]
    [SupportedOSPlatform("windows")]
    private static extern int WinVerifyTrust(IntPtr hwnd, ref Guid pgActionID, ref WINTRUST_DATA pWVTData);
}
