import Foundation

/// Секрет на время жизни процесса. Релей штампует им свои запросы к самому себе
/// (127.0.0.1), чтобы access-лог мог отличить их от трафика cloudflared и от
/// локального браузера — все трое приходят с одного и того же loopback-адреса.
/// Именно поэтому ключ, а не заголовок-константа: константу подделал бы любой,
/// кто открыл localhost:8000 в браузере, и метка транспорта в логе стала бы ложью.
enum RelayMarker {
    static let key = UUID().uuidString
}

/// Сводка релей-цикла раз в 5 минут вместо строки на каждый поллинг.
///
/// Построчный лог поллинга занимал **91% всего файла** и вытеснял из 500-строчного
/// буфера всё полезное — глубина памяти лога падала до ~17 минут. Гасим его порогом
/// (`debug`), но признак жизни релея терять нельзя — поэтому счётчики + периодический
/// итог. Живёт под замком: `loop()` один, но пусть будет честно.
final class RelayHeartbeat {
    private let lock = NSLock()
    var polls = 0, cmds = 0, errors = 0
    private var windowStart = Date()

    func flushIfDue(every seconds: TimeInterval = 300) {
        lock.lock()
        guard Date().timeIntervalSince(windowStart) >= seconds else { lock.unlock(); return }
        let (p, c, e) = (polls, cmds, errors)
        polls = 0; cmds = 0; errors = 0
        windowStart = Date()
        lock.unlock()
        logger.info("[RELAY] heartbeat: polls=\(p) cmds=\(c) errors=\(e) window=\(Int(seconds / 60))m")
    }
}

let beat = RelayHeartbeat()

// Long-poll relay: polls cloud /api/relay/poll/<agentID>, forwards commands
// to the local HTTP server, then posts results back to the cloud.
final class CloudRelay {
    static let shared = CloudRelay()
    private init() {}

    // Capability flags advertised to the cloud on every poll / binding so it can
    // version-gate playlist-mobile routes (finding-12): a build without this flag
    // gets 426 "agent update required" instead of a silent 404 that would leave
    // the phone's overlay wedged as forever-pending. Comma-separated for growth.
    static let capabilities = "playlists_v1"

    private let stateLock = NSLock()
    private var running = false

    private let pollQueue = DispatchQueue(label: "rimeo.relay.poll", qos: .utility)
    private let commandQueue = DispatchQueue(label: "rimeo.relay.command", qos: .utility, attributes: .concurrent)
    private var lastAdvertisedTunnel: String?

    func startIfLinked() {
        let data = DataStore.shared.data
        guard !data.cloud_url.isEmpty, !data.cloud_token.isEmpty else { return }
        start(cloudURL: data.cloud_url, token: data.cloud_token)
    }

    func start(cloudURL: String, token: String) {
        stateLock.lock()
        if running {
            stateLock.unlock()
            return
        }
        running = true
        stateLock.unlock()

        pollQueue.async {
            self.loop(initialCloudURL: cloudURL, initialToken: token)
        }
    }

    func stop() {
        stateLock.lock()
        running = false
        stateLock.unlock()
    }

