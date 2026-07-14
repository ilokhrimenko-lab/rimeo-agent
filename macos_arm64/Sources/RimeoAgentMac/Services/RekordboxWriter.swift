import Foundation
import AppKit

// ФАЗА 6 — SYNC: запись overlay-плейлистов в Rekordbox master.db.
// Спека: memory/tasks/playlists-sync-phase6.md (§2 «Агент: SyncEngine»).
//
// Оркестратор. Сама запись живёт во frozen-бинаре `rbdb-sync-helper`
// (pyrekordbox), потому что корректность записи в master.db держится на трёх
// инвариантах (USN, masterPlaylists6.xml, типы ID), промах по любому из которых
// не падает, а ТИХО ПРОХОДИТ — и Rekordbox отвергает правку позже. Здесь —
// всё, что вокруг записи: барьеры, backup/restore, план, verify, write-back.
//
// Транзакции у pyrekordbox нет (внутри `remove_from_playlist` свой commit), поэтому
// единственная гарантия атомарности — файловый backup всех трёх файлов БД.

// MARK: - Контракт с rbdb-sync-helper (plan.json / out.json)

/// Одна операция записи. Схема 1:1 с `plan.json` хелпера — snake_case намеренно,
/// это межпроцессная граница, а не Swift-API.
struct SyncOp: Codable {
    /// `create_folder` | `create_playlist` | `membership` | `rename` | `move` | `delete`
    let type: String
    let rimeo_id: String?
    let rekordbox_id: String?
    let name: String?
    /// Родитель ещё не существует в базе — он создаётся в этом же прогоне.
    /// Хелпер резолвит его через локальную карту `rimeo_id → новый ID`.
    let parent_rimeo_id: String?
    /// Родитель уже в базе — резолв строго по ID, НИКОГДА по имени
    /// (Rekordbox допускает одноимённых сиблингов).
    let parent_rekordbox_id: String?
    let seq: Int?
    /// Желаемое КОНЕЧНОЕ состояние состава. Не список операций: дельту хелпер
    /// считает сам, из живого чтения БД (единственная защита от дублей).
    let desired: [String]?

    init(type: String,
         rimeo_id: String? = nil,
         rekordbox_id: String? = nil,
         name: String? = nil,
         parent_rimeo_id: String? = nil,
         parent_rekordbox_id: String? = nil,
         seq: Int? = nil,
         desired: [String]? = nil) {
        self.type = type
        self.rimeo_id = rimeo_id
        self.rekordbox_id = rekordbox_id
        self.name = name
        self.parent_rimeo_id = parent_rimeo_id
        self.parent_rekordbox_id = parent_rekordbox_id
        self.seq = seq
        self.desired = desired
    }
}

struct SyncPlan: Codable {
    let ops: [SyncOp]
}

/// Результат одной op из `out.json`. Всё, кроме `ok`, опционально: хелпер кладёт
/// `rekordbox_id` только при успехе, `reason` — только при отказе.
struct SyncOpResult: Codable {
    let rimeo_id: String?
    let rekordbox_id: String?
    let ok: Bool
    let added: Int?
    let removed: Int?
    let reordered: Int?
    let reason: String?
    /// Треки из `desired`, которых нет в базе (их просто пропустили).
    let skipped: [String]?
}

/// `out.json` целиком.
struct SyncHelperOutput: Codable {
    let ops: [SyncOpResult]
    let usn_before: Int?
    let usn_after: Int?
    /// USN обязан сдвинуться, если что-то писали. Не сдвинулся → Rekordbox
    /// правку отвергнет; для нас это провал, а не успех.
    let usn_advanced: Bool?
}

// MARK: - Результат sync (наружу, в APIRouter)

struct SyncedPlaylist {
    let rimeo_id: String
    let rekordbox_id: String?
    let sync_state: String     // "synced" | "pending" (правка прилетела во время sync)
}

struct FailedPlaylist {
    let rimeo_id: String?
    let reason: String
}

struct SyncCounts {
    var created  = 0
    var updated  = 0
    var deleted  = 0
    var added    = 0
    var removed  = 0
    var reordered = 0

    var json: [String: Int] {
        ["created": created, "updated": updated, "deleted": deleted,
         "added": added, "removed": removed, "reordered": reordered]
    }
}

/// Единственный тип, который APIRouter отдаёт наружу:
/// `HTTPResponse.json(result.body, status: result.status)`.
struct SyncResult {
    var status: Int = 200
    /// Машинный код отказа: `sync_in_progress` | `rekordbox_running` |
    /// `ambiguous_path` | `db_unavailable` | `helper_unavailable` |
    /// `backup_failed` | `write_failed` | `write_verify_failed` | `usn_not_advanced`.
    var error: String? = nil
    var detail: String? = nil
    /// Нечего синкать — идемпотентный успех, а не ошибка.
    var nothing: Bool = false
    var synced: [SyncedPlaylist] = []
    var failed: [FailedPlaylist] = []
    var counts = SyncCounts()

    var ok: Bool { error == nil }

