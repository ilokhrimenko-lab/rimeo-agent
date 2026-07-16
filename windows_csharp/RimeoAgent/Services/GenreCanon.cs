using System.Globalization;
using System.Text;

namespace RimeoAgent.Services;

// В библиотеке 60 сырых написаний жанра на ~8 реальных корзин: "Afro House" / "Afro-House" /
// "AfroHouse", "Хаус" (кириллица!) / "House", "Organic House" / "Organic House / Downtempo".
// Сырое сравнение строк (a.ToLower() == b.ToLower()) считает их РАЗНЫМИ жанрами,
// т.е. жанровый бонус в скоринге просто не срабатывает на половине совпадений.
//
// Ключ поиска — «сплющенное» написание: только буквы и цифры, lowercase. Поэтому одна
// строка таблицы закрывает сразу "Afro House", "Afro-House", "AfroHouse", "afro  house".
//
// Порт GenreCanon.swift. Таблица и поведение обязаны совпадать с macOS байт-в-байт:
// оба агента отдают один и тот же /api/similar, расхождение канона = разные подборки
// на одной и той же библиотеке.
public static class GenreCanon
{
    /// Сплющенный алиас → каноническая корзина. Таблица собрана по реальным 59
    /// написаниям библиотеки, а не «на будущее»: незнакомый жанр НЕ схлопывается
    /// насильно, он остаётся собой (см. fallback в <see cref="Canon"/>).
    ///
    /// Ordinal-компаратор ЯВНО: ключи уже сплющены и в нижнем регистре, а
    /// культурное сравнение по умолчанию сложило бы "хаус" и "house" в разные
    /// корзины непредсказуемо (и зависело бы от локали машины пользователя).
    private static readonly Dictionary<string, string> Aliases = new(StringComparer.Ordinal)
    {
        // afro                      "Afro House", "Afro-House", "AfroHouse", "AFRO HOUSE "
        ["afrohouse"]             = "afro_house",
        ["afro"]                  = "afro_house",   // "Afro / Latin / Brazilian"
        ["afrotech"]              = "afro_house",
        // house                     "House", "Хаус"
        ["house"]                 = "house",
        ["хаус"]                  = "house",
        // organic                   "Organic House", "Organic House / Downtempo"
        ["organic"]               = "organic",
        ["organichouse"]          = "organic",
        ["organichousedowntempo"] = "organic",
        // hip-hop                   "Hip-Hop", "Hip Hop/Rap"
        ["hiphop"]                = "hiphop",
        ["hiphoprap"]             = "hiphop",
        ["rap"]                   = "hiphop",
        // melodic                   "Melodic House & Techno", "Melodic Techno"
        ["melodichousetechno"]    = "melodic",
        ["melodichouseandtechno"] = "melodic",
        ["melodichouse"]          = "melodic",
        ["melodictechno"]         = "melodic",
        // tech house                "Tech House", "Tech House / Breakbeat"
        ["techhouse"]             = "tech_house",
        // minimal                   "Minimal / Deep Tech", "Minimal/tech house", "Minimal"
        ["minimal"]               = "minimal",
        ["minimaldeeptech"]       = "minimal",
        ["deeptech"]              = "minimal",
        // deep house
        ["deephouse"]             = "deep_house",
        // indie dance               "Indie Dance" (+ составное имя Beatport)
        ["indiedance"]            = "indie_dance",
        ["indiedancenudisco"]     = "indie_dance",
        // кириллица — прямые переводы, встречаются в тегах
        ["поп"]                   = "pop",
        ["электронная"]           = "electronic",
    };

    /// Разделители «нескольких жанров в одном поле». Ровно те же три символа, что в Swift.
    private static readonly char[] MultiGenreSeparators = { ',', ';', '/' };

    /// Ключ сравнения: каноническая корзина, либо — для незнакомого жанра —
    /// нормализованный lowercase (жанр не теряем, просто сравниваем аккуратно).
    /// Пустой/мусорный вход → "" (вызывающий обязан считать это «нет жанра»).
    public static string Canon(string? raw)
    {
        // В Swift параметр не-опциональный; на C# Track.Genre хоть и не-null по
        // контракту, но через JSON/БД может приехать null — считаем это «нет жанра».
        if (string.IsNullOrEmpty(raw)) return "";

        var flat = Flatten(raw);
        if (flat.Length == 0) return "";
        if (Aliases.TryGetValue(flat, out var bucket)) return bucket;

        // Несколько жанров в одном поле ("House, Tech House", "Tech House / Breakbeat",
        // "Minimal/tech house") — основной жанр ПЕРВЫЙ. Составные имена Beatport
        // ("Minimal / Deep Tech", "Organic House / Downtempo") сюда не доходят: они
        // уже совпали целиком строчкой выше.
        //
        // RemoveEmptyEntries воспроизводит omittingEmptySubsequences из Swift-овского
        // split(whereSeparator:): ",House" даёт "House", а не пустую голову. Строка
        // из одних пробелов (" / House") пустой НЕ считается ни там, ни тут — голова
        // сплющивается в "" и мы честно падаем в normalized(), как на маке.
        var head = raw.Split(MultiGenreSeparators, StringSplitOptions.RemoveEmptyEntries)
                      .FirstOrDefault();
        if (head is not null)
        {
            var headFlat = Flatten(head);
            if (headFlat.Length > 0 && Aliases.TryGetValue(headFlat, out var headBucket))
                return headBucket;
        }

        return Normalized(raw);
    }

