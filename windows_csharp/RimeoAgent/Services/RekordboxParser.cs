using System.Globalization;
using System.Xml.Linq;
using Microsoft.Data.Sqlite;
using RimeoAgent.Config;
using RimeoAgent.Models;

namespace RimeoAgent.Services;

public sealed class RekordboxParser
{
    public static readonly RekordboxParser Shared = new();

    private readonly object _lock = new();
    private LibraryData? _cachedData;
    private double       _cachedMtime;
    private string       _cachedSourceKey = "";
    // Производный индекс id → Track, строится ВМЕСТЕ с _cachedData (единый источник
    // правды). Раньше TrackById делал Parse().Tracks.FirstOrDefault — линейный скан
    // библиотеки на КАЖДЫЙ /stream, а плеер шлёт range-шторм из десятков запросов на
    // один трек. Паритет с cachedTrackIndex в macOS RekordboxParser.swift.
    private Dictionary<string, Track> _cachedTrackIndex = new();
    // Debounce: даже если mtime сменился, не переразбираем чаще, чем раз в N сек —
    // чтобы checkpoint Rekordbox не молотил диск во время стрима. Реальные правки
    // подхватятся с задержкой < N сек. Паритет с macOS-агентом.
    private double       _lastParseAt;
    private const double MinReparseInterval = 3.0;

    public LibraryData Parse()
    {
        lock (_lock) { return ApplyHistoryNames(ParseInternal()); }
    }

    // Overlay user-chosen history names (DataStore.history_names) on the parsed
    // library. Applied on every public Parse() so a rename shows on the next
    // /api/data without re-reading the DB. Rekordbox's own DB is never written.
    private static LibraryData ApplyHistoryNames(LibraryData data)
    {
        var overrides = DataStore.Shared.Data.HistoryNames;
        if (overrides.Count == 0) return data;
        // Clone only the renamed entries so the cached library keeps the original
        // DB names — otherwise a later reset couldn't restore them.
        var playlists = data.Playlists.Select(pl =>
        {
            if (pl.History == true && pl.HistoryId != null
                && overrides.TryGetValue(pl.HistoryId, out var custom)
                && !string.IsNullOrEmpty(custom))
            {
                // ⚠️ Копируем ВСЕ поля. Раньше здесь пересобирался Playlist только из
                // Path/Date/Updated/History/HistoryId/Name — и переименование истории
                // ТЕРЯЛО Smart/RekordboxId/Parent/IsFolder/IsSmart/Seq. Для history-узла
                // они сейчас null, но молчаливая потеря полей на копировании модели —
                // ровно тот баг, который потом всплывает у обычных плейлистов.
                return new Playlist
                {
                    Path        = pl.Path,
                    Date        = pl.Date,
                    Smart       = pl.Smart,
                    Updated     = pl.Updated,
                    History     = pl.History,
                    HistoryId   = pl.HistoryId,
                    Name        = custom,
                    RekordboxId = pl.RekordboxId,
                    Parent      = pl.Parent,
                    IsFolder    = pl.IsFolder,
                    IsSmart     = pl.IsSmart,
                    Seq         = pl.Seq,
                };
            }
            return pl;
        }).ToList();
        return new LibraryData { Tracks = data.Tracks, Playlists = playlists, XmlDate = data.XmlDate, Source = data.Source };
    }

    private LibraryData ParseInternal()
    {
        var dbPath = AppConfig.Shared.DbPath;
        if (AppConfig.Shared.DbSourceEnabled && !string.IsNullOrEmpty(dbPath) && File.Exists(dbPath))
        {
            var mtime = DbMtime(dbPath);
            var key = $"db:{dbPath}";
            if (_cachedData != null && key == _cachedSourceKey)
            {
                if (mtime == _cachedMtime) return _cachedData;
                // mtime сменился, но не парсим чаще раза в N сек (debounce).
                if (Now() - _lastParseAt < MinReparseInterval) return _cachedData;
            }
            _lastParseAt = Now();

            Log.Info("Parsing Rekordbox master.db (cache miss)…");
            // mtime передаём ВНУТРЬ, а не пересчитываем там: внутри был GetMtime(dbPath),
            // то есть mtime только самого файла БЕЗ -wal. Rekordbox пишет в WAL-режиме,
            // и mtime master.db заморожен до checkpoint (часами). Ключ КЭША при этом
            // WAL-осведомлён — получалось, что парсер библиотеку перечитывает, а
            // LibraryData.XmlDate остаётся прежним. А по XmlDate версионируются
            // CoPlayGraph и TrackAvailability: граф не пересобирался бы на новой
            // библиотеке и продолжал рекомендовать по старой. Ровно тот же mtime, что
            // и в ключе кэша, macOS отдаёт хелперу аргументом.
            var result = ParseMasterDb(dbPath, mtime);
            // Разбор БД мог провалиться (сменился ключ SQLCipher, поехала схема в новой
            // версии Rekordbox) — тогда он отдаёт пустую библиотеку. Класть её в кэш и
            // отдавать клиенту нельзя: агент показал бы ПУСТУЮ библиотеку вместо того,
            // чтобы съехать на экспортированный XML. macOS в этом месте падает на XML —
            // делаем так же, иначе одна неудачная миграция Rekordbox выключает
            // Windows-агент целиком, а mac продолжает работать.
            if (result.Tracks.Count > 0)
            {
                SetCache(result, mtime, key);
                Log.Info($"DB parsed: {result.Tracks.Count} tracks");
                return result;
            }
            Log.Warn("master.db parse produced no tracks — falling back to XML source");
        }

        var xmlPath = AppConfig.Shared.XmlPath;
        if (AppConfig.Shared.XmlSourceEnabled && !string.IsNullOrEmpty(xmlPath) && File.Exists(xmlPath))
        {
            var mtime = GetMtime(xmlPath);
            var key = $"xml:{xmlPath}";
            if (_cachedData != null && mtime == _cachedMtime && key == _cachedSourceKey)
                return _cachedData;

            Log.Info("Parsing Rekordbox XML (cache miss)…");
            var result = ParseXml(xmlPath, mtime);
            SetCache(result, mtime, key);
            Log.Info($"XML parsed: {result.Tracks.Count} tracks");
            return result;
        }

        return new LibraryData();
    }

