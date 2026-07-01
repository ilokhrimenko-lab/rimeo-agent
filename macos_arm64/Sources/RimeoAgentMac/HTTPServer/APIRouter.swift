import Foundation
import Darwin

// Routes all HTTP requests to the appropriate handler
// Mirrors api_server.py endpoint-for-endpoint

enum StreamDiag {
    struct Entry: Codable {
        let ts: String
        let track_id: String
        let path: String
        let resolved_path: String
        let status: Int
        let range: String
        let preload: Bool
        let bytes: Int
        let note: String
    }
    private static let lock = NSLock()
    private static var buffer: [Entry] = []
    private static let capacity = 20

    static func record(trackID: String, path: String, resolvedPath: String, status: Int,
                       range: String, preload: Bool, bytes: Int = 0, note: String = "") {
        let entry = Entry(
            ts: ISO8601DateFormatter().string(from: Date()),
            track_id: trackID, path: path, resolved_path: resolvedPath,
            status: status, range: range, preload: preload, bytes: bytes, note: note
        )
        lock.lock()
        buffer.append(entry)
        if buffer.count > capacity { buffer.removeFirst(buffer.count - capacity) }
        lock.unlock()
    }

    static func snapshot() -> [Entry] {
        lock.lock(); defer { lock.unlock() }
        return buffer
    }
}

final class APIRouter {
    static let shared = APIRouter()
    private init() {}

    // Endpoints reachable through the public named tunnel that expose user data
    // (audio bytes, waveform pre-computes, cover art, the full library JSON).
    // All other routes are either local-network only or are authenticated by
    // their own pairing/account flow.
    private static let jwtProtectedPaths: Set<String> = [
        "/stream", "/waveform", "/artwork", "/api/data", "/api/logs"
    ]

    // Tracks with a Rekordbox bitrate above this (kbps) are "hi-res" (≈24-bit PCM):
    // their sustained bitrate overruns the Cloudflare-tunnel bandwidth and stalls the
    // player, so /stream serves a 16-bit/44.1/stereo WAV down-convert instead. A
    // bitrate of 0/unknown is treated as NOT hi-res (served unchanged).
    private static let hiResBitrateThreshold = 2000

    func route(_ req: HTTPRequest) -> HTTPResponse {
        let path = req.path

        if APIRouter.jwtProtectedPaths.contains(path) {
            if let failure = authGate(req) { return failure }
        }

        switch (req.method, path) {
        // Audio
        case ("GET", "/stream"):         return streamAudio(req)
        case ("GET", "/waveform"):       return getWaveform(req)
        case ("GET", "/artwork"):        return getArtwork(req)
        case ("GET", "/reveal"):         return revealInFinder(req)

        // Library
        case ("GET", "/api/data"):       return getLibraryData(req)

        // Diagnostic logs (pulled by iOS/web "Report a problem" via the cloud relay)
        case ("GET", "/api/logs"):       return getLogs(req)

        // Pairing
        case ("GET", "/api/pairing_info"):   return getPairingInfo(req)
        case ("GET", "/api/check_pairing"):  return checkPairing(req)

        // Notes / exclusions
        case ("POST", "/api/save_note"):       return saveNote(req)
        case ("POST", "/api/save_exclusions"): return saveExclusions(req)

        // Play-history rename
        case ("POST", "/api/rename_history"):  return renameHistory(req)

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
        case ("POST", "/api/agent_login"):     return agentSignIn(req)
        case ("POST", "/api/agent_signup"):    return agentSignUp(req)
        case ("POST", "/api/unlink_account"):  return unlinkAccount(req)

        // Tunnel
        case ("GET", "/api/tunnel/status"):  return tunnelStatus(req)
        case ("POST", "/api/tunnel/start"):  return tunnelStart(req)
        case ("POST", "/api/tunnel/stop"):   return tunnelStop(req)

        // Bug report
        case ("POST", "/api/report_bug"):    return reportBug(req)

        // Diagnostics
        case ("GET", "/api/admin/diag"):     return adminDiag(req)

        default:
            return HTTPResponse.error("Not found", status: 404)
        }
    }

    // MARK: - /stream

    /// Returns the `/Volumes/<name>` mount point for an external-volume path, or nil for
    /// internal-disk paths (where a missing file is a genuine 404, not an unmounted drive).
    private func removableVolumeRoot(for path: String) -> String? {
        let prefix = "/Volumes/"
        guard path.hasPrefix(prefix) else { return nil }
        let rest = path.dropFirst(prefix.count)
        if let slash = rest.firstIndex(of: "/") {
            return prefix + rest[..<slash]
        }
        return prefix + rest
    }