    var body: [String: Any] {
        var dict: [String: Any] = [
            "status":  error == nil ? "ok" : "error",
            "synced":  synced.map { s -> [String: Any] in
                var d: [String: Any] = ["rimeo_id": s.rimeo_id, "sync_state": s.sync_state]
                if let rb = s.rekordbox_id, !rb.isEmpty { d["rekordbox_id"] = rb }
                return d
            },
            "failed":  failed.map { f -> [String: Any] in
                var d: [String: Any] = ["reason": f.reason]
                if let r = f.rimeo_id { d["rimeo_id"] = r }
                return d
            },
            "counts":  counts.json,
        ]
        if nothing { dict["nothing"] = true }
        if let e = error { dict["error"] = e }
        if let d = detail, !d.isEmpty { dict["detail"] = d }
        return dict
    }

    static func failure(_ code: String, status: Int,
                        detail: String? = nil,
                        failed: [FailedPlaylist] = []) -> SyncResult {
        SyncResult(status: status, error: code, detail: detail, failed: failed)
    }

    static var nothingToDo: SyncResult {
        SyncResult(nothing: true)
    }
}

// MARK: - Барьер 1: Rekordbox запущен?

enum RekordboxProcess {
    /// Fail-closed детект. Точный bundleID — жёсткий сигнал; substring по имени —
    /// мягкий фолбэк (может сработать на осиротевшем rekordboxAgent). Авторитетный
    /// сигнал всё равно у Барьера 2 (lock-probe BEGIN IMMEDIATE внутри хелпера):
    /// если лок берётся — база свободна.
    static func isRunning() -> (running: Bool, who: String?) {
        let ids = ["com.pioneerdj.rekordboxdj",
                   "com.pioneerdj.rekordbox",
                   "com.pioneerdj.rekordboxagent",
                   "com.alphatheta.rekordbox"]
        let apps = NSWorkspace.shared.runningApplications
        if let a = apps.first(where: { ids.contains($0.bundleIdentifier ?? "") }) {
            return (true, a.bundleIdentifier)
        }
        if let a = apps.first(where: { ($0.localizedName ?? "").lowercased().hasPrefix("rekordbox") }) {
            return (true, a.localizedName)
        }
        return (false, nil)
    }
}

// MARK: - SyncEngine

final class RekordboxWriter {
    static let shared = RekordboxWriter()

    /// Своя serial-очередь (по образцу RekordboxParser): два Sync никогда не идут
    /// параллельно. Второй запрос при этом НЕ ждёт в очереди — он сразу получает
    /// 409 sync_in_progress (double-tap кнопки / авто-ретрай релея не должны
    /// прогнать план дважды).
    private let queue = DispatchQueue(label: "rimeo.rbwriter", qos: .userInitiated)
    private let flightLock = NSLock()
    private var inFlight = false

    private let maxBackups = 5

    /// Коды, при которых хелпер гарантированно НЕ ТРОНУЛ базу (упал до первой
    /// записи). Restore после них не просто не нужен — он ОПАСЕН: при
    /// `rekordbox_running` база открыта живым Rekordbox, и подмена файлов под ним
    /// и есть та самая порча, ради предотвращения которой стоит барьер.
    private static let preWriteErrorCodes: Set<String> = [
        "rekordbox_running", "helper_unavailable", "db_not_found", "db_open_failed",
        "db_path_mismatch", "lock_probe_failed", "bad_plan", "usage",
    ]

    /// Умеет ли текущий rbdb-sync-helper op `move`. См. appendMove().
    private static let moveOpSupported = false

    private init() {}

    // MARK: - Прогресс (для честного экрана синка на телефоне)

    /// Стадии ровно те, что реально происходят — не декоративные.
    /// Телефон опрашивает их через GET /api/playlist/sync/status.
    /// ⚠️ Если добавляешь шаг сюда — добавь и в `stageTotal`, иначе прогресс-бар соврёт.
    struct Progress: Codable {
        var active: Bool = false
        var stage: String = "idle"      // checking | backup | writing | verifying | done | error
        var stageIndex: Int = 0
        var stageTotal: Int = 4
        var tracksDone: Int = 0
        var tracksTotal: Int = 0
        var playlistName: String = ""
        var error: String? = nil
    }

    private let progressLock = NSLock()
    private var _progress = Progress()

    var progress: Progress {
        progressLock.lock(); defer { progressLock.unlock() }
        return _progress
    }

    private func setProgress(_ mutate: (inout Progress) -> Void) {
        progressLock.lock()
        mutate(&_progress)
        progressLock.unlock()
    }

    private func stage(_ name: String, index: Int) {
        setProgress { p in
            p.active = true
            p.stage = name
            p.stageIndex = index
        }
    }

    // MARK: Точка входа

    /// `rimeoIDs == nil` — синкать всё pending. Иначе — только указанные overlay
    /// (+ их pending-родители, иначе ребёнку некуда лечь).
    func sync(rimeoIDs: [String]? = nil) -> SyncResult {
        flightLock.lock()
        if inFlight {
            flightLock.unlock()
            logger.info("sync: rejected — already in flight")
            return .failure("sync_in_progress", status: 409)
        }
        inFlight = true
        flightLock.unlock()

        defer {
            flightLock.lock()
            inFlight = false
            flightLock.unlock()
        }

        return queue.sync { performSync(rimeoIDs: rimeoIDs) }
    }

