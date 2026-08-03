import XCTest
@testable import RimeoAgent

final class HTTPServerQueryParsingTests: XCTestCase {
    func testParseFormQueryDecodesPercentEncodedSpacesInPath() {
        let query = parseFormQuery("path=%2FUsers%2Filia%2FDocuments%2FAI%20stuff%2FTrack%20One.aiff&id=123")

        XCTAssertEqual(query["path"], "/Users/ilia/Documents/AI stuff/Track One.aiff")
        XCTAssertEqual(query["id"], "123")
    }

    func testParseFormQueryPreservesLiteralPlusSignsInPath() {
        let query = parseFormQuery("path=%2FUsers%2Filia%2FDocuments%2FAI+stuff%2FTrack+One.aiff&id=123")

        XCTAssertEqual(query["path"], "/Users/ilia/Documents/AI+stuff/Track+One.aiff")
        XCTAssertEqual(query["id"], "123")
    }

    func testParseFormQueryPreservesEqualsInsideValue() {
        let query = parseFormQuery("token=abc%3Ddef%3Dghi")

        XCTAssertEqual(query["token"], "abc=def=ghi")
    }

    func testParseFormQueryHandlesFlagWithoutValue() {
        let query = parseFormQuery("preload")

        XCTAssertEqual(query["preload"], "")
    }

    /// «Толерантное» извлечение `path` обрывается на списке известных ключей. Пока в нём не
    /// было `&src=`, запрос вида `?id=…&path=…&src=ios` отдавал 404 на существующий файл:
    /// путь съедал хвост запроса. Порядок параметров у клиента не должен быть негласным
    /// контрактом — проверяем все ключи, которые вообще приходят после `path`.
    func testParseFormQueryStopsPathAtEveryKnownParameter() {
        let cases: [(String, String)] = [
            ("src", "ios"), ("fmt", "original"), ("raw", "1"), ("token", "abc"),
            ("session", "s1"), ("lan_token", "psk"), ("preload", "1"), ("id", "42"),
        ]
        for (key, value) in cases {
            let query = parseFormQuery("id=7&path=%2Fmusic%2FTrack%20One.aiff&\(key)=\(value)")
            XCTAssertEqual(query["path"], "/music/Track One.aiff", "терминатор &\(key)=")
            XCTAssertEqual(query[key], value, "значение \(key)")
        }
    }

    /// Неэкранированный `&` в имени файла (клиенты, которые не кодируют значение) всё ещё
    /// должен доезжать целиком, а идущие следом параметры — разбираться отдельно.
    func testParseFormQueryKeepsUnescapedAmpersandInsidePath() {
        let query = parseFormQuery("path=/music/Nervo & Hook N Sling - Reason.wav&id=42&src=ios")

        XCTAssertEqual(query["path"], "/music/Nervo & Hook N Sling - Reason.wav")
        XCTAssertEqual(query["id"], "42")
        XCTAssertEqual(query["src"], "ios")
    }
}
