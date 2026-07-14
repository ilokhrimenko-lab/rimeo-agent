import Foundation

// Ранжирование кандидатов: «похожие треки» (/api/similar) и «что добавить в плейлист»
// (/api/playlist/recommendations). Оба роута — один движок: разница только в том,
// сколько треков в сид-наборе (один трек против всего состава плейлиста).
//
// СТАРЫЙ алгоритм (и почему он давал «случайный мусор»):
//   гейт по BPM (±1.6%) + гармонии → линейная сумма ЧЕТЫРЁХ БУЛЕВЫХ бонусов
//   (label 2.0, duration 1.5, genre 1.0, artist 0.5) → тай-брейк по |ΔBPM|.
//   На реальной библиотеке (2280 треков) это разваливалось так:
//     • 75% библиотеки лежит в окне 118–130 BPM ⇒ «близкий BPM» не различает НИЧЕГО,
//       но именно он был главным тай-брейком. Когда все бонусы нулевые (обычный
//       случай — лейбл совпадает редко), выдача превращалась в «у кого BPM ближе»,
//       то есть в шум.
//     • duration (второй по величине вес!) у клубных треков 5–7 минут срабатывает
//       практически у всех — раздавал 1.5 балла почти случайным трекам.
//     • бонусы булевы ⇒ огромные группы кандидатов с одинаковым total, порядок внутри
//       группы решал ΔBPM.
//
// НОВЫЙ алгоритм. Скор = взвешенная смесь ДВУХ путей, оба в [0…1]:
//
//   1) CO-PLAY (главный) — CoPlayGraph: реальные переходы из истории сетов + совместность
//      в РУЧНЫХ плейлистах. Это единственный сигнал в библиотеке, который отражает вкус,
//      а не метаданные Beatport.
//   2) CONTENT (вспомогательный) — насколько кандидат попадает в ПРОФИЛЬ сид-набора:
//      доля сидов с тем же лейблом / жанром / артистом + гармоническая близость к
//      палитре тональностей плейлиста. Все фичи ГРАДУИРОВАНЫ (доли, не булевы), поэтому
//      массовых ничьих больше нет и тай-брейк по BPM не нужен.
//
//   BPM теперь ТОЛЬКО ГЕЙТ (абсолютное окно ±N BPM вокруг темпового коридора плейлиста,
//   с поддержкой half/double-time: 62 BPM подходит к 124) и НЕ участвует в ранжировании.
//   duration выкинут из скора совсем (оставлен только флаг duration_match в ответе).
//
// Все веса/пороги — в similarity_config.json (правится в /admin, синкается из облака).

struct SimilarityConfig: Codable {

    // MARK: гейты кандидата

    /// Абсолютный допуск по темпу, ±BPM. ГЛАВНЫЙ гейт. Процентный допуск при 124 BPM
    /// давал ±2 BPM у быстрых треков и ±1.6 у медленных — разная строгость на ровном месте.
    var bpm_tolerance_abs: Double
    /// Legacy-процент. Работает ТОЛЬКО когда bpm_tolerance_abs <= 0 (обратная совместимость
    /// со старым конфигом из облака, где абсолютного поля ещё нет).
    var bpm_tolerance_pct: Double
    /// 62 BPM ↔ 124 BPM — один и тот же грув. Кандидат сворачивается в октаву плейлиста.
    var bpm_allow_half_double: Bool
    /// Расстояние по колесу Camelot при одинаковой стороне (A/B), в шагах.
    var key_max_steps: Int
    /// Только для информационного флага duration_match в ответе. В скор НЕ входит.
    var duration_tolerance_pct: Double

    // MARK: выдача

    var result_limit: Int
    /// Глубина ранжированного списка, из которого нарезаются страницы (кнопка Refresh
    /// отдаёт СЛЕДУЮЩИЙ срез, а не тот же топ). Работа O(pool·log pool), не O(библиотеки).
    var candidate_pool: Int
    /// Не больше N треков одного артиста / лейбла в выдаче (0 = без ограничения).
    /// Лишние не выбрасываются, а сдвигаются в хвост — на следующих страницах они появятся.
    var max_per_artist: Int
    var max_per_label: Int

    // MARK: смешивание путей

    /// Вклад графа совместности и вклад метаданных. Нормируются суммой, поэтому важно
    /// их ОТНОШЕНИЕ, а не абсолютные значения.
    var coplay_weight: Double
    var content_weight: Double
    /// Веса каналов ВНУТРИ графа: история сетов против ручных плейлистов.
    var history_weight: Double
    var playlist_weight: Double
    /// Холодный старт: доля content-скора, которой замещается co-play у треков, про которые
    /// граф не знает НИЧЕГО (никогда не игрались и не лежат ни в одном ручном плейлисте —
    /// на реальной библиотеке это 17%). Подробности — в комментарии к `blend`.
    var cold_start_backoff: Double
    /// КВОТА ОТКРЫТИЙ: сколько позиций из каждых 10 гарантированно отдаётся трекам,
    /// которые НИКОГДА не игрались (47% библиотеки). Подробности — в `interleaveCold`.
    /// 0 = квота выключена (выдача чисто по скору).
    var cold_start_quota_per_10: Int

    var weights: Weights

    /// Веса ВНУТРИ content-пути. Нормируются суммой активных, так что это относительная
    /// важность признаков, а не абсолютные баллы.
    struct Weights: Codable {
        var label:  Double
        var genre:  Double
        var artist: Double
        /// Гармоническая близость к палитре тональностей сид-набора.
        var key:    Double
        /// МЁРТВЫЙ вес. Оставлен, чтобы старые конфиги (и админка) парсились без ошибок:
        /// длительность у клубных треков 5–7 минут совпадает почти у всех и в скоре была
        /// чистым шумом. Значение игнорируется.
        var duration: Double