    /// Единая точка установки кеша: данные + mtime + ключ + производный индекс id→Track.
    /// Здесь же явно сбрасываются ПРОИЗВОДНЫЕ кэши: граф совместных проигрываний учится
    /// на составах плейлистов/историй, а список недоступных треков — на Location. Оба
    /// версионируются по ключу библиотеки, но versioning ловит смену библиотеки лениво,
    /// на первом запросе; явный сброс здесь честнее и не даёт графу секунду-другую
    /// отвечать по старому составу сразу после переразбора базы.
    private void SetCache(LibraryData data, double mtime, string sourceKey)
    {
        _cachedData      = data;
        _cachedMtime     = mtime;
        _cachedSourceKey = sourceKey;

        var index = new Dictionary<string, Track>(data.Tracks.Count);
        foreach (var t in data.Tracks) index[t.Id] = t;
        _cachedTrackIndex = index;

        CoPlayGraph.Shared.Invalidate();
        TrackAvailability.Shared.Invalidate();
    }

    private const string RekordboxDbKey = "402fd482c38817c35ffa8ffb8c7d93143b749e7d315df7a81732a1ff43608497";

    // ── Разбор дат Rekordbox ────────────────────────────────────────────────
    // djmdContent.created_at выглядит как "2026-05-15 10:23:45.123 +00:00": пробел
    // вместо T, дробные секунды, смещение. DateTime.TryParse(RoundtripKind) это НЕ
    // разбирает ⇒ свежедобавленные треки получали timestamp 0 и тонули на дне
    // отсортированного по дате списка. Порт parseRekordboxDate из HelperMain.swift.
    // Всё строго InvariantCulture: на русской/немецкой Windows парсер по текущей
    // локали спотыкается о разделители, а библиотека обязана читаться одинаково.
    private static readonly string[] RekordboxDateFormats =
    {
        "yyyy-MM-dd HH:mm:ss.ffffff zzz",
        "yyyy-MM-dd HH:mm:ss.fff zzz",
        "yyyy-MM-dd HH:mm:ss zzz",
        "yyyy-MM-dd HH:mm:ss.ffffff",
        "yyyy-MM-dd HH:mm:ss.fff",
        "yyyy-MM-dd HH:mm:ss",
        "yyyy-MM-dd'T'HH:mm:ss.ffffff",
        "yyyy-MM-dd'T'HH:mm:ss",
        "yyyy-MM-dd",
    };

    private const DateTimeStyles RbDateStyles =
        DateTimeStyles.AssumeUniversal | DateTimeStyles.AdjustToUniversal;

    private static double? ParseRekordboxDate(string? raw)
    {
        var s = (raw ?? "").Trim();
        if (s.Length == 0) return null;

        // Общий разбор (ISO 8601 с 'T'/'Z' и вариант с пробелом) — покрывает
        // большинство строк Rekordbox; точные форматы ниже добиваются остаток.
        if (DateTimeOffset.TryParse(s, CultureInfo.InvariantCulture, RbDateStyles, out var dto))
            return (dto.UtcDateTime - DateTime.UnixEpoch).TotalSeconds;

        if (DateTimeOffset.TryParseExact(s, RekordboxDateFormats, CultureInfo.InvariantCulture,
                                         RbDateStyles, out var exact))
            return (exact.UtcDateTime - DateTime.UnixEpoch).TotalSeconds;

        return null;
    }

    private static double AsTimestamp(string createdAt, string fallbackDate)
        => ParseRekordboxDate(createdAt) ?? ParseRekordboxDate(fallbackDate) ?? 0;

    // ── Типобезопасное чтение колонок ───────────────────────────────────────
    // SQLite типизирует значения, а не колонки: BPM может приехать как long или как
    // double. Прежний код звал .ToString() и парсил обратно по ТЕКУЩЕЙ локали —
    // на локали с запятой-разделителем это тихая потеря значения. Читаем по типу.
    private static string ColText(SqliteDataReader r, int i)
        => r.IsDBNull(i) ? "" : (r.GetValue(i)?.ToString() ?? "");

    private static double ColDouble(SqliteDataReader r, int i)
    {
        if (r.IsDBNull(i)) return 0;
        return r.GetValue(i) switch
        {
            double d => d,
            long   l => l,
            int    n => n,
            decimal m => (double)m,
            string s => double.TryParse(s, NumberStyles.Float, CultureInfo.InvariantCulture, out var v) ? v : 0,
            _ => 0,
        };
    }

    private static int ColInt(SqliteDataReader r, int i)
    {
        if (r.IsDBNull(i)) return 0;
        return r.GetValue(i) switch
        {
            long   l => unchecked((int)l),
            int    n => n,
            // sqlite3_column_int64 усекает дробную часть, а не округляет — повторяем.
            double d => (int)d,
            decimal m => (int)m,
            string s => int.TryParse(s, NumberStyles.Integer, CultureInfo.InvariantCulture, out var v) ? v : 0,
            _ => 0,
        };
    }

    // ── Узел дерева плейлистов ──────────────────────────────────────────────
    private sealed class PlaylistNode
    {
        public string Id        = "";
        public string Name      = "";
        public string Parent    = "";
        public int    Attribute;          // 0 обычный, 1 папка, 4 smart
        public string SmartList = "";
        public int?   Seq;                // djmdPlaylist.Seq — порядок внутри родителя
    }

