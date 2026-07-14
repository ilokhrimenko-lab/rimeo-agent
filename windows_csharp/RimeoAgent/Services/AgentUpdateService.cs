using System.Text.Json;
using RimeoAgent.Config;

namespace RimeoAgent.Services;

/// Результат POST /api/agent/update. Осмысленно ровно одно состояние:
/// AlreadyRunning → уже обновляемся; Error != null → проверка сорвалась (сеть);
/// Info == null → уже последняя версия; Accepted → задача запущена.
public sealed record UpdateStartResult(bool Accepted, bool AlreadyRunning, UpdateInfo? Info, string? Error);

public sealed record UpdateStatus(string Stage, double Progress, string? Error, string? TargetVersion);

/// Состояние самообновления, инициированного по HTTP (телефон → POST /api/agent/update).
/// Стадии: idle → downloading → verifying → installing → restarting.
///
/// "done" в ЭТОМ процессе не наступает никогда: ApplyZip запускает bat-скрипт
/// (xcopy + перезапуск) и делает Environment.Exit(0). Поэтому перед перезапуском на
/// диск синхронно пишется маркер update_result.json, и "done" отдаёт уже НОВЫЙ,
/// обновлённый процесс — сравнив свой билд с записанным в маркере.
public sealed class AgentUpdateService
{
    public static readonly AgentUpdateService Shared = new();

    public const string StageIdle       = "idle";
    public const string StageDownloading = "downloading";
    public const string StageError      = "error";
    public const string StageRestarting = "restarting";
    public const string StageDone       = "done";

    // Маркер старше этого срока — не ответ на текущий запрос телефона, а прошлое
    // обновление: гасим его, чтобы статус не залипал в "done" навсегда.
    private static readonly TimeSpan ResultTtl = TimeSpan.FromMinutes(15);

    private readonly object _lock = new();
    private bool    _running;
    private string  _stage = StageIdle;
    private double  _progress;
    private string? _error;
    private string? _target;

    private static string ResultFile => Path.Combine(AppConfig.Shared.BaseDir, "update_result.json");

    private sealed class UpdateResult
    {
        public string   Tag   { get; set; } = "";
        public int      Build { get; set; }
        public DateTime At    { get; set; }
    }

    /// Проверяет GitHub (блокирующе, таймаут 10 с внутри QueryLatest) и, если есть
    /// строго более новый билд, запускает загрузку+установку в фоне.
    public UpdateStartResult Start()
    {
        lock (_lock)
        {
            if (_running) return new UpdateStartResult(false, true, null, null);
        }

        var info = UpdateChecker.Shared.ForceCheck();
        if (info == null)
            return new UpdateStartResult(false, false, null, UpdateChecker.Shared.LastCheckError);

        lock (_lock)
        {
            if (_running) return new UpdateStartResult(false, true, null, null);
            _running  = true;
            _stage    = StageDownloading;
            _progress = 0;
            _error    = null;
            _target   = info.Version;
        }
        ClearResult();

        Task.Run(() =>
        {
            try
            {
                UpdateChecker.Shared.DownloadAndApply(info, SetProgress, SetStage);
                // Сюда не возвращаемся: ApplyZip завершает процесс.
            }
            catch (Exception ex)
            {
                Log.Error($"Remote update failed: {ex.Message}");
                lock (_lock)
                {
                    _running  = false;
                    _stage    = StageError;
                    _progress = 0;
                    _error    = ex.Message;
                }
            }
        });

        return new UpdateStartResult(true, false, info, null);
    }

    public UpdateStatus Status()
    {
        lock (_lock)
        {
            if (_running || _stage == StageError)
                return new UpdateStatus(_stage, _progress, _error, _target);
        }

        var result = ReadResult();
        if (result == null) return new UpdateStatus(StageIdle, 0, null, null);
        if (DateTime.UtcNow - result.At > ResultTtl)
        {
            ClearResult();
            return new UpdateStatus(StageIdle, 0, null, null);
        }

        var current = UpdateChecker.ParseBuild(AppConfig.Shared.BuildNumber);
        if (current >= result.Build)
            return new UpdateStatus(StageDone, 1.0, null, result.Tag);

        // Маркер свежий, а билд не сменился — xcopy не отработал (файлы заняты и т.п.).
        return new UpdateStatus(StageError, 0,
            $"update did not apply (still build {AppConfig.Shared.BuildNumber})", result.Tag);
    }

    private void SetProgress(double p)
    {
        lock (_lock)
        {
            if (_running && _stage == StageDownloading) _progress = Math.Clamp(p, 0, 1);
        }
    }

    private void SetStage(string stage)
    {
        string? target;
        lock (_lock)
        {
            _stage = stage;
            _progress = stage switch
            {
                "verifying"     => 0.90,
                "installing"    => 0.95,
                StageRestarting => 1.00,
                _               => _progress,
            };
            target = _target;
        }
        Log.Info($"Remote update stage: {stage}");

        // Через миллисекунды после "restarting" процесс умрёт (Environment.Exit),
        // поэтому маркер пишем СИНХРОННО — DataStore.Save асинхронный и не успеет.
        if (stage == StageRestarting && !string.IsNullOrEmpty(target)) WriteResult(target!);
    }

    private static void WriteResult(string tag)
    {
        try
        {
            var json = JsonSerializer.Serialize(new UpdateResult
            {
                Tag   = tag,
                Build = UpdateChecker.ParseBuild(tag),
                At    = DateTime.UtcNow,
            });
            File.WriteAllText(ResultFile, json);
        }
        catch (Exception ex) { Log.Warn($"Update result marker write failed: {ex.Message}"); }
    }

    private static UpdateResult? ReadResult()
    {
        try
        {
            return File.Exists(ResultFile)
                ? JsonSerializer.Deserialize<UpdateResult>(File.ReadAllText(ResultFile))
                : null;
        }
        catch { return null; }
    }

    private static void ClearResult()
    {
        try { if (File.Exists(ResultFile)) File.Delete(ResultFile); } catch { }
    }
}
