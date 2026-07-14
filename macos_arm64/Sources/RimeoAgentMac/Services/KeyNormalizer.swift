import Foundation

// Тональность в master.db (djmdKey.ScaleName) приходит в ДВУХ нотациях вперемешку:
// Camelot ("9A", "12B") и классика ("Am", "F#m", "C", "Db"). Старый parseCamelot
// понимал только Camelot → у ~47% библиотеки key_relation == .unknown, и гармонический
// фильтр для них молча выключался. Этот нормализатор приводит ЛЮБОЕ написание к Camelot.
//
// Считаем через pitch class (0–11), а не по таблице написаний: это бесплатно решает
// энгармонику (C#m == Dbm == 12A, F#m == Gbm == 11A, G#m == Abm == 1A) и редкие
// написания (Cb, E#), которых нет в таблице iOS-конвертера.
// Порт логики Rimeo/KeyFormat.swift (KeyFormatter) — результаты совпадают на всех 24 ключах.

enum KeyNormalizer {

    /// Camelot-код: номер на колесе (1…12) + сторона (A = minor, B = major).
    struct Camelot: Equatable {
        let number: Int
        let letter: Character   // "A" | "B"

        var text: String { "\(number)\(letter)" }
    }

    // pitch class → номер на колесе Camelot.
    // B-сторона (мажор): C=8B, G=9B, D=10B, A=11B, E=12B, B=1B, F#=2B, Db=3B, Ab=4B, Eb=5B, Bb=6B, F=7B
    private static let majorWheel: [Int] = [8, 3, 10, 5, 12, 7, 2, 9, 4, 11, 6, 1]
    // A-сторона (минор): Am=8A, Em=9A, Bm=10A, F#m=11A, C#m=12A, Abm=1A, Ebm=2A, Bbm=3A, Fm=4A, Cm=5A, Gm=6A, Dm=7A
    private static let minorWheel: [Int] = [5, 12, 7, 2, 9, 4, 11, 6, 1, 8, 3, 10]

    private static let pitchClass: [Character: Int] = [
        "C": 0, "D": 2, "E": 4, "F": 5, "G": 7, "A": 9, "B": 11
    ]

    /// Главная точка входа: любое написание → канонический Camelot ("9A"), либо nil.
    static func camelot(_ raw: String) -> String? {
        components(raw)?.text
    }

    /// Разобранный Camelot — то, что нужно скорингу (номер + сторона колеса).
    static func components(_ raw: String) -> Camelot? {
        let s = clean(raw)
        guard !s.isEmpty else { return nil }
        return parseCamelotNotation(s) ?? parseClassicNotation(s)
    }

    /// Camelot → классика (написание как в Rekordbox). Обратная таблица нужна ровно
    /// для 24 канонических кодов, поэтому здесь она явная, а не через pitch class.
    private static let camelotToClassic: [String: String] = [
        "1A": "Abm", "2A": "Ebm", "3A": "Bbm", "4A": "Fm",
        "5A": "Cm",  "6A": "Gm",  "7A": "Dm",  "8A": "Am",
        "9A": "Em",  "10A": "Bm", "11A": "F#m", "12A": "C#m",
        "1B": "B",   "2B": "F#",  "3B": "Db",  "4B": "Ab",
        "5B": "Eb",  "6B": "Bb",  "7B": "F",   "8B": "C",
        "9B": "G",   "10B": "D",  "11B": "A",  "12B": "E"
    ]

    /// Любое написание → классика ("Am"), либо nil.
    static func classic(_ raw: String) -> String? {
        guard let c = components(raw) else { return nil }
        return camelotToClassic[c.text]
    }

    // MARK: - Разбор

    // Убираем пробелы и юникодные знаки альтерации (♯/♭ встречаются в тегах из Mixed In Key).
    private static func clean(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        s = s.replacingOccurrences(of: "♯", with: "#")
        s = s.replacingOccurrences(of: "♭", with: "b")
        s = s.replacingOccurrences(of: " ", with: "")
        guard s != "—", s != "-", s.lowercased() != "unknown", s.lowercased() != "none" else { return "" }
        return s
    }

    private static func parseCamelotNotation(_ s: String) -> Camelot? {
        let digits = s.prefix(while: { $0.isNumber })
        guard !digits.isEmpty, let num = Int(digits), num >= 1, num <= 12 else { return nil }
        let rest = s.dropFirst(digits.count)
        guard rest.count == 1, let ch = rest.first else { return nil }
        let letter = Character(String(ch).uppercased())
        guard letter == "A" || letter == "B" else { return nil }
        return Camelot(number: num, letter: letter)
    }

    private static func parseClassicNotation(_ s: String) -> Camelot? {
        var chars = Array(s)
        guard let rootChar = chars.first else { return nil }
        let root = Character(String(rootChar).uppercased())
        guard var pc = pitchClass[root] else { return nil }
        chars.removeFirst()

        // Альтерация. "b" в позиции 1 — это бемоль ("Bbm"), а не корень: корень уже съеден.
        if let acc = chars.first {
            if acc == "#" {
                pc += 1; chars.removeFirst()
            } else if acc == "b" || acc == "B" {
                pc -= 1; chars.removeFirst()
            }
        }
        pc = ((pc % 12) + 12) % 12

        // Лад. Регистр не различаем: "CM" считаем минором так же, как это делает
        // iOS-конвертер (normalizeClassic заменяет "M" → "m"), иначе агент и приложение
        // разошлись бы на одном и том же теге.
        let suffix = String(chars).lowercased()
        let isMinor: Bool
        switch suffix {
        case "":                             isMinor = false   // голый корень = мажор
        case "maj", "major":                 isMinor = false
        case "m", "mi", "min", "minor", "-": isMinor = true
        default:                             return nil        // мусор вроде "10m", "Amx"
        }

        return Camelot(number: isMinor ? minorWheel[pc] : majorWheel[pc],
                       letter: isMinor ? "A" : "B")
    }
}