        init(label: Double, genre: Double, artist: Double, key: Double, duration: Double) {
            self.label = label; self.genre = genre; self.artist = artist
            self.key = key; self.duration = duration
        }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            label    = try c.decodeIfPresent(Double.self, forKey: .label)    ?? 2.0
            genre    = try c.decodeIfPresent(Double.self, forKey: .genre)    ?? 1.0
            artist   = try c.decodeIfPresent(Double.self, forKey: .artist)   ?? 0.5
            key      = try c.decodeIfPresent(Double.self, forKey: .key)      ?? 1.5
            duration = try c.decodeIfPresent(Double.self, forKey: .duration) ?? 1.5
        }
    }

    init(bpm_tolerance_abs: Double, bpm_tolerance_pct: Double, bpm_allow_half_double: Bool,
         key_max_steps: Int, duration_tolerance_pct: Double,
         result_limit: Int, candidate_pool: Int, max_per_artist: Int, max_per_label: Int,
         coplay_weight: Double, content_weight: Double,
         history_weight: Double, playlist_weight: Double, cold_start_backoff: Double,
         cold_start_quota_per_10: Int = 3,
         weights: Weights) {
        self.cold_start_quota_per_10 = cold_start_quota_per_10
        self.bpm_tolerance_abs     = bpm_tolerance_abs
        self.bpm_tolerance_pct     = bpm_tolerance_pct
        self.bpm_allow_half_double = bpm_allow_half_double
        self.key_max_steps         = key_max_steps
        self.duration_tolerance_pct = duration_tolerance_pct
        self.result_limit   = result_limit
        self.candidate_pool = candidate_pool
        self.max_per_artist = max_per_artist
        self.max_per_label  = max_per_label
        self.coplay_weight      = coplay_weight
        self.content_weight     = content_weight
        self.history_weight     = history_weight
        self.playlist_weight    = playlist_weight
        self.cold_start_backoff = cold_start_backoff
        self.weights = weights
    }

    // Каждое поле — decodeIfPresent: конфиг, лежащий в облаке/на диске со старой схемой
    // (bpm_tolerance_pct + key_max_steps + duration_tolerance_pct + result_limit + weights),
    // обязан декодироваться и давать разумные новые дефолты.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        bpm_tolerance_abs      = try c.decodeIfPresent(Double.self, forKey: .bpm_tolerance_abs)      ?? 3.0
        bpm_tolerance_pct      = try c.decodeIfPresent(Double.self, forKey: .bpm_tolerance_pct)      ?? 1.6
        bpm_allow_half_double  = try c.decodeIfPresent(Bool.self,   forKey: .bpm_allow_half_double)  ?? true
        key_max_steps          = try c.decodeIfPresent(Int.self,    forKey: .key_max_steps)          ?? 1
        duration_tolerance_pct = try c.decodeIfPresent(Double.self, forKey: .duration_tolerance_pct) ?? 10.0
        result_limit           = try c.decodeIfPresent(Int.self,    forKey: .result_limit)           ?? 50
        candidate_pool         = try c.decodeIfPresent(Int.self,    forKey: .candidate_pool)         ?? 300
        max_per_artist         = try c.decodeIfPresent(Int.self,    forKey: .max_per_artist)         ?? 2
        max_per_label          = try c.decodeIfPresent(Int.self,    forKey: .max_per_label)          ?? 3
        coplay_weight          = try c.decodeIfPresent(Double.self, forKey: .coplay_weight)          ?? 0.65
        content_weight         = try c.decodeIfPresent(Double.self, forKey: .content_weight)         ?? 0.35
        history_weight         = try c.decodeIfPresent(Double.self, forKey: .history_weight)         ?? 1.0
        playlist_weight        = try c.decodeIfPresent(Double.self, forKey: .playlist_weight)        ?? 0.6
        cold_start_backoff     = try c.decodeIfPresent(Double.self, forKey: .cold_start_backoff)     ?? 0.5
        // Ключа нет в конфиге, сохранённом до появления квоты, — и это нормальный,
        // а не аварийный путь: старый конфиг обязан парситься и получать дефолт.
        cold_start_quota_per_10 = try c.decodeIfPresent(Int.self, forKey: .cold_start_quota_per_10) ?? 3
        weights                = try c.decodeIfPresent(Weights.self, forKey: .weights)
            ?? Weights(label: 2.0, genre: 1.0, artist: 0.5, key: 1.5, duration: 1.5)
    }

    static let `default` = SimilarityConfig(
        bpm_tolerance_abs:      3.0,
        bpm_tolerance_pct:      1.6,
        bpm_allow_half_double:  true,
        key_max_steps:          1,
        duration_tolerance_pct: 10.0,
        result_limit:           50,
        candidate_pool:         300,
        max_per_artist:         2,
        max_per_label:          3,
        coplay_weight:          0.65,
        content_weight:         0.35,
        history_weight:         1.0,
        playlist_weight:        0.6,
        cold_start_backoff:     0.5,
        cold_start_quota_per_10: 3,
        weights: Weights(label: 2.0, genre: 1.0, artist: 0.5, key: 1.5, duration: 1.5)
    )
}

final class SimilarityEngine {
    static let shared = SimilarityEngine()
    private init() { self._config = SimilarityEngine.loadConfig() }

