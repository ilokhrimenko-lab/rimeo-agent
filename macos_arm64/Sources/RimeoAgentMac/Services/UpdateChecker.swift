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

    func checkAsync(callback: @escaping (UpdateInfo?) -> Void) {
        DispatchQueue.global(qos: .utility).async {
            callback(self.check())
        }
    }

    func check() -> UpdateInfo? {
        guard isDue else { return nil }
        stamp()

        let repo    = AppConfig.shared.githubRepo
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
              tag != AppConfig.shared.version else { return nil }

        let assetName = "RimeoAgentMac.zip"
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
        sema.wait()
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

        // Get current bundle path
        let currentApp = Bundle.main.bundleURL
        let script = tmp.appendingPathComponent("update.sh")
        let scriptText = """
        #!/bin/bash
        sleep 2
        rm -rf "\(currentApp.path)"
        cp -R "\(newApp.path)" "\(currentApp.path)"
        open "\(currentApp.path)"
        rm -rf "\(tmp.path)"
        """
        try scriptText.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)

        let sh = Process()
        sh.executableURL = URL(fileURLWithPath: "/bin/bash")
        sh.arguments = [script.path]
        try sh.run()

        logger.info("Update script launched — exiting")
        exit(0)
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
