import XCTest
@testable import RimeoAgent

// Ранжирование рекомендаций. Библиотека синтетическая: тесты не должны зависеть от
// того, что лежит в master.db на конкретной машине.
final class SimilarityEngineTests: XCTestCase {

    private var saved: SimilarityConfig!
    /// Треки синтетические, но ФАЙЛЫ под ними должны существовать: движок теперь не
    /// рекомендует то, чего нет на диске (см. TrackAvailability).
    private var tmpDir: URL!

    override func setUp() {
        super.setUp()
        saved = SimilarityEngine.shared.config
        SimilarityEngine.shared.setConfig(.default)
        tmpDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("simtests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        CoPlayGraph.shared.invalidate()
        TrackAvailability.shared.invalidate()
    }

    override func tearDown() {
        SimilarityEngine.shared.setConfig(saved)
        try? FileManager.default.removeItem(at: tmpDir)
        CoPlayGraph.shared.invalidate()
        TrackAvailability.shared.invalidate()
        super.tearDown()
    }

    // MARK: фабрика

    // title по умолчанию УНИКАЛЕН (из id). Общий тайтл на всю синтетическую библиотеку —
    // это, с точки зрения движка, один и тот же трек, импортированный N раз, и дедуп
    // (справедливо) схлопнул бы её в одну строку.
    private func track(_ id: String, artist: String = "A", title: String? = nil,
                       genre: String = "House", label: String = "L",
                       key: String = "8A", bpm: Double = 124,
                       playlists: [String] = [], indices: [String: Int] = [:],
                       histories: [String] = [], histIndices: [String: Int] = [:],
                       location: String? = nil) -> Track {
        // По умолчанию под треком создаётся настоящий файл. Явный `location` (в т.ч. на
        // несуществующий путь) — для проверок гейта доступности.
        let loc: String
        if let location = location {
            loc = location
        } else {
            let url = tmpDir.appendingPathComponent("\(id).mp3")
            FileManager.default.createFile(atPath: url.path, contents: Data("x".utf8))
            loc = url.path
        }
        return Track(id: id, artist: artist, title: title ?? "Title \(id)", genre: genre, label: label,
                     rel_date: "", key: key, bpm: bpm, duration: 360, bitrate: 320,
                     play_count: histories.isEmpty ? 0 : 1,
                     location: loc, timestamp: 0, date_str: "",
                     image_path: nil, playlists: playlists, playlist_indices: indices,
                     histories: histories, history_indices: histIndices)
    }

    /// Тёплый трек: играл в какой-то давней сессии. Нужен там, где проверяется квота
    /// открытий — иначе синтетическая библиотека целиком «холодная» и квота вырождается.
    private func warm(_ id: String, artist: String = "A", genre: String = "House",
                      label: String = "L", key: String = "8A", bpm: Double = 124) -> Track {
        track(id, artist: artist, genre: genre, label: label, key: key, bpm: bpm,
              histories: ["hist:warm-\(id)"], histIndices: ["hist:warm-\(id)": 1])
    }

    private func lib(_ tracks: [Track], playlists: [Playlist] = []) -> LibraryData {
        LibraryData(tracks: tracks, playlists: playlists, xml_date: 1, source: "test")
    }

    private func playlist(_ path: String, smart: Bool = false) -> Playlist {
        var p = Playlist(path: path, date: 0, smart: smart, history: false,
                         history_id: nil, name: path)
        p.is_smart = smart
        p.is_folder = false
        return p
    }

    // MARK: гейт по темпу

    // ГЛАВНОЕ изменение: гейт абсолютный (±3 BPM), а не процентный, и НЕ участвует
    // в ранжировании. 124±3 → 121…127 проходят, 130 нет.
    func testBPMGateIsAbsolute() {
        let seed = track("seed", bpm: 124)
        let l = lib([seed,
                     track("in-lo",  bpm: 121),
                     track("in-hi",  bpm: 127),
                     track("out-hi", bpm: 130),
                     track("out-lo", bpm: 118)])
        let got = Set(SimilarityEngine.shared
            .findSimilar(trackID: "seed", library: l, topN: 50).map { $0.track.id })
        XCTAssertEqual(got, ["in-lo", "in-hi"])
    }

    // Трек на 62 BPM — тот же грув, что 124 (half-time). Раньше он отсекался гейтом.
    func testHalfAndDoubleTimePass() {
        let l = lib([track("seed", bpm: 124),
                     track("half",   bpm: 62),
                     track("double", bpm: 248),
                     track("nope",   bpm: 90)])
        let got = Set(SimilarityEngine.shared
            .findSimilar(trackID: "seed", library: l, topN: 50).map { $0.track.id })
        XCTAssertEqual(got, ["half", "double"])
    }

    func testHalfDoubleCanBeDisabled() {
        var cfg = SimilarityConfig.default
        cfg.bpm_allow_half_double = false
        SimilarityEngine.shared.setConfig(cfg)
        let l = lib([track("seed", bpm: 124), track("half", bpm: 62)])
        XCTAssertTrue(SimilarityEngine.shared.findSimilar(trackID: "seed", library: l).isEmpty)
    }

    // Коридор плейлиста строится по p10…p90 состава: один затесавшийся даунтемпо-трек
    // не должен раскрывать окно на всю библиотеку.
    func testPlaylistBPMCorridorIgnoresOutlier() {
        var seeds = (0..<10).map { track("s\($0)", bpm: 124) }
        seeds.append(track("s-out", bpm: 100))          // выброс
        let l = lib(seeds + [track("c-in", bpm: 126), track("c-out", bpm: 105)])
        let got = Set(SimilarityEngine.shared
            .recommendForPlaylist(trackIDs: seeds.map { $0.id }, library: l, topN: 50)
            .map { $0.track.id })
        XCTAssertTrue(got.contains("c-in"))
        XCTAssertFalse(got.contains("c-out"))
    }

    // MARK: гейт по тональности

    func testKeyGateDropsIncompatibleAndSurvivesClassicNotation() {
        // Сид 8A (= Am). Совместимы: 8A (exact), 8B (relative), 7A/9A (соседи по колесу).
        // 2A — противоположная сторона колеса, несовместим.
        let l = lib([track("seed", key: "Am"),
                     track("same",     key: "8A"),
                     track("relative", key: "8B"),
                     track("neighbor", key: "Em"),      // 9A
                     track("far",      key: "2A")])
        let got = Set(SimilarityEngine.shared
            .findSimilar(trackID: "seed", library: l, topN: 50).map { $0.track.id })
        XCTAssertEqual(got, ["same", "relative", "neighbor"])

        // use_key=false — гейт снят, приезжают все.
        let all = SimilarityEngine.shared
            .findSimilar(trackID: "seed", library: l, topN: 50, useKey: false)
        XCTAssertEqual(all.count, 4)
    }

    func testUnparseableKeyIsNotAHardExclude() {
        let l = lib([track("seed", key: "8A"), track("junk", key: "10m")])
        let got = SimilarityEngine.shared.findSimilar(trackID: "seed", library: l, topN: 50)
        XCTAssertEqual(got.map { $0.track.id }, ["junk"])
        XCTAssertEqual(got.first?.score.key_relation, "—")
    }

    // MARK: co-play против метаданных

    // Трек, который РЕАЛЬНО играли рядом с треками плейлиста, обязан обойти трек с
    // такими же метаданными, но без истории. Это и есть суть переписывания.
    func testCoPlayBeatsPlainMetadata() {
        // Сет из 10 треков: сиды плейлиста + "coplayed" стоят рядом в истории.
        var tracks: [Track] = []
        for i in 0..<6 {
            tracks.append(track("s\(i)", artist: "Seed\(i)", label: "SeedLab",
                                histories: ["hist:1"], histIndices: ["hist:1": i]))
        }
        // Сосед по сету — метаданные НЕ совпадают с плейлистом.
        tracks.append(track("coplayed", artist: "X", label: "OtherLab",
                            histories: ["hist:1"], histIndices: ["hist:1": 6]))
        // Добиваем сессию до порога minSessionTracks (10).
        for i in 7..<12 {
            tracks.append(track("filler\(i)", artist: "F\(i)", label: "FillLab",
                                histories: ["hist:1"], histIndices: ["hist:1": i]))
        }
        // Конкурент: те же лейбл/жанр/ключ, что у сидов, но истории нет вообще.
        tracks.append(track("metaonly", artist: "M", label: "SeedLab"))

        let l = lib(tracks, playlists: [playlist("hist:1")])
        let seeds = (0..<6).map { "s\($0)" }
        let got = SimilarityEngine.shared.recommendForPlaylist(
            trackIDs: seeds, library: l, topN: 10)

        let ids = got.map { $0.track.id }
        XCTAssertTrue(ids.contains("coplayed"))
        XCTAssertTrue(ids.contains("metaonly"))
        XCTAssertLessThan(ids.firstIndex(of: "coplayed")!, ids.firstIndex(of: "metaonly")!,
                          "реальная совместность обязана бить голое совпадение лейбла")
    }

    // Smart-плейлисты в граф не попадают: их состав порождён правилом (genre = X),
    // учиться на них = переучиваться на тот же жанровый фильтр.
    func testSmartPlaylistIsNotASignal() {
        let seeds = (0..<3).map { i in
            track("s\(i)", playlists: ["smart"], indices: ["smart": i])
        }
        let cand = track("c", artist: "C", label: "CL", playlists: ["smart"], indices: ["smart": 3])
        let l = lib(seeds + [cand], playlists: [playlist("smart", smart: true)])
        CoPlayGraph.shared.ensureBuilt(from: l)
        XCTAssertFalse(CoPlayGraph.shared.knows("c"))
    }

    // MARK: холодный старт

    // Трек, о котором граф не знает НИЧЕГО, но который идеально ложится в профиль,
    // обязан обойти известный графу трек, который с этим плейлистом никак не связан
    // и по метаданным чужой. Иначе 17% библиотеки (непроигранные) утонули бы навсегда.
    func testColdTrackWithPerfectContentBeatsKnownButUnrelated() {
        var tracks: [Track] = []
        for i in 0..<6 {
            tracks.append(track("s\(i)", artist: "Seed\(i)", genre: "Afro House",
                                label: "SeedLab", key: "8A",
                                histories: ["hist:1"], histIndices: ["hist:1": i]))
        }
        // Известен графу (лежал в другом сете), но с плейлистом не пересекается,
        // и метаданные чужие.
        for i in 0..<10 {
            tracks.append(track("other\(i)", artist: "O\(i)", genre: "Tech House",
                                label: "OtherLab", key: "8B",
                                histories: ["hist:2"], histIndices: ["hist:2": i]))
        }
        // Холодный: ни истории, ни плейлистов — зато профиль плейлиста в точности.
        tracks.append(track("cold", artist: "Seed0", genre: "Afro House",
                            label: "SeedLab", key: "8A"))
        // Добиваем первую сессию до порога.
        for i in 6..<12 {
            tracks.append(track("f\(i)", artist: "F\(i)", genre: "Afro House", label: "SeedLab",
                                histories: ["hist:1"], histIndices: ["hist:1": i]))
        }

        let l = lib(tracks, playlists: [playlist("hist:1"), playlist("hist:2")])
        let got = SimilarityEngine.shared.recommendForPlaylist(
            trackIDs: (0..<6).map { "s\($0)" }, library: l, topN: 50)
        let ids = got.map { $0.track.id }

        XCTAssertTrue(CoPlayGraph.shared.knows("other0"))
        XCTAssertFalse(CoPlayGraph.shared.knows("cold"))
        XCTAssertTrue(ids.contains("cold"))
        XCTAssertLessThan(ids.firstIndex(of: "cold")!, ids.firstIndex(of: "other0")!,
                          "холодный трек с идеальным профилем не должен тонуть под известным-но-чужим")
    }

    // MARK: разнообразие

    // Группа-«захватчик» здесь СИЛЬНЕЕ остальных по контенту (точная тональность против
    // соседней), поэтому без лимита она забрала бы весь топ — ровно то, от чего защищаемся.
    func testArtistCap() {
        var cfg = SimilarityConfig.default
        cfg.max_per_artist = 2
        cfg.max_per_label  = 0                 // проверяем ровно лимит по артисту
        SimilarityEngine.shared.setConfig(cfg)

        var tracks = [track("seed", artist: "Seed", label: "SeedLab", key: "8A")]
        for i in 0..<10 {                      // один артист, точная тональность
            tracks.append(track("h\(i)", artist: "Hog", label: "HogLab\(i)", key: "8A"))
        }
        for i in 0..<10 {                      // разные артисты, соседняя тональность (слабее)
            tracks.append(track("d\(i)", artist: "Div\(i)", label: "DivLab\(i)", key: "9A"))
        }
        let l = lib(tracks)

        let got = SimilarityEngine.shared.recommendForPlaylist(
            trackIDs: ["seed"], library: l, topN: 8)
        XCTAssertEqual(got.filter { $0.track.artist == "Hog" }.count, 2,
                       "не больше 2 треков одного артиста в выдаче")

        // Лишние не выброшены, а сдвинуты в хвост — на следующих страницах они есть.
        let tail = SimilarityEngine.shared.recommendForPlaylist(
            trackIDs: ["seed"], library: l, topN: 50)
        XCTAssertEqual(tail.filter { $0.track.artist == "Hog" }.count, 10)
    }

    func testLabelCap() {
        var cfg = SimilarityConfig.default
        cfg.max_per_artist = 0
        cfg.max_per_label  = 3
        SimilarityEngine.shared.setConfig(cfg)

        var tracks = [track("seed", artist: "Seed", label: "SeedLab", key: "8A")]
        for i in 0..<10 {                      // один лейбл, точная тональность
            tracks.append(track("m\(i)", artist: "Art\(i)", label: "MegaLab", key: "8A"))
        }
        for i in 0..<10 {
            tracks.append(track("d\(i)", artist: "Div\(i)", label: "DivLab\(i)", key: "9A"))
        }
        let l = lib(tracks)

        let got = SimilarityEngine.shared.recommendForPlaylist(
            trackIDs: ["seed"], library: l, topN: 8)
        XCTAssertEqual(got.filter { $0.track.label == "MegaLab" }.count, 3,
                       "не больше 3 треков одного лейбла в выдаче")
    }

    // MARK: страницы и детерминированность

    // Refresh при неизменном составе обязан давать «ещё», а не тот же топ — при этом
    // без рандома: та же пара (состав, offset) всегда даёт ту же выдачу.
    func testPaginationIsDisjointAndDeterministic() {
        var tracks = [track("seed", artist: "S", label: "SL")]
        for i in 0..<40 {
            tracks.append(track("c\(i)", artist: "A\(i)", label: "L\(i)",
                                bpm: 124 + Double(i % 3) - 1))
        }
        let l = lib(tracks)

        let p1 = SimilarityEngine.shared.recommendForPlaylist(trackIDs: ["seed"], library: l, topN: 10)
        let p2 = SimilarityEngine.shared.recommendForPlaylist(trackIDs: ["seed"], library: l,
                                                              topN: 10, offset: 10)
        XCTAssertEqual(p1.count, 10)
        XCTAssertEqual(p2.count, 10)
        XCTAssertTrue(Set(p1.map { $0.track.id }).isDisjoint(with: p2.map { $0.track.id }))

        let again = SimilarityEngine.shared.recommendForPlaylist(trackIDs: ["seed"], library: l, topN: 10)
        XCTAssertEqual(p1.map { $0.track.id }, again.map { $0.track.id })
        XCTAssertEqual(p1.map { $0.score.total }, again.map { $0.score.total })

        // Оффсет за пределами пула — пусто, а не крэш (клиент по этому сигналу
        // возвращается на первую страницу).
        XCTAssertTrue(SimilarityEngine.shared
            .recommendForPlaylist(trackIDs: ["seed"], library: l, topN: 10, offset: 9999).isEmpty)
    }

    func testMembersAndExcludesNeverComeBack() {
        let l = lib([track("s1"), track("s2"), track("x"), track("ok")])
        let got = SimilarityEngine.shared.recommendForPlaylist(
            trackIDs: ["s1", "s2"], library: l, topN: 50, excludeIDs: ["x"])
        XCTAssertEqual(got.map { $0.track.id }, ["ok"])
    }

    // MARK: контракт ответа

    // Форму ответа декодят iOS (`SimilarResult.Score`) и веб-плеер (`_buildMetricsHtml`
    // в parser.py рисует чипы по label_match/genre_match/artist_match и key_relation).
    // Поля НЕЛЬЗЯ выкидывать, даже если UI перестал показывать «почему».
    func testResponseShapeIsStable() throws {
        let l = lib([track("seed"), track("c", artist: "C", label: "CL")])
        let res = SimilarityEngine.shared.recommendForPlaylist(trackIDs: ["seed"], library: l, topN: 1)
        XCTAssertEqual(res.count, 1)

        let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(res)) as? [[String: Any]]
        let score = json?.first?["score"] as? [String: Any]
        XCTAssertNotNil(json?.first?["track"])
        XCTAssertEqual(Set(score.map { Array($0.keys) } ?? []),
                       ["total", "bpm_delta", "key_relation",
                        "label_match", "genre_match", "artist_match", "duration_match"])
        // total — шкала [0…1] (раньше была сумма бонусов 0…5); ранжирование по нему.
        let total = score?["total"] as? Double ?? -1
        XCTAssertGreaterThanOrEqual(total, 0)
        XCTAssertLessThanOrEqual(total, 1)
    }

