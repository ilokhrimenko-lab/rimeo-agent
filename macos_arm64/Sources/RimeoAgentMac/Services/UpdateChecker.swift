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
            try applyZip(at: stagedZipURL)   // extract+replace+relaunch → exit(0)
            return true
        } catch {
            logger.warning("Applying staged update failed: \(error)")
            try? FileManager.default.removeItem(at: stagedZipURL)
            return false
        }
    }

    // Download + apply immediately (manual "Update now" flow).
    func downloadAndApply(_ info: UpdateInfo, progress: @escaping (Double) -> Void) throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("rimeo_upd_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let zipPath = tmp.appendingPathComponent("update.zip")
        try downloadZip(info, to: zipPath) { progress($0 * 0.85) }
        progress(0.9)
        try applyZip(at: zipPath)   // relaunches → exit(0)
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
    }

    // Extract zip → replace running bundle (unprivileged, osascript fallback) → relaunch → exit(0).
    private func applyZip(at zipPath: URL) throws {
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

        // Unprivileged replace first (works when the bundle is in a user-writable
        // location → fully silent). Fall back to osascript (admin prompt) otherwise.
        let replaced = (try? replaceApp(from: newAppPath, to: currentPath)) ?? false
        if !replaced {
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

    private func fetchLatest() -> UpdateInfo? {
        let repo = AppConfig.shared.githubRepo
        // Iterate ALL releases and pick the highest BUILD NUMBER that ships a mac
        // asset. GitHub's /releases/latest is ordered by publish date and is
        // unreliable when mac/win release tags interleave (the "seesaw": a newer
        // win-only release made /latest carry no mac asset → no update found).
        guard repo != "your-org/rimeo",
              let url = URL(string: "https://api.github.com/repos/\(repo)/releases?per_page=50")
        else { return nil }

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
        else { return nil }

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

        if let best { logger.info("Update available: build\(currentBuild) → \(best.version)") }
        return best
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
