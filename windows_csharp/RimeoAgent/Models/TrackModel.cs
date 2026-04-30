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
    [JsonPropertyName("bitrate")]          public int    Bitrate        { get; set; }
    [JsonPropertyName("play_count")]       public int    PlayCount      { get; set; }
    [JsonPropertyName("location")]         public string Location       { get; set; } = "";
    [JsonPropertyName("timestamp")]        public double Timestamp      { get; set; }
    [JsonPropertyName("date_str")]         public string DateStr        { get; set; } = "0000-00-00";
    [JsonPropertyName("playlists")]        public List<string> Playlists { get; set; } = new();
    [JsonPropertyName("playlist_indices")] public Dictionary<string, int> PlaylistIndices { get; set; } = new();
}

public sealed class Playlist
{
    [JsonPropertyName("path")] public string Path { get; set; } = "";
    [JsonPropertyName("date")] public double Date { get; set; }
}

public sealed class LibraryData
{
    [JsonPropertyName("tracks")]    public List<Track>    Tracks    { get; set; } = new();
    [JsonPropertyName("playlists")] public List<Playlist> Playlists { get; set; } = new();
    [JsonPropertyName("xml_date")]  public double         XmlDate   { get; set; }
    [JsonPropertyName("source")]    public string?        Source    { get; set; }
}