    // Поля, нужные для вычисления условий smart-плейлиста. Держим параллельно
    // трекам (тот же индекс), заполняем в том же проходе — до сортировки.
    private sealed class SmartEvalRow
    {
        public string Artist    = "";
        public string Title     = "";
        public string Genre     = "";
        public string Label     = "";
        public string Key       = "";
        public string Comments  = "";
        public string FileName  = "";
        public double Bpm;
        public int    Bitrate;
        public int    PlayCount;
        public string Year      = "";
        public double DateAdded;          // epoch seconds
        public string StockDate = "";     // "YYYY-MM-DD"
    }

    private sealed class SmartCondition
    {
        public string Property   = "";
        public int    Op;
        public string ValueLeft  = "";
        public string ValueRight = "";
        public string Unit       = "";
    }

    private static LibraryData ParseMasterDb(string dbPath, double mtime)
    {
        try
        {
            SQLitePCL.Batteries_V2.Init();
            var cs = new SqliteConnectionStringBuilder
            {
                DataSource = dbPath,
                Password   = RekordboxDbKey,
                Mode       = SqliteOpenMode.ReadOnly,
            }.ToString();

            using var conn = new SqliteConnection(cs);
            conn.Open();

            // ── Tracks ──────────────────────────────────────────────────────
            var tracksDb   = new List<Track>();
            var trackIndex = new Dictionary<string, int>();
            var evalRows   = new List<SmartEvalRow>();   // параллельно tracksDb

            // SQL дословно из HelperMain.swift (источник правды по формату выдачи).
            // Commnt / FileNameL / StockDate нужны ТОЛЬКО smart-условиям, ImagePath —
            // обложке (Rekordbox хранит её отдельно от файла), Length — движку
            // рекомендаций (медиана длительности состава + флаг duration_match).
            const string trackSql = @"
                SELECT c.ID,
                       COALESCE(a.Name,''),
                       COALESCE(c.Title,''),
                       COALESCE(g.Name,''),
                       COALESCE(l.Name,''),
                       COALESCE(c.ReleaseYear,''),
                       COALESCE(k.ScaleName,'—'),
                       COALESCE(c.BPM,0),
                       COALESCE(c.BitRate,0),
                       COALESCE(c.DJPlayCount,0),
                       COALESCE(c.FolderPath,''),
                       COALESCE(c.DateCreated,''),
                       COALESCE(c.created_at,''),
                       COALESCE(c.ImagePath,''),
                       COALESCE(c.Commnt,''),
                       COALESCE(c.FileNameL,''),
                       COALESCE(c.StockDate,''),
                       COALESCE(c.Length,0)
                FROM djmdContent c
                LEFT JOIN djmdArtist a ON c.ArtistID = a.ID
                LEFT JOIN djmdGenre  g ON c.GenreID  = g.ID
                LEFT JOIN djmdLabel  l ON c.LabelID  = l.ID
                LEFT JOIN djmdKey    k ON c.KeyID    = k.ID
                WHERE c.rb_local_deleted = 0";

            using (var cmd = conn.CreateCommand())
            {
                cmd.CommandText = trackSql;
                using var rdr = cmd.ExecuteReader();
                while (rdr.Read())
                {
                    var tid = ColText(rdr, 0);
                    if (tid.Length == 0) continue;

                    var fallbackDate = ColText(rdr, 11);          // DateCreated
                    var createdAt    = ColText(rdr, 12);          // created_at
                    var ts           = AsTimestamp(createdAt, fallbackDate);
                    // date_str берётся из DateCreated (а НЕ из created_at) — как в
                    // HelperMain.swift: created_at несёт время правки записи в БД,
                    // DateCreated — дату добавления трека, её и показываем.
                    //
                    // Гейт — на ПУСТОТУ, а не на длину (Swift: `fallbackDate.isEmpty ?
                    // "0000-00-00" : String(prefix(10))`). Кривой импорт кладёт в
                    // DateCreated огрызок вроде "2026": macOS отдал бы "2026", а
                    // проверка на длину подменяла бы его на "0000-00-00" — то есть
                    // Windows врал бы, что даты нет, хотя она есть.
                    var dateStr      = fallbackDate.Length == 0
                        ? "0000-00-00"
                        : (fallbackDate.Length >= 10 ? fallbackDate[..10] : fallbackDate);

                    var rawBpm    = ColDouble(rdr, 7);
                    var bpm       = rawBpm == 0 ? 0 : rawBpm / 100.0;
                    var bitrate   = ColInt(rdr, 8);
                    var playCount = ColInt(rdr, 9);
                    var lengthSec = ColDouble(rdr, 17);

                    var artist  = ColText(rdr, 1); if (artist.Length == 0) artist = "Unknown Artist";
                    var title   = ColText(rdr, 2); if (title.Length  == 0) title  = "Unknown Title";
                    var genre   = ColText(rdr, 3);
                    var label   = ColText(rdr, 4);
                    var relDate = ColText(rdr, 5);
                    var rawKey  = ColText(rdr, 6);                // уже '—' если NULL (COALESCE)
                    var key     = rawKey.Length == 0 ? "—" : rawKey;

                    tracksDb.Add(new Track
                    {
                        Id        = tid,
                        Artist    = artist,
                        Title     = title,
                        Genre     = genre,
                        Label     = label,
                        RelDate   = relDate,
                        Key       = key,
                        Bpm       = bpm,
                        Duration  = lengthSec > 0 ? lengthSec : null,
                        Bitrate   = bitrate,
                        PlayCount = playCount,
                        Location  = NormalizeDbPath(ColText(rdr, 10)),
                        Timestamp = ts,
                        DateStr   = dateStr,
                        ImagePath = ColText(rdr, 13),
                    });
                    trackIndex[tid] = tracksDb.Count - 1;

                    evalRows.Add(new SmartEvalRow
                    {
                        Artist    = artist,
                        Title     = title,
                        Genre     = genre,
                        Label     = label,
                        Key       = rawKey,          // сырой ключ (Camelot) для сравнения
                        Comments  = ColText(rdr, 14),
                        FileName  = ColText(rdr, 15),
                        Bpm       = bpm,
                        Bitrate   = bitrate,
                        PlayCount = playCount,
                        Year      = relDate,
                        DateAdded = ts,
                        StockDate = ColText(rdr, 16),
                    });
                }
            }

            // ── Playlists (узлы дерева) ─────────────────────────────────────
            var nodes = ReadPlaylistNodes(conn);

            // Путь узла = имена предков через " / ". Порт playlistPath из
            // HelperMain.swift: обрыв на "root" (виртуальный корень, строки в
            // djmdPlaylist для него нет) + защита от цикла через seen.
            string BuildPath(string id)
            {
                var parts = new List<string>();
                var seen  = new HashSet<string>(StringComparer.Ordinal);
                var cur   = id;
                while (cur.Length > 0 && cur != "root" && seen.Add(cur))
                {
                    if (!nodes.TryGetValue(cur, out var n)) break;
                    parts.Add(n.Name);
                    cur = n.Parent;
                }
                parts.Reverse();
                return string.Join(" / ", parts.Where(p => p.Length > 0));
            }

            // djmdPlaylist.updated_at → path (сортировка «Recently changed» на клиенте).
            // Defensive: если колонки нет в этой версии Rekordbox — ловим исключение и
            // оставляем словарь пустым; клиент падает на Date, библиотека не ломается.
            var playlistUpdated = new Dictionary<string, double>();
            try
            {
                using var cmd = conn.CreateCommand();
                cmd.CommandText = "SELECT ID, COALESCE(updated_at,'') FROM djmdPlaylist WHERE rb_local_deleted = 0";
                using var rdr = cmd.ExecuteReader();
                while (rdr.Read())
                {
                    var id  = ColText(rdr, 0);
                    var raw = ColText(rdr, 1);
                    if (id.Length == 0 || raw.Length == 0) continue;
                    var ts = ParseRekordboxDate(raw);
                    if (ts == null) continue;
                    var p = BuildPath(id);
                    if (p.Length == 0) continue;
                    // Одноимённые узлы схлопываются в один путь — берём максимум.
                    if (!playlistUpdated.TryGetValue(p, out var prev) || ts.Value > prev)
                        playlistUpdated[p] = ts.Value;
                }
            }
            catch (Exception ex) { Log.Warn($"playlist updated_at skipped: {ex.Message}"); }

            // ── Состав обычных плейлистов ───────────────────────────────────
            var playlistLatest = new Dictionary<string, double>();

            using (var cmd = conn.CreateCommand())
            {
                cmd.CommandText = "SELECT PlaylistID, ContentID, TrackNo FROM djmdSongPlaylist WHERE rb_local_deleted = 0";
                using var rdr = cmd.ExecuteReader();
                while (rdr.Read())
                {
                    var plId  = ColText(rdr, 0);
                    var tId   = ColText(rdr, 1);
                    var order = ColInt(rdr, 2);

                    if (!trackIndex.TryGetValue(tId, out var idx)) continue;
                    var pPath = BuildPath(plId);
                    if (pPath.Length == 0) continue;

                    tracksDb[idx].PlaylistIndices[pPath] = order;
                    if (!tracksDb[idx].Playlists.Contains(pPath))
                        tracksDb[idx].Playlists.Add(pPath);
                    if (tracksDb[idx].Timestamp > playlistLatest.GetValueOrDefault(pPath, 0))
                        playlistLatest[pPath] = tracksDb[idx].Timestamp;
                }
            }

            // ── Smart-плейлисты (Attribute == 4) ────────────────────────────
            // Их состава НЕТ в djmdSongPlaylist — он ВЫЧИСЛЯЕТСЯ из XML-правил в
            // колонке SmartList. Без этого smart-плейлисты приезжали пустыми, а
            // CoPlayGraph не мог их исключить и переучивался на том же жанровом
            // фильтре. Порядок обхода узлов — по ID (Ordinal), чтобы предупреждение
            // о коллизии путей и раскладка совпадали между запусками.
            var smartPaths = new HashSet<string>(StringComparer.Ordinal);
            foreach (var node in nodes.Values.OrderBy(n => n.Id, StringComparer.Ordinal))
            {
                if (node.Attribute != 4 || node.SmartList.Length == 0) continue;
                var parsed = ParseSmartConditions(node.SmartList);
                if (parsed == null) continue;
                var path = BuildPath(node.Id);
                if (path.Length == 0) continue;
                smartPaths.Add(path);

                var (logical, conditions) = parsed.Value;
                var order = 0;
                // Треки ещё в порядке выдачи БД (сортировка по дате — ниже), как и в
                // Swift: порядок внутри smart-плейлиста обязан совпасть с macOS.
                for (int i = 0; i < tracksDb.Count; i++)
                {
                    if (!SmartRowMatches(evalRows[i], logical, conditions)) continue;
                    order++;
                    tracksDb[i].PlaylistIndices[path] = order;
                    if (!tracksDb[i].Playlists.Contains(path))
                        tracksDb[i].Playlists.Add(path);
                    if (tracksDb[i].Timestamp > playlistLatest.GetValueOrDefault(path, 0))
                        playlistLatest[path] = tracksDb[i].Timestamp;
                }
            }

            // ── Play histories (djmdHistory + djmdSongHistory) ───────────────
            // Membership lands in track.Histories (separate from Playlists); each
            // session is emitted as a Playlist with History=true. Wrapped so older
            // Rekordbox DBs without these tables just yield no histories.
            var historyPlaylists = new List<Playlist>();
            try
            {
                var histName = new Dictionary<string, string>();
                var histDate = new Dictionary<string, double>();
                using (var cmd = conn.CreateCommand())
                {
                    // Attribute = 0 → a real per-set history session; Attribute = 1 → a
                    // Year/Month folder node in Rekordbox's history tree. Without this
                    // filter the folder rows (named "2026", "6", …) leak in as phantom
                    // sessions — the "fake history" bug. Mirrors pyrekordbox / the
                    // include_folders=false convention (same as djmdPlaylist).
                    cmd.CommandText = "SELECT ID, COALESCE(Name,''), COALESCE(DateCreated,''), COALESCE(created_at,'') FROM djmdHistory WHERE rb_local_deleted = 0 AND COALESCE(Attribute,0) = 0";
                    using var rdr = cmd.ExecuteReader();
                    while (rdr.Read())
                    {
                        var hid = ColText(rdr, 0);
                        if (hid.Length == 0) continue;
                        var name = ColText(rdr, 1).Trim();
                        if (name.Length == 0) name = $"History {hid}";
                        histName[hid] = name;
                        histDate[hid] = AsTimestamp(ColText(rdr, 3), ColText(rdr, 2));
                    }
                }
                using (var cmd = conn.CreateCommand())
                {
                    cmd.CommandText = "SELECT HistoryID, ContentID, TrackNo FROM djmdSongHistory WHERE rb_local_deleted = 0";
                    using var rdr = cmd.ExecuteReader();
                    while (rdr.Read())
                    {
                        var hid   = ColText(rdr, 0);
                        var tId   = ColText(rdr, 1);
                        var order = ColInt(rdr, 2);
                        if (!histName.ContainsKey(hid)) continue;
                        if (!trackIndex.TryGetValue(tId, out var idx)) continue;
                        var key = $"hist:{hid}";
                        tracksDb[idx].HistoryIndices[key] = order;
                        if (!tracksDb[idx].Histories.Contains(key))
                            tracksDb[idx].Histories.Add(key);
                    }
                }
                historyPlaylists = histName
                    .OrderBy(kv => kv.Key, StringComparer.Ordinal)   // детерминированный порядок выдачи
                    .Select(kv => new Playlist
                    {
                        Path      = $"hist:{kv.Key}",
                        Date      = histDate.GetValueOrDefault(kv.Key, 0),
                        Smart     = false,
                        Updated   = histDate.GetValueOrDefault(kv.Key, 0),
                        History   = true,
                        HistoryId = kv.Key,
                        Name      = kv.Value,
                    }).ToList();
            }
            catch (Exception ex)
            {
                Log.Warn($"history parse skipped: {ex.Message}");
            }

            tracksDb.Sort((a, b) => b.Timestamp.CompareTo(a.Timestamp));

            // Отдаём узел для КАЖДОГО djmdPlaylist — папки (Attribute==1), пустые и
            // smart-плейлисты тоже, а не только те, у кого есть треки. Иначе клиент не
            // видит дерева и не может адресовать плейлист по rekordbox_id (мутации
            // ходят строго по нему). Одноимённые узлы схлопываются в один путь показа —
            // пишем Log.Warn, но узлы отдаём: составы не сольются, они уже разведены
            // по rekordbox_id.
            var emittedPaths = new HashSet<string>(StringComparer.Ordinal);
            var regular      = new List<Playlist>();
            foreach (var node in nodes.Values.OrderBy(n => n.Id, StringComparer.Ordinal))
            {
                var path = BuildPath(node.Id);
                if (path.Length == 0) continue;
                if (!emittedPaths.Add(path))
                    Log.Warn($"playlist path collision: {path}");

                regular.Add(new Playlist
                {
                    Path        = path,
                    Date        = playlistLatest.GetValueOrDefault(path, 0),
                    Smart       = smartPaths.Contains(path),
                    Updated     = playlistUpdated.GetValueOrDefault(path, playlistLatest.GetValueOrDefault(path, 0)),
                    RekordboxId = node.Id,
                    Parent      = node.Parent.Length == 0 ? "root" : node.Parent,
                    IsFolder    = node.Attribute == 1,
                    IsSmart     = node.Attribute == 4,
                    Seq         = node.Seq,
                });
            }

            // ⚠️ Порядок Rekordbox — это Seq ВНУТРИ родителя, а не алфавит по пути (и не
            // «сначала папки»: у папок и плейлистов единое пространство Seq, папка может
            // стоять НИЖЕ плейлиста). Раньше Windows отдавал алфавит ⇒ пункт «Rekordbox
            // order» показывал разный порядок на iOS-клиентах в зависимости от того,
            // какой агент отдал библиотеку. History-сессии всегда в конец.
            //
            // Тайбрейк — по RekordboxId, а НЕ по Path (та же строка в HelperMain.swift).
            // Seq уникален только внутри родителя, поэтому равный Seq = узлы в РАЗНЫХ
            // папках, и их взаимный порядок в плоском списке ни на что не влияет (клиент
            // собирает дерево по parent). Но сортировать их надо ОДИНАКОВО с macOS, а по
            // пути это невозможно: Swift сравнивает String канонически, C# — ординально
            // по UTF-16. На плейлисте с эмодзи (суррогатная пара) или диакритикой в NFD
            // платформы разошлись бы. Id — ASCII-номер, сравнивается одинаково везде.
            var playlists = regular
                .OrderBy(p => p.Seq ?? 0)
                .ThenBy(p => p.RekordboxId, StringComparer.Ordinal)
                .ToList();
            playlists.AddRange(historyPlaylists);

            // mtime приходит АРГУМЕНТОМ (WAL-осведомлённый, тот же, что в ключе кэша).
            // Локальный GetMtime(dbPath) здесь читал бы только сам файл БЕЗ -wal — и
            // XmlDate замирал бы на часы, пока Rekordbox не сделает checkpoint.
            return new LibraryData { Tracks = tracksDb, Playlists = playlists, XmlDate = mtime, Source = "db" };
        }
        catch (Exception ex)
        {
            Log.Error($"master.db parse failed: {ex.Message}");
            return new LibraryData();
        }
    }

