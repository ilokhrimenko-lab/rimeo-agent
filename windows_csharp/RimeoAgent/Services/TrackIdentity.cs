using System.Globalization;
using System.Text;
using RimeoAgent.Models;

namespace RimeoAgent.Services;

// «Тот же самый трек», импортированный в библиотеку дважды с разными ID: одна и та же
// запись, отличаются только теги (у одной копии пустой лейбл, у другой заполнен) или
// контейнер (.wav и .aiff). Исключение кандидатов ТОЛЬКО по id такой дубль не ловит —
// и движок предлагал добавить в плейлист то, что в нём уже лежит. На реальной
// библиотеке (2280 треков) это 26 групп дублей и первые же позиции выдачи.
//
// Ключ «та же запись» = нормализованный СОСТАВ артистов + нормализованный тайтл.
//
// ГРАНИЦА, которую нельзя перейти. Схлопывать разрешено только маркеры «та же версия»
// ((Extended Mix), (Original Mix), (Radio Edit), «- Extended», (Ext)) и featuring-хвосты.
// Имя ремиксера — часть произведения: "(Peggy Gou Remix)" и "(Jack Back Remix)" — РАЗНЫЕ
// треки, и предлагать их к плейлисту, где лежит оригинал, совершенно законно. Поэтому
// список нейтральных маркеров ЗАКРЫТЫЙ (белый список сегментов целиком), а не эвристика
// «выкинуть всё, что в скобках».
public static class TrackIdentity
{
    /// Сегмент скобок или dash-хвоста, который означает «та же самая запись, просто
    /// стандартная форма релиза». Сравнение по сплющенному виду, поэтому одна строка
    /// закрывает "(Extended Mix)", "(extended mix)", "[EXTENDED  MIX]".
    private static readonly HashSet<string> NeutralMarkers = new(StringComparer.Ordinal)
    {
        "extended", "extendedmix", "extendedversion", "extendededit", "ext", "extmix",
        "original", "originalmix", "originalversion",
        "radio", "radioedit", "radiomix", "radioversion",
    };

    /// Слова-разделители соавторства ВНУТРИ поля артиста. Ищутся как отдельное слово —
    /// иначе "feat" порезало бы "Featherstone". "and" сюда НЕ входит намеренно: это
    /// живое слово внутри имён ("Above and Beyond"), а реальные теги соавторства в
    /// Rekordbox идут через запятую или &.
    private static readonly HashSet<string> ArtistJoiners = new(StringComparer.Ordinal)
    {
        "feat", "ft", "featuring", "vs", "x",
    };

    /// Порядок проверки значим: длинные формы раньше коротких, иначе "featuring X"
    /// съелось бы префиксом "feat" и в имя артиста уехал бы огрызок "uring X".
    private static readonly string[] FeatPrefixes =
    {
        "featuring ", "feat. ", "feat ", "ft. ", "ft ", "featuring", "feat.", "ft.",
    };

    private static readonly char[] ArtistSeparators = { ',', '&', ';', '/', '+' };

    /// Ключ дубликата, либо null — когда опознавать нечем (пустой тайтл). Трек без тайтла
    /// дублем НЕ считаем: иначе все безымянные схлопнулись бы в один.
    public static string? Key(string artist, string title)
    {
        // System.Text.Json кладёт JSON-null прямо в non-nullable string, минуя
        // инициализатор `= ""` в модели, — тег без artist/title в базе не имеет права
        // ронять весь пересчёт дублей на NullReferenceException.
        var rawArtist = string.IsNullOrEmpty(artist) ? "" : artist;
        var rawTitle  = string.IsNullOrEmpty(title)  ? "" : title;

        var (parts, feats) = ParseTitle(rawTitle);

        var sb = new StringBuilder();
        foreach (var p in parts) sb.Append(Flatten(p));
        var t = sb.ToString();
        if (t.Length == 0) return null;

        // Артисты — МНОЖЕСТВО, а не строка: "Rafael, Mita Gami" и "Mita Gami & Rafael" —
        // один и тот же дуэт, поэтому имена сортируются. Featured-артисты из тайтла
        // переезжают сюда же: "A - Song (feat. B)" и "A, B - Song" — одна запись.
        var names = new List<string>();
        var seen  = new HashSet<string>(StringComparer.Ordinal);
        foreach (var raw in SplitArtists(rawArtist).Concat(feats))
        {
            var f = Flatten(raw);
            if (f.Length == 0) continue;
            if (seen.Add(f)) names.Add(f);
        }
        // Ordinal, а НЕ List.Sort() по умолчанию: дефолтный компаратор культурно-зависим,
        // и на машине с турецкой/шведской локалью тот же дуэт дал бы другой порядок имён
        // → другой ключ → дубль перестал бы схлопываться. Swift сортирует по скалярам,
        // ordinal — его прямой аналог.
        names.Sort(StringComparer.Ordinal);

        return string.Join("&", names) + "|" + t;
    }

