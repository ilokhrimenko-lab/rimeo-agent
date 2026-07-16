namespace RimeoAgent.Services;

// Тональность в master.db (djmdKey.ScaleName) приходит в ДВУХ нотациях вперемешку:
// Camelot ("9A", "12B") и классика ("Am", "F#m", "C", "Db"). Старый ParseCamelot в
// SimilarityEngine понимал только Camelot → у ~47% библиотеки ключ не распознавался,
// CamelotScore молча отдавал нейтральные 0.5, и гармонический фильтр для этих треков
// был фактически выключен. Этот нормализатор приводит ЛЮБОЕ написание к Camelot.
//
// Считаем через pitch class (0–11), а не по таблице написаний: это бесплатно решает
// энгармонику (C#m == Dbm == 12A, F#m == Gbm == 11A, G#m == Abm == 1A) и редкие
// написания (Cb, E#), которых нет в таблице iOS-конвертера.
// Порт macos_arm64/.../Services/KeyNormalizer.swift — результаты обязаны совпадать
// на всех 24 ключах, иначе мак и винда разойдутся в выдаче на одной и той же библиотеке.
public static class KeyNormalizer
{
    /// Camelot-код: номер на колесе (1…12) + сторона ('A' = minor, 'B' = major).
    public readonly record struct Camelot(int Number, char Letter)
    {
        // Вычисляемое, а не auto-property: в readonly record struct get-only auto-property
        // пришлось бы присваивать в primary constructor, чего позиционная запись не умеет.
        public string Text => $"{Number}{Letter}";
    }

    // pitch class → номер на колесе Camelot.
    // B-сторона (мажор): C=8B, G=9B, D=10B, A=11B, E=12B, B=1B, F#=2B, Db=3B, Ab=4B, Eb=5B, Bb=6B, F=7B
    private static readonly int[] MajorWheel = { 8, 3, 10, 5, 12, 7, 2, 9, 4, 11, 6, 1 };
    // A-сторона (минор): Am=8A, Em=9A, Bm=10A, F#m=11A, C#m=12A, Abm=1A, Ebm=2A, Bbm=3A, Fm=4A, Cm=5A, Gm=6A, Dm=7A
    private static readonly int[] MinorWheel = { 5, 12, 7, 2, 9, 4, 11, 6, 1, 8, 3, 10 };

    private static readonly Dictionary<char, int> PitchClass = new()
    {
        ['C'] = 0, ['D'] = 2, ['E'] = 4, ['F'] = 5, ['G'] = 7, ['A'] = 9, ['B'] = 11
    };

    /// Camelot → классика (написание как в Rekordbox). Обратная таблица нужна ровно
    /// для 24 канонических кодов, поэтому здесь она явная, а не через pitch class.
    private static readonly Dictionary<string, string> CamelotToClassic = new()
    {
        ["1A"] = "Abm", ["2A"] = "Ebm", ["3A"] = "Bbm",  ["4A"] = "Fm",
        ["5A"] = "Cm",  ["6A"] = "Gm",  ["7A"] = "Dm",   ["8A"] = "Am",
        ["9A"] = "Em",  ["10A"] = "Bm", ["11A"] = "F#m", ["12A"] = "C#m",
        ["1B"] = "B",   ["2B"] = "F#",  ["3B"] = "Db",   ["4B"] = "Ab",
        ["5B"] = "Eb",  ["6B"] = "Bb",  ["7B"] = "F",    ["8B"] = "C",
        ["9B"] = "G",   ["10B"] = "D",  ["11B"] = "A",   ["12B"] = "E"
    };

    /// Разобранный Camelot — то, что нужно скорингу (номер + сторона колеса).
    public static Camelot? Components(string? raw)
    {
        var s = Clean(raw);
        if (s.Length == 0) return null;
        return ParseCamelotNotation(s) ?? ParseClassicNotation(s);
    }