    private func streamAudio(_ req: HTTPRequest) -> HTTPResponse {
        guard let filePath = req.queryParams["path"], !filePath.isEmpty else {
            return .error("path required", status: 400)
        }
        let resolvedPath = resolveTrackPath(filePath)
        let trackID = req.queryParams["id"] ?? ""
        let preload = req.queryParams["preload"] == "1" || req.queryParams["preload"] == "true"
        // raw=1 → byte-for-byte ORIGINAL (download / offline must stay lossless):
        // no 16-bit down-convert and no AIFF→WAV.
        let raw     = req.queryParams["raw"] == "1" || req.queryParams["raw"] == "true"
        let ext     = (resolvedPath as NSString).pathExtension.lowercased()
        let rangeHeader = req.headers["range"] ?? "(none)"
        let src = req.queryParams["src"] ?? "unknown"

        logger.info("Stream request: src=\(src), track=\(trackID), preload=\(preload), range=\(rangeHeader), raw_path=\(filePath), resolved_path=\(resolvedPath)")
        if filePath != resolvedPath {
            logger.info("Stream path resolved: raw=\(filePath), resolved=\(resolvedPath)")
        }

        TCCDiagnostics.logPathAccess("stream", path: resolvedPath)
        let exists = FileManager.default.fileExists(atPath: resolvedPath)
        let readable = FileManager.default.isReadableFile(atPath: resolvedPath)
        TCCDiagnostics.logPathResult("stream", path: resolvedPath, exists: exists, readable: readable)

        guard exists else {
            // Drive unmounted vs file genuinely missing — distinct causes, distinct codes,
            // so the web client can show a specific message instead of blaming the tunnel.
            if let volRoot = removableVolumeRoot(for: resolvedPath),
               !FileManager.default.fileExists(atPath: volRoot) {
                logger.warning("Stream request failed: volume not mounted, track=\(trackID), volume=\(volRoot), path=\(resolvedPath)")
                StreamDiag.record(trackID: trackID, path: filePath, resolvedPath: resolvedPath,
                                  status: 410, range: rangeHeader, preload: preload, note: "volume_not_mounted")
                return .error("Music drive is not connected", status: 410)
            }
            logger.warning("Stream request failed: file not found, track=\(trackID), path=\(resolvedPath)")
            StreamDiag.record(trackID: trackID, path: filePath, resolvedPath: resolvedPath,
                              status: 404, range: rangeHeader, preload: preload, note: "file_not_found")
            return .error("File not found", status: 404)
        }

        guard readable else {
            // File is present but the OS denies reads (TCC / permissions) — 403, not 404.
            logger.warning("Stream request failed: permission denied, track=\(trackID), path=\(resolvedPath)")
            StreamDiag.record(trackID: trackID, path: filePath, resolvedPath: resolvedPath,
                              status: 403, range: rangeHeader, preload: preload, note: "permission_denied")
            return .error("File access denied", status: 403)
        }

        var finalPath = resolvedPath

        // Hi-res down-convert (applies to ALL clients): a Rekordbox bitrate above the
        // threshold (≈24-bit PCM) overruns the sustained Cloudflare-tunnel bandwidth and
        // stalls the player, so serve a 16-bit/44.1/stereo WAV instead. Bypassed by raw=1
        // (download/offline must stay byte-for-byte lossless) and when bitrate is unknown.
        let bitrate = RekordboxParser.shared.track(byID: trackID)?.bitrate ?? 0
        let isHiRes = !raw && bitrate > APIRouter.hiResBitrateThreshold

        if isHiRes {
            if preload {
                DispatchQueue.global(qos: .utility).async {
                    _ = try? AudioService.shared.ensure16BitWAV(path: resolvedPath, trackID: trackID)
                }
                StreamDiag.record(trackID: trackID, path: filePath, resolvedPath: resolvedPath,
                                  status: 200, range: rangeHeader, preload: true, note: "preloading_16bit")
                return .json(["status": "preloading"])
            }
            logger.info("Stream request: down-converting hi-res to 16-bit, track=\(trackID), bitrate=\(bitrate), path=\(resolvedPath)")
            do {
                finalPath = try AudioService.shared.ensure16BitWAV(path: resolvedPath, trackID: trackID)
                logger.info("Stream request: 16-bit ready, track=\(trackID), wav=\(finalPath)")
            } catch {
                logger.warning("Stream request failed during 16-bit conversion: track=\(trackID), error=\(error)")
                StreamDiag.record(trackID: trackID, path: filePath, resolvedPath: resolvedPath,
                                  status: 503, range: rangeHeader, preload: preload, note: "conv16_failed")
                return .error("Audio conversion failed — retry in a moment", status: 503)
            }
        } else {
            // AIFF needs WAV conversion only for the web player (wavesurfer.js can't decode AIFF).
            // iOS AVPlayer plays AIFF natively, so skip the ffmpeg step entirely for src=ios —
            // saves ~1-3s per track and removes ffmpeg/Pipe pressure on the agent.
            // raw=1 also skips this — the download must be the byte-for-byte original.
            let needsAIFFConversion = !raw && (ext == "aif" || ext == "aiff") && src != "ios"
            if needsAIFFConversion {
                if preload {
                    DispatchQueue.global(qos: .utility).async {
                        _ = try? AudioService.shared.ensureWAV(path: resolvedPath, trackID: trackID)
                    }
                    StreamDiag.record(trackID: trackID, path: filePath, resolvedPath: resolvedPath,
                                      status: 200, range: rangeHeader, preload: true, note: "preloading_aiff")
                    return .json(["status": "preloading"])
                }
                logger.info("Stream request: converting AIFF for web, track=\(trackID), path=\(resolvedPath)")
                do {
                    finalPath = try AudioService.shared.ensureWAV(path: resolvedPath, trackID: trackID)
                    logger.info("Stream request: AIFF ready, track=\(trackID), wav=\(finalPath)")
                } catch {
                    logger.warning("Stream request failed during AIFF conversion: track=\(trackID), error=\(error)")
                    StreamDiag.record(trackID: trackID, path: filePath, resolvedPath: resolvedPath,
                                      status: 503, range: rangeHeader, preload: preload, note: "aiff_conversion_failed")
                    return .error("Audio conversion failed — retry in a moment", status: 503)
                }
            } else if preload {
                StreamDiag.record(trackID: trackID, path: filePath, resolvedPath: resolvedPath,
                                  status: 200, range: rangeHeader, preload: true, note: "preloading")
                return .json(["status": "preloading"])
            }
        }

        let mime    = mimeType(for: finalPath)
        let size    = (try? FileManager.default.attributesOfItem(atPath: finalPath))?[.size] as? Int ?? 0
        guard size > 0 else {
            logger.warning("Stream request failed: file empty, track=\(trackID), final_path=\(finalPath)")
            StreamDiag.record(trackID: trackID, path: filePath, resolvedPath: resolvedPath,
                              status: 404, range: rangeHeader, preload: preload, note: "file_empty")
            return .error("File empty", status: 404)
        }

        // A request WITHOUT a Range header must get 200 (full body), NOT 206. Chrome's
        // <audio>/MediaElement treats "a 206 that spans the whole file" as a single
        // non-seekable blob and drains it all before it plays; a 200 + Accept-Ranges lets
        // it buffer progressively and range-fetch as needed. Real Range requests still get
        // a proper 206 below. (iOS AVPlayer / Cast / downloads always send Range → 206.)
        let hasRange = req.headers["range"] != nil

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
            logger.warning("Stream request failed: invalid range=\(rangeHeader), track=\(trackID), size=\(size)")
            StreamDiag.record(trackID: trackID, path: filePath, resolvedPath: resolvedPath,
                              status: 416, range: rangeHeader, preload: preload, note: "invalid_range")
            return HTTPResponse(
                status:  416,
                headers: ["Content-Range": "bytes */\(size)"],
                body:    .empty
            )
        }
        end = min(end, size - 1)

