import Foundation

final class TunnelManager {
    static let shared = TunnelManager()
    private init() {}

    private var proc:          Process?
    private var tunnelURL:     String = ""
    private var _shouldRun:    Bool   = false
    private var _loopRunning:  Bool   = false
    private let lock           = NSLock()
    private let normalRestartDelay: TimeInterval = 5
    private let maxRestartDelay: TimeInterval = 300
    private let rateLimitRestartDelay: TimeInterval = 15 * 60

    // Tracks when the last successful tunnel connection was established
    private var lastTunnelEstablished: Date? = nil
    // Keepalive: last time we sent a ping through the tunnel
    private var lastKeepaliveSent: Date? = nil
    private let keepaliveInterval: TimeInterval = 9 * 60  // 9 min (QUIC idle timeout is ~18 min)
    // Stuck-loop detection: kill process if tunnel was established but hasn't reconnected in this interval
    private let stuckDetectionInterval: TimeInterval = 10 * 60

    var activeURL: String { lock.lock(); defer { lock.unlock() }; return tunnelURL }
    var isRunning: Bool   { lock.lock(); defer { lock.unlock() }; return proc?.isRunning == true }

    func autoStartIfAvailable() {
        if findCloudflared() != nil {
            start()
            scheduleHealthCheck()
        } else {
            logger.warning("Tunnel auto-start skipped: required system component not found")
            DataStore.shared.update { $0.tunnel_url = "" }
        }
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
            .appendingPathComponent("Contents/MacOS/tunnel-runtime").path
        if FileManager.default.isExecutableFile(atPath: bundled) { return bundled }

        let appSupport = ComponentManager.shared.componentURL(id: "tunnel-runtime").path
        if FileManager.default.isExecutableFile(atPath: appSupport) { return appSupport }

        let locations = [
            "/usr/local/bin/cloudflared", "/opt/homebrew/bin/cloudflared",
            "/usr/bin/cloudflared", "\(NSHomeDirectory())/.local/bin/cloudflared"
        ]
        for loc in locations where FileManager.default.isExecutableFile(atPath: loc) { return loc }
        return findSystemExecutable("cloudflared")
    }

    private func shouldKeepRunning() -> Bool {
        lock.lock(); defer { lock.unlock() }; return _shouldRun
    }

