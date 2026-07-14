import Foundation

// Граф совместности треков — «что с чем реально играется/лежит вместе».
//
// Два независимых канала, оба строятся из уже разобранной библиотеки (LibraryData):
//
//   1) HISTORY — упорядоченные сеты Rekordbox (djmdHistory). У трека есть
//      history_indices["hist:<id>"] = TrackNo, то есть позиция в сете. Соседние
//      позиции = реальный, проверенный человеком переход. Это сильнейший сигнал
//      в библиотеке, и до сих пор он не использовался вообще.
//
//   2) PLAYLIST — co-occurrence в РУЧНЫХ плейлистах (playlist_indices). SMART-
//      плейлисты исключены намеренно: их состав порождён правилом («genre = Afro
//      House»), учиться на них = переучивать модель на тот же жанровый фильтр,
//      который мы и пытаемся заменить. Канал важен потому, что покрывает те треки,
//      которых нет в истории (никогда не игрались).
//
// Оба канала дают ЧИСЛО в [0…1] на пару треков; шкалы каналов приведены друг к
// другу нормировкой по 99-му перцентилю (см. `rescale`), поэтому их можно
// складывать с весами.
//
// Класс не знает ни про SimilarityEngine, ни про HTTP: чистая функция от LibraryData.
final class CoPlayGraph {
    static let shared = CoPlayGraph()
    private init() {}

    // MARK: - Параметры (осознанные константы, не конфиг)

    /// Сессии короче этого — мусор: Rekordbox сам режет историю на огрызки
    /// (открыл деку, дёрнул трек, закрыл). На реальной библиотеке отсечение
    /// оставляет ~60% сессий, но ~90% переходов.
    static let minSessionTracks = 10

    /// Окно соседства в сете: вес по смещению позиции. [0] — прямой сосед (i,i+1),
    /// [1] — «через один». Треки через один тоже связаны (диджей уже был в этой
    /// зоне вечера), но втрое слабее.
    static let neighborWeights: [Double] = [1.0, 0.4]

    /// Демпфер редких пар (shrinkage). Косинус сам по себе даёт 1.0 паре, которая
    /// встретилась ОДИН раз у двух треков, больше нигде не игравшихся, — это
    /// переоценка одиночного наблюдения. Множитель c/(c+k) гасит такие пары:
    /// одно соседство → ×0.5, три → ×0.75.
    static let historyShrinkK  = 1.0
    /// Для плейлистов вклад пары дробный (1/(n-1)), поэтому и k меньше.
    static let playlistShrinkK = 0.25

    /// Плейлисты-свалки (архив/«всё подряд») кураторским сигналом не являются и
    /// дают квадратичный взрыв пар. На реальной библиотеке максимум — 136 треков.
    static let maxManualPlaylistSize = 400

    /// Верхняя граница строки графа. Хвост слабых связей не влияет на топ-50, но
    /// удваивает память на хабах.
    static let maxNeighbors = 250

    /// Веса каналов по умолчанию. История точнее (это ФАКТ проигрывания), но
    /// покрывает ~53% библиотеки; плейлисты слабее, зато покрывают ~81%.
    static let defaultHistoryWeight  = 1.0
    static let defaultPlaylistWeight = 0.6

    /// Полунасыщение агрегата по плейлисту: raw=2.0 → 0.5. Насыщающая нормировка
    /// (raw/(raw+h)) монотонна, поэтому НЕ меняет ранжирование, но держит выход в
    /// (0…1) независимо от размера плейлиста — иначе плейлист на 200 треков давал
    /// бы кандидатов со скором 15, а на 5 треков — 0.3, и общий вес графа в
    /// SimilarityEngine пришлось бы подбирать под каждый размер.
    static let playlistHalfSaturation = 2.0

    /// Предохранитель: у совсем гигантских плейлистов берём каждый k-й трек как сид.
    static let maxSeeds = 500

    // MARK: - Состояние