    // MARK: конфиг

    // Старый конфиг из облака (без новых полей) обязан парситься и давать новые дефолты.
    func testLegacyConfigDecodesWithSaneDefaults() throws {
        let old = """
        {"bpm_tolerance_pct":1.6,"key_max_steps":1,"duration_tolerance_pct":10.0,
         "result_limit":50,"weights":{"label":2.0,"genre":1.0,"artist":0.5,"duration":1.5}}
        """.data(using: .utf8)!
        let cfg = try JSONDecoder().decode(SimilarityConfig.self, from: old)
        XCTAssertEqual(cfg.bpm_tolerance_abs, 3.0)
        XCTAssertTrue(cfg.bpm_allow_half_double)
        XCTAssertEqual(cfg.candidate_pool, 300)
        XCTAssertEqual(cfg.max_per_artist, 2)
        XCTAssertEqual(cfg.max_per_label, 3)
        XCTAssertEqual(cfg.coplay_weight, 0.65)
        XCTAssertEqual(cfg.content_weight, 0.35)
        XCTAssertEqual(cfg.cold_start_backoff, 0.5)
        XCTAssertEqual(cfg.cold_start_quota_per_10, 3)
        XCTAssertEqual(cfg.weights.key, 1.5)
        XCTAssertEqual(cfg.weights.label, 2.0)   // старые веса уважаются
    }

