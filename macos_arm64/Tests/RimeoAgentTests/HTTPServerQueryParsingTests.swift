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
}