    struct Stats: Codable {
        var tracks:           Int
        var sessionsTotal:    Int      // сессий в истории всего
        var sessionsUsed:     Int      // из них >= minSessionTracks
        var historyPairs:     Int      // уникальных пар A–B (симметричных)
        var manualPlaylists:  Int      // ручных непустых плейлистов
        var playlistPairs:    Int
        var historyCoverage:  Int      // треков с хотя бы одной связью по истории
        var playlistCoverage: Int
        var coldTracks:       Int      // ни истории, ни ручных плейлистов
        var buildMs:          Double
        var version:          String
    }

    private let lock = NSLock()

    private var version   = ""
    private var ids:      [String] = []
    private var indexOf:  [String: Int] = [:]
    /// Нормированные строки графа: rows[i][j] = сила связи i↔j в [0…1].
    private var histRows: [[Int: Double]] = []
    private var histNext: [[Int: Double]] = []   // направленная A→B (что играют ПОСЛЕ A)
    private var plRows:   [[Int: Double]] = []
    private var lastStats: Stats?

    // MARK: - Публичный API

    /// Ключ версии графа = ключ кэша парсера. `xml_date` — это mtime master.db
    /// (max по db/-wal), см. RekordboxParser.dbMtime. Значит граф протухает ровно
    /// тогда, когда протухает кэш парса, и не пересобирается, пока библиотека не
    /// изменилась.
    static func versionKey(_ lib: LibraryData) -> String {
        "\(lib.xml_date)|\(lib.tracks.count)|\(lib.playlists.count)"
    }

    /// Ленивая сборка: no-op, если граф уже построен на этой версии библиотеки.
    @discardableResult
    func ensureBuilt(from lib: LibraryData) -> Stats {
        let key = CoPlayGraph.versionKey(lib)
        lock.lock()
        if version == key, let s = lastStats { lock.unlock(); return s }
        let s = build(lib, key: key)          // строим под тем же локом: параллельные
        lock.unlock()                         // запросы не должны строить дважды
        return s
    }

    func invalidate() {
        lock.lock()
        version = ""; ids = []; indexOf = [:]
        histRows = []; histNext = []; plRows = []
        lastStats = nil
        lock.unlock()
    }

    func stats() -> Stats? {
        lock.lock(); defer { lock.unlock() }
        return lastStats
    }

    /// Знает ли граф этот трек хоть что-нибудь (не «холодный» ли он).
    func knows(_ trackID: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard let i = indexOf[trackID] else { return false }
        return !histRows[i].isEmpty || !plRows[i].isEmpty
    }

    /// Связность одного трека: кандидат → сила в [0…1] (сумма каналов, приведённая
    /// к единице). Пустой словарь = граф про этот трек ничего не знает.
    func relatedness(to trackID: String,
                     historyWeight: Double = CoPlayGraph.defaultHistoryWeight,
                     playlistWeight: Double = CoPlayGraph.defaultPlaylistWeight) -> [String: Double] {
        lock.lock(); defer { lock.unlock() }
        guard let i = indexOf[trackID] else { return [:] }
        let norm = max(historyWeight + playlistWeight, 0.0001)
        var out = [String: Double](minimumCapacity: histRows[i].count + plRows[i].count)
        for (j, v) in histRows[i] { out[ids[j]] = v * historyWeight / norm }
        for (j, v) in plRows[i]   { out[ids[j], default: 0] += v * playlistWeight / norm }
        return out
    }

    /// Агрегат по всему составу плейлиста: кандидат → сила в (0…1).
    /// Сами члены плейлиста из выдачи исключены. Ранжирование = ранжирование по
    /// сырой сумме (нормировка монотонна), значение — сравнимо между плейлистами.
    func relatedness(toPlaylist trackIDs: [String],
                     historyWeight: Double = CoPlayGraph.defaultHistoryWeight,
                     playlistWeight: Double = CoPlayGraph.defaultPlaylistWeight) -> [String: Double] {
        let raw = rawRelatedness(toPlaylist: trackIDs,
                                 historyWeight: historyWeight, playlistWeight: playlistWeight)
        guard !raw.isEmpty else { return [:] }
        let h = CoPlayGraph.playlistHalfSaturation
        var out = [String: Double](minimumCapacity: raw.count)
        for (id, v) in raw { out[id] = v / (v + h) }
        return out
    }

