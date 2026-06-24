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
    // Rekordbox play-history session. `history_id` is the stable djmdHistory.ID
    // (rename key); `name` is the display name (rename override applied). For
    // regular playlists these are nil and the client derives the name from `path`.
    var history:     Bool?
    var history_id:  String?
    var name:        String?

    static func == (lhs: Playlist, rhs: Playlist) -> Bool { lhs.path == rhs.path }
}

struct LibraryData: Codable {
    let tracks:    [Track]
    let playlists: [Playlist]
    let xml_date:  Double
    let source:    String?
}