    private func scheduleHealthCheck() {
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 120) { [weak self] in
            guard let self = self else { return }
            lock.lock()
            let shouldRun        = _shouldRun
            let loopRunning      = _loopRunning
            let currentURL       = tunnelURL
            let established      = lastTunnelEstablished
            let lastKeepalive    = lastKeepaliveSent
            let currentProc      = proc
            lock.unlock()

            if shouldRun {
                if !loopRunning {
                    logger.warning("Tunnel health check: loop not running, restarting")
                    start()
                } else if !currentURL.isEmpty {
                    // Tunnel is active — send keepalive if due
                    let now = Date()
                    let sinceKeepalive = now.timeIntervalSince(lastKeepalive ?? .distantPast)
                    if sinceKeepalive >= keepaliveInterval {
                        logger.debug("Tunnel health check: ok, url=\(currentURL) — sending keepalive ping")
                        sendKeepalivePing(to: currentURL)
                        lock.lock(); lastKeepaliveSent = now; lock.unlock()
                    } else {
                        logger.debug("Tunnel health check: ok, url=\(currentURL)")
                    }
                } else if let established = established {
                    // Tunnel URL cleared (connection dropped) — check if stuck
                    let minutesSinceEstablished = Date().timeIntervalSince(established) / 60
                    if minutesSinceEstablished >= stuckDetectionInterval / 60 {
                        logger.warning("Tunnel health check: cloudflared stuck reconnecting for \(Int(minutesSinceEstablished))m, killing process to force restart")
                        currentProc?.terminate()
                        lock.lock(); lastTunnelEstablished = nil; lock.unlock()
                    } else {
                        logger.debug("Tunnel health check: cloudflared reconnecting (\(Int(minutesSinceEstablished))m since last connection)")
                    }
                } else {
                    logger.debug("Tunnel health check: cloudflared running, awaiting URL")
                }
            }
            scheduleHealthCheck()
        }
    }

    private func sendKeepalivePing(to tunnelURL: String) {
        guard let url = URL(string: "\(tunnelURL)/api/status") else { return }
        var req = URLRequest(url: url)
        req.timeoutInterval = 10
        URLSession.shared.dataTask(with: req) { _, resp, error in
            if let error = error {
                logger.warning("Tunnel keepalive ping failed: \(error.localizedDescription)")
            } else {
                let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
                logger.debug("Tunnel keepalive ping: HTTP \(status)")
            }
        }.resume()
    }

    private func runTunnel() {
        defer {
            lock.lock(); _loopRunning = false; lock.unlock()
            logger.info("Tunnel loop exited")
        }

        var consecutiveFailures = 0

        while shouldKeepRunning() {
            guard let cmd = findCloudflared() else {
                logger.error("cloudflared not found in bundle or system paths")
                return
            }

            let p = Process()
            p.executableURL = URL(fileURLWithPath: cmd)
            p.arguments = [
                "tunnel", "--url",
                "http://127.0.0.1:\(AppConfig.shared.port)",
                "--metrics", "127.0.0.1:0",
                "--no-autoupdate",
                "--protocol", "http2"
            ]

            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError  = pipe

            do { try p.run() } catch {
                logger.error("cloudflared launch failed: \(error)")
                guard shouldKeepRunning() else { return }
                consecutiveFailures += 1
                let delay = restartDelay(forFailures: consecutiveFailures)
                logger.info("cloudflared launch retry in \(formatDelay(delay))")
                sleepWhileRunning(delay)
                continue
            }

            lock.lock(); proc = p; lock.unlock()
            logger.info("cloudflared started (path: \(cmd))")

            let urlRegex = try? NSRegularExpression(
                pattern: "https://[a-zA-Z0-9-]+\\.trycloudflare\\.com")

            let fh = pipe.fileHandleForReading
            var sawTunnelURL = false
            var sawRateLimit = false
            while p.isRunning {
                let data = fh.availableData
                guard !data.isEmpty, let line = String(data: data, encoding: .utf8) else {
                    Thread.sleep(forTimeInterval: 0.1)
                    continue
                }
                logger.debug("cloudflared: \(line.trimmingCharacters(in: .newlines))")
                if isRateLimitOutput(line) {
                    sawRateLimit = true
                }
                if let regex = urlRegex, tunnelURL.isEmpty {
                    let range = NSRange(line.startIndex ..< line.endIndex, in: line)
                    if let match = regex.firstMatch(in: line, range: range),
                       let swiftRange = Range(match.range, in: line) {
                        let url = String(line[swiftRange])
                        sawTunnelURL = true
                        consecutiveFailures = 0
                        lock.lock()
                        tunnelURL = url
                        lastTunnelEstablished = Date()
                        lastKeepaliveSent = nil
                        lock.unlock()
                        logger.info("Tunnel active: \(url)")
                        DataStore.shared.update { $0.tunnel_url = url }
                        DispatchQueue.main.async { AppState.shared.tunnelURL = url; AppState.shared.tunnelActive = true }
                        CloudRelay.shared.noteTunnelChanged(url)
                        CloudRelay.shared.pushTunnelUpdate(url)
                    }
                }
            }

            lock.lock()
            tunnelURL = ""
            proc = nil
            lastKeepaliveSent = nil
            // Keep lastTunnelEstablished so the stuck-loop watchdog knows when the connection dropped
            lock.unlock()
            DataStore.shared.update { $0.tunnel_url = "" }
            DispatchQueue.main.async { AppState.shared.tunnelURL = ""; AppState.shared.tunnelActive = false }
            CloudRelay.shared.noteTunnelChanged("")
            logger.info("cloudflared stopped")

            guard shouldKeepRunning() else { break }
            let delay: TimeInterval
            if sawRateLimit {
                consecutiveFailures += 1
                delay = rateLimitRestartDelay
                logger.warning("cloudflared hit Cloudflare quick tunnel rate limit; pausing restart for \(formatDelay(delay))")
                AppState.shared.setTunnelRateLimited(delay: delay)
            } else if sawTunnelURL {
                consecutiveFailures = 0
                delay = normalRestartDelay
                logger.info("cloudflared restarting in \(formatDelay(delay))")
            } else {
                consecutiveFailures += 1
                delay = restartDelay(forFailures: consecutiveFailures)
                logger.info("cloudflared restarting in \(formatDelay(delay)) after \(consecutiveFailures) failed attempt(s)")
            }
            sleepWhileRunning(delay)
        }
    }

    private func isRateLimitOutput(_ line: String) -> Bool {
        line.localizedCaseInsensitiveContains("429 Too Many Requests")
            || line.localizedCaseInsensitiveContains("error code: 1015")
    }

    private func restartDelay(forFailures failures: Int) -> TimeInterval {
        let exponent = max(0, min(failures - 1, 6))
        let delay = normalRestartDelay * pow(2.0, Double(exponent))
        return min(delay, maxRestartDelay)
    }

    private func sleepWhileRunning(_ delay: TimeInterval) {
        let deadline = Date().addingTimeInterval(delay)
        while shouldKeepRunning() && Date() < deadline {
            Thread.sleep(forTimeInterval: min(1, deadline.timeIntervalSinceNow))
        }
    }

    private func formatDelay(_ delay: TimeInterval) -> String {
        if delay >= 60 {
            let minutes = Int(delay / 60)
            let seconds = Int(delay) % 60
            return seconds == 0 ? "\(minutes)m" : "\(minutes)m \(seconds)s"
        }
        return "\(Int(delay))s"
    }
}