        let length    = end - start + 1
        let server    = HTTPServer(port: 0)   // reuse writeAll helper
        let respStatus = hasRange ? 206 : 200
        logger.info("Stream response: track=\(trackID), status=\(respStatus), mime=\(mime), bytes=\(start)-\(end)/\(size), length=\(length), final_path=\(finalPath)")
        StreamDiag.record(trackID: trackID, path: filePath, resolvedPath: resolvedPath,
                          status: respStatus, range: rangeHeader, preload: preload, bytes: length, note: "ok")

        var headers = [
            "Content-Type":   mime,
            "Content-Length": "\(length)",
            "Accept-Ranges":  "bytes",
        ]
        if hasRange {
            headers["Content-Range"] = "bytes \(start)-\(end)/\(size)"
        }
        return HTTPResponse(
            status: respStatus,
            headers: headers,
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
        let resolvedPath = resolveTrackPath(path)
        TCCDiagnostics.logPathAccess("waveform", path: resolvedPath)
        let preload = req.queryParams["preload"] == "1" || req.queryParams["preload"] == "true"
        if preload {
            DispatchQueue.global(qos: .utility).async {
                _ = AudioService.shared.waveform(path: resolvedPath, trackID: id)
            }
            return .json(["status": "preloading"])
        }
        let result = AudioService.shared.waveform(path: resolvedPath, trackID: id)
        return .json(result)
    }

    // MARK: - /artwork