    // MARK: Флоу

    private func performSync(rimeoIDs: [String]?) -> SyncResult {
        // 1. pending
        var pending = DataStore.shared.pendingSyncOverlays()
        if let ids = rimeoIDs {
            pending = selectRequested(ids, from: pending, all: DataStore.shared.data.playlists)
        }
        guard !pending.isEmpty else {
            logger.info("sync: nothing pending")
            return .nothingToDo
        }

        setProgress { p in
            p = Progress(active: true, stage: "checking", stageIndex: 1, stageTotal: 4,
                         tracksDone: 0, tracksTotal: 0,
                         playlistName: pending.first?.name ?? "", error: nil)
        }

        // 2. БАРЬЕР 1 — Rekordbox запущен. База не тронута, backup не делаем.
        let rb = RekordboxProcess.isRunning()
        if rb.running {
            logger.info("sync: refused — Rekordbox is running (\(rb.who ?? "?"))")
            setProgress { p in p.active = false; p.stage = "error"; p.error = "rekordbox_running" }
            return .failure("rekordbox_running", status: 409, detail: rb.who)
        }

        // Источник должен быть master.db: в XML-режиме rekordbox_id нет и писать некуда.
        let cfg = AppConfig.shared
        let dbPath = cfg.dbPath
        guard cfg.dbSourceEnabled, !dbPath.isEmpty,
              FileManager.default.fileExists(atPath: dbPath) else {
            return .failure("db_unavailable", status: 409,
                            detail: "master.db source is off or missing")
        }

        guard let helper = Self.bundledSyncHelperPath() else {
            logger.warning("sync: rbdb-sync-helper not bundled")
            return .failure("helper_unavailable", status: 500,
                            detail: "rbdb-sync-helper not found")
        }

        // 3. План строим ДО backup: он чистое чтение и может отказать
        //    (ambiguous_path) — не плодим бесполезный снимок базы.
        let lib = RekordboxParser.shared.parse()
        let planned: PlannedSync
        switch buildSyncPlan(pending: pending, lib: lib) {
        case .rejected(let code):
            logger.warning("sync: plan rejected — \(code)")
            return .failure(code, status: 409)
        case .ok(let p):
            planned = p
        }
        guard !planned.plan.ops.isEmpty else {
            logger.info("sync: plan is empty after filtering")
            return .nothingToDo
        }

        // 4. BACKUP — master.db + -wal + -shm атомарно (все три!). Только .db при
        //    непустом -wal = неконсистентный снимок = битый откат.
        //    Собственный master.backup.db Rekordbox НЕ ТРОГАЕМ — это последняя
        //    линия обороны юзера.
        stage("backup", index: 2)
        guard let backup = makeBackup(dbPath: dbPath) else {
            setProgress { p in p.active = false; p.stage = "error"; p.error = "backup_failed" }
            return .failure("backup_failed", status: 500,
                            detail: "could not snapshot master.db (+wal/-shm)")
        }
        rotateBackups()

        // 5. ЗАПИСЬ через хелпер. Путь к базе передаём ЯВНО: если path не задан,
        //    pyrekordbox берёт его ИЗ КОНФИГА REKORDBOX — то есть боевую базу
        //    (13.07 так и потеряли библиотеку на «изолированном» прогоне).
        stage("writing", index: 3)
        let run = runHelper(helper: helper, dbPath: dbPath, plan: planned.plan)

        switch run {
        case .launchFailure(let code, let detail):
            if !Self.preWriteErrorCodes.contains(code) { restore(backup, dbPath: dbPath) }
            let status = (code == "rekordbox_running") ? 409 : 500
            logger.warning("sync: helper failed — \(code) \(detail ?? "")")
            setProgress { p in p.active = false; p.stage = "error"; p.error = code }
            return .failure(code, status: status, detail: detail)

        case .output(let out):
            // 6. Ошибка любой op → RESTORE (все 3 файла), last_synced_hash НЕ
            //    двигаем: overlay останется pending → повтор безопасен.
            guard out.ops.count == planned.plan.ops.count else {
                restore(backup, dbPath: dbPath)
                return .failure("write_failed", status: 500,
                                detail: "helper returned \(out.ops.count) results for \(planned.plan.ops.count) ops")
            }
            let failedOps = out.ops.filter { !$0.ok }
            if !failedOps.isEmpty {
                restore(backup, dbPath: dbPath)
                let failed = failedOps.map {
                    FailedPlaylist(rimeo_id: $0.rimeo_id, reason: $0.reason ?? "write_failed")
                }
                logger.warning("sync: \(failedOps.count) op(s) failed → restored backup")
                return .failure("write_failed", status: 500, failed: failed)
            }

            // Писали, а USN не сдвинулся → Rekordbox эту правку отвергнет.
            // Это «тихий провал», ради ловли которого весь §1 спеки.
            if expectedWrite(plan: planned.plan, results: out.ops), out.usn_advanced == false {
                restore(backup, dbPath: dbPath)
                logger.warning("sync: USN did not advance → restored backup")
                return .failure("usn_not_advanced", status: 500,
                                detail: "usn \(out.usn_before ?? -1) → \(out.usn_after ?? -1)")
            }

            // 7. VERIFY по перечитанной базе. invalidateCache() обходит debounce.
            stage("verifying", index: 4)
            RekordboxParser.shared.invalidateCache()
            let after = RekordboxParser.shared.parse()
            if let missing = verify(plan: planned.plan, results: out.ops, lib: after) {
                // Строки могли лечь, но мы их не видим — значит и «Записано» юзеру
                // показывать нельзя. Откатываем: overlay останется pending
                // (rekordbox_id не проставлен), повтор безопасен и не задвоит.
                restore(backup, dbPath: dbPath)
                RekordboxParser.shared.invalidateCache()
                logger.warning("sync: verify failed — \(missing) not visible after re-parse")
                setProgress { p in p.active = false; p.stage = "error"; p.error = "write_verify_failed" }
                return .failure("write_verify_failed", status: 500, detail: missing)
            }

            // 8. ТОЛЬКО ПОСЛЕ VERIFY — write-back в DataStore.
            let result = commitWriteBack(planned: planned, results: out.ops)

            // 9.
            DispatchQueue.main.async { AppState.shared.refreshFromData() }

            let c = result.counts
            let summary = "created=\(c.created) updated=\(c.updated) deleted=\(c.deleted) added=\(c.added) removed=\(c.removed) reordered=\(c.reordered)"
            logger.info("sync: ok — \(summary)")
            setProgress { p in
                p.active = false
                p.stage = "done"
                p.stageIndex = p.stageTotal
                p.error = nil
            }
            return result
        }
    }

