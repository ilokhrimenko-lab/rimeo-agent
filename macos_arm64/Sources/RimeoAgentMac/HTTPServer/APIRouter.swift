import Foundation
import Darwin

// Routes all HTTP requests to the appropriate handler
// Mirrors api_server.py endpoint-for-endpoint

final class APIRouter {
    static let shared = APIRouter()
    private init() {}

    func route(_ req: HTTPRequest) -> HTTPResponse {
        let path = req.path

        switch (req.method, path) {
        // Audio
        case ("GET", "/stream"):         return streamAudio(req)
        case ("GET", "/waveform"):       return getWaveform(req)
        case ("GET", "/artwork"):        return getArtwork(req)
        case ("GET", "/reveal"):         return revealInFinder(req)

        // Library
        case ("GET", "/api/data"):       return getLibraryData(req)

        // Pairing
        case ("GET", "/api/pairing_info"):   return getPairingInfo(req)
        case ("GET", "/api/check_pairing"):  return checkPairing(req)

        // Notes / exclusions
        case ("POST", "/api/save_note"):       return saveNote(req)
        case ("POST", "/api/save_exclusions"): return saveExclusions(req)

        // Telegram
        case ("POST", "/api/send_tg"):     return sendTelegram(req)

        // Analysis
        case ("GET", "/api/analysis"):         return getAnalysis(req)
        case ("GET", "/api/analysis/status"):  return getAnalysisStatus(req)
        case ("POST", "/api/analysis/start"):  return startAnalysis(req)
        case ("POST", "/api/analysis/stop"):   return stopAnalysis(req)
        case ("POST", "/api/analysis/recheck"):return recheckAnalysis(req)
        case ("GET", "/api/analysis/track_list"): return getAnalysedIDs(req)

        // Similar
        case ("GET", "/api/similar"):      return getSimilar(req)

        // Status / account
        case ("GET", "/api/status"):       return getStatus(req)
        case ("GET", "/api/account"):      return getAccount(req)
        case ("POST", "/api/link_account"):    return linkAccount(req)
        case ("POST", "/api/unlink_account"):  return unlinkAccount(req)

        // Tunnel
        case ("GET", "/api/tunnel/status"):  return tunnelStatus(req)
        case ("POST", "/api/tunnel/start"):  return tunnelStart(req)
        case ("POST", "/api/tunnel/stop"):   return tunnelStop(req)

        // Bug report
        case ("POST", "/api/report_bug"):    return reportBug(req)

        default:
            return HTTPResponse.error("Not found", status: 404)
        }
    }

    // MARK: - /stream

    private func streamAudio(_ req: HTTPRequest) -> HTTPResponse {
        guard let filePath = req.queryParams["path"], !filePath.isEmpty else {
            return .error("path required", status: 400)
        }
        let trackID = req.queryParams["id"] ?? ""
        let preload = req.queryParams["preload"] == "1" || req.queryParams["preload"] == "true"
        let ext     = (filePath as NSString).pathExtension.lowercased()

        guard FileManager.default.fileExists(atPath: filePath) else {
            return .error("File not found", status: 404)
        }

        var finalPath = filePath
        if ext == "aif" || ext == "aiff" {
            if preload {
                DispatchQueue.global(qos: .utility).async {
                    _ = try? AudioService.shared.ensureWAV(path: filePath, trackID: trackID)
                }
                return .json(["status": "preloading"])
            }
            do {
                finalPath = try AudioService.shared.ensureWAV(path: filePath, trackID: trackID)
            } catch {
                return .error("Audio conversion failed — retry in a moment", status: 503)
            }
        } else if preload {
            return .json(["status": "preloading"])
        }

        let mime    = mimeType(for: finalPath)
        let size    = (try? FileManager.default.attributesOfItem(atPath: finalPath))?[.size] as? Int ?? 0
        guard size > 0 else { return .error("File empty", status: 404) }

        var start = 0
        var end   = size - 1

        if let rangeHeader = req.headers["range"] {
            let cleaned = rangeHeader.replacingOccurrences(of: "bytes=", with: "")
            let parts   = cleaned.components(separatedBy: "-")
            if parts.count == 2 {
                start = Int(parts[0]) ?? 0
                end   = Int(parts[1].isEmpty ? "\(size - 1)" : parts[1]) ?? (size - 1)
            }
        }

        guard start <= end, start < size else {
            return HTTPResponse(
                status:  416,
                headers: ["Content-Range": "bytes */\(size)"],
                body:    .empty
            )
        }
        end = min(end, size - 1)

        let length    = end - start + 1
        let server    = HTTPServer(port: 0)   // reuse writeAll helper

        return HTTPResponse(
            status: 206,
            headers: [
                "Content-Type":   mime,
                "Content-Length": "\(length)",
                "Content-Range":  "bytes \(start)-\(end)/\(size)",
                "Accept-Ranges":  "bytes",
            ],
            body: .stream { fd in
                guard let fh = FileHandle(forReadingAtPath: finalPath) else { return }
                defer { fh.closeFile() }
                fh.seek(toFileOffset: UInt64(start))
                var remaining = length
                while remaining > 0 {
                    let chunk = min(256 * 1024, remaining)
                    let data  = fh.readData(ofLength: chunk)
                    if data.isEmpty { break }
                    remaining -= data.count
                    server.writeAll(fd, data)
                }
            }
        )
    }