    /// Чтение узлов djmdPlaylist. Seq/SmartList/Attribute обязательны для дерева и
    /// smart-плейлистов, но на экзотической схеме без Seq запрос упадёт — тогда
    /// перечитываем без него (seq = null → узел уедет в начало сортировки), а не
    /// роняем всю библиотеку. Порт defensive-ветки из python-хелпера macOS.
    private static Dictionary<string, PlaylistNode> ReadPlaylistNodes(SqliteConnection conn)
    {
        const string withSeq = @"SELECT ID, Name, ParentID, COALESCE(Attribute,0), COALESCE(SmartList,''), COALESCE(Seq,0)
                                 FROM djmdPlaylist WHERE rb_local_deleted = 0";
        const string noSeq   = @"SELECT ID, Name, ParentID, COALESCE(Attribute,0), COALESCE(SmartList,'')
                                 FROM djmdPlaylist WHERE rb_local_deleted = 0";

        for (int attempt = 0; attempt < 2; attempt++)
        {
            var hasSeq = attempt == 0;
            try
            {
                var nodes = new Dictionary<string, PlaylistNode>(StringComparer.Ordinal);
                using var cmd = conn.CreateCommand();
                cmd.CommandText = hasSeq ? withSeq : noSeq;
                using var rdr = cmd.ExecuteReader();
                while (rdr.Read())
                {
                    var id = ColText(rdr, 0);
                    if (id.Length == 0) continue;
                    nodes[id] = new PlaylistNode
                    {
                        Id        = id,
                        Name      = ColText(rdr, 1),
                        Parent    = ColText(rdr, 2),
                        Attribute = ColInt(rdr, 3),
                        SmartList = ColText(rdr, 4),
                        Seq       = hasSeq ? ColInt(rdr, 5) : null,
                    };
                }
                return nodes;
            }
            catch (Exception ex) when (hasSeq)
            {
                Log.Warn($"djmdPlaylist.Seq unavailable, falling back: {ex.Message}");
            }
        }
        return new Dictionary<string, PlaylistNode>(StringComparer.Ordinal);
    }

