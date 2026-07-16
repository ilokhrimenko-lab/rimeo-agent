using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;
using RimeoAgent.Config;

namespace RimeoAgent.Models;

// Оверлей пользовательского плейлиста (Фаза 0 — плейлисты из iOS). Живёт в
// rimo_data.json рядом с notes/exclusions и подмешивается в /api/data на чтении;
// master.db на Windows пока НЕ пишется (см. capabilities.playlist_sync).
// Чисто-Rimeo плейлист: RekordboxId == null, синтетический путь "rmo:<rimeo_id>".
// Правка существующего Rekordbox-плейлиста: RekordboxId заполнен, Dirty == true —
// оверлей перекрывает разобранный состав ПО ID, никогда по пути (у одноимённых
// плейлистов путь совпадает и составы бы слились).
//
// System.Text.Json терпит отсутствующие ключи (поле получает значение по
// умолчанию), поэтому старый rimo_data.json без `playlists` десериализуется без
// исключения и агент не «распаривается» после обновления.
public sealed class PlaylistOverlay
{
    [JsonPropertyName("rimeo_id")]         public string  RimeoId        { get; set; } = "";
    [JsonPropertyName("rekordbox_id")]     public string? RekordboxId    { get; set; }
    [JsonPropertyName("name")]             public string  Name           { get; set; } = "";
    [JsonPropertyName("parent")]           public string? Parent         { get; set; }
    [JsonPropertyName("is_folder")]        public bool    IsFolder       { get; set; }
    [JsonPropertyName("track_ids")]        public List<string> TrackIds  { get; set; } = new();
    [JsonPropertyName("state")]            public string  State          { get; set; } = "pending";
    [JsonPropertyName("dirty")]            public bool    Dirty          { get; set; } = true;
    [JsonPropertyName("content_hash")]     public string? ContentHash    { get; set; }
    [JsonPropertyName("last_synced_hash")] public string? LastSyncedHash { get; set; }
    // Tombstone (полный CRUD-delete). Удалённый оверлей прячет плейлист из /api/data:
    // чисто-Rimeo просто не отдаётся, правка Rekordbox-плейлиста — выкидывается из
    // разобранного списка.
    [JsonPropertyName("deleted")]          public bool    Deleted        { get; set; }

    /// Подпись синка (Фаза 6). ContentHash покрывает ТОЛЬКО состав, поэтому
    /// переименование, перенос, создание папки и удаление оставляют его
    /// байт-в-байт прежним — проверка «что синкать» по ContentHash молча объявила
    /// бы эти правки уже записанными. Подпись покрывает всё, что писатель умеет
    /// протолкнуть в master.db: имя, родителя, папочность, tombstone И состав.
    [JsonIgnore]
    public string SyncSignature
    {
        get
        {
            // U+001F (unit separator) не встречается ни в имени, ни в пути, ни в id →
            // Escape записан ЯВНО: невидимый управляющий символ в исходнике рано или
            // поздно теряется при копировании, а хеш обязан совпадать с macOS.
            // нет коллизии между (name="a", parent="b") и (name="a\u001Fb", parent="").
            var parts = string.Join("\u001F", new[]
            {
                Name,
                Parent ?? "",
                IsFolder ? "1" : "0",
                Deleted  ? "1" : "0",
                string.Join("\n", TrackIds),
            });
            return PlaylistHash.ContentHash(new List<string> { parts });
        }
    }
}

/// Кросс-платформенный хеш состава плейлиста. ОБЯЗАН оставаться байт-в-байт
/// одинаковым с iOS / web / macOS, иначе оверлеи никогда не самоочистятся:
/// SHA-256 в нижнем регистре hex от упорядоченных track_ids, склеенных "\n".
/// Порядок значим; id не приводятся к одному регистру.
public static class PlaylistHash
{
    public static string ContentHash(IEnumerable<string> trackIds)
    {
        var joined = string.Join("\n", trackIds);
        var hash   = SHA256.HashData(Encoding.UTF8.GetBytes(joined));
        return Convert.ToHexString(hash).ToLowerInvariant();
    }
}

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
    // Оверлейные правки плейлистов из iOS (Фаза 0). Подмешиваются в /api/data на
    // чтении; в master.db на Windows не уезжают (записи ещё нет).
    [JsonPropertyName("playlists")]         public List<PlaylistOverlay>      Playlists        { get; set; } = new();
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

    /// Оверлеи, которые ещё отличаются от того, что записано в master.db (Фаза 6).
    /// Единственный источник правды и для движка синка, и для счётчика pending_sync
    /// в /api/data — они не имеют права разойтись, иначе кнопка Sync либо предлагает
    /// пустой прогон, либо прячет нужный.
    ///
    /// Tombstone плейлиста, который до базы так и не доехал, удалять там нечего —
    /// он НЕ pending. LastSyncedHash == null ⇒ ни разу не синкали ⇒ pending.
    public List<PlaylistOverlay> PendingSyncOverlays()
    {
        return Data.Playlists
            .Where(ov => !(ov.Deleted && string.IsNullOrEmpty(ov.RekordboxId))
                         && ov.LastSyncedHash != ov.SyncSignature)
            .ToList();
    }
}