    // MARK: - /waveform

    private func getWaveform(_ req: HTTPRequest) -> HTTPResponse {
        guard let path = req.queryParams["path"], !path.isEmpty,
              let id   = req.queryParams["id"],   !id.isEmpty else {
            return .error("path and id required", status: 400)
        }
        let preload = req.queryParams["preload"] == "1" || req.queryParams["preload"] == "true"
        if preload {
            DispatchQueue.global(qos: .utility).async {
                _ = AudioService.shared.waveform(path: path, trackID: id)
            }
            return .json(["status": "preloading"])
        }
        let result = AudioService.shared.waveform(path: path, trackID: id)
        return .json(result)
    }

    // MARK: - /artwork

    private func getArtwork(_ req: HTTPRequest) -> HTTPResponse {
        guard let path = req.queryParams["path"], !path.isEmpty,
              let id   = req.queryParams["id"],   !id.isEmpty else {
            return .error("path and id required", status: 400)
        }
        let preload = req.queryParams["preload"] == "1" || req.queryParams["preload"] == "true"
        if preload {
            DispatchQueue.global(qos: .utility).async {
                _ = AudioService.shared.artwork(path: path, trackID: id)
            }
            return .json(["status": "preloading"])
        }
        guard let artPath = AudioService.shared.artwork(path: path, trackID: id),
              let data = try? Data(contentsOf: URL(fileURLWithPath: artPath)) else {
            return .error("Artwork not found", status: 404)
        }
        return HTTPResponse(status: 200,
                            headers: ["Content-Type": "image/jpeg",
                                      "Content-Length": "\(data.count)"],
                            body: .data(data))
    }

    // MARK: - /reveal

    private func revealInFinder(_ req: HTTPRequest) -> HTTPResponse {
        guard let path = req.queryParams["path"], FileManager.default.fileExists(atPath: path) else {
            return .error("File not found", status: 404)
        }
        Process.launchedProcess(launchPath: "/usr/bin/open",
                                arguments: ["-R", path])
        return .json(["status": "ok"])
    }

    // MARK: - /api/data

    private func getLibraryData(_ req: HTTPRequest) -> HTTPResponse {
        let lib  = RekordboxParser.shared.parse()
        let data = DataStore.shared.data
        logger.info("GET /api/data -> \(lib.tracks.count) tracks, \(lib.playlists.count) playlists, source=\(lib.source ?? "unknown")")
        let obj: [String: Any] = [
            "tracks":            lib.tracks.map { encodableTrack($0) },
            "playlists":         lib.playlists.map { ["path": $0.path, "date": $0.date] },
            "notes":             data.notes,
            "global_exclusions": data.global_exclusions,
            // Return both keys during parity migration:
            // Python serves library_date, while existing Swift code used xml_date.
            "library_date":      lib.xml_date,
            "xml_date":          lib.xml_date,
        ]
        return .json(obj)
    }

    // MARK: - /api/pairing_info

