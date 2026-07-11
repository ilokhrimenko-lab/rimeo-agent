import Foundation

struct Track: Codable, Identifiable, Equatable {
    let id:               String
    let artist:           String
    let title:            String
    let genre:            String
    let label:            String
    let rel_date:         String
    let key:              String
    let bpm:              Double
    var duration:         Double?   // track length in seconds (Rekordbox TotalTime)
    let bitrate:          Int
    let play_count:       Int
    let location:         String
    let timestamp:        Double
    let date_str:         String
    var image_path:       String?
    var playlists:        [String]
    var playlist_indices: [String: Int]
    // Rekordbox play-history membership — kept separate from `playlists` so the
    // playlist-count badge / popup stay clean (a track played in N sessions must
    // not read as "in N playlists"). Paths use the "hist:<id>" namespace.
    var histories:        [String]      = []
    var history_indices:  [String: Int] = [:]

    static func == (lhs: Track, rhs: Track) -> Bool { lhs.id == rhs.id }
}

struct Playlist: Codable, Identifiable, Equatable {
    var id: String { path }
    let path: String
    let date: Double
    let smart: Bool?
    /// Дата последнего изменения плейлиста (djmdPlaylist.updated_at). Опционально —
    /// парсер отдаёт её только когда колонка доступна; иначе nil (клиент падает на `date`).
    var updated: Double? = nil
    // Rekordbox play-history session. `history_id` is the stable djmdHistory.ID
    // (rename key); `name` is the display name (rename override applied). For
    // regular playlists these are nil and the client derives the name from `path`.
    var history:     Bool?
    var history_id:  String?
    var name:        String?
    // Playlist identity + tree (Фаза 0 — плейлисты из iOS). The parser now emits a
    // node for EVERY djmdPlaylist (folders, empty, smart), so overlay mutations can
    // address a playlist strictly by `rekordbox_id` (path is display-only and can
    // collide between same-named playlists). All optional so older helper output /
    // disk caches that predate these keys still decode.
    var rekordbox_id: String?   // djmdPlaylist.ID
    var parent:       String?   // djmdPlaylist.ParentID ("root" at top level)
    var is_folder:    Bool?     // Attribute == 1
    var is_smart:     Bool?     // Attribute == 4

    static func == (lhs: Playlist, rhs: Playlist) -> Bool { lhs.path == rhs.path }
}

struct LibraryData: Codable {
    let tracks:    [Track]
    let playlists: [Playlist]
    let xml_date:  Double
    let source:    String?
}
