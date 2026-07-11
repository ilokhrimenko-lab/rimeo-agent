import Foundation
import SQLCipher

private let rekordboxDBKey = "402fd482c38817c35ffa8ffb8c7d93143b749e7d315df7a81732a1ff43608497"

struct HelperTrack: Codable {
    let id: String
    let artist: String
    let title: String
    let genre: String
    let label: String
    let rel_date: String
    let key: String
    let bpm: Double
    let duration: Double?
    let bitrate: Int
    let play_count: Int
    let location: String
    let timestamp: Double
    let date_str: String
    let image_path: String
    var playlists: [String]
    var playlist_indices: [String: Int]
    var histories: [String] = []
    var history_indices: [String: Int] = [:]
}

struct HelperPlaylist: Codable {
    let path: String
    let date: Double
    let smart: Bool
    var history: Bool? = nil
    var history_id: String? = nil
    var name: String? = nil
    // Identity + tree (Фаза 0). Emitted for every djmdPlaylist node so the client
    // can address playlists by rekordbox_id and render folders / empty playlists.
    var rekordbox_id: String? = nil   // djmdPlaylist.ID
    var parent: String? = nil         // djmdPlaylist.ParentID ("root" at top level)
    var is_folder: Bool? = nil        // Attribute == 1
    var is_smart: Bool? = nil         // Attribute == 4
}

struct HelperLibraryData: Codable {
    let tracks: [HelperTrack]
    let playlists: [HelperPlaylist]
    let xml_date: Double
    let source: String?
}

struct PlaylistNode {
    let id: String
    let name: String
    let parent: String
    let attribute: Int
    let smartList: String
}

// Fields needed to evaluate Rekordbox smart-playlist conditions, kept parallel to
// `tracks` (same index, populated in the same pass before sorting).
struct SmartEvalRow {
    let artist: String
    let title: String
    let genre: String
    let label: String
    let key: String
    let comments: String
    let fileName: String
    let bpm: Double
    let bitrate: Int
    let playCount: Int
    let year: String
    let dateAdded: Double   // epoch seconds (DateCreated/created_at)
    let stockDate: String   // "YYYY-MM-DD"
}

struct SmartCondition {
    let property: String
    let op: Int
    let valueLeft: String
    let valueRight: String
    let unit: String
}

enum HelperError: LocalizedError {
    case usage
    case openFailed(String)
    case keyFailed(String)
    case prepareFailed(String)
    case stepFailed(String)

    var errorDescription: String? {
        switch self {
        case .usage:
            return "usage: rbdb-helper <master.db path> <mtime> [output.json]"
        case .openFailed(let msg):
            return "open failed: \(msg)"
        case .keyFailed(let msg):
            return "key failed: \(msg)"
        case .prepareFailed(let msg):
            return "prepare failed: \(msg)"
        case .stepFailed(let msg):
            return "query failed: \(msg)"
        }
    }
}

final class DatabaseHandle {
    let raw: OpaquePointer

    init(path: String) throws {
        var db: OpaquePointer?
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX | SQLITE_OPEN_URI
        let rc = sqlite3_open_v2("file:\(path)?mode=ro", &db, flags, nil)
        guard rc == SQLITE_OK, let db else {
            let msg = db.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "unknown error"
            if let db { sqlite3_close(db) }
            throw HelperError.openFailed(msg)
        }
        raw = db
        sqlite3_extended_result_codes(db, 1)
        sqlite3_busy_timeout(db, 3_000)
    }

    deinit {
        sqlite3_close(raw)
    }

    func applyKey() throws {
        let keyBytes = Array(rekordboxDBKey.utf8)
        let rc = keyBytes.withUnsafeBytes { bytes in
            sqlite3_key(raw, bytes.baseAddress, Int32(bytes.count))
        }
        guard rc == SQLITE_OK else {
            throw HelperError.keyFailed(String(cString: sqlite3_errmsg(raw)))
        }

        // Force key validation early so failures are reported clearly.
        try executeScalar("SELECT count(*) FROM sqlite_master")
    }