    // MARK: - Выборка pending

    /// Явно запрошенные overlay + их pending-родители (папку-родителя надо создать
    /// раньше ребёнка, даже если юзер её не выделял).
    private func selectRequested(_ ids: [String],
                                 from pending: [PlaylistOverlay],
                                 all: [PlaylistOverlay]) -> [PlaylistOverlay] {
        let pendingByID = Dictionary(pending.map { ($0.rimeo_id, $0) }, uniquingKeysWith: { a, _ in a })
        let allByID     = Dictionary(all.map { ($0.rimeo_id, $0) },     uniquingKeysWith: { a, _ in a })

        var picked: [String: PlaylistOverlay] = [:]
        var stack = ids
        var guardHops = 0
        while let id = stack.popLast(), guardHops < 10_000 {
            guardHops += 1
            guard picked[id] == nil, let ov = pendingByID[id] else { continue }
            picked[id] = ov
            // Родитель нужен только если он сам ещё не в базе.
            if let raw = ov.parent, !raw.isEmpty {
                let key = raw.hasPrefix("rmo:") ? String(raw.dropFirst(4)) : raw
                if let parent = allByID[key], (parent.rekordbox_id ?? "").isEmpty {
                    stack.append(parent.rimeo_id)
                }
            }
        }
        // Порядок как в pending (стабильный), не как в ids.
        return pending.filter { picked[$0.rimeo_id] != nil }
    }

    // MARK: - Sync plan

    /// План + снимок overlay, из которых он построен. Снимок нужен для write-back:
    /// подпись штампуем ту, что синкали, а не ту, что могла прилететь во время sync.
    private struct PlannedSync {
        let plan: SyncPlan
        /// index в plan.ops → rimeo_id (для write-back и counts)
        let snapshot: [String: PlaylistOverlay]   // rimeo_id → overlay на момент плана
        let signature: [String: String]           // rimeo_id → syncSignature на момент плана
    }

    private enum ParentRef {
        case root
        case pending(String)      // rimeo_id родителя, создаётся в этом же прогоне
        case existing(String)     // rekordbox_id
        case ambiguous
    }

    private enum PlanOutcome {
        case ok(PlannedSync)
        case rejected(String)     // машинный код → 409
    }