    // ── Smart-плейлисты: разбор правил и сопоставление ───────────────────────
    // Rekordbox держит smart-плейлист как Attribute == 4 + XML в колонке SmartList.
    // Коды операторов (как в pyrekordbox): 1 equal, 2 not-equal, 3 greater, 4 less,
    // 5 in-range, 6 in-last, 7 not-in-last, 8 contains, 9 not-contains,
    // 10 starts-with, 11 ends-with. LogicalOperator: 1 = ALL (AND), 2 = ANY (OR).

    private static (int Logical, List<SmartCondition> Conditions)? ParseSmartConditions(string xml)
    {
        try
        {
            var root = XDocument.Parse(xml).Root;
            if (root == null) return null;

            var logical = int.TryParse(root.Attribute("LogicalOperator")?.Value,
                                       NumberStyles.Integer, CultureInfo.InvariantCulture, out var lg) ? lg : 1;

            var conds = new List<SmartCondition>();
            foreach (var node in root.Elements("CONDITION"))
            {
                conds.Add(new SmartCondition
                {
                    Property   = node.Attribute("PropertyName")?.Value ?? "",
                    Op         = int.TryParse(node.Attribute("Operator")?.Value,
                                              NumberStyles.Integer, CultureInfo.InvariantCulture, out var op) ? op : 0,
                    ValueLeft  = node.Attribute("ValueLeft")?.Value  ?? "",
                    ValueRight = node.Attribute("ValueRight")?.Value ?? "",
                    Unit       = node.Attribute("ValueUnit")?.Value  ?? "",
                });
            }
            return conds.Count == 0 ? null : (logical, conds);
        }
        catch
        {
            // Битый/незнакомый SmartList — плейлист просто останется пустым, а не
            // уронит разбор всей библиотеки.
            return null;
        }
    }

