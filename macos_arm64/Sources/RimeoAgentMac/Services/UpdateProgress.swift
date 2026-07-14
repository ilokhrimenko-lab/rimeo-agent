import Foundation

/// Честный прогресс обновления агента: POST /api/agent/update запускает установку,
/// GET /api/agent/update/status отдаёт стадию телефону.
///
/// ⚠️ Стадии обязаны отражать РЕАЛЬНЫЙ ход. `verifying` выставляется ровно вокруг
/// проверки подписи (UpdateSignatureVerifier), `installing` — ровно вокруг подмены
/// бандла. Никаких декоративных таймеров: пользователю показывают «Signature
/// verified», и это должно быть правдой, а не анимацией.
final class UpdateProgress {
    static let shared = UpdateProgress()

    enum Stage: String {
        case idle, downloading, verifying, installing, restarting, done, error
    }

    struct Snapshot {
        var stage: Stage
        var progress: Double      // 0…1 — значимо только на .downloading
        var targetTag: String
        var targetBuild: Int
        var error: String?

        var isActive: Bool {
            switch stage {
            case .downloading, .verifying, .installing, .restarting: return true
            case .idle, .done, .error:                               return false
            }
        }
    }

    private let lock = NSLock()
    private var stage: Stage = .idle
    private var fraction: Double = 0
    private var targetTag = ""
    private var targetBuild = 0
    private var errorText: String?

    /// Установка уже идёт (любой источник: телефон, кнопка в UI, staged-апдейт).
    /// Второй запрос на обновление должен получить 409, а не запустить гонку двух
    /// процессов за один и тот же бандл.
    private var inFlight = false

    /// Обновление запущено ПО ЗАПРОСУ с телефона. Только тогда процесс перед exit(0)
    /// ждёт, пока клиент реально заберёт стадию `restarting`: при старте с диска
    /// (staged-апдейт) ждать некого и задержка была бы вредна.
    private var apiInitiated = false
    private var restartingDelivered = false

    /// Хэндофф через перезапуск: процесс умирает внутри applyZip (open + exit 0),
    /// поэтому стадию `done` физически может отдать только НОВЫЙ процесс — по файлу,
    /// который оставил старый. Память тут не переживает обновление, диск переживает.
    private struct Handoff: Codable {
        let tag: String
        let build: Int
        let ts: Double
    }
    private var handoff: Handoff?

    /// `done` живёт ровно столько, сколько имеет смысл для экрана обновления: телефон
    /// опрашивает статус, пока агент не вернётся. Через 10 минут это уже не «только что
    /// обновились», а мусор — и мы снова честно говорим `idle`.
    private static let doneTTL: TimeInterval = 600

    private var handoffURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("RimeoAgent/update_handoff.json")
    }

    private init() {
        if let data = try? Data(contentsOf: handoffURL),
           let h = try? JSONDecoder().decode(Handoff.self, from: data) {
            handoff = h
        }
    }

    // MARK: - Чтение (GET /api/agent/update/status)

    /// `currentBuild` передаётся снаружи (UpdateChecker парсит тег релиза) — здесь
    /// он нужен только чтобы понять, что перезапуск действительно принёс новый билд.
    func snapshot(currentBuild: Int) -> Snapshot {
        lock.lock(); defer { lock.unlock() }

        // Ничего не идёт, но на диске лежит расписка от прошлого процесса: если
        // запущенный билд >= обещанного, обновление реально доехало → `done`.
        if stage == .idle, let h = handoff {
            let fresh = Date().timeIntervalSince1970 - h.ts < Self.doneTTL
            if fresh, h.build > 0, currentBuild >= h.build {
                return Snapshot(stage: .done, progress: 1, targetTag: h.tag,
                                targetBuild: h.build, error: nil)
            }
            if !fresh {
                handoff = nil
                try? FileManager.default.removeItem(at: handoffURL)
            }
        }
        return Snapshot(stage: stage, progress: fraction, targetTag: targetTag,
                        targetBuild: targetBuild, error: errorText)
    }

    /// Роутер зовёт это, когда фактически отдал клиенту стадию `restarting`.
    func markRestartingDelivered() {
        lock.lock(); restartingDelivered = true; lock.unlock()
    }

    // MARK: - Переходы стадий

    /// Атомарно занимает слот под обновление с телефона. false — уже идёт (→ 409).
    func tryBeginAPIUpdate() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if inFlight { return false }
        inFlight = true
        apiInitiated = true
        restartingDelivered = false
        return true
    }

    /// Слот занят, но обновляться не на что (или GitHub не ответил) — откатываем, не
    /// трогая стадию: врать про downloading, ничего не скачав, нельзя.
    func abortBegin() {
        lock.lock()
        inFlight = false
        apiInitiated = false
        lock.unlock()
    }

    func startDownload(tag: String, build: Int) {
        lock.lock()
        stage = .downloading
        fraction = 0
        targetTag = tag
        targetBuild = build
        errorText = nil
        lock.unlock()
    }

    /// Реальная доля скачанного (URLSession task.progress), 0…1.
    func setDownloadFraction(_ f: Double) {
        lock.lock()
        if stage == .downloading { fraction = min(max(f, 0), 1) }
        lock.unlock()
    }

    func enterVerifying(tag: String) {
        lock.lock()
        inFlight = true
        stage = .verifying
        fraction = 1
        if !tag.isEmpty { targetTag = tag }
        errorText = nil
        lock.unlock()
    }

    func enterInstalling() {
        lock.lock()
        stage = .installing
        lock.unlock()
    }

    /// Бандл уже подменён, дальше — open + exit(0). Расписку пишем на диск ДО выхода:
    /// после exit сообщить `done` будет некому.
    func enterRestarting(tag: String, build: Int) {
        lock.lock()
        stage = .restarting
        if !tag.isEmpty { targetTag = tag }
        if build > 0 { targetBuild = build }
        let h = Handoff(tag: targetTag, build: targetBuild, ts: Date().timeIntervalSince1970)
        handoff = h
        lock.unlock()

        try? FileManager.default.createDirectory(
            at: handoffURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(h) {
            try? data.write(to: handoffURL, options: .atomic)
        }
    }

    /// Держит процесс живым, пока телефон не заберёт стадию `restarting` (или пока не
    /// истечёт таймаут). Зовётся ПЕРЕД тем, как поднять новый инстанс: пока мы живы,
    /// порт агента занят нами, и новому процессу драться за него не нужно.
    /// При обновлении не по API (staged/кнопка в UI) возвращается мгновенно.
    func awaitRestartingDelivered(timeout: TimeInterval) {
        lock.lock()
        let mustWait = apiInitiated
        lock.unlock()
        guard mustWait else { return }

        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            lock.lock()
            let delivered = restartingDelivered
            lock.unlock()
            if delivered {
                // Флаг ставится в обработчике, ДО того как байты ответа ушли в сокет —
                // даём записи дописаться, иначе клиент получит обрыв вместо ответа.
                Thread.sleep(forTimeInterval: 0.3)
                return
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
    }

    func fail(_ message: String) {
        lock.lock()
        stage = .error
        errorText = message
        inFlight = false
        apiInitiated = false
        lock.unlock()
    }
}