    private func buildSyncPlan(pending: [PlaylistOverlay],
                               lib: LibraryData) -> PlanOutcome {
        var baseByRBID: [String: Playlist] = [:]
        var pathCount:  [String: Int] = [:]
        var byPath:     [String: Playlist] = [:]
        for p in lib.playlists {
            if let rb = p.rekordbox_id, !rb.isEmpty { baseByRBID[rb] = p }
            guard !p.path.isEmpty else { continue }
            pathCount[p.path, default: 0] += 1
            byPath[p.path] = p
        }

        let allOverlays = DataStore.shared.data.playlists
        var overlayByRimeoID: [String: PlaylistOverlay] = [:]
        for ov in allOverlays where !ov.rimeo_id.isEmpty { overlayByRimeoID[ov.rimeo_id] = ov }

        // Smart / history sync не пишет — барьеры мутаций их и так не пускают,
        // это защита от «протёкшего» overlay.
        let syncable = pending.filter { ov in
            guard let rb = ov.rekordbox_id, !rb.isEmpty, let base = baseByRBID[rb] else { return true }
            if base.is_smart == true || base.history == true {
                logger.warning("sync: skipping smart/history playlist \(rb)")
                return false
            }
            return true
        }
        guard !syncable.isEmpty else { return .ok(PlannedSync(plan: SyncPlan(ops: []), snapshot: [:], signature: [:])) }

        // Родитель: "rmo:<rimeo_id>" | голый rimeo_id | rekordbox_id | display-path.
        // Резолв всегда сводится к rekordbox_id или к pending-родителю — НИКОГДА к имени.
        func resolveParent(_ raw: String?) -> ParentRef {
            guard let p = raw?.trimmingCharacters(in: .whitespaces), !p.isEmpty else { return .root }
            let key = p.hasPrefix("rmo:") ? String(p.dropFirst(4)) : p
            if let ov = overlayByRimeoID[key] {
                if let rb = ov.rekordbox_id, !rb.isEmpty { return .existing(rb) }
                return .pending(ov.rimeo_id)
            }
            if baseByRBID[p] != nil { return .existing(p) }
            if let n = pathCount[p] {
                if n > 1 { return .ambiguous }                       // одноимённые сиблинги
                if let m = byPath[p], let rb = m.rekordbox_id, !rb.isEmpty { return .existing(rb) }
            }
            // Битая ссылка (папку удалили в Rekordbox). Кладём в корень и говорим об
            // этом в лог: плейлист в корне юзер поправит, вечно pending-очередь — нет.
            logger.warning("sync: unresolved parent \"\(p)\" → root")
            return .root
        }

        // Топологический порядок среди создаваемых: родитель-папка раньше ребёнка.
        let creates = syncable.filter { !$0.deleted && ($0.rekordbox_id ?? "").isEmpty }
        let createByID = Dictionary(creates.map { ($0.rimeo_id, $0) }, uniquingKeysWith: { a, _ in a })
        var ordered: [PlaylistOverlay] = []
        var visiting = Set<String>()
        var visited  = Set<String>()
        func visit(_ ov: PlaylistOverlay) {
            guard !visited.contains(ov.rimeo_id) else { return }
            guard !visiting.contains(ov.rimeo_id) else { return }   // цикл — рвём
            visiting.insert(ov.rimeo_id)
            if case .pending(let pid) = resolveParent(ov.parent), let parent = createByID[pid] {
                visit(parent)
            }
            visiting.remove(ov.rimeo_id)
            visited.insert(ov.rimeo_id)
            ordered.append(ov)
        }
        for ov in creates { visit(ov) }

        var ops: [SyncOp] = []
        var snapshot: [String: PlaylistOverlay] = [:]
        var signature: [String: String] = [:]
        var ambiguous = false

        func parentFields(_ ov: PlaylistOverlay) -> (String?, String?) {
            switch resolveParent(ov.parent) {
            case .root:              return (nil, nil)
            case .pending(let rid):  return (rid, nil)
            case .existing(let rb):  return (nil, rb)
            case .ambiguous:         ambiguous = true; return (nil, nil)
            }
        }

        func remember(_ ov: PlaylistOverlay) {
            snapshot[ov.rimeo_id]  = ov
            signature[ov.rimeo_id] = ov.syncSignature
        }

        // Перенос уже существующего в базе плейлиста в другую папку. В v6 не
        // отправляется: rbdb-sync-helper знает пять op (create_folder,
        // create_playlist, membership, rename, delete) и на "move" вернёт
        // unknown_op → откат всего батча. Ставить его в план «на вырост» нельзя.
        // Дырой это не становится: эндпоинта, меняющего родителя существующего
        // плейлиста, в агенте нет — parent проставляется только при create и там
        // уезжает в create_folder/create_playlist. Когда в хелпере появится ветка
        // move (db.move_playlist(pl, parent, seq)) — снять гейт.
        func appendMove(_ ops: inout [SyncOp], ov: PlaylistOverlay, rb: String,
                        parentRimeoID: String?, parentRekordboxID: String?) {
            guard Self.moveOpSupported else {
                logger.warning("sync: move of \(rb) skipped — helper has no \"move\" op")
                return
            }
            ops.append(SyncOp(type: "move", rimeo_id: ov.rimeo_id, rekordbox_id: rb,
                              parent_rimeo_id: parentRimeoID,
                              parent_rekordbox_id: parentRekordboxID))
        }

        // (a) Папки и плейлисты, которых ещё нет в базе — в топо-порядке.
        for ov in ordered {
            let (prid, prb) = parentFields(ov)
            remember(ov)
            if ov.is_folder {
                ops.append(SyncOp(type: "create_folder", rimeo_id: ov.rimeo_id,
                                  name: ov.name, parent_rimeo_id: prid, parent_rekordbox_id: prb))
            } else {
                ops.append(SyncOp(type: "create_playlist", rimeo_id: ov.rimeo_id,
                                  name: ov.name, parent_rimeo_id: prid, parent_rekordbox_id: prb,
                                  desired: ov.track_ids))
            }
        }

        // (b) Уже существующие в базе: rename → move → membership.
        for ov in syncable where !ov.deleted {
            guard let rb = ov.rekordbox_id, !rb.isEmpty else { continue }
            guard let base = baseByRBID[rb] else {
                // ID из overlay нет в базе (плейлист удалили в Rekordbox). Молча
                // пропускаем: пересоздавать не просили, а create дал бы дубль.
                logger.warning("sync: overlay \(ov.rimeo_id) points at missing rekordbox_id \(rb) — skipped")
                continue
            }
            remember(ov)

            let baseName = displayName(of: base)
            if !ov.name.isEmpty, ov.name != baseName {
                ops.append(SyncOp(type: "rename", rimeo_id: ov.rimeo_id, rekordbox_id: rb, name: ov.name))
            }

            // Move. Два правила, оба важные:
            //
            // 1. Двигаем ТОЛЬКО при явно заданном parent. У overlay, созданного
            //    rename/add/remove, parent == nil — это «не трогать», а НЕ «в корень»:
            //    иначе первый же Sync вынес бы чужие плейлисты из папок в корень.
            // 2. Нерезолвящийся parent (папку снесли в Rekordbox) — тоже НЕ трогаем.
            //    resolveParent в этом случае отдаёт .root, и наивное «wantParent !=
            //    currentParent» выкинуло бы плейлист в корень на ровном месте.
            if ov.parent != nil {
                switch resolveParent(ov.parent) {
                case .existing(let prb) where prb != (base.parent ?? "root"):
                    appendMove(&ops, ov: ov, rb: rb, parentRimeoID: nil, parentRekordboxID: prb)
                case .pending(let prid):
                    appendMove(&ops, ov: ov, rb: rb, parentRimeoID: prid, parentRekordboxID: nil)
                case .ambiguous:
                    ambiguous = true
                default:
                    break   // уже там / root / нерезолвящийся — не двигаем
                }
            }

            if !ov.is_folder {
                ops.append(SyncOp(type: "membership", rimeo_id: ov.rimeo_id, rekordbox_id: rb,
                                  desired: ov.track_ids))
            }
        }

        // (c) Delete — последними, дети раньше родителей (глубина по base-дереву).
        let deletes = syncable.filter { $0.deleted && !($0.rekordbox_id ?? "").isEmpty }
        let byDepth = deletes.sorted { a, b in
            depth(of: a.rekordbox_id ?? "", baseByRBID: baseByRBID)
                > depth(of: b.rekordbox_id ?? "", baseByRBID: baseByRBID)
        }
        for ov in byDepth {
            remember(ov)
            ops.append(SyncOp(type: "delete", rimeo_id: ov.rimeo_id, rekordbox_id: ov.rekordbox_id))
        }

        if ambiguous { return .rejected("ambiguous_path") }
        return .ok(PlannedSync(plan: SyncPlan(ops: ops), snapshot: snapshot, signature: signature))
    }