    func executeScalar(_ sql: String) throws {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(raw, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw HelperError.prepareFailed(String(cString: sqlite3_errmsg(raw)))
        }
        defer { sqlite3_finalize(stmt) }

        let rc = sqlite3_step(stmt)
        guard rc == SQLITE_ROW || rc == SQLITE_DONE else {
            throw HelperError.stepFailed(String(cString: sqlite3_errmsg(raw)))
        }
    }

    func prepare(_ sql: String) throws -> OpaquePointer {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(raw, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw HelperError.prepareFailed(String(cString: sqlite3_errmsg(raw)))
        }
        return stmt
    }
}

func columnText(_ stmt: OpaquePointer, _ index: Int32) -> String {
    guard let ptr = sqlite3_column_text(stmt, index) else { return "" }
    return String(cString: ptr)
}

func columnInt(_ stmt: OpaquePointer, _ index: Int32) -> Int {
    Int(sqlite3_column_int64(stmt, index))
}

func columnDouble(_ stmt: OpaquePointer, _ index: Int32) -> Double {
    sqlite3_column_double(stmt, index)
}

// Rekordbox 6 djmdContent.created_at is "2026-05-15 10:23:45.123 +00:00"
// (space separator, fractional seconds, optional offset) — ISO8601DateFormatter
// rejects it, unlike Python's lenient datetime.fromisoformat used by the old
// prototype. Without tolerant parsing, freshly added tracks get timestamp 0 and
// sink below the client's date-sorted visible window.
private let rekordboxDateFormats = [
    "yyyy-MM-dd HH:mm:ss.SSSSSS xxxxx",
    "yyyy-MM-dd HH:mm:ss.SSS xxxxx",
    "yyyy-MM-dd HH:mm:ss xxxxx",
    "yyyy-MM-dd HH:mm:ss.SSSSSS",
    "yyyy-MM-dd HH:mm:ss.SSS",
    "yyyy-MM-dd HH:mm:ss",
    "yyyy-MM-dd'T'HH:mm:ss.SSSSSS",
    "yyyy-MM-dd'T'HH:mm:ss",
    "yyyy-MM-dd",
]

private func parseRekordboxDate(_ raw: String) -> Double? {
    let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !s.isEmpty else { return nil }

    let isoFrac = ISO8601DateFormatter()
    isoFrac.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let d = isoFrac.date(from: s) { return d.timeIntervalSince1970 }
    let iso = ISO8601DateFormatter()
    if let d = iso.date(from: s) { return d.timeIntervalSince1970 }

    let fmt = DateFormatter()
    fmt.locale = Locale(identifier: "en_US_POSIX")
    fmt.timeZone = TimeZone(identifier: "UTC")
    for pattern in rekordboxDateFormats {
        fmt.dateFormat = pattern
        if let d = fmt.date(from: s) { return d.timeIntervalSince1970 }
    }
    return nil
}

func asTimestamp(_ createdAt: String, _ fallbackDate: String) -> Double {
    if let ts = parseRekordboxDate(createdAt) { return ts }
    if let ts = parseRekordboxDate(fallbackDate) { return ts }
    return 0
}

func playlistPath(for playlistID: String, playlists: [String: PlaylistNode]) -> String {
    var parts: [String] = []
    var seen = Set<String>()
    var current = playlistID

    while !current.isEmpty && current != "root" && !seen.contains(current) {
        seen.insert(current)
        guard let item = playlists[current] else { break }
        parts.append(item.name)
        current = item.parent
    }

    return parts.reversed().filter { !$0.isEmpty }.joined(separator: " / ")
}

// MARK: - Smart playlist evaluation
//
// Rekordbox stores smart playlists as `djmdPlaylist.Attribute == 4` with a
// `SmartList` XML column describing filter rules. Unlike regular playlists, their
// membership is NOT in djmdSongPlaylist — it must be computed from the rules.
// Operator codes (match pyrekordbox): 1 equal, 2 not-equal, 3 greater, 4 less,
// 5 in-range, 6 in-last, 7 not-in-last, 8 contains, 9 not-contains,
// 10 starts-with, 11 ends-with. LogicalOperator: 1 = ALL (AND), 2 = ANY (OR).