    // MARK: дубликаты — «предлагает то, что уже в плейлисте»

    // Реальный случай из приёмки: тот же трек импортирован в библиотеку ДВАЖДЫ под разными
    // id, отличается только незаполненный лейбл. Исключение по id его не ловило, и движок
    // предлагал добавить в плейлист то, что в нём уже лежит — пользователь видит это первым.
    func testDuplicateOfPlaylistMemberIsNotRecommended() {
        let l = lib([track("17029898",  artist: "Rafael, Mita Gami",
                           title: "What Is Luv (Extended Mix)", label: "Maccabi House"),
                     track("233632012", artist: "Rafael, Mita Gami",
                           title: "What Is Luv (Extended Mix)", label: ""),
                     track("other", artist: "Someone", title: "Another Track")])
        let ids = SimilarityEngine.shared
            .recommendForPlaylist(trackIDs: ["17029898"], library: l, topN: 50)
            .map { $0.track.id }
        XCTAssertEqual(ids, ["other"], "дубль трека, который уже в плейлисте, предлагать нельзя")
    }

    // Нормализация обязана схлопывать РЕАЛЬНЫЕ различия тегов: регистр, лишние пробелы,
    // маркеры «та же версия», featuring-хвост, порядок артистов.
    func testDuplicateNormalizationCollapsesVersionMarkersAndFeat() {
        let l = lib([
            track("m",  artist: "Rafael, Mita Gami",  title: "What Is Luv (Extended Mix)"),
            track("v1", artist: "rafael,  mita gami", title: "  WHAT IS LUV  "),
            track("v2", artist: "Mita Gami & Rafael", title: "What Is Luv (Original Mix)"),
            track("v3", artist: "Rafael, Mita Gami",  title: "What Is Luv - Extended"),
            track("v4", artist: "Rafael",             title: "What Is Luv (feat. Mita Gami) [Radio Edit]"),
            track("keep", artist: "Z", title: "Totally Other"),
        ])
        let ids = SimilarityEngine.shared
            .recommendForPlaylist(trackIDs: ["m"], library: l, topN: 50).map { $0.track.id }
        XCTAssertEqual(ids, ["keep"])
    }

