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
    let bitrate:          Int
    let play_count:       Int
    let location:         String
    let timestamp:        Double
    let date_str:         String
    var playlists:        [String]
    var playlist_indices: [String: Int]

    static func == (lhs: Track, rhs: Track) -> Bool { lhs.id == rhs.id }
}

struct Playlist: Codable, Identifiable, Equatable {
    var id: String { path }
    let path: String
    let date: Double

    static func == (lhs: Playlist, rhs: Playlist) -> Bool { lhs.path == rhs.path }
}

struct LibraryData: Codable {
    let tracks:    [Track]
    let playlists: [Playlist]
    let xml_date:  Double
    let source:    String?
}