    // Config is mutable: it starts from the cached/bundled file and is then
    // refreshed from the cloud (admin-managed) at startup + on a timer, so
    // tuning the algorithm never requires shipping a new agent build.
    private let configLock = NSLock()
    private var _config: SimilarityConfig
    private var refreshTimer: DispatchSourceTimer?
    private let refreshInterval: TimeInterval = 600   // 10 minutes

    var config: SimilarityConfig {
        configLock.lock(); defer { configLock.unlock() }
        return _config
    }

    /// internal, а не private: этим же сеттером конфиг подменяют тесты, чтобы не зависеть
    /// от того, какой конфиг закэширован на конкретной машине.
    func setConfig(_ cfg: SimilarityConfig) {
        configLock.lock(); _config = cfg; configLock.unlock()
    }

    // Persisted copy of the last-known-good cloud config — preferred source on
    // the next launch so offline starts keep the latest admin-tuned values.
    private static var cachedConfigURL: URL {
        AppConfig.shared.baseDir.appendingPathComponent("similarity_config.json")
    }

    /// Форма ответа НЕ менялась (её декодят iOS и веб-плеер) — сменилась только шкала
    /// `total`: раньше это была сумма бонусов 0…5, теперь смесь двух путей в 0…1.
    /// Ни один клиент `total` не показывает, он нужен только для ранжирования.
    struct MatchScore: Codable {
        let total:          Double   // 0…1: coplay_weight·co + content_weight·content
        let bpm_delta:      Double   // |BPM кандидата (свёрнутый в октаву) − центр коридора|
        let key_relation:   String   // "exact" | "relative" | "compatible" | "—"
        let label_match:    Bool
        let genre_match:    Bool
        let artist_match:   Bool
        let duration_match: Bool     // информационный флаг, в скор НЕ входит
    }

    struct SimilarResult: Codable {
        let track: Track
        let score: MatchScore
    }

    // MARK: - Config loading

    // Startup source priority: cached cloud config → bundled file → built-in default.
    private static func loadConfig() -> SimilarityConfig {
        if let data = try? Data(contentsOf: cachedConfigURL),
           let cfg  = try? JSONDecoder().decode(SimilarityConfig.self, from: data) {
            return cfg
        }
        if let url = Bundle.main.url(forResource: "similarity_config", withExtension: "json"),
           let data = try? Data(contentsOf: url),
           let cfg  = try? JSONDecoder().decode(SimilarityConfig.self, from: data) {
            return cfg
        }
        return .default
    }

    // MARK: - Cloud sync

    /// Kick off cloud config syncing: one immediate fetch + a repeating timer.
    /// Safe to call once at app launch.
    func startCloudSync() {
        refreshFromCloud()
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        timer.schedule(deadline: .now() + refreshInterval, repeating: refreshInterval)
        timer.setEventHandler { [weak self] in self?.refreshFromCloud() }
        timer.resume()
        refreshTimer = timer
    }

    /// Fetch the admin-managed config from the cloud; on success update the live
    /// config and persist it for the next launch. Failures are silently ignored
    /// (we keep whatever config we already have).
    func refreshFromCloud() {
        guard let url = URL(string: "\(AppConfig.shared.rimeoAppURL)/api/similarity_config") else { return }
        var req = URLRequest(url: url)
        req.setValue("RimeoAgentMac/\(AppConfig.shared.version)", forHTTPHeaderField: "User-Agent")
        req.cachePolicy = .reloadIgnoringLocalCacheData
        req.timeoutInterval = 10

        URLSession.shared.dataTask(with: req) { [weak self] data, _, _ in
            guard let self = self,
                  let data = data,
                  let cfg = try? JSONDecoder().decode(SimilarityConfig.self, from: data) else { return }
            self.setConfig(cfg)
            try? data.write(to: SimilarityEngine.cachedConfigURL, options: .atomic)
        }.resume()
    }

    // MARK: - Public API

    /// «Похожие треки» на один трек. Сид-набор из одного элемента — тот же движок,
    /// что и у рекомендаций плейлиста.
    func findSimilar(trackID: String, library: LibraryData,
                     topN: Int? = nil, useKey: Bool = true,
                     excludeIDs: Set<String> = []) -> [SimilarResult] {
        // diversify: false — у /api/similar ограничивать «не больше 2 треков артиста»
        // неправильно: «ещё вот эти два ремикса того же артиста» здесь и есть ответ.
        // quota: false — «похожие треки» обязаны быть похожими; подмешивать сюда открытия
        // (это фича блока «что ДОБАВИТЬ») значило бы врать про смысл списка.
        rank(seedIDs: [trackID], library: library, topN: topN, useKey: useKey,
             excludeIDs: excludeIDs, offset: 0, diversify: false, quota: false)
    }

    /// «Что добавить» для плейлиста ЦЕЛИКОМ. Сид — весь состав (не сэмпл: и граф, и
    /// профиль строятся за доли миллисекунды, а сэмплирование теряло кластеры).
    ///
    /// `offset` — страница ранжированного списка. Кнопка Refresh при неизменном составе
    /// шлёт offset += limit и получает СЛЕДУЮЩИЙ срез, а не тот же топ. Ранжирование
    /// при этом остаётся полностью детерминированным (никакого рандома): одна и та же
    /// пара (состав, offset) всегда даёт одну и ту же выдачу.
    func recommendForPlaylist(trackIDs: [String], library: LibraryData,
                              topN: Int? = nil, useKey: Bool = true,
                              excludeIDs: Set<String> = [], offset: Int = 0) -> [SimilarResult] {
        rank(seedIDs: trackIDs, library: library, topN: topN, useKey: useKey,
             excludeIDs: excludeIDs, offset: offset, diversify: true, quota: true)
    }