    /// Имя узла = последний сегмент display-path (парсер отдаёт `name` только у history).
    private func displayName(of p: Playlist) -> String {
        if let n = p.name, !n.isEmpty { return n }
        return p.path.components(separatedBy: " / ").last ?? p.path
    }

    private func depth(of rbID: String, baseByRBID: [String: Playlist]) -> Int {
        var d = 0
        var cur = rbID
        var seen = Set<String>()
        while let node = baseByRBID[cur], let parent = node.parent, parent != "root",
              !seen.contains(cur) {
            seen.insert(cur)
            cur = parent
            d += 1
            if d > 64 { break }
        }
        return d
    }

    // MARK: - Backup / restore (все три файла)

    private struct Backup {
        let dir: URL
        /// Какие суффиксы реально лежали в снимке (["", "-wal", "-shm"]).
        let suffixes: [String]
    }

    private static let dbSuffixes = ["", "-wal", "-shm"]

    private func backupsRoot() -> URL {
        AppConfig.shared.baseDir.appendingPathComponent("backups")
    }

    private func makeBackup(dbPath: String) -> Backup? {
        let fm = FileManager.default
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        f.locale = Locale(identifier: "en_US_POSIX")
        let dir = backupsRoot().appendingPathComponent(f.string(from: Date()))

        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            logger.warning("sync: backup dir failed — \(error)")
            return nil
        }

