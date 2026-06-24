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
                return new Playlist
                {
                    Path = pl.Path, Date = pl.Date,
                    History = pl.History, HistoryId = pl.HistoryId, Name = custom,
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
            var result = ParseMasterDb(dbPath);
            _cachedData = result;
            _cachedMtime = mtime;
            _cachedSourceKey = key;
            Log.Info($"DB parsed: {result.Tracks.Count} tracks");
            return result;
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
            _cachedData = result;
            _cachedMtime = mtime;
            _cachedSourceKey = key;
            Log.Info($"XML parsed: {result.Tracks.Count} tracks");
            return result;
        }

        return new LibraryData();
    }

    private const string RekordboxDbKey = "402fd482c38817c35ffa8ffb8c7d93143b749e7d315df7a81732a1ff43608497";

    private static LibraryData ParseMasterDb(string dbPath)
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
            var tracksDb    = new List<Track>();
            var trackIndex  = new Dictionary<string, int>();

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
                       COALESCE(c.created_at,'')
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
                    var tid      = rdr.GetValue(0)?.ToString() ?? "";
                    if (string.IsNullOrEmpty(tid)) continue;

                    var rawBpm   = rdr.GetValue(7)?.ToString() ?? "0";
                    var bpm      = double.TryParse(rawBpm, out var b) ? b / 100.0 : 0;
                    var bitrate  = int.TryParse(rdr.GetValue(8)?.ToString(), out var br) ? br : 0;
                    var playCount= int.TryParse(rdr.GetValue(9)?.ToString(), out var pc) ? pc : 0;

                    // Prefer created_at (ISO 8601), fall back to DateCreated
                    var rawDate  = rdr.GetValue(12)?.ToString() ?? "";
                    if (string.IsNullOrEmpty(rawDate))
                        rawDate  = rdr.GetValue(11)?.ToString() ?? "";

                    double ts = 0;
                    if (DateTime.TryParse(rawDate, null, System.Globalization.DateTimeStyles.RoundtripKind, out var dt))
                        ts = new DateTimeOffset(dt).ToUnixTimeMilliseconds() / 1000.0;

                    var rawPath  = rdr.GetValue(10)?.ToString() ?? "";
                    var location = NormalizeDbPath(rawPath);

                    var track = new Track
                    {
                        Id        = tid,
                        Artist    = rdr.GetValue(1)?.ToString() ?? "Unknown Artist",
                        Title     = rdr.GetValue(2)?.ToString() ?? "Unknown Title",
                        Genre     = rdr.GetValue(3)?.ToString() ?? "",
                        Label     = rdr.GetValue(4)?.ToString() ?? "",
                        RelDate   = rdr.GetValue(5)?.ToString() ?? "",
                        Key       = rdr.GetValue(6)?.ToString() ?? "—",
                        Bpm       = bpm,
                        Bitrate   = bitrate,
                        PlayCount = playCount,
                        Location  = location,
                        Timestamp = ts,
                        DateStr   = rawDate.Length >= 10 ? rawDate[..10] : "0000-00-00",
                    };

                    trackIndex[tid] = tracksDb.Count;
                    tracksDb.Add(track);
                }
            }

            // ── Playlists ────────────────────────────────────────────────────
            var playlistNames  = new Dictionary<string, string>();  // id → name
            var playlistParent = new Dictionary<string, string>();  // id → parentId

            using (var cmd = conn.CreateCommand())
            {
                cmd.CommandText = "SELECT ID, Name, ParentID FROM djmdPlaylist WHERE rb_local_deleted = 0";
                using var rdr = cmd.ExecuteReader();
                while (rdr.Read())
                {
                    var id   = rdr.GetValue(0)?.ToString() ?? "";
                    var name = rdr.GetValue(1)?.ToString() ?? "";
                    var pid  = rdr.GetValue(2)?.ToString() ?? "";
                    if (!string.IsNullOrEmpty(id)) { playlistNames[id] = name; playlistParent[id] = pid; }
                }
            }

            string BuildPath(string id)
            {
                var parts = new List<string>();
                var cur   = id;
                for (int depth = 0; depth < 20 && !string.IsNullOrEmpty(cur); depth++)
                {
                    if (!playlistNames.TryGetValue(cur, out var n)) break;
                    parts.Insert(0, n);
                    playlistParent.TryGetValue(cur, out var p);
                    cur = p ?? "";
                }
                return string.Join(" / ", parts.Where(p => !string.Equals(p, "ROOT", StringComparison.OrdinalIgnoreCase)));
            }

            var allPlaylists = new Dictionary<string, double>();

            using (var cmd = conn.CreateCommand())
            {
                cmd.CommandText = "SELECT PlaylistID, ContentID, TrackNo FROM djmdSongPlaylist WHERE rb_local_deleted = 0";
                using var rdr = cmd.ExecuteReader();
                while (rdr.Read())
                {
                    var plId  = rdr.GetValue(0)?.ToString() ?? "";
                    var tId   = rdr.GetValue(1)?.ToString() ?? "";
                    var order = int.TryParse(rdr.GetValue(2)?.ToString(), out var o) ? o : 0;

                    if (!trackIndex.TryGetValue(tId, out var idx)) continue;
                    var pPath = BuildPath(plId);
                    if (string.IsNullOrEmpty(pPath)) continue;

                    if (!allPlaylists.ContainsKey(pPath)) allPlaylists[pPath] = 0;
                    tracksDb[idx].PlaylistIndices[pPath] = order;
                    if (!tracksDb[idx].Playlists.Contains(pPath))
                        tracksDb[idx].Playlists.Add(pPath);
                    if (tracksDb[idx].Timestamp > allPlaylists[pPath])
                        allPlaylists[pPath] = tracksDb[idx].Timestamp;
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
                    cmd.CommandText = "SELECT ID, COALESCE(Name,''), COALESCE(DateCreated,''), COALESCE(created_at,'') FROM djmdHistory WHERE rb_local_deleted = 0";
                    using var rdr = cmd.ExecuteReader();
                    while (rdr.Read())
                    {
                        var hid = rdr.GetValue(0)?.ToString() ?? "";
                        if (string.IsNullOrEmpty(hid)) continue;
                        var name = (rdr.GetValue(1)?.ToString() ?? "").Trim();
                        if (name.Length == 0) name = $"History {hid}";
                        var rawHd = rdr.GetValue(3)?.ToString() ?? "";
                        if (string.IsNullOrEmpty(rawHd)) rawHd = rdr.GetValue(2)?.ToString() ?? "";
                        double hd = 0;
                        if (DateTime.TryParse(rawHd, null, System.Globalization.DateTimeStyles.RoundtripKind, out var hdt))
                            hd = new DateTimeOffset(hdt).ToUnixTimeMilliseconds() / 1000.0;
                        histName[hid] = name;
                        histDate[hid] = hd;
                    }
                }
                using (var cmd = conn.CreateCommand())
                {
                    cmd.CommandText = "SELECT HistoryID, ContentID, TrackNo FROM djmdSongHistory WHERE rb_local_deleted = 0";
                    using var rdr = cmd.ExecuteReader();
                    while (rdr.Read())
                    {
                        var hid   = rdr.GetValue(0)?.ToString() ?? "";
                        var tId   = rdr.GetValue(1)?.ToString() ?? "";
                        var order = int.TryParse(rdr.GetValue(2)?.ToString(), out var o) ? o : 0;
                        if (!histName.ContainsKey(hid)) continue;
                        if (!trackIndex.TryGetValue(tId, out var idx)) continue;
                        var key = $"hist:{hid}";
                        tracksDb[idx].HistoryIndices[key] = order;
                        if (!tracksDb[idx].Histories.Contains(key))
                            tracksDb[idx].Histories.Add(key);
                    }
                }
                historyPlaylists = histName.Select(kv => new Playlist
                {
                    Path = $"hist:{kv.Key}",
                    Date = histDate.GetValueOrDefault(kv.Key, 0),
                    History = true,
                    HistoryId = kv.Key,
                    Name = kv.Value,
                }).ToList();
            }
            catch (Exception ex)
            {
                Log.Warn($"history parse skipped: {ex.Message}");
            }

            tracksDb.Sort((a, b) => b.Timestamp.CompareTo(a.Timestamp));
            var playlists = allPlaylists.Select(kv => new Playlist { Path = kv.Key, Date = kv.Value }).ToList();
            playlists.AddRange(historyPlaylists);
            var mtime     = GetMtime(dbPath);
            return new LibraryData { Tracks = tracksDb, Playlists = playlists, XmlDate = mtime, Source = "db" };
        }
        catch (Exception ex)
        {
            Log.Error($"master.db parse failed: {ex.Message}");
            return new LibraryData();
        }
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
                    double ts = 0;
                    if (DateTime.TryParse(rawDate, out var dt))
                        ts = new DateTimeOffset(dt).ToUnixTimeMilliseconds() / 1000.0;

                    var bpm = double.TryParse(el.Attribute("AverageBpm")?.Value, out var b) ? b : 0;
                    var br  = int.TryParse(el.Attribute("BitRate")?.Value, out var bri) ? bri : 0;
                    var pc  = int.TryParse(el.Attribute("PlayCount")?.Value, out var pci) ? pci : 0;
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
                        var filtered = path.Where(p => p.ToUpper() != "ROOT").ToList();
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

            var playlists = allPlaylists.Select(kv => new Playlist { Path = kv.Key, Date = kv.Value }).ToList();
            return new LibraryData { Tracks = tracksDb, Playlists = playlists, XmlDate = mtime, Source = "xml" };
        }
        catch (Exception ex)
        {
            Log.Error($"XML parse failed: {ex.Message}");
            return new LibraryData();
        }
    }

    private static string NormalizePath(string loc)
    {
        var s = loc;
        if (s.StartsWith("file://localhost/")) s = s["file://localhost".Length..];
        else if (s.StartsWith("file:///"))       s = s["file://".Length..];

        // URL decode
        s = Uri.UnescapeDataString(s);

        // Convert Unix-style to Windows-style (e.g., /C:/Music → C:\Music)
        if (s.Length >= 3 && s[0] == '/' && s[2] == ':')
            s = s[1..].Replace('/', '\\');

        return s;
    }

    public void InvalidateCache()
    {
        lock (_lock)
        {
            _cachedData = null;
            _cachedMtime = 0;
            _cachedSourceKey = "";
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