    private func isRunning() -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return running
    }

    private func loop(initialCloudURL: String, initialToken: String) {
        var backoff: TimeInterval = 1
        // Consecutive non-definitive 403s (token_mismatch / unknown). A single 403
        // is no longer treated as proof of "signed in elsewhere" — it can be a
        // transient race (a quick re-login, server blip). Only a definitive
        // `evicted` reason, or N consecutive non-definitive 403s, signs us out.
        var consecutive403 = 0

        while isRunning() {
            let data = DataStore.shared.data
            let cloudURL = data.cloud_url.isEmpty ? initialCloudURL : data.cloud_url
            let cloudToken = data.cloud_token.isEmpty ? initialToken : data.cloud_token

            if cloudURL.isEmpty || cloudToken.isEmpty {
                Thread.sleep(forTimeInterval: 30)
                continue
            }

            let tunnel = TunnelManager.shared.activeURL
            var pollURL = "\(cloudURL)/api/relay/poll/\(AppConfig.shared.agentID)?token=\(cloudToken)"
            let encodedTunnel = tunnel.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
            pollURL += "&tunnel=\(encodedTunnel)"
            // П7: report build so the server can gate named-tunnel + JWT on
            // agent_min_build (old agents that omit this stay on quick-tunnel).
            let encodedBuild = AppConfig.shared.buildNumber.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
            pollURL += "&build=\(encodedBuild)"
            pollURL += "&caps=\(CloudRelay.capabilities)"
            // LAN-PSK по heartbeat: агент, уже связанный с облаком, повторно
            // /api/agent/login не дёргает, поэтому линковка — не канал. Публикуем
            // секрет здесь, и облако передаст его телефону того же аккаунта. Без
            // этого прямой путь по локалке не включается (телефон уходит в туннель).
            let encodedPSK = APIRouter.ensureLANSecret()
                .addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
            pollURL += "&lan_secret=\(encodedPSK)"
            logTunnelAdvertisementIfChanged(tunnel)

            guard let url = URL(string: pollURL) else {
                Thread.sleep(forTimeInterval: 10)
                continue
            }

            logger.debug("Cloud relay poll: \(cloudURL)")
            beat.polls += 1
            beat.flushIfDue()

            var req = URLRequest(url: url)
            req.timeoutInterval = 30
            AppConfig.shared.applyCloudHeaders(to: &req)

            let sema = DispatchSemaphore(value: 0)
            var respData: Data?
            var httpCode = 0
            var requestError: Error?

            URLSession.shared.dataTask(with: req) { data, resp, error in
                respData = data
                httpCode = (resp as? HTTPURLResponse)?.statusCode ?? 0
                requestError = error
                sema.signal()
            }.resume()
            sema.wait()

            if let requestError {
                // Benign: the long-poll was held open with no command to deliver
                // and timed out. Re-poll immediately — backing off here makes the
                // agent deaf to new requests for up to 30s during quiet periods.
                if (requestError as? URLError)?.code == .timedOut {
                    backoff = 1
                    continue
                }
                logger.warning("Cloud relay error: \(requestError.localizedDescription), retry in \(Int(backoff))s")
                Thread.sleep(forTimeInterval: backoff)
                backoff = min(backoff * 2, 30)
                continue
            }

            if httpCode == 403 {
                var reason: String?
                if let respData,
                   let json = try? JSONSerialization.jsonObject(with: respData),
                   let obj = json as? [String: Any] {
                    reason = obj["reason"] as? String
                }
                // `evicted` = the binding is gone → the account signed in on another
                // computer (single active agent per account). Definitive: sign out.
                if reason == "evicted" {
                    logger.warning("Cloud relay: 403 evicted — signed in elsewhere. Clearing session.")
                    // Keep cloud_user_id (email): the account is de-authed but we
                    // prefill the sign-in gate with the email so reconnecting is a
                    // one-tap password re-entry, not a blank cold gate. An explicit
                    // Sign out still clears the email.
                    DataStore.shared.update { d in
                        d.cloud_url = ""
                        d.cloud_token = ""
                    }
                    DispatchQueue.main.async { AppState.shared.refreshFromData() }
                    self.stop()
                    return
                }
                // `token_mismatch` / unknown: the token was superseded — usually a
                // transient race (a quick re-login). Retry; only sign out if it
                // persists, so a single racy 403 no longer kicks the user out.
                consecutive403 += 1
                if consecutive403 >= 3 {
                    logger.warning("Cloud relay: 403 (\(reason ?? "no reason")) persisted ×\(consecutive403) — clearing session.")
                    // Keep cloud_user_id (email): the account is de-authed but we
                    // prefill the sign-in gate with the email so reconnecting is a
                    // one-tap password re-entry, not a blank cold gate. An explicit
                    // Sign out still clears the email.
                    DataStore.shared.update { d in
                        d.cloud_url = ""
                        d.cloud_token = ""
                    }
                    DispatchQueue.main.async { AppState.shared.refreshFromData() }
                    self.stop()
                    return
                }
                logger.warning("Cloud relay: 403 (\(reason ?? "no reason")) — retry \(consecutive403)/3 in \(Int(backoff))s")
                Thread.sleep(forTimeInterval: backoff)
                backoff = min(backoff * 2, 30)
                continue
            }

            guard httpCode == 200, let data = respData else {
                logger.warning("Cloud relay poll: HTTP \(httpCode), retry in \(Int(backoff))s")
                Thread.sleep(forTimeInterval: backoff)
                backoff = min(backoff * 2, 30)
                continue
            }
            consecutive403 = 0

            guard let msg = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                logger.warning("Cloud relay error: invalid JSON payload, retry in \(Int(backoff))s")
                Thread.sleep(forTimeInterval: backoff)
                backoff = min(backoff * 2, 30)
                continue
            }

            backoff = 1

            if (msg["type"] as? String) == "ping" {
                // The cloud piggybacks whether a phone is signed in to this account
                // on the idle heartbeat, so the Devices tab can show a real status.
                if let phone = msg["phone"] as? Bool {
                    DispatchQueue.main.async { AppState.shared.phoneConnected = phone }
                }
                continue
            }

            let reqID = msg["req_id"] as? String ?? ""
            let method = msg["method"] as? String ?? "GET"
            let path = msg["path"] as? String ?? "/"
            logger.debug("Cloud relay cmd: req_id=\(reqID) method=\(method) path=\(path)")
            beat.cmds += 1

            commandQueue.async {
                self.handleCommand(msg, cloudURL: cloudURL)
            }
        }
    }

    func noteTunnelChanged(_ tunnelURL: String) {
        logger.info("Cloud relay tunnel state changed: tunnel_url=\(tunnelURL.isEmpty ? "(none)" : tunnelURL)")
    }

    func pushTunnelUpdate(_ tunnelURL: String) {
        let data = DataStore.shared.data
        guard !data.cloud_url.isEmpty, !data.cloud_token.isEmpty,
              let encoded = tunnelURL.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "\(data.cloud_url)/api/relay/poll/\(AppConfig.shared.agentID)?token=\(data.cloud_token)&tunnel=\(encoded)&build=\(AppConfig.shared.buildNumber.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")&caps=\(CloudRelay.capabilities)") else { return }
        var req = URLRequest(url: url)
        req.timeoutInterval = 5
        AppConfig.shared.applyCloudHeaders(to: &req)
        URLSession.shared.dataTask(with: req) { _, _, _ in
            logger.info("Tunnel URL pushed to cloud: \(tunnelURL)")
        }.resume()
    }

    private func logTunnelAdvertisementIfChanged(_ tunnelURL: String) {
        stateLock.lock()
        let previous = lastAdvertisedTunnel
        if previous != tunnelURL {
            lastAdvertisedTunnel = tunnelURL
        }
        stateLock.unlock()

        guard previous != tunnelURL else { return }
        if tunnelURL.isEmpty {
            logger.warning("Cloud relay advertising no tunnel URL. If the web app only plays audio through direct tunnel URLs, waveform/artwork can work while audio never requests /stream.")
        } else {
            logger.info("Cloud relay advertising tunnel URL: \(tunnelURL)")
        }
    }

    /// Replays a cloud-relayed request against the local HTTP server (127.0.0.1).
    /// THREAT MODEL (6006): the cloud signs its own JWT, so a relayed request clears
    /// authGate — a compromised cloud could reach protected endpoints. This is now
    /// BOUNDED by 6002 (LibraryPathGuard): the file endpoints only ever serve files
    /// inside the library's own directories, so even a hostile relay can NOT read
    /// arbitrary host files (e.g. ~/.ssh/id_rsa). Remote control via relay-JWT is a
    /// deliberate feature; see README "Threat model & trust boundaries".
    private func handleCommand(_ cmd: [String: Any], cloudURL: String) {
        let reqID = cmd["req_id"] as? String ?? ""
        let method = cmd["method"] as? String ?? "GET"
        let path = cmd["path"] as? String ?? "/"
        let rawHeaders = cmd["headers"] as? [String: String] ?? [:]
        let headers = rawHeaders.filter { !$0.key.isEmpty && !$0.value.isEmpty }
        let bodyB64 = cmd["body"] as? String
        let body = bodyB64.flatMap { Data(base64Encoded: $0) }
        let rangeHeader = headers.first { $0.key.lowercased() == "range" }?.value ?? "(none)"

        logger.debug("Relay local request: req=\(reqID), method=\(method), path=\(path), range=\(rangeHeader), headers=\(headers.count), body_bytes=\(body?.count ?? 0)")
        if path.hasPrefix("/stream"), rangeHeader == "(none)" {
            logger.warning("Relay stream request has no Range header: req=\(reqID), path=\(path). Audio may require large buffered relay response.")
        }

        guard let localURL = URL(string: "http://127.0.0.1:\(AppConfig.shared.port)\(path)") else { return }

        var req = URLRequest(url: localURL)
        req.httpMethod = method
        req.httpBody = body
        req.timeoutInterval = 30
        headers.forEach { key, value in
            let lower = key.lowercased()
            guard lower != "host" else { return }
            req.setValue(value, forHTTPHeaderField: key)
        }
        // Метка релея. Без неё запрос от CloudRelay неотличим в логе от cloudflared и
        // от локального браузера — все трое приходят с 127.0.0.1. Ключ генерится на
        // запуск процесса, поэтому подделать метку RELAY снаружи невозможно.
        // Host релей намеренно вырезает (выше), так что опознать его по нему нельзя.
        req.setValue(RelayMarker.key, forHTTPHeaderField: "X-Rimeo-Relay-Key")
        req.setValue(reqID,           forHTTPHeaderField: "X-Rimeo-Req-Id")

        let sema = DispatchSemaphore(value: 0)
        var resultBody = Data()
        var resultStatus = 502
        var resultHeaders = [String: String]()
        var localError: Error?
        let startedAt = Date()

        URLSession.shared.dataTask(with: req) { data, resp, error in
            localError = error
            resultBody = data ?? Data()
            if let http = resp as? HTTPURLResponse {
                resultStatus = http.statusCode
                http.allHeaderFields.forEach { key, value in
                    resultHeaders["\(key)"] = "\(value)"
                }
            } else if error != nil {
                resultStatus = 502
            }
            sema.signal()
        }.resume()
        sema.wait()
        let elapsed = Date().timeIntervalSince(startedAt)

        let result: [String: Any]
        if let localError {
            logger.error("Relay error req=\(reqID) path=\(path): \(localError.localizedDescription)")
            result = [
                "req_id": reqID,
                "status": 502,
                "headers": [:],
                "body_b64": Data(localError.localizedDescription.utf8).base64EncodedString(),
            ]
        } else {
            logger.debug("Relay local response: req=\(reqID), status=\(resultStatus), body_bytes=\(resultBody.count), elapsed=\(String(format: "%.2f", elapsed))s, path=\(path)")
            result = [
                "req_id": reqID,
                "status": resultStatus,
                "headers": resultHeaders,
                "body_b64": resultBody.base64EncodedString(),
            ]
        }

        guard let resultData = try? JSONSerialization.data(withJSONObject: result),
              let resultURL = URL(string: "\(cloudURL)/api/relay/result") else {
            return
        }

        var post = URLRequest(url: resultURL)
        post.httpMethod = "POST"
        post.httpBody = resultData
        post.timeoutInterval = 30
        AppConfig.shared.applyCloudHeaders(to: &post, contentType: "application/json")

        let sema2 = DispatchSemaphore(value: 0)
        var postError: Error?
        var postStatus = 0
        URLSession.shared.dataTask(with: post) { _, response, error in
            postError = error
            postStatus = (response as? HTTPURLResponse)?.statusCode ?? 0
            sema2.signal()
        }.resume()
        sema2.wait()

        if let postError {
            logger.error("Relay result POST failed req=\(reqID): \(postError.localizedDescription)")
        } else if postStatus != 200 {
            logger.error("Relay result POST failed req=\(reqID): HTTP \(postStatus)")
        } else {
            logger.debug("Relay result POST ok req=\(reqID) status=\(resultStatus)")
        }
    }
}
