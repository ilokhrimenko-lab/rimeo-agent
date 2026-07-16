using System.Buffers.Binary;
using System.Diagnostics;
using System.Globalization;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;
using RimeoAgent.Config;
using RimeoAgent.Models;

namespace RimeoAgent.Services;

// ФАЗА 6 — SYNC: запись overlay-плейлистов в Rekordbox master.db (порт macOS
// RekordboxWriter.swift, 1:1 по поведению).
//
// Оркестратор. Сама запись живёт во frozen-бинаре `rbdb-sync-helper.exe`
// (PyInstaller + pyrekordbox), потому что корректность записи в master.db держится
// на трёх инвариантах (USN, masterPlaylists6.xml, типы ID), промах по любому из
// которых не падает, а ТИХО ПРОХОДИТ — и Rekordbox отвергает правку позже. Здесь —
// всё, что вокруг записи: барьеры, backup/restore, план, verify, write-back.
//
// Транзакции у pyrekordbox нет (внутри remove_from_playlist свой commit), поэтому
// единственная гарантия атомарности — файловый backup всех трёх файлов БД.

// MARK: - Контракт с rbdb-sync-helper (plan.json / out.json)

/// Одна операция записи. Схема 1:1 с `plan.json` хелпера — snake_case намеренно,
/// это межпроцессная граница, а не C#-API. Хелпер общий с macOS: любое расхождение
/// в именах ключей здесь = молчаливо потерянное поле (Python читает через .get()).
public sealed class SyncOp
{
    /// `create_folder` | `create_playlist` | `membership` | `rename` | `move` | `delete`
    [JsonPropertyName("type")] public string Type { get; set; } = "";

