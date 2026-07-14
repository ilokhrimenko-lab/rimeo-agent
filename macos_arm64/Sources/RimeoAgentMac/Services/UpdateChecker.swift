import Foundation

struct UpdateInfo {
    let version:     String
    let downloadURL: String
    let notes:       String
}

final class UpdateChecker {
    static let shared = UpdateChecker()
    private init() {}

    private let stampFile = FileManager.default.urls(
        for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("RimeoAgent/last_update_check")

    // MARK: - Кэш «последнего билда» (для capabilities в /api/data)

    private let latestLock = NSLock()
    private var _latestKnownBuild = 0
    private var _latestKnownTag   = ""
    private var _lastCheckAt      = Date.distantPast

    /// Билд последнего релиза, который агент видел на GitHub. 0 — ещё ни разу не
    /// спрашивали (это НЕ значит «обновлений нет»). Читается синхронно из /api/data —
    /// поэтому только кэш, без похода в сеть.
    var latestKnownBuild: Int {
        latestLock.lock(); defer { latestLock.unlock() }
        return _latestKnownBuild
    }

    var latestKnownTag: String {
        latestLock.lock(); defer { latestLock.unlock() }
        return _latestKnownTag
    }

    /// Билд запущенного сейчас агента (из тега релиза, вшитого в build_info.py).
    var currentBuild: Int { parseBuild(AppConfig.shared.releaseTag) }

    func buildNumber(ofTag tag: String) -> Int { parseBuild(tag) }

    /// Ненавязчиво освежает кэш для capabilities: не чаще раза в 15 минут и всегда в
    /// фоне — /api/data не имеет права ждать GitHub.
    func refreshLatestInBackgroundIfStale() {
        latestLock.lock()
        let due = Date().timeIntervalSince(_lastCheckAt) > 900
        // Слот занимаем ДО ухода в фон: иначе десяток параллельных /api/data устроит
        // шторм запросов к GitHub API (и упрётся в rate limit).
        if due { _lastCheckAt = Date() }
        latestLock.unlock()
        guard due else { return }
        DispatchQueue.global(qos: .utility).async { _ = self.fetchLatest() }
    }

    // Called automatically at startup — respects 24h cooldown
    func checkAsync(callback: @escaping (UpdateInfo?) -> Void) {
        DispatchQueue.global(qos: .utility).async {
            guard self.isDue else { callback(nil); return }
            self.stamp()
            callback(self.fetchLatest())
        }
    }

    // Called by the user manually — always hits the network
    func forceCheckAsync(callback: @escaping (UpdateInfo?) -> Void) {
        DispatchQueue.global(qos: .utility).async {
            self.stamp()
            callback(self.fetchLatest())
        }
    }

    // MARK: - Silent staging (hourly check downloads in background; apply on next launch)

    private var stagedZipURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("RimeoAgent/staged_update.zip")
    }

    /// Hourly background check: if a strictly-newer build is available, download its
    /// zip to a staging file and record the tag. No UI, no relaunch — installed on
    /// the next launch via `applyStagedUpdateIfPresent()`.
    func checkAndStageSilently() {
        DispatchQueue.global(qos: .utility).async {
            guard let info = self.fetchLatest() else { return }
            // Same build already staged on disk? Don't re-download.
            if DataStore.shared.data.staged_update_tag == info.version,
               FileManager.default.fileExists(atPath: self.stagedZipURL.path) { return }
            do {
                try FileManager.default.createDirectory(
                    at: self.stagedZipURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true)
                try self.downloadZip(info, to: self.stagedZipURL) { _ in }
                DataStore.shared.update { $0.staged_update_tag = info.version }
                logger.info("Staged silent update: \(info.version)")
            } catch {
                logger.warning("Silent update staging failed: \(error)")
            }
        }
    }

    /// Called at launch before the UI: if a staged build is ready and strictly newer
    /// than the running one, install it (extract+replace) and relaunch. Returns true
    /// when applying (the process is about to exit/relaunch).
    @discardableResult
    func applyStagedUpdateIfPresent() -> Bool {
        let tag = DataStore.shared.data.staged_update_tag
        guard !tag.isEmpty,
              parseBuild(tag) > parseBuild(AppConfig.shared.releaseTag),
              FileManager.default.fileExists(atPath: stagedZipURL.path) else {
            // Stale / own-build / missing zip — clear the record.
            if !tag.isEmpty { DataStore.shared.update { $0.staged_update_tag = "" } }
            try? FileManager.default.removeItem(at: stagedZipURL)
            return false
        }
        do {
            logger.info("Applying staged update \(tag) at launch")
            DataStore.shared.update { $0.staged_update_tag = "" }
            try applyZip(at: stagedZipURL, tag: tag)   // extract+replace+relaunch → exit(0)
            return true
        } catch {
            logger.warning("Applying staged update failed: \(error)")
            UpdateProgress.shared.fail(error.localizedDescription)
            try? FileManager.default.removeItem(at: stagedZipURL)
            return false
        }
    }

