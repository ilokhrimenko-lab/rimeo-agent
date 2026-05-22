import Foundation

/// П8: fetches a per-user named cloudflared tunnel from the server and writes
/// the local `~/.cloudflared` config so TunnelManager can switch off the shared
/// quick tunnel onto `<hash>.agent.rimeo.app`.
///
/// No-op when already on a named tunnel, when the agent isn't linked, or when
/// the server declines (rollout gate off / build below threshold / Cloudflare
/// error). Transient declines (throttled / cloudflare_error / db_error) are
/// retried a bounded number of times honouring the server's `retry_after`.
final class TunnelProvisioner {
    static let shared = TunnelProvisioner()
    private init() {}

    private let stateLock = NSLock()
    private var inFlight = false
    private let maxAttempts = 5
    private let retryReasons: Set<String> = ["throttled", "cloudflare_error", "db_error"]

    private var cloudflaredDir: String { "\(NSHomeDirectory())/.cloudflared" }
    private var configPath: String { "\(cloudflaredDir)/config.yml" }

    /// Entry point — call once at startup after the relay is up. Runs the whole
    /// (bounded-retry) flow on a background queue; safe to call repeatedly.
    func provisionIfNeeded() {
        stateLock.lock()
        if inFlight { stateLock.unlock(); return }
        inFlight = true
        stateLock.unlock()

        DispatchQueue.global(qos: .utility).async {
            self.attempt(1)
            self.stateLock.lock(); self.inFlight = false; self.stateLock.unlock()
        }
    }

    private func attempt(_ n: Int) {
        if TunnelManager.shared.hasNamedTunnelConfig() {
            logger.info("Tunnel provision: already on a named tunnel, skipping")
            return
        }
        let data = DataStore.shared.data
        guard !data.cloud_url.isEmpty, !data.cloud_token.isEmpty else {
            logger.debug("Tunnel provision: agent not linked, skipping")
            return
        }

        guard let result = fetch(cloudURL: data.cloud_url, token: data.cloud_token) else {
            if n < maxAttempts {
                logger.debug("Tunnel provision: network error, retry \(n + 1)/\(maxAttempts) in 30s")
                Thread.sleep(forTimeInterval: 30)
                attempt(n + 1)
            }
            return
        }

        if (result["provisioned"] as? Bool) == true {
            apply(result)
            return
        }

        let reason = (result["reason"] as? String) ?? "unknown"
        let retryAfter = doubleValue(result["retry_after"])
        let retryable = retryReasons.contains(reason)
        logger.info("Tunnel provision declined: reason=\(reason)" + (retryable ? ", will retry" : ""))
        if retryable, n < maxAttempts, retryAfter > 0 {
            Thread.sleep(forTimeInterval: min(retryAfter, 300))
            attempt(n + 1)
        }
    }

    private func fetch(cloudURL: String, token: String) -> [String: Any]? {
        let agentID = AppConfig.shared.agentID
        let build = AppConfig.shared.buildNumber
            .addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        let urlStr = "\(cloudURL)/api/agent/tunnel_provision?agent_id=\(agentID)&token=\(token)&build=\(build)"
        guard let url = URL(string: urlStr) else { return nil }

        var req = URLRequest(url: url)
        req.timeoutInterval = 30
        AppConfig.shared.applyCloudHeaders(to: &req)

        let sema = DispatchSemaphore(value: 0)
        var out: [String: Any]?
        URLSession.shared.dataTask(with: req) { data, _, _ in
            if let data, let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                out = json
            }
            sema.signal()
        }.resume()
        sema.wait()
        return out
    }

    private func apply(_ result: [String: Any]) {
        guard let tunnelID = result["tunnel_id"] as? String, !tunnelID.isEmpty,
              let hostname = result["hostname"] as? String, !hostname.isEmpty,
              let credsB64 = result["credentials_b64"] as? String, !credsB64.isEmpty,
              let creds = Data(base64Encoded: credsB64) else {
            logger.warning("Tunnel provision: malformed payload, cannot apply")
            return
        }

        let fm = FileManager.default
        do {
            try fm.createDirectory(atPath: cloudflaredDir, withIntermediateDirectories: true,
                                   attributes: [.posixPermissions: 0o700])
        } catch {
            logger.warning("Tunnel provision: cannot create \(cloudflaredDir): \(error)")
            return
        }

        let credsPath = "\(cloudflaredDir)/\(tunnelID).json"
        do {
            try creds.write(to: URL(fileURLWithPath: credsPath))
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: credsPath)
        } catch {
            logger.warning("Tunnel provision: cannot write credentials file: \(error)")
            return
        }

        // config_src=local — ingress lives here, not on Cloudflare. cloudflared
        // is launched as `tunnel --config <this> run <uuid>` by TunnelManager.
        let yaml = """
        tunnel: \(tunnelID)
        credentials-file: \(credsPath)
        ingress:
          - hostname: \(hostname)
            service: http://127.0.0.1:\(AppConfig.shared.port)
          - service: http_status:404
        """
        do {
            try yaml.write(toFile: configPath, atomically: true, encoding: .utf8)
        } catch {
            logger.warning("Tunnel provision: cannot write config.yml: \(error)")
            return
        }

        let reused = (result["reused"] as? Bool) == true
        logger.info("Tunnel provisioned (\(reused ? "reused" : "new")): hostname=\(hostname), uuid=\(tunnelID) — switching tunnel")
        TunnelManager.shared.reloadAfterConfigChange()
    }

    private func doubleValue(_ any: Any?) -> Double {
        if let d = any as? Double { return d }
        if let i = any as? Int { return Double(i) }
        if let s = any as? String, let d = Double(s) { return d }
        return 0
    }
}
