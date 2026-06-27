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

    // Readiness probe: cloudflared prints the URL ~30-50s before the tunnel
    // actually proxies. Stage the URL here while probing /api/status through
    // it; only promote to tunnelURL (and publish to cloud) after a 2xx response.
    private var pendingTunnelURL: String = ""
    private let readinessMaxAttempts: Int = 30
    private let readinessInterval: TimeInterval = 2.0
    private let readinessProbeTimeout: TimeInterval = 5.0

    // Diagnostics
    private var currentMode: String = "unknown"        // "named" | "quick" | "unknown"
    private var currentNamedUUID: String = ""
    private var currentNamedHostname: String = ""

    var activeURL: String { lock.lock(); defer { lock.unlock() }; return tunnelURL }
    var isRunning: Bool   { lock.lock(); defer { lock.unlock() }; return proc?.isRunning == true }
    // Hostname assigned by the named tunnel (e.g. "<hash>.agent.rimeo.app").
    // Empty when running in quick-tunnel mode. Used as the JWT audience claim.
    var namedHostname: String { lock.lock(); defer { lock.unlock() }; return currentNamedHostname }

    struct DiagSnapshot {
        let mode: String
        let namedUUID: String
        let namedHostname: String
        let activeURL: String
        let pendingURL: String
        let lastEstablished: Date?
        let lastKeepalive: Date?
        let cloudflaredFound: Bool
        let processRunning: Bool
        let shouldRun: Bool
    }

    func diagSnapshot() -> DiagSnapshot {
        lock.lock(); defer { lock.unlock() }
        return DiagSnapshot(
            mode: currentMode,
            namedUUID: currentNamedUUID,
            namedHostname: currentNamedHostname,
            activeURL: tunnelURL,
            pendingURL: pendingTunnelURL,
            lastEstablished: lastTunnelEstablished,
            lastKeepalive: lastKeepaliveSent,
            cloudflaredFound: findCloudflared() != nil,
            processRunning: proc?.isRunning == true,
            shouldRun: _shouldRun
        )
    }

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
        _shouldRun       = true
        _loopRunning     = true
        tunnelURL        = ""
        pendingTunnelURL = ""
        lock.unlock()
        DispatchQueue.global(qos: .utility).async { self.runTunnel() }
    }

    func stop() {
        lock.lock()
        _shouldRun       = false
        proc?.terminate()
        proc             = nil
        tunnelURL        = ""
        pendingTunnelURL = ""
        lock.unlock()
        DataStore.shared.update { $0.tunnel_url = "" }
        AppState.shared.refreshFromData()
    }

    /// True when a valid named-tunnel config.yml is present (tunnel uuid +
    /// hostname). Used by TunnelProvisioner to avoid clobbering an existing
    /// (server- or manually-provisioned) named tunnel.
    func hasNamedTunnelConfig() -> Bool { parseNamedTunnelConfig() != nil }

    /// Recycle cloudflared so a freshly-written config.yml takes effect. The
    /// run loop re-reads parseNamedTunnelConfig() on every iteration, so
    /// terminating the current process is enough to flip quick → named. If the
    /// loop isn't running yet, start it.
    func reloadAfterConfigChange() {
        lock.lock()
        let running = _loopRunning
        let p = proc
        lock.unlock()
        if running {
            logger.info("Tunnel config changed — recycling cloudflared to apply named tunnel")
            p?.terminate()
        } else {
            logger.info("Tunnel config changed — starting tunnel to apply named tunnel")
            start()
        }
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

    private func probeReadinessAndPromote(candidateURL: String) {
        for attempt in 1...readinessMaxAttempts {
            lock.lock()
            let stillPending = (pendingTunnelURL == candidateURL && tunnelURL.isEmpty && _shouldRun)
            lock.unlock()
            guard stillPending else {
                logger.debug("Tunnel readiness probe abandoned: candidate=\(candidateURL) no longer pending")
                return
            }
            if probeReadinessOnce(candidateURL) {
                logger.info("Tunnel ready after \(attempt) probe(s): \(candidateURL)")
                promote(candidateURL: candidateURL)
                return
            }
            Thread.sleep(forTimeInterval: readinessInterval)
        }
        logger.warning("Tunnel readiness probe exhausted \(readinessMaxAttempts) attempts; promoting anyway: \(candidateURL)")
        promote(candidateURL: candidateURL)
    }

    private func probeReadinessOnce(_ url: String) -> Bool {
        guard let probeURL = URL(string: "\(url)/api/status") else { return false }
        var req = URLRequest(url: probeURL)
        // ВАЖНО: GET, не HEAD. Роутер матчит по (метод, путь) и HEAD-кейса для
        // /api/status нет → HEAD проваливается в default → 404 (≥400) → probe
        // НИКОГДА не проходит и каждый холодный старт впустую жжёт 30×2с до
        // «promoting anyway». GET /api/status отдаёт 200 и промоут срабатывает сразу.
        req.httpMethod = "GET"
        req.timeoutInterval = readinessProbeTimeout
        let sema = DispatchSemaphore(value: 0)
        var alive = false
        URLSession.shared.dataTask(with: req) { _, resp, error in
            if error == nil, let http = resp as? HTTPURLResponse, http.statusCode < 400 {
                alive = true
            }
            sema.signal()
        }.resume()
        sema.wait()
        return alive
    }

    private func promote(candidateURL: String) {
        lock.lock()
        guard pendingTunnelURL == candidateURL && tunnelURL.isEmpty else { lock.unlock(); return }
        tunnelURL = candidateURL
        lastTunnelEstablished = Date()
        lastKeepaliveSent = nil
        pendingTunnelURL = ""
        lock.unlock()
        logger.info("Tunnel active: \(candidateURL)")
        DataStore.shared.update { $0.tunnel_url = candidateURL }
        DispatchQueue.main.async {
            AppState.shared.tunnelURL = candidateURL
            AppState.shared.tunnelActive = true
        }
        CloudRelay.shared.noteTunnelChanged(candidateURL)
        CloudRelay.shared.pushTunnelUpdate(candidateURL)
    }

    private struct NamedTunnelConfig {
        let uuid: String
        let hostname: String
        let configPath: String
    }

    private func parseNamedTunnelConfig() -> NamedTunnelConfig? {
        let path = "\(AppConfig.shared.cloudflaredDir)/config.yml"
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
        var uuid: String?
        var hostname: String?
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            if uuid == nil, line.hasPrefix("tunnel:") {
                let value = line.dropFirst("tunnel:".count).trimmingCharacters(in: .whitespaces)
                if !value.isEmpty { uuid = value }
            }
            if hostname == nil, let range = line.range(of: "hostname:") {
                let value = line[range.upperBound...].trimmingCharacters(in: .whitespaces)
                if !value.isEmpty { hostname = value }
            }
            if uuid != nil && hostname != nil { break }
        }
        guard let uuid, let hostname else { return nil }
        return NamedTunnelConfig(uuid: uuid, hostname: hostname, configPath: path)
    }

    /// Kill stray `tunnel-runtime` processes left over from a previous agent
    /// instance (crash, force-quit, or silent self-update that replaced the app
    /// without our `stop()` running). We own this named tunnel exclusively, so any
    /// pre-existing tunnel-runtime is by definition orphaned. Two cloudflared
    /// connectors registering the SAME tunnel make Cloudflare round-robin across
    /// the duplicate registrations — which surfaces to the user as audio stutter
    /// and "http2: stream closed" errors. Called right before we launch our own
    /// process; at that point our previous child (if any) has already exited, so
    /// we additionally skip any still-running child we own.
    private func reapStrayTunnelRuntimes() {
        let runtimePath = ComponentManager.shared.componentURL(id: "tunnel-runtime").path
        lock.lock(); let ownPid = (proc?.isRunning == true) ? proc?.processIdentifier : nil; lock.unlock()

        let pgrep = Process()
        pgrep.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        pgrep.arguments = ["-f", runtimePath]
        let pipe = Pipe()
        pgrep.standardOutput = pipe
        pgrep.standardError  = Pipe()
        do { try pgrep.run() } catch {
            logger.warning("Stray-tunnel reap skipped: pgrep launch failed: \(error)")
            return
        }
        pgrep.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let out = String(data: data, encoding: .utf8) else { return }

        for line in out.split(whereSeparator: \.isNewline) {
            guard let pid = Int32(line.trimmingCharacters(in: .whitespaces)) else { continue }
            if pid == ownPid { continue }
            logger.warning("Reaping stray tunnel-runtime pid=\(pid) before launching ours (orphaned duplicate on the same named tunnel — cause of stream stutter)")
            kill(pid, SIGTERM)
        }
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

            // Clear any orphaned cloudflared from a prior agent run before we add
            // ours — duplicates on the same tunnel cause playback stutter.
            reapStrayTunnelRuntimes()

            let namedConfig = parseNamedTunnelConfig()
            let p = Process()
            p.executableURL = URL(fileURLWithPath: cmd)
            if let named = namedConfig {
                p.arguments = [
                    "tunnel",
                    "--config", named.configPath,
                    "--metrics", "127.0.0.1:0",
                    "--no-autoupdate",
                    "--protocol", "http2",
                    "run", named.uuid
                ]
                lock.lock()
                currentMode = "named"
                currentNamedUUID = named.uuid
                currentNamedHostname = named.hostname
                lock.unlock()
                logger.info("Tunnel mode: named (uuid=\(named.uuid), hostname=\(named.hostname))")
            } else {
                p.arguments = [
                    "tunnel", "--url",
                    "http://127.0.0.1:\(AppConfig.shared.port)",
                    "--metrics", "127.0.0.1:0",
                    "--no-autoupdate",
                    "--protocol", "http2"
                ]
                lock.lock()
                currentMode = "quick"
                currentNamedUUID = ""
                currentNamedHostname = ""
                lock.unlock()
            }

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

            if let named = namedConfig {
                let candidate = "https://\(named.hostname)"
                sawTunnelURL = true
                consecutiveFailures = 0
                lock.lock()
                pendingTunnelURL = candidate
                lock.unlock()
                logger.info("Named tunnel URL pending readiness probe: \(candidate)")
                DispatchQueue.global(qos: .utility).async { [weak self] in
                    self?.probeReadinessAndPromote(candidateURL: candidate)
                }
            }
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
                if let regex = urlRegex, tunnelURL.isEmpty, pendingTunnelURL.isEmpty {
                    let range = NSRange(line.startIndex ..< line.endIndex, in: line)
                    if let match = regex.firstMatch(in: line, range: range),
                       let swiftRange = Range(match.range, in: line) {
                        let url = String(line[swiftRange])
                        sawTunnelURL = true
                        consecutiveFailures = 0
                        lock.lock()
                        pendingTunnelURL = url
                        lock.unlock()
                        logger.info("Tunnel URL pending readiness probe: \(url)")
                        DispatchQueue.global(qos: .utility).async { [weak self] in
                            self?.probeReadinessAndPromote(candidateURL: url)
                        }
                    }
                }
            }

            lock.lock()
            tunnelURL = ""
            pendingTunnelURL = ""
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
