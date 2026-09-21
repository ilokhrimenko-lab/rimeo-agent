import XCTest
@testable import RimeoAgent

/// #81 — XML-источник обязан отдавать папки (включая пустые) с теми же полями
/// дерева, что и master.db-ветка: is_folder / is_smart / parent / seq.
/// До фикса эмитились только Type="1": пустая папка исчезала, у iOS
/// `playlistFolders` был пуст, мобильный веб не видел ничего внутри папок,
/// а порядок зависел от хеш-сида процесса (Dictionary).
final class XMLPlaylistFoldersTests: XCTestCase {

    private static let xml = """
    <?xml version="1.0" encoding="UTF-8"?>
    <DJ_PLAYLISTS Version="1.0.0">
      <PRODUCT Name="rekordbox" Version="6.8.5" Company="AlphaTheta"/>
      <COLLECTION Entries="3">
        <TRACK TrackID="1" Name="One" Artist="A" DateAdded="2026-01-01" Location="file://localhost/Music/1.mp3"/>
        <TRACK TrackID="2" Name="Two" Artist="B" DateAdded="2026-02-01" Location="file://localhost/Music/2.mp3"/>
        <TRACK TrackID="3" Name="Three" Artist="C" DateAdded="2026-03-01" Location="file://localhost/Music/3.mp3"/>
      </COLLECTION>
      <PLAYLISTS>
        <NODE Type="0" Name="ROOT" Count="5">
          <NODE Name="Top PL" Type="1" KeyType="0" Entries="1"><TRACK Key="1"/></NODE>
          <NODE Name="House" Type="0" Count="3">
            <NODE Name="Deep" Type="1" KeyType="0" Entries="2"><TRACK Key="2"/><TRACK Key="1"/></NODE>
            <NODE Name="Sub" Type="0" Count="1">
              <NODE Name="Late" Type="1" KeyType="0" Entries="1"><TRACK Key="3"/></NODE>
            </NODE>
            <NODE Name="Empty PL" Type="1" KeyType="0" Entries="0"/>
          </NODE>
          <NODE Name="Empty Folder" Type="0" Count="0"/>
          <NODE Name="Shell" Type="0" Count="1">
            <NODE Name="Inner Empty" Type="0" Count="0"/>
          </NODE>
          <NODE Name="Aardvark" Type="1" KeyType="0" Entries="0"/>
        </NODE>
      </PLAYLISTS>
    </DJ_PLAYLISTS>
    """

    private func parse() -> LibraryData {
        RekordboxParser.shared.parseXML(Self.xml, mtime: 1)
    }

    func testEveryNodeInDocumentOrder() {
        XCTAssertEqual(parse().playlists.map(\.path), [
            "Top PL", "House", "House / Deep", "House / Sub", "House / Sub / Late",
            "House / Empty PL", "Empty Folder", "Shell", "Shell / Inner Empty", "Aardvark",
        ])
    }

    func testTreeFieldsMatchMasterDBShape() {
        let byPath = Dictionary(uniqueKeysWithValues: parse().playlists.map { ($0.path, $0) })
        let expected: [(String, Bool, String, Int)] = [
            ("Top PL",              false, "root",        1),
            ("House",               true,  "root",        2),
            ("House / Deep",        false, "House",       1),
            ("House / Sub",         true,  "House",       2),
            ("House / Sub / Late",  false, "House / Sub", 1),
            ("House / Empty PL",    false, "House",       3),
            ("Empty Folder",        true,  "root",        3),
            ("Shell",               true,  "root",        4),
            ("Shell / Inner Empty", true,  "Shell",       1),
            ("Aardvark",            false, "root",        5),
        ]
        for (path, folder, parent, seq) in expected {
            guard let p = byPath[path] else { XCTFail("нет \(path)"); continue }
            XCTAssertEqual(p.is_folder, folder, path)
            XCTAssertEqual(p.is_smart, false, path)
            XCTAssertEqual(p.parent, parent, path)
            XCTAssertEqual(p.seq, seq, path)
            // В XML нет ID узлов. Выдуманный rekordbox_id увёл бы мутации/Sync в master.db.
            XCTAssertNil(p.rekordbox_id, path)
        }
    }

    func testMembershipAndFolderDate() {
        let lib = parse()
        let t1 = lib.tracks.first { $0.id == "1" }!
        XCTAssertEqual(Set(t1.playlists), ["Top PL", "House / Deep"])
        XCTAssertEqual(t1.playlist_indices["House / Deep"], 2)
        XCTAssertEqual(lib.tracks.first { $0.id == "3" }?.playlist_indices, ["House / Sub / Late": 1])
        let byPath = Dictionary(uniqueKeysWithValues: lib.playlists.map { ($0.path, $0) })
        XCTAssertEqual(byPath["House"]?.date, 0, "у папки нет своего состава — как у master.db")
        XCTAssertGreaterThan(byPath["House / Deep"]?.date ?? 0, 0)
    }

    func testDeterministic() {
        XCTAssertEqual(parse().playlists.map(\.path), parse().playlists.map(\.path))
    }
}
