import XCTest
@testable import RimeoAgent

/// Таблица всех 24 ключей в трёх нотациях (Camelot / классика Rekordbox / энгармоника)
/// → ожидаемый канонический Camelot. Раньше parseCamelot понимал только Camelot, из-за
/// чего ~47% библиотеки (классика "Am", "Fm", "C#m") давали key_relation == .unknown.
/// Run: `swift test --filter KeyNormalizerTests`.
final class KeyNormalizerTests: XCTestCase {

    /// (ожидаемый Camelot, [все допустимые написания])
    private let table: [(String, [String])] = [
        // Минор (A-сторона)
        ("1A",  ["1A",  "1a",  "Abm", "G#m", "abm",  "g#m"]),
        ("2A",  ["2A",  "2a",  "Ebm", "D#m", "ebm",  "d#m"]),
        ("3A",  ["3A",  "3a",  "Bbm", "A#m", "bbm",  "a#m"]),
        ("4A",  ["4A",  "4a",  "Fm",  "E#m", "fm"]),
        ("5A",  ["5A",  "5a",  "Cm",  "B#m", "cm"]),
        ("6A",  ["6A",  "6a",  "Gm",  "gm"]),
        ("7A",  ["7A",  "7a",  "Dm",  "dm"]),
        ("8A",  ["8A",  "8a",  "Am",  "am"]),
        ("9A",  ["9A",  "9a",  "Em",  "Fbm", "em"]),
        ("10A", ["10A", "10a", "Bm",  "Cbm", "bm"]),
        ("11A", ["11A", "11a", "F#m", "Gbm", "f#m", "gbm"]),
        ("12A", ["12A", "12a", "C#m", "Dbm", "c#m", "dbm"]),
        // Мажор (B-сторона)
        ("1B",  ["1B",  "1b",  "B",   "Cb",  "b"]),
        ("2B",  ["2B",  "2b",  "F#",  "Gb",  "f#",  "gb"]),
        ("3B",  ["3B",  "3b",  "Db",  "C#",  "db",  "c#"]),
        ("4B",  ["4B",  "4b",  "Ab",  "G#",  "ab",  "g#"]),
        ("5B",  ["5B",  "5b",  "Eb",  "D#",  "eb",  "d#"]),
        ("6B",  ["6B",  "6b",  "Bb",  "A#",  "bb",  "a#"]),
        ("7B",  ["7B",  "7b",  "F",   "E#",  "f"]),
        ("8B",  ["8B",  "8b",  "C",   "B#",  "c"]),
        ("9B",  ["9B",  "9b",  "G",   "g"]),
        ("10B", ["10B", "10b", "D",   "d"]),
        ("11B", ["11B", "11b", "A",   "a"]),
        ("12B", ["12B", "12b", "E",   "Fb",  "e"]),
    ]

    func test_allTwentyFourKeys_inEveryNotation() {
        for (expected, spellings) in table {
            for raw in spellings {
                XCTAssertEqual(KeyNormalizer.camelot(raw), expected,
                               "\(raw) должен нормализоваться в \(expected)")
            }
        }
        XCTAssertEqual(table.count, 24)
    }

    /// Энгармоника — главный источник промахов: C#m и Dbm это одна и та же нота.
    func test_enharmonics_collapse() {
        XCTAssertEqual(KeyNormalizer.camelot("C#m"), KeyNormalizer.camelot("Dbm"))
        XCTAssertEqual(KeyNormalizer.camelot("F#m"), KeyNormalizer.camelot("Gbm"))
        XCTAssertEqual(KeyNormalizer.camelot("Abm"), KeyNormalizer.camelot("G#m"))
        XCTAssertEqual(KeyNormalizer.camelot("Db"),  KeyNormalizer.camelot("C#"))
    }

    /// Пробелы, юникодные ♯/♭ и словесные суффиксы — из тегов Mixed In Key.
    func test_tolerantSpellings() {
        XCTAssertEqual(KeyNormalizer.camelot(" Am "),     "8A")
        XCTAssertEqual(KeyNormalizer.camelot("A minor"),  "8A")
        XCTAssertEqual(KeyNormalizer.camelot("Amin"),     "8A")
        XCTAssertEqual(KeyNormalizer.camelot("C major"),  "8B")
        XCTAssertEqual(KeyNormalizer.camelot("Cmaj"),     "8B")
        XCTAssertEqual(KeyNormalizer.camelot("F♯m"),      "11A")
        XCTAssertEqual(KeyNormalizer.camelot("E♭m"),      "2A")
        XCTAssertEqual(KeyNormalizer.camelot(" 9a "),     "9A")
    }

    func test_garbage_returnsNil() {
        for raw in ["", "  ", "—", "-", "10m", "13A", "0A", "9C", "H", "Hm", "Amx",
                    "unknown", "None", "1", "A#x", "12", "AB C"] {
            XCTAssertNil(KeyNormalizer.camelot(raw), "\(raw) не должен парситься")
        }
    }

    /// Обратный путь: Camelot → классика (написание как в Rekordbox).
    func test_classicRoundTrip() {
        XCTAssertEqual(KeyNormalizer.classic("12A"), "C#m")
        XCTAssertEqual(KeyNormalizer.classic("Dbm"), "C#m")
        XCTAssertEqual(KeyNormalizer.classic("8B"),  "C")
        XCTAssertEqual(KeyNormalizer.classic("Am"),  "Am")
        XCTAssertNil(KeyNormalizer.classic("10m"))
    }

    /// Гармонический фильтр опирается на (номер, сторона) — проверяем разбор.
    func test_components() {
        let c = KeyNormalizer.components("Fm")
        XCTAssertEqual(c?.number, 4)
        XCTAssertEqual(c?.letter, "A")
        XCTAssertEqual(c?.text, "4A")
    }
}