    private func getArtwork(_ req: HTTPRequest) -> HTTPResponse {
        guard let path = req.queryParams["path"], !path.isEmpty,
              let id   = req.queryParams["id"],   !id.isEmpty else {
            return .error("path and id required", status: 400)
        }
        let resolvedPath = resolveTrackPath(path)
        TCCDiagnostics.logPathAccess("artwork", path: resolvedPath)
        let preload = req.queryParams["preload"] == "1" || req.queryParams["preload"] == "true"
        if preload {
            DispatchQueue.global(qos: .utility).async {
                _ = AudioService.shared.artwork(path: resolvedPath, trackID: id)
            }
            return .json(["status": "preloading"])
        }
        if let artPath = AudioService.shared.artwork(path: resolvedPath, trackID: id),
           let data = try? Data(contentsOf: URL(fileURLWithPath: artPath)) {
            return HTTPResponse(status: 200,
                                headers: ["Content-Type": "image/jpeg",
                                          "Content-Length": "\(data.count)"],
                                body: .data(data))
        }

        // No embedded artwork stream in the audio file. Rekordbox keeps cover art
        // separately (djmdContent.ImagePath under the rekordbox share folder), so
        // fall back to that before giving up.
        if let rbArt = rekordboxArtworkFile(forTrackID: id),
           let data = try? Data(contentsOf: URL(fileURLWithPath: rbArt)) {
            let ext = (rbArt as NSString).pathExtension.lowercased()
            let mime = (ext == "png") ? "image/png" : "image/jpeg"
            return HTTPResponse(status: 200,
                                headers: ["Content-Type": mime,
                                          "Content-Length": "\(data.count)"],
                                body: .data(data))
        }

        // Missing artwork is a valid state for many audio files.
        // Return 204 instead of 404 to avoid "track not found" handling on clients.
        return HTTPResponse(status: 204, headers: [:], body: .empty)
    }

    // Resolves the Rekordbox-managed cover file for a track id, or nil if the
    // track has no ImagePath or the file is absent. Rekordbox stores ImagePath
    // relative to "<rekordbox dir>/share" (dbPath lives at "<rekordbox dir>/master.db").
    private func rekordboxArtworkFile(forTrackID id: String) -> String? {
        guard let track = RekordboxParser.shared.track(byID: id),
              let imagePath = track.image_path,
              !imagePath.isEmpty else { return nil }

        let fm = FileManager.default
        if imagePath.hasPrefix("/"), fm.fileExists(atPath: imagePath) {
            return imagePath
        }

        let rbDir = (AppConfig.shared.dbPath as NSString).deletingLastPathComponent
        let shareDir = (rbDir as NSString).appendingPathComponent("share")
        let rel = imagePath.hasPrefix("/") ? String(imagePath.dropFirst()) : imagePath
        let candidate = (shareDir as NSString).appendingPathComponent(rel)
        return fm.fileExists(atPath: candidate) ? candidate : nil
    }

    // MARK: - /reveal

    private func revealInFinder(_ req: HTTPRequest) -> HTTPResponse {
        guard let path = req.queryParams["path"] else {
            return .error("File not found", status: 404)
        }
        let resolvedPath = resolveTrackPath(path)
        TCCDiagnostics.logPathAccess("reveal", path: resolvedPath)
        let exists = FileManager.default.fileExists(atPath: resolvedPath)
        let readable = FileManager.default.isReadableFile(atPath: resolvedPath)
        TCCDiagnostics.logPathResult("reveal", path: resolvedPath, exists: exists, readable: readable)
        guard exists else {
            return .error("File not found", status: 404)
        }
        Process.launchedProcess(launchPath: "/usr/bin/open",
                                arguments: ["-R", resolvedPath])
        return .json(["status": "ok"])
    }

    private func resolveTrackPath(_ rawPath: String) -> String {
        if FileManager.default.fileExists(atPath: rawPath) {
            return rawPath
        }

        let standardized = URL(fileURLWithPath: rawPath).standardizedFileURL.path
        if FileManager.default.fileExists(atPath: standardized) {
            logger.info("Path normalized via standardized URL: \(rawPath) -> \(standardized)")
            return standardized
        }

        // Fallback for username drift between exported library paths and current macOS account.
        let home = NSHomeDirectory()
        let marker = "/Users/"
        if rawPath.hasPrefix(marker) {
            let parts = rawPath.split(separator: "/", omittingEmptySubsequences: false)
            // "", "Users", "<username>", ...
            if parts.count >= 4 {
                let suffix = parts.dropFirst(3).joined(separator: "/")
                let candidate = "\(home)/\(suffix)"
                if FileManager.default.fileExists(atPath: candidate) {
                    logger.warning("Path remapped to current home: \(rawPath) -> \(candidate)")
                    return candidate
                }
            }
        }

        return rawPath
    }

    // MARK: - /api/data

