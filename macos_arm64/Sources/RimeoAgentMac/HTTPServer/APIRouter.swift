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

    // Protected endpoints (data + mutating/control) live in AccessControl
    // (SecurityGates.swift): AccessControl.dataProtectedPaths + controlProtectedPaths.

    // Tracks with a Rekordbox bitrate above this (kbps) are "hi-res" (≈24-bit PCM):
    // their sustained bitrate overruns the Cloudflare-tunnel bandwidth and stalls the
    // player, so /stream serves a 16-bit/44.1/stereo WAV down-convert instead. A
    // bitrate of 0/unknown is treated as NOT hi-res (served unchanged).
    private static let hiResBitrateThreshold = 2000

    func route(_ req: HTTPRequest) -> HTTPResponse {
        let path = req.path

        // Auth gate for data-exposing (6001) and mutating/control (6004) endpoints.
        // In-process UI calls (req.trusted) bypass; every socket request is gated,
        // including a same-machine browser hitting 127.0.0.1.
        if req.trusted {
            req.ctx.auth = "trusted"
        } else if AccessControl.requiresAuth(path: path) {
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

        // Playlists (Фаза 0 — плейлисты из iOS). Overlay-only CRUD: the routes below
        // never touch master.db. Mutations are auth-gated (SecurityGates); the
        // read-only recommendations route is PUBLIC (like /api/similar).
        case ("POST", "/api/playlist/create"):          return createPlaylist(req)
        case ("POST", "/api/playlist/create_folder"):   return createFolder(req)
        case ("POST", "/api/playlist/add"):             return playlistAdd(req)
        case ("POST", "/api/playlist/remove"):          return playlistRemove(req)
        case ("POST", "/api/playlist/reorder"):         return playlistReorder(req)
        case ("POST", "/api/playlist/rename"):          return playlistRename(req)
        case ("POST", "/api/playlist/delete"):          return playlistDelete(req)
        case ("POST", "/api/playlist/recommendations"): return getPlaylistRecommendations(req)

        // Фаза 6 — the one route that writes the overlays INTO master.db.
        // Auth-gated in AccessControl.controlProtectedPaths (риск 14).
        case ("POST", "/api/playlist/sync"):            return playlistSync(req)
        case ("GET",  "/api/playlist/sync/status"):     return playlistSyncStatus(req)

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

        // Обновление агента по запросу с телефона (не дожидаясь часового авто-цикла)
        case ("POST", "/api/agent/update"):        return agentUpdateStart(req)
        case ("GET",  "/api/agent/update/status"): return agentUpdateStatus(req)

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
        // 6002: only serve files that live inside the library's own directories.
        // Blocks ?path=/Users/<u>/.ssh/id_rsa, ../ traversal and symlink escapes.
        guard LibraryPathGuard.isAllowed(resolvedPath) else {
            logger.warning("Blocked non-library stream path: raw=\(filePath), resolved=\(resolvedPath)")
            return .error("Forbidden", status: 403)
        }
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
        let respStatus = hasRange ? 206 : 200
        logger.debug("Stream response: track=\(trackID), status=\(respStatus), mime=\(mime), bytes=\(start)-\(end)/\(size), length=\(length), final_path=\(finalPath)")
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
            body: .stream { fd -> Int in
                guard let fh = FileHandle(forReadingAtPath: finalPath) else { return 0 }
                defer { fh.closeFile() }
                fh.seek(toFileOffset: UInt64(start))
                var remaining = length
                var written   = 0
                while remaining > 0 {
                    let chunk = min(256 * 1024, remaining)
                    let data  = fh.readData(ofLength: chunk)
                    if data.isEmpty { break }
                    remaining -= data.count
                    let n = socketWriteAll(fd, data)
                    written += n
                    // Короткая запись = клиент закрыл соединение. Досылать некому;
                    // в access-логе это станет `bytes=X/Y abort=client`.
                    if n < data.count { break }
                }
                return written
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
        guard LibraryPathGuard.isAllowed(resolvedPath) else {   // 6002
            logger.warning("Blocked non-library waveform path: \(resolvedPath)")
            return .error("Forbidden", status: 403)
        }
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
        guard LibraryPathGuard.isAllowed(resolvedPath) else {   // 6002
            logger.warning("Blocked non-library artwork path: \(resolvedPath)")
            return .error("Forbidden", status: 403)
        }
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
        guard LibraryPathGuard.isAllowed(resolvedPath) else {   // 6002 + 6004
            logger.warning("Blocked non-library reveal path: \(resolvedPath)")
            return .error("Forbidden", status: 403)
        }
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

        // Merge playlist overlays (Фаза 0). tracks/playlists are mutated copies so
        // the parser cache stays untouched. `overlayByPath` carries the overlay to
        // encodablePlaylist for the extra keys (rimeo_id/track_ids/state/hash).
        var tracks    = lib.tracks
        var playlists = lib.playlists
        var overlayByPath: [String: PlaylistOverlay] = [:]
        // Synced overlays (dirty == false): master.db is the source of their
        // membership, so they are NOT merged — but the base playlist still has to
        // carry their rimeo_id. See the `guard ov.dirty` branch below (риск 7).
        var identityByPath: [String: PlaylistOverlay] = [:]

        if !data.playlists.isEmpty {
            var trackIndex = [String: Int](minimumCapacity: tracks.count)
            for (i, t) in tracks.enumerated() { trackIndex[t.id] = i }

            // Dedup base playlists by rekordbox_id (override target) and by path.
            var indexByRBID: [String: Int] = [:]
            for (i, p) in playlists.enumerated() {
                if let rb = p.rekordbox_id, !rb.isEmpty { indexByRBID[rb] = i }
            }

            // Rebuild a path's membership from an overlay's ordered, deduped ids.
            func stripPath(_ path: String) {
                for i in tracks.indices {
                    tracks[i].playlist_indices.removeValue(forKey: path)
                    if let j = tracks[i].playlists.firstIndex(of: path) {
                        tracks[i].playlists.remove(at: j)
                    }
                }
            }
            func injectMembership(path: String, trackIDs: [String]) {
                for (pos, tid) in trackIDs.enumerated() {
                    guard let idx = trackIndex[tid] else { continue }
                    tracks[idx].playlist_indices[path] = pos + 1
                    if !tracks[idx].playlists.contains(path) {
                        tracks[idx].playlists.append(path)
                    }
                }
            }

            let now = Date().timeIntervalSince1970
            var removedRBIDs = Set<String>()
            for ov in data.playlists {
                if ov.deleted {
                    // Tombstone: strip membership + drop an edited Rekordbox playlist
                    // from the parsed list; a pure-Rimeo one is simply never emitted.
                    if let rb = ov.rekordbox_id, !rb.isEmpty, let idx = indexByRBID[rb] {
                        let path = playlists[idx].path
                        if !path.isEmpty { stripPath(path) }
                        removedRBIDs.insert(rb)
                    }
                    continue
                }
                if let rb = ov.rekordbox_id, !rb.isEmpty {
                    // Edited Rekordbox playlist: override by id, only when dirty.
                    guard let idx = indexByRBID[rb] else { continue } // unknown id → skip
                    let path = playlists[idx].path
                    guard !path.isEmpty else { continue }
                    guard ov.dirty else {
                        // Clean → base is the source of the membership (Sync wrote it
                        // there). We still stamp rimeo_id/sync_state onto the base
                        // playlist: without it the iOS overlay — which is keyed by
                        // rimeo_id — never matches the real playlist and the user gets a
                        // phantom `rmo:` twin sitting next to it (риск 7).
                        identityByPath[path] = ov
                        continue
                    }
                    stripPath(path)                            // overlay is authoritative
                    injectMembership(path: path, trackIDs: ov.track_ids)
                    overlayByPath[path] = ov
                } else {
                    // Pure-Rimeo playlist: synthetic namespaced path, never collides
                    // with a real Rekordbox path (finding-21).
                    let path = "rmo:\(ov.rimeo_id)"
                    guard !ov.rimeo_id.isEmpty else { continue }
                    injectMembership(path: path, trackIDs: ov.track_ids)
                    overlayByPath[path] = ov
                    playlists.append(Playlist(
                        path: path, date: now, smart: false, updated: now,
                        history: nil, history_id: nil, name: ov.name.isEmpty ? nil : ov.name,
                        rekordbox_id: nil, parent: ov.parent,
                        is_folder: ov.is_folder, is_smart: false
                    ))
                }
            }

            // Drop tombstoned Rekordbox playlists after the loop (indices used above
            // stay valid; overlayByPath entries for removed paths become inert).
            if !removedRBIDs.isEmpty {
                playlists.removeAll { p in
                    if let rb = p.rekordbox_id, removedRBIDs.contains(rb) { return true }
                    return false
                }
            }
        }

        // Same predicate as RekordboxWriter's pending list — one source of truth, or
        // the button offers a sync that no-ops (or hides one that is needed).
        let pendingSync = DataStore.shared.pendingSyncOverlays().count

        logger.info("GET /api/data -> \(tracks.count) tracks, \(playlists.count) playlists (\(overlayByPath.count) overlay), pending_sync=\(pendingSync), source=\(lib.source ?? "unknown")")
        let obj: [String: Any] = [
            "tracks":            tracks.map { encodableTrack($0) },
            "playlists":         playlists.map {
                encodablePlaylist($0, overlay: overlayByPath[$0.path], identity: identityByPath[$0.path])
            },
            "notes":             data.notes,
            "global_exclusions": data.global_exclusions,
            // Return both keys during parity migration:
            // Python serves library_date, while existing Swift code used xml_date.
            "library_date":      lib.xml_date,
            "xml_date":          lib.xml_date,
            // Фаза 6. Clients gate their Sync UI on these two.
            "capabilities":      agentCapabilities(),
            "pending_sync":      pendingSync,
        ]
        return .json(obj)
    }

    /// Announced in /api/data; iOS decodes it into `AgentCapabilities` (Models.swift)
    /// and gates its playlist UI + Sync button on it. Without this block iOS falls
    /// back to *inferring* support from the shape of the payload and pins
    /// `syncSupported = false` — the Sync button is simply never offered.
    ///
    /// `playlist_sync` is a genuine capability, not a health check: it says "this
    /// build has POST /api/playlist/sync AND is configured against a master.db it
    /// could write". In XML-only mode there are no Rekordbox IDs and sync can never
    /// work, so the button must not exist. Transient failures (Rekordbox open, helper
    /// missing, DB busy) stay TRUE here on purpose — they come back from the sync
    /// call as actionable errors ("Закройте Rekordbox и повторите"), which beats a
    /// button that silently disappears.
    private func agentCapabilities() -> [String: Any] {
        let cfg = AppConfig.shared
        let canWriteDB = cfg.dbSourceEnabled && !cfg.dbPath.isEmpty
            && FileManager.default.fileExists(atPath: cfg.dbPath)
        // Наличия базы МАЛО: запись делает frozen-бинарь rbdb-sync-helper, и если он
        // не забандлен (или сборка его потеряла), Sync упадёт с 500 helper_unavailable.
        // Без этой проверки юзер видел бы активную кнопку, жал — и получал ошибку.
        // Capability обязана отражать РЕАЛЬНУЮ способность, а не намерение.
        let hasHelper = RekordboxWriter.bundledSyncHelperPath() != nil

        // Кэш «последнего билда» освежаем в ФОНЕ (не чаще раза в 15 мин): /api/data —
        // горячая ручка, ждать GitHub она не имеет права. Поэтому latest_build здесь
        // всегда из кэша.
        let checker = UpdateChecker.shared
        checker.refreshLatestInBackgroundIfStale()
        let latest  = checker.latestKnownBuild
        let current = checker.currentBuild

        return [
            "playlists":       true,
            "playlist_sync":   canWriteDB && hasHelper,
            "recommendations": true,
            "platform":        "macos",
            "agent_version":   cfg.buildNumber,
            // Аддитивно (старый контракт не ломаем): iOS сравнивает билды и предлагает
            // обновление через POST /api/agent/update.
            // ⚠️ latest_build == 0 значит «агент ещё НЕ спрашивал GitHub», а НЕ
            // «обновлений нет» — поэтому update_available в этом случае false.
            "current_build":    current,
            "latest_build":     latest,
            "update_available": latest > current,
            "self_update":      true,
        ]
    }

    /// "synced" iff what is in master.db matches the overlay right now. Deliberately
    /// the same comparison as DataStore.pendingSyncOverlays() (signature vs
    /// last_synced_hash), so the per-playlist badge and the `pending_sync` count can
    /// never contradict each other.
    private func syncState(_ ov: PlaylistOverlay) -> String {
        ov.last_synced_hash == ov.syncSignature ? "synced" : "pending"
    }

    // MARK: - Pending sync

    /// Сколько оверлеев ещё не записано в master.db. Тот же источник, что и
    /// `pending_sync` в /api/data (DataStore.pendingSyncOverlays) — они НЕ должны
    /// расходиться, иначе кнопка Sync либо предлагает пустой прогон, либо прячет нужный.
    private func pendingSyncCount() -> Int {
        DataStore.shared.pendingSyncOverlays().count
    }

    // MARK: - LAN PSK

    /// Персистентный PSK агента для LAN-авторизации. Выпускается один раз и живёт
    /// в rimo_data.json.
    ///
    /// ⚠️ ГРАБЛИ: раньше секрет рождался ТОЛЬКО внутри getPairingInfo (то есть при
    /// показе QR-кода). У всех, кто связал агент и телефон по email/паролю, а не
    /// сканом QR, `lan_secret` оставался пустым — и весь LAN-путь был мёртв:
    /// SecurityGates.decide() пропускает PSK-ветку при пустом секрете, остаётся
    /// только JWT, которого в локальной сети никто не подставляет → 401. Телефон
    /// молча уходил в облако и тянул музыку через Cloudflare, стоя в одной
    /// комнате с Mac. Поэтому теперь PSK выпускается и при логине в облако.
    static func ensureLANSecret() -> String {
        let existing = DataStore.shared.data.lan_secret
        if !existing.isEmpty { return existing }
        let bytes = (0..<32).map { _ in UInt8.random(in: 0...255) }
        let psk = Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        DataStore.shared.update { d in d.lan_secret = psk }
        return psk
    }

    // MARK: - /api/pairing_info

    private func getPairingInfo(_ req: HTTPRequest) -> HTTPResponse {
        let chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"
        let code  = String((0..<5).map { _ in chars.randomElement()! })

        let psk = Self.ensureLANSecret()
        DataStore.shared.update { d in d.pairing_code = code }

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

    // MARK: - Playlists (overlay CRUD)

    /// JSON string arrays are permissive: numbers are coerced to their string form
    /// (track ids are strings in the model, but a client may send them numeric).
    private func coerceStringArray(_ any: Any?) -> [String] {
        if let arr = any as? [Any] {
            return arr.compactMap { v in
                if let s = v as? String { return s }
                if let n = v as? NSNumber { return n.stringValue }
                return nil
            }
        }
        if let s = any as? String { return [s] }
        if let n = any as? NSNumber { return [n.stringValue] }
        return []
    }

    /// Dedup preserving first-seen order, dropping empties (spec: Set с сохранением порядка).
    private func dedupOrdered(_ ids: [String]) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for id in ids where !id.isEmpty {
            if seen.insert(id).inserted { out.append(id) }
        }
        return out
    }

    /// `track_id` (single) + `track_ids` (array), merged and deduped in order.
    private func bodyTrackIDs(_ body: [String: Any]) -> [String] {
        var ids = coerceStringArray(body["track_id"])
        ids.append(contentsOf: coerceStringArray(body["track_ids"]))
        return dedupOrdered(ids)
    }

    /// Addressing is strictly by id (finding-5): rimeo_id (pure-Rimeo / synthesized
    /// override) or rekordbox_id (real playlist). Empty strings collapse to nil.
    private func addressing(_ body: [String: Any]) -> (rimeo: String?, rekordbox: String?) {
        let rimeo = (body["rimeo_id"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let rb    = coerceStringArray(body["rekordbox_id"]).first.flatMap { $0.isEmpty ? nil : $0 }
        return (rimeo, rb)
    }

    /// Ordered base membership of a parsed playlist path, rebuilt from the tracks'
    /// `playlist_indices`. Used to SEED an override the first time an existing
    /// Rekordbox playlist is edited (the overlay then replaces base membership, so
    /// starting empty would blank the playlist).
    private func parsedMembership(path: String, tracks: [Track]) -> [String] {
        guard !path.isEmpty else { return [] }
        var pairs: [(String, Int)] = []
        for t in tracks {
            if let pos = t.playlist_indices[path] { pairs.append((t.id, pos)) }
        }
        pairs.sort { $0.1 < $1.1 }
        return pairs.map { $0.0 }
    }

    /// 409 barrier for add/reorder/remove targeting a real Rekordbox playlist:
    /// folders / smart / history are not track-editable, and a display-path
    /// collision (same-named playlists) is refused so membership never merges
    /// (finding-19/5). nil ⇒ ok. Pure-Rimeo overlays are checked separately.
    private func rekordboxPlaylistBarrier(_ rb: String?, lib: LibraryData) -> HTTPResponse? {
        guard let rb = rb, !rb.isEmpty,
              let pl = lib.playlists.first(where: { $0.rekordbox_id == rb }) else { return nil }
        if pl.is_folder == true || pl.is_smart == true || pl.smart == true || pl.history == true {
            return HTTPResponse.error("not_editable", status: 409)
        }
        if !pl.path.isEmpty, lib.playlists.filter({ $0.path == pl.path }).count > 1 {
            return HTTPResponse.error("ambiguous_path", status: 409)
        }
        return nil
    }

    /// A pure-Rimeo folder overlay can't hold tracks either.
    private func overlayFolderBarrier(_ rimeo: String?, overlays: [PlaylistOverlay]) -> HTTPResponse? {
        guard let r = rimeo,
              let ov = overlays.first(where: { $0.rimeo_id == r }), ov.is_folder else { return nil }
        return HTTPResponse.error("not_editable", status: 409)
    }

    /// Find-or-create the overlay and apply `transform` to its track ids. `seed` is
    /// used only when CREATING an override of an existing Rekordbox playlist so the
    /// base membership is preserved. Every mutation recomputes content_hash and
    /// marks the overlay dirty/pending (finding-7). Runs inside DataStore.update.
    @discardableResult
    private func upsertOverlay(into d: inout RimoData,
                              rimeoID: String?, rekordboxID: String?,
                              seed: [String] = [],
                              name: String? = nil,
                              isFolder: Bool? = nil,
                              parent: String? = nil,
                              deleted: Bool = false,
                              transform: ([String]) -> [String]) -> (hash: String, rimeoID: String, state: String) {
        var idx: Int? = nil
        if let r = rimeoID, !r.isEmpty { idx = d.playlists.firstIndex { $0.rimeo_id == r } }
        if idx == nil, let rb = rekordboxID, !rb.isEmpty {
            idx = d.playlists.firstIndex { $0.rekordbox_id == rb }
        }

        var ov: PlaylistOverlay
        if let i = idx {
            ov = d.playlists[i]
            ov.track_ids = dedupOrdered(transform(ov.track_ids))
        } else {
            ov = PlaylistOverlay()
            ov.rimeo_id     = (rimeoID?.isEmpty == false) ? rimeoID! : "rmo_\(UUID().uuidString.prefix(12))"
            ov.rekordbox_id = (rekordboxID?.isEmpty == false) ? rekordboxID : nil
            ov.track_ids    = dedupOrdered(transform(seed))
        }
        if let name = name { ov.name = name }
        if let isFolder = isFolder { ov.is_folder = isFolder }
        if let parent = parent { ov.parent = parent }
        ov.deleted      = deleted
        ov.dirty        = true
        ov.state        = "pending"
        ov.content_hash = PlaylistHash.contentHash(ov.track_ids)

        if let i = idx { d.playlists[i] = ov } else { d.playlists.append(ov) }
        return (ov.content_hash ?? "", ov.rimeo_id, ov.state)
    }

    private func jsonBody(_ req: HTTPRequest) -> [String: Any]? {
        try? JSONSerialization.jsonObject(with: req.body) as? [String: Any]
    }

    // POST /api/playlist/create {rimeo_id,name,parent?,is_folder,track_ids[]}
    private func createPlaylist(_ req: HTTPRequest) -> HTTPResponse {
        guard let body = jsonBody(req) else { return .error("Bad request", status: 400) }
        let (rimeo, rb) = addressing(body)
        let name     = (body["name"] as? String) ?? ""
        let parent   = (body["parent"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let isFolder = (body["is_folder"] as? Bool) ?? false
        let incoming = isFolder ? [] : bodyTrackIDs(body)

        var hash = ""; var rid = ""; var state = "pending"
        DataStore.shared.update { d in
            let r = upsertOverlay(into: &d, rimeoID: rimeo, rekordboxID: rb,
                                  name: name, isFolder: isFolder, parent: parent) { $0 + incoming }
            hash = r.hash; rid = r.rimeoID; state = r.state
        }
        return .json(["status": "ok", "rimeo_id": rid, "content_hash": hash, "state": state,
                      "pending_sync": pendingSyncCount()])
    }

    // POST /api/playlist/create_folder {rimeo_id,name,parent?}
    private func createFolder(_ req: HTTPRequest) -> HTTPResponse {
        guard let body = jsonBody(req) else { return .error("Bad request", status: 400) }
        let (rimeo, rb) = addressing(body)
        let name   = (body["name"] as? String) ?? ""
        let parent = (body["parent"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        DataStore.shared.update { d in
            upsertOverlay(into: &d, rimeoID: rimeo, rekordboxID: rb,
                          name: name, isFolder: true, parent: parent) { _ in [] }
        }
        return .json(["status": "ok", "pending_sync": pendingSyncCount()])
    }

    // POST /api/playlist/add {rimeo_id?|rekordbox_id?, track_id|track_ids[]}
    private func playlistAdd(_ req: HTTPRequest) -> HTTPResponse {
        guard let body = jsonBody(req) else { return .error("Bad request", status: 400) }
        let (rimeo, rb) = addressing(body)
        guard rimeo != nil || rb != nil else { return .error("rimeo_id or rekordbox_id required", status: 400) }
        let newIDs = bodyTrackIDs(body)

        let lib = RekordboxParser.shared.parse()
        if let barrier = overlayFolderBarrier(rimeo, overlays: DataStore.shared.data.playlists) { return barrier }
        if let barrier = rekordboxPlaylistBarrier(rb, lib: lib) { return barrier }

        let seed = seedMembership(forRekordboxID: rb, lib: lib)
        var hash = ""; var state = "pending"
        DataStore.shared.update { d in
            let r = upsertOverlay(into: &d, rimeoID: rimeo, rekordboxID: rb, seed: seed) { $0 + newIDs }
            hash = r.hash; state = r.state
        }
        return .json(["status": "ok", "content_hash": hash, "state": state,
                      "pending_sync": pendingSyncCount()])
    }

    // POST /api/playlist/remove {rimeo_id?|rekordbox_id?, track_id|track_ids[]}
    private func playlistRemove(_ req: HTTPRequest) -> HTTPResponse {
        guard let body = jsonBody(req) else { return .error("Bad request", status: 400) }
        let (rimeo, rb) = addressing(body)
        guard rimeo != nil || rb != nil else { return .error("rimeo_id or rekordbox_id required", status: 400) }
        let removeIDs = Set(bodyTrackIDs(body))

        let lib = RekordboxParser.shared.parse()
        if let barrier = rekordboxPlaylistBarrier(rb, lib: lib) { return barrier }

        let seed = seedMembership(forRekordboxID: rb, lib: lib)
        var hash = ""
        DataStore.shared.update { d in
            let r = upsertOverlay(into: &d, rimeoID: rimeo, rekordboxID: rb, seed: seed) { cur in
                cur.filter { !removeIDs.contains($0) }
            }
            hash = r.hash
        }
        return .json(["status": "ok", "content_hash": hash,
                      "pending_sync": pendingSyncCount()])
    }

    // POST /api/playlist/reorder {rimeo_id?|rekordbox_id?, path?, track_ids[]}
    private func playlistReorder(_ req: HTTPRequest) -> HTTPResponse {
        guard let body = jsonBody(req) else { return .error("Bad request", status: 400) }
        let (rimeo, rb) = addressing(body)
        let ordered = dedupOrdered(coerceStringArray(body["track_ids"]))

        let lib = RekordboxParser.shared.parse()
        if let barrier = rekordboxPlaylistBarrier(rb, lib: lib) { return barrier }

        // Don't create an overlay blind: reorder needs an existing target unless a
        // rimeo_id is supplied (create-if-missing only then), per contract (finding-19).
        let overlays  = DataStore.shared.data.playlists
        let hasOverlay = (rimeo.map { r in overlays.contains { $0.rimeo_id == r } } ?? false)
                      || (rb.map { x in overlays.contains { $0.rekordbox_id == x } } ?? false)
        let hasParsed  = rb.map { x in lib.playlists.contains { $0.rekordbox_id == x } } ?? false
        if !hasOverlay && !hasParsed && (rimeo == nil) {
            return .error("playlist_not_found", status: 409)
        }

        var hash = ""; var state = "pending"
        DataStore.shared.update { d in
            let r = upsertOverlay(into: &d, rimeoID: rimeo, rekordboxID: rb, seed: ordered) { _ in ordered }
            hash = r.hash; state = r.state
        }
        return .json(["status": "ok", "content_hash": hash, "state": state,
                      "pending_sync": pendingSyncCount()])
    }

    // POST /api/playlist/rename {rimeo_id?|rekordbox_id?, name}
    private func playlistRename(_ req: HTTPRequest) -> HTTPResponse {
        guard let body = jsonBody(req) else { return .error("Bad request", status: 400) }
        let (rimeo, rb) = addressing(body)
        guard rimeo != nil || rb != nil else { return .error("rimeo_id or rekordbox_id required", status: 400) }
        let name = (body["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !name.isEmpty else { return .error("name required", status: 400) }

        let lib = RekordboxParser.shared.parse()
        let seed = seedMembership(forRekordboxID: rb, lib: lib)   // preserve membership on first override
        DataStore.shared.update { d in
            upsertOverlay(into: &d, rimeoID: rimeo, rekordboxID: rb, seed: seed, name: name) { $0 }
        }
        return .json(["status": "ok", "pending_sync": pendingSyncCount()])
    }

    // POST /api/playlist/delete {rimeo_id?|rekordbox_id?} — tombstone in overlay
    private func playlistDelete(_ req: HTTPRequest) -> HTTPResponse {
        guard let body = jsonBody(req) else { return .error("Bad request", status: 400) }
        let (rimeo, rb) = addressing(body)
        guard rimeo != nil || rb != nil else { return .error("rimeo_id or rekordbox_id required", status: 400) }
        DataStore.shared.update { d in
            upsertOverlay(into: &d, rimeoID: rimeo, rekordboxID: rb, deleted: true) { _ in [] }
        }
        return .json(["status": "ok", "pending_sync": pendingSyncCount()])
    }

    // GET /api/playlist/sync/status — честный прогресс идущего Sync.
    //
    // Синк — блокирующий POST на десятки секунд, поэтому стадии телефон забирает
    // ОТДЕЛЬНЫМ опросом. Стадии реальные (checking → backup → writing → verifying),
    // счётчик треков приходит из stdout хелпера. Декоративного прогресса тут нет:
    // если бы агент их не слал, экран мог бы только крутить спиннер и врать.
    private func playlistSyncStatus(_ req: HTTPRequest) -> HTTPResponse {
        let p = RekordboxWriter.shared.progress
        var body: [String: Any] = [
            "active":       p.active,
            "stage":        p.stage,
            "stage_index":  p.stageIndex,
            "stage_total":  p.stageTotal,
            "tracks_done":  p.tracksDone,
            "tracks_total": p.tracksTotal,
            "playlist":     p.playlistName,
        ]
        if let e = p.error { body["error"] = e }
        return .json(body)
    }

    // POST /api/playlist/sync {rimeo_ids?: [String]} — Фаза 6. Writes the pending
    // overlays INTO the user's real Rekordbox master.db. Auth-gated (риск 14).
    //
    // Thin on purpose: every dangerous step (Rekordbox-running barrier, 3-file
    // backup, plan, helper subprocess, USN check, verify-by-reparse, write-back)
    // lives in RekordboxWriter, which serialises runs on its own queue. Synchronous
    // like sendTelegram — the caller gets the real outcome, not a fire-and-forget
    // "ok" it would have to poll.
    //
    //   200 {status:"ok", synced:[{rimeo_id,rekordbox_id,sync_state}], failed:[], counts:{…}}
    //   200 {status:"ok", synced:[], nothing:true}    — nothing pending (idempotent)
    //   409 sync_in_progress | rekordbox_running | ambiguous_path | db_unavailable
    //   500 write_failed | helper_unavailable | backup_failed | usn_not_advanced |
    //       write_verify_failed
    private func playlistSync(_ req: HTTPRequest) -> HTTPResponse {
        // Body is OPTIONAL: an empty POST means "sync everything pending" (that is
        // what the iOS button sends). So no 400 on a missing/!dict body — only an
        // explicit non-empty `rimeo_ids` narrows the run.
        let requested = jsonBody(req).map { dedupOrdered(coerceStringArray($0["rimeo_ids"])) } ?? []
        let result = RekordboxWriter.shared.sync(rimeoIDs: requested.isEmpty ? nil : requested)

        if result.ok {
            let c = result.counts
            logger.info("POST /api/playlist/sync -> ok, synced=\(result.synced.count) nothing=\(result.nothing) created=\(c.created) updated=\(c.updated) deleted=\(c.deleted)")
        } else {
            logger.warning("POST /api/playlist/sync -> \(result.status) \(result.error ?? "?") \(result.detail ?? "")")
        }
        return .json(result.body, status: result.status)
    }

    // POST /api/playlist/recommendations {playlist_id?, track_ids[], limit, use_key, exclude_ids[], offset?}
    // PUBLIC (like /api/similar). Response mirrors /api/similar: {results:[{track,score}]}.
    //
    // `offset` — страница ранжированного списка. Кнопка Refresh в iOS при неизменном
    // составе шлёт offset += limit и получает СЛЕДУЮЩИЙ срез вместо того же самого топа;
    // само ранжирование при этом детерминировано (рандома нет). Старый клиент поле не
    // шлёт → offset 0 → поведение как раньше.
    private func getPlaylistRecommendations(_ req: HTTPRequest) -> HTTPResponse {
        guard let body = jsonBody(req) else { return .error("Bad request", status: 400) }
        let trackIDs = dedupOrdered(coerceStringArray(body["track_ids"]))
        guard !trackIDs.isEmpty else { return .json(["results": [Any]()]) }   // empty seed → []

        let rawLimit = (body["limit"] as? NSNumber)?.intValue
            ?? Int((body["limit"] as? String) ?? "") ?? 50
        let limit    = min(max(1, rawLimit), 50)                          // clamp ≤ 50
        let useKey   = (body["use_key"] as? Bool) ?? true
        let exclude  = Set(coerceStringArray(body["exclude_ids"]))
        let rawOffset = (body["offset"] as? NSNumber)?.intValue
            ?? Int((body["offset"] as? String) ?? "") ?? 0
        let offset    = min(max(0, rawOffset), 5000)                      // защита от мусора в теле

        let lib     = RekordboxParser.shared.parse()                     // reuse cached parse
        let results = SimilarityEngine.shared.recommendForPlaylist(
            trackIDs: trackIDs, library: lib,
            topN: limit, useKey: useKey, excludeIDs: exclude, offset: offset)

        guard let data = try? JSONEncoder().encode(results),
              let json = try? JSONSerialization.jsonObject(with: data) else {
            return .error("Encode error", status: 500)
        }
        return .json(["results": json])
    }

    /// Ordered base membership to seed a first-time override of an existing
    /// Rekordbox playlist; empty for pure-Rimeo targets.
    private func seedMembership(forRekordboxID rb: String?, lib: LibraryData) -> [String] {
        guard let rb = rb, !rb.isEmpty,
              let pl = lib.playlists.first(where: { $0.rekordbox_id == rb }) else { return [] }
        return parsedMembership(path: pl.path, tracks: lib.tracks)
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
            trackID: id, library: lib,
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
            "log":           logger.tail(bytes: 256 * 1024),
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
            "caps":       CloudRelay.capabilities,
            // Облако передаст PSK телефону того же аккаунта — тот же уровень
            // доверия, что и QR (который печатает секрет прямо на экране), но
            // работает и при входе по email. Без этого LAN-путь не включается.
            "lan_secret": Self.ensureLANSecret(),
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
            "caps":       CloudRelay.capabilities,
            "lan_secret": Self.ensureLANSecret(),
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
    /// Auth for protected paths. A valid per-device PSK authorises a LOCAL client
    /// without the server JWT (the LAN path); otherwise a valid server JWT is
    /// required, which the server only signs once the agent is on its NAMED tunnel.
    ///
    /// 6001 fix: when there is neither a PSK nor a named tunnel, this now DENIES
    /// (fail-closed) instead of returning nil (fail-open). The policy lives in the
    /// pure, unit-tested AccessControl.decide so the exploit/legit cases are
    /// exercised directly in tests.
    private func authGate(_ req: HTTPRequest) -> HTTPResponse? {
        let secret   = DataStore.shared.data.lan_secret
        let provided = req.queryParams["lan_token"] ?? bearerToken(req)
        let aud      = TunnelManager.shared.namedHostname
        let jwtToken = JWTValidator.extractToken(from: req)

        let decision = AccessControl.decide(
            lanSecret: secret,
            providedToken: provided,
            namedHostname: aud,
            jwtToken: jwtToken,
            validate: { JWTValidator.validate(token: $0, expectedAudience: $1) }
        )
        if decision == .allow {
            // Основание допуска пишем в контекст запроса — его подхватит одна строка
            // [REQ] в access-логе (auth=psk / auth=jwt). Отдельную INFO-строку здесь
            // больше не плодим: она дублировала бы [REQ] на каждый запрос.
            let byPSK = !secret.isEmpty && provided != nil
                && AccessControl.constantTimeEquals(provided!, secret)
            req.ctx.auth = byPSK ? "psk" : "jwt"
            return nil
        }

        let reason: String
        if aud.isEmpty {
            reason = (provided == nil) ? "no_credentials" : "psk_invalid_no_tunnel"
        } else {
            reason = JWTValidator.validate(token: jwtToken, expectedAudience: aud)?.rawValue ?? "unauthorized"
        }
        req.ctx.auth = "deny:\(reason)"
        logger.warning("Auth rejected: path=\(req.path), reason=\(reason), aud=\(aud), token_present=\(jwtToken != nil), psk_present=\(provided != nil)")
        return HTTPResponse(
            status: 401,
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

    private func bearerToken(_ req: HTTPRequest) -> String? {
        guard let auth = req.headers["authorization"],
              auth.lowercased().hasPrefix("bearer ") else { return nil }
        return String(auth.dropFirst("bearer ".count))
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

    /// `overlay` — the overlay that OWNS this playlist's membership (pure-Rimeo, or a
    /// dirty override of a Rekordbox one): its values win over the parsed ones.
    /// `identity` — a already-synced overlay (Фаза 6): master.db is authoritative for
    /// the content, so only the identity/state keys are stamped on and `track_ids`
    /// are deliberately NOT emitted (they could be stale if the user edited the
    /// playlist inside Rekordbox after the sync). The two are mutually exclusive.
    private func encodablePlaylist(_ p: Playlist,
                                   overlay: PlaylistOverlay? = nil,
                                   identity: PlaylistOverlay? = nil) -> [String: Any] {
        var dict: [String: Any] = [
            "path": p.path, "date": p.date, "smart": p.smart ?? false,
            // «Recently changed» на клиенте: реальный updated_at, иначе fallback на date.
            "updated": p.updated ?? p.date,
            "is_folder": p.is_folder ?? false,
            "is_smart":  p.is_smart ?? (p.smart ?? false),
        ]
        if let rb = p.rekordbox_id, !rb.isEmpty { dict["rekordbox_id"] = rb }
        if let parent = p.parent, !parent.isEmpty { dict["parent"] = parent }
        if let name = p.name, !name.isEmpty { dict["name"] = name }
        // ⚠️ Этот словарь собирается ВРУЧНУЮ — новое поле модели сюда не попадёт само.
        // Именно так `seq` (порядок Rekordbox) молча терялся, хотя и парсер, и модель
        // его уже отдавали.
        if let seq = p.seq { dict["seq"] = seq }
        if p.history == true {
            dict["history"]    = true
            dict["history_id"] = p.history_id ?? ""
            dict["name"]       = p.name ?? ""
        }
        // Overlay-backed playlist (Фаза 0): carry the id/membership/state so iOS can
        // dedup by id, show the "not synced" badge and self-clear the overlay once
        // the agent's content_hash matches. Overlay values win over parsed ones.
        if let ov = overlay {
            dict["rimeo_id"]     = ov.rimeo_id
            dict["track_ids"]    = ov.track_ids
            dict["state"]        = ov.state
            dict["content_hash"] = ov.content_hash ?? PlaylistHash.contentHash(ov.track_ids)
            dict["is_folder"]    = ov.is_folder
            // Фаза 6: "pending" = not (yet) written into master.db. Drives the
            // "not synced" badge; `state` above is the Фаза-0 overlay lifecycle.
            dict["sync_state"]   = syncState(ov)
            if let rb = ov.rekordbox_id, !rb.isEmpty { dict["rekordbox_id"] = rb }
            if let parent = ov.parent, !parent.isEmpty { dict["parent"] = parent }
            if !ov.name.isEmpty { dict["name"] = ov.name }
        } else if let ov = identity {
            // Synced: the parsed playlist IS the truth. Stamp only who it is, so the
            // iOS overlay matches it by rimeo_id instead of drawing a phantom twin.
            dict["rimeo_id"]   = ov.rimeo_id
            dict["sync_state"] = syncState(ov)
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

    // MARK: - /api/agent/update

    // POST /api/agent/update — поставить последний релиз ПРЯМО СЕЙЧАС.
    //
    // Отвечает сразу: скачивание, проверка подписи и подмена бандла идут в фоне
    // (UpdateChecker.startUpdateNow), а стадии телефон забирает из
    // GET /api/agent/update/status. Блокируемся только на опрос GitHub — без него
    // нечем ответить на вопрос «а есть ли куда обновляться».
    //
    //   200 {status:"started", target, target_build, current_build, notes}
    //   200 {status:"up_to_date", current_build, latest_build}
    //   409 update_in_progress    — установка уже идёт
    //   503 update_check_failed   — GitHub недоступен. Отдельный код нужен, чтобы НЕ
    //                               соврать «у вас последняя версия» при сетевой ошибке.
    private func agentUpdateStart(_ req: HTTPRequest) -> HTTPResponse {
        let checker = UpdateChecker.shared
        let current = checker.currentBuild
        switch checker.startUpdateNow() {
        case .started(let tag, let build, let notes):
            logger.info("POST /api/agent/update -> starting \(tag) (build\(current) → build\(build))")
            return .json([
                "status":        "started",
                "target":        tag,
                "target_build":  build,
                "current_build": current,
                "notes":         notes,
            ])
        case .upToDate:
            logger.info("POST /api/agent/update -> already on latest (build\(current))")
            return .json([
                "status":        "up_to_date",
                "current_build": current,
                "latest_build":  checker.latestKnownBuild,
            ])
        case .inProgress:
            return .error("update_in_progress", status: 409)
        case .checkFailed:
            return .error("update_check_failed", status: 503)
        }
    }

    // GET /api/agent/update/status — честные стадии обновления для прогресса в iOS:
    // idle | downloading (progress 0…1) | verifying | installing | restarting | done | error.
    //
    // Стадии проставляет сам UpdateChecker вокруг РЕАЛЬНЫХ шагов (скачивание,
    // проверка подписи, подмена бандла) — декоративного таймера тут нет: телефон
    // показывает «Signature verified» только после того, как подпись действительно
    // проверена.
    //
    // `restarting` — последняя стадия, которую этот процесс успевает отдать: applyZip
    // сразу за ней делает open + exit(0). Отметка ниже сообщает апдейтеру, что ответ
    // ушёл, и он может выходить. `done` придёт уже от НОВОГО процесса.
    private func agentUpdateStatus(_ req: HTTPRequest) -> HTTPResponse {
        let cfg     = AppConfig.shared
        let current = UpdateChecker.shared.currentBuild
        let s       = UpdateProgress.shared.snapshot(currentBuild: current)

        if s.stage == .restarting { UpdateProgress.shared.markRestartingDelivered() }

        var body: [String: Any] = [
            "stage":         s.stage.rawValue,
            "active":        s.isActive,
            "progress":      s.progress,
            "current_build": current,
            "agent_version": cfg.buildNumber,
        ]
        if !s.targetTag.isEmpty { body["target"]       = s.targetTag }
        if s.targetBuild > 0    { body["target_build"] = s.targetBuild }
        if let e = s.error      { body["error"]        = e }
        return .json(body)
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
