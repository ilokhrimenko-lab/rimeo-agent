using System.Text.Json.Serialization;

namespace RimeoAgent.Models;

public sealed class Track
{
    [JsonPropertyName("id")]               public string Id             { get; set; } = "";
    [JsonPropertyName("artist")]           public string Artist         { get; set; } = "";
    [JsonPropertyName("title")]            public string Title          { get; set; } = "";
    [JsonPropertyName("genre")]            public string Genre          { get; set; } = "";
    [JsonPropertyName("label")]            public string Label          { get; set; } = "";
    [JsonPropertyName("rel_date")]         public string RelDate        { get; set; } = "";
    [JsonPropertyName("key")]              public string Key            { get; set; } = "—";
    [JsonPropertyName("bpm")]              public double Bpm            { get; set; }
    // Длина трека в секундах (djmdContent.Length / XML TotalTime). Нужна движку
    // рекомендаций для флага duration_match и медианы состава. Отсутствует (null) —
    // ключ не сериализуется, как и в macOS-агенте (encodableTrack).
    [JsonPropertyName("duration")]
    [JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    public double? Duration { get; set; }
    [JsonPropertyName("bitrate")]          public int    Bitrate        { get; set; }
    [JsonPropertyName("play_count")]       public int    PlayCount      { get; set; }
    [JsonPropertyName("location")]         public string Location       { get; set; } = "";
    [JsonPropertyName("timestamp")]        public double Timestamp      { get; set; }
    [JsonPropertyName("date_str")]         public string DateStr        { get; set; } = "0000-00-00";
    // djmdContent.ImagePath — обложка, которую Rekordbox хранит ОТДЕЛЬНО от файла
    // (в <rekordbox>/share). Внутреннее поле: macOS его тоже парсит, но в /api/data
    // НЕ отдаёт — клиенты берут обложку через /artwork. Не сериализуем, иначе
    // контракт разъедется с маком.
    [JsonIgnore]                           public string ImagePath      { get; set; } = "";
    [JsonPropertyName("playlists")]        public List<string> Playlists { get; set; } = new();
    [JsonPropertyName("playlist_indices")] public Dictionary<string, int> PlaylistIndices { get; set; } = new();
    // Play-history membership — separate from Playlists so playlist counts stay clean.
    [JsonPropertyName("histories")]        public List<string> Histories { get; set; } = new();
    [JsonPropertyName("history_indices")]  public Dictionary<string, int> HistoryIndices { get; set; } = new();
}

public sealed class Playlist
{
    [JsonPropertyName("path")] public string Path { get; set; } = "";
    [JsonPropertyName("date")] public double Date { get; set; }
    // Legacy-поле: дублирует IsSmart. macOS отдаёт оба (старые клиенты читают `smart`).
    [JsonPropertyName("smart")]
    [JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    public bool? Smart { get; set; }
    // «Recently changed» на клиенте: реальный djmdPlaylist.updated_at, если доступен;
    // иначе не сериализуется (null) и клиент падает на Date.
    [JsonPropertyName("updated")]
    [JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    public double? Updated { get; set; }
    // Rekordbox play-history session. Omitted (null) for regular playlists.
    [JsonPropertyName("history")]
    [JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    public bool? History { get; set; }
    [JsonPropertyName("history_id")]
    [JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    public string? HistoryId { get; set; }
    [JsonPropertyName("name")]
    [JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    public string? Name { get; set; }

    // ── Identity + дерево. Парсер обязан отдавать узел для КАЖДОГО djmdPlaylist
    // (папки, пустые, smart), иначе мутации нечем адресовать: `path` — только для
    // показа, у одноимённых плейлистов он совпадает.
    [JsonPropertyName("rekordbox_id")]
    [JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    public string? RekordboxId { get; set; }          // djmdPlaylist.ID
    [JsonPropertyName("parent")]
    [JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    public string? Parent { get; set; }               // djmdPlaylist.ParentID ("root" на верхнем уровне)
    [JsonPropertyName("is_folder")]
    [JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    public bool? IsFolder { get; set; }               // Attribute == 1
    [JsonPropertyName("is_smart")]
    [JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    public bool? IsSmart { get; set; }                // Attribute == 4
    /// djmdPlaylist.Seq — НАСТОЯЩИЙ порядок показа внутри родителя. Единое
    /// пространство для папок и плейлистов: папка может стоять НИЖЕ плейлиста,
    /// поэтому «сначала папки» — это НЕ порядок Rekordbox. Без Seq пункт
    /// «Rekordbox order» на клиенте был пустышкой (отдавался алфавит).
    [JsonPropertyName("seq")]
    [JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    public int? Seq { get; set; }
}

public sealed class LibraryData
{
    [JsonPropertyName("tracks")]    public List<Track>    Tracks    { get; set; } = new();
    [JsonPropertyName("playlists")] public List<Playlist> Playlists { get; set; } = new();
    [JsonPropertyName("xml_date")]  public double         XmlDate   { get; set; }
    [JsonPropertyName("source")]    public string?        Source    { get; set; }
}