    /// Сырая сумма вкладов сидов (не насыщена). Полезна для диагностики и для
    /// потребителя, которому нужна «поддержка» кандидата, а не шкала.
    func rawRelatedness(toPlaylist trackIDs: [String],
                        historyWeight: Double = CoPlayGraph.defaultHistoryWeight,
                        playlistWeight: Double = CoPlayGraph.defaultPlaylistWeight) -> [String: Double] {
        lock.lock(); defer { lock.unlock() }
        guard !ids.isEmpty else { return [:] }

        var seedIdx: [Int] = []
        var member = Set<Int>()
        for id in trackIDs {
            guard let i = indexOf[id] else { continue }
            if member.insert(i).inserted { seedIdx.append(i) }
        }
        guard !seedIdx.isEmpty else { return [:] }
        seedIdx = sample(seedIdx, max: CoPlayGraph.maxSeeds)

        var acc = [Int: Double]()
        for i in seedIdx {
            for (j, v) in histRows[i] where !member.contains(j) {
                acc[j, default: 0] += v * historyWeight
            }
            for (j, v) in plRows[i] where !member.contains(j) {
                acc[j, default: 0] += v * playlistWeight
            }
        }
        var out = [String: Double](minimumCapacity: acc.count)
        for (j, v) in acc { out[ids[j]] = v }
        return out
    }

    // Удобные обёртки: сами гарантируют сборку графа на актуальной версии
    // библиотеки. Рекомендуемая точка входа для SimilarityEngine — забыть
    // ensureBuilt и молча получить пустой граф так нельзя.

    func relatedness(to trackID: String, library: LibraryData,
                     historyWeight: Double = CoPlayGraph.defaultHistoryWeight,
                     playlistWeight: Double = CoPlayGraph.defaultPlaylistWeight) -> [String: Double] {
        ensureBuilt(from: library)
        return relatedness(to: trackID, historyWeight: historyWeight, playlistWeight: playlistWeight)
    }

    func relatedness(toPlaylist trackIDs: [String], library: LibraryData,
                     historyWeight: Double = CoPlayGraph.defaultHistoryWeight,
                     playlistWeight: Double = CoPlayGraph.defaultPlaylistWeight) -> [String: Double] {
        ensureBuilt(from: library)
        return relatedness(toPlaylist: trackIDs, historyWeight: historyWeight, playlistWeight: playlistWeight)
    }

    /// Направленный канал: что по истории играют ПОСЛЕ этого трека. Для «добавить
    /// в плейлист» не нужен, но это тот же граф, и он нужен для «что поставить
    /// следующим» — отдаём отдельно, чтобы не смешивать с симметричной близостью.
    func successors(of trackID: String) -> [String: Double] {
        lock.lock(); defer { lock.unlock() }
        guard let i = indexOf[trackID] else { return [:] }
        var out = [String: Double](minimumCapacity: histNext[i].count)
        for (j, v) in histNext[i] { out[ids[j]] = v }
        return out
    }

    // MARK: - Сборка