    /// Главная точка входа: любое написание → канонический Camelot ("9A"), либо null.
    public static string? ToCamelot(string? raw) => Components(raw)?.Text;

    /// Любое написание → классика ("Am"), либо null.
    public static string? ToClassic(string? raw)
    {
        var c = Components(raw);
        if (c is null) return null;
        return CamelotToClassic.TryGetValue(c.Value.Text, out var classic) ? classic : null;
    }

    // MARK: - Разбор

    // Убираем пробелы и юникодные знаки альтерации (♯/♭ встречаются в тегах из Mixed In Key).
    private static string Clean(string? raw)
    {
        if (raw is null) return "";
        // TextNorm.Trim, а НЕ raw.Trim(): Foundation режет и U+200B (ZWSP), .NET — нет.
        // Тег "9A" с зацепившимся ZWSP давал бы на маке 9A, а на Windows — null.
        var s = TextNorm.Trim(raw);
        s = s.Replace("♯", "#");
        s = s.Replace("♭", "b");
        s = s.Replace(" ", "");
        // Плейсхолдеры «ключа нет». Сравнение через ToLowerInvariant, а не ToLower():
        // в turkish locale ToLower('I') даёт 'ı', и "UNKNOWN" перестал бы отсекаться —
        // Rekordbox на винде запускают в том числе с турецкой локалью.
        var lower = s.ToLowerInvariant();
        if (s == "—" || s == "-" || lower == "unknown" || lower == "none") return "";
        return s;
    }

    private static Camelot? ParseCamelotNotation(string s)
    {
        // Только ASCII-цифры. Swift берёт префикс по Character.isNumber (шире: туда
        // попадают арабо-индийские цифры и "½"), но затем Int(digits) на них падает
        // и возвращает nil — то есть итог тот же null. Явный ASCII-скан даёт ровно
        // такое же поведение без сюрпризов от char.IsDigit, который тоже пропускает
        // не-ASCII десятичные цифры, а int.Parse их бы принял и разошёлся с маком.
        int i = 0;
        while (i < s.Length && s[i] >= '0' && s[i] <= '9') i++;
        if (i == 0) return null;
        if (!int.TryParse(s[..i], out int num) || num < 1 || num > 12) return null;

        var rest = s[i..];
        if (rest.Length != 1) return null;
        char letter = char.ToUpperInvariant(rest[0]);
        if (letter != 'A' && letter != 'B') return null;
        return new Camelot(num, letter);
    }

    private static Camelot? ParseClassicNotation(string s)
    {
        if (s.Length == 0) return null;
        char root = char.ToUpperInvariant(s[0]);
        if (!PitchClass.TryGetValue(root, out int pc)) return null;
        int idx = 1;

        // Альтерация. "b" в позиции 1 — это бемоль ("Bbm"), а не корень: корень уже съеден.
        if (idx < s.Length)
        {
            char acc = s[idx];
            if (acc == '#') { pc += 1; idx++; }
            else if (acc == 'b' || acc == 'B') { pc -= 1; idx++; }
        }
        pc = ((pc % 12) + 12) % 12;

        // Лад. Регистр не различаем: "CM" считаем минором так же, как это делает
        // iOS-конвертер (normalizeClassic заменяет "M" → "m"), иначе агент и приложение
        // разошлись бы на одном и том же теге.
        var suffix = s[idx..].ToLowerInvariant();
        bool isMinor;
        switch (suffix)
        {
            case "":                              isMinor = false; break;   // голый корень = мажор
            case "maj":
            case "major":                         isMinor = false; break;
            case "m":
            case "mi":
            case "min":
            case "minor":
            case "-":                             isMinor = true;  break;
            default:                              return null;              // мусор вроде "10m", "Amx"
        }

        return new Camelot(isMinor ? MinorWheel[pc] : MajorWheel[pc], isMinor ? 'A' : 'B');
    }
}