    // MARK: - Ядро ранжирования

    private func rank(seedIDs: [String], library: LibraryData,
                      topN: Int?, useKey: Bool,
                      excludeIDs: Set<String>, offset: Int,
                      diversify: Bool, quota: Bool) -> [SimilarResult] {
        let cfg   = config                        // атомарный снимок на весь запрос
        let limit = max(1, topN ?? cfg.result_limit)

        var seenSeed = Set<String>()
        let seeds = seedIDs.filter { !$0.isEmpty && seenSeed.insert($0).inserted }
        guard !seeds.isEmpty else { return [] }

        let tracks = library.tracks
        var byID = [String: Track](minimumCapacity: tracks.count)
        for t in tracks { byID[t.id] = t }

        let seedTracks = seeds.compactMap { byID[$0] }
        guard !seedTracks.isEmpty else { return [] }

        let profile = SeedProfile(seedTracks, cfg: cfg)
        let exclude = seenSeed.union(excludeIDs)

        // Исключение по id ловит только сам файл, а в библиотеке один и тот же трек лежит
        // импортированным ДВАЖДЫ (разные id, разные теги). Поэтому вторая, более сильная
        // защита — по нормализованной паре (артист, тайтл): всё, что уже есть в составе
        // (или в exclude_ids), не предлагаем ни под каким id. Ремиксы при этом остаются
        // разными треками — см. TrackIdentity.
        var excludeKeys = Set<String>()
        for id in exclude {
            if let t = byID[id], let k = TrackIdentity.key(t) { excludeKeys.insert(k) }
        }

        // Битые треки (файла на диске нет) в выдачу не пускаем: играть нечего. Считается
        // один раз на версию библиотеки, не на запрос. Важно, что это ОТДЕЛЬНЫЙ гейт, а не
        // добавка в excludeKeys: битая копия трека не должна утаскивать за собой живую
        // (в библиотеке лежат и .wav-битый, и .aiff-живой одного и того же трека).
        let unavailable = TrackAvailability.shared.unavailableIDs(in: library)

        // Граф совместности. Для одного сида берём ПОПАРНУЮ силу (она уже нормирована
        // на топ-1% канала), для плейлиста — насыщенный агрегат: у агрегата другая шкала,
        // и подмешивать одну в другую нельзя.
        let graph = CoPlayGraph.shared
        let co: [String: Double] = seeds.count == 1
            ? graph.relatedness(to: seeds[0], library: library,
                                historyWeight: cfg.history_weight,
                                playlistWeight: cfg.playlist_weight)
            : graph.relatedness(toPlaylist: seeds, library: library,
                                historyWeight: cfg.history_weight,
                                playlistWeight: cfg.playlist_weight)

        // Проход 1 — гейты и сырые каналы. Скор здесь ещё не считается: сначала надо
        // увидеть весь пул, чтобы привести каналы к общей шкале (см. ниже).
        struct Cand {
            let track:   Track
            let co:      Double
            let content: Double
            let bpmDelta: Double
            let keyRel:  KeyRel
            let label:   Bool
            let genre:   Bool
            let artist:  Bool
            let duration: Bool
            let known:   Bool
            /// Ключ дубликата — по нему схлопываем повторы уже внутри самой выдачи.
            let dupKey:  String?
            /// «Открытие»: трек НИ РАЗУ не игрался. Ровно тот же признак, по которому
            /// пользователь считает список полезным. play_count и пустая история в
            /// Rekordbox совпадают один-в-один (проверено на живой базе), берём историю.
            let cold:    Bool
        }
        var pool: [Cand] = []
        pool.reserveCapacity(min(tracks.count, 1024))

        for b in tracks {
            if exclude.contains(b.id) { continue }

            // Гейт 0 — файла нет на диске. Проверяем ПЕРВЫМ и до дедупа: битую копию надо
            // выкинуть раньше, чем она успеет «занять» ключ дубликата и вытеснить живую.
            if unavailable.contains(b.id) { continue }

            // Гейт 1 — дубликат того, что уже в плейлисте (тот же трек под другим id).
            let dupKey = TrackIdentity.key(b)
            if let k = dupKey, excludeKeys.contains(k) { continue }

            // Гейт 2 — темп. Абсолютное окно вокруг коридора сид-набора, с half/double.
            guard let bpm = profile.foldedBPM(b.bpm, cfg: cfg) else { continue }

            // Гейт 3 — гармония. Кандидат обязан быть совместим хотя бы с одной
            // тональностью палитры. Нераспознанный ключ гейт НЕ режет (как и раньше).
            let cand = KeyNormalizer.components(b.key)
            let (keyFit, keyRel) = profile.keyAffinity(cand, cfg: cfg)
            if useKey, profile.hasKeys, cand != nil, keyFit <= 0 { continue }

            let labelFit  = profile.labelShare[Self.norm(b.label)] ?? 0
            let genreFit  = profile.genreShare[GenreCanon.canon(b.genre)] ?? 0
            let artistFit = profile.artistShare[Self.norm(b.artist)] ?? 0

            pool.append(Cand(
                track:   b,
                co:      co[b.id] ?? 0,
                content: profile.content(keyFit: useKey ? keyFit : nil,
                                         labelFit: labelFit, genreFit: genreFit,
                                         artistFit: artistFit, cfg: cfg),
                bpmDelta: (abs(bpm - profile.bpmCenter) * 10).rounded() / 10,
                keyRel:  keyRel,
                label:   labelFit  > 0,
                genre:   genreFit  > 0,
                artist:  artistFit > 0,
                duration: profile.durationMatches(b.duration, cfg: cfg),
                known:   graph.knows(b.id),
                dupKey:  dupKey,
                cold:    b.histories.isEmpty))
        }
        guard !pool.isEmpty else { return [] }

        // Приведение каналов к общей шкале — по 99-му перцентилю ПУЛА (тот же приём,
        // которым CoPlayGraph сводит свои два канала).
        //
        // ЗАЧЕМ. content — это ДОЛИ состава («лейбл встречается у 6 сидов из 75»), и они
        // сжимаются как ~1/N: замер на живой библиотеке дал content ∈ [0…0.28] у плейлиста
        // на 75 треков против [0…1] у одного сида, тогда как co живёт в [0…0.6]. Без
        // приведения веса coplay/content означали бы РАЗНОЕ для плейлиста на 5 и на 100
        // треков, а холодные треки (у которых нет co вообще) не могли бы догнать тёплые
        // никогда — при том что по метаданным они, как выяснилось, даже чуть лучше
        // (mean content 0.149 против 0.131).
        //
        // Порог у co (`coScaleFloor`) — предохранитель: если у плейлиста связей почти нет
        // (max co = 0.02), делить на такой перцентиль нельзя, иначе единственная слабая
        // связь раздувается до 1.0 и вылезает на первое место. Ниже порога co НЕ
        // растягивается — «слабо» остаётся «слабо». У content такого порога нет: он
        // определён для каждого трека всегда.
        let coScale      = max(Self.percentile(pool.map { $0.co }, 0.99), Self.coScaleFloor)
        let contentScale = max(Self.percentile(pool.map { $0.content }, 0.99), 0.0001)

        struct Scored {
            let track:   Track
            let score:   MatchScore
            let co:      Double        // СЫРОЕ, не обрезанное — только для тай-брейка
            let content: Double
            let dupKey:  String?
            let cold:    Bool
        }
        var scored: [Scored] = pool.map { c in
            let coHat      = min(1.0, c.co / coScale)
            let contentHat = min(1.0, c.content / contentScale)
            let total = blend(co: coHat, content: contentHat, known: c.known, cfg: cfg)
            return Scored(
                track: c.track,
                score: MatchScore(
                    total:          (total * 10_000).rounded() / 10_000,
                    bpm_delta:      c.bpmDelta,
                    key_relation:   c.keyRel.label,
                    label_match:    c.label,
                    genre_match:    c.genre,
                    artist_match:   c.artist,
                    duration_match: c.duration
                ),
                co: c.co, content: c.content, dupKey: c.dupKey, cold: c.cold)
        }

        // Сортировка БЕЗ ΔBPM: он ничего не различает (75% библиотеки в окне 118–130) и
        // именно он был источником «случайного мусора».
        //
        // Тай-брейк идёт по СЫРЫМ каналам, а не по обрезанным: всё, что сильнее 99-го
        // перцентиля, в скоре схлопнуто в 1.0 (это цена общей шкалы), и без сырых значений
        // порядок на самом верху выдачи решался бы по id. Последний ключ — id: порядок
        // обхода Dictionary в Swift рандомизирован по процессу, и без него выдача гуляла бы
        // между перезапусками агента.
        scored.sort { l, r in
            if l.score.total != r.score.total { return l.score.total > r.score.total }
            if l.co          != r.co          { return l.co > r.co }
            if l.content     != r.content     { return l.content > r.content }
            return l.track.id < r.track.id
        }

        // Дедуп ВНУТРИ выдачи. Обе копии дубля могут лежать вне плейлиста — тогда список
        // показал бы один и тот же трек дважды. Список уже отсортирован, поэтому первая
        // встреченная копия — лучшая.
        var seenDup = Set<String>()
        var unique: [Scored] = []
        unique.reserveCapacity(scored.count)
        for s in scored {
            if let k = s.dupKey, !seenDup.insert(k).inserted { continue }
            unique.append(s)
        }

        let poolSize   = max(limit, cfg.candidate_pool)
        let quotaPer10 = quota ? max(0, min(10, cfg.cold_start_quota_per_10)) : 0

        var base = Array(unique.prefix(poolSize))
        if quotaPer10 > 0 {
            // Холодных в основном пуле может не быть ВОВСЕ: потолок холодного трека
            // (0.5·0.65 + 0.35 = 0.675 против 1.0 у тёплого) на плотных кластерах не даёт
            // ему пролезть никогда. Поэтому кандидатов на квоту добираем из хвоста: они уже
            // прошли гейты по BPM и тональности, а между собой отсортированы по content
            // (у холодного трека total монотонен по content) — то есть это лучшие
            // РЕЛЕВАНТНЫЕ открытия, а не случайные треки. Берём с запасом: часть срежут
            // лимиты «не больше N одного артиста/лейбла».
            let need = (poolSize + 9) / 10 * quotaPer10
            let have = base.reduce(0) { $0 + ($1.cold ? 1 : 0) }
            if have < need {
                base += unique.dropFirst(poolSize).filter { $0.cold }.prefix(2 * (need - have))
            }
        }

        var kept = base, overflow: [Scored] = []
        if diversify {
            (kept, overflow) = splitByDiversity(base, cfg: cfg) {
                (artist: $0.track.artist, label: $0.track.label)
            }
        }
        // Квота — ПОСЛЕ лимитов по артисту/лейблу и только внутри `kept`. Переставлять
        // внутри kept безопасно: лимит там соблюдён на всём списке, а значит и на любом его
        // куске. Тянуть же треки из overflow вперёд нельзя — это и есть нарушение лимита.
        if quotaPer10 > 0 { kept = interleaveCold(kept, quota: quotaPer10) { $0.cold } }
        let ranked = kept + overflow

        let start = min(max(0, offset), ranked.count)
        let end   = min(start + limit, ranked.count)
        guard start < end else { return [] }
        return ranked[start..<end].map { SimilarResult(track: $0.track, score: $0.score) }
    }