    public static string? Key(Track t) => Key(t.Artist, t.Title);

    // MARK: - Тайтл

    /// Тайтл → (значимые куски, featured-артисты). Значимые куски — это ядро названия
    /// и всё, что не входит в белый список нейтральных маркеров (в первую очередь имя
    /// ремиксера). Скобки и dash-хвосты разбираются одинаково, поэтому
    /// "Song (Peggy Gou Remix)" и "Song - Peggy Gou Remix" дают один ключ.
    private static (List<string> Parts, List<string> Feats) ParseTitle(string raw)
    {
        var bare     = new StringBuilder();
        var brackets = new List<string>();
        var buf      = new StringBuilder();
        var depth    = 0;

        // Ручной разбор с depth, а не regex: скобки в тегах бывают вложенными
        // ("Song (Remix (Dub))") и незакрытыми ("Song (Extended Mix"), и Regex на
        // сбалансированные группы тут только маскирует такие теги.
        foreach (var ch in raw)
        {
            switch (ch)
            {
                case '(':
                case '[':
                    if (depth == 0) buf.Clear(); else buf.Append(ch);
                    depth += 1;
                    break;
                case ')':
                case ']':
                    if (depth == 1) { brackets.Add(buf.ToString()); buf.Clear(); }
                    else if (depth > 1) buf.Append(ch);
                    // Непарная закрывающая скобка при depth == 0 просто ВЫБРАСЫВАЕТСЯ
                    // (не уезжает в bare) — ровно как в Swift-оригинале.
                    depth = Math.Max(0, depth - 1);
                    break;
                default:
                    if (depth > 0) buf.Append(ch); else bare.Append(ch);
                    break;
            }
        }
        if (depth > 0 && buf.Length > 0) brackets.Add(buf.ToString());   // незакрытая скобка в теге

        var parts = new List<string>();
        var feats = new List<string>();

        var chunks = SplitDashes(bare.ToString());
        // Индексный цикл, а не foreach по отфильтрованному: i считает ВСЕ куски, включая
        // пустые. Тайтл " - Extended Mix" даёт chunks ["", "Extended Mix"] — «ядро» (i==0)
        // пустое, и хвост обязан пройти проверку на нейтральный маркер, а не подменить
        // собой ядро.
        for (var i = 0; i < chunks.Count; i++)
        {
            var t = TextNorm.Trim(chunks[i]);
            if (t.Length == 0) continue;
            if (i == 0) { parts.Add(t); continue; }              // ядро тайтла — всегда значимо
            var f = FeatNames(t);
            if (f != null) { feats.AddRange(f); continue; }
            if (NeutralMarkers.Contains(Flatten(t))) continue;
            parts.Add(t);
        }
        foreach (var seg in brackets)
        {
            var t = TextNorm.Trim(seg);
            if (t.Length == 0) continue;
            var f = FeatNames(t);
            if (f != null) { feats.AddRange(f); continue; }
            if (NeutralMarkers.Contains(Flatten(t))) continue;
            parts.Add(t);
        }
        return (parts, feats);
    }

    /// Режем только dash с пробелами (" - ", " – ", " — ", " -- "): дефис внутри слова
    /// ("Hip-Hop", "Re-Work") разделителем не является.
    private static List<string> SplitDashes(string s)
    {
        var separators = new[] { " - ", " – ", " — ", " -- " };
        var outp = new List<string> { s };
        foreach (var sep in separators)
        {
            var next = new List<string>(outp.Count);
            foreach (var chunk in outp)
                // StringSplitOptions.None: components(separatedBy:) в Swift сохраняет
                // пустые куски, и на них завязан индекс i в ParseTitle.
                next.AddRange(chunk.Split(sep, StringSplitOptions.None));
            outp = next;
        }
        return outp;
    }

    /// Сегмент вида "feat. Someone" → имена. null — сегмент не про featuring.
    private static List<string>? FeatNames(string segment)
    {
        var low = segment.ToLowerInvariant();
        foreach (var p in FeatPrefixes)
        {
            // Ordinal: культурно-зависимый StartsWith по умолчанию в .NET может счесть
            // "ft." совпадением там, где посимвольно его нет (и наоборот), — здесь нужен
            // строгий байтовый префикс.
            if (!low.StartsWith(p, StringComparison.Ordinal)) continue;
            // Префиксы ASCII, поэтому длина в lowercase совпадает с длиной в оригинале,
            // и хвост можно резать по индексу исходной (не приведённой) строки.
            return SplitArtists(segment.Substring(p.Length));
        }
        return null;
    }

