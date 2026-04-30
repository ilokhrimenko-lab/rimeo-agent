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

    // Download zip, extract .app, run shell script to replace current bundle + relaunch
    func downloadAndApply(_ info: UpdateInfo, progress: @escaping (Double) -> Void) throws {
        guard let dlURL = URL(string: info.downloadURL) else {
            throw NSError(domain: "Updater", code: 1, userInfo: [NSLocalizedDescriptionKey: "Invalid URL"])
        }

        let tmp    = FileManager.default.temporaryDirectory
            .appendingPathComponent("rimeo_upd_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let zipPath = tmp.appendingPathComponent("update.zip")

        // Download
        var req = URLRequest(url: dlURL, timeoutInterval: 300)
        req.setValue("RimeoAgentMac/\(AppConfig.shared.version)", forHTTPHeaderField: "User-Agent")

        let sema = DispatchSemaphore(value: 0)
        var dlError: Error?
        let task = URLSession.shared.downloadTask(with: req) { localURL, _, err in
            if let err { dlError = err; sema.signal(); return }
            if let lURL = localURL { try? FileManager.default.moveItem(at: lURL, to: zipPath) }
            sema.signal()
        }
        task.resume()
        let obs = task.progress.observe(\.fractionCompleted) { p, _ in
            progress(p.fractionCompleted * 0.8)
        }
        sema.wait()
        obs.invalidate()
        if let e = dlError { throw e }

        // Extract
        let ext = tmp.appendingPathComponent("ext")
        try FileManager.default.createDirectory(at: ext, withIntermediateDirectories: true)
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

        let currentApp = Bundle.main.bundleURL
        let newAppPath = newApp.path
        let currentPath = currentApp.path

        // Try unprivileged replace first (works when .app is in user-writable location)
        let replaced = (try? replaceApp(from: newAppPath, to: currentPath)) ?? false

        if !replaced {
            // Fall back to osascript — shows Touch ID / password dialog
            let shellCmd = "rm -rf '\(currentPath)' && cp -R '\(newAppPath)' '\(currentPath)'"
            let appleScript = "do shell script \"\(shellCmd)\" with administrator privileges"
            let osascript = Process()
            osascript.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            osascript.arguments = ["-e", appleScript]
            try osascript.run()
            osascript.waitUntilExit()
            guard osascript.terminationStatus == 0 else {
                throw NSError(domain: "Updater", code: 3,
                              userInfo: [NSLocalizedDescriptionKey: "Installation cancelled or failed"])
            }
        }

        progress(1.0)
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

    private func fetchLatest() -> UpdateInfo? {
        let repo = AppConfig.shared.githubRepo
        guard repo != "your-org/rimeo",
              let url = URL(string: "https://api.github.com/repos/\(repo)/releases/latest")
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
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag  = json["tag_name"] as? String, !tag.isEmpty,
              tag != AppConfig.shared.releaseTag else { return nil }

        let assetName = "RimeoAgent_mac.zip"
        guard let assets = json["assets"] as? [[String: Any]],
              let asset  = assets.first(where: { $0["name"] as? String == assetName }),
              let dlURL  = asset["browser_download_url"] as? String else { return nil }

        logger.info("Update available: \(AppConfig.shared.version) → \(tag)")
        return UpdateInfo(
            version:     tag,
            downloadURL: dlURL,
            notes:       (json["body"] as? String ?? "").prefix(400).description
        )
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