    /// Совпадение жанров с учётом канонизации. Пустой жанр не совпадает ни с чем,
    /// включая другой пустой.
    public static bool Same(string? a, string? b)
    {
        var x = Canon(a);
        var y = Canon(b);
        return x.Length > 0 && string.Equals(x, y, StringComparison.Ordinal);
    }

    // MARK: - Нормализация

    /// Только буквы и цифры, lowercase: "Afro-House" и "AfroHouse" → "afrohouse".
    /// Кириллица сохраняется, поэтому "Хаус" → "хаус".
    ///
    /// Идём по РУНАМ (code points), а не по char: char — это UTF-16 code unit, и
    /// char.IsLetterOrDigit на половинке суррогатной пары вернёт false, молча
    /// выкинув символ вне BMP (эмодзи-жанр, редкие письменности). Swift фильтрует
    /// unicodeScalars, т.е. именно code points — повторяем один в один.
    ///
    /// Категории берём вручную: Swift-овский CharacterSet.alphanumerics — это
    /// L* + M* + N*, а Rune.IsLetterOrDigit — только L* + Nd. Разница вылезает на
    /// декомпозированной диакритике ("é" = "e" + U+0301): .NET выкинул бы
    /// комбинирующую метку, macOS — оставил, и один и тот же жанр дал бы разные
    /// ключи на двух агентах.
    private static string Flatten(string raw)
    {
        // Лоуэркейс СНАЧАЛА и по всей строке — как в Swift (raw.lowercased()):
        // полный юникодный лоуэркейс может менять длину, поэтому это не то же
        // самое, что опускать регистр каждой руны по отдельности.
        // Invariant, а не текущая культура: на турецкой локали ToLower("I") даёт "ı",
        // и "Indie Dance" перестал бы попадать в таблицу алиасов.
        //
        // ⚠️ NFC обязателен: Swift сравнивает String канонически, поэтому "é" одним
        // символом и "e"+U+0301 для него — ОДИН ключ словаря алиасов. В .NET сравнение
        // ординальное, и без нормализации декомпозированный тег молча не находил бы
        // свою корзину. Тот же баг поймали на TrackIdentity (см. комментарий там).
        var lowered = TextNorm.Nfc(raw.ToLowerInvariant());

        var sb = new StringBuilder(lowered.Length);
        foreach (var rune in lowered.EnumerateRunes())
        {
            if (IsAlphanumeric(rune)) sb.Append(rune.ToString());
        }
        return sb.ToString();
    }

    /// Эквивалент CharacterSet.alphanumerics из Foundation: буквы (L*), метки (M*)
    /// и любые числа (N*, а не только десятичные цифры).
    private static bool IsAlphanumeric(System.Text.Rune rune) =>
        System.Text.Rune.GetUnicodeCategory(rune) switch
        {
            UnicodeCategory.UppercaseLetter      or
            UnicodeCategory.LowercaseLetter      or
            UnicodeCategory.TitlecaseLetter      or
            UnicodeCategory.ModifierLetter       or
            UnicodeCategory.OtherLetter          or
            UnicodeCategory.NonSpacingMark       or
            UnicodeCategory.SpacingCombiningMark or
            UnicodeCategory.EnclosingMark        or
            UnicodeCategory.DecimalDigitNumber   or
            UnicodeCategory.LetterNumber         or
            UnicodeCategory.OtherNumber          => true,
            _                                    => false,
        };

    /// Читаемый lowercase для незнакомых жанров: пунктуация → пробел, пробелы схлопнуты.
    /// "Progressive-House" и "Progressive House" дадут один ключ.
    /// NFC — по той же причине, что и во Flatten: это ключ сравнения, а Swift сравнивает
    /// канонически.
    private static string Normalized(string raw)
    {
        var lowered = TextNorm.Nfc(raw.ToLowerInvariant());

        var parts = new List<string>();
        var token = new StringBuilder();
        foreach (var ch in lowered)
        {
            // Swift режет по CharacterSet(charactersIn: "-_/\\&,.|+()[]") ∪
            // .whitespacesAndNewlines. char.IsWhiteSpace закрывает и пробелы (Zs/Zl/Zp),
            // и переводы строк (\n \r \t \v \f, U+0085) — то же множество на практике.
            // TextNorm.IsWhitespace, а НЕ char.IsWhiteSpace: Foundation считает пробелом
            // и U+200B (ZWSP), .NET — нет. Без этого "Progressive<ZWSP>House" на маке
            // канонизируется в "progressive house", а на Windows — в один слипшийся
            // токен, и жанровый бонус срабатывает только на одной из платформ.
            if (IsSeparator(ch) || TextNorm.IsWhitespace(ch))
            {
                if (token.Length > 0) { parts.Add(token.ToString()); token.Clear(); }
            }
            else
            {
                token.Append(ch);
            }
        }
        if (token.Length > 0) parts.Add(token.ToString());

        return string.Join(" ", parts);
    }

    /// Пунктуация-разделитель. Список символ-в-символ из Swift: "-_/\&,.|+()[]".
    /// Обратный слеш в Swift-исходнике экранирован ("\\"), т.е. это ОДИН символ '\'.
    private static bool IsSeparator(char ch) => ch switch
    {
        '-' or '_' or '/' or '\\' or '&' or ',' or '.' or
        '|' or '+' or '(' or ')' or '[' or ']' => true,
        _                                      => false,
    };
}