    private enum SmartKind { None, Text, Number, Date }

    private readonly record struct SmartValue(SmartKind Kind, string Text, double Number, DateTime? Date);

    private static SmartValue SmartFieldValue(string property, SmartEvalRow row) => property switch
    {
        "artist"                     => new SmartValue(SmartKind.Text, row.Artist, 0, null),
        "name" or "title"            => new SmartValue(SmartKind.Text, row.Title, 0, null),
        "genre"                      => new SmartValue(SmartKind.Text, row.Genre, 0, null),
        "label"                      => new SmartValue(SmartKind.Text, row.Label, 0, null),
        "key"                        => new SmartValue(SmartKind.Text, row.Key, 0, null),
        "comments"                   => new SmartValue(SmartKind.Text, row.Comments, 0, null),
        "fileName"                   => new SmartValue(SmartKind.Text, row.FileName, 0, null),
        "bpm"                        => new SmartValue(SmartKind.Number, "", row.Bpm, null),
        "bitRate" or "bitrate"       => new SmartValue(SmartKind.Number, "", row.Bitrate, null),
        "dj_play_count" or "playCount" => new SmartValue(SmartKind.Number, "", row.PlayCount, null),
        "year"                       => new SmartValue(SmartKind.Number, "", SmartNumber(row.Year), null),
        "stockDate" or "dateReleased" => new SmartValue(SmartKind.Date, "", 0, SmartParseDateOnly(row.StockDate)),
        "dateAdded" or "dateCreated" => new SmartValue(SmartKind.Date, "", 0, DateTime.UnixEpoch.AddSeconds(row.DateAdded)),
        _                            => new SmartValue(SmartKind.None, "", 0, null),
    };

    private static double SmartNumber(string s)
        => double.TryParse(s, NumberStyles.Float, CultureInfo.InvariantCulture, out var v) ? v : 0;

