using System.Globalization;
using RimeoAgent.Models;

namespace RimeoAgent.Services;

// Битые треки: запись в библиотеке есть, файла на диске нет. На реальной библиотеке это
// 150 треков из 2280 (6.6%) — импорт из старой медиатеки, пути со старым юзернеймом
// (такого пользователя больше не существует) и записи вида "soundcloud:tracks:123",
// которые вообще не файлы.
//
// ПОЧЕМУ ЭТО ВАЖНО ИМЕННО ДЛЯ РЕКОМЕНДАЦИЙ. Битый трек НИКОГДА не игрался — по определению,
// играть-то нечего. Значит для квоты открытий (она берёт именно непроигранные треки) он
// выглядит идеальным кандидатом: 131 из 150 битых треков непроигранные. Без этого гейта
// блок «что добавить» начал бы подсовывать треки, которых физически нет на диске — тот самый
// «случайный мусор», на который и жаловался пользователь.
//
// ЦЕНА ПРОВЕРКИ. File.Exists на 2280 треков в КАЖДОМ запросе — недопустимо. Поэтому множество
// недоступных id считается один раз на версию библиотеки и кэшируется.
public sealed class TrackAvailability
{
    public static readonly TrackAvailability Shared = new();
    private TrackAvailability() { }

    private readonly object _lock = new();
    private string _version = "";
    private HashSet<string> _unavailable = new(StringComparer.Ordinal);

    /// Ключ кэша. Кроме версии библиотеки в него входит СПИСОК ГОТОВЫХ ТОМОВ: отключённый
    /// внешний (или отвалившийся сетевой) диск делает свои треки временно недоступными, но
    /// не мёртвыми навсегда. Воткнули диск обратно — ключ поменялся, множество пересчиталось,
    /// треки вернулись в выдачу. Без этого они «умерли» бы до следующего изменения библиотеки.
    ///
    /// РАЗНИЦА С macOS. Там ключ строится из содержимого /Volumes. На Windows нет единой точки
    /// монтирования, эквивалент — сами тома: DriveInfo.GetDrives(), отфильтрованные по IsReady
    /// (несмонтированный CD-привод / отвалившийся сетевой диск числятся в списке, но не готовы —
    /// без фильтра ключ бы не менялся при их появлении/пропаже).
    private static string VersionKey(LibraryData lib)
    {
        string volumes;
        try
        {
            // Sort ordinal + join: ключ обязан быть детерминированным, а порядок выдачи
            // GetDrives() формально не гарантирован.
            var names = DriveInfo.GetDrives()
                .Where(d => d.IsReady)
                .Select(d => d.Name)
                .OrderBy(n => n, StringComparer.Ordinal);
            volumes = string.Join(",", names);
        }
        catch
        {
            // Перечисление томов может кинуть (например, IOException на битом сетевом
            // маппинге). Тогда ключ строится без томов — хуже кэшируется, но не падает.
            volumes = "";
        }
        // "R" + InvariantCulture: XmlDate — double, и под локалью с запятой-разделителем
        // ключ разъехался бы между машинами и между запусками.
        var xmlDate = lib.XmlDate.ToString("R", CultureInfo.InvariantCulture);
        return $"{xmlDate}|{lib.Tracks.Count}|{volumes}";
    }

    /// id треков, которые сейчас нечем играть. Тяжёлый проход — только при смене ключа.
    public HashSet<string> UnavailableIds(LibraryData lib)
    {
        var key = VersionKey(lib);
        lock (_lock)
        {
            if (key == _version) return new HashSet<string>(_unavailable, StringComparer.Ordinal);

            var dead = new HashSet<string>(StringComparer.Ordinal);
            foreach (var t in lib.Tracks)
            {
                if (!IsPlayable(t.Location)) dead.Add(t.Id);
            }
            _version = key;
            _unavailable = dead;
            // Копия наружу: в Swift Set — value type, и вызывающий не мог испортить кэш.
            // В C# HashSet — ссылка, поэтому отдаём снимок, иначе чужой .Remove() тихо
            // «вылечил» бы битый трек до конца жизни процесса.
            return new HashSet<string>(dead, StringComparer.Ordinal);
        }
    }

    public void Invalidate()
    {
        lock (_lock)
        {
            _version = "";
            _unavailable = new HashSet<string>(StringComparer.Ordinal);
        }
    }

    /// Есть ли что играть по этому пути.
    ///
    /// Не-абсолютный путь отбрасываем сразу и НЕ трогаем диск: "soundcloud:tracks:123" — это
    /// не файл, а ссылка на стрим, которого у агента нет. Точно так же отсекаются относительные
    /// огрызки, оставшиеся от старых импортов.
    ///
    /// РАЗНИЦА С macOS. Там абсолютность определялась префиксом "/". На Windows абсолютный путь —
    /// это "C:\..." или UNC "\\server\share\...", поэтому проверка идёт через
    /// Path.IsPathFullyQualified: он принимает и UNC, и "D:\x", и отвергает "soundcloud:tracks:123"
    /// (двоеточие не на позиции 1), drive-relative "D:file.mp3" и относительные огрызки.
    public static bool IsPlayable(string location)
    {
        var path = (location ?? "").Trim();
        if (path.Length == 0) return false;
        try
        {
            if (!Path.IsPathFullyQualified(path)) return false;
            // File.Exists (а не Directory/любой inode): в отличие от FileManager.fileExists,
            // папка по пути трека здесь честно считается «нечем играть».
            return File.Exists(path);
        }
        catch
        {
            // Путь с недопустимыми для тома символами / слишком длинный — играть нечем.
            // Молча false вместо исключения наружу: это гейт рекомендаций, а не валидатор.
            return false;
        }
    }
}
