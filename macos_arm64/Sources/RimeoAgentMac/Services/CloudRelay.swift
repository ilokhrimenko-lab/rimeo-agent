import Foundation

// Long-poll relay: polls cloud /api/relay/poll/<agentID>, forwards commands
// to the local HTTP server, then posts results back to the cloud.
final class CloudRelay {
    static let shared = CloudRelay()
    private init() {}

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
            if !tunnel.isEmpty,
               let encodedTunnel = tunnel.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) {
                pollURL += "&tunnel=\(encodedTunnel)"
            }
            logTunnelAdvertisementIfChanged(tunnel)

            guard let url = URL(string: pollURL) else {
                Thread.sleep(forTimeInterval: 10)
                continue
            }

            logger.info("Cloud relay connecting: \(cloudURL)")

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
                logger.warning("Cloud relay error: \(requestError.localizedDescription), retry in \(Int(backoff))s")
                Thread.sleep(forTimeInterval: backoff)
                backoff = min(backoff * 2, 30)
                continue
            }

            if httpCode == 403 {
                logger.warning("Cloud relay: unauthorized (bad token), retry in 60s")
                Thread.sleep(forTimeInterval: 60)
                backoff = 1
                continue
            }

            guard httpCode == 200, let data = respData else {
                logger.warning("Cloud relay poll: HTTP \(httpCode), retry in \(Int(backoff))s")
                Thread.sleep(forTimeInterval: backoff)
                backoff = min(backoff * 2, 30)
                continue
            }

            guard let msg = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                logger.warning("Cloud relay error: invalid JSON payload, retry in \(Int(backoff))s")
                Thread.sleep(forTimeInterval: backoff)
                backoff = min(backoff * 2, 30)
                continue
            }

            backoff = 1

            if (msg["type"] as? String) == "ping" {
                continue
            }

            let reqID = msg["req_id"] as? String ?? ""
            let method = msg["method"] as? String ?? "GET"
            let path = msg["path"] as? String ?? "/"
            logger.debug("Cloud relay cmd: req_id=\(reqID) method=\(method) path=\(path)")

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
              let url = URL(string: "\(data.cloud_url)/api/relay/poll/\(AppConfig.shared.agentID)?token=\(data.cloud_token)&tunnel=\(encoded)") else { return }
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

    private func handleCommand(_ cmd: [String: Any], cloudURL: String) {
        let reqID = cmd["req_id"] as? String ?? ""
        let method = cmd["method"] as? String ?? "GET"
        let path = cmd["path"] as? String ?? "/"
        let rawHeaders = cmd["headers"] as? [String: String] ?? [:]
        let headers = rawHeaders.filter { !$0.key.isEmpty && !$0.value.isEmpty }
        let bodyB64 = cmd["body"] as? String
        let body = bodyB64.flatMap { Data(base64Encoded: $0) }
        let rangeHeader = headers.first { $0.key.lowercased() == "range" }?.value ?? "(none)"

        logger.info("Relay local request: req=\(reqID), method=\(method), path=\(path), range=\(rangeHeader), headers=\(headers.count), body_bytes=\(body?.count ?? 0)")
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
            logger.info("Relay local response: req=\(reqID), status=\(resultStatus), body_bytes=\(resultBody.count), elapsed=\(String(format: "%.2f", elapsed))s, path=\(path)")
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
