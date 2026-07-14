import Foundation

// «Тот же самый трек», импортированный в библиотеку дважды с разными ID: одна и та же
// запись, отличаются только теги (у одной копии пустой лейбл, у другой заполнен).
// Исключение кандидатов ТОЛЬКО по id такой дубль не ловит — и движок предлагал добавить
// в плейлист то, что в нём уже лежит. На реальной библиотеке (2280 треков) это 26 групп
// дублей и первые же позиции выдачи.
//
// Ключ «та же запись» = нормализованный СОСТАВ артистов + нормализованный тайтл.
//
// ГРАНИЦА, которую нельзя перейти. Схлопывать разрешено только маркеры «та же версия»
// ((Extended Mix), (Original Mix), (Radio Edit), «- Extended», (Ext)) и featuring-хвосты.
// Имя ремиксера — часть произведения: "(Peggy Gou Remix)" и "(Jack Back Remix)" — РАЗНЫЕ
// треки, и предлагать их к плейлисту, где лежит оригинал, совершенно законно. Поэтому
// список нейтральных маркеров ЗАКРЫТЫЙ (белый список сегментов целиком), а не эвристика
// «выкинуть всё, что в скобках».
enum TrackIdentity {

    /// Сегмент скобок или dash-хвоста, который означает «та же самая запись, просто
    /// стандартная форма релиза». Сравнение по сплющенному виду, поэтому одна строка
    /// закрывает "(Extended Mix)", "(extended mix)", "[EXTENDED  MIX]".
    private static let neutralMarkers: Set<String> = [
        "extended", "extendedmix", "extendedversion", "extendededit", "ext", "extmix",
        "original", "originalmix", "originalversion",
        "radio", "radioedit", "radiomix", "radioversion",
    ]

    /// Слова-разделители соавторства ВНУТРИ поля артиста. Ищутся как отдельное слово —
    /// иначе "feat" порезало бы "Featherstone". "and" сюда НЕ входит намеренно: это
    /// живое слово внутри имён ("Above and Beyond"), а реальные теги соавторства в
    /// Rekordbox идут через запятую или &.
    private static let artistJoiners: Set<String> = ["feat", "ft", "featuring", "vs", "x"]

    /// Ключ дубликата, либо nil — когда опознавать нечем (пустой тайтл). Трек без тайтла
    /// дублем НЕ считаем: иначе все безымянные схлопнулись бы в один.
    static func key(artist: String, title: String) -> String? {
        let (parts, feats) = parseTitle(title)
        let t = parts.map(flatten).joined()
        guard !t.isEmpty else { return nil }

        // Артисты — МНОЖЕСТВО, а не строка: "Rafael, Mita Gami" и "Mita Gami & Rafael" —
        // один и тот же дуэт, поэтому имена сортируются. Featured-артисты из тайтла
        // переезжают сюда же: "A - Song (feat. B)" и "A, B - Song" — одна запись.
        var seen = Set<String>()
        let names = (splitArtists(artist) + feats)
            .map(flatten)
            .filter { !$0.isEmpty && seen.insert($0).inserted }
            .sorted()
        return names.joined(separator: "&") + "|" + t
    }

    static func key(_ track: Track) -> String? {
        key(artist: track.artist, title: track.title)
    }

    // MARK: - Тайтл

    /// Тайтл → (значимые куски, featured-артисты). Значимые куски — это ядро названия
    /// и всё, что не входит в белый список нейтральных маркеров (в первую очередь имя
    /// ремиксера). Скобки и dash-хвосты разбираются одинаково, поэтому
    /// "Song (Peggy Gou Remix)" и "Song - Peggy Gou Remix" дают один ключ.
    private static func parseTitle(_ raw: String) -> (parts: [String], feats: [String]) {
        var bare = ""
        var brackets: [String] = []
        var buf = ""
        var depth = 0

        for ch in raw {
            switch ch {
            case "(", "[":
                if depth == 0 { buf = "" } else { buf.append(ch) }
                depth += 1
            case ")", "]":
                if depth == 1 { brackets.append(buf); buf = "" }
                else if depth > 1 { buf.append(ch) }
                depth = max(0, depth - 1)
            default:
                if depth > 0 { buf.append(ch) } else { bare.append(ch) }
            }
        }
        if depth > 0, !buf.isEmpty { brackets.append(buf) }   // незакрытая скобка в теге

        var parts: [String] = []
        var feats: [String] = []

        for (i, chunk) in splitDashes(bare).enumerated() {
            let t = chunk.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !t.isEmpty else { continue }
            if i == 0 { parts.append(t); continue }            // ядро тайтла — всегда значимо
            if let f = featNames(t) { feats += f; continue }
            if neutralMarkers.contains(flatten(t)) { continue }
            parts.append(t)
        }
        for seg in brackets {
            let t = seg.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !t.isEmpty else { continue }
            if let f = featNames(t) { feats += f; continue }
            if neutralMarkers.contains(flatten(t)) { continue }
            parts.append(t)
        }
        return (parts, feats)
    }

    /// Режем только dash с пробелами (" - ", " – ", " — "): дефис внутри слова
    /// ("Hip-Hop", "Re-Work") разделителем не является.
    private static func splitDashes(_ s: String) -> [String] {
        var out = [s]
        for sep in [" - ", " – ", " — ", " -- "] {
            out = out.flatMap { $0.components(separatedBy: sep) }
        }
        return out
    }

    /// Сегмент вида "feat. Someone" → имена. nil — сегмент не про featuring.
    private static func featNames(_ segment: String) -> [String]? {
        let low = segment.lowercased()
        for p in ["featuring ", "feat. ", "feat ", "ft. ", "ft ", "featuring", "feat.", "ft."] where low.hasPrefix(p) {
            return splitArtists(String(segment.dropFirst(p.count)))
        }
        return nil
    }

    // MARK: - Артисты

    private static let artistSeparators = CharacterSet(charactersIn: ",&;/+")

    private static func splitArtists(_ raw: String) -> [String] {
        raw.components(separatedBy: artistSeparators)
            .flatMap(splitJoiners)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    /// "Rafael feat. Mita Gami" → ["Rafael", "Mita Gami"]: featured-артист — тоже артист,
    /// и в другой копии того же трека он вполне может стоять просто через запятую.
    private static func splitJoiners(_ s: String) -> [String] {
        var out: [String] = []
        var cur: [Substring] = []
        for w in s.split(separator: " ") {
            if artistJoiners.contains(flatten(String(w))) {
                out.append(cur.joined(separator: " ")); cur = []
            } else {
                cur.append(w)
            }
        }
        out.append(cur.joined(separator: " "))
        return out
    }

    // MARK: - Нормализация

    /// Только буквы и цифры, lowercase: регистр, пробелы и пунктуация из ключа уходят.
    /// Юникод-осведомлён, поэтому кириллица в тегах не теряется.
    private static func flatten(_ raw: String) -> String {
        String(raw.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) })
    }
}