    [JsonPropertyName("rimeo_id")]
    [JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    public string? RimeoId { get; set; }

    [JsonPropertyName("rekordbox_id")]
    [JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    public string? RekordboxId { get; set; }

    [JsonPropertyName("name")]
    [JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    public string? Name { get; set; }

    /// Родитель ещё не существует в базе — он создаётся в этом же прогоне.
    /// Хелпер резолвит его через локальную карту `rimeo_id → новый ID`.
    [JsonPropertyName("parent_rimeo_id")]
    [JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    public string? ParentRimeoId { get; set; }

    /// Родитель уже в базе — резолв строго по ID, НИКОГДА по имени
    /// (Rekordbox допускает одноимённых сиблингов).
    [JsonPropertyName("parent_rekordbox_id")]
    [JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    public string? ParentRekordboxId { get; set; }

    [JsonPropertyName("seq")]
    [JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    public int? Seq { get; set; }

    /// Желаемое КОНЕЧНОЕ состояние состава. Не список операций: дельту хелпер
    /// считает сам, из живого чтения БД (единственная защита от дублей).
    [JsonPropertyName("desired")]
    [JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    public List<string>? Desired { get; set; }
}

public sealed class SyncPlan
{
    [JsonPropertyName("ops")] public List<SyncOp> Ops { get; set; } = new();
}

/// Результат одной op из `out.json`. Всё, кроме `ok`, опционально: хелпер кладёт
/// `rekordbox_id` только при успехе, `reason` — только при отказе.
public sealed class SyncOpResult
{
    [JsonPropertyName("rimeo_id")]     public string? RimeoId     { get; set; }
    [JsonPropertyName("rekordbox_id")] public string? RekordboxId { get; set; }
    [JsonPropertyName("ok")]           public bool    Ok          { get; set; }
    [JsonPropertyName("added")]        public int?    Added       { get; set; }
    [JsonPropertyName("removed")]      public int?    Removed     { get; set; }
    [JsonPropertyName("reordered")]    public int?    Reordered   { get; set; }
    [JsonPropertyName("reason")]       public string? Reason      { get; set; }
    /// Треки из `desired`, которых нет в базе (их просто пропустили).
    [JsonPropertyName("skipped")]      public List<string>? Skipped { get; set; }
}

/// `out.json` целиком.
public sealed class SyncHelperOutput
{
    [JsonPropertyName("ops")]        public List<SyncOpResult> Ops { get; set; } = new();
    [JsonPropertyName("usn_before")] public long? UsnBefore { get; set; }
    [JsonPropertyName("usn_after")]  public long? UsnAfter  { get; set; }
    /// USN обязан сдвинуться, если что-то писали. Не сдвинулся → Rekordbox
    /// правку отвергнет; для нас это провал, а не успех.
    [JsonPropertyName("usn_advanced")] public bool? UsnAdvanced { get; set; }
}

// MARK: - Результат sync (наружу, в ApiRouter)

public sealed class SyncedPlaylist
{
    public string  RimeoId     { get; }
    public string? RekordboxId { get; }
    /// "synced" | "pending" (правка прилетела во время sync) | "deleted"
    public string  SyncState   { get; }

    public SyncedPlaylist(string rimeoId, string? rekordboxId, string syncState)
    {
        RimeoId = rimeoId; RekordboxId = rekordboxId; SyncState = syncState;
    }
}

public sealed class FailedPlaylist
{
    public string? RimeoId { get; }
    public string  Reason  { get; }

    public FailedPlaylist(string? rimeoId, string reason) { RimeoId = rimeoId; Reason = reason; }
}

public sealed class SyncCounts
{
    public int Created   { get; set; }
    public int Updated   { get; set; }
    public int Deleted   { get; set; }
    public int Added     { get; set; }
    public int Removed   { get; set; }
    public int Reordered { get; set; }

    public Dictionary<string, int> Json => new()
    {
        ["created"] = Created, ["updated"] = Updated, ["deleted"] = Deleted,
        ["added"]   = Added,   ["removed"] = Removed, ["reordered"] = Reordered,
    };
}

/// Единственный тип, который ApiRouter отдаёт наружу:
/// `WriteJson(resp, result.Status, result.Body)`.
public sealed class SyncResult
{
    public int Status { get; set; } = 200;

    /// Машинный код отказа: `sync_in_progress` | `rekordbox_running` |
    /// `ambiguous_path` | `db_unavailable` | `helper_unavailable` |
    /// `backup_failed` | `write_failed` | `write_verify_failed` | `usn_not_advanced`.
    public string? Error  { get; set; }
    public string? Detail { get; set; }

    /// Нечего синкать — идемпотентный успех, а не ошибка.
    public bool Nothing { get; set; }

    public List<SyncedPlaylist> Synced { get; set; } = new();
    public List<FailedPlaylist> Failed { get; set; } = new();
    public SyncCounts Counts { get; set; } = new();

    public bool Ok => Error == null;

    public Dictionary<string, object> Body
    {
        get
        {
            var dict = new Dictionary<string, object>
            {
                ["status"] = Error == null ? "ok" : "error",
                ["synced"] = Synced.Select(s =>
                {
                    var d = new Dictionary<string, object>
                    {
                        ["rimeo_id"]   = s.RimeoId,
                        ["sync_state"] = s.SyncState,
                    };
                    if (!string.IsNullOrEmpty(s.RekordboxId)) d["rekordbox_id"] = s.RekordboxId!;
                    return d;
                }).ToList(),
                ["failed"] = Failed.Select(f =>
                {
                    var d = new Dictionary<string, object> { ["reason"] = f.Reason };
                    if (f.RimeoId != null) d["rimeo_id"] = f.RimeoId;
                    return d;
                }).ToList(),
                ["counts"] = Counts.Json,
            };
            if (Nothing) dict["nothing"] = true;
            if (Error != null) dict["error"] = Error;
            if (!string.IsNullOrEmpty(Detail)) dict["detail"] = Detail!;
            return dict;
        }
    }

    public static SyncResult Failure(string code, int status,
                                     string? detail = null,
                                     List<FailedPlaylist>? failed = null)
        => new() { Status = status, Error = code, Detail = detail, Failed = failed ?? new() };

    public static SyncResult NothingToDo => new() { Nothing = true };
}

/// Снимок прогресса для GET /api/playlist/sync/status.
/// Стадии ровно те, что реально происходят — не декоративные: телефон их показывает.
/// ⚠️ Добавляешь шаг — правь и StageTotal, иначе прогресс-бар соврёт.
public sealed class SyncProgress
{
    public bool    Active       { get; set; }
    public string  Stage        { get; set; } = "idle";   // checking | backup | writing | verifying | done | error
    public int     StageIndex   { get; set; }
    public int     StageTotal   { get; set; } = 4;
    public int     TracksDone   { get; set; }
    public int     TracksTotal  { get; set; }
    public string  PlaylistName { get; set; } = "";
    public string? Error        { get; set; }

    public SyncProgress Clone() => new()
    {
        Active = Active, Stage = Stage, StageIndex = StageIndex, StageTotal = StageTotal,
        TracksDone = TracksDone, TracksTotal = TracksTotal,
        PlaylistName = PlaylistName, Error = Error,
    };
}

// MARK: - Барьер 1: Rekordbox запущен?

public static class RekordboxProcess
{
    /// Имена процессов Rekordbox на Windows. Сравнение регистронезависимое: имя в
    /// таблице процессов приходит из имени файла на диске, а его регистр между
    /// версиями инсталлятора менялся.
    private static readonly string[] Names =
    {
        "rekordbox", "rekordboxAgent", "rekordboxAgentX",
    };

    /// Детект ДО backup'а: нашли процесс — сразу понятный 409, не трогая базу и не
    /// плодя снимок.
    ///
    /// ⚠️ FAIL-CLOSED ПРИ ОТКАЗЕ ПЕРЕЧИСЛЕНИЯ. Раньше здесь при исключении
    /// возвращалось (false) — «Rekordbox не запущен» — в расчёте на то, что дальше
    /// подстрахует lock-probe хелпера. Это НЕВЕРНО: master.db у Rekordbox 6 в
    /// WAL-режиме, а в WAL читатель НЕ держит write-lock, и `BEGIN IMMEDIATE` спокойно
    /// возьмётся, пока Rekordbox ОТКРЫТ и просто ничего не пишет. То есть lock-probe
    /// ловит только АКТИВНУЮ запись, а «Rekordbox запущен и простаивает» ловит ИМЕННО
    /// этот барьер. Ослабив его до fail-open, мы бы при сбое перечисления сняли бэкап и
    /// начали писать в базу под открытым Rekordbox — и он затер бы наши правки своим
    /// состоянием (а то и порвал файл). Поэтому не смогли проверить — считаем, что
    /// ЗАПУЩЕН, и отдаём понятный 409: пусть пользователь закроет Rekordbox и повторит.
    public static (bool Running, string? Who) IsRunning()
    {
        Process[] procs;
        try { procs = Process.GetProcesses(); }
        catch (Exception ex)
        {
            Log.Warn($"sync: process enumeration failed ({ex.Message}) — fail-closed, treating Rekordbox as running");
            return (true, "unknown (process enumeration failed)");
        }

        string? exact = null;
        string? fuzzy = null;
        try
        {
            foreach (var p in procs)
            {
                string name;
                // ProcessName у процесса, умершего между снимком и чтением, бросает.
                try { name = p.ProcessName; } catch { continue; }
                if (string.IsNullOrEmpty(name)) continue;

                if (exact == null &&
                    Names.Any(n => string.Equals(n, name, StringComparison.OrdinalIgnoreCase)))
                {
                    exact = name;
                    break;
                }
                // Мягкий фолбэк — на осиротевший rekordboxAgent или новое имя из
                // будущей версии («rekordbox 7» и т.п.).
                if (fuzzy == null && name.StartsWith("rekordbox", StringComparison.OrdinalIgnoreCase))
                    fuzzy = name;
            }
        }
        finally
        {
            foreach (var p in procs) { try { p.Dispose(); } catch { } }
        }

        var who = exact ?? fuzzy;
        return (who != null, who);
    }
}

// MARK: - SyncEngine

public sealed class RekordboxWriter
{
    public static readonly RekordboxWriter Shared = new();

    /// Два Sync никогда не идут параллельно. Второй запрос при этом НЕ ждёт в
    /// очереди — он сразу получает 409 sync_in_progress (double-tap кнопки /
    /// авто-ретрай релея не должны прогнать план дважды).
    private readonly object _runLock    = new();
    private readonly object _flightLock = new();
    private bool _inFlight;

    private const int MaxBackups = 5;

    private const string HelperName = "rbdb-sync-helper.exe";

    /// Коды, при которых хелпер гарантированно НЕ ТРОНУЛ базу (упал до первой
    /// записи). Restore после них не просто не нужен — он ОПАСЕН: при
    /// `rekordbox_running` база открыта живым Rekordbox, и подмена файлов под ним
    /// и есть та самая порча, ради предотвращения которой стоит барьер.
    private static readonly HashSet<string> PreWriteErrorCodes = new(StringComparer.Ordinal)
    {
        "rekordbox_running", "helper_unavailable", "db_not_found", "db_open_failed",
        "db_path_mismatch", "lock_probe_failed", "bad_plan", "usage",
    };

    /// Умеет ли текущий rbdb-sync-helper op `move`. См. AppendMove().
    /// `static readonly`, а не `const`: с const компилятор объявил бы тело AppendMove
    /// недостижимым (CS0162) — предупреждение, которое хочется чинить удалением кода,
    /// а он тут нужен целиком, ждёт ветки move в хелпере.
    private static readonly bool MoveOpSupported = false;

    private RekordboxWriter() { }

    // MARK: - Прогресс (для честного экрана синка на телефоне)

    private readonly object _progressLock = new();
    private SyncProgress _progress = new();

    public SyncProgress Progress
    {
        get { lock (_progressLock) return _progress.Clone(); }
    }

    private void SetProgress(Action<SyncProgress> mutate)
    {
        lock (_progressLock) mutate(_progress);
    }

    private void Stage(string name, int index) => SetProgress(p =>
    {
        p.Active     = true;
        p.Stage      = name;
        p.StageIndex = index;
    });

    // MARK: Точка входа

    /// `rimeoIds == null` — синкать всё pending. Иначе — только указанные overlay
    /// (+ их pending-родители, иначе ребёнку некуда лечь).
    public SyncResult Sync(IReadOnlyList<string>? rimeoIds = null)
    {
        lock (_flightLock)
        {
            if (_inFlight)
            {
                Log.Info("sync: rejected — already in flight");
                return SyncResult.Failure("sync_in_progress", 409);
            }
            _inFlight = true;
        }

        try
        {
            lock (_runLock) return PerformSync(rimeoIds);
        }
        finally
        {
            lock (_flightLock) _inFlight = false;
        }
    }

    // MARK: Флоу

    private SyncResult PerformSync(IReadOnlyList<string>? rimeoIds)
    {
        // 1. pending
        var pending = DataStore.Shared.PendingSyncOverlays();
        if (rimeoIds != null)
            pending = SelectRequested(rimeoIds, pending, DataStore.Shared.Data.Playlists);

        if (pending.Count == 0)
        {
            Log.Info("sync: nothing pending");
            return SyncResult.NothingToDo;
        }

        SetProgress(p =>
        {
            p.Active       = true;
            p.Stage        = "checking";
            p.StageIndex   = 1;
            p.StageTotal   = 4;
            p.TracksDone   = 0;
            p.TracksTotal  = 0;
            p.PlaylistName = pending[0].Name;
            p.Error        = null;
        });

        // 2. БАРЬЕР 1 — Rekordbox запущен. База не тронута, backup не делаем.
        var rb = RekordboxProcess.IsRunning();
        if (rb.Running)
        {
            Log.Info($"sync: refused — Rekordbox is running ({rb.Who ?? "?"})");
            SetProgress(p => { p.Active = false; p.Stage = "error"; p.Error = "rekordbox_running"; });
            return SyncResult.Failure("rekordbox_running", 409, rb.Who);
        }

        // Источник должен быть master.db: в XML-режиме rekordbox_id нет и писать некуда.
        var cfg    = AppConfig.Shared;
        var dbPath = cfg.DbPath;
        if (!cfg.DbSourceEnabled || string.IsNullOrEmpty(dbPath) || !File.Exists(dbPath))
            return SyncResult.Failure("db_unavailable", 409, "master.db source is off or missing");

        var helper = BundledSyncHelperPath();
        if (helper == null)
        {
            Log.Warn("sync: rbdb-sync-helper not bundled");
            return SyncResult.Failure("helper_unavailable", 500, "rbdb-sync-helper not found");
        }

        // 3. План строим ДО backup: он чистое чтение и может отказать (ambiguous_path) —
        //    не плодим бесполезный снимок базы.
        var lib = RekordboxParser.Shared.Parse();
        var (planned, rejected) = BuildSyncPlan(pending, lib);
        if (rejected != null)
        {
            Log.Warn($"sync: plan rejected — {rejected}");
            return SyncResult.Failure(rejected, 409);
        }
        if (planned!.Plan.Ops.Count == 0)
        {
            Log.Info("sync: plan is empty after filtering");
            return SyncResult.NothingToDo;
        }

        // 4. BACKUP — master.db + -wal + -shm атомарно (все три!). Только .db при
        //    непустом -wal = неконсистентный снимок = битый откат.
        //    Собственный master.backup.db Rekordbox НЕ ТРОГАЕМ — это последняя линия
        //    обороны юзера.
        Stage("backup", 2);
        var backup = MakeBackup(dbPath);
        if (backup == null)
        {
            SetProgress(p => { p.Active = false; p.Stage = "error"; p.Error = "backup_failed"; });
            return SyncResult.Failure("backup_failed", 500, "could not snapshot master.db (+wal/-shm)");
        }
        RotateBackups();

        // 5. ЗАПИСЬ через хелпер. Путь к базе передаём ЯВНО: если path не задан,
        //    pyrekordbox берёт его ИЗ КОНФИГА REKORDBOX — то есть боевую базу
        //    (13.07 так и потеряли библиотеку на «изолированном» прогоне).
        Stage("writing", 3);
        var run = RunHelper(helper, dbPath, planned.Plan);

        if (run.Failure is { } fail)
        {
            if (!PreWriteErrorCodes.Contains(fail.Code)) Restore(backup, dbPath);
            var status = fail.Code == "rekordbox_running" ? 409 : 500;
            Log.Warn($"sync: helper failed — {fail.Code} {fail.Detail ?? ""}");
            SetProgress(p => { p.Active = false; p.Stage = "error"; p.Error = fail.Code; });
            return SyncResult.Failure(fail.Code, status, fail.Detail);
        }

        var output = run.Output!;

        // 6. Ошибка любой op → RESTORE (все 3 файла), LastSyncedHash НЕ двигаем:
        //    overlay останется pending → повтор безопасен.
        if (output.Ops.Count != planned.Plan.Ops.Count)
        {
            Restore(backup, dbPath);
            return SyncResult.Failure("write_failed", 500,
                $"helper returned {output.Ops.Count} results for {planned.Plan.Ops.Count} ops");
        }

        var failedOps = output.Ops.Where(o => !o.Ok).ToList();
        if (failedOps.Count > 0)
        {
            Restore(backup, dbPath);
            var failed = failedOps
                .Select(o => new FailedPlaylist(o.RimeoId, o.Reason ?? "write_failed"))
                .ToList();
            Log.Warn($"sync: {failedOps.Count} op(s) failed → restored backup");
            return SyncResult.Failure("write_failed", 500, failed: failed);
        }

        // Писали, а USN не сдвинулся → Rekordbox эту правку отвергнет. Это «тихий
        // провал», ради ловли которого запись вообще вынесена в pyrekordbox.
        if (ExpectedWrite(planned.Plan, output.Ops) && output.UsnAdvanced == false)
        {
            Restore(backup, dbPath);
            Log.Warn("sync: USN did not advance → restored backup");
            return SyncResult.Failure("usn_not_advanced", 500,
                $"usn {output.UsnBefore?.ToString() ?? "-1"} → {output.UsnAfter?.ToString() ?? "-1"}");
        }

        // 7. VERIFY по перечитанной базе. InvalidateCache() обходит debounce.
        Stage("verifying", 4);
        RekordboxParser.Shared.InvalidateCache();
        var after   = RekordboxParser.Shared.Parse();
        var missing = Verify(planned.Plan, output.Ops, after);
        if (missing != null)
        {
            // Строки могли лечь, но мы их не видим — значит и «Записано» юзеру
            // показывать нельзя. Откатываем: overlay останется pending
            // (RekordboxId не проставлен), повтор безопасен и не задвоит.
            Restore(backup, dbPath);
            RekordboxParser.Shared.InvalidateCache();
            Log.Warn($"sync: verify failed — {missing} not visible after re-parse");
            SetProgress(p => { p.Active = false; p.Stage = "error"; p.Error = "write_verify_failed"; });
            return SyncResult.Failure("write_verify_failed", 500, missing);
        }

        // 8. ТОЛЬКО ПОСЛЕ VERIFY — write-back в DataStore.
        var result = CommitWriteBack(planned, output.Ops);

        // 9. Обновить UI агента. Безопасно с фонового потока: RefreshFromData читает
        //    DataStore под его собственным локом, а каждый сеттер AppState сам
        //    маршалит PropertyChanged в UI-поток через DispatcherQueue (AppState.OnUI).
        AppState.Shared.RefreshFromData();

        var c = result.Counts;
        Log.Info($"sync: ok — created={c.Created} updated={c.Updated} deleted={c.Deleted} "
               + $"added={c.Added} removed={c.Removed} reordered={c.Reordered}");
        SetProgress(p =>
        {
            p.Active     = false;
            p.Stage      = "done";
            p.StageIndex = p.StageTotal;
            p.Error      = null;
        });
        return result;
    }

    // MARK: - Выборка pending

    /// Явно запрошенные overlay + их pending-родители (папку-родителя надо создать
    /// раньше ребёнка, даже если юзер её не выделял).
    private static List<PlaylistOverlay> SelectRequested(IReadOnlyList<string> ids,
                                                         List<PlaylistOverlay> pending,
                                                         List<PlaylistOverlay> all)
    {
        var pendingById = new Dictionary<string, PlaylistOverlay>(StringComparer.Ordinal);
        foreach (var ov in pending) pendingById.TryAdd(ov.RimeoId, ov);

        var allById = new Dictionary<string, PlaylistOverlay>(StringComparer.Ordinal);
        foreach (var ov in all) allById.TryAdd(ov.RimeoId, ov);

        var picked = new HashSet<string>(StringComparer.Ordinal);
        var stack  = new Stack<string>(ids);
        var hops   = 0;
        while (stack.Count > 0 && hops < 10_000)
        {
            hops++;
            var id = stack.Pop();
            if (picked.Contains(id)) continue;
            if (!pendingById.TryGetValue(id, out var ov)) continue;
            picked.Add(id);

            // Родитель нужен только если он сам ещё не в базе.
            var raw = ov.Parent;
            if (string.IsNullOrEmpty(raw)) continue;
            var key = raw!.StartsWith("rmo:", StringComparison.Ordinal) ? raw[4..] : raw;
            if (allById.TryGetValue(key, out var parent) && string.IsNullOrEmpty(parent.RekordboxId))
                stack.Push(parent.RimeoId);
        }

        // Порядок как в pending (стабильный), не как в ids.
        return pending.Where(ov => picked.Contains(ov.RimeoId)).ToList();
    }

    // MARK: - Sync plan

    /// План + снимок overlay, из которых он построен. Снимок нужен для write-back:
    /// подпись штампуем ту, что синкали, а не ту, что могла прилететь во время sync.
    private sealed class PlannedSync
    {
        public SyncPlan Plan { get; init; } = new();
        /// rimeo_id → overlay на момент плана
        public Dictionary<string, PlaylistOverlay> Snapshot { get; init; } = new(StringComparer.Ordinal);
        /// rimeo_id → SyncSignature на момент плана
        public Dictionary<string, string> Signature { get; init; } = new(StringComparer.Ordinal);
    }

    private enum ParentKind { Root, Pending, Existing, Ambiguous }

    private readonly record struct ParentRef(ParentKind Kind, string? Id);

    /// Возвращает (план, null) или (null, машинный код отказа → 409).
    private static (PlannedSync? Planned, string? Rejected) BuildSyncPlan(
        List<PlaylistOverlay> pending, LibraryData lib)
    {
        var baseByRbId = new Dictionary<string, Playlist>(StringComparer.Ordinal);
        var pathCount  = new Dictionary<string, int>(StringComparer.Ordinal);
        var byPath     = new Dictionary<string, Playlist>(StringComparer.Ordinal);
        foreach (var p in lib.Playlists)
        {
            if (!string.IsNullOrEmpty(p.RekordboxId)) baseByRbId[p.RekordboxId!] = p;
            if (string.IsNullOrEmpty(p.Path)) continue;
            pathCount[p.Path] = pathCount.GetValueOrDefault(p.Path) + 1;
            byPath[p.Path]    = p;
        }

        var overlayByRimeoId = new Dictionary<string, PlaylistOverlay>(StringComparer.Ordinal);
        foreach (var ov in DataStore.Shared.Data.Playlists)
            if (!string.IsNullOrEmpty(ov.RimeoId)) overlayByRimeoId[ov.RimeoId] = ov;

        // Smart / history sync не пишет — барьеры мутаций их и так не пускают,
        // это защита от «протёкшего» overlay.
        var syncable = pending.Where(ov =>
        {
            if (string.IsNullOrEmpty(ov.RekordboxId)) return true;
            if (!baseByRbId.TryGetValue(ov.RekordboxId!, out var b)) return true;
            if (b.IsSmart == true || b.History == true)
            {
                Log.Warn($"sync: skipping smart/history playlist {ov.RekordboxId}");
                return false;
            }
            return true;
        }).ToList();

        if (syncable.Count == 0) return (new PlannedSync(), null);

        // Родитель: "rmo:<rimeo_id>" | голый rimeo_id | rekordbox_id | display-path.
        // Резолв всегда сводится к rekordbox_id или к pending-родителю — НИКОГДА к имени.
        ParentRef ResolveParent(string? raw)
        {
            var p = raw?.Trim();
            if (string.IsNullOrEmpty(p)) return new ParentRef(ParentKind.Root, null);

            var key = p.StartsWith("rmo:", StringComparison.Ordinal) ? p[4..] : p;
            if (overlayByRimeoId.TryGetValue(key, out var ov))
            {
                return !string.IsNullOrEmpty(ov.RekordboxId)
                    ? new ParentRef(ParentKind.Existing, ov.RekordboxId)
                    : new ParentRef(ParentKind.Pending, ov.RimeoId);
            }
            if (baseByRbId.ContainsKey(p)) return new ParentRef(ParentKind.Existing, p);
            if (pathCount.TryGetValue(p, out var n))
            {
                if (n > 1) return new ParentRef(ParentKind.Ambiguous, null);   // одноимённые сиблинги
                if (byPath.TryGetValue(p, out var m) && !string.IsNullOrEmpty(m.RekordboxId))
                    return new ParentRef(ParentKind.Existing, m.RekordboxId);
            }
            // Битая ссылка (папку удалили в Rekordbox). Кладём в корень и говорим об
            // этом в лог: плейлист в корне юзер поправит, вечно pending-очередь — нет.
            Log.Warn($"sync: unresolved parent \"{p}\" → root");
            return new ParentRef(ParentKind.Root, null);
        }

        // Топологический порядок среди создаваемых: родитель-папка раньше ребёнка.
        var creates    = syncable.Where(ov => !ov.Deleted && string.IsNullOrEmpty(ov.RekordboxId)).ToList();
        var createById = new Dictionary<string, PlaylistOverlay>(StringComparer.Ordinal);
        foreach (var ov in creates) createById.TryAdd(ov.RimeoId, ov);

        var ordered  = new List<PlaylistOverlay>();
        var visiting = new HashSet<string>(StringComparer.Ordinal);
        var visited  = new HashSet<string>(StringComparer.Ordinal);

        void Visit(PlaylistOverlay ov)
        {
            if (visited.Contains(ov.RimeoId)) return;
            if (!visiting.Add(ov.RimeoId)) return;                 // цикл — рвём
            var pr = ResolveParent(ov.Parent);
            if (pr.Kind == ParentKind.Pending && pr.Id != null
                && createById.TryGetValue(pr.Id, out var parent))
                Visit(parent);
            visiting.Remove(ov.RimeoId);
            visited.Add(ov.RimeoId);
            ordered.Add(ov);
        }
        foreach (var ov in creates) Visit(ov);

        var ops       = new List<SyncOp>();
        var snapshot  = new Dictionary<string, PlaylistOverlay>(StringComparer.Ordinal);
        var signature = new Dictionary<string, string>(StringComparer.Ordinal);
        var ambiguous = false;

        (string? ParentRimeoId, string? ParentRekordboxId) ParentFields(PlaylistOverlay ov)
        {
            var pr = ResolveParent(ov.Parent);
            switch (pr.Kind)
            {
                case ParentKind.Pending:   return (pr.Id, null);
                case ParentKind.Existing:  return (null, pr.Id);
                case ParentKind.Ambiguous: ambiguous = true; return (null, null);
                default:                   return (null, null);
            }
        }

        void Remember(PlaylistOverlay ov)
        {
            snapshot[ov.RimeoId]  = ov;
            signature[ov.RimeoId] = ov.SyncSignature;
        }

        // Перенос уже существующего в базе плейлиста в другую папку. В v6 не
        // отправляется: rbdb-sync-helper знает пять op (create_folder, create_playlist,
        // membership, rename, delete) и на "move" вернёт unknown_op → откат всего
        // батча. Ставить его в план «на вырост» нельзя.
        // Дырой это не становится: эндпоинта, меняющего родителя существующего
        // плейлиста, в агенте нет — parent проставляется только при create и там
        // уезжает в create_folder/create_playlist. Когда в хелпере появится ветка
        // move (db.move_playlist(pl, parent, seq)) — снять гейт.
        void AppendMove(PlaylistOverlay ov, string rb, string? parentRimeoId, string? parentRekordboxId)
        {
            // ReSharper disable once ConditionIsAlwaysTrueOrFalse
            if (!MoveOpSupported)
            {
                Log.Warn($"sync: move of {rb} skipped — helper has no \"move\" op");
                return;
            }
            ops.Add(new SyncOp
            {
                Type = "move", RimeoId = ov.RimeoId, RekordboxId = rb,
                ParentRimeoId = parentRimeoId, ParentRekordboxId = parentRekordboxId,
            });
        }

        // (a) Папки и плейлисты, которых ещё нет в базе — в топо-порядке.
        foreach (var ov in ordered)
        {
            var (prid, prb) = ParentFields(ov);
            Remember(ov);
            ops.Add(ov.IsFolder
                ? new SyncOp
                {
                    Type = "create_folder", RimeoId = ov.RimeoId, Name = ov.Name,
                    ParentRimeoId = prid, ParentRekordboxId = prb,
                }
                : new SyncOp
                {
                    Type = "create_playlist", RimeoId = ov.RimeoId, Name = ov.Name,
                    ParentRimeoId = prid, ParentRekordboxId = prb,
                    Desired = new List<string>(ov.TrackIds),
                });
        }

        // (b) Уже существующие в базе: rename → move → membership.
        foreach (var ov in syncable)
        {
            if (ov.Deleted) continue;
            var rb = ov.RekordboxId;
            if (string.IsNullOrEmpty(rb)) continue;
            if (!baseByRbId.TryGetValue(rb!, out var basePl))
            {
                // ID из overlay нет в базе (плейлист удалили в Rekordbox). Молча
                // пропускаем: пересоздавать не просили, а create дал бы дубль.
                Log.Warn($"sync: overlay {ov.RimeoId} points at missing rekordbox_id {rb} — skipped");
                continue;
            }
            Remember(ov);

            var baseName = DisplayName(basePl);
            if (!string.IsNullOrEmpty(ov.Name) && ov.Name != baseName)
                ops.Add(new SyncOp { Type = "rename", RimeoId = ov.RimeoId, RekordboxId = rb, Name = ov.Name });

            // Move. Два правила, оба важные:
            //
            // 1. Двигаем ТОЛЬКО при явно заданном parent. У overlay, созданного
            //    rename/add/remove, Parent == null — это «не трогать», а НЕ «в корень»:
            //    иначе первый же Sync вынес бы чужие плейлисты из папок в корень.
            // 2. Нерезолвящийся parent (папку снесли в Rekordbox) — тоже НЕ трогаем.
            //    ResolveParent в этом случае отдаёт Root, и наивное «wantParent !=
            //    currentParent» выкинуло бы плейлист в корень на ровном месте.
            if (ov.Parent != null)
            {
                var pr = ResolveParent(ov.Parent);
                switch (pr.Kind)
                {
                    case ParentKind.Existing when pr.Id != (basePl.Parent ?? "root"):
                        AppendMove(ov, rb!, null, pr.Id);
                        break;
                    case ParentKind.Pending:
                        AppendMove(ov, rb!, pr.Id, null);
                        break;
                    case ParentKind.Ambiguous:
                        ambiguous = true;
                        break;
                    default:
                        break;   // уже там / root / нерезолвящийся — не двигаем
                }
            }

            if (!ov.IsFolder)
                ops.Add(new SyncOp
                {
                    Type = "membership", RimeoId = ov.RimeoId, RekordboxId = rb,
                    Desired = new List<string>(ov.TrackIds),
                });
        }

        // (c) Delete — последними, дети раньше родителей (глубина по base-дереву).
        var deletes = syncable
            .Where(ov => ov.Deleted && !string.IsNullOrEmpty(ov.RekordboxId))
            .OrderByDescending(ov => Depth(ov.RekordboxId ?? "", baseByRbId))
            .ToList();
        foreach (var ov in deletes)
        {
            Remember(ov);
            ops.Add(new SyncOp { Type = "delete", RimeoId = ov.RimeoId, RekordboxId = ov.RekordboxId });
        }

        if (ambiguous) return (null, "ambiguous_path");
        return (new PlannedSync
        {
            Plan      = new SyncPlan { Ops = ops },
            Snapshot  = snapshot,
            Signature = signature,
        }, null);
    }

    /// Имя узла = последний сегмент display-path (парсер отдаёт `Name` только у history).
    private static string DisplayName(Playlist p)
    {
        if (!string.IsNullOrEmpty(p.Name)) return p.Name!;
        var parts = p.Path.Split(" / ");
        return parts.Length > 0 ? parts[^1] : p.Path;
    }

    private static int Depth(string rbId, Dictionary<string, Playlist> baseByRbId)
    {
        var d    = 0;
        var cur  = rbId;
        var seen = new HashSet<string>(StringComparer.Ordinal);
        while (baseByRbId.TryGetValue(cur, out var node)
               && !string.IsNullOrEmpty(node.Parent) && node.Parent != "root"
               && !seen.Contains(cur))
        {
            seen.Add(cur);
            cur = node.Parent!;
            d++;
            if (d > 64) break;
        }
        return d;
    }

    // MARK: - Backup / restore (все три файла)

    private sealed class Backup
    {
        public string Dir { get; init; } = "";
        /// Какие суффиксы реально лежали в снимке ("", "-wal", "-shm").
        public List<string> Suffixes { get; init; } = new();
        /// Какие СОСЕДНИЕ файлы реально лежали в снимке (masterPlaylists6.xml).
        public List<string> Siblings { get; init; } = new();
    }

    private static readonly string[] DbSuffixes = { "", "-wal", "-shm" };

    /// ⚠️ ВТОРОЙ ОБЯЗАТЕЛЬНЫЙ МАНИФЕСТ. Его не бэкапили НИ НА ОДНОЙ платформе — дыру
    /// нашли и закрыли здесь же (в macOS-writer'е она была ровно та же).
    ///
    /// `masterPlaylists6.xml` лежит РЯДОМ с master.db (это не суффикс, а отдельное имя) и
    /// является вторым источником правды о плейлистах: не обновил его — плейлистов в
    /// Rekordbox просто не видно. `pyrekordbox.commit()` его ПИШЕТ (`playlist_xml.save()`).
    ///
    /// А снимок брали только с трёх файлов базы. Значит при откате (провал op, USN не
    /// сдвинулся, verify не сошёлся) база возвращалась к прежнему состоянию, а манифест
    /// оставался НОВЫЙ — со ссылками на плейлисты, которых в базе уже нет. То есть
    /// «безопасный откат» сам оставлял библиотеку рассогласованной.
    ///
    /// Замерено на копии живой базы: один create_playlist изменил XML с 47 837 до 47 946
    /// байт и вписал туда id нового плейлиста.
    private static readonly string[] DbSiblings = { "masterPlaylists6.xml" };

    private static string BackupsRoot() => Path.Combine(AppConfig.Shared.BaseDir, "backups");

    private static Backup? MakeBackup(string dbPath)
    {
        // InvariantCulture ОБЯЗАТЕЛЕН: на тайской/арабской локали DateTime.ToString с
        // кастомным форматом взял бы календарь культуры (буддийский год 2569, арабские
        // цифры), имя папки получилось бы другим — и ротация, которая сортирует снимки
        // ПО ИМЕНИ, удаляла бы не то.
        var stamp = DateTime.Now.ToString("yyyyMMdd-HHmmss", CultureInfo.InvariantCulture);
        var dir   = Path.Combine(BackupsRoot(), stamp);

        try { Directory.CreateDirectory(dir); }
        catch (Exception ex)
        {
            Log.Warn($"sync: backup dir failed — {ex.Message}");
            return null;
        }

        var taken = new List<string>();
        var baseName = Path.GetFileName(dbPath);
        foreach (var suffix in DbSuffixes)
        {
            var src = dbPath + suffix;
            if (!File.Exists(src)) continue;                     // -wal/-shm может не быть
            var dst = Path.Combine(dir, baseName + suffix);
            try
            {
                File.Copy(src, dst, overwrite: true);
                taken.Add(suffix);
            }
            catch (Exception ex)
            {
                Log.Warn($"sync: backup of {baseName + suffix} failed — {ex.Message}");
                TryDeleteDir(dir);
                return null;
            }
        }

        // Сам master.db обязателен; без него откатывать нечем.
        if (!taken.Contains(""))
        {
            TryDeleteDir(dir);
            return null;
        }

        // Соседние манифесты — см. комментарий к DbSiblings. Отсутствие файла НЕ фатально
        // (в свежей библиотеке XML может ещё не родиться), но если он есть — обязан попасть
        // в снимок, иначе откат его не вернёт.
        var dbDir    = Path.GetDirectoryName(dbPath) ?? "";
        var siblings = new List<string>();
        foreach (var name in DbSiblings)
        {
            var src = Path.Combine(dbDir, name);
            if (!File.Exists(src)) continue;
            try
            {
                File.Copy(src, Path.Combine(dir, name), overwrite: true);
                siblings.Add(name);
            }
            catch (Exception ex)
            {
                Log.Warn($"sync: backup of {name} failed — {ex.Message}");
                TryDeleteDir(dir);
                return null;
            }
        }

        var took = string.Join(",", taken.Select(s => s.Length == 0 ? "db" : s).Concat(siblings));
        Log.Info($"sync: backup → {dir} [{took}]");
        return new Backup { Dir = dir, Suffixes = taken, Siblings = siblings };
    }

    /// Откат. Порядок важен: сперва СНОСИМ живые -wal/-shm, потом кладём файлы из
    /// снимка. Иначе SQLite накатит оставшийся -wal поверх восстановленной базы — то
    /// есть вернёт ровно то, что мы откатываем (а то и порвёт файл).
    private static void Restore(Backup backup, string dbPath)
    {
        var baseName = Path.GetFileName(dbPath);

        foreach (var suffix in DbSuffixes)
        {
            try { File.Delete(dbPath + suffix); } catch { /* нет файла / занят — падать нельзя, мы в откате */ }
        }
        foreach (var suffix in backup.Suffixes)
        {
            var src = Path.Combine(backup.Dir, baseName + suffix);
            try
            {
                File.Copy(src, dbPath + suffix, overwrite: true);
            }
            catch (Exception ex)
            {
                Log.Error($"sync: RESTORE FAILED for {baseName + suffix} — {ex.Message}; "
                        + $"snapshot kept at {backup.Dir}");
            }
        }

        // Манифесты. Откатываем ПОСЛЕ базы и по принципу «вернуть ровно то, что было»:
        // файл был в снимке → перезаписываем им живой; файла в снимке НЕ было, а сейчас
        // он есть → его создал ЭТОТ прогон, и откат обязан его убрать. Иначе XML остался
        // бы новее базы и ссылался на плейлисты, которых уже нет.
        var dbDir = Path.GetDirectoryName(dbPath) ?? "";
        foreach (var name in DbSiblings)
        {
            var live = Path.Combine(dbDir, name);
            if (backup.Siblings.Contains(name))
            {
                try { File.Copy(Path.Combine(backup.Dir, name), live, overwrite: true); }
                catch (Exception ex)
                {
                    Log.Error($"sync: RESTORE FAILED for {name} — {ex.Message}; "
                            + $"snapshot kept at {backup.Dir}");
                }
            }
            else if (File.Exists(live))
            {
                try { File.Delete(live); } catch { /* в откате падать нельзя */ }
            }
        }

        RekordboxParser.Shared.InvalidateCache();
        Log.Warn($"sync: master.db restored from {backup.Dir}");
    }

    /// Держим последние N снимков. Собственный `master.backup.db` Rekordbox живёт рядом
    /// с базой и нас не касается — не перезаписывать, это последняя линия обороны.
    private static void RotateBackups()
    {
        try
        {
            var root = BackupsRoot();
            if (!Directory.Exists(root)) return;
            var dirs = Directory.GetDirectories(root)
                .OrderByDescending(d => Path.GetFileName(d) ?? "", StringComparer.Ordinal)  // имя = timestamp
                .ToList();
            if (dirs.Count <= MaxBackups) return;
            foreach (var old in dirs.Skip(MaxBackups)) TryDeleteDir(old);
        }
        catch (Exception ex)
        {
            Log.Warn($"sync: backup rotation failed — {ex.Message}");
        }
    }

    private static void TryDeleteDir(string dir)
    {
        try { Directory.Delete(dir, recursive: true); } catch { }
    }

    // MARK: - Запуск хелпера

    private readonly record struct HelperFailure(string Code, string? Detail);

    private readonly record struct HelperRun(SyncHelperOutput? Output, HelperFailure? Failure);

    /// ⚠️ Энкодер тут ДЕФОЛТНЫЙ, и это осознанно: он экранирует всё не-ASCII в \uXXXX.
    /// UnsafeRelaxedJsonEscaping (соблазнительный «чтобы кириллица читалась глазами»)
    /// сломал бы синк ровно у тех, у кого плейлисты названы не по-английски: хелпер
    /// читает план через `json.load(open(plan_path))`, а Python на Windows берёт для
    /// open() КОДИРОВКУ ЛОКАЛИ (cp1251/cp1252), а не UTF-8. Сырые UTF-8-байты он бы
    /// раскодировал в мусор или упал с bad_plan. Чистый ASCII проходит через любую
    /// однобайтовую кодировку без потерь. (На macOS локаль и так UTF-8, поэтому там
    /// граблей нет — это чисто windows-специфичная разница.)
    private static readonly JsonSerializerOptions PlanJsonOptions = new()
    {
        DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull,
    };

    private HelperRun RunHelper(string helper, string dbPath, SyncPlan plan)
    {
        var tmp      = Path.GetTempPath();
        var planPath = Path.Combine(tmp, $"rimeo_syncplan_{Guid.NewGuid():N}.json");
        var outPath  = Path.Combine(tmp, $"rimeo_syncout_{Guid.NewGuid():N}.json");

        try
        {
            try
            {
                File.WriteAllText(planPath, JsonSerializer.Serialize(plan, PlanJsonOptions), new UTF8Encoding(false));
            }
            catch (Exception ex)
            {
                return new HelperRun(null, new HelperFailure("write_failed", $"cannot write plan: {ex.Message}"));
            }

            var psi = new ProcessStartInfo
            {
                FileName               = helper,
                UseShellExecute        = false,
                // Хелпер — консольный PyInstaller-бинарь. Без этого посреди сета у диджея
                // на секунды всплывало бы чёрное окно консоли поверх Rekordbox.
                CreateNoWindow         = true,
                RedirectStandardOutput = true,
                RedirectStandardError  = true,
                StandardOutputEncoding = new UTF8Encoding(false),
                StandardErrorEncoding  = new UTF8Encoding(false),
            };
            // ArgumentList, а не Arguments: пути к master.db и temp-файлам почти всегда
            // содержат пробелы (C:\Users\John Smith\AppData\...). Ручная склейка строки
            // здесь = хелпер получает обрезанный путь и пишет не в ту базу.
            //
            // Путь к базе передаём ЯВНО: pyrekordbox при path=None молча берёт базу
            // ИЗ КОНФИГА REKORDBOX — то есть боевую библиотеку юзера.
            psi.ArgumentList.Add(dbPath);
            psi.ArgumentList.Add(planPath);
            psi.ArgumentList.Add(outPath);

            // Заставляем Python работать в UTF-8, а не в кодировке локали. На Windows
            // `open()` и sys.stdout/stderr по умолчанию берут ANSI-кодировку системы
            // (cp1251/cp1252), и всё не-ASCII (имя плейлиста в тексте исключения,
            // локализованное сообщение об ошибке ФС) приезжало бы к нам мусором — а мы
            // показываем это юзеру как `detail`. План мы и так шлём чистым ASCII
            // (см. PlanJsonOptions), так что эти переменные лишь чинят обратный канал.
            // Если сборка хелпера их проигнорирует — станет ровно как было, хуже не будет.
            psi.Environment["PYTHONUTF8"]       = "1";
            psi.Environment["PYTHONIOENCODING"] = "utf-8";

            using var proc = new Process { StartInfo = psi };

            // Прогресс из stdout — ПО МЕРЕ ПОСТУПЛЕНИЯ, иначе телефон увидел бы стадии
            // только после того, как всё уже записано (то есть никогда).
            // Итоговый результат едет НЕ здесь, а в out.json — stdout только под прогресс.
            proc.OutputDataReceived += (_, e) =>
            {
                if (string.IsNullOrEmpty(e.Data)) return;
                ApplyProgressLine(e.Data);
            };

            // stderr копим в буфер и читаем АСИНХРОННО: синхронный ReadToEnd() после
            // WaitForExit() ждал бы процесс, который сам ждёт, пока мы разгребём его
            // заполненный пайп → взаимный дедлок навсегда.
            var stderrBuf  = new StringBuilder();
            var stderrLock = new object();
            proc.ErrorDataReceived += (_, e) =>
            {
                if (e.Data == null) return;
                lock (stderrLock) stderrBuf.AppendLine(e.Data);
            };

            try
            {
                proc.Start();
            }
            catch (Exception ex)
            {
                return new HelperRun(null, new HelperFailure("helper_unavailable", ex.Message));
            }

            proc.BeginOutputReadLine();
            proc.BeginErrorReadLine();

            // Хелпер НЕ должен уметь виснуть навсегда: если он завис (антивирус
            // сканирует свежий exe, файловая блокировка, дедлок), беспараметрический
            // WaitForExit() блокировал бы этот поток бесконечно — а вместе с ним
            // Sync() никогда не дошёл бы до своего finally, и _inFlight остался бы
            // true НАВСЕГДА: все последующие синки получали бы 409 sync_in_progress
            // до ручного перезапуска агента (см. инцидент 16.07 — зависание >30 мин
            // на одном прогоне без единой строки в логе после старта backup).
            const int HelperTimeoutSec = 180;
            var finished = proc.WaitForExit(HelperTimeoutSec * 1000);
            if (!finished)
            {
                Log.Warn($"sync: helper did not exit within {HelperTimeoutSec}s — killing");
                try { proc.Kill(entireProcessTree: true); } catch (Exception ex) { Log.Warn($"sync: kill failed — {ex.Message}"); }
                // Короткий добор после kill: дать асинхронным пайпам дойти до EOF, но
                // не рисковать повторным бесконечным ожиданием, если kill не сработал.
                try { proc.WaitForExit(5000); } catch { }
                return new HelperRun(null, new HelperFailure("helper_timeout",
                    $"rbdb-sync-helper did not exit within {HelperTimeoutSec}s"));
            }
            // Именно ПОВТОРНЫЙ беспараметрический WaitForExit() после успешного
            // WaitForExit(timeout): только он гарантированно дожидается EOF
            // асинхронных пайпов — иначе последние строки stderr (там едет код
            // ошибки хелпера!) мы могли бы просто не увидеть.
            proc.WaitForExit();

            string stderr;
            lock (stderrLock) stderr = stderrBuf.ToString().Trim();

            if (proc.ExitCode != 0)
            {
                // Хелпер отдаёт понятный код в stderr: {"error":"...","detail":"..."}.
                var code   = "write_failed";
                string? detail = string.IsNullOrEmpty(stderr) ? null : stderr;
                var parsed = ParseHelperError(stderr);
                if (parsed != null)
                {
                    code   = parsed.Value.Code;
                    detail = parsed.Value.Detail;
                }
                return new HelperRun(null, new HelperFailure(code, detail));
            }

            if (!string.IsNullOrEmpty(stderr)) Log.Debug($"sync helper stderr: {stderr}");

            string raw;
            try { raw = File.ReadAllText(outPath); }
            catch
            {
                return new HelperRun(null, new HelperFailure("write_failed", "helper produced no output"));
            }

            try
            {
                var output = JsonSerializer.Deserialize<SyncHelperOutput>(raw);
                if (output == null)
                    return new HelperRun(null, new HelperFailure("write_failed", "bad helper output: null"));
                return new HelperRun(output, null);
            }
            catch (Exception ex)
            {
                var snippet = raw.Length > 300 ? raw[..300] : raw;
                return new HelperRun(null,
                    new HelperFailure("write_failed", $"bad helper output: {ex.Message}; {snippet}"));
            }
        }
        finally
        {
            try { File.Delete(planPath); } catch { }
            try { File.Delete(outPath);  } catch { }
        }
    }

    /// Одна строка stdout хелпера = `{"progress":{...}}`. Чужие строки (например
    /// финальное `{"status":"ok"}`) молча игнорируем — прогресс не имеет права падать.
    private void ApplyProgressLine(string line)
    {
        try
        {
            using var doc = JsonDocument.Parse(line);
            if (doc.RootElement.ValueKind != JsonValueKind.Object) return;
            if (!doc.RootElement.TryGetProperty("progress", out var pr)) return;
            if (pr.ValueKind != JsonValueKind.Object) return;

            SetProgress(p =>
            {
                if (pr.TryGetProperty("stage", out var st) && st.ValueKind == JsonValueKind.String)
                    p.Stage = st.GetString() ?? p.Stage;
                if (pr.TryGetProperty("tracks_done", out var td) && td.TryGetInt32(out var d))
                    p.TracksDone = d;
                if (pr.TryGetProperty("tracks_total", out var tt) && tt.TryGetInt32(out var t))
                    p.TracksTotal = t;
            });
        }
        catch { /* не-JSON строка в stdout — не наше дело */ }
    }

    private static (string Code, string? Detail)? ParseHelperError(string stderr)
    {
        if (string.IsNullOrEmpty(stderr)) return null;
        // Хелпер может дописать в stderr предупреждения рантайма ДО своей JSON-строки —
        // берём последнюю непустую строку, она и есть fail().
        var last = stderr.Split('\n').Select(l => l.Trim())
                         .LastOrDefault(l => l.Length > 0 && l.StartsWith("{", StringComparison.Ordinal));
        if (last == null) return null;
        try
        {
            using var doc = JsonDocument.Parse(last);
            if (doc.RootElement.ValueKind != JsonValueKind.Object) return null;
            if (!doc.RootElement.TryGetProperty("error", out var e) || e.ValueKind != JsonValueKind.String)
                return null;
            string? detail = doc.RootElement.TryGetProperty("detail", out var d)
                             && d.ValueKind == JsonValueKind.String
                ? d.GetString() : null;
            return (e.GetString()!, detail);
        }
        catch { return null; }
    }

    // MARK: - Поиск хелпера + проверка архитектуры

    /// Путь к frozen-бинарю записи, или null — если он не забандлен / не той арки.
    ///
    /// `static` и публичный НАМЕРЕННО: этот же ответ нужен AgentCapabilities() в ApiRouter.
    /// Без него capability `playlist_sync` смотрела бы только на наличие master.db, кнопка
    /// Sync светилась бы активной, а любое нажатие падало бы с 500 helper_unavailable.
    /// Capability обязана отражать РЕАЛЬНУЮ способность, а не намерение.
    public static string? BundledSyncHelperPath()
    {
        // Явное переопределение пути к хелперу.
        //
        // Зачем оно в проде: если хелпер придётся пересобрать (сменилась схема Rekordbox,
        // всплыл баг в pyrekordbox), саппорт сможет подсунуть исправленный бинарь ОДНОМУ
        // пользователю, не выкатывая релиз на всех. Без этого единственный путь — новый
        // билд агента.
        //
        // Зачем оно нам: запись в чужую библиотеку — самый опасный код в проекте, и его
        // надо уметь прогонять end-to-end ДО того, как он попадёт к людям. Стенд паритета
        // (docs/parity-harness.md) собирает Windows-логику под net8.0 и гоняет её на macOS
        // против копии настоящей master.db — но там нет и не может быть PE-бинаря, поэтому
        // без этой переменной самый рискованный путь остался бы непроверенным.
        //
        // Проверку архитектуры для переопределённого пути НЕ пропускаем: если подсунули
        // бинарь не той арки, честнее отдать capability=false, чем упасть при нажатии.
        var overridePath = Environment.GetEnvironmentVariable("RIMEO_SYNC_HELPER");
        if (!string.IsNullOrWhiteSpace(overridePath))
        {
            if (File.Exists(overridePath) && CanRunOnThisMachine(overridePath))
            {
                Log.Info($"sync: using helper override RIMEO_SYNC_HELPER={overridePath}");
                return overridePath;
            }
            Log.Warn($"sync: RIMEO_SYNC_HELPER={overridePath} ignored — missing or wrong architecture");
        }

        var dirs = new[]
        {
            AppContext.BaseDirectory,
            Path.GetDirectoryName(Environment.ProcessPath ?? "") ?? "",
        };

        foreach (var dir in dirs)
        {
            if (string.IsNullOrEmpty(dir)) continue;
            var path = Path.Combine(dir, HelperName);
            if (!File.Exists(path)) continue;
            // ⚠️ Наличия файла МАЛО — арка. Агент публикуется и под win-x64, и под
            // win-arm64, а rbdb-sync-helper.exe PyInstaller собирает ТОЛЬКО под x64
            // (кросс-компиляции у него нет, CI-раннер x64). Без этой проверки на
            // arm64-машине файл лежит, capability отвечает «умею», кнопка светится —
            // а нажатие падает с «%1 is not a valid Win32 application».
            if (!CanRunOnThisMachine(path)) continue;
            return path;
        }
        return null;
    }

    // IMAGE_FILE_HEADER.Machine
    private const ushort ImageFileMachineI386  = 0x014C;
    private const ushort ImageFileMachineAmd64 = 0x8664;
    private const ushort ImageFileMachineArm64 = 0xAA64;

    /// Запустится ли этот бинарь на машине, на которой мы СЕЙЧАС исполняемся.
    ///
    /// Читаем PE-заголовок сами, а не пытаемся запустить: PyInstaller-onefile при старте
    /// распаковывает во временную папку десятки мегабайт, и «проверка запуском» стоила бы
    /// секунд на КАЖДОМ /api/data (capability считается там).
    ///
    /// Матрица намеренно не хардкодит «хелперx64-only» — когда появится arm64-сборка,
    /// проверка просто начнёт её принимать.
    private static bool CanRunOnThisMachine(string path)
    {
        // Агент существует только под Windows — но его ЧИСТАЯ ЛОГИКА собирается и
        // исполняется headless-ом на macOS: так проверяется паритет
        // (docs/parity-harness.md), и именно так прогоняется САМЫЙ ОПАСНЫЙ путь проекта —
        // запись в master.db, на копии настоящей базы. PE-бинаря там нет и быть не может
        // (хелпер — питон-скрипт), поэтому вне Windows «запустится ли» решает не
        // PE-заголовок, а ядро при exec. На реальную Windows-сборку эта ветка не влияет
        // никак: там OperatingSystem.IsWindows() всегда true.
        if (!OperatingSystem.IsWindows()) return File.Exists(path);

        var machine = PeMachine(path);
        if (machine == null) return false;          // не PE / короче заголовка / нечитаем

        var self = RuntimeInformation.ProcessArchitecture;

        // Точное совпадение. Сюда же попадает x64-агент, эмулируемый на arm64-Windows:
        // ProcessArchitecture у него X64, и x64-хелпер ему родной.
        if (machine == ImageFileMachineAmd64 && self == Architecture.X64)   return true;
        if (machine == ImageFileMachineArm64 && self == Architecture.Arm64) return true;
        if (machine == ImageFileMachineI386  && self == Architecture.X86)   return true;

        // x86-бинарь идёт под WOW64 на x64 и под x86-эмуляцией на ARM64 — это есть во
        // всех поддерживаемых нами Windows. (Сегодня недостижимо: PyInstaller собирает
        // x64. Ветка стоит, чтобы 32-битная сборка хелпера не выключила синк молча.)
        if (machine == ImageFileMachineI386 && self is Architecture.X64 or Architecture.Arm64)
            return true;

        // x64-хелпер на arm64-агенте. Эмуляция x64 на ARM появилась только в Windows 11
        // (build 22000+); на Windows 10 ARM64 её НЕТ — там эмулируется лишь x86, и запуск
        // упал бы. Минимальная поддерживаемая версия у агента — 10.0.17763, так что
        // «просто разрешить» нельзя. Проверяем реальную сборку ОС: Environment.OSVersion в
        // .NET 5+ идёт через RtlGetVersion и НЕ врёт из-за манифеста совместимости.
        //
        // Цена ошибки в эту сторону мала и не разрушительна: если эмуляция всё же не
        // заведётся, Process.Start бросит → helper_unavailable, а этот код входит в
        // PreWriteErrorCodes — база не тронута, откатывать нечего. Цена ошибки в другую
        // сторону (честный false на Win11 ARM) — синк, которого у пользователя нет вообще.
        if (machine == ImageFileMachineAmd64 && self == Architecture.Arm64)
            return Environment.OSVersion.Version.Build >= 22000;

        return false;
    }

    /// IMAGE_FILE_HEADER.Machine из PE-заголовка, или null если это не PE.
    /// Все смещения — из НЕДОВЕРЕННОГО файла, поэтому каждое сверяется с длиной файла:
    /// битый/обрезанный exe обязан дать null, а не исключение и не чтение мусора.
    private static ushort? PeMachine(string path)
    {
        try
        {
            using var fs = new FileStream(path, FileMode.Open, FileAccess.Read,
                                          FileShare.ReadWrite | FileShare.Delete);

            // IMAGE_DOS_HEADER: "MZ" + e_lfanew по смещению 0x3C.
            Span<byte> dos = stackalloc byte[0x40];
            if (fs.Length < dos.Length) return null;
            fs.ReadExactly(dos);
            if (dos[0] != (byte)'M' || dos[1] != (byte)'Z') return null;

            var lfanew = BinaryPrimitives.ReadUInt32LittleEndian(dos[0x3C..]);
            // За e_lfanew обязаны влезть сигнатура "PE\0\0" (4) + IMAGE_FILE_HEADER (20).
            if (lfanew > fs.Length - 24) return null;

            fs.Seek(lfanew, SeekOrigin.Begin);
            Span<byte> head = stackalloc byte[6];               // "PE\0\0" + Machine
            fs.ReadExactly(head);
            if (head[0] != (byte)'P' || head[1] != (byte)'E' || head[2] != 0 || head[3] != 0)
                return null;

            return BinaryPrimitives.ReadUInt16LittleEndian(head[4..]);
        }
        catch
        {
            return null;
        }
    }

    // MARK: - Verify

    /// Ждали записи? (delete «already_gone» и membership с нулевой дельтой ничего не
    /// пишут — по ним требовать сдвига USN нельзя.)
    private static bool ExpectedWrite(SyncPlan plan, List<SyncOpResult> results)
    {
        for (var i = 0; i < plan.Ops.Count && i < results.Count; i++)
        {
            var op = plan.Ops[i];
            var r  = results[i];
            var touched = (r.Added ?? 0) + (r.Removed ?? 0) + (r.Reordered ?? 0);
            if (touched > 0) return true;
            switch (op.Type)
            {
                case "create_folder":
                case "create_playlist":
                case "rename":
                case "move":
                    return true;
                case "delete":
                    if (r.Reason != "already_gone") return true;
                    break;
            }
        }
        return false;
    }

    /// Новые ID реально в перечитанной базе, удалённых — реально нет.
    /// Возвращает описание первой непрошедшей проверки, null = всё сошлось.
    private static string? Verify(SyncPlan plan, List<SyncOpResult> results, LibraryData lib)
    {
        var live = new HashSet<string>(StringComparer.Ordinal);
        foreach (var p in lib.Playlists)
            if (!string.IsNullOrEmpty(p.RekordboxId)) live.Add(p.RekordboxId!);

        for (var i = 0; i < plan.Ops.Count && i < results.Count; i++)
        {
            var op = plan.Ops[i];
            var r  = results[i];
            switch (op.Type)
            {
                case "create_folder":
                case "create_playlist":
                    if (string.IsNullOrEmpty(r.RekordboxId))
                        return $"create returned no rekordbox_id ({op.RimeoId ?? "?"})";
                    if (!live.Contains(r.RekordboxId!))
                        return $"new playlist {r.RekordboxId} not in library after re-parse";
                    break;
                case "delete":
                    if (!string.IsNullOrEmpty(op.RekordboxId) && live.Contains(op.RekordboxId!))
                        return $"deleted playlist {op.RekordboxId} still in library after re-parse";
                    break;
                case "rename":
                case "move":
                case "membership":
                    if (!string.IsNullOrEmpty(op.RekordboxId) && !live.Contains(op.RekordboxId!))
                        return $"playlist {op.RekordboxId} vanished after re-parse";
                    break;
            }
        }
        return null;
    }

    // MARK: - Write-back (только после verify)

    private static SyncResult CommitWriteBack(PlannedSync planned, List<SyncOpResult> results)
    {
        // rimeo_id → новый rekordbox_id (только для create).
        var newIds     = new Dictionary<string, string>(StringComparer.Ordinal);
        var counts     = new SyncCounts();
        var deletedIds = new HashSet<string>(StringComparer.Ordinal);
        var touched    = new HashSet<string>(StringComparer.Ordinal);

        for (var i = 0; i < planned.Plan.Ops.Count && i < results.Count; i++)
        {
            var op  = planned.Plan.Ops[i];
            var r   = results[i];
            var rid = op.RimeoId;
            if (string.IsNullOrEmpty(rid)) continue;

            touched.Add(rid!);
            counts.Added     += r.Added ?? 0;
            counts.Removed   += r.Removed ?? 0;
            counts.Reordered += r.Reordered ?? 0;

            switch (op.Type)
            {
                case "create_folder":
                case "create_playlist":
                    if (!string.IsNullOrEmpty(r.RekordboxId)) newIds[rid!] = r.RekordboxId!;
                    counts.Created++;
                    break;
                case "delete":
                    deletedIds.Add(rid!);
                    counts.Deleted++;
                    break;
            }
        }
        counts.Updated = touched.Where(id => !deletedIds.Contains(id) && !newIds.ContainsKey(id)).Count();

        var synced = new List<SyncedPlaylist>();

        DataStore.Shared.Update(d =>
        {
            var kept = new List<PlaylistOverlay>(d.Playlists.Count);

            foreach (var ov in d.Playlists)
            {
                if (!touched.Contains(ov.RimeoId)) { kept.Add(ov); continue; }

                // Tombstone отработал — overlay больше не нужен.
                if (deletedIds.Contains(ov.RimeoId) && ov.Deleted) continue;

                if (newIds.TryGetValue(ov.RimeoId, out var rb)) ov.RekordboxId = rb;

                // Штампуем подпись ТОГО состояния, которое синкали. Если юзер правил
                // плейлист во время sync, текущая подпись уже другая → overlay остаётся
                // pending и уедет следующим прогоном (не теряем правку и не врём
                // «Записано»).
                var plannedSig = planned.Signature.GetValueOrDefault(ov.RimeoId) ?? ov.SyncSignature;
                ov.LastSyncedHash = plannedSig;
                var stillSame = ov.SyncSignature == plannedSig;
                ov.Dirty = !stillSame;
                ov.State = stillSame ? "synced" : "pending";
                kept.Add(ov);

                synced.Add(new SyncedPlaylist(ov.RimeoId, ov.RekordboxId, ov.State));
            }
            d.Playlists = kept;
        });

        // Удалённые тоже отдаём клиенту: iOS должен снять их локальные overlay.
        foreach (var rid in deletedIds)
            synced.Add(new SyncedPlaylist(rid,
                planned.Snapshot.GetValueOrDefault(rid)?.RekordboxId, "deleted"));

        return new SyncResult { Status = 200, Synced = synced, Counts = counts };
    }
}
