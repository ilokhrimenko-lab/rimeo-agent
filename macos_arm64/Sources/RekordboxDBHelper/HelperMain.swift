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
    let bitrate: Int
    let play_count: Int
    let location: String
    let timestamp: Double
    let date_str: String
    var playlists: [String]
    var playlist_indices: [String: Int]
}

struct HelperPlaylist: Codable {
    let path: String
    let date: Double
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

func asTimestamp(_ createdAt: String, _ fallbackDate: String) -> Double {
    let iso = ISO8601DateFormatter()
    if !createdAt.isEmpty, let d = iso.date(from: createdAt) {
        return d.timeIntervalSince1970
    }

    if !fallbackDate.isEmpty {
        if let d = iso.date(from: fallbackDate) {
            return d.timeIntervalSince1970
        }
        let prefix = String(fallbackDate.prefix(10))
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        fmt.locale = Locale(identifier: "en_US_POSIX")
        if let d = fmt.date(from: prefix) {
            return d.timeIntervalSince1970
        }
    }
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
        COALESCE(c.created_at, '')
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

        trackIndex[id] = tracks.count
        tracks.append(
            HelperTrack(
                id: id,
                artist: columnText(tracksStmt, 1).isEmpty ? "Unknown Artist" : columnText(tracksStmt, 1),
                title: columnText(tracksStmt, 2).isEmpty ? "Unknown Title" : columnText(tracksStmt, 2),
                genre: columnText(tracksStmt, 3),
                label: columnText(tracksStmt, 4),
                rel_date: columnText(tracksStmt, 5),
                key: columnText(tracksStmt, 6).isEmpty ? "—" : columnText(tracksStmt, 6),
                bpm: bpmRaw == 0 ? 0 : (bpmRaw / 100.0),
                bitrate: columnInt(tracksStmt, 8),
                play_count: columnInt(tracksStmt, 9),
                location: columnText(tracksStmt, 10),
                timestamp: timestamp,
                date_str: dateString,
                playlists: [],
                playlist_indices: [:]
            )
        )
    }

    let playlistsStmt = try db.prepare(
        """
        SELECT ID, Name, ParentID
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
            parent: columnText(playlistsStmt, 2)
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

    tracks.sort { $0.timestamp > $1.timestamp }

    let playlists = playlistLatest.keys.sorted().map {
        HelperPlaylist(path: $0, date: playlistLatest[$0] ?? 0)
    }

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