    /// Смесь двух путей.
    ///
    /// ПОЧЕМУ ИМЕННО ТАК (холодный старт). У 17% библиотеки co-play == 0 просто потому,
    /// что трек ни разу не игрался и не лежит ни в одном ручном плейлисте — граф о нём
    /// НЕ ЗНАЕТ. Но ровно такой же 0 получает трек, который граф знает отлично и который
    /// с этим плейлистом никак не связан. Это два РАЗНЫХ факта: «нет данных» и «есть
    /// данные, и они против». Складывая их в одну формулу, мы бы навсегда утопили
    /// непроигранные треки — и «новые треки не рекомендуются» стало бы новой жалобой.
    ///
    /// Поэтому для НЕИЗВЕСТНЫХ графу треков co-play не обнуляется, а ИМПУТИРУЕТСЯ из
    /// content-скора с дисконтом `cold_start_backoff` (0.5): это оценка, а не факт, и
    /// стоить она должна вдвое дешевле факта. Итог: холодный трек с идеальным контентом
    /// обгоняет тёплый трек с плохим контентом, но проигрывает тёплому с реальной
    /// историей совместных проигрываний. Ровно то поведение, которого мы хотим.
    private func blend(co: Double, content: Double, known: Bool, cfg: SimilarityConfig) -> Double {
        let wCo = max(0, cfg.coplay_weight)
        let wCt = max(0, cfg.content_weight)
        let norm = wCo + wCt
        guard norm > 0 else { return content }
        let coEff = known ? co : max(0, min(1, cfg.cold_start_backoff)) * content
        return (wCo * coEff + wCt * content) / norm
    }

