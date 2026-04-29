import Foundation

final class TunnelManager {
    static let shared = TunnelManager()
    private init() {}

    private var proc:          Process?
    private var tunnelURL:     String = ""
    private var _shouldRun:    Bool   = false
    private var _loopRunning:  Bool   = false
    private let lock           = NSLock()

    var activeURL: String { lock.lock(); defer { lock.unlock() }; return tunnelURL }
    var isRunning: Bool   { lock.lock(); defer { lock.unlock() }; return proc?.isRunning == true }

    func autoStartIfAvailable() {
        if findCloudflared() != nil {
            start()
            scheduleHealthCheck()
        } else {
            logger.info("cloudflared not found, attempting runtime download")
            downloadCloudflaredIfNeeded { [weak self] success in
                guard let self = self else { return }
                if success {
                    self.start()
                    self.scheduleHealthCheck()
                } else {
                    logger.warning("Tunnel auto-start skipped: cloudflared download failed")
                    DataStore.shared.update { $0.tunnel_url = "" }
                }
            }
        }
    }

    private static var appSupportCloudflaredPath: String {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first!.appendingPathComponent("RimeoAgent").path
        return (dir as NSString).appendingPathComponent("cloudflared")
    }

    private func downloadCloudflaredIfNeeded(completion: @escaping (Bool) -> Void) {
        let destPath = Self.appSupportCloudflaredPath
        if FileManager.default.isExecutableFile(atPath: destPath) {
            logger.info("cloudflared already in app support: \(destPath)")
            completion(true)
            return
        }

        let arch = {
            var info = utsname()
            uname(&info)
            let machine = withUnsafeBytes(of: &info.machine) { ptr in
                ptr.bindMemory(to: CChar.self).baseAddress.map { String(cString: $0) } ?? ""
            }
            return machine.contains("arm") ? "arm64" : "amd64"
        }()

        logger.info("Fetching latest cloudflared release tag (arch: \(arch))...")

        guard let apiURL = URL(string: "https://api.github.com/repos/cloudflare/cloudflared/releases/latest") else {
            completion(false); return
        }

        URLSession.shared.dataTask(with: apiURL) { data, _, error in
            guard let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tag = json["tag_name"] as? String else {
                logger.error("cloudflared: failed to fetch release tag: \(error?.localizedDescription ?? "no data")")
                completion(false)
                return
            }

            let asset = "cloudflared-darwin-\(arch)"
            guard let dlURL = URL(string: "https://github.com/cloudflare/cloudflared/releases/download/\(tag)/\(asset)") else {
                completion(false); return
            }

            logger.info("Downloading cloudflared \(tag) (\(asset))...")

            URLSession.shared.downloadTask(with: dlURL) { tmpURL, _, dlError in
                guard let tmpURL = tmpURL else {
                    logger.error("cloudflared download failed: \(dlError?.localizedDescription ?? "unknown")")
                    completion(false)
                    return
                }

                do {
                    let dir = (destPath as NSString).deletingLastPathComponent
                    try FileManager.default.createDirectory(atPath: dir,
                        withIntermediateDirectories: true, attributes: nil)
                    if FileManager.default.fileExists(atPath: destPath) {
                        try FileManager.default.removeItem(atPath: destPath)
                    }
                    try FileManager.default.moveItem(at: tmpURL, to: URL(fileURLWithPath: destPath))
                    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: destPath)
                    logger.info("cloudflared installed to \(destPath)")
                    completion(true)
                } catch {
                    logger.error("cloudflared install failed: \(error)")
                    completion(false)
                }
            }.resume()
        }.resume()
    }

    func start() {
        lock.lock()
        if _loopRunning { lock.unlock(); return }
        _shouldRun   = true
        _loopRunning = true
        tunnelURL    = ""
        lock.unlock()
        DispatchQueue.global(qos: .utility).async { self.runTunnel() }
    }

    func stop() {
        lock.lock()
        _shouldRun = false
        proc?.terminate()
        proc      = nil
        tunnelURL = ""
        lock.unlock()
        DataStore.shared.update { $0.tunnel_url = "" }
        AppState.shared.refreshFromData()
    }

    func findCloudflared() -> String? {
        let bundled = Bundle.main.bundleURL
            .appendingPathComponent("Contents/MacOS/cloudflared").path
        if FileManager.default.isExecutableFile(atPath: bundled) { return bundled }

        let appSupport = Self.appSupportCloudflaredPath
        if FileManager.default.isExecutableFile(atPath: appSupport) { return appSupport }

        let locations = [
            "/usr/local/bin/cloudflared", "/opt/homebrew/bin/cloudflared",
            "/usr/bin/cloudflared", "\(NSHomeDirectory())/.local/bin/cloudflared"
        ]
        for loc in locations where FileManager.default.fileExists(atPath: loc) { return loc }
        return findBinary("cloudflared")
    }

    private func shouldKeepRunning() -> Bool {
        lock.lock(); defer { lock.unlock() }; return _shouldRun
    }

    private func scheduleHealthCheck() {
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 600) { [weak self] in
            guard let self = self else { return }
            lock.lock()
            let shouldRun    = _shouldRun
            let loopRunning  = _loopRunning
            let currentURL   = tunnelURL
            lock.unlock()

            if shouldRun {
                if !loopRunning {
                    logger.warning("Tunnel health check: loop not running, restarting")
                    start()
                } else if currentURL.isEmpty {
                    logger.debug("Tunnel health check: cloudflared running, awaiting URL")
                } else {
                    logger.debug("Tunnel health check: ok, url=\(currentURL)")
                }
            }
            scheduleHealthCheck()
        }
    }

    private func runTunnel() {
        defer {
            lock.lock(); _loopRunning = false; lock.unlock()
            logger.info("Tunnel loop exited")
        }

        while shouldKeepRunning() {
            guard let cmd = findCloudflared() else {
                logger.error("cloudflared not found in bundle or system paths")
                return
            }

            let p = Process()
            p.executableURL = URL(fileURLWithPath: cmd)
            p.arguments = [
                "tunnel", "--url",
                "http://localhost:\(AppConfig.shared.port)",
                "--no-autoupdate"
            ]

            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError  = pipe

            do { try p.run() } catch {
                logger.error("cloudflared launch failed: \(error)")
                guard shouldKeepRunning() else { return }
                Thread.sleep(forTimeInterval: 5)
                continue
            }

            lock.lock(); proc = p; lock.unlock()
            logger.info("cloudflared started (path: \(cmd))")

            let urlRegex = try? NSRegularExpression(
                pattern: "https://[a-zA-Z0-9-]+\\.trycloudflare\\.com")

            let fh = pipe.fileHandleForReading
            while p.isRunning {
                let data = fh.availableData
                guard !data.isEmpty, let line = String(data: data, encoding: .utf8) else {
                    Thread.sleep(forTimeInterval: 0.1)
                    continue
                }
                logger.debug("cloudflared: \(line.trimmingCharacters(in: .newlines))")
                if let regex = urlRegex, tunnelURL.isEmpty {
                    let range = NSRange(line.startIndex ..< line.endIndex, in: line)
                    if let match = regex.firstMatch(in: line, range: range),
                       let swiftRange = Range(match.range, in: line) {
                        let url = String(line[swiftRange])
                        lock.lock(); tunnelURL = url; lock.unlock()
                        logger.info("Tunnel active: \(url)")
                        DataStore.shared.update { $0.tunnel_url = url }
                        DispatchQueue.main.async { AppState.shared.tunnelURL = url; AppState.shared.tunnelActive = true }
                        CloudRelay.shared.noteTunnelChanged(url)
                        CloudRelay.shared.pushTunnelUpdate(url)
                    }
                }
            }

            lock.lock(); tunnelURL = ""; proc = nil; lock.unlock()
            DataStore.shared.update { $0.tunnel_url = "" }
            DispatchQueue.main.async { AppState.shared.tunnelURL = ""; AppState.shared.tunnelActive = false }
            CloudRelay.shared.noteTunnelChanged("")
            logger.info("cloudflared stopped")

            guard shouldKeepRunning() else { break }
            logger.info("cloudflared restarting in 5s")
            Thread.sleep(forTimeInterval: 5)
        }
    }
}
