import Foundation

final class RekordboxParser: NSObject {
    static let shared = RekordboxParser()

    private let queue = DispatchQueue(label: "rimeo.parser", qos: .userInitiated)
    private var cachedData:  LibraryData?
    private var cachedMtime: Double = 0
    private var cachedSourceKey: String = ""

    // Last error from master.db helper; nil when last attempt succeeded or cache was cleared
    private(set) var masterDBError: String? = nil
    // Avoid re-running the Python helper for the same file version that already failed
    private var masterDBLastFailedPath:  String = ""
    private var masterDBLastFailedMtime: Double = -1

    func parse() -> LibraryData {
        return queue.sync { _parse() }
    }

    private func _parse() -> LibraryData {
        let dbPath = AppConfig.shared.dbPath
        if !dbPath.isEmpty, FileManager.default.fileExists(atPath: dbPath) {
            let mtime = fileMtime(at: dbPath)
            let cacheKey = "db:\(dbPath)"
            if let cached = cachedData, mtime == cachedMtime, cacheKey == cachedSourceKey {
                return cached
            }

            let alreadyFailed = dbPath == masterDBLastFailedPath && mtime == masterDBLastFailedMtime
            if !alreadyFailed {
                if let dbResult = parseMasterDB(dbPath: dbPath, mtime: mtime),
                   !dbResult.tracks.isEmpty {
                    cachedData = dbResult
                    cachedMtime = mtime
                    cachedSourceKey = cacheKey
                    masterDBError = nil
                    masterDBLastFailedPath = ""
                    masterDBLastFailedMtime = -1
                    logger.info("master.db parsed: \(dbResult.tracks.count) tracks")
                    return dbResult
                }
                masterDBLastFailedPath = dbPath
                masterDBLastFailedMtime = mtime
            }
        }

        let xmlPath = AppConfig.shared.xmlPath
        guard !xmlPath.isEmpty, FileManager.default.fileExists(atPath: xmlPath) else {
            return LibraryData(tracks: [], playlists: [], xml_date: 0, source: nil)
        }

        let mtime = fileMtime(at: xmlPath)
        let cacheKey = "xml:\(xmlPath)"

        if let cached = cachedData, mtime == cachedMtime, cacheKey == cachedSourceKey {
            return cached
        }

        logger.info("Parsing Rekordbox XML (cache miss)…")
        guard let data = FileManager.default.contents(atPath: xmlPath),
              let xml = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1)
        else {
            return LibraryData(tracks: [], playlists: [], xml_date: 0, source: nil)
        }