    /// Разнообразие: не больше `max_per_artist` треков одного артиста и `max_per_label`
    /// одного лейбла. Лишние НЕ выбрасываются, а уезжают в `overflow` — хвост ранжированного
    /// списка. Иначе они пропали бы и из следующих страниц (Refresh), а это потеря кандидатов.
    ///
    /// Возвращает две части раздельно (а не склеенный список) ровно затем, чтобы квота
    /// открытий могла переставлять треки ВНУТРИ `kept`, не втягивая туда `overflow`.
    private func splitByDiversity<T>(_ items: [T], cfg: SimilarityConfig,
                                     keys: (T) -> (artist: String, label: String)) -> ([T], [T]) {
        let artistCap = cfg.max_per_artist
        let labelCap  = cfg.max_per_label
        guard artistCap > 0 || labelCap > 0 else { return (items, []) }

        var artistCount: [String: Int] = [:]
        var labelCount:  [String: Int] = [:]
        var kept: [T] = [], overflow: [T] = []
        kept.reserveCapacity(items.count)

        for it in items {
            let k = keys(it)
            let a = Self.norm(k.artist), l = Self.norm(k.label)
            // Пустой артист/лейбл (тег не заполнен) — не «один и тот же» артист, лимит не применяем.
            let artistOver = artistCap > 0 && !a.isEmpty && (artistCount[a] ?? 0) >= artistCap
            let labelOver  = labelCap  > 0 && !l.isEmpty && (labelCount[l]  ?? 0) >= labelCap
            if artistOver || labelOver {
                overflow.append(it)
            } else {
                if !a.isEmpty { artistCount[a, default: 0] += 1 }
                if !l.isEmpty { labelCount[l,  default: 0] += 1 }
                kept.append(it)
            }
        }
        return (kept, overflow)
    }

    /// КВОТА ОТКРЫТИЙ: в каждой десятке позиций — не меньше `quota` треков, которые никогда
    /// не игрались.
    ///
    /// ПОЧЕМУ КВОТА, А НЕ ВЕС. Холодный трек получает co-play не фактом, а оценкой с
    /// дисконтом, поэтому его потолок структурно ниже тёплого (0.675 против 1.0 при
    /// дефолтном конфиге). На плотных кластерах — а плейлист по определению плотный
    /// кластер — он не пролезает в топ НИКОГДА, и замер это подтвердил: 0 непроигранных
    /// треков в топ-10 при 47% непроигранных в библиотеке. Подкрутка весов лечит симптом
    /// на одном плейлисте и ломает другой; гарантия же формулируется прямо: блок называется
    /// «что ДОБАВИТЬ», значит открытия в нём обязаны БЫТЬ.
    ///
    /// Тёплый порядок при этом не перетасовывается: холодного добираем только тогда, когда
    /// в текущей десятке позиций уже впритык — то есть открытия садятся в хвост десятки, а
    /// топ остаётся за настоящими совпадениями. Квота считается по позиции в РАНЖИРОВАННОМ
    /// списке, а не в странице, поэтому работает и на offset-страницах (вторая десятка —
    /// такая же десятка). Полностью детерминированно: рандома нет.
    private func interleaveCold<T>(_ items: [T], quota: Int, isCold: (T) -> Bool) -> [T] {
        guard quota > 0, !items.isEmpty else { return items }
        let coldIdx = items.indices.filter { isCold(items[$0]) }
        guard !coldIdx.isEmpty else { return items }

        var out: [T] = []
        out.reserveCapacity(items.count)
        var emitted = [Bool](repeating: false, count: items.count)
        var next = 0            // следующий по рангу невыданный
        var cold = 0            // следующий невыданный холодный
        var coldInBlock = 0

        while out.count < items.count {
            let pos = out.count % 10
            if pos == 0 { coldInBlock = 0 }
            while cold < coldIdx.count, emitted[coldIdx[cold]] { cold += 1 }

            let idx: Int
            if quota - coldInBlock >= 10 - pos, cold < coldIdx.count {
                idx = coldIdx[cold]                       // мест в десятке ровно под дефицит
            } else {
                while next < items.count, emitted[next] { next += 1 }
                guard next < items.count else { break }
                idx = next
            }
            emitted[idx] = true
            if isCold(items[idx]) { coldInBlock += 1 }
            out.append(items[idx])
        }
        return out
    }