private let smartDateOnlyFormatter: DateFormatter = {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.timeZone = TimeZone(identifier: "UTC")
    f.dateFormat = "yyyy-MM-dd"
    return f
}()

private func smartParseDateOnly(_ s: String) -> Date? {
    let trimmed = String(s.prefix(10))
    guard trimmed.count == 10 else { return nil }
    return smartDateOnlyFormatter.date(from: trimmed)
}

func parseSmartConditions(_ xml: String) -> (logical: Int, conditions: [SmartCondition])? {
    guard let data = xml.data(using: .utf8),
          let doc = try? XMLDocument(data: data, options: []),
          let root = doc.rootElement() else { return nil }
    let logical = Int(root.attribute(forName: "LogicalOperator")?.stringValue ?? "1") ?? 1
    var conds: [SmartCondition] = []
    for node in root.elements(forName: "CONDITION") {
        conds.append(SmartCondition(
            property: node.attribute(forName: "PropertyName")?.stringValue ?? "",
            op: Int(node.attribute(forName: "Operator")?.stringValue ?? "0") ?? 0,
            valueLeft: node.attribute(forName: "ValueLeft")?.stringValue ?? "",
            valueRight: node.attribute(forName: "ValueRight")?.stringValue ?? "",
            unit: node.attribute(forName: "ValueUnit")?.stringValue ?? ""
        ))
    }
    return conds.isEmpty ? nil : (logical, conds)
}

private enum SmartFieldValue {
    case text(String)
    case number(Double)
    case date(Date?)
}

private func smartFieldValue(_ property: String, _ row: SmartEvalRow) -> SmartFieldValue? {
    switch property {
    case "artist":                 return .text(row.artist)
    case "name", "title":          return .text(row.title)
    case "genre":                  return .text(row.genre)
    case "label":                  return .text(row.label)
    case "key":                    return .text(row.key)
    case "comments":               return .text(row.comments)
    case "fileName":               return .text(row.fileName)
    case "bpm":                    return .number(row.bpm)
    case "bitRate", "bitrate":     return .number(Double(row.bitrate))
    case "dj_play_count", "playCount": return .number(Double(row.playCount))
    case "year":                   return .number(Double(row.year) ?? 0)
    case "stockDate", "dateReleased": return .date(smartParseDateOnly(row.stockDate))
    case "dateAdded", "dateCreated":  return .date(Date(timeIntervalSince1970: row.dateAdded))
    default:                       return nil
    }
}

private func smartEvalText(_ op: Int, _ field: String, _ vl: String) -> Bool {
    let s = field.lowercased(); let v = vl.lowercased()
    switch op {
    case 1:  return s == v
    case 2:  return s != v
    case 8:  return s.contains(v)
    case 9:  return !s.contains(v)
    case 10: return s.hasPrefix(v)
    case 11: return s.hasSuffix(v)
    default: return false
    }
}

private func smartEvalNumber(_ op: Int, _ x: Double, _ vl: String, _ vr: String) -> Bool {
    let a = Double(vl) ?? 0; let b = Double(vr) ?? 0
    switch op {
    case 1:  return x == a
    case 2:  return x != a
    case 3:  return x > a
    case 4:  return x < a
    case 5:  return x >= a && x <= b
    default: return false
    }
}

private func smartEvalDate(_ op: Int, _ d: Date?, _ vl: String, _ vr: String, _ unit: String) -> Bool {
    guard let d = d else { return false }
    switch op {
    case 5:
        guard let a = smartParseDateOnly(vl), let b = smartParseDateOnly(vr) else { return false }
        return d >= a && d <= b
    case 6, 7:
        let n = Int(vl) ?? 0
        let comp: Calendar.Component
        switch unit {
        case "month": comp = .month
        case "week":  comp = .weekOfYear
        case "year":  comp = .year
        default:      comp = .day
        }
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC") ?? .current
        guard let threshold = cal.date(byAdding: comp, value: -n, to: Date()) else { return false }
        let within = d >= threshold
        return op == 6 ? within : !within
    default:
        return false
    }
}