        let result = parseXML(xml, mtime: mtime)
        cachedData  = result
        cachedMtime = mtime
        cachedSourceKey = cacheKey
        logger.info("XML parsed: \(result.tracks.count) tracks")
        return result
    }

    // SAX-style parse using XMLParser for large file performance
    private func parseXML(_ xmlString: String, mtime: Double) -> LibraryData {
        guard let data = xmlString.data(using: .utf8) else {
            return LibraryData(tracks: [], playlists: [], xml_date: mtime, source: "xml")
        }

        // Use XMLDocument (DOM) — fine for typical Rekordbox libraries up to ~50k tracks
        guard let doc = try? XMLDocument(data: data, options: []) else {
            return LibraryData(tracks: [], playlists: [], xml_date: mtime, source: "xml")
        }
        let root = doc.rootElement()

        // --- Parse COLLECTION ---
        var tracksDB: [Track] = []
        if let collection = root?.elements(forName: "COLLECTION").first {
            for el in collection.elements(forName: "TRACK") {
                guard let tid = el.attribute(forName: "TrackID")?.stringValue,
                      !tid.isEmpty else { continue }

                let rawDate = el.attribute(forName: "DateAdded")?.stringValue ?? ""
                let ts: Double
                if let d = ISO8601DateFormatter().date(from: rawDate) {
                    ts = d.timeIntervalSince1970
                } else if rawDate.count >= 10,
                          let d = DateFormatter.yyyyMMdd.date(from: String(rawDate.prefix(10))) {
                    ts = d.timeIntervalSince1970
                } else {
                    ts = 0
                }

                let bpm    = Double(el.attribute(forName: "AverageBpm")?.stringValue ?? "0") ?? 0
                let br     = Int(el.attribute(forName: "BitRate")?.stringValue ?? "0") ?? 0
                let pc     = Int(el.attribute(forName: "PlayCount")?.stringValue ?? "0") ?? 0
                let rawLoc = el.attribute(forName: "Location")?.stringValue ?? ""

                tracksDB.append(Track(
                    id:               tid,
                    artist:           el.attribute(forName: "Artist")?.stringValue ?? "Unknown Artist",
                    title:            el.attribute(forName: "Name")?.stringValue ?? "Unknown Title",
                    genre:            el.attribute(forName: "Genre")?.stringValue ?? "",
                    label:            el.attribute(forName: "Label")?.stringValue ?? "",
                    rel_date:         el.attribute(forName: "Year")?.stringValue ?? "",
                    key:              el.attribute(forName: "Tonality")?.stringValue ?? "—",
                    bpm:              bpm,
                    bitrate:          br,
                    play_count:       pc,
                    location:         normalizePath(rawLoc),
                    timestamp:        ts,
                    date_str:         rawDate.count >= 10 ? String(rawDate.prefix(10)) : "0000-00-00",
                    playlists:        [],
                    playlist_indices: [:]
                ))
            }
        }

        // Build lookup for O(1) track access
        var trackIndex: [String: Int] = [:]
        for (i, t) in tracksDB.enumerated() { trackIndex[t.id] = i }

        // --- Parse PLAYLISTS ---
        var allPlaylists: [String: Double] = [:]

        func walkPlaylists(_ node: XMLElement, path: [String]) {
            for n in node.elements(forName: "NODE") {
                let nodeType = n.attribute(forName: "Type")?.stringValue ?? ""
                let name     = n.attribute(forName: "Name")?.stringValue ?? ""
                if nodeType == "0" {
                    walkPlaylists(n, path: path + [name])
                } else if nodeType == "1" {
                    let filtered = path.filter { $0.uppercased() != "ROOT" }
                    let pPath    = (filtered + [name]).joined(separator: " / ")
                    if allPlaylists[pPath] == nil { allPlaylists[pPath] = 0 }

                    var order = 1
                    for trackNode in n.elements(forName: "TRACK") {
                        let key = trackNode.attribute(forName: "Key")?.stringValue
                               ?? trackNode.attribute(forName: "TrackID")?.stringValue
                               ?? ""
                        if let idx = trackIndex[key] {
                            tracksDB[idx].playlist_indices[pPath] = order
                            if !tracksDB[idx].playlists.contains(pPath) {
                                tracksDB[idx].playlists.append(pPath)
                            }
                            if tracksDB[idx].timestamp > (allPlaylists[pPath] ?? 0) {
                                allPlaylists[pPath] = tracksDB[idx].timestamp
                            }
                        }
                        order += 1
                    }
                }
            }
        }

        if let plRoot = root?.elements(forName: "PLAYLISTS").first {
            walkPlaylists(plRoot, path: [])
        }

        tracksDB.sort { $0.timestamp > $1.timestamp }

        let playlists = allPlaylists.map { Playlist(path: $0.key, date: $0.value) }
        return LibraryData(tracks: tracksDB, playlists: playlists, xml_date: mtime, source: "xml")
    }

    private func normalizePath(_ loc: String) -> String {
        var s = loc
        if s.hasPrefix("file://localhost/") {
            s = String(s.dropFirst("file://localhost".count))
        } else if s.hasPrefix("file:///") {
            s = String(s.dropFirst("file://".count))
        }
        return s.removingPercentEncoding ?? s
    }

    func invalidateCache() {
        queue.sync {
            cachedMtime = 0
            cachedData = nil
            cachedSourceKey = ""
            masterDBLastFailedMtime = -1
            masterDBLastFailedPath = ""
            masterDBError = nil
        }
    }

    private func fileMtime(at path: String) -> Double {
        do {
            let attrs = try FileManager.default.attributesOfItem(atPath: path)
            return (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        } catch {
            return 0
        }
    }

    private func parseMasterDB(dbPath: String, mtime: Double) -> LibraryData? {
        if let nativeResult = parseMasterDBWithBundledHelper(dbPath: dbPath, mtime: mtime) {
            return nativeResult
        }
        return parseMasterDBWithPythonHelper(dbPath: dbPath, mtime: mtime)
    }

    private func parseMasterDBWithBundledHelper(dbPath: String, mtime: Double) -> LibraryData? {
        guard let helper = bundledMasterDBHelperPath() else {
            logger.info("bundled master.db helper not found; falling back to Python helper")
            return nil
        }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: helper)
        let tempOutput = FileManager.default.temporaryDirectory
            .appendingPathComponent("rimeo_masterdb_native_\(UUID().uuidString).json")
        proc.arguments = [dbPath, String(mtime), tempOutput.path]

        let errPipe = Pipe()
        proc.standardError = errPipe

        do {
            try proc.run()
            proc.waitUntilExit()
        } catch {
            logger.warning("bundled master.db helper launch failed: \(error)")
            masterDBError = error.localizedDescription
            return nil
        }

        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        let stderr = String(data: errData, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        guard proc.terminationStatus == 0 else {
            try? FileManager.default.removeItem(at: tempOutput)
            logger.warning("bundled master.db helper failed: \(stderr)")
            masterDBError = stderr.isEmpty ? "bundled helper failed" : stderr
            return nil
        }

        guard let outData = try? Data(contentsOf: tempOutput) else {
            logger.warning("bundled master.db helper did not produce output file")
            masterDBError = "bundled helper produced no output"
            return nil
        }
        try? FileManager.default.removeItem(at: tempOutput)

        do {
            return try JSONDecoder().decode(LibraryData.self, from: outData)
        } catch {
            let snippet = String(data: outData.prefix(300), encoding: .utf8) ?? ""
            logger.warning("bundled master.db helper decode failed: \(error); payload=\(snippet)")
            masterDBError = "bundled helper JSON decode error: \(error.localizedDescription)"
            return nil
        }
    }

    private func bundledMasterDBHelperPath() -> String? {
        let fm = FileManager.default
        let execDir = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
        let candidates = [
            execDir.appendingPathComponent("rbdb-helper").path,
            execDir.appendingPathComponent("RekordboxDBHelper").path,
            Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/rbdb-helper").path,
            Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/RekordboxDBHelper").path,
        ]

        for path in candidates where fm.isExecutableFile(atPath: path) {
            return path
        }
        return nil
    }

    private func parseMasterDBWithPythonHelper(dbPath: String, mtime: Double) -> LibraryData? {
        guard let python = findBinary("python3") else {
            logger.warning("python3 not found — master.db fallback unavailable")
            masterDBError = "python3 not found"
            return nil
        }

        let script = #"""
import base64
import datetime as dt
import json
import os
import sys
import zlib

try:
    from sqlcipher3 import dbapi2 as sqlite3
except ModuleNotFoundError:
    try:
        from pysqlcipher3 import dbapi2 as sqlite3
    except ModuleNotFoundError:
        sys.stderr.write("SQLCipher Python module missing: tried sqlcipher3 and pysqlcipher3")
        sys.exit(2)

BLOB_KEY = b"657f48f84c437cc1"
BLOB = b"PN_Pq^*N>(JYe*u^8;Yg76HuZ<mR13S?=>)b9;DpoTXV(6ItkU`}8*m6tx_I{Solh_N#dfe{v="

def deobfuscate(blob: bytes) -> str:
    data = base64.b85decode(blob)
    xored = bytes(b ^ BLOB_KEY[i % len(BLOB_KEY)] for i, b in enumerate(data))
    return zlib.decompress(xored).decode("utf-8")

def as_timestamp(created_at: str, fallback_date: str) -> float:
    try:
        if created_at:
            return dt.datetime.fromisoformat(str(created_at)).timestamp()
    except Exception:
        pass
    try:
        if fallback_date:
            return dt.datetime.fromisoformat(str(fallback_date)).timestamp()
    except Exception:
        pass
    return 0.0

db_path = sys.argv[1]
mtime = float(sys.argv[2])
out_path = sys.argv[3]

con = sqlite3.connect(f"file:{db_path}?mode=ro", uri=True)
cur = con.cursor()
cur.execute(f"PRAGMA key = '{deobfuscate(BLOB)}';")

cur.execute(
    """
    SELECT
        c.ID,
        COALESCE(a.Name, ''),
        COALESCE(c.Title, ''),
        COALESCE(g.Name, ''),
        COALESCE(l.Name, ''),
        COALESCE(c.ReleaseYear, ''),
        COALESCE(k.ScaleName, '—'),
        COALESCE(c.BPM, 0),
        COALESCE(c.BitRate, 0),
        COALESCE(c.DJPlayCount, 0),
        COALESCE(c.FolderPath, ''),
        COALESCE(c.DateCreated, ''),
        COALESCE(c.created_at, '')
    FROM djmdContent c
    LEFT JOIN djmdArtist a ON c.ArtistID = a.ID
    LEFT JOIN djmdGenre g  ON c.GenreID = g.ID
    LEFT JOIN djmdLabel l  ON c.LabelID = l.ID
    LEFT JOIN djmdKey k    ON c.KeyID = k.ID
    WHERE c.rb_local_deleted = 0
    """
)

tracks = []
track_index = {}
for row in cur.fetchall():
    track_id = str(row[0])
    date_str = str(row[11] or '')[:10] if row[11] else "0000-00-00"
    timestamp = as_timestamp(row[12], row[11])
    track = {
        "id": track_id,
        "artist": str(row[1] or "Unknown Artist"),
        "title": str(row[2] or "Unknown Title"),
        "genre": str(row[3] or ""),
        "label": str(row[4] or ""),
        "rel_date": str(row[5] or ""),
        "key": str(row[6] or "—"),
        "bpm": round(float(row[7] or 0) / 100.0, 2) if row[7] else 0.0,
        "bitrate": int(row[8] or 0),
        "play_count": int(row[9] or 0),
        "location": str(row[10] or ""),
        "timestamp": timestamp,
        "date_str": date_str,
        "playlists": [],
        "playlist_indices": {},
    }
    track_index[track_id] = len(tracks)
    tracks.append(track)

cur.execute(
    """
    SELECT ID, Name, ParentID, Attribute
    FROM djmdPlaylist
    WHERE rb_local_deleted = 0
    """
)
playlist_rows = cur.fetchall()
playlists = {
    str(row[0]): {
        "id": str(row[0]),
        "name": str(row[1] or ""),
        "parent": str(row[2] or "root"),
        "attribute": int(row[3] or 0),
    }
    for row in playlist_rows
}

def playlist_path(pid: str) -> str:
    parts = []
    seen = set()
    current = pid
    while current and current != "root" and current not in seen:
        seen.add(current)
        item = playlists.get(current)
        if not item:
            break
        parts.append(item["name"])
        current = item["parent"]
    parts.reverse()
    return " / ".join([p for p in parts if p])

playlist_latest = {}

cur.execute(
    """
    SELECT PlaylistID, ContentID, TrackNo
    FROM djmdSongPlaylist
    WHERE rb_local_deleted = 0
    """
)
for playlist_id, content_id, track_no in cur.fetchall():
    pid = str(playlist_id)
    tid = str(content_id)
    idx = track_index.get(tid)
    if idx is None:
        continue
    ppath = playlist_path(pid)
    if not ppath:
        continue
    track = tracks[idx]
    track["playlist_indices"][ppath] = int(track_no or 0)
    if ppath not in track["playlists"]:
        track["playlists"].append(ppath)
    if track["timestamp"] > playlist_latest.get(ppath, 0):
        playlist_latest[ppath] = track["timestamp"]

tracks.sort(key=lambda item: item["timestamp"], reverse=True)
playlists_list = [{"path": path, "date": playlist_latest[path]} for path in playlist_latest]

with open(out_path, "w", encoding="utf-8") as fh:
    json.dump({
        "tracks": tracks,
        "playlists": playlists_list,
        "xml_date": mtime,
        "source": "db",
    }, fh)
"""#

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: python)
        let tempOutput = FileManager.default.temporaryDirectory
            .appendingPathComponent("rimeo_masterdb_\(UUID().uuidString).json")
        proc.arguments = ["-c", script, dbPath, String(mtime), tempOutput.path]

        let errPipe = Pipe()
        proc.standardError = errPipe

        do {
            try proc.run()
            proc.waitUntilExit()
        } catch {
            logger.warning("master.db helper launch failed: \(error)")
            masterDBError = error.localizedDescription
            return nil
        }

        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        let stderr = String(data: errData, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        guard proc.terminationStatus == 0 else {
            try? FileManager.default.removeItem(at: tempOutput)
            logger.warning("master.db helper failed: \(stderr)")
            masterDBError = stderr
            return nil
        }

        if !stderr.isEmpty {
            logger.debug("master.db helper stderr: \(stderr)")
        }

        guard let outData = try? Data(contentsOf: tempOutput) else {
            logger.warning("master.db helper did not produce output file")
            masterDBError = "helper produced no output"
            return nil
        }
        try? FileManager.default.removeItem(at: tempOutput)

        do {
            return try JSONDecoder().decode(LibraryData.self, from: outData)
        } catch {
            let snippet = String(data: outData.prefix(300), encoding: .utf8) ?? ""
            logger.warning("master.db decode failed: \(error); payload=\(snippet)")
            masterDBError = "JSON decode error: \(error.localizedDescription)"
            return nil
        }
    }
}

private extension DateFormatter {
    static let yyyyMMdd: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()
}