    // ГРАНИЦА, которую переходить нельзя. Другой ремикс той же песни — ДРУГОЙ трек, и
    // предложить его к плейлисту с оригиналом совершенно законно. Схлопнуть его в «дубль»
    // означало бы молча потерять живого кандидата.
    func testDifferentRemixIsNotADuplicate() {
        let l = lib([track("m",     artist: "Artist", title: "Song (Extended Mix)"),
                     track("peggy", artist: "Artist", title: "Song (Peggy Gou Remix)"),
                     track("jack",  artist: "Artist", title: "Song (Jack Back Remix)")])
        let ids = Set(SimilarityEngine.shared
            .recommendForPlaylist(trackIDs: ["m"], library: l, topN: 50).map { $0.track.id })
        XCTAssertEqual(ids, ["peggy", "jack"], "разные ремиксы — это разные треки")
    }

    // Обе копии дубля могут лежать ВНЕ плейлиста — тогда список показал бы один и тот же
    // трек дважды.
    func testDuplicateIsNotShownTwiceInResults() {
        let l = lib([track("seed", artist: "S", title: "Seed"),
                     track("a", artist: "Dup Artist", title: "Dup (Extended Mix)", label: "L1"),
                     track("b", artist: "Dup Artist", title: "Dup (Original Mix)",  label: "")])
        let got = SimilarityEngine.shared.recommendForPlaylist(trackIDs: ["seed"], library: l, topN: 50)
        XCTAssertEqual(got.map { $0.track.id }, ["a"])
    }