private func smartEvalCondition(_ cond: SmartCondition, _ row: SmartEvalRow) -> Bool {
    guard let fv = smartFieldValue(cond.property, row) else { return false }
    switch fv {
    case .text(let s):   return smartEvalText(cond.op, s, cond.valueLeft)
    case .number(let x): return smartEvalNumber(cond.op, x, cond.valueLeft, cond.valueRight)
    case .date(let d):   return smartEvalDate(cond.op, d, cond.valueLeft, cond.valueRight, cond.unit)
    }
}

func smartRowMatches(_ row: SmartEvalRow, logical: Int, conditions: [SmartCondition]) -> Bool {
    if conditions.isEmpty { return false }
    if logical == 2 {
        return conditions.contains { smartEvalCondition($0, row) }
    }
    return conditions.allSatisfy { smartEvalCondition($0, row) }
}

func parseMasterDB(dbPath: String, mtime: Double) throws -> HelperLibraryData {
    let db = try DatabaseHandle(path: dbPath)
    try db.applyKey()

    let tracksSQL = """
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
        COALESCE(c.StockDate, ''),
        COALESCE(c.Length, 0)
    FROM djmdContent c
    LEFT JOIN djmdArtist a ON c.ArtistID = a.ID
    LEFT JOIN djmdGenre g  ON c.GenreID = g.ID
    LEFT JOIN djmdLabel l  ON c.LabelID = l.ID
    LEFT JOIN djmdKey k    ON c.KeyID = k.ID
    WHERE c.rb_local_deleted = 0
    """

    let tracksStmt = try db.prepare(tracksSQL)
    defer { sqlite3_finalize(tracksStmt) }

    var tracks: [HelperTrack] = []
    var trackIndex: [String: Int] = [:]
    var evalRows: [SmartEvalRow] = []   // parallel to `tracks`, used for smart playlists

    while true {
        let rc = sqlite3_step(tracksStmt)
        if rc == SQLITE_DONE { break }
        guard rc == SQLITE_ROW else {
            throw HelperError.stepFailed(String(cString: sqlite3_errmsg(db.raw)))
        }

        let id = columnText(tracksStmt, 0)
        let fallbackDate = columnText(tracksStmt, 11)
        let createdAt = columnText(tracksStmt, 12)
        let timestamp = asTimestamp(createdAt, fallbackDate)
        let dateString = fallbackDate.isEmpty ? "0000-00-00" : String(fallbackDate.prefix(10))
        let bpmRaw = columnDouble(tracksStmt, 7)
        let bpm = bpmRaw == 0 ? 0 : (bpmRaw / 100.0)
        let artist = columnText(tracksStmt, 1).isEmpty ? "Unknown Artist" : columnText(tracksStmt, 1)
        let title = columnText(tracksStmt, 2).isEmpty ? "Unknown Title" : columnText(tracksStmt, 2)
        let genre = columnText(tracksStmt, 3)
        let label = columnText(tracksStmt, 4)
        let relDate = columnText(tracksStmt, 5)
        let key = columnText(tracksStmt, 6).isEmpty ? "—" : columnText(tracksStmt, 6)
        let bitrate = columnInt(tracksStmt, 8)
        let playCount = columnInt(tracksStmt, 9)
        let lengthSec = columnDouble(tracksStmt, 17)

        trackIndex[id] = tracks.count
        tracks.append(
            HelperTrack(
                id: id,
                artist: artist,
                title: title,
                genre: genre,
                label: label,
                rel_date: relDate,
                key: key,
                bpm: bpm,
                duration: lengthSec > 0 ? lengthSec : nil,
                bitrate: bitrate,
                play_count: playCount,
                location: columnText(tracksStmt, 10),
                timestamp: timestamp,
                date_str: dateString,
                image_path: columnText(tracksStmt, 13),
                playlists: [],
                playlist_indices: [:]
            )
        )
        evalRows.append(
            SmartEvalRow(
                artist: artist,
                title: title,
                genre: genre,
                label: label,
                key: columnText(tracksStmt, 6),   // raw key (Camelot) for matching
                comments: columnText(tracksStmt, 14),
                fileName: columnText(tracksStmt, 15),
                bpm: bpm,
                bitrate: bitrate,
                playCount: playCount,
                year: relDate,
                dateAdded: timestamp,
                stockDate: columnText(tracksStmt, 16)
            )
        )
    }

    let playlistsStmt = try db.prepare(
        """
        SELECT ID, Name, ParentID, COALESCE(Attribute, 0), COALESCE(SmartList, '')
        FROM djmdPlaylist
        WHERE rb_local_deleted = 0
        """
    )
    defer { sqlite3_finalize(playlistsStmt) }

    var playlistsByID: [String: PlaylistNode] = [:]
    while true {
        let rc = sqlite3_step(playlistsStmt)
        if rc == SQLITE_DONE { break }
        guard rc == SQLITE_ROW else {
            throw HelperError.stepFailed(String(cString: sqlite3_errmsg(db.raw)))
        }

        let id = columnText(playlistsStmt, 0)
        playlistsByID[id] = PlaylistNode(
            id: id,
            name: columnText(playlistsStmt, 1),
            parent: columnText(playlistsStmt, 2),
            attribute: columnInt(playlistsStmt, 3),
            smartList: columnText(playlistsStmt, 4)
        )
    }

    let membershipStmt = try db.prepare(
        """
        SELECT PlaylistID, ContentID, TrackNo
        FROM djmdSongPlaylist
        WHERE rb_local_deleted = 0
        """
    )
    defer { sqlite3_finalize(membershipStmt) }

    var playlistLatest: [String: Double] = [:]

    while true {
        let rc = sqlite3_step(membershipStmt)
        if rc == SQLITE_DONE { break }
        guard rc == SQLITE_ROW else {
            throw HelperError.stepFailed(String(cString: sqlite3_errmsg(db.raw)))
        }

        let playlistID = columnText(membershipStmt, 0)
        let trackID = columnText(membershipStmt, 1)
        let trackNo = columnInt(membershipStmt, 2)

        guard let idx = trackIndex[trackID] else { continue }
        let path = playlistPath(for: playlistID, playlists: playlistsByID)
        guard !path.isEmpty else { continue }

        tracks[idx].playlist_indices[path] = trackNo
        if !tracks[idx].playlists.contains(path) {
            tracks[idx].playlists.append(path)
        }

        if tracks[idx].timestamp > (playlistLatest[path] ?? 0) {
            playlistLatest[path] = tracks[idx].timestamp
        }
    }

    // Smart playlists (Attribute == 4): membership is computed from the SmartList
    // filter rules rather than read from djmdSongPlaylist.
    var smartPaths = Set<String>()
    for node in playlistsByID.values where node.attribute == 4 {
        guard !node.smartList.isEmpty,
              let parsed = parseSmartConditions(node.smartList) else { continue }
        let path = playlistPath(for: node.id, playlists: playlistsByID)
        guard !path.isEmpty else { continue }
        smartPaths.insert(path)

        var order = 0
        for idx in tracks.indices
        where smartRowMatches(evalRows[idx], logical: parsed.logical, conditions: parsed.conditions) {
            order += 1
            tracks[idx].playlist_indices[path] = order
            if !tracks[idx].playlists.contains(path) {
                tracks[idx].playlists.append(path)
            }
            if tracks[idx].timestamp > (playlistLatest[path] ?? 0) {
                playlistLatest[path] = tracks[idx].timestamp
            }
        }
    }

    // Play histories (djmdHistory + djmdSongHistory). Stored separate from
    // playlists: membership lands in track.histories (not track.playlists) and the
    // session is emitted as a Playlist with history=true. Wrapped in do/catch so
    // older Rekordbox DBs without these tables just yield no histories.
    var historyPlaylists: [HelperPlaylist] = []
    do {
        struct HistMeta { let name: String; let date: Double }
        var histMeta: [String: HistMeta] = [:]

        let histStmt = try db.prepare(
            """
            SELECT ID, COALESCE(Name, ''), COALESCE(DateCreated, ''), COALESCE(created_at, '')
            FROM djmdHistory
            WHERE rb_local_deleted = 0 AND COALESCE(Attribute, 0) = 0
            """
        )
        defer { sqlite3_finalize(histStmt) }
        while true {
            let rc = sqlite3_step(histStmt)
            if rc == SQLITE_DONE { break }
            guard rc == SQLITE_ROW else { break }
            let id = columnText(histStmt, 0)
            guard !id.isEmpty else { continue }
            let name = columnText(histStmt, 1)
            let date = asTimestamp(columnText(histStmt, 3), columnText(histStmt, 2))
            histMeta[id] = HistMeta(name: name.isEmpty ? "History \(id)" : name, date: date)
        }

        let songStmt = try db.prepare(
            """
            SELECT HistoryID, ContentID, TrackNo
            FROM djmdSongHistory
            WHERE rb_local_deleted = 0
            """
        )
        defer { sqlite3_finalize(songStmt) }
        while true {
            let rc = sqlite3_step(songStmt)
            if rc == SQLITE_DONE { break }
            guard rc == SQLITE_ROW else { break }
            let histID = columnText(songStmt, 0)
            let trackID = columnText(songStmt, 1)
            let trackNo = columnInt(songStmt, 2)
            guard histMeta[histID] != nil, let idx = trackIndex[trackID] else { continue }
            let key = "hist:\(histID)"
            tracks[idx].history_indices[key] = trackNo
            if !tracks[idx].histories.contains(key) {
                tracks[idx].histories.append(key)
            }
        }

        historyPlaylists = histMeta.map { id, meta in
            HelperPlaylist(path: "hist:\(id)", date: meta.date, smart: false,
                           history: true, history_id: id, name: meta.name)
        }
    } catch {
        historyPlaylists = []
    }

    tracks.sort { $0.timestamp > $1.timestamp }

    // Emit EVERY djmdPlaylist node — folders (Attribute==1), empty playlists and
    // smart playlists included, not just those with tracks — so the client gets the
    // full tree and a stable rekordbox_id per node (finding-6). Same-name playlists
    // in one folder collapse to one display path; log the collision (mutations
    // still address by rekordbox_id, so membership does not merge). (finding-5)
    var emittedPaths = Set<String>()
    var regularPlaylists: [HelperPlaylist] = []
    for node in playlistsByID.values {
        let path = playlistPath(for: node.id, playlists: playlistsByID)
        guard !path.isEmpty else { continue }
        if emittedPaths.contains(path) {
            FileHandle.standardError.write(Data("rbdb-helper: playlist path collision: \(path)\n".utf8))
        }
        emittedPaths.insert(path)
        regularPlaylists.append(HelperPlaylist(
            path: path,
            date: playlistLatest[path] ?? 0,
            smart: smartPaths.contains(path),
            rekordbox_id: node.id,
            parent: node.parent.isEmpty ? "root" : node.parent,
            is_folder: node.attribute == 1,
            is_smart: node.attribute == 4
        ))
    }
    let playlists = regularPlaylists.sorted { $0.path < $1.path } + historyPlaylists

    return HelperLibraryData(
        tracks: tracks,
        playlists: playlists,
        xml_date: mtime,
        source: "db"
    )
}

@main
struct RekordboxDBHelperMain {
    static func main() {
        do {
            guard CommandLine.arguments.count >= 3 else {
                throw HelperError.usage
            }

            let dbPath = CommandLine.arguments[1]
            let mtime = Double(CommandLine.arguments[2]) ?? 0
            let result = try parseMasterDB(dbPath: dbPath, mtime: mtime)

            let encoder = JSONEncoder()
            encoder.outputFormatting = []
            let data = try encoder.encode(result)
            if CommandLine.arguments.count >= 4 {
                let outPath = CommandLine.arguments[3]
                try data.write(to: URL(fileURLWithPath: outPath), options: .atomic)
            } else {
                FileHandle.standardOutput.write(data)
            }
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
            FileHandle.standardError.write(Data(message.utf8))
            exit(1)
        }
    }
}