    // MARK: - On-demand обновление (POST /api/agent/update с телефона)

    enum StartUpdateOutcome {
        case started(tag: String, build: Int, notes: String)
        case upToDate
        case inProgress
        case checkFailed      // GitHub не ответил — это НЕ «обновлений нет»
    }

    /// Ставит последний релиз ПРЯМО СЕЙЧАС, не дожидаясь часового фонового цикла.
    /// Блокируется только на опрос GitHub (иначе нечем ответить на «а есть ли куда
    /// обновляться»); скачивание, проверка подписи и подмена бандла уходят в фон, а
    /// стадии телефон забирает из GET /api/agent/update/status.
    func startUpdateNow() -> StartUpdateOutcome {
        guard UpdateProgress.shared.tryBeginAPIUpdate() else { return .inProgress }

        let found: UpdateInfo
        switch fetchLatestResult() {
        case .update(let info): found = info
        case .upToDate:         UpdateProgress.shared.abortBegin(); return .upToDate
        case .failed:           UpdateProgress.shared.abortBegin(); return .checkFailed
        }

        let build = parseBuild(found.version)
        UpdateProgress.shared.startDownload(tag: found.version, build: build)

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let tmp = FileManager.default.temporaryDirectory
                    .appendingPathComponent("rimeo_upd_\(UUID().uuidString)")
                try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
                defer { try? FileManager.default.removeItem(at: tmp) }
                let zipPath = tmp.appendingPathComponent("update.zip")
                // Ровно те же примитивы, что и у авто-апдейта: качаем zip + .sig и
                // отдаём в applyZip, который fail-closed проверяет подпись. Своей
                // «облегчённой» проверки тут нет и быть не может.
                try self.downloadZip(found, to: zipPath) { UpdateProgress.shared.setDownloadFraction($0) }
                try self.applyZip(at: zipPath, tag: found.version)   // verify → install → restart → exit(0)
            } catch {
                logger.warning("On-demand update failed: \(error)")
                UpdateProgress.shared.fail(error.localizedDescription)
            }
        }
        logger.info("On-demand update started: \(found.version)")
        return .started(tag: found.version, build: build, notes: found.notes)
    }

    // Download + apply immediately (manual "Update now" flow).
    func downloadAndApply(_ info: UpdateInfo, progress: @escaping (Double) -> Void) throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("rimeo_upd_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let zipPath = tmp.appendingPathComponent("update.zip")
        do {
            try downloadZip(info, to: zipPath) { progress($0 * 0.85) }
            progress(0.9)
            try applyZip(at: zipPath, tag: info.version)   // relaunches → exit(0)
        } catch {
            UpdateProgress.shared.fail(error.localizedDescription)
            throw error
        }
    }

    private func downloadZip(_ info: UpdateInfo, to dest: URL, progress: @escaping (Double) -> Void) throws {
        guard let dlURL = URL(string: info.downloadURL) else {
            throw NSError(domain: "Updater", code: 1, userInfo: [NSLocalizedDescriptionKey: "Invalid URL"])
        }
        var req = URLRequest(url: dlURL, timeoutInterval: 300)
        req.setValue("RimeoAgentMac/\(AppConfig.shared.version)", forHTTPHeaderField: "User-Agent")
        let sema = DispatchSemaphore(value: 0)
        var dlError: Error?
        let task = URLSession.shared.downloadTask(with: req) { localURL, _, err in
            if let err { dlError = err; sema.signal(); return }
            if let lURL = localURL {
                try? FileManager.default.removeItem(at: dest)
                do { try FileManager.default.moveItem(at: lURL, to: dest) }
                catch { dlError = error }
            }
            sema.signal()
        }
        task.resume()
        let obs = task.progress.observe(\.fractionCompleted) { p, _ in progress(p.fractionCompleted) }
        sema.wait()
        obs.invalidate()
        if let e = dlError { throw e }

        // 6005: fetch the detached signature alongside the archive. Best-effort —
        // if it is absent, applyZip's fail-closed verification rejects the update.
        downloadSignatureBestEffort(zipURL: dlURL, sigDest: dest.appendingPathExtension("sig"))
    }

    private func downloadSignatureBestEffort(zipURL: URL, sigDest: URL) {
        guard let sigURL = URL(string: zipURL.absoluteString + ".sig") else { return }
        var req = URLRequest(url: sigURL, timeoutInterval: 60)
        req.setValue("RimeoAgentMac/\(AppConfig.shared.version)", forHTTPHeaderField: "User-Agent")
        let sema = DispatchSemaphore(value: 0)
        URLSession.shared.downloadTask(with: req) { localURL, resp, _ in
            defer { sema.signal() }
            guard let localURL, (resp as? HTTPURLResponse)?.statusCode == 200 else { return }
            try? FileManager.default.removeItem(at: sigDest)
            try? FileManager.default.moveItem(at: localURL, to: sigDest)
        }.resume()
        sema.wait()
    }

    // Extract zip → replace running bundle (unprivileged, osascript fallback) → relaunch → exit(0).
    private func applyZip(at zipPath: URL, tag: String) throws {
        // Стадии для GET /api/agent/update/status ставятся ровно вокруг настоящих
        // шагов: «verifying» держится, пока идут ОБЕ проверки подписи (detached ES256
        // на архив + Developer ID на .app), и снимается только после них.
        UpdateProgress.shared.enterVerifying(tag: tag)

        // 6005: verify the archive's detached ECDSA-P256/SHA-256 signature with the
        // baked update public key BEFORE extracting it. Fail-closed — a missing or
        // invalid .sig aborts the update. Identical check runs on Windows.
        try UpdateSignatureVerifier.verifyZipSignature(
            zipPath: zipPath.path, sigPath: zipPath.path + ".sig")
        logger.info("Update archive signature verified (detached ES256)")

        let ext = FileManager.default.temporaryDirectory
            .appendingPathComponent("rimeo_apply_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: ext, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: ext) }

        let unzip = Process()
        unzip.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        unzip.arguments = ["-q", zipPath.path, "-d", ext.path]
        try unzip.run(); unzip.waitUntilExit()

        guard let newApp = try FileManager.default.contentsOfDirectory(
            at: ext, includingPropertiesForKeys: nil
        ).first(where: { $0.pathExtension == "app" }) else {
            throw NSError(domain: "Updater", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "No .app in archive"])
        }

        let currentPath = Bundle.main.bundleURL.path
        let newAppPath  = newApp.path

        // 6005: verify the downloaded .app is Developer-ID signed by OUR team
        // (codesign --verify --strict + TeamIdentifier == MM3Q8TJL85) BEFORE it can
        // replace the running bundle. A compromised GitHub release can serve a zip
        // but cannot forge our signature, so verification throws here → no replace,
        // no silent RCE. Fail-closed: any error aborts the update.
        try UpdateSignatureVerifier.verify(appPath: newAppPath)
        logger.info("Update signature verified (Developer ID team \(UpdateSignatureVerifier.expectedTeamID))")

        // Подпись проверена — только теперь трогаем установленный бандл.
        UpdateProgress.shared.enterInstalling()

        // Unprivileged replace first (works when the bundle is in a user-writable
        // location → fully silent). Fall back to osascript (admin prompt) otherwise.
        let replaced = (try? replaceApp(from: newAppPath, to: currentPath)) ?? false
        if !replaced {
            // 6005: never interpolate a path with shell metacharacters into the
            // privileged `do shell script` (command-injection hardening).
            guard UpdateSignatureVerifier.isSafeShellPath(currentPath),
                  UpdateSignatureVerifier.isSafeShellPath(newAppPath) else {
                throw UpdateSignatureError.unsafePath("update bundle path contains unsafe characters")
            }
            let shellCmd = "rm -rf '\(currentPath)' && cp -R '\(newAppPath)' '\(currentPath)'"
            let appleScript = "do shell script \"\(shellCmd)\" with administrator privileges"
            let osascript = Process()
            osascript.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            osascript.arguments = ["-e", appleScript]
            try osascript.run(); osascript.waitUntilExit()
            guard osascript.terminationStatus == 0 else {
                throw NSError(domain: "Updater", code: 3,
                              userInfo: [NSLocalizedDescriptionKey: "Installation failed"])
            }
        }

        try? FileManager.default.removeItem(at: stagedZipURL)
        logger.info("Update installed — relaunching")
        DataStore.shared.update { $0.just_updated = true }

        // Процесс сейчас умрёт (exit 0), и вместе с ним HTTP-сервер. Стадию
        // «restarting» отдаём ДО выхода: ждём, пока телефон её реально заберёт (или
        // 5 с таймаута) — и только потом поднимаем новый инстанс, иначе новый процесс
        // упрётся в порт, который ещё держим мы. При staged-апдейте на старте ждать
        // некого, и awaitRestartingDelivered возвращается мгновенно.
        UpdateProgress.shared.enterRestarting(tag: tag, build: parseBuild(tag))
        UpdateProgress.shared.awaitRestartingDelivered(timeout: 5)

        let reopen = Process()
        reopen.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        reopen.arguments = [currentPath]
        try reopen.run()
        exit(0)
    }

    // MARK: - Pending update (update on next launch)

    var pendingUpdate: UpdateInfo? {
        let d = DataStore.shared.data
        guard !d.pending_update_url.isEmpty else { return nil }
        return UpdateInfo(version: d.pending_update_tag, downloadURL: d.pending_update_url, notes: "")
    }

    func setPending(_ info: UpdateInfo) {
        DataStore.shared.update {
            $0.pending_update_url = info.downloadURL
            $0.pending_update_tag = info.version
        }
    }

    func clearPending() {
        DataStore.shared.update {
            $0.pending_update_url = ""
            $0.pending_update_tag = ""
        }
    }

    // MARK: - Private

    // Trailing run of digits: "mac-v1.0-build214" -> 214, "214" -> 214, "dev" -> 0.
    private func parseBuild(_ s: String?) -> Int {
        guard let s, !s.isEmpty else { return 0 }
        var i = s.endIndex
        while i > s.startIndex, s[s.index(before: i)].isNumber { i = s.index(before: i) }
        return Int(s[i...]) ?? 0
    }

    /// Три РАЗНЫХ исхода опроса GitHub. `failed` (сеть/парсинг) — не то же самое, что
    /// `upToDate`: телефону, нажавшему «Обновить», нельзя врать «у вас последняя
    /// версия», когда мы просто не дозвонились до GitHub.
    private enum FetchResult {
        case update(UpdateInfo)
        case upToDate
        case failed
    }

    private func fetchLatest() -> UpdateInfo? {
        if case .update(let info) = fetchLatestResult() { return info }
        return nil
    }

    private func fetchLatestResult() -> FetchResult {
        let repo = AppConfig.shared.githubRepo
        // Iterate ALL releases and pick the highest BUILD NUMBER that ships a mac
        // asset. GitHub's /releases/latest is ordered by publish date and is
        // unreliable when mac/win release tags interleave (the "seesaw": a newer
        // win-only release made /latest carry no mac asset → no update found).
        guard repo != "your-org/rimeo",
              let url = URL(string: "https://api.github.com/repos/\(repo)/releases?per_page=50")
        else { return .failed }

        var req = URLRequest(url: url)
        req.setValue("RimeoAgentMac/\(AppConfig.shared.version)", forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 10

        let sema = DispatchSemaphore(value: 0)
        var payload: Data?
        URLSession.shared.dataTask(with: req) { data, _, _ in
            payload = data; sema.signal()
        }.resume()
        sema.wait()

        guard let data = payload,
              let releases = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else { return .failed }

        let assetName = "RimeoAgent_mac.zip"
        let currentBuild = parseBuild(AppConfig.shared.releaseTag)
        var bestBuild = currentBuild
        var best: UpdateInfo? = nil

        for rel in releases {
            if (rel["draft"] as? Bool) == true || (rel["prerelease"] as? Bool) == true { continue }
            let tag = rel["tag_name"] as? String ?? ""
            let b = parseBuild(tag)
            if b <= bestBuild { continue }   // only ever offer a strictly newer build
            guard let assets = rel["assets"] as? [[String: Any]],
                  let asset  = assets.first(where: { $0["name"] as? String == assetName }),
                  let dlURL  = asset["browser_download_url"] as? String else { continue }
            bestBuild = b
            best = UpdateInfo(version: tag, downloadURL: dlURL,
                              notes: (rel["body"] as? String ?? "").prefix(400).description)
        }

        // GitHub ответил — кэшируем «самый свежий известный билд» для capabilities.
        // bestBuild стартует с текущего и только растёт, так что это max(current, latest).
        latestLock.lock()
        _latestKnownBuild = bestBuild
        _latestKnownTag   = best?.version ?? AppConfig.shared.releaseTag
        _lastCheckAt      = Date()
        latestLock.unlock()

        guard let best else { return .upToDate }
        logger.info("Update available: build\(currentBuild) → \(best.version)")
        return .update(best)
    }

    private func replaceApp(from src: String, to dst: String) throws -> Bool {
        let fm = FileManager.default
        guard fm.isWritableFile(atPath: (dst as NSString).deletingLastPathComponent) else { return false }
        if fm.fileExists(atPath: dst) { try fm.removeItem(atPath: dst) }
        try fm.copyItem(atPath: src, toPath: dst)
        return true
    }

    private var isDue: Bool {
        guard let data = try? Data(contentsOf: stampFile),
              let str  = String(data: data, encoding: .utf8),
              let date = ISO8601DateFormatter().date(from: str.trimmingCharacters(in: .whitespacesAndNewlines))
        else { return true }
        return Date().timeIntervalSince(date) > 86400
    }

    private func stamp() {
        try? ISO8601DateFormatter().string(from: Date())
            .write(to: stampFile, atomically: true, encoding: .utf8)
    }
}
