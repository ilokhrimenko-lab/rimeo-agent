using System.Text;

namespace RimeoAgent.Services;

/// Юникодная нормализация ключей сравнения — одна на всех, кто эти ключи строит
/// (TrackIdentity, GenreCanon, SimilarityEngine).
///
/// ⚠️ ЗАЧЕМ ОНА ВООБЩЕ НУЖНА. Swift сравнивает String по КАНОНИЧЕСКОЙ эквивалентности:
/// "ó" единым символом U+00F3 и "o" + U+0301 — для него одна и та же строка, и Set/
/// Dictionary схлопывают их в один элемент. В .NET сравнение ординальное, это ДВЕ
/// разные строки. На живой библиотеке (трек 62017310) тег artist записан в NFD, а
/// title того же трека — в NFC: без приведения к NFC ключ дубликата не совпадал сам
/// с собой, и дедуп по этой записи молча отключался.
///
/// ⚠️ ПОЧЕМУ ЧЕРЕЗ try/catch. String.Normalize() НЕ тотальна: на непарном суррогате
/// (битый UTF-16 в теге — приезжает из криво сконвертированных библиотек) она бросает
/// ArgumentException. Swift-овский flatten бросить не может в принципе. А ключи здесь
/// считаются для КАЖДОГО кандидата, поэтому один битый тег уронил бы ВЕСЬ запрос
/// рекомендаций, а не выкинул бы один трек. Откатываемся на ненормализованную строку:
/// сравнение для этого одного трека деградирует до побайтового (как было до NFC), но
/// библиотека продолжает работать.
///
/// 🚨 НЕ ВКЛЮЧАЙ `<InvariantGlobalization>true</InvariantGlobalization>` в
/// RimeoAgent.csproj. В invariant-режиме .NET выкидывает ICU, и Normalize() становится
/// ТИХИМ no-op — не бросает, а просто возвращает строку как есть. Дедуп сломается
/// обратно, молча, без единой ошибки в логе. Проверено.
public static class TextNorm
{
    public static string Nfc(string s)
    {
        try { return s.Normalize(NormalizationForm.FormC); }
        catch (ArgumentException) { return s; }
    }

    /// ⚠️ ПРОБЕЛЬНЫЕ МНОЖЕСТВА ДВУХ ПЛАТФОРМ НЕ СОВПАДАЮТ — и это не теория.
    ///
    /// Swift везде режет по `CharacterSet.whitespacesAndNewlines`. Оно ВКЛЮЧАЕТ
    /// U+200B (ZERO WIDTH SPACE). .NET-овский `char.IsWhiteSpace` — НЕТ: для него
    /// U+200B это категория Cf (format), а не пробел.
    ///
    /// Исчерпывающий перебор всего BMP (65 536 скаляров) дал РОВНО ОДНО расхождение —
    /// U+200B. Но оно живое: ZWSP приезжает копипастом тегов с веба (Beatport,
    /// Bandcamp, сторонние ID3-теггеры). Последствия были ровно те, ради недопущения
    /// которых этот порт и делался:
    ///   • KeyNormalizer: тег "9A<ZWSP>" → на macOS "9A", на Windows null ⇒ у трека
    ///     есть гармония на маке и нет на винде;
    ///   • GenreCanon.Normalized: "Progressive<ZWSP>House" → на macOS
    ///     "progressive house", на Windows "progressive<ZWSP>house" ⇒ жанровый бонус
    ///     срабатывает на маке и не срабатывает на винде.
    ///
    /// Поэтому ВСЕ обрезки и проверки «это пробел?» в коде, портированном со Swift,
    /// обязаны идти через эти два метода, а не через Trim()/char.IsWhiteSpace.
    private const char ZeroWidthSpace = '\u200B';

    private static readonly char[] FoundationWhitespace = BuildFoundationWhitespace();

    private static char[] BuildFoundationWhitespace()
    {
        var set = new List<char> { ZeroWidthSpace };
        for (int c = 0; c <= 0xFFFF; c++)
            if (char.IsWhiteSpace((char)c)) set.Add((char)c);
        return set.ToArray();
    }

    /// Аналог Swift-ового `trimmingCharacters(in: .whitespacesAndNewlines)`.
    public static string Trim(string s) => s.Trim(FoundationWhitespace);

    /// Аналог `CharacterSet.whitespacesAndNewlines.contains(scalar)`.
    public static bool IsWhitespace(char c) => char.IsWhiteSpace(c) || c == ZeroWidthSpace;
}
