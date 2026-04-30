using System.Text.Json;
using System.Text.Json.Serialization;
using RimeoAgent.Config;

namespace RimeoAgent.Models;

public sealed class RimoData
{
    [JsonPropertyName("notes")]             public Dictionary<string, string> Notes           { get; set; } = new();
    [JsonPropertyName("global_exclusions")] public List<string>               GlobalExclusions { get; set; } = new();
    [JsonPropertyName("pairing_code")]      public string                     PairingCode      { get; set; } = "";
    [JsonPropertyName("cloud_url")]         public string                     CloudUrl         { get; set; } = "";
    [JsonPropertyName("cloud_user_id")]     public string?                    CloudUserId      { get; set; }
    [JsonPropertyName("cloud_token")]       public string                     CloudToken       { get; set; } = "";
    [JsonPropertyName("tunnel_url")]        public string                     TunnelUrl        { get; set; } = "";
    [JsonPropertyName("max_cache_gb")]      public double                     MaxCacheGb       { get; set; } = 3.0;
}

public sealed class DataStore
{
    public static readonly DataStore Shared = new();

    private readonly object _lock = new();
    private RimoData _data = new();

    public RimoData Data { get { lock (_lock) return _data; } }

    private DataStore()
    {
        _data = Load();
    }

    private RimoData Load()
    {
        try
        {
            if (!File.Exists(AppConfig.Shared.DataFile)) return new RimoData();
            var json = File.ReadAllText(AppConfig.Shared.DataFile);
            return JsonSerializer.Deserialize<RimoData>(json) ?? new RimoData();
        }
        catch { return new RimoData(); }
    }

    public void Save(RimoData data)
    {
        lock (_lock) { _data = data; }
        Task.Run(() =>
        {
            try
            {
                var json = JsonSerializer.Serialize(data, new JsonSerializerOptions { WriteIndented = true });
                File.WriteAllText(AppConfig.Shared.DataFile, json);
            }
            catch (Exception ex) { Log.Error($"DataStore save failed: {ex.Message}"); }
        });
    }

    public void Update(Action<RimoData> action)
    {
        RimoData copy;
        lock (_lock) { copy = JsonSerializer.Deserialize<RimoData>(JsonSerializer.Serialize(_data))!; }
        action(copy);
        Save(copy);
    }
}