    private func getPairingInfo(_ req: HTTPRequest) -> HTTPResponse {
        let chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"
        let code  = String((0..<5).map { _ in chars.randomElement()! })

        DataStore.shared.update { $0.pairing_code = code }

        let localIP  = AppConfig.shared.getLocalIP()
        let localURL = "http://\(localIP):\(AppConfig.shared.port)"
        let d        = DataStore.shared.data
        let url      = TunnelManager.shared.activeURL.isEmpty
                        ? (d.tunnel_url.isEmpty ? localURL : d.tunnel_url)
                        : TunnelManager.shared.activeURL
        let qrData   = #"{"url":"\#(url)","code":"\#(code)","agent_id":"\#(AppConfig.shared.agentID)"}"#
        let encoded  = qrData.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? qrData
        let qrURL    = "https://api.qrserver.com/v1/create-qr-code/?size=300x300&data=\(encoded)"

        return .json([
            "code":     code,
            "qr_url":   qrURL,
            "local_url": url,
            "agent_id": AppConfig.shared.agentID,
        ])
    }

    // MARK: - /api/check_pairing

    private func checkPairing(_ req: HTTPRequest) -> HTTPResponse {
        guard let code = req.queryParams["code"] else {
            return .error("code required", status: 400)
        }
        let stored = DataStore.shared.data.pairing_code
        if stored == code.uppercased() || stored == code {
            return .json(["status": "ok"])
        }
        return .error("Invalid pairing code", status: 403)
    }

    // MARK: - /api/save_note

