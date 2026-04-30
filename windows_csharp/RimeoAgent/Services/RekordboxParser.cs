using System.Xml.Linq;
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

    public LibraryData Parse()
    {
        lock (_lock) { return ParseInternal(); }
    }

    private LibraryData ParseInternal()
    {
        var xmlPath = AppConfig.Shared.XmlPath;
        if (!string.IsNullOrEmpty(xmlPath) && File.Exists(xmlPath))
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
}
