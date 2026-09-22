import XCTest
@testable import RimeoAgent

/// Кеш разрешённых корней path-guard (#8). Раньше ключ был «число треков | первый |
/// последний путь»: трек переехал в другую папку (Relocate в Rekordbox), а эти три
/// значения не изменились → кеш не пересобирался, агент сам отдавал новый путь в
/// /api/data и сам же отвечал на него 403.
final class PathGuardRootsTests: XCTestCase {
    private func track(_ id: String, _ loc: String) -> Track {
        Track(id: id, artist: "", title: id, genre: "", label: "", rel_date: "", key: "", bpm: 0,
              duration: nil, bitrate: 320, play_count: 0, location: loc, timestamp: 0, date_str: "",
              image_path: nil, playlists: [], playlist_indices: [:])
    }
    private func lib(_ tracks: [Track], mtime: Double) -> LibraryData {
        LibraryData(tracks: tracks, playlists: [], xml_date: mtime, source: "db")
    }

    func test_relocatedMiddleTrack_changesSignature_andRoots() {
        let before = lib([track("1", "/m/a/1.mp3"), track("2", "/m/old/2.mp3"), track("3", "/m/a/3.mp3")], mtime: 100)
        let after  = lib([track("1", "/m/a/1.mp3"), track("2", "/m/new/2.mp3"), track("3", "/m/a/3.mp3")], mtime: 200)
        // Старый ключ (число | первый | последний) у этих библиотек совпадал бы.
        XCTAssertEqual(before.tracks.count, after.tracks.count)
        XCTAssertEqual(before.tracks.first?.location, after.tracks.first?.location)
        XCTAssertEqual(before.tracks.last?.location, after.tracks.last?.location)
        XCTAssertNotEqual(LibraryPathGuard.rootsSignature(before), LibraryPathGuard.rootsSignature(after),
                          "переразбор библиотеки (новый mtime) обязан менять ключ кеша корней")
        let roots = LibraryPathGuard.allowedRoots(tracks: after.tracks)
        XCTAssertTrue(roots.contains("/m/new"), "новая папка трека должна стать разрешённой")
        XCTAssertFalse(roots.contains("/m/old"), "старая папка после переезда больше не разрешена")
    }

    func test_sameSnapshot_sameSignature() {
        let a = lib([track("1", "/m/a/1.mp3")], mtime: 100)
        XCTAssertEqual(LibraryPathGuard.rootsSignature(a), LibraryPathGuard.rootsSignature(a),
                       "попадание в кеш на горячем /stream не должно менять ключ")
    }

    func test_sourceSwitch_changesSignature() {
        let db  = LibraryData(tracks: [track("1", "/m/a/1.mp3")], playlists: [], xml_date: 100, source: "db")
        let xml = LibraryData(tracks: [track("1", "/m/a/1.mp3")], playlists: [], xml_date: 100, source: "xml")
        XCTAssertNotEqual(LibraryPathGuard.rootsSignature(db), LibraryPathGuard.rootsSignature(xml))
    }
}
