import Foundation

// В библиотеке 60 сырых написаний жанра на ~8 реальных корзин: "Afro House" / "Afro-House" /
// "AfroHouse", "Хаус" (кириллица!) / "House", "Organic House" / "Organic House / Downtempo".
// Сырое сравнение строк (a.lowercased() == b.lowercased()) считает их РАЗНЫМИ жанрами,
// т.е. жанровый бонус в скоринге просто не срабатывает на половине совпадений.
//
// Ключ поиска — «сплющенное» написание: только буквы и цифры, lowercase. Поэтому одна
// строка таблицы закрывает сразу "Afro House", "Afro-House", "AfroHouse", "afro  house".

enum GenreCanon {

    /// Сплющенный алиас → каноническая корзина. Таблица собрана по реальным 59
    /// написаниям библиотеки, а не «на будущее»: незнакомый жанр НЕ схлопывается
    /// насильно, он остаётся собой (см. fallback в `canon`).
    private static let aliases: [String: String] = [
        // afro                      "Afro House", "Afro-House", "AfroHouse", "AFRO HOUSE "
        "afrohouse":               "afro_house",
        "afro":                    "afro_house",   // "Afro / Latin / Brazilian"
        "afrotech":                "afro_house",
        // house                     "House", "Хаус"
        "house":                   "house",
        "хаус":                    "house",
        // organic                   "Organic House", "Organic House / Downtempo"
        "organic":                 "organic",
        "organichouse":            "organic",
        "organichousedowntempo":   "organic",
        // hip-hop                   "Hip-Hop", "Hip Hop/Rap"
        "hiphop":                  "hiphop",
        "hiphoprap":               "hiphop",
        "rap":                     "hiphop",
        // melodic                   "Melodic House & Techno", "Melodic Techno"
        "melodichousetechno":      "melodic",
        "melodichouseandtechno":   "melodic",
        "melodichouse":            "melodic",
        "melodictechno":           "melodic",
        // tech house                "Tech House", "Tech House / Breakbeat"
        "techhouse":               "tech_house",
        // minimal                   "Minimal / Deep Tech", "Minimal/tech house", "Minimal"
        "minimal":                 "minimal",
        "minimaldeeptech":         "minimal",
        "deeptech":                "minimal",
        // deep house
        "deephouse":               "deep_house",
        // indie dance               "Indie Dance" (+ составное имя Beatport)
        "indiedance":              "indie_dance",
        "indiedancenudisco":       "indie_dance",
        // кириллица — прямые переводы, встречаются в тегах
        "поп":                     "pop",
        "электронная":             "electronic",
    ]

    /// Ключ сравнения: каноническая корзина, либо — для незнакомого жанра —
    /// нормализованный lowercase (жанр не теряем, просто сравниваем аккуратно).
    /// Пустой/мусорный вход → "" (вызывающий обязан считать это «нет жанра»).
    static func canon(_ raw: String) -> String {
        let flat = flatten(raw)
        guard !flat.isEmpty else { return "" }
        if let bucket = aliases[flat] { return bucket }

        // Несколько жанров в одном поле ("House, Tech House", "Tech House / Breakbeat",
        // "Minimal/tech house") — основной жанр ПЕРВЫЙ. Составные имена Beatport
        // ("Minimal / Deep Tech", "Organic House / Downtempo") сюда не доходят: они
        // уже совпали целиком строчкой выше.
        if let head = raw.split(whereSeparator: { ",;/".contains($0) }).first {
            let headFlat = flatten(String(head))
            if !headFlat.isEmpty, let bucket = aliases[headFlat] { return bucket }
        }

        return normalized(raw)
    }

    /// Совпадение жанров с учётом канонизации. Пустой жанр не совпадает ни с чем,
    /// включая другой пустой.
    static func same(_ a: String, _ b: String) -> Bool {
        let x = canon(a)
        let y = canon(b)
        return !x.isEmpty && x == y
    }

    // MARK: - Нормализация

    /// Только буквы и цифры, lowercase: "Afro-House" и "AfroHouse" → "afrohouse".
    /// Кириллица сохраняется (isLetter юникод-осведомлён), поэтому "Хаус" → "хаус".
    private static func flatten(_ raw: String) -> String {
        String(raw.lowercased().unicodeScalars.filter {
            CharacterSet.alphanumerics.contains($0)
        })
    }

    /// Читаемый lowercase для незнакомых жанров: пунктуация → пробел, пробелы схлопнуты.
    /// "Progressive-House" и "Progressive House" дадут один ключ.
    private static func normalized(_ raw: String) -> String {
        let separators = CharacterSet(charactersIn: "-_/\\&,.|+()[]").union(.whitespacesAndNewlines)
        return raw.lowercased()
            .components(separatedBy: separators)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}
