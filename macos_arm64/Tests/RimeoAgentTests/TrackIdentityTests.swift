import XCTest
@testable import RimeoAgent

// Ключ «та же запись». Главный риск здесь — не пропустить дубль, а СХЛОПНУТЬ ЛИШНЕЕ:
// потерянный ремикс — это молча потерянный кандидат, и заметить это гораздо труднее,
// чем лишнюю строку в выдаче. Поэтому негативных проверок тут больше, чем позитивных.
final class TrackIdentityTests: XCTestCase {

    private func key(_ artist: String, _ title: String) -> String? {
        TrackIdentity.key(artist: artist, title: title)
    }
    private func same(_ a: (String, String), _ b: (String, String)) -> Bool {
        guard let x = key(a.0, a.1), let y = key(b.0, b.1) else { return false }
        return x == y
    }

    // MARK: схлопываем — «та же версия»

    func testVersionMarkersCollapse() {
        let base = ("Rafael, Mita Gami", "What Is Luv")
        for variant in ["What Is Luv (Extended Mix)",
                        "What Is Luv (Original Mix)",
                        "What Is Luv (Radio Edit)",
                        "What Is Luv [Extended]",
                        "What Is Luv (Ext)",
                        "What Is Luv - Extended",
                        "What Is Luv - Extended Mix",
                        "  what is luv  "] {
            XCTAssertTrue(same(base, ("Rafael, Mita Gami", variant)), "не схлопнулось: \(variant)")
        }
    }

    // Состав артистов — МНОЖЕСТВО: порядок и разделитель в теге ничего не значат.
    func testArtistOrderAndSeparatorsDoNotMatter() {
        XCTAssertTrue(same(("Rafael, Mita Gami", "Song"), ("Mita Gami & Rafael", "Song")))
        XCTAssertTrue(same(("A; B", "Song"), ("B, A", "Song")))
    }

    // featuring — где бы он ни стоял (в тайтле или в артисте) — это один и тот же трек.
    func testFeaturingTailsCollapse() {
        XCTAssertTrue(same(("Rafael", "Song (feat. Mita Gami)"), ("Rafael, Mita Gami", "Song")))
        XCTAssertTrue(same(("Rafael ft. Mita Gami", "Song"),     ("Rafael, Mita Gami", "Song")))
        XCTAssertTrue(same(("Rafael featuring Mita Gami", "Song"),
                           ("Rafael", "Song [feat. Mita Gami]")))
    }

    // MARK: НЕ схлопываем — значимые различия

    // Имя ремиксера — часть произведения. Это главная граница всей фичи.
    func testDifferentRemixesStayDifferent() {
        XCTAssertFalse(same(("Artist", "Song (Peggy Gou Remix)"),
                            ("Artist", "Song (Jack Back Remix)")))
        XCTAssertFalse(same(("Artist", "Song (Peggy Gou Remix)"),
                            ("Artist", "Song (Extended Mix)")))
        XCTAssertFalse(same(("Artist", "Song (Peggy Gou Remix)"), ("Artist", "Song")))
    }

    // Скобочная и dash-запись одного и того же ремикса — одна запись.
    func testSameRemixInEitherNotationCollapses() {
        XCTAssertTrue(same(("Artist", "Song (Peggy Gou Remix)"),
                           ("Artist", "Song - Peggy Gou Remix")))
    }

    func testDifferentTitlesAndArtistsStayDifferent() {
        XCTAssertFalse(same(("Artist", "Song One"), ("Artist", "Song Two")))
        XCTAssertFalse(same(("Artist A", "Song"),   ("Artist B", "Song")))
        // Дефис внутри слова — не разделитель версии.
        XCTAssertFalse(same(("Artist", "Re-Work"), ("Artist", "Work")))
    }

    // MARK: вырожденные входы

    // Трек без тайтла опознавать нечем — дублем НЕ считаем, иначе все безымянные
    // схлопнулись бы в один и пропали бы из выдачи скопом.
    func testEmptyTitleHasNoIdentity() {
        XCTAssertNil(key("Artist", ""))
        XCTAssertNil(key("Artist", "   "))
        XCTAssertNil(key("", "(Extended Mix)"))   // от тайтла не осталось ничего значимого
    }

    func testEmptyArtistStillIdentifies() {
        XCTAssertNotNil(key("", "What Is Luv"))
        XCTAssertTrue(same(("", "What Is Luv"), ("", "What Is Luv (Extended Mix)")))
    }
}