    // exclude_ids — тот же контракт: исключён id, значит исключены и его дубли.
    func testExcludedIDAlsoExcludesItsDuplicate() {
        let l = lib([track("seed", artist: "S", title: "Seed"),
                     track("x",  artist: "Dup Artist", title: "Dup (Extended Mix)"),
                     track("x2", artist: "Dup Artist", title: "Dup"),
                     track("ok", artist: "Other", title: "Fine")])
        let ids = SimilarityEngine.shared
            .recommendForPlaylist(trackIDs: ["seed"], library: l, topN: 50, excludeIDs: ["x"])
            .map { $0.track.id }
        XCTAssertEqual(ids, ["ok"])
    }

    // MARK: квота открытий

    /// Библиотека для проверки квоты: тёплые треки с ИДЕАЛЬНЫМ профилем (тот же лейбл, что
    /// у сида) против холодных с профилем послабее. Без квоты тёплые забирают топ целиком —
    /// ровно то, что случилось на живой библиотеке (0 непроигранных треков в топ-10 при 47%
    /// непроигранных в библиотеке).
    private func quotaLib(coldArtist: (Int) -> String = { "C\($0)" }) -> LibraryData {
        var tracks = [warm("seed", artist: "Seed", label: "SeedLab")]
        for i in 0..<40 { tracks.append(warm("w\(i)", artist: "W\(i)", label: "SeedLab")) }
        for i in 0..<10 { tracks.append(track("c\(i)", artist: coldArtist(i), label: "ColdLab")) }
        return lib(tracks)
    }