    // MARK: - Артисты

    private static List<string> SplitArtists(string raw)
    {
        var outp = new List<string>();
        foreach (var chunk in raw.Split(ArtistSeparators))
            foreach (var name in SplitJoiners(chunk))
            {
                var t = TextNorm.Trim(name);
                if (t.Length > 0) outp.Add(t);
            }
        return outp;
    }

    /// "Rafael feat. Mita Gami" → ["Rafael", "Mita Gami"]: featured-артист — тоже артист,
    /// и в другой копии того же трека он вполне может стоять просто через запятую.
    private static List<string> SplitJoiners(string s)
    {
        var outp = new List<string>();
        var cur  = new List<string>();
        // RemoveEmptyEntries = поведение Swift-овского split(separator:), который по
        // умолчанию схлопывает подряд идущие пробелы.
        foreach (var w in s.Split(' ', StringSplitOptions.RemoveEmptyEntries))
        {
            // Сравнение по сплющенному слову: так "feat." и "Feat" — тот же джойнер,
            // но подстрока внутри "Featherstone" джойнером не становится.
            if (ArtistJoiners.Contains(Flatten(w)))
            {
                outp.Add(string.Join(" ", cur));
                cur.Clear();
            }
            else cur.Add(w);
        }
        outp.Add(string.Join(" ", cur));
        return outp;
    }

    // MARK: - Нормализация

    /// Только буквы и цифры, lowercase: регистр, пробелы и пунктуация из ключа уходят.
    /// Юникод-осведомлён, поэтому кириллица в тегах не теряется.
    ///
    /// ⚠️ NFC-НОРМАЛИЗАЦИЯ — НЕ ПЕДАНТИЗМ, А ПОЧИНЕННЫЙ БАГ. Swift сравнивает String
    /// по КАНОНИЧЕСКОЙ ЭКВИВАЛЕНТНОСТИ: "ó" как единый U+00F3 и как "o"+U+0301 — для
    /// него одна и та же строка, поэтому Set схлопывает их в один элемент. В .NET
    /// StringComparer.Ordinal сравнивает байты, и это ДВЕ разные строки.
    ///
    /// На живой библиотеке это не теория: у трека 62017310 тег artist = "Crusy, Lubó"
    /// записан в NFD, а title = "New Life (feat. Lubó)" — в NFC. Без нормализации
    /// ключ выходил "crusy&lubó&lubó|newlife" (артист продублирован) вместо
    /// "crusy&lubó|newlife" — то есть ключ дубликата НЕ совпадал с ключом второй копии
    /// той же записи, и весь дедуп по этой паре молча отключался.
    ///
    /// 🚨 НЕ ВКЛЮЧАЙ `<InvariantGlobalization>true</InvariantGlobalization>` в
    /// RimeoAgent.csproj. В invariant-режиме .NET выкидывает ICU, и String.Normalize()
    /// становится ТИХИМ no-op: он не бросает исключение, а просто возвращает строку
    /// как есть. Дедуп сломается обратно — молча, без единой ошибки в логе. Проверено.
    private static string Flatten(string raw)
    {
        var sb = new StringBuilder(raw.Length);
        // EnumerateRunes, а не foreach по char: char в .NET — это UTF-16 code unit, и
        // посимвольный обход разрезал бы суррогатную пару на две «не-буквы», выкинув
        // из ключа любой символ вне BMP. Swift итерирует unicodeScalars — руны это он
        // и есть.
        foreach (var r in TextNorm.Nfc(raw.ToLowerInvariant()).EnumerateRunes())
            if (IsAlphanumeric(Rune.GetUnicodeCategory(r)))
                sb.Append(r.ToString());
        return sb.ToString();
    }


    /// Аналог CharacterSet.alphanumerics из Foundation: категории L*, M* и N*.
    /// char.IsLetterOrDigit НЕ подходит — он не считает буквой комбинирующие метки (M*)
    /// и нечего-цифры вроде римских (Nl/No), из-за чего декомпозированная кириллица/
    /// умляуты в тегах потеряли бы диакритику и две копии трека разошлись бы по ключу.
    private static bool IsAlphanumeric(UnicodeCategory c) => c
        is UnicodeCategory.UppercaseLetter
        or UnicodeCategory.LowercaseLetter
        or UnicodeCategory.TitlecaseLetter
        or UnicodeCategory.ModifierLetter
        or UnicodeCategory.OtherLetter
        or UnicodeCategory.NonSpacingMark
        or UnicodeCategory.SpacingCombiningMark
        or UnicodeCategory.EnclosingMark
        or UnicodeCategory.DecimalDigitNumber
        or UnicodeCategory.LetterNumber
        or UnicodeCategory.OtherNumber;
}
