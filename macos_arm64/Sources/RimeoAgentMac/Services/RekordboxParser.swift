import Foundation

final class RekordboxParser: NSObject {
    static let shared = RekordboxParser()

    private let queue = DispatchQueue(label: "rimeo.parser", qos: .userInitiated)
    private var cachedData:  LibraryData?
    private var cachedMtime: Double = 0
    private var cachedSourceKey: String = ""
    // Производный индекс trackID → Track, строится вместе с cachedData (единый
    // источник правды). Нужен для O(1)-поиска обложек вместо скана всех треков.
    private var cachedTrackIndex: [String: Track] = [:]
    // Debounce: даже если mtime сменился, не переразбираем чаще, чем раз в N сек —
    // чтобы checkpoint Rekordbox во время стрима не молотил диск. Реальные правки
    // библиотеки подхватятся с задержкой < N сек (для DJ-сценария незаметно).
    private var lastParseAt: Double = 0
    private let minReparseInterval: Double = 3.0

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
        if AppConfig.shared.dbSourceEnabled, !dbPath.isEmpty, FileManager.default.fileExists(atPath: dbPath) {
            let mtime = dbMtime(at: dbPath)
            let cacheKey = "db:\(dbPath)"
            if let cached = cachedData, cacheKey == cachedSourceKey {
                // Свежий кеш — отдаём сразу.
                if mtime == cachedMtime { return cached }
                // mtime сменился, но не парсим чаще раза в N сек (debounce).
                if now() - lastParseAt < minReparseInterval { return cached }
            }
            lastParseAt = now()

            let alreadyFailed = dbPath == masterDBLastFailedPath && mtime == masterDBLastFailedMtime
            if !alreadyFailed {
                if let dbResult = parseMasterDB(dbPath: dbPath, mtime: mtime),
                   !dbResult.tracks.isEmpty {
                    setCache(dbResult, mtime: mtime, sourceKey: cacheKey)
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
        guard AppConfig.shared.xmlSourceEnabled, !xmlPath.isEmpty, FileManager.default.fileExists(atPath: xmlPath) else {
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
        setCache(result, mtime: mtime, sourceKey: cacheKey)
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
                let dur    = Double(el.attribute(forName: "TotalTime")?.stringValue ?? "0") ?? 0
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
                    duration:         dur > 0 ? dur : nil,
                    bitrate:          br,
                    play_count:       pc,
                    location:         normalizePath(rawLoc),
                    timestamp:        ts,
                    date_str:         rawDate.count >= 10 ? String(rawDate.prefix(10)) : "0000-00-00",
                    image_path:       nil,
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

        let playlists = allPlaylists.map { Playlist(path: $0.key, date: $0.value, smart: false) }
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

    // Rekordbox 6 master.db is SQLite in WAL mode: new edits land in master.db-wal
    // first and the main master.db mtime stays frozen until a checkpoint. Key the
    // cache on the newest of db / -wal so WAL writes invalidate the cache.
    // NB: -shm (shared-memory index) НЕ учитываем — SQLite дёргает его при любом
    // открытии БД (даже на чтение), реальных данных там нет; раньше из-за него
    // кеш сбрасывался почти на каждый запрос и БД переразбиралась во время стрима.
    private func dbMtime(at dbPath: String) -> Double {
        var latest = 0.0
        for suffix in ["", "-wal"] {
            let m = fileMtime(at: dbPath + suffix)
            if m > latest { latest = m }
        }
        return latest
    }

    private func now() -> Double { Date().timeIntervalSinceReferenceDate }

    // Единая точка установки кеша: данные + mtime + ключ + производный индекс.
    private func setCache(_ data: LibraryData, mtime: Double, sourceKey: String) {
        cachedData = data
        cachedMtime = mtime
        cachedSourceKey = sourceKey
        var index = [String: Track](minimumCapacity: data.tracks.count)
        for t in data.tracks { index[t.id] = t }
        cachedTrackIndex = index
    }

    /// O(1)-поиск трека по id из кеша (для обложек). Гарантирует прогрев кеша.
    func track(byID id: String) -> Track? {
        return queue.sync {
            _ = _parse()
            return cachedTrackIndex[id]
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
        COALESCE(c.created_at, ''),
        COALESCE(c.ImagePath, ''),
        COALESCE(c.Commnt, ''),
        COALESCE(c.FileNameL, ''),
        COALESCE(c.StockDate, '')
    FROM djmdContent c
    LEFT JOIN djmdArtist a ON c.ArtistID = a.ID
    LEFT JOIN djmdGenre g  ON c.GenreID = g.ID
    LEFT JOIN djmdLabel l  ON c.LabelID = l.ID
    LEFT JOIN djmdKey k    ON c.KeyID = k.ID
    WHERE c.rb_local_deleted = 0
    """
)

tracks = []
eval_rows = []   # parallel to tracks; fields needed to evaluate smart playlists
track_index = {}
for row in cur.fetchall():
    track_id = str(row[0])
    date_str = str(row[11] or '')[:10] if row[11] else "0000-00-00"
    timestamp = as_timestamp(row[12], row[11])
    bpm = round(float(row[7] or 0) / 100.0, 2) if row[7] else 0.0
    track = {
        "id": track_id,
        "artist": str(row[1] or "Unknown Artist"),
        "title": str(row[2] or "Unknown Title"),
        "genre": str(row[3] or ""),
        "label": str(row[4] or ""),
        "rel_date": str(row[5] or ""),
        "key": str(row[6] or "—"),
        "bpm": bpm,
        "bitrate": int(row[8] or 0),
        "play_count": int(row[9] or 0),
        "location": str(row[10] or ""),
        "timestamp": timestamp,
        "date_str": date_str,
        "image_path": str(row[13] or ""),
        "playlists": [],
        "playlist_indices": {},
    }
    track_index[track_id] = len(tracks)
    tracks.append(track)
    eval_rows.append({
        "artist": str(row[1] or ""),
        "title": str(row[2] or ""),
        "genre": str(row[3] or ""),
        "label": str(row[4] or ""),
        "key": str(row[6] or ""),   # raw Camelot key for matching
        "comments": str(row[14] or ""),
        "fileName": str(row[15] or ""),
        "bpm": bpm,
        "bitrate": int(row[8] or 0),
        "playCount": int(row[9] or 0),
        "year": str(row[5] or ""),
        "dateAdded": timestamp,
        "stockDate": str(row[16] or "")[:10],
    })

cur.execute(
    """
    SELECT ID, Name, ParentID, Attribute, SmartList
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
        "smart_list": str(row[4] or ""),
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

# Smart playlists (Attribute == 4): membership is computed from the SmartList
# filter rules. Operator codes (pyrekordbox): 1 equal, 2 not-equal, 3 greater,
# 4 less, 5 in-range, 6 in-last, 7 not-in-last, 8 contains, 9 not-contains,
# 10 starts-with, 11 ends-with. LogicalOperator: 1 = ALL (AND), 2 = ANY (OR).
import xml.etree.ElementTree as _ET

_TEXT_PROPS = {"artist", "name", "title", "genre", "label", "key", "comments", "fileName"}
_NUM_PROPS = {"bpm", "bitRate", "bitrate", "dj_play_count", "playCount", "year"}
_DATE_PROPS = {"stockDate", "dateReleased", "dateAdded", "dateCreated"}
_PROP_FIELD = {
    "artist": "artist", "name": "title", "title": "title", "genre": "genre",
    "label": "label", "key": "key", "comments": "comments", "fileName": "fileName",
    "bpm": "bpm", "bitRate": "bitrate", "bitrate": "bitrate",
    "dj_play_count": "playCount", "playCount": "playCount", "year": "year",
    "stockDate": "stockDate", "dateReleased": "stockDate",
    "dateAdded": "dateAdded", "dateCreated": "dateAdded",
}

def _parse_date_only(s):
    try:
        return dt.date.fromisoformat(str(s)[:10])
    except Exception:
        return None

def _smart_match(prop, op, vl, vr, unit, row):
    field = _PROP_FIELD.get(prop)
    if field is None:
        return False
    if prop in _TEXT_PROPS:
        s = str(row.get(field, "")).lower()
        v = str(vl or "").lower()
        if op == 1:  return s == v
        if op == 2:  return s != v
        if op == 8:  return v in s
        if op == 9:  return v not in s
        if op == 10: return s.startswith(v)
        if op == 11: return s.endswith(v)
        return False
    if prop in _NUM_PROPS:
        try:
            x = float(row.get(field, 0) or 0)
            a = float(vl or 0)
            b = float(vr or 0)
        except Exception:
            return False
        if op == 1: return x == a
        if op == 2: return x != a
        if op == 3: return x > a
        if op == 4: return x < a
        if op == 5: return a <= x <= b
        return False
    if prop in _DATE_PROPS:
        if field == "dateAdded":
            try:
                d = dt.datetime.fromtimestamp(float(row.get(field, 0) or 0)).date()
            except Exception:
                d = None
        else:
            d = _parse_date_only(row.get(field, ""))
        if d is None:
            return False
        if op == 5:
            a, b = _parse_date_only(vl), _parse_date_only(vr)
            return bool(a and b and a <= d <= b)
        if op in (6, 7):
            try:
                n = int(vl or 0)
            except Exception:
                n = 0
            mult = {"month": 30, "week": 7, "year": 365}.get(unit, 1)
            threshold = dt.date.today() - dt.timedelta(days=n * mult)
            within = d >= threshold
            return within if op == 6 else (not within)
        return False
    return False

smart_paths = set()
for node in playlists.values():
    if node.get("attribute") != 4:
        continue
    smart = node.get("smart_list") or ""
    if not smart:
        continue
    try:
        root = _ET.fromstring(smart)
    except Exception:
        continue
    try:
        logical = int(root.get("LogicalOperator") or "1")
    except Exception:
        logical = 1
    conds = [
        (
            cc.get("PropertyName") or "",
            int(cc.get("Operator") or "0"),
            cc.get("ValueLeft") or "",
            cc.get("ValueRight") or "",
            cc.get("ValueUnit") or "",
        )
        for cc in root.findall("CONDITION")
    ]
    if not conds:
        continue
    ppath = playlist_path(node["id"])
    if not ppath:
        continue
    smart_paths.add(ppath)
    order = 0
    for idx, erow in enumerate(eval_rows):
        results = [_smart_match(p, o, vl, vr, u, erow) for (p, o, vl, vr, u) in conds]
        ok = all(results) if logical == 1 else any(results)
        if not ok:
            continue
        order += 1
        track = tracks[idx]
        track["playlist_indices"][ppath] = order
        if ppath not in track["playlists"]:
            track["playlists"].append(ppath)
        if track["timestamp"] > playlist_latest.get(ppath, 0):
            playlist_latest[ppath] = track["timestamp"]

tracks.sort(key=lambda item: item["timestamp"], reverse=True)
playlists_list = [{"path": path, "date": playlist_latest[path], "smart": path in smart_paths} for path in playlist_latest]

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