    func testColdStartQuotaFillsEveryTenPositions() {
        var cfg = SimilarityConfig.default
        cfg.max_per_label = 0            // лейблом не мешаем: проверяется ровно квота
        SimilarityEngine.shared.setConfig(cfg)
        let l = quotaLib()

        let top = SimilarityEngine.shared.recommendForPlaylist(trackIDs: ["seed"], library: l, topN: 10)
        XCTAssertEqual(top.count, 10)
        XCTAssertGreaterThanOrEqual(top.filter { $0.track.histories.isEmpty }.count, 3,
                                    "в топ-10 обязано быть не меньше 3 непроигранных треков")

        // Квота считается по позиции в РАНЖИРОВАННОМ списке, поэтому вторая страница
        // (Refresh с offset) — такая же десятка, а не «остатки после квоты».
        let page2 = SimilarityEngine.shared.recommendForPlaylist(
            trackIDs: ["seed"], library: l, topN: 10, offset: 10)
        XCTAssertEqual(page2.count, 10)
        XCTAssertGreaterThanOrEqual(page2.filter { $0.track.histories.isEmpty }.count, 3)
        XCTAssertTrue(Set(top.map { $0.track.id }).isDisjoint(with: page2.map { $0.track.id }))

        // Рандома нет: та же пара (состав, offset) — та же выдача.
        let again = SimilarityEngine.shared.recommendForPlaylist(trackIDs: ["seed"], library: l, topN: 10)
        XCTAssertEqual(top.map { $0.track.id }, again.map { $0.track.id })
    }