    private func saveNote(_ req: HTTPRequest) -> HTTPResponse {
        guard let body = try? JSONSerialization.jsonObject(with: req.body) as? [String: String],
              let tid  = body["id"] else {
            return .error("Bad request", status: 400)
        }
        let note = (body["note"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        DataStore.shared.update { d in
            if note.isEmpty { d.notes.removeValue(forKey: tid) }
            else            { d.notes[tid] = note }
        }
        return .json(["status": "ok"])
    }

    // MARK: - /api/save_exclusions

    private func saveExclusions(_ req: HTTPRequest) -> HTTPResponse {
        guard let list = try? JSONSerialization.jsonObject(with: req.body) as? [String] else {
            return .error("Expected array of strings", status: 400)
        }
        DataStore.shared.update { $0.global_exclusions = list }
        return .json(["status": "ok"])
    }

    // MARK: - /api/send_tg

    private func sendTelegram(_ req: HTTPRequest) -> HTTPResponse {
        // Simple TG send — token/chat stored in env (optional feature)
        let token  = ProcessInfo.processInfo.environment["RIMEO_TG_TOKEN"] ?? ""
        let chatID = ProcessInfo.processInfo.environment["RIMEO_TG_CHAT_ID"] ?? ""
        guard !token.isEmpty, !chatID.isEmpty else {
            return .error("Telegram not configured", status: 503)
        }
        guard let body = try? JSONSerialization.jsonObject(with: req.body) as? [String: String] else {
            return .error("Bad request", status: 400)
        }
        let text = "🎵 \(body["artist"] ?? "") — \(body["title"] ?? "")"
        let tgURL = URL(string: "https://api.telegram.org/bot\(token)/sendMessage")!
        var post  = URLRequest(url: tgURL)
        post.httpMethod = "POST"
        post.httpBody   = try? JSONSerialization.data(withJSONObject: ["chat_id": chatID, "text": text])
        post.setValue("application/json", forHTTPHeaderField: "Content-Type")
        post.timeoutInterval = 10
        let sema = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: post) { _, _, _ in sema.signal() }.resume()
        sema.wait()
        return .json(["status": "ok"])
    }

    // MARK: - Analysis

    private func getAnalysis(_ req: HTTPRequest) -> HTTPResponse {
        guard let id = req.queryParams["id"] else { return .error("id required", status: 400) }
        guard let feat = AnalysisEngine.shared.getFeatures(id) else {
            return .error("Track not analysed yet", status: 404)
        }
        guard let data = try? JSONEncoder().encode(feat),
              let obj  = try? JSONSerialization.jsonObject(with: data) else {
            return .error("Encode error", status: 500)
        }
        return .json(obj)
    }

    private func getAnalysisStatus(_ req: HTTPRequest) -> HTTPResponse {
        let s = AppState.shared
        let summary = analysisSummary()
        return .json([
            "running": s.analysisRunning,
            "total":   s.analysisRunning ? s.analysisTotal : summary.available,
            "done":    s.analysisDone,
            "current": s.analysisCurrent,
            "errors":  s.analysisErrors,
            "unavailable": s.analysisRunning ? s.analysisUnavailable : summary.unavailable,
            "analyzed_count": summary.analyzed,
            "not_analyzed": summary.notAnalyzed,
            "available_count": summary.available,
            "library_count": summary.library,
            "all_analyzed": summary.notAnalyzed == 0 && summary.available > 0,
        ])
    }

    private func startAnalysis(_ req: HTTPRequest) -> HTTPResponse {
        let s = AppState.shared
        guard !s.analysisRunning else { return .json(["status": "already_running"]) }
        AnalysisEngine.shared.resetCancellation()
        DispatchQueue.main.async {
            s.analysisRunning = true
            s.analysisDone = 0
            s.analysisErrors = 0
            s.analysisUnavailable = 0
            s.analysisCurrent = ""
        }
        DispatchQueue.global(qos: .utility).async { self.runAnalysisJob() }
        return .json(["status": "started"])
    }

    private func stopAnalysis(_ req: HTTPRequest) -> HTTPResponse {
        AnalysisEngine.shared.requestCancel()
        DispatchQueue.main.async {
            AppState.shared.analysisRunning = false
            AppState.shared.analysisCurrent = "Stopping..."
        }
        return .json(["status": "stopping"])
    }

    private func recheckAnalysis(_ req: HTTPRequest) -> HTTPResponse {
        let s = AppState.shared
        guard !s.analysisRunning else { return .json(["status": "already_running"]) }
        let store      = AnalysisEngine.shared.storeSnapshot()
        let required   = Set(["energy", "timbre", "groove", "happiness"])
        let incomplete = store.filter { !required.isSubset(of: Set($0.value.asDictKeys())) }.count
        AnalysisEngine.shared.resetCancellation()
        DispatchQueue.main.async {
            s.analysisRunning = true
            s.analysisDone = 0
            s.analysisErrors = 0
            s.analysisUnavailable = 0
            s.analysisCurrent = ""
        }
        DispatchQueue.global(qos: .utility).async { self.runAnalysisJob() }
        return .json(["status": "started", "incomplete_tracks": incomplete])
    }

    private func runAnalysisJob() {
        let lib    = RekordboxParser.shared.parse()
        var seen   = [String: Track]()
        lib.tracks.forEach { seen[$0.id] = $0 }
        let tracks = Array(seen.values)
        let availableTracks = tracks.filter { FileManager.default.fileExists(atPath: $0.location) }
        let unavailableCount = tracks.count - availableTracks.count
        let total  = availableTracks.count
        let s      = AppState.shared
        var successCount = 0
        var errorCount = 0

        DispatchQueue.main.async {
            s.analysisTotal = total
            s.analysisUnavailable = unavailableCount
        }
        if unavailableCount > 0 {
            logger.info("Analysis skipped unavailable files: \(unavailableCount)")
        }

        let initialStore = AnalysisEngine.shared.storeSnapshot()

        for (i, track) in availableTracks.enumerated() {
            if AnalysisEngine.shared.shouldCancel() { break }
            let label = "\(track.artist) — \(track.title)"
            DispatchQueue.main.async { s.analysisCurrent = label; s.analysisDone = i }

            if let existing = initialStore[track.id],
               existing.energy > 0, !existing.timbre.isEmpty,
               existing.groove > 0, existing.happiness >= 0 {
                successCount += 1
                DispatchQueue.main.async { s.analysisDone = i + 1 }
                continue
            }

            if let result = AnalysisEngine.shared.analyzeTrack(track) {
                AnalysisEngine.shared.setFeatures(track.id, result)
                AnalysisEngine.shared.saveStore()
                successCount += 1
            } else {
                errorCount += 1
                DispatchQueue.main.async { s.analysisErrors = errorCount }
            }
            DispatchQueue.main.async { s.analysisDone = i + 1 }
        }

        AnalysisEngine.shared.saveStore()
        DispatchQueue.main.async {
            s.analysisRunning = false
            if !AnalysisEngine.shared.shouldCancel() {
                s.analysisDone = total
            }
            s.analysisCurrent = ""
        }
        if AnalysisEngine.shared.shouldCancel() {
            logger.info("Analysis stopped: analyzed=\(successCount), errors=\(errorCount), unavailable=\(unavailableCount), total=\(tracks.count)")
        } else {
            logger.info("Analysis complete: analyzed=\(successCount), errors=\(errorCount), unavailable=\(unavailableCount), total=\(tracks.count)")
        }
    }

    private func getAnalysedIDs(_ req: HTTPRequest) -> HTTPResponse {
        let ids = AnalysisEngine.shared.allIDs()
        return .json(["ids": ids, "count": ids.count])
    }

    private func analysisSummary() -> (library: Int, available: Int, unavailable: Int, analyzed: Int, notAnalyzed: Int) {
        let lib = RekordboxParser.shared.parse()
        var seen = [String: Track]()
        lib.tracks.forEach { seen[$0.id] = $0 }

        let tracks = Array(seen.values)
        let availableIDs = Set(
            tracks
                .filter { FileManager.default.fileExists(atPath: $0.location) }
                .map { $0.id }
        )
        let required = Set(["energy", "timbre", "groove", "happiness"])
        let store = AnalysisEngine.shared.storeSnapshot()
        let analyzed = store.filter { id, features in
            availableIDs.contains(id) && required.isSubset(of: Set(features.asDictKeys()))
        }.count
        let available = availableIDs.count
        return (
            library: tracks.count,
            available: available,
            unavailable: tracks.count - available,
            analyzed: analyzed,
            notAnalyzed: max(0, available - analyzed)
        )
    }

    // MARK: - /api/similar

    private func getSimilar(_ req: HTTPRequest) -> HTTPResponse {
        guard let id = req.queryParams["id"] else { return .error("id required", status: 400) }
        let limit  = Int(req.queryParams["limit"] ?? "10") ?? 10
        let useKey = (req.queryParams["use_key"] ?? "1") != "0"

        guard AnalysisEngine.shared.getFeatures(id) != nil else {
            return .error("Track not analysed — run /api/analysis/start first", status: 404)
        }

        let lib       = RekordboxParser.shared.parse()
        let store     = AnalysisEngine.shared.storeSnapshot()
        let results   = SimilarityEngine.shared.findSimilar(
            trackID: id, allTracks: lib.tracks, analysisData: store,
            topN: min(limit, 50), useKey: useKey
        )

        guard let resultsData = try? JSONEncoder().encode(results),
              let resultsJSON = try? JSONSerialization.jsonObject(with: resultsData)
        else { return .error("Encode error", status: 500) }

        let srcFeat = store[id]
        let srcData = srcFeat.flatMap { try? JSONEncoder().encode($0) }
        let srcJSON = srcData.flatMap { try? JSONSerialization.jsonObject(with: $0) }

        return .json([
            "results":         resultsJSON,
            "source_features": srcJSON as Any,
            "analyzed_count":  store.count,
        ])
    }

    // MARK: - /api/status

    private func getStatus(_ req: HTTPRequest) -> HTTPResponse {
        let cfg  = AppConfig.shared
        let data = DataStore.shared.data
        let dbExists = !cfg.dbPath.isEmpty && FileManager.default.fileExists(atPath: cfg.dbPath)
        return .json([
            "agent_id":   cfg.agentID,
            "version":    cfg.displayVersion,
            "xml_path":   cfg.xmlPath,
            "xml_exists": FileManager.default.fileExists(atPath: cfg.xmlPath),
            "db_path":    cfg.dbPath,
            "db_exists":  dbExists,
            "library_source": dbExists ? "db" : "xml",
            "cloud_url":  data.cloud_url,
            "is_linked":  !data.cloud_url.isEmpty,
        ])
    }

    // MARK: - /api/account

    private func getAccount(_ req: HTTPRequest) -> HTTPResponse {
        let cfg  = AppConfig.shared
        let data = DataStore.shared.data
        return .json([
            "cloud_url":     data.cloud_url,
            "cloud_user_id": data.cloud_user_id as Any,
            "is_linked":     !data.cloud_url.isEmpty,
            "agent_id":      cfg.agentID,
            "agent_url":     cfg.localAgentURL(),
        ])
    }

    // MARK: - /api/link_account

    private func linkAccount(_ req: HTTPRequest) -> HTTPResponse {
        guard let body = try? JSONSerialization.jsonObject(with: req.body) as? [String: Any],
              let token = (body["token"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !token.isEmpty else {
            return .error("token required", status: 400)
        }

        // Try to decode compound token {url, t}
        var cloudURL  = (body["cloud_url"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        var rawToken  = token
        if let decoded = decodeCompoundToken(token) {
            cloudURL  = decoded.url.isEmpty ? cloudURL : decoded.url
            rawToken  = decoded.token
        }
        if cloudURL.isEmpty { cloudURL = AppConfig.shared.rimeoAppURL }
        cloudURL = cloudURL.hasSuffix("/") ? String(cloudURL.dropLast()) : cloudURL

        let cfg      = AppConfig.shared
        let localURL = cfg.localAgentURL()
        let d        = DataStore.shared.data
        let tunnel   = TunnelManager.shared.activeURL.isEmpty ? d.tunnel_url : TunnelManager.shared.activeURL

        let payload: [String: Any] = [
            "token":      rawToken,
            "agent_id":   cfg.agentID,
            "agent_url":  localURL,
            "tunnel_url": tunnel,
            "agent_name": cfg.appName,
        ]

        guard let payloadData = try? JSONSerialization.data(withJSONObject: payload),
              let endpoint    = URL(string: "\(cloudURL)/api/agents/link") else {
            return .error("Invalid cloud URL", status: 400)
        }

        var post = URLRequest(url: endpoint)
        post.httpMethod = "POST"; post.httpBody = payloadData
        AppConfig.shared.applyCloudHeaders(to: &post, contentType: "application/json")
        post.timeoutInterval = 15

        let sema = DispatchSemaphore(value: 0)
        var resultData: Data?; var httpCode = 0
        URLSession.shared.dataTask(with: post) { data, resp, _ in
            httpCode = (resp as? HTTPURLResponse)?.statusCode ?? 0
            resultData = data; sema.signal()
        }.resume()
        sema.wait()

        guard httpCode == 200, let rd = resultData,
              let result = try? JSONSerialization.jsonObject(with: rd) as? [String: Any]
        else {
            let msg = resultData.flatMap { String(data: $0, encoding: .utf8) } ?? "Unknown error"
            return .error("Cloud rejected link: \(msg)", status: httpCode > 0 ? httpCode : 502)
        }

        DataStore.shared.update { d in
            d.cloud_url     = cloudURL
            d.cloud_user_id = result["email"] as? String
            if let ct = result["cloud_token"] as? String { d.cloud_token = ct }
        }
        DispatchQueue.main.async { AppState.shared.refreshFromData() }
        CloudRelay.shared.start(cloudURL: cloudURL, token: DataStore.shared.data.cloud_token)

        return .json(["status": "linked", "cloud_url": cloudURL, "result": result])
    }

    // MARK: - /api/unlink_account

    private func unlinkAccount(_ req: HTTPRequest) -> HTTPResponse {
        let d         = DataStore.shared.data
        let cloudURL  = d.cloud_url
        if !cloudURL.isEmpty,
           let endpoint = URL(string: "\(cloudURL)/api/agents/unlink_by_agent") {
            let payload = try? JSONSerialization.data(withJSONObject: ["agent_id": AppConfig.shared.agentID])
            var post = URLRequest(url: endpoint)
            post.httpMethod = "POST"; post.httpBody = payload
            AppConfig.shared.applyCloudHeaders(to: &post, contentType: "application/json")
            post.timeoutInterval = 5
            let sema = DispatchSemaphore(value: 0)
            URLSession.shared.dataTask(with: post) { _, _, _ in sema.signal() }.resume()
            sema.wait()
        }
        CloudRelay.shared.stop()
        DataStore.shared.update { d in d.cloud_url = ""; d.cloud_user_id = nil; d.cloud_token = "" }
        DispatchQueue.main.async { AppState.shared.refreshFromData() }
        return .json(["status": "unlinked"])
    }

    // MARK: - Tunnel

    private func tunnelStatus(_ req: HTTPRequest) -> HTTPResponse {
        let d      = DataStore.shared.data
        let active = TunnelManager.shared.isRunning
        let url    = active ? TunnelManager.shared.activeURL : ""
        return .json([
            "active":            active,
            "url":               url,
            "cloudflared_found": TunnelManager.shared.findCloudflared() != nil,
        ])
    }

    private func tunnelStart(_ req: HTTPRequest) -> HTTPResponse {
        TunnelManager.shared.start()
        // Wait up to 20s for URL
        var waited = 0.0
        while waited < 20 && TunnelManager.shared.activeURL.isEmpty {
            Thread.sleep(forTimeInterval: 0.5)
            waited += 0.5
        }
        let url = TunnelManager.shared.activeURL
        return .json(["status": url.isEmpty ? "starting" : "started", "url": url])
    }

    private func tunnelStop(_ req: HTTPRequest) -> HTTPResponse {
        TunnelManager.shared.stop()
        return .json(["status": "stopped"])
    }

    // MARK: - /api/report_bug

    private func reportBug(_ req: HTTPRequest) -> HTTPResponse {
        guard let body = try? JSONSerialization.jsonObject(with: req.body) as? [String: Any],
              let desc = (body["description"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !desc.isEmpty else {
            return .error("description required", status: 400)
        }
        let logExcerpt = logger.lastLines(80)
        let d         = DataStore.shared.data
        guard !d.cloud_url.isEmpty,
              let endpoint = URL(string: "\(d.cloud_url)/api/report_bug") else {
            return .error("Agent is not linked to a cloud account", status: 503)
        }

        let payload: [String: Any] = [
            "agent_id":    AppConfig.shared.agentID,
            "user_email":  d.cloud_user_id ?? "",
            "description": desc,
            "log_excerpt": logExcerpt,
        ]
        guard let payloadData = try? JSONSerialization.data(withJSONObject: payload) else {
            return .error("Encode error", status: 500)
        }
        var post = URLRequest(url: endpoint)
        post.httpMethod = "POST"; post.httpBody = payloadData
        AppConfig.shared.applyCloudHeaders(to: &post, contentType: "application/json")
        post.timeoutInterval = 15

        let sema = DispatchSemaphore(value: 0)
        var code = 0
        URLSession.shared.dataTask(with: post) { _, resp, _ in
            code = (resp as? HTTPURLResponse)?.statusCode ?? 0; sema.signal()
        }.resume()
        sema.wait()

        guard code == 200 else { return .error("Cloud returned \(code)", status: 502) }
        return .json(["status": "ok"])
    }

    // MARK: - Helpers

    private func encodableTrack(_ t: Track) -> [String: Any] {
        [
            "id": t.id, "artist": t.artist, "title": t.title,
            "genre": t.genre, "label": t.label, "rel_date": t.rel_date,
            "key": t.key, "bpm": t.bpm, "bitrate": t.bitrate,
            "play_count": t.play_count, "location": t.location,
            "timestamp": t.timestamp, "date_str": t.date_str,
            "playlists": t.playlists, "playlist_indices": t.playlist_indices,
        ]
    }

    private func decodeCompoundToken(_ token: String) -> (url: String, token: String)? {
        guard let data = Data(base64Encoded: token + "==") ?? Data(base64Encoded: token),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let t    = json["t"] as? String else { return nil }
        let url = (json["url"] as? String ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (url, t)
    }

    private func mimeType(for path: String) -> String {
        let ext = (path as NSString).pathExtension.lowercased()
        switch ext {
        case "mp3":  return "audio/mpeg"
        case "wav":  return "audio/wav"
        case "m4a":  return "audio/mp4"
        case "aac":  return "audio/aac"
        case "ogg":  return "audio/ogg"
        case "flac": return "audio/flac"
        default:     return "audio/mpeg"
        }
    }
}

// Helper so TrackFeatures can expose its keys
extension TrackFeatures {
    func asDictKeys() -> [String] {
        var keys = ["energy", "timbre", "groove", "happiness"]
        return keys
    }
}