    /// "YYYY-MM-DD…" → дата (UTC, полночь). Только первые 10 символов, как в Swift:
    /// StockDate иногда приезжает с временем, а сравнивать надо по дню.
    private static DateTime? SmartParseDateOnly(string s)
    {
        if (s.Length < 10) return null;
        var head = s[..10];
        if (DateTime.TryParseExact(head, "yyyy-MM-dd", CultureInfo.InvariantCulture,
                                   DateTimeStyles.AssumeUniversal | DateTimeStyles.AdjustToUniversal, out var d))
            return d;
        return null;
    }

    private static bool SmartEvalText(int op, string field, string vl)
    {
        var s = field.ToLowerInvariant();
        var v = vl.ToLowerInvariant();
        return op switch
        {
            1  => s == v,
            2  => s != v,
            8  => s.Contains(v, StringComparison.Ordinal),
            9  => !s.Contains(v, StringComparison.Ordinal),
            10 => s.StartsWith(v, StringComparison.Ordinal),
            11 => s.EndsWith(v, StringComparison.Ordinal),
            _  => false,
        };
    }

    private static bool SmartEvalNumber(int op, double x, string vl, string vr)
    {
        var a = SmartNumber(vl);
        var b = SmartNumber(vr);
        return op switch
        {
            1 => x == a,
            2 => x != a,
            3 => x > a,
            4 => x < a,
            5 => x >= a && x <= b,
            _ => false,
        };
    }

    private static bool SmartEvalDate(int op, DateTime? d, string vl, string vr, string unit)
    {
        if (d == null) return false;
        switch (op)
        {
            case 5:
            {
                var a = SmartParseDateOnly(vl);
                var b = SmartParseDateOnly(vr);
                if (a == null || b == null) return false;
                return d.Value >= a.Value && d.Value <= b.Value;
            }
            case 6:
            case 7:
            {
                var n = int.TryParse(vl, NumberStyles.Integer, CultureInfo.InvariantCulture, out var v) ? v : 0;
                // Порог считаем от UtcNow: календарь Swift здесь тоже в UTC. Календарные
                // месяцы/годы (AddMonths/AddYears), а не «30 дней» — иначе «за последний
                // месяц» плыло бы относительно Rekordbox.
                var now = DateTime.UtcNow;
                var threshold = unit switch
                {
                    "month" => now.AddMonths(-n),
                    "week"  => now.AddDays(-7.0 * n),
                    "year"  => now.AddYears(-n),
                    _       => now.AddDays(-n),
                };
                var within = d.Value >= threshold;
                return op == 6 ? within : !within;
            }
            default:
                return false;
        }
    }

    private static bool SmartEvalCondition(SmartCondition cond, SmartEvalRow row)
    {
        var fv = SmartFieldValue(cond.Property, row);
        return fv.Kind switch
        {
            SmartKind.Text   => SmartEvalText(cond.Op, fv.Text, cond.ValueLeft),
            SmartKind.Number => SmartEvalNumber(cond.Op, fv.Number, cond.ValueLeft, cond.ValueRight),
            SmartKind.Date   => SmartEvalDate(cond.Op, fv.Date, cond.ValueLeft, cond.ValueRight, cond.Unit),
            _                => false,
        };
    }

    private static bool SmartRowMatches(SmartEvalRow row, int logical, List<SmartCondition> conditions)
    {
        if (conditions.Count == 0) return false;
        if (logical == 2) return conditions.Any(c => SmartEvalCondition(c, row));
        return conditions.All(c => SmartEvalCondition(c, row));
    }

    private static string NormalizeDbPath(string path)
    {
        if (string.IsNullOrEmpty(path)) return path;
        // FolderPath in master.db is already a Windows absolute path, but may be URL-encoded
        var s = Uri.UnescapeDataString(path);
        // Normalise any forward slashes that Pioneer occasionally writes
        return s.Replace('/', '\\');
    }