    // Открытия релевантны, а не случайны: они прошли те же гейты (BPM + тональность) и
    // отобраны по content-пути. Трек за пределами коридора в квоту не попадает.
    func testQuotaPicksOnlyGatedCandidates() {
        var cfg = SimilarityConfig.default
        cfg.max_per_label = 0
        SimilarityEngine.shared.setConfig(cfg)

        var tracks = [warm("seed", artist: "Seed", label: "SeedLab")]
        for i in 0..<40 { tracks.append(warm("w\(i)", artist: "W\(i)", label: "SeedLab")) }
        // Холодный, но чужой по темпу и тональности — квота не имеет права его протащить.
        tracks.append(track("junk", artist: "Junk", label: "ColdLab", key: "2B", bpm: 150))
        let l = lib(tracks)

        let ids = SimilarityEngine.shared
            .recommendForPlaylist(trackIDs: ["seed"], library: l, topN: 10).map { $0.track.id }
        XCTAssertFalse(ids.contains("junk"))
    }

    // Квота не имеет права нарушать лимит «не больше 2 треков одного артиста».
    func testColdQuotaRespectsArtistCap() {
        var cfg = SimilarityConfig.default
        cfg.max_per_label = 0
        SimilarityEngine.shared.setConfig(cfg)
        let l = quotaLib(coldArtist: { _ in "ColdHog" })      // все холодные — один артист

        let top = SimilarityEngine.shared.recommendForPlaylist(trackIDs: ["seed"], library: l, topN: 10)
        XCTAssertEqual(top.filter { $0.track.artist == "ColdHog" }.count, 2,
                       "лимит по артисту сильнее квоты — квота это гарантия, а не право нарушать")
    }

    // Квоту можно выключить (0) — тогда выдача чисто по скору, как до этой правки.
    func testColdQuotaCanBeDisabled() {
        var cfg = SimilarityConfig.default
        cfg.max_per_label = 0
        cfg.cold_start_quota_per_10 = 0
        SimilarityEngine.shared.setConfig(cfg)
        let l = quotaLib()

        let top = SimilarityEngine.shared.recommendForPlaylist(trackIDs: ["seed"], library: l, topN: 10)
        XCTAssertEqual(top.filter { $0.track.histories.isEmpty }.count, 0,
                       "без квоты плотный тёплый кластер забирает топ целиком — это и был баг")
    }

    // /api/similar — не блок «что добавить»: подмешивать туда открытия значило бы врать
    // про смысл списка («похожие треки» обязаны быть похожими).
    func testQuotaDoesNotApplyToFindSimilar() {
        var cfg = SimilarityConfig.default
        cfg.max_per_label = 0
        SimilarityEngine.shared.setConfig(cfg)
        let l = quotaLib()

        let top = SimilarityEngine.shared.findSimilar(trackID: "seed", library: l, topN: 10)
        XCTAssertEqual(top.filter { $0.track.histories.isEmpty }.count, 0)
    }

    // MARK: битые треки (файла нет на диске)

    // 6.6% реальной библиотеки — записи без файла: импорт из медиатеки iTunes ("/Contents/…"),
    // пути со старым юзернеймом ("/Users/ilya/…"), "soundcloud:tracks:…". Играть нечего.
    func testBrokenTracksAreNeverRecommended() {
        let l = lib([track("seed", artist: "S"),
                     track("gone",  artist: "G1", location: "/Contents/Some/Missing.m4a"),
                     track("olduser", artist: "G2", location: "/Users/ilya/Music/Gone.mp3"),
                     track("stream", artist: "G3", location: "soundcloud:tracks:123456"),
                     track("empty",  artist: "G4", location: ""),
                     track("alive",  artist: "OK")])
        let ids = SimilarityEngine.shared
            .recommendForPlaylist(trackIDs: ["seed"], library: l, topN: 50).map { $0.track.id }
        XCTAssertEqual(ids, ["alive"], "трек без файла рекомендовать нельзя — его нечем играть")
    }