    private func getLibraryData(_ req: HTTPRequest) -> HTTPResponse {
        let lib  = RekordboxParser.shared.parse()
        let data = DataStore.shared.data
        logger.info("GET /api/data -> \(lib.tracks.count) tracks, \(lib.playlists.count) playlists, source=\(lib.source ?? "unknown")")
        let obj: [String: Any] = [
            "tracks":            lib.tracks.map { encodableTrack($0) },
            "playlists":         lib.playlists.map { encodablePlaylist($0) },
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

        // Persistent per-device PSK (generate once, reuse across QR refreshes).
        var psk = DataStore.shared.data.lan_secret
        if psk.isEmpty {
            let bytes = (0..<32).map { _ in UInt8.random(in: 0...255) }
            psk = Data(bytes).base64EncodedString()
                .replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")
        }
        DataStore.shared.update { d in d.pairing_code = code; d.lan_secret = psk }

        let localIP  = AppConfig.shared.getLocalIP()
        let port     = Int(AppConfig.shared.port)
        let localURL = "http://\(localIP):\(port)"
        let hostname = ProcessInfo.processInfo.hostName
        let d        = DataStore.shared.data
        let url      = TunnelManager.shared.activeURL.isEmpty
                        ? (d.tunnel_url.isEmpty ? localURL : d.tunnel_url)
                        : TunnelManager.shared.activeURL

        // v2 payload: keeps url/code for back-compat, adds the LAN fields iOS
        // (PairingInfo v2) needs — secret(PSK), mDNS hostname, LAN ip:port.
        var qrDict: [String: Any] = [
            "v": 2,
            "url": url,
            "code": code,
            "agent_id": AppConfig.shared.agentID,
            "secret": psk,
            "hostname": hostname,
            "lan_ip": localIP,
            "lan_port": port,
        ]
        // Dual-mode: also embed a cloud session (type/cloud_url/mobile_token) so one
        // scan gives BOTH LAN (PSK) and remote (cloud). Best-effort — LAN-only if
        // not cloud-linked or rimeo.app is unreachable.
        if let cloud = _fetchCloudPairing() {
            qrDict["type"]         = "rimeo_cloud"
            qrDict["cloud_url"]    = cloud.cloudURL
            qrDict["mobile_token"] = cloud.mobileToken
        }

        let qrData  = (try? JSONSerialization.data(withJSONObject: qrDict))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        let encoded = qrData.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? qrData
        let qrURL   = "https://api.qrserver.com/v1/create-qr-code/?size=300x300&data=\(encoded)"

        // The Pairing view embeds these response fields into the displayed QR.
        var resp = qrDict
        resp["qr_url"]    = qrURL
        resp["local_url"] = url
        return .json(resp)
    }

    /// Best-effort: ask rimeo.app for a one-time mobile pairing token so the QR can
    /// also establish a cloud session (remote access). nil if not cloud-linked or
    /// the call fails — the QR then stays LAN-only. Synchronous (getPairingInfo
    /// runs off the main thread when the Pairing view refreshes).
    private func _fetchCloudPairing() -> (cloudURL: String, mobileToken: String)? {
        let d = DataStore.shared.data
        guard !d.cloud_url.isEmpty, !d.cloud_token.isEmpty,
              var comps = URLComponents(string: "\(d.cloud_url)/api/agents/mobile_token") else { return nil }
        comps.queryItems = [
            URLQueryItem(name: "agent_id", value: AppConfig.shared.agentID),
            URLQueryItem(name: "token", value: d.cloud_token),
        ]
        guard let url = comps.url else { return nil }
        var req = URLRequest(url: url)
        req.timeoutInterval = 6
        var result: (String, String)?
        let sem = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: req) { data, _, _ in
            defer { sem.signal() }
            guard let data,
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let mt  = obj["mobile_token"] as? String, !mt.isEmpty,
                  let cu  = obj["cloud_url"] as? String, !cu.isEmpty else { return }
            result = (cu, mt)
        }.resume()
        _ = sem.wait(timeout: .now() + 7)
        return result
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

    // MARK: - /api/rename_history

    /// Sets (or clears, when `name` is empty) the custom display name for a
    /// Rekordbox play-history session. Stored in DataStore.history_names and
    /// applied to every subsequent /api/data — Rekordbox's own DB is never written.
    private func renameHistory(_ req: HTTPRequest) -> HTTPResponse {
        guard let body = try? JSONSerialization.jsonObject(with: req.body) as? [String: String],
              let hid  = body["history_id"], !hid.isEmpty else {
            return .error("history_id required", status: 400)
        }
        let name = (body["name"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        DataStore.shared.update { d in
            if name.isEmpty { d.history_names.removeValue(forKey: hid) }
            else            { d.history_names[hid] = name }
        }
        return .json(["status": "ok"])
    }

    // MARK: - /api/save_exclusions

    private func saveExclusions(_ req: HTTPRequest) -> HTTPResponse {
        guard let list = try? JSONSerialization.jsonObject(with: req.body) as? [String] else {
            return .error("Expected array of strings", status: 400)
        }
        // The "All collection" playlist holds the entire library; excluding it
        // orphans freshly-added tracks (they only live in auto playlists) and
        // hides them from All Collection. Never allow it into the exclusion set.
        let cleaned = list.filter { $0.trimmingCharacters(in: .whitespaces).lowercased() != "all collection" }
        DataStore.shared.update { $0.global_exclusions = cleaned }
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
        let limit  = Int(req.queryParams["limit"] ?? "20") ?? 20
        let useKey = (req.queryParams["use_key"] ?? "1") != "0"

        let lib     = RekordboxParser.shared.parse()
        let results = SimilarityEngine.shared.findSimilar(
            trackID: id, allTracks: lib.tracks,
            topN: min(limit, 50), useKey: useKey
        )

        guard let resultsData = try? JSONEncoder().encode(results),
              let resultsJSON = try? JSONSerialization.jsonObject(with: resultsData)
        else { return .error("Encode error", status: 500) }

        return .json(["results": resultsJSON])
    }

    // MARK: - /api/logs

    /// Tail of the agent log + host/OS/version, pulled by the cloud relay when a
    /// user submits "Report a problem" from iOS/web. JWT-protected like /api/data.
    private func getLogs(_ req: HTTPRequest) -> HTTPResponse {
        let cfg = AppConfig.shared
        return .json([
            "platform":      "macos",
            "os":            ProcessInfo.processInfo.operatingSystemVersionString,
            "agent_version": cfg.displayVersion,
            "agent_id":      cfg.agentID,
            "log":           logger.lastLines(800),
        ])
    }

    // MARK: - /api/status

    private func getStatus(_ req: HTTPRequest) -> HTTPResponse {
        let cfg  = AppConfig.shared
        let data = DataStore.shared.data
        let dbExists = !cfg.dbPath.isEmpty && FileManager.default.fileExists(atPath: cfg.dbPath)
        let tunnel = currentTunnelInfo()
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
            "agent_url":  cfg.localAgentURL(),
            "tunnel_url": tunnel.url,
            "tunnel_active": tunnel.active,
            "cloudflared_found": tunnel.cloudflaredFound,
            "stream_transport": tunnel.url.isEmpty ? "relay_only" : "tunnel",
        ])
    }

    // MARK: - /api/account

    private func getAccount(_ req: HTTPRequest) -> HTTPResponse {
        let cfg  = AppConfig.shared
        let data = DataStore.shared.data
        let tunnel = currentTunnelInfo()
        return .json([
            "cloud_url":     data.cloud_url,
            "cloud_user_id": data.cloud_user_id as Any,
            "is_linked":     !data.cloud_url.isEmpty,
            "agent_id":      cfg.agentID,
            "agent_url":     cfg.localAgentURL(),
            "tunnel_url":    tunnel.url,
            "tunnel_active": tunnel.active,
            "cloudflared_found": tunnel.cloudflaredFound,
            "stream_transport": tunnel.url.isEmpty ? "relay_only" : "tunnel",
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

        // П8: a freshly linked agent should migrate to its named tunnel right
        // away rather than waiting for the next launch. No-op when the rollout
        // gate declines.
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2) {
            TunnelProvisioner.shared.provisionIfNeeded()
        }

        return .json(["status": "linked", "cloud_url": cloudURL, "result": result])
    }

    // MARK: - /api/agent_login & /api/agent_signup (login-model)

    private func agentSignIn(_ req: HTTPRequest) -> HTTPResponse {
        agentAuth(req, cloudPath: "/api/agent/login")
    }

    private func agentSignUp(_ req: HTTPRequest) -> HTTPResponse {
        agentAuth(req, cloudPath: "/api/agent/signup")
    }

    /// Shared email+password flow for sign-in and sign-up. Posts the credentials
    /// to the cloud, stores the returned cloud_token, and starts the relay. The
    /// cloud enforces a single active agent per account (others are evicted).
    private func agentAuth(_ req: HTTPRequest, cloudPath: String) -> HTTPResponse {
        guard let body = try? JSONSerialization.jsonObject(with: req.body) as? [String: Any],
              let email = (body["email"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              let password = body["password"] as? String,
              !email.isEmpty, !password.isEmpty else {
            return .error("email and password required", status: 400)
        }

        let cfg      = AppConfig.shared
        var cloudURL = cfg.rimeoAppURL
        cloudURL = cloudURL.hasSuffix("/") ? String(cloudURL.dropLast()) : cloudURL
        let localURL = cfg.localAgentURL()
        let d        = DataStore.shared.data
        let tunnel   = TunnelManager.shared.activeURL.isEmpty ? d.tunnel_url : TunnelManager.shared.activeURL

        let payload: [String: Any] = [
            "email":      email,
            "password":   password,
            "agent_id":   cfg.agentID,
            "agent_url":  localURL,
            "tunnel_url": tunnel,
            "agent_name": cfg.appName,
        ]

        guard let payloadData = try? JSONSerialization.data(withJSONObject: payload),
              let endpoint    = URL(string: "\(cloudURL)\(cloudPath)") else {
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
              let result = try? JSONSerialization.jsonObject(with: rd) as? [String: Any],
              let ct = result["cloud_token"] as? String, !ct.isEmpty else {
            // Surface the cloud's own message (e.g. invalid credentials / email taken).
            let cloudMsg = (resultData.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] })?["error"] as? String
            let raw = resultData.flatMap { String(data: $0, encoding: .utf8) }
            return .error(cloudMsg ?? raw ?? "Sign-in failed", status: httpCode > 0 ? httpCode : 502)
        }

        DataStore.shared.update { d in
            d.cloud_url     = cloudURL
            d.cloud_user_id = result["email"] as? String
            d.cloud_token   = ct
        }

        // Demo/review account → serve the bundled 15-track royalty-free library
        // from this agent (the real Rekordbox DB is never read). Lets App Review
        // see a working library straight from the agent downloaded off rimeo.app.
        let signedInEmail = (result["email"] as? String ?? email).lowercased()
        if signedInEmail == "demo@rimeo.app" {
            AppConfig.shared.activateReviewMode()
            RekordboxParser.shared.invalidateCache()
            DispatchQueue.main.async { AppState.shared.refreshLibrarySource() }
        }

        DispatchQueue.main.async { AppState.shared.refreshFromData() }
        CloudRelay.shared.start(cloudURL: cloudURL, token: ct)

        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2) {
            TunnelProvisioner.shared.provisionIfNeeded()
        }

        return .json(["status": "ok", "cloud_url": cloudURL, "email": result["email"] as? String ?? email])
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
        let tunnel = currentTunnelInfo()
        return .json([
            "active":            tunnel.active,
            "url":               tunnel.url,
            "stored_url":        tunnel.storedURL,
            "cloudflared_found": tunnel.cloudflaredFound,
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

    // MARK: - JWT middleware

    /// Auth for protected paths (M4). LAN vs remote split:
    ///  • Remote (via Cloudflare named tunnel) → server JWT, exactly as before.
    ///  • Local network → per-device PSK (`?lan_token=` or Bearer). No JWT needed,
    ///    so a directly-paired iOS device can load the library / stream on the LAN.
    ///    This is what fixes "scanning the QR didn't open the library".
    /// If no PSK has been provisioned yet, falls back to the legacy JWT gate.
    private func authGate(_ req: HTTPRequest) -> HTTPResponse? {
        // A valid per-device PSK authorises a LOCAL client without the server JWT
        // (the LAN path). Otherwise fall back to the JWT gate (remote / relay /
        // tunnel path), exactly as before. PSK-or-JWT avoids fragile "is this via
        // the tunnel?" detection — the relay presents requests without consistent
        // cf-* headers/Host, so detection mis-fired and broke remote access. The
        // premium gate is enforced server-side anyway: a free user gets neither a
        // tunnel nor a JWT, so they can only ever reach us directly on the LAN.
        let secret = DataStore.shared.data.lan_secret
        if !secret.isEmpty {
            let provided = req.queryParams["lan_token"] ?? bearerToken(req)
            if let provided = provided, provided == secret {
                logger.info("authGate: LAN/psk path=\(req.path)")
                return nil
            }
        }
        logger.info("authGate: remote/jwt path=\(req.path)")
        return jwtGate(req)
    }

    private func bearerToken(_ req: HTTPRequest) -> String? {
        guard let auth = req.headers["authorization"],
              auth.lowercased().hasPrefix("bearer ") else { return nil }
        return String(auth.dropFirst("bearer ".count))
    }

    private func jwtGate(_ req: HTTPRequest) -> HTTPResponse? {
        let aud = TunnelManager.shared.namedHostname
        // П8 safety: enforce JWT only once migrated onto the named tunnel.
        // While still on a quick tunnel (namedHostname empty) the server does
        // not sign tokens for this binding, so enforcing here would lock the
        // agent out of its own /stream before provisioning completes.
        guard !aud.isEmpty else { return nil }
        let token = JWTValidator.extractToken(from: req)
        guard let failure = JWTValidator.validate(token: token, expectedAudience: aud) else {
            return nil
        }
        let reason = failure.rawValue
        logger.warning("JWT rejected: path=\(req.path), reason=\(reason), aud=\(aud), token_present=\(token != nil)")
        return HTTPResponse(
            status: failure.status,
            headers: [
                "Content-Type": "application/json",
                "WWW-Authenticate": "Bearer realm=\"rimeo-agent\", error=\"\(reason)\"",
            ],
            body: .data((try? JSONSerialization.data(withJSONObject: [
                "error": "unauthorized",
                "reason": reason,
            ])) ?? Data())
        )
    }

    // MARK: - Helpers

    private func encodableTrack(_ t: Track) -> [String: Any] {
        var dict: [String: Any] = [
            "id": t.id, "artist": t.artist, "title": t.title,
            "genre": t.genre, "label": t.label, "rel_date": t.rel_date,
            "key": t.key, "bpm": t.bpm, "bitrate": t.bitrate,
            "play_count": t.play_count, "location": t.location,
            "timestamp": t.timestamp, "date_str": t.date_str,
            "playlists": t.playlists, "playlist_indices": t.playlist_indices,
            "histories": t.histories, "history_indices": t.history_indices,
        ]
        if let d = t.duration { dict["duration"] = d }
        return dict
    }

    private func encodablePlaylist(_ p: Playlist) -> [String: Any] {
        var dict: [String: Any] = [
            "path": p.path, "date": p.date, "smart": p.smart ?? false,
        ]
        if p.history == true {
            dict["history"]    = true
            dict["history_id"] = p.history_id ?? ""
            dict["name"]       = p.name ?? ""
        }
        return dict
    }

    private func decodeCompoundToken(_ token: String) -> (url: String, token: String)? {
        guard let data = Data(base64Encoded: token + "==") ?? Data(base64Encoded: token),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let t    = json["t"] as? String else { return nil }
        let url = (json["url"] as? String ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (url, t)
    }

    // MARK: - /api/admin/diag

    private func adminDiag(_ req: HTTPRequest) -> HTTPResponse {
        let snap = TunnelManager.shared.diagSnapshot()
        let cfg  = AppConfig.shared
        let data = DataStore.shared.data
        let iso  = ISO8601DateFormatter()

        var streamEntries: [[String: Any]] = []
        for e in StreamDiag.snapshot() {
            streamEntries.append([
                "ts": e.ts,
                "track_id": e.track_id,
                "path": e.path,
                "resolved_path": e.resolved_path,
                "status": e.status,
                "range": e.range,
                "preload": e.preload,
                "bytes": e.bytes,
                "note": e.note,
            ])
        }

        return .json([
            "agent_id":   cfg.agentID,
            "version":    cfg.displayVersion,
            "port":       Int(cfg.port),
            "stored_tunnel_url": data.tunnel_url,
            "tunnel": [
                "mode":             snap.mode,
                "named_uuid":       snap.namedUUID,
                "named_hostname":   snap.namedHostname,
                "active_url":       snap.activeURL,
                "pending_url":      snap.pendingURL,
                "last_established": snap.lastEstablished.map { iso.string(from: $0) } as Any,
                "last_keepalive":   snap.lastKeepalive.map { iso.string(from: $0) } as Any,
                "cloudflared_found": snap.cloudflaredFound,
                "process_running":   snap.processRunning,
                "should_run":        snap.shouldRun,
            ],
            "stream_recent": streamEntries,
            "now": iso.string(from: Date()),
        ])
    }

    private func currentTunnelInfo() -> (active: Bool, url: String, storedURL: String, cloudflaredFound: Bool) {
        let active = TunnelManager.shared.isRunning
        let activeURL = TunnelManager.shared.activeURL
        let storedURL = DataStore.shared.data.tunnel_url
        return (
            active: active && !activeURL.isEmpty,
            url: !activeURL.isEmpty ? activeURL : storedURL,
            storedURL: storedURL,
            cloudflaredFound: TunnelManager.shared.findCloudflared() != nil
        )
    }

    private func mimeType(for path: String) -> String {
        let ext = (path as NSString).pathExtension.lowercased()
        switch ext {
        case "mp3":         return "audio/mpeg"
        case "wav":         return "audio/wav"
        case "m4a":         return "audio/mp4"
        case "aac":         return "audio/aac"
        case "ogg":         return "audio/ogg"
        case "flac":        return "audio/flac"
        case "aif", "aiff": return "audio/x-aiff"
        default:            return "audio/mpeg"
        }
    }
}

// Helper so TrackFeatures can expose its keys
extension TrackFeatures {
    func asDictKeys() -> [String] {
        let keys = ["energy", "timbre", "groove", "happiness"]
        return keys
    }
}