    /// Вызывается под локом.
    private func build(_ lib: LibraryData, key: String) -> Stats {
        let t0 = Date()
        let tracks = lib.tracks
        let n = tracks.count

        ids = tracks.map { $0.id }
        indexOf = [String: Int](minimumCapacity: n)
        for (i, t) in tracks.enumerated() { indexOf[t.id] = i }

        // --- Канал 1: история сетов ---------------------------------------

        var sessions: [String: [(no: Int, idx: Int)]] = [:]
        for (i, t) in tracks.enumerated() {
            for (path, no) in t.history_indices {
                sessions[path, default: []].append((no, i))
            }
        }

        var histC = [[Int: Double]](repeating: [:], count: n)   // симметричные веса
        var histD = [[Int: Double]](repeating: [:], count: n)   // направленные A→B
        var sessionsUsed = 0

        for (_, rows) in sessions {
            guard rows.count >= CoPlayGraph.minSessionTracks else { continue }
            sessionsUsed += 1
            let seq = rows.sorted { $0.no < $1.no }.map { $0.idx }
            for i in seq.indices {
                for d in 1...CoPlayGraph.neighborWeights.count {
                    let j = i + d
                    guard j < seq.count else { break }
                    let a = seq[i], b = seq[j]
                    guard a != b else { continue }   // трек могли поставить дважды за сет
                    let w = CoPlayGraph.neighborWeights[d - 1]
                    histC[a][b, default: 0] += w
                    histC[b][a, default: 0] += w
                    histD[a][b, default: 0] += w
                }
            }
        }

        // Нормировка по популярности. Берём косинус (association strength):
        //     sim(A,B) = c(A,B) / sqrt(deg(A) * deg(B))
        // где deg — суммарный вес соседств трека. Трек, который стоит в каждом
        // сете, имеет огромный deg, и его связи автоматически обесцениваются —
        // иначе он бы «похож на всё».
        // Почему не PMI: PMI взрывается на редких парах (два трека, сыгранных
        // рядом ровно один раз, получают максимальный балл) и требует отдельного
        // порога по частоте. Косинус деградирует плавно, а одиночные наблюдения
        // додавливаем shrinkage-множителем c/(c+k).
        let histDeg = histC.map { $0.values.reduce(0, +) }
        var histScore = [[Int: Double]](repeating: [:], count: n)
        var histSamples: [Double] = []
        histSamples.reserveCapacity(4096)
        for a in 0..<n {
            guard histDeg[a] > 0 else { continue }
            var row = [Int: Double](minimumCapacity: histC[a].count)
            for (b, c) in histC[a] {
                guard histDeg[b] > 0 else { continue }
                let cosine = c / (histDeg[a] * histDeg[b]).squareRoot()
                let shrink = c / (c + CoPlayGraph.historyShrinkK)
                let s = cosine * shrink
                guard s > 0 else { continue }
                row[b] = s
                if a < b { histSamples.append(s) }   // уникальные пары для перцентиля
            }
            histScore[a] = row
        }
        let histPairs = histSamples.count
        rescale(&histScore, samples: histSamples)

        // Направленный канал — та же формула, но по out/in-степеням.
        var outDeg = [Double](repeating: 0, count: n)
        var inDeg  = [Double](repeating: 0, count: n)
        for a in 0..<n {
            for (b, c) in histD[a] { outDeg[a] += c; inDeg[b] += c }
        }
        var dirScore = [[Int: Double]](repeating: [:], count: n)
        var dirSamples: [Double] = []
        for a in 0..<n where outDeg[a] > 0 {
            var row = [Int: Double](minimumCapacity: histD[a].count)
            for (b, c) in histD[a] {
                guard inDeg[b] > 0 else { continue }
                let s = (c / (outDeg[a] * inDeg[b]).squareRoot()) * (c / (c + CoPlayGraph.historyShrinkK))
                guard s > 0 else { continue }
                row[b] = s
                dirSamples.append(s)
            }
            dirScore[a] = row
        }
        rescale(&dirScore, samples: dirSamples)

        // --- Канал 2: co-occurrence в РУЧНЫХ плейлистах ---------------------

        // Ручной = не папка, не smart, не история. Хелпер отдаёт is_smart/is_folder,
        // legacy-`smart` дублирует is_smart — проверяем оба, чтобы старый кэш парса
        // тоже фильтровался правильно.
        var manualPaths = Set<String>()
        for pl in lib.playlists {
            if pl.history == true || pl.is_folder == true || pl.is_smart == true || pl.smart == true { continue }
            manualPaths.insert(pl.path)
        }

        var members: [String: [Int]] = [:]
        for (i, t) in tracks.enumerated() {
            for p in t.playlists where manualPaths.contains(p) {
                members[p, default: []].append(i)
            }
        }

        var plC = [[Int: Double]](repeating: [:], count: n)
        var manualUsed = 0
        for (_, m) in members {
            let size = m.count
            guard size >= 2, size <= CoPlayGraph.maxManualPlaylistSize else { continue }
            manualUsed += 1
            // Гашение размером: каждый трек раздаёт РОВНО единицу веса своим
            // соседям по плейлисту → пара из плейлиста на 12 весит 1/11 = 0.091,
            // а из плейлиста на 100 — 1/99 = 0.010 (в 9 раз меньше). Побочный
            // приятный эффект: deg(X) в этом канале ≈ числу плейлистов с X,
            // поэтому косинус ниже читается как «доля общих плейлистов».
            let w = 1.0 / Double(size - 1)
            for x in 0..<size {
                let a = m[x]
                for y in (x + 1)..<size {
                    let b = m[y]
                    plC[a][b, default: 0] += w
                    plC[b][a, default: 0] += w
                }
            }
        }

        let plDeg = plC.map { $0.values.reduce(0, +) }
        var plScore = [[Int: Double]](repeating: [:], count: n)
        var plSamples: [Double] = []
        plSamples.reserveCapacity(1 << 16)
        for a in 0..<n {
            guard plDeg[a] > 0 else { continue }
            var row = [Int: Double](minimumCapacity: plC[a].count)
            for (b, c) in plC[a] {
                guard plDeg[b] > 0 else { continue }
                let s = (c / (plDeg[a] * plDeg[b]).squareRoot()) * (c / (c + CoPlayGraph.playlistShrinkK))
                guard s > 0 else { continue }
                row[b] = s
                if a < b { plSamples.append(s) }
            }
            plScore[a] = row
        }
        let plPairs = plSamples.count
        rescale(&plScore, samples: plSamples)

        // --- Обрезка хвостов и публикация -----------------------------------

        prune(&histScore)
        prune(&dirScore)
        prune(&plScore)

        histRows = histScore
        histNext = dirScore
        plRows   = plScore
        version  = key

        var histCov = 0, plCov = 0, cold = 0
        for i in 0..<n {
            let h = !histRows[i].isEmpty
            let p = !plRows[i].isEmpty
            if h { histCov += 1 }
            if p { plCov += 1 }
            if !h && !p { cold += 1 }
        }

        let s = Stats(
            tracks: n,
            sessionsTotal: sessions.count,
            sessionsUsed: sessionsUsed,
            historyPairs: histPairs,
            manualPlaylists: manualUsed,
            playlistPairs: plPairs,
            historyCoverage: histCov,
            playlistCoverage: plCov,
            coldTracks: cold,
            buildMs: (Date().timeIntervalSince(t0) * 1000 * 100).rounded() / 100,
            version: key
        )
        lastStats = s
        return s
    }