    private static LibraryData ParseXml(string xmlPath, double mtime)
    {
        try
        {
            var doc = XDocument.Load(xmlPath);
            var root = doc.Root;
            if (root == null) return new LibraryData();

            var tracksDb = new List<Track>();
            var trackIndex = new Dictionary<string, int>();

            var collection = root.Element("COLLECTION");
            if (collection != null)
            {
                foreach (var el in collection.Elements("TRACK"))
                {
                    var tid = el.Attribute("TrackID")?.Value ?? "";
                    if (string.IsNullOrEmpty(tid)) continue;

                    var rawDate = el.Attribute("DateAdded")?.Value ?? "";
                    var ts = ParseRekordboxDate(rawDate) ?? 0;

                    var bpm = XmlDouble(el, "AverageBpm");
                    // TotalTime (секунды) — та же роль, что Length в master.db: без неё
                    // движок рекомендаций не считает медиану длительности состава.
                    var dur = XmlDouble(el, "TotalTime");
                    var br  = (int)XmlDouble(el, "BitRate");
                    var pc  = (int)XmlDouble(el, "PlayCount");
                    var rawLoc = el.Attribute("Location")?.Value ?? "";

                    var track = new Track
                    {
                        Id        = tid,
                        Artist    = el.Attribute("Artist")?.Value ?? "Unknown Artist",
                        Title     = el.Attribute("Name")?.Value   ?? "Unknown Title",
                        Genre     = el.Attribute("Genre")?.Value  ?? "",
                        Label     = el.Attribute("Label")?.Value  ?? "",
                        RelDate   = el.Attribute("Year")?.Value   ?? "",
                        Key       = el.Attribute("Tonality")?.Value ?? "—",
                        Bpm       = bpm,
                        Duration  = dur > 0 ? dur : null,
                        Bitrate   = br,
                        PlayCount = pc,
                        Location  = NormalizePath(rawLoc),
                        Timestamp = ts,
                        DateStr   = rawDate.Length >= 10 ? rawDate[..10] : "0000-00-00",
                    };

                    trackIndex[tid] = tracksDb.Count;
                    tracksDb.Add(track);
                }
            }

            // Parse PLAYLISTS
            var allPlaylists = new Dictionary<string, double>();

            void WalkPlaylists(XElement node, List<string> path)
            {
                foreach (var n in node.Elements("NODE"))
                {
                    var nodeType = n.Attribute("Type")?.Value ?? "";
                    var name     = n.Attribute("Name")?.Value ?? "";
                    if (nodeType == "0")
                    {
                        WalkPlaylists(n, path.Append(name).ToList());
                    }
                    else if (nodeType == "1")
                    {
                        var filtered = path.Where(p => p.ToUpperInvariant() != "ROOT").ToList();
                        var pPath    = string.Join(" / ", filtered.Append(name));
                        if (!allPlaylists.ContainsKey(pPath)) allPlaylists[pPath] = 0;

                        int order = 1;
                        foreach (var tn in n.Elements("TRACK"))
                        {
                            var key = tn.Attribute("Key")?.Value ?? tn.Attribute("TrackID")?.Value ?? "";
                            if (trackIndex.TryGetValue(key, out var idx))
                            {
                                tracksDb[idx].PlaylistIndices[pPath] = order;
                                if (!tracksDb[idx].Playlists.Contains(pPath))
                                    tracksDb[idx].Playlists.Add(pPath);
                                if (tracksDb[idx].Timestamp > allPlaylists[pPath])
                                    allPlaylists[pPath] = tracksDb[idx].Timestamp;
                            }
                            order++;
                        }
                    }
                }
            }

            var plRoot = root.Element("PLAYLISTS");
            if (plRoot != null) WalkPlaylists(plRoot, new List<string>());

            tracksDb.Sort((a, b) => b.Timestamp.CompareTo(a.Timestamp));

            // XML-экспорт Rekordbox не несёт ни Seq, ни ID узлов — Seq/RekordboxId
            // остаются null, и клиент падает на алфавит. Это ЧЕСТНО: порядка Rekordbox
            // в XML попросту нет, притворяться нечем. Порядок выдачи детерминируем сами.
            var playlists = allPlaylists
                .OrderBy(kv => kv.Key, StringComparer.Ordinal)
                .Select(kv => new Playlist { Path = kv.Key, Date = kv.Value, Smart = false })
                .ToList();
            return new LibraryData { Tracks = tracksDb, Playlists = playlists, XmlDate = mtime, Source = "xml" };
        }
        catch (Exception ex)
        {
            Log.Error($"XML parse failed: {ex.Message}");
            return new LibraryData();
        }
    }

    // Числа в XML Rekordbox всегда с точкой-разделителем; парсим строго Invariant,
    // иначе на локали с запятой AverageBpm="128.50" превращается в 12850.
    private static double XmlDouble(XElement el, string attr)
    {
        var raw = el.Attribute(attr)?.Value;
        if (string.IsNullOrEmpty(raw)) return 0;
        return double.TryParse(raw, NumberStyles.Float, CultureInfo.InvariantCulture, out var v) ? v : 0;
    }

    private static string NormalizePath(string loc)
    {
        var s = loc;
        // StringComparison.Ordinal ЯВНО. Перегрузка StartsWith(string) сравнивает
        // культурно (ICU): игнорируемые символы (soft hyphen, ZWJ) в начале Location
        // дают ЛОЖНЫЙ StartsWith, после чего `s[..N]` срезает не тот кусок и путь
        // превращается в мусор. Для протокольного префикса культура не при чём.
        if (s.StartsWith("file://localhost/", StringComparison.Ordinal))
            s = s["file://localhost".Length..];
        else if (s.StartsWith("file:///", StringComparison.Ordinal))
            s = s["file://".Length..];

        // URL decode
        s = Uri.UnescapeDataString(s);

        // Convert Unix-style to Windows-style (e.g., /C:/Music → C:\Music)
        if (s.Length >= 3 && s[0] == '/' && s[2] == ':')
            s = s[1..].Replace('/', '\\');

        return s;
    }

    // Lookup of a track by Rekordbox id from the (cached) library. Used by the stream
    // route to read a track's bitrate for the hi-res down-convert decision. O(1) по
    // производному индексу: /stream приходит range-штормом, линейный скан там был
    // худшим местом парсера. Паритет с macOS RekordboxParser.track(byID:).
    public Track? TrackById(string id)
    {
        if (string.IsNullOrEmpty(id)) return null;
        lock (_lock)
        {
            _ = ParseInternal();   // прогрев кеша + индекса
            return _cachedTrackIndex.GetValueOrDefault(id);
        }
    }

    public void InvalidateCache()
    {
        lock (_lock)
        {
            _cachedData = null;
            _cachedMtime = 0;
            _cachedSourceKey = "";
            _cachedTrackIndex = new Dictionary<string, Track>();
        }
    }

    private static double GetMtime(string path)
    {
        try
        {
            return new DateTimeOffset(File.GetLastWriteTimeUtc(path)).ToUnixTimeMilliseconds() / 1000.0;
        }
        catch { return 0; }
    }

    private static double Now() => DateTimeOffset.UtcNow.ToUnixTimeMilliseconds() / 1000.0;

    // Rekordbox 6 master.db — SQLite в WAL-режиме: правки сначала попадают в
    // master.db-wal, а mtime самой master.db «заморожен» до checkpoint. Ключ кеша —
    // по новейшему из db / -wal, чтобы WAL-записи инвалидировали кеш.
    // NB: -shm НЕ учитываем (его SQLite дёргает при любом открытии БД даже на
    // чтение — иначе кеш сбрасывался бы почти на каждый запрос). Паритет с macOS.
    private static double DbMtime(string dbPath)
    {
        var latest = 0.0;
        foreach (var suffix in new[] { "", "-wal" })
        {
            var m = GetMtime(dbPath + suffix);
            if (m > latest) latest = m;
        }
        return latest;
    }
}