        var taken: [String] = []
        let base = (dbPath as NSString).lastPathComponent
        for suffix in Self.dbSuffixes {
            let src = dbPath + suffix
            guard fm.fileExists(atPath: src) else { continue }   // -wal/-shm может не быть
            let dst = dir.appendingPathComponent(base + suffix)
            do {
                try fm.copyItem(atPath: src, toPath: dst.path)
                taken.append(suffix)
            } catch {
                logger.warning("sync: backup of \(base + suffix) failed — \(error)")
                try? fm.removeItem(at: dir)
                return nil
            }
        }
        // Сам master.db обязателен; без него откатывать нечем.
        guard taken.contains("") else {
            try? fm.removeItem(at: dir)
            return nil
        }
        let took = taken.map { $0.isEmpty ? "db" : $0 }.joined(separator: ",")
        logger.info("sync: backup → \(dir.path) [\(took)]")
        return Backup(dir: dir, suffixes: taken)
    }

    /// Откат. Порядок важен: сперва СНОСИМ живые -wal/-shm, потом кладём файлы из
    /// снимка. Иначе SQLite накатит оставшийся -wal поверх восстановленной базы —
    /// то есть вернёт ровно то, что мы откатываем (а то и порвёт файл).
    private func restore(_ backup: Backup, dbPath: String) {
        let fm = FileManager.default
        let base = (dbPath as NSString).lastPathComponent

        for suffix in Self.dbSuffixes {
            try? fm.removeItem(atPath: dbPath + suffix)
        }
        for suffix in backup.suffixes {
            let src = backup.dir.appendingPathComponent(base + suffix)
            do {
                try fm.copyItem(atPath: src.path, toPath: dbPath + suffix)
            } catch {
                logger.error("sync: RESTORE FAILED for \(base + suffix) — \(error); snapshot kept at \(backup.dir.path)")
            }
        }
        RekordboxParser.shared.invalidateCache()
        logger.warning("sync: master.db restored from \(backup.dir.path)")
    }

    /// Держим последние N снимков. Собственный `master.backup.db` Rekordbox живёт
    /// рядом с базой и нас не касается — не перезаписывать, это последняя линия обороны.
    private func rotateBackups() {
        let fm = FileManager.default
        let root = backupsRoot()
        guard let items = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { return }
        let dirs = items.filter { url in
                var isDir: ObjCBool = false
                return fm.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
            }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }     // имя = timestamp
        guard dirs.count > maxBackups else { return }
        for old in dirs.dropFirst(maxBackups) {
            try? fm.removeItem(at: old)
        }
    }

    // MARK: - Запуск хелпера

    private enum HelperRun {
        case output(SyncHelperOutput)
        case launchFailure(code: String, detail: String?)
    }

    private func runHelper(helper: String, dbPath: String, plan: SyncPlan) -> HelperRun {
        let fm  = FileManager.default
        let tmp = fm.temporaryDirectory
        let planURL = tmp.appendingPathComponent("rimeo_syncplan_\(UUID().uuidString).json")
        let outURL  = tmp.appendingPathComponent("rimeo_syncout_\(UUID().uuidString).json")
        defer {
            try? fm.removeItem(at: planURL)
            try? fm.removeItem(at: outURL)
        }

        do {
            let encoder = JSONEncoder()
            try encoder.encode(plan).write(to: planURL, options: .atomic)
        } catch {
            return .launchFailure(code: "write_failed", detail: "cannot write plan: \(error.localizedDescription)")
        }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: helper)
        // Путь к базе — ЯВНО. Хелпер сверит его с тем, что открыла библиотека:
        // pyrekordbox при path=nil молча берёт базу из конфига Rekordbox.
        proc.arguments = [dbPath, planURL.path, outURL.path]

        let errPipe = Pipe()
        let outPipe = Pipe()
        proc.standardError  = errPipe
        proc.standardOutput = outPipe

        // Прогресс из stdout — ПО МЕРЕ ПОСТУПЛЕНИЯ, иначе телефон увидел бы стадии
        // только после того, как всё уже записано (то есть никогда).
        // Итоговый результат едет НЕ здесь, а в out.json — stdout только под прогресс.
        var outBuf = Data()
        outPipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            let chunk = h.availableData
            guard !chunk.isEmpty else { return }
            outBuf.append(chunk)
            while let nl = outBuf.firstIndex(of: 0x0A) {
                let line = outBuf.prefix(upTo: nl)
                outBuf.removeSubrange(...nl)
                guard let obj = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                      let pr = obj["progress"] as? [String: Any] else { continue }
                self?.setProgress { p in
                    if let st = pr["stage"] as? String { p.stage = st }
                    if let d = pr["tracks_done"] as? Int { p.tracksDone = d }
                    if let t = pr["tracks_total"] as? Int { p.tracksTotal = t }
                }
            }
        }
        defer { outPipe.fileHandleForReading.readabilityHandler = nil }

        do {
            try proc.run()
        } catch {
            return .launchFailure(code: "helper_unavailable", detail: error.localizedDescription)
        }
        // Читаем до waitUntilExit: полный пайп заблокировал бы хелпер намертво.
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()

        let stderr = String(data: errData, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        guard proc.terminationStatus == 0 else {
            // Хелпер отдаёт понятный код в stderr: {"error":"...","detail":"..."}.
            var code = "write_failed"
            var detail: String? = stderr.isEmpty ? nil : stderr
            if let d = stderr.data(using: .utf8),
               let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
               let e = obj["error"] as? String {
                code = e
                detail = obj["detail"] as? String
            }
            return .launchFailure(code: code, detail: detail)
        }

        if !stderr.isEmpty { logger.debug("sync helper stderr: \(stderr)") }

        guard let raw = try? Data(contentsOf: outURL) else {
            return .launchFailure(code: "write_failed", detail: "helper produced no output")
        }
        do {
            return .output(try JSONDecoder().decode(SyncHelperOutput.self, from: raw))
        } catch {
            let snippet = String(data: raw.prefix(300), encoding: .utf8) ?? ""
            return .launchFailure(code: "write_failed",
                                  detail: "bad helper output: \(error.localizedDescription); \(snippet)")
        }
    }

    /// Путь к frozen-бинарю записи, или nil — если он не забандлен.
    ///
    /// `static` и не-private НАМЕРЕННО: этот же ответ нужен `agentCapabilities()` в APIRouter.
    /// Без него capability `playlist_sync` смотрела бы только на наличие master.db, кнопка Sync
    /// светилась бы активной, а любое нажатие падало бы с 500 helper_unavailable.
    /// Capability обязана отражать РЕАЛЬНУЮ способность, а не намерение.
    static func bundledSyncHelperPath() -> String? {
        let fm = FileManager.default
        let execDir = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
        let candidates = [
            execDir.appendingPathComponent("rbdb-sync-helper").path,
            Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/rbdb-sync-helper").path,
        ]
        for path in candidates where fm.isExecutableFile(atPath: path) { return path }
        return nil
    }

    // MARK: - Verify

    /// Ждали записи? (delete «already_gone» и membership с нулевой дельтой ничего
    /// не пишут — по ним требовать сдвига USN нельзя.)
    private func expectedWrite(plan: SyncPlan, results: [SyncOpResult]) -> Bool {
        for (op, r) in zip(plan.ops, results) {
            let touched = (r.added ?? 0) + (r.removed ?? 0) + (r.reordered ?? 0)
            if touched > 0 { return true }
            switch op.type {
            case "create_folder", "create_playlist", "rename", "move": return true
            case "delete": if r.reason != "already_gone" { return true }
            default: break
            }
        }
        return false
    }

    /// Новые ID реально в перечитанной базе, удалённых — реально нет.
    /// Возвращает описание первой непрошедшей проверки, nil = всё сошлось.
    private func verify(plan: SyncPlan, results: [SyncOpResult], lib: LibraryData) -> String? {
        var live = Set<String>()
        for p in lib.playlists {
            if let rb = p.rekordbox_id, !rb.isEmpty { live.insert(rb) }
        }
        for (op, r) in zip(plan.ops, results) {
            switch op.type {
            case "create_folder", "create_playlist":
                guard let rb = r.rekordbox_id, !rb.isEmpty else {
                    return "create returned no rekordbox_id (\(op.rimeo_id ?? "?"))"
                }
                if !live.contains(rb) { return "new playlist \(rb) not in library after re-parse" }
            case "delete":
                if let rb = op.rekordbox_id, !rb.isEmpty, live.contains(rb) {
                    return "deleted playlist \(rb) still in library after re-parse"
                }
            case "rename", "move", "membership":
                if let rb = op.rekordbox_id, !rb.isEmpty, !live.contains(rb) {
                    return "playlist \(rb) vanished after re-parse"
                }
            default:
                break
            }
        }
        return nil
    }

    // MARK: - Write-back (только после verify)

    private func commitWriteBack(planned: PlannedSync, results: [SyncOpResult]) -> SyncResult {
        // rimeo_id → новый rekordbox_id (только для create).
        var newIDs: [String: String] = [:]
        var counts = SyncCounts()
        var deletedIDs = Set<String>()
        var touched = Set<String>()

        for (op, r) in zip(planned.plan.ops, results) {
            guard let rid = op.rimeo_id, !rid.isEmpty else { continue }
            touched.insert(rid)
            counts.added     += r.added ?? 0
            counts.removed   += r.removed ?? 0
            counts.reordered += r.reordered ?? 0

            switch op.type {
            case "create_folder", "create_playlist":
                if let rb = r.rekordbox_id, !rb.isEmpty { newIDs[rid] = rb }
                counts.created += 1
            case "delete":
                deletedIDs.insert(rid)
                counts.deleted += 1
            case "rename", "move", "membership":
                break
            default:
                break
            }
        }
        counts.updated = touched.subtracting(deletedIDs).subtracting(newIDs.keys).count

        var synced: [SyncedPlaylist] = []

        DataStore.shared.update { d in
            var kept: [PlaylistOverlay] = []
            kept.reserveCapacity(d.playlists.count)

            for var ov in d.playlists {
                guard touched.contains(ov.rimeo_id) else { kept.append(ov); continue }

                // Tombstone отработал — overlay больше не нужен.
                if deletedIDs.contains(ov.rimeo_id), ov.deleted { continue }

                if let rb = newIDs[ov.rimeo_id] { ov.rekordbox_id = rb }

                // Штампуем подпись ТОГО состояния, которое синкали. Если юзер правил
                // плейлист во время sync, текущая подпись уже другая → overlay
                // остаётся pending и уедет следующим прогоном (не теряем правку и
                // не врём «Записано»).
                let plannedSig = planned.signature[ov.rimeo_id] ?? ov.syncSignature
                ov.last_synced_hash = plannedSig
                let stillSame = (ov.syncSignature == plannedSig)
                ov.dirty = !stillSame
                ov.state = stillSame ? "synced" : "pending"
                kept.append(ov)

                synced.append(SyncedPlaylist(rimeo_id: ov.rimeo_id,
                                             rekordbox_id: ov.rekordbox_id,
                                             sync_state: ov.state))
            }
            d.playlists = kept
        }

        // Удалённые тоже отдаём клиенту: iOS должен снять их локальные overlay.
        for rid in deletedIDs {
            synced.append(SyncedPlaylist(rimeo_id: rid,
                                         rekordbox_id: planned.snapshot[rid]?.rekordbox_id,
                                         sync_state: "deleted"))
        }

        return SyncResult(status: 200, synced: synced, counts: counts)
    }
}