    // Тот же гейт обязан работать и на /api/similar.
    func testBrokenTracksAreNeverReturnedByFindSimilar() {
        let l = lib([track("seed"),
                     track("gone", artist: "G", location: "/Contents/Missing.m4a"),
                     track("alive", artist: "OK")])
        let ids = SimilarityEngine.shared
            .findSimilar(trackID: "seed", library: l, topN: 50).map { $0.track.id }
        XCTAssertEqual(ids, ["alive"])
    }

    // САМОЕ ОПАСНОЕ ПЕРЕСЕЧЕНИЕ: битый трек никогда не игрался ПО ОПРЕДЕЛЕНИЮ (играть нечего),
    // поэтому для квоты открытий он выглядит идеальным кандидатом. На живой библиотеке 131 из
    // 150 битых треков — непроигранные. Квота не имеет права затащить в выдачу ни одного.
    func testColdQuotaNeverPullsInBrokenTracks() {
        var cfg = SimilarityConfig.default
        cfg.max_per_label = 0
        SimilarityEngine.shared.setConfig(cfg)

        var tracks = [warm("seed", artist: "Seed", label: "SeedLab")]
        for i in 0..<40 { tracks.append(warm("w\(i)", artist: "W\(i)", label: "SeedLab")) }
        // Холодные и БИТЫЕ — идеальный профиль, но файла нет.
        for i in 0..<20 {
            tracks.append(track("dead\(i)", artist: "D\(i)", label: "SeedLab",
                                location: "/Contents/dead\(i).m4a"))
        }
        // Холодные и живые — их и должна брать квота.
        for i in 0..<5 { tracks.append(track("live\(i)", artist: "L\(i)", label: "ColdLab")) }
        let l = lib(tracks)

        let top = SimilarityEngine.shared.recommendForPlaylist(trackIDs: ["seed"], library: l, topN: 10)
        XCTAssertTrue(top.allSatisfy { !$0.track.id.hasPrefix("dead") },
                      "квота открытий не имеет права тащить треки без файла")
        XCTAssertGreaterThanOrEqual(top.filter { $0.track.histories.isEmpty }.count, 3,
                                    "квота при этом обязана выполниться живыми холодными треками")
    }

    // Битая копия не должна утаскивать за собой живую: в библиотеке лежат .wav (битый) и
    // .aiff (живой) одного и того же трека — предложить обязаны живой.
    func testBrokenDuplicateDoesNotSuppressItsLiveTwin() {
        let l = lib([track("seed", artist: "S", title: "Seed"),
                     track("dead", artist: "Rafael, Mita Gami", title: "What Is Luv (Extended Mix)",
                           location: "/Volumes/GONE/What Is Luv.wav"),
                     track("live", artist: "Rafael, Mita Gami", title: "What Is Luv (Extended Mix)")])
        let ids = SimilarityEngine.shared
            .recommendForPlaylist(trackIDs: ["seed"], library: l, topN: 50).map { $0.track.id }
        XCTAssertEqual(ids, ["live"])
    }

    // Абсолютный допуск можно выключить (=0) и вернуться к процентному — обратная
    // совместимость для того, кто уже крутил bpm_tolerance_pct в /admin.
    func testZeroAbsToleranceFallsBackToPercent() {
        var cfg = SimilarityConfig.default
        cfg.bpm_tolerance_abs = 0
        cfg.bpm_tolerance_pct = 1.6            // 124 × 1.6% ≈ ±1.98
        SimilarityEngine.shared.setConfig(cfg)
        let l = lib([track("seed", bpm: 124), track("near", bpm: 125.5), track("far", bpm: 127)])
        let got = Set(SimilarityEngine.shared
            .findSimilar(trackID: "seed", library: l, topN: 50).map { $0.track.id })
        XCTAssertEqual(got, ["near"])
    }
}
