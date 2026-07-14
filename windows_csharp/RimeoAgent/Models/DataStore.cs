using System.Text.Json;
using System.Text.Json.Serialization;
using RimeoAgent.Config;

namespace RimeoAgent.Models;

public sealed class RimoData
{
    [JsonPropertyName("notes")]             public Dictionary<string, string> Notes           { get; set; } = new();
    // Custom names for Rekordbox play-history sessions (djmdHistory.ID → name).
    // Applied to the parsed library on read; Rekordbox's DB stays untouched.
    [JsonPropertyName("history_names")]     public Dictionary<string, string> HistoryNames    { get; set; } = new();
    [JsonPropertyName("global_exclusions")] public List<string>               GlobalExclusions { get; set; } = new();
    [JsonPropertyName("pairing_code")]      public string                     PairingCode      { get; set; } = "";
    // Per-device LAN pre-shared key (M4). Persistent (unlike the rotating
    // PairingCode). Authorises direct local-network requests without a server JWT;
    // emitted in the v2 QR as `secret`, sent back as `?lan_token=`. Mirrors macOS.
    [JsonPropertyName("lan_secret")]        public string                     LanSecret        { get; set; } = "";
    [JsonPropertyName("cloud_url")]         public string                     CloudUrl         { get; set; } = "";
    [JsonPropertyName("cloud_user_id")]     public string?                    CloudUserId      { get; set; }
    [JsonPropertyName("cloud_token")]       public string                     CloudToken       { get; set; } = "";
    [JsonPropertyName("tunnel_url")]        public string                     TunnelUrl        { get; set; } = "";
    [JsonPropertyName("max_cache_gb")]      public double                     MaxCacheGb       { get; set; } = 3.0;
    // Silent auto-update: hourly check downloads the new build's zip to a staging
    // file in the background; it is applied (xcopy+restart) on the next launch.
    // Non-empty = a staged build is ready to install. Mirrors macOS.
    [JsonPropertyName("staged_update_tag")] public string                     StagedUpdateTag  { get; set; } = "";
    // Автозапуск включается автоматически ОДИН раз (первый запуск после установки).
    // Флаг не даёт включить его снова, если пользователь снял тумблер в Settings.
    [JsonPropertyName("autostart_configured")] public bool                    AutostartConfigured { get; set; }
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
                // Atomic write: a crash/shutdown mid-write must not leave a truncated
                // JSON that throws on the next Load() and resets the store (→ unpair).
                // System.Text.Json already tolerates missing keys (new fields keep
                // their C# defaults), so schema evolution alone is safe here; the temp
                // + Move guards the corrupt-file path.
                var path = AppConfig.Shared.DataFile;
                var tmp  = path + ".tmp";
                File.WriteAllText(tmp, json);
                File.Move(tmp, path, overwrite: true);
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

    /// Generate the per-device LAN PSK at startup if none exists yet, so the
    /// agent's own WinUI control calls — which authenticate over 127.0.0.1 with
    /// ?lan_token= — work before the pairing QR has ever been shown (task 6004).
    /// Idempotent: a no-op once a secret is present.
    public void EnsureLanSecret()
    {
        if (!string.IsNullOrEmpty(Data.LanSecret)) return;
        var raw = new byte[32];
        System.Security.Cryptography.RandomNumberGenerator.Fill(raw);
        var psk = Convert.ToBase64String(raw).Replace("+", "-").Replace("/", "_").Replace("=", "");
        Update(d => { if (string.IsNullOrEmpty(d.LanSecret)) d.LanSecret = psk; });
    }
}