    private static func norm(_ s: String) -> String {
        s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// Минимальный масштаб co-канала. Ниже него канал НЕ растягивается: у плейлиста,
    /// про который граф почти ничего не знает, единственная слабая связь не должна
    /// превращаться в «сильнейшую связь этого плейлиста» и уезжать на первое место.
    /// Значение — в шкале CoPlayGraph, где 1.0 = связь силы топ-1% канала.
    private static let coScaleFloor = 0.2

    /// p-й перцентиль (без интерполяции). Максимум брать нельзя — это выброс.
    private static func percentile(_ xs: [Double], _ p: Double) -> Double {
        guard !xs.isEmpty else { return 0 }
        let sorted = xs.sorted()
        let idx = min(sorted.count - 1, max(0, Int(Double(sorted.count - 1) * p)))
        return sorted[idx]
    }

    // MARK: - Профиль сид-набора

    /// То, ОТ ЧЕГО считаются рекомендации: темповый коридор, палитра тональностей и
    /// доли лейблов/жанров/артистов во всём составе плейлиста. Строится один раз на запрос.
    ///
    /// Все content-фичи — ДОЛИ сидов (0…1), а не булевы флаги. Это принципиально: булевы
    /// бонусы давали сотни кандидатов с одинаковым total, и порядок внутри них решал ΔBPM,
    /// то есть шум. Доля же различает «лейбл, на котором 15 треков из 40» и «лейбл,
    /// который встретился один раз».
    private struct SeedProfile {
        let count: Int
        let bpmCenter: Double          // медиана темпа (после свёртки half/double)
        let bpmLow:  Double            // p10 − допуск
        let bpmHigh: Double            // p90 + допуск
        let hasBPM: Bool

        /// Слот Camelot (0…23) → доля сидов в этой тональности.
        let keySlots: [Int: Double]
        let hasKeys: Bool

        let labelShare:  [String: Double]
        let genreShare:  [String: Double]
        let artistShare: [String: Double]
        let hasLabels:  Bool
        let hasGenres:  Bool
        let hasArtists: Bool

        let medianDuration: Double?

        init(_ seeds: [Track], cfg: SimilarityConfig) {
            count = seeds.count

            // --- темп -----------------------------------------------------
            let rawBPMs = seeds.map { $0.bpm }.filter { $0 > 0 }.sorted()
            hasBPM = !rawBPMs.isEmpty
            if hasBPM {
                let median0 = rawBPMs[rawBPMs.count / 2]
                // Сначала сворачиваем сами сиды: в плейлисте может лежать и 62, и 124 —
                // без свёртки коридор растянулся бы на всю библиотеку.
                let folded = rawBPMs
                    .map { cfg.bpm_allow_half_double ? SeedProfile.fold($0, toward: median0) : $0 }
                    .sorted()
                let center = folded[folded.count / 2]
                let tol = cfg.bpm_tolerance_abs > 0
                    ? cfg.bpm_tolerance_abs
                    : center * cfg.bpm_tolerance_pct / 100.0
                // p10…p90, а не min…max: один затесавшийся даунтемпо-трек не должен
                // раскрывать коридор всего плейлиста.
                let lo = folded[Int(Double(folded.count - 1) * 0.10)]
                let hi = folded[Int(Double(folded.count - 1) * 0.90 + 0.9999)]
                bpmCenter = center
                bpmLow    = lo - tol
                bpmHigh   = hi + tol
            } else {
                bpmCenter = 0; bpmLow = 0; bpmHigh = 0
            }

            // --- тональности ----------------------------------------------
            var slots: [Int: Double] = [:]
            var keyed = 0
            for t in seeds {
                guard let c = KeyNormalizer.components(t.key) else { continue }
                keyed += 1
                slots[SeedProfile.slot(c), default: 0] += 1
            }
            hasKeys = keyed > 0
            if keyed > 0 { for (k, v) in slots { slots[k] = v / Double(keyed) } }
            keySlots = slots

            // --- лейбл / жанр / артист ------------------------------------
            // Знаменатель — число сидов С ЗАПОЛНЕННЫМ полем, а не весь состав: иначе
            // в плейлисте, где у половины треков нет лейбла, максимум labelFit был бы 0.5.
            labelShare  = SeedProfile.share(seeds.map { SimilarityEngine.norm($0.label) })
            artistShare = SeedProfile.share(seeds.map { SimilarityEngine.norm($0.artist) })
            genreShare  = SeedProfile.share(seeds.map { GenreCanon.canon($0.genre) })
            hasLabels  = !labelShare.isEmpty
            hasArtists = !artistShare.isEmpty
            hasGenres  = !genreShare.isEmpty

            let durs = seeds.compactMap { $0.duration }.filter { $0 > 0 }.sorted()
            medianDuration = durs.isEmpty ? nil : durs[durs.count / 2]
        }

        private static func share(_ values: [String]) -> [String: Double] {
            var counts: [String: Double] = [:]
            var total = 0.0
            for v in values where !v.isEmpty {
                counts[v, default: 0] += 1
                total += 1
            }
            guard total > 0 else { return [:] }
            return counts.mapValues { $0 / total }
        }

        /// Camelot → индекс 0…23 (номер × 2 + сторона). Гистограмма по 24 слотам считается
        /// один раз, поэтому keyAffinity кандидата — это 24 операции, а не проход по всем сидам.
        private static func slot(_ c: KeyNormalizer.Camelot) -> Int {
            (c.number - 1) * 2 + (c.letter == "A" ? 0 : 1)
        }
        private static func unslot(_ s: Int) -> (num: Int, letter: Character) {
            (s / 2 + 1, s % 2 == 0 ? "A" : "B")
        }

        /// Свёртка half/double-time к октаве центра: 62 → 124, 248 → 124. Порог √2 ≈ 1.414 —
        /// естественная граница между «в два раза медленнее» и «просто медленнее».
        static func fold(_ bpm: Double, toward center: Double) -> Double {
            guard bpm > 0, center > 0 else { return bpm }
            var x = bpm
            var guardCount = 0
            while x < center / 1.414 && guardCount < 4 { x *= 2; guardCount += 1 }
            while x > center * 1.414 && guardCount < 8 { x /= 2; guardCount += 1 }
            return x
        }

        /// Гейт по темпу. nil → кандидат отсеян. Иначе — BPM кандидата, свёрнутый в
        /// октаву плейлиста (его же кладём в bpm_delta ответа).
        func foldedBPM(_ bpm: Double, cfg: SimilarityConfig) -> Double? {
            guard bpm > 0 else { return nil }        // трек без темпа не рекомендуем (как и раньше)
            guard hasBPM else { return bpm }         // у сидов нет темпа — гейт нечем применить
            let x = cfg.bpm_allow_half_double ? SeedProfile.fold(bpm, toward: bpmCenter) : bpm
            guard x >= bpmLow, x <= bpmHigh else { return nil }
            return x
        }

        /// Гармоническая близость кандидата к ПАЛИТРЕ тональностей плейлиста: сумма долей
        /// сидов, взвешенная качеством перехода. Для одного сида вырождается ровно в старое
        /// exact/relative/compatible. Возвращает и лучшее отношение — для поля key_relation.
        func keyAffinity(_ cand: KeyNormalizer.Camelot?, cfg: SimilarityConfig) -> (Double, KeyRel) {
            guard let c = cand, hasKeys else { return (0, .unknown) }
            var fit = 0.0
            var best = KeyRel.incompatible
            for (s, share) in keySlots {
                let (num, letter) = SeedProfile.unslot(s)
                let diff  = abs(num - c.number)
                let steps = min(diff, 12 - diff)
                let rel: KeyRel
                if num == c.number && letter == c.letter      { rel = .exact }
                else if num == c.number                       { rel = .relative }
                else if letter == c.letter && steps <= cfg.key_max_steps { rel = .compatible }
                else                                          { rel = .incompatible }
                fit += rel.affinity * share
                if rel.rank > best.rank { best = rel }
            }
            return (fit, best)
        }

        /// Content-скор в [0…1]: взвешенное среднее активных фич. Признак, который в этом
        /// плейлисте не может сработать (например, ни у одного сида не заполнен лейбл),
        /// из знаменателя ИСКЛЮЧАЕТСЯ — иначе он молча штрафовал бы всех кандидатов разом.
        func content(keyFit: Double?, labelFit: Double, genreFit: Double, artistFit: Double,
                     cfg: SimilarityConfig) -> Double {
            let w = cfg.weights
            var num = 0.0, den = 0.0
            if let k = keyFit, hasKeys, w.key > 0    { num += w.key    * k;         den += w.key }
            if hasLabels,  w.label  > 0              { num += w.label  * labelFit;  den += w.label }
            if hasGenres,  w.genre  > 0              { num += w.genre  * genreFit;  den += w.genre }
            if hasArtists, w.artist > 0              { num += w.artist * artistFit; den += w.artist }
            guard den > 0 else { return 0 }
            return min(1.0, num / den)
        }

        /// Информационный флаг (в скор не входит): длина кандидата в окне от медианы состава.
        func durationMatches(_ d: Double?, cfg: SimilarityConfig) -> Bool {
            guard let d = d, d > 0, let m = medianDuration, m > 0 else { return false }
            return abs(d - m) / m <= cfg.duration_tolerance_pct / 100.0
        }
    }

    // MARK: - Гармоническое отношение

    enum KeyRel {
        case exact        // та же тональность
        case relative     // тот же номер, другая сторона колеса (параллельный мажор/минор)
        case compatible   // та же сторона, в пределах key_max_steps по колесу
        case incompatible
        case unknown      // ключ не распознан — НЕ повод отсеивать кандидата

        var label: String {
            switch self {
            case .exact:        return "exact"
            case .relative:     return "relative"
            case .compatible:   return "compatible"
            case .incompatible: return "incompatible"
            case .unknown:      return "—"
            }
        }

        /// Вклад в keyFit. Точное совпадение — эталон перехода; параллельная тональность
        /// почти так же хороша; соседняя по колесу — рабочий, но заметно более слабый ход.
        var affinity: Double {
            switch self {
            case .exact:      return 1.0
            case .relative:   return 0.7
            case .compatible: return 0.5
            default:          return 0.0
            }
        }

        var rank: Int {
            switch self {
            case .exact:        return 4
            case .relative:     return 3
            case .compatible:   return 2
            case .unknown:      return 1
            case .incompatible: return 0
            }
        }
    }
}
