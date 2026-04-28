import Foundation

final class TunnelManager {
    static let shared = TunnelManager()
    private init() {}

    private var proc:      Process?
    private var tunnelURL: String = ""
    private let lock      = NSLock()

    var activeURL: String { lock.lock(); defer { lock.unlock() }; return tunnelURL }
    var isRunning: Bool   { lock.lock(); defer { lock.unlock() }; return proc?.isRunning == true }

    func autoStartIfAvailable() {
        guard findCloudflared() != nil else { return }
        start()
    }

    func start() {
        lock.lock()
        if proc?.isRunning == true { lock.unlock(); return }
        tunnelURL = ""
        lock.unlock()

        DispatchQueue.global(qos: .utility).async { self.runTunnel() }
    }

    func stop() {
        lock.lock()
        proc?.terminate()
        proc      = nil
        tunnelURL = ""
        lock.unlock()
        DataStore.shared.update { $0.tunnel_url = "" }
        AppState.shared.refreshFromData()
    }

    func findCloudflared() -> String? {
        let locations = [
            "/usr/local/bin/cloudflared", "/opt/homebrew/bin/cloudflared",
            "/usr/bin/cloudflared", "\(NSHomeDirectory())/.local/bin/cloudflared"
        ]
        for loc in locations where FileManager.default.fileExists(atPath: loc) { return loc }
        return findBinary("cloudflared")
    }

    private func runTunnel() {
        guard let cmd = findCloudflared() else {
            logger.error("cloudflared not found — install: brew install cloudflared")
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

        do { try p.run() } catch { logger.error("cloudflared launch failed: \(error)"); return }

        lock.lock(); proc = p; lock.unlock()
        logger.info("cloudflared started")

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
                }
            }
        }

        lock.lock(); tunnelURL = ""; proc = nil; lock.unlock()
        DataStore.shared.update { $0.tunnel_url = "" }
        DispatchQueue.main.async { AppState.shared.tunnelURL = ""; AppState.shared.tunnelActive = false }
        logger.info("cloudflared stopped")
    }
}
