import XCTest
@testable import RimeoAgent

/// 60 сырых написаний жанра в библиотеке схлопываются в ~8 корзин. Сырое сравнение
/// строк считало "Afro House" и "Afro-House" разными жанрами → жанровый бонус не
/// срабатывал. Run: `swift test --filter GenreCanonTests`.
final class GenreCanonTests: XCTestCase {

    func test_buckets() {
        let cases: [(String, String)] = [
            ("Afro House",                  "afro_house"),
            ("Afro-House",                  "afro_house"),
            ("AfroHouse",                   "afro_house"),
            ("afro house",                  "afro_house"),
            ("House",                       "house"),
            ("Хаус",                        "house"),
            ("Organic House",               "organic"),
            ("Organic House / Downtempo",   "organic"),
            ("Hip-Hop",                     "hiphop"),
            ("Hip Hop/Rap",                 "hiphop"),
            ("Melodic House & Techno",      "melodic"),
            ("Tech House",                  "tech_house"),
            ("Minimal / Deep Tech",         "minimal"),
            ("Deep House",                  "deep_house"),
            ("Indie Dance",                 "indie_dance"),
            // реальные написания из библиотеки
            ("AFRO HOUSE ",                 "afro_house"),
            ("Afrohouse",                   "afro_house"),
            ("Melodic Techno",              "melodic"),
            ("Minimal",                     "minimal"),
        ]
        for (raw, expected) in cases {
            XCTAssertEqual(GenreCanon.canon(raw), expected, "\(raw) → \(expected)")
        }
    }

    /// Мультижанр в одном поле: берём первый сегмент.
    func test_multiGenreField_usesFirstSegment() {
        XCTAssertEqual(GenreCanon.canon("House, Tech House"),        "house")
        XCTAssertEqual(GenreCanon.canon("Tech House / Breakbeat"),   "tech_house")
        XCTAssertEqual(GenreCanon.canon("Minimal/tech house"),       "minimal")
        XCTAssertEqual(GenreCanon.canon("Afro House, Club Classic"), "afro_house")
        XCTAssertEqual(GenreCanon.canon("Afro / Latin / Brazilian"), "afro_house")
    }

    /// Составные имена Beatport не должны резаться по "/" — они матчатся целиком.
    func test_compoundBeatportNames_notSplit() {
        XCTAssertEqual(GenreCanon.canon("Organic House / Downtempo"), "organic")
        XCTAssertEqual(GenreCanon.canon("Minimal / Deep Tech"),       "minimal")
        // "Nu Disco / Disco" не сливаем с Indie Dance — пользователь держит их врозь.
        XCTAssertEqual(GenreCanon.canon("Nu Disco / Disco"),          "nu disco disco")
        XCTAssertFalse(GenreCanon.same("Nu Disco / Disco", "Indie Dance"))
    }

    func test_unknownGenre_isNormalizedNotLost() {
        XCTAssertEqual(GenreCanon.canon("Progressive House"), "progressive house")
        XCTAssertEqual(GenreCanon.canon("Progressive-House"), "progressive house")
        XCTAssertEqual(GenreCanon.canon("  DRUM & BASS  "),   "drum bass")
        XCTAssertTrue(GenreCanon.same("Progressive House", "Progressive-House"))
    }

    func test_emptyGenre_neverMatches() {
        XCTAssertEqual(GenreCanon.canon(""),    "")
        XCTAssertEqual(GenreCanon.canon("   "), "")
        XCTAssertFalse(GenreCanon.same("", ""))
        XCTAssertFalse(GenreCanon.same("House", ""))
    }

    func test_same_acrossSpellings() {
        XCTAssertTrue(GenreCanon.same("Afro House", "AfroHouse"))
        XCTAssertTrue(GenreCanon.same("Хаус", "House"))
        XCTAssertTrue(GenreCanon.same("Organic House", "Organic House / Downtempo"))
        XCTAssertFalse(GenreCanon.same("Deep House", "Tech House"))
        XCTAssertFalse(GenreCanon.same("House", "Afro House"))
    }
}