    // MARK: - Хелперы

    /// Приводим канал к общей шкале: делим на 99-й перцентиль его же пар и режем
    /// по 1.0. Медиану/максимум брать нельзя: максимум — это выброс (одна пара
    /// «два трека, игравшихся только друг с другом»), он бы прижал весь канал к
    /// нулю. После этого 1.0 читается одинаково в обоих каналах: «связь силы
    /// топ-1% в своём канале», и каналы можно складывать с весами.
    private func rescale(_ rows: inout [[Int: Double]], samples: [Double]) {
        guard !samples.isEmpty else { return }
        let scale: Double
        if samples.count < 20 {
            scale = samples.max() ?? 1
        } else {
            let sorted = samples.sorted()
            scale = sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.99))]
        }
        guard scale > 0 else { return }
        // Округление до 1e-6 — не косметика: степени треков считаются суммой по
        // словарю, а порядок обхода Dictionary в Swift зависит от seed процесса.
        // Без округления скоры гуляли бы в 16-м знаке между перезапусками агента и
        // ничьи в топе схлопывались бы по-разному. Округлили — выдача бит-в-бит
        // одинаковая.
        for a in rows.indices where !rows[a].isEmpty {
            rows[a] = rows[a].mapValues { (min(1.0, $0 / scale) * 1_000_000).rounded() / 1_000_000 }
        }
    }

    private func prune(_ rows: inout [[Int: Double]]) {
        for a in rows.indices where rows[a].count > CoPlayGraph.maxNeighbors {
            let top = rows[a].sorted { $0.value > $1.value }.prefix(CoPlayGraph.maxNeighbors)
            rows[a] = Dictionary(uniqueKeysWithValues: top.map { ($0.key, $0.value) })
        }
    }

    /// Детерминированная выборка каждого k-го — стабильна между запросами.
    private func sample(_ xs: [Int], max limit: Int) -> [Int] {
        guard xs.count > limit, limit > 0 else { return xs }
        let step = Int((Double(xs.count) / Double(limit)).rounded(.up))
        var out: [Int] = []
        var i = 0
        while i < xs.count { out.append(xs[i]); i += step }
        return out
    }
}
