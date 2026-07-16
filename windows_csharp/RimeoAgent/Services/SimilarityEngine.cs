using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;
using RimeoAgent.Config;
using RimeoAgent.Models;

namespace RimeoAgent.Services;

// Ранжирование кандидатов: «похожие треки» (/api/similar) и «что добавить в плейлист»
// (/api/playlist/recommendations). Оба роута — один движок: разница только в том,
// сколько треков в сид-наборе (один трек против всего состава плейлиста).
//
// СТАРЫЙ алгоритм на Windows (и почему он выбрасывается целиком) — это вообще ДРУГОЙ
// движок: скор считался по аудио-фичам (MFCC/clap/energy из AnalysisEngine) + гейт по
// BPM ±8 + сортировка по ΔBPM. С macOS он не совпадал ни полями score, ни смыслом, хотя
// iOS декодирует ОДНИ И ТЕ ЖЕ поля. Новый движок метаданных+совместности не использует
// TrackFeatures вообще.
//
// Претензии к старому ранжированию (общие для обеих платформ):
//   • 75% реальной библиотеки лежит в окне 118–130 BPM ⇒ «близкий BPM» не различает
//     НИЧЕГО, но именно он был главным тай-брейком — выдача превращалась в шум.
//   • duration у клубных треков 5–7 минут срабатывает почти у всех — раздавал баллы
//     случайным трекам.
//   • бонусы булевы ⇒ огромные группы кандидатов с одинаковым total.
//
// НОВЫЙ алгоритм. Скор = взвешенная смесь ДВУХ путей, оба в [0…1]:
//   1) CO-PLAY (главный) — CoPlayGraph: реальные переходы из истории сетов + совместность
//      в РУЧНЫХ плейлистах. Единственный сигнал в библиотеке, отражающий вкус, а не
//      метаданные Beatport.
//   2) CONTENT (вспомогательный) — насколько кандидат попадает в ПРОФИЛЬ сид-набора:
//      доля сидов с тем же лейблом / жанром / артистом + гармоническая близость к палитре
//      тональностей. Все фичи ГРАДУИРОВАНЫ (доли, не булевы) ⇒ массовых ничьих нет.
//
//   BPM теперь ТОЛЬКО ГЕЙТ (абсолютное окно ±N BPM вокруг темпового коридора плейлиста,
//   с half/double-time: 62 BPM подходит к 124) и в ранжировании НЕ участвует.
//   duration выкинут из скора совсем (остался только флаг duration_match в ответе).
//
// Все веса/пороги — в similarity_config.json (правится в /admin, синкается из облака).
// Windows до сих пор облачный конфиг не читал вообще — движок был захардкожен, и веса
// нельзя было крутить из админки. Теперь читает (см. StartCloudSync).

/// <summary>
/// Конфиг движка. Имена свойств — ТОЧНЫЙ snake_case из similarity_config.json и из
/// облачного /api/similarity_config: та же схема, что у macOS-агента и у админки.
///
/// У КАЖДОГО поля есть дефолт-инициализатор. Это не косметика: конфиг, лежащий в облаке
/// или на диске со СТАРОЙ схемой (bpm_tolerance_pct + key_max_steps + result_limit +
/// weights), обязан десериализоваться и получить разумные новые дефолты, а не уронить
/// парсинг. System.Text.Json просто не трогает свойство, если ключа нет в JSON — ровно
/// это и даёт поведение Swift-ового decodeIfPresent(...) ?? default.
/// </summary>
public sealed class SimilarityConfig
{
    // ── гейты кандидата ──────────────────────────────────────────────────────

    /// Абсолютный допуск по темпу, ±BPM. ГЛАВНЫЙ гейт. Процентный допуск при 124 BPM
    /// давал ±2 BPM у быстрых треков и ±1.6 у медленных — разная строгость на ровном месте.
    [JsonPropertyName("bpm_tolerance_abs")]      public double bpm_tolerance_abs      { get; set; } = 3.0;
    /// Legacy-процент. Работает ТОЛЬКО когда bpm_tolerance_abs <= 0 (обратная совместимость
    /// со старым конфигом из облака, где абсолютного поля ещё нет).
    [JsonPropertyName("bpm_tolerance_pct")]      public double bpm_tolerance_pct      { get; set; } = 1.6;
    /// 62 BPM ↔ 124 BPM — один и тот же грув. Кандидат сворачивается в октаву плейлиста.
    [JsonPropertyName("bpm_allow_half_double")]  public bool   bpm_allow_half_double  { get; set; } = true;
    /// Расстояние по колесу Camelot при одинаковой стороне (A/B), в шагах.
    [JsonPropertyName("key_max_steps")]          public int    key_max_steps          { get; set; } = 1;
    /// Только для информационного флага duration_match в ответе. В скор НЕ входит.
    [JsonPropertyName("duration_tolerance_pct")] public double duration_tolerance_pct { get; set; } = 10.0;

    // ── выдача ───────────────────────────────────────────────────────────────

    [JsonPropertyName("result_limit")]   public int result_limit   { get; set; } = 50;
    /// Глубина ранжированного списка, из которого нарезаются страницы (кнопка Refresh
    /// отдаёт СЛЕДУЮЩИЙ срез, а не тот же топ). Работа O(pool·log pool), не O(библиотеки).
    [JsonPropertyName("candidate_pool")] public int candidate_pool { get; set; } = 300;
    /// Не больше N треков одного артиста / лейбла в выдаче (0 = без ограничения).
    /// Лишние не выбрасываются, а сдвигаются в хвост — на следующих страницах они появятся.
    [JsonPropertyName("max_per_artist")]  public int max_per_artist { get; set; } = 2;
    [JsonPropertyName("max_per_label")]   public int max_per_label  { get; set; } = 3;

    // ── смешивание путей ─────────────────────────────────────────────────────

    /// Вклад графа совместности и вклад метаданных. Нормируются суммой, поэтому важно их
    /// ОТНОШЕНИЕ, а не абсолютные значения.
    [JsonPropertyName("coplay_weight")]   public double coplay_weight   { get; set; } = 0.65;
    [JsonPropertyName("content_weight")]  public double content_weight  { get; set; } = 0.35;
    /// Веса каналов ВНУТРИ графа: история сетов против ручных плейлистов.
    [JsonPropertyName("history_weight")]  public double history_weight  { get; set; } = 1.0;
    [JsonPropertyName("playlist_weight")] public double playlist_weight { get; set; } = 0.6;
    /// Холодный старт: доля content-скора, которой замещается co-play у треков, про которые
    /// граф не знает НИЧЕГО (никогда не игрались и не лежат ни в одном ручном плейлисте —
    /// на реальной библиотеке это 17%). Подробности — в комментарии к Blend.
    [JsonPropertyName("cold_start_backoff")] public double cold_start_backoff { get; set; } = 0.5;
    /// КВОТА ОТКРЫТИЙ: сколько позиций из каждых 10 гарантированно отдаётся трекам, которые
    /// НИКОГДА не игрались (47% библиотеки). Подробности — в InterleaveCold.
    /// 0 = квота выключена (выдача чисто по скору).
    [JsonPropertyName("cold_start_quota_per_10")] public int cold_start_quota_per_10 { get; set; } = 3;

    [JsonPropertyName("weights")] public WeightSet weights { get; set; } = new();

    /// Веса ВНУТРИ content-пути. Нормируются суммой активных, так что это относительная
    /// важность признаков, а не абсолютные баллы.
    public sealed class WeightSet
    {
        [JsonPropertyName("label")]  public double label  { get; set; } = 2.0;
        [JsonPropertyName("genre")]  public double genre  { get; set; } = 1.0;
        [JsonPropertyName("artist")] public double artist { get; set; } = 0.5;
        /// Гармоническая близость к палитре тональностей сид-набора.
        [JsonPropertyName("key")]    public double key    { get; set; } = 1.5;
        /// МЁРТВЫЙ вес. Оставлен, чтобы старые конфиги (и админка) парсились без ошибок:
        /// длительность у клубных треков 5–7 минут совпадает почти у всех и в скоре была
        /// чистым шумом. Значение игнорируется.
        [JsonPropertyName("duration")] public double duration { get; set; } = 1.5;
    }

    public static SimilarityConfig Default => new();
}

public sealed class SimilarityEngine
{
    public static readonly SimilarityEngine Shared = new();

    private SimilarityEngine()
    {
        _config = LoadConfig();
    }

    // Конфиг изменяемый: стартует с закэшированного/встроенного файла и обновляется из
    // облака (админка) при старте и по таймеру — подкрутка алгоритма не требует нового
    // билда агента.
    private readonly object _cfgLock = new();
    private SimilarityConfig _config;
    // Явно System.Threading.Timer, а не System.Timers/DispatcherTimer: тики не должны ходить
    // через UI-поток WinUI.
    private System.Threading.Timer? _refreshTimer;
    private const int RefreshIntervalSeconds = 600;     // 10 минут, как на macOS

    // Один HttpClient на процесс: новый на каждый тик таймера жёг бы сокеты (классический
    // SocketException: address already in use под TIME_WAIT на длинных аптаймах агента).
    private static readonly HttpClient Http = new() { Timeout = TimeSpan.FromSeconds(10) };

    /// Опции парсинга конфига. PropertyNameCaseInsensitive + AllowReadingFromString —
    /// страховка от облака/админки: если поле придёт как "3.0" (строкой) или как
    /// "BPM_Tolerance_Abs", конфиг не должен молча откатываться на дефолт целиком.
    private static readonly JsonSerializerOptions ConfigJson = new()
    {
        PropertyNameCaseInsensitive = true,
        NumberHandling = JsonNumberHandling.AllowReadingFromString,
        AllowTrailingCommas = true,
        ReadCommentHandling = JsonCommentHandling.Skip,
    };

    public SimilarityConfig Config
    {
        get { lock (_cfgLock) return _config; }
    }

    /// public, а не private: этим же сеттером конфиг подменяют тесты, чтобы не зависеть от
    /// того, какой конфиг закэширован на конкретной машине.
    public void SetConfig(SimilarityConfig cfg)
    {
        // ⚠️ `"weights": null` в конфиге НЕ откатывается на инициализатор `= new()`:
        // System.Text.Json честно записывает в свойство null. Дальше `cfg.weights.key`
        // в content() — NullReferenceException, и падает ВЕСЬ запрос рекомендаций, а не
        // одно поле. Свифтовый decodeIfPresent на null отдал бы дефолт, поэтому чиним
        // здесь, в единственной точке входа конфига (её же зовут LoadConfig и облачный
        // синк), а не в каждом потребителе.
        cfg.weights ??= new SimilarityConfig.WeightSet();
        lock (_cfgLock) { _config = cfg; }
    }

    /// Копия последнего удачного облачного конфига. На следующем старте она в приоритете,
    /// чтобы офлайн-запуск сохранял актуальные значения из админки.
    private static string CachedConfigPath => Path.Combine(AppConfig.Shared.BaseDir, "similarity_config.json");

    /// Файл рядом с exe (аналог Bundle.main на macOS).
    private static string BundledConfigPath => Path.Combine(AppContext.BaseDirectory, "similarity_config.json");

    /// Форма ответа зафиксирована (её декодят iOS и веб-плеер): total, bpm_delta,
    /// key_relation, label_match, genre_match, artist_match, duration_match. Шкала `total` —
    /// 0…1 (смесь двух путей), а не старая сумма бонусов. Ни один клиент total не
    /// показывает, он нужен только для ранжирования.
    public sealed record MatchScore(
        [property: JsonPropertyName("total")]          double Total,          // 0…1: coplay_weight·co + content_weight·content
        [property: JsonPropertyName("bpm_delta")]      double BpmDelta,       // |BPM кандидата (свёрнутый в октаву) − центр коридора|
        [property: JsonPropertyName("key_relation")]   string KeyRelation,    // "exact" | "relative" | "compatible" | "incompatible" | "—"
        [property: JsonPropertyName("label_match")]    bool   LabelMatch,
        [property: JsonPropertyName("genre_match")]    bool   GenreMatch,
        [property: JsonPropertyName("artist_match")]   bool   ArtistMatch,
        [property: JsonPropertyName("duration_match")] bool   DurationMatch); // информационный флаг, в скор НЕ входит

    public sealed record SimilarResult(
        [property: JsonPropertyName("track")] Track      Track,
        [property: JsonPropertyName("score")] MatchScore Score);

    // ── Загрузка конфига ─────────────────────────────────────────────────────

    // Приоритет источников на старте: кэш облачного конфига → файл рядом с exe → дефолт.
    private static SimilarityConfig LoadConfig()
    {
        foreach (var path in new[] { CachedConfigPath, BundledConfigPath })
        {
            try
            {
                if (!File.Exists(path)) continue;
                var cfg = JsonSerializer.Deserialize<SimilarityConfig>(File.ReadAllText(path), ConfigJson);
                if (cfg != null) { cfg.weights ??= new SimilarityConfig.WeightSet(); return cfg; }
            }
            catch { /* битый/недочитанный файл — просто идём к следующему источнику */ }
        }
        return SimilarityConfig.Default;
    }

    // ── Синк с облаком ───────────────────────────────────────────────────────

    /// Немедленный запрос + повторы по таймеру. Вызывается один раз при старте агента.
    public void StartCloudSync()
    {
        _ = Task.Run(RefreshFromCloudAsync);
        // System.Threading.Timer: тики уходят в пул потоков, UI-поток WinUI не трогаем.
        // Держим ссылку в поле, иначе GC соберёт таймер вместе с первым же тиком.
        _refreshTimer = new System.Threading.Timer(
            _ => _ = RefreshFromCloudAsync(),
            null,
            TimeSpan.FromSeconds(RefreshIntervalSeconds),
            TimeSpan.FromSeconds(RefreshIntervalSeconds));
    }

    /// Тянем конфиг из облака (он правится в /admin); при успехе — подменяем живой конфиг и
    /// сохраняем на диск для следующего запуска. Ошибки ГЛУШИМ: остаёмся на том конфиге,
    /// который уже есть. Агент без интернета обязан рекомендовать, а не падать.
    public async Task RefreshFromCloudAsync()
    {
        try
        {
            using var req = new HttpRequestMessage(HttpMethod.Get,
                $"{AppConfig.RimeoAppUrl}/api/similarity_config");
            req.Headers.TryAddWithoutValidation("User-Agent", $"RimeoAgentWin/{AppConfig.Shared.Version}");
            // Ответ мог осесть в кэше HttpClient/прокси — админская правка обязана доезжать
            // с первого тика, а не через 10 минут.
            req.Headers.CacheControl = new System.Net.Http.Headers.CacheControlHeaderValue { NoCache = true };

            using var resp = await Http.SendAsync(req).ConfigureAwait(false);
            if (!resp.IsSuccessStatusCode) return;
            var body = await resp.Content.ReadAsStringAsync().ConfigureAwait(false);

            var cfg = JsonSerializer.Deserialize<SimilarityConfig>(body, ConfigJson);
            if (cfg == null) return;
            SetConfig(cfg);

            // Пишем ИСХОДНОЕ тело, а не пересериализованный объект: так на диск попадают и
            // поля, которых этот билд ещё не знает (новый ключ из админки не потеряется при
            // откате на старый агент). Atomic: обрыв записи не должен оставить обрезанный
            // JSON, который на следующем старте молча откатит конфиг к дефолту.
            var tmp = CachedConfigPath + ".tmp";
            await File.WriteAllTextAsync(tmp, body, new UTF8Encoding(false)).ConfigureAwait(false);
            File.Move(tmp, CachedConfigPath, overwrite: true);
        }
        catch { /* молча: сеть/облако недоступны — работаем на текущем конфиге */ }
    }

    // ── Публичный API ────────────────────────────────────────────────────────

    /// «Похожие треки» на один трек. Сид-набор из одного элемента — тот же движок, что и у
    /// рекомендаций плейлиста.
    public List<SimilarResult> FindSimilar(string trackId, LibraryData lib,
                                           int? topN = null, bool useKey = true,
                                           HashSet<string>? excludeIds = null)
    {
        // diversify: false — у /api/similar ограничивать «не больше 2 треков артиста»
        // неправильно: «ещё вот эти два ремикса того же артиста» здесь и есть ответ.
        // quota: false — «похожие треки» обязаны быть похожими; подмешивать сюда открытия
        // (это фича блока «что ДОБАВИТЬ») значило бы врать про смысл списка.
        return Rank(new[] { trackId }, lib, topN, useKey, excludeIds, offset: 0,
                    diversify: false, quota: false);
    }

    /// «Что добавить» для плейлиста ЦЕЛИКОМ. Сид — весь состав (не сэмпл: и граф, и профиль
    /// строятся за доли миллисекунды, а сэмплирование теряло кластеры).
    ///
    /// `offset` — страница ранжированного списка. Кнопка Refresh при неизменном составе шлёт
    /// offset += limit и получает СЛЕДУЮЩИЙ срез, а не тот же топ. Ранжирование при этом
    /// полностью детерминировано (рандома нет): одна и та же пара (состав, offset) всегда
    /// даёт одну и ту же выдачу.
    public List<SimilarResult> RecommendForPlaylist(IReadOnlyList<string> trackIds, LibraryData lib,
                                                    int? topN = null, bool useKey = true,
                                                    HashSet<string>? excludeIds = null, int offset = 0)
    {
        return Rank(trackIds, lib, topN, useKey, excludeIds, offset, diversify: true, quota: true);
    }

    // ── Ядро ранжирования ────────────────────────────────────────────────────

    /// Кандидат после гейтов: сырые каналы, без скора. Скор считается вторым проходом —
    /// сначала надо увидеть ВЕСЬ пул, чтобы привести каналы к общей шкале.
    private sealed record Cand(
        Track Track, double Co, double Content, double BpmDelta, KeyRel KeyRel,
        bool Label, bool Genre, bool Artist, bool Duration, bool Known,
        // DupKey — ключ дубликата: по нему схлопываем повторы уже внутри самой выдачи.
        string? DupKey,
        // Cold — «открытие»: трек НИ РАЗУ не игрался. Ровно тот признак, по которому
        // пользователь считает список полезным. play_count и пустая история в Rekordbox
        // совпадают один-в-один (проверено на живой базе), берём историю.
        bool Cold);

    private sealed record Scored(
        Track Track, MatchScore Score,
        double Co,        // СЫРОЕ, не обрезанное — только для тай-брейка
        double Content,
        string? DupKey, bool Cold);

    private List<SimilarResult> Rank(IReadOnlyList<string> seedIds, LibraryData lib,
                                     int? topN, bool useKey,
                                     HashSet<string>? excludeIds, int offset,
                                     bool diversify, bool quota)
    {
        var cfg   = Config;                                  // атомарный снимок на весь запрос
        var limit = Math.Max(1, topN ?? cfg.result_limit);

        var seenSeed = new HashSet<string>(StringComparer.Ordinal);
        var seeds = new List<string>();
        foreach (var id in seedIds)
        {
            if (string.IsNullOrEmpty(id)) continue;
            if (seenSeed.Add(id)) seeds.Add(id);
        }
        if (seeds.Count == 0) return new List<SimilarResult>();

        var tracks = lib.Tracks;
        var byId = new Dictionary<string, Track>(tracks.Count, StringComparer.Ordinal);
        foreach (var t in tracks) byId[t.Id] = t;

        var seedTracks = new List<Track>(seeds.Count);
        foreach (var id in seeds) if (byId.TryGetValue(id, out var t)) seedTracks.Add(t);
        if (seedTracks.Count == 0) return new List<SimilarResult>();

        var profile = new SeedProfile(seedTracks, cfg);

        var exclude = new HashSet<string>(seenSeed, StringComparer.Ordinal);
        if (excludeIds != null) exclude.UnionWith(excludeIds);

        // Исключение по id ловит только сам файл, а в библиотеке один и тот же трек лежит
        // импортированным ДВАЖДЫ (разные id, разные теги). Поэтому вторая, более сильная
        // защита — по нормализованной паре (артист, тайтл): всё, что уже есть в составе (или
        // в exclude_ids), не предлагаем ни под каким id. Ремиксы при этом остаются разными
        // треками — см. TrackIdentity.
        var excludeKeys = new HashSet<string>(StringComparer.Ordinal);
        foreach (var id in exclude)
        {
            if (byId.TryGetValue(id, out var t))
            {
                var k = TrackIdentity.Key(t);
                if (k != null) excludeKeys.Add(k);
            }
        }

        // Битые треки (файла на диске нет) в выдачу не пускаем: играть нечего. Считается один
        // раз на версию библиотеки, не на запрос. Важно, что это ОТДЕЛЬНЫЙ гейт, а не добавка
        // в excludeKeys: битая копия трека не должна утаскивать за собой живую (в библиотеке
        // лежат и .wav-битый, и .aiff-живой одного и того же трека).
        var unavailable = TrackAvailability.Shared.UnavailableIds(lib);

        // Граф совместности. Для одного сида берём ПОПАРНУЮ силу (она уже нормирована на
        // топ-1% канала), для плейлиста — насыщенный агрегат: у агрегата другая шкала, и
        // подмешивать одну в другую нельзя.
        var graph = CoPlayGraph.Shared;
        var co = seeds.Count == 1
            ? graph.Relatedness(seeds[0], lib, cfg.history_weight, cfg.playlist_weight)
            : graph.RelatednessToPlaylist(seeds, lib, cfg.history_weight, cfg.playlist_weight);

        // Проход 1 — гейты и сырые каналы.
        var pool = new List<Cand>(Math.Min(tracks.Count, 1024));
        foreach (var b in tracks)
        {
            if (exclude.Contains(b.Id)) continue;

            // Гейт 0 — файла нет на диске. Проверяем ПЕРВЫМ и до дедупа: битую копию надо
            // выкинуть раньше, чем она успеет «занять» ключ дубликата и вытеснить живую.
            if (unavailable.Contains(b.Id)) continue;

            // Гейт 1 — дубликат того, что уже в плейлисте (тот же трек под другим id).
            var dupKey = TrackIdentity.Key(b);
            if (dupKey != null && excludeKeys.Contains(dupKey)) continue;

            // Гейт 2 — темп. Абсолютное окно вокруг коридора сид-набора, с half/double.
            var folded = profile.FoldedBpm(b.Bpm, cfg);
            if (folded == null) continue;
            var bpm = folded.Value;

            // Гейт 3 — гармония. Кандидат обязан быть совместим хотя бы с одной тональностью
            // палитры. Нераспознанный ключ гейт НЕ режет (как и раньше).
            var cand = KeyNormalizer.Components(b.Key);
            var (keyFit, keyRel) = profile.KeyAffinity(cand, cfg);
            if (useKey && profile.HasKeys && cand != null && keyFit <= 0) continue;

            var labelFit  = profile.LabelShare.GetValueOrDefault(Norm(b.Label));
            var genreFit  = profile.GenreShare.GetValueOrDefault(GenreCanon.Canon(b.Genre));
            var artistFit = profile.ArtistShare.GetValueOrDefault(Norm(b.Artist));

            pool.Add(new Cand(
                Track:   b,
                Co:      co.GetValueOrDefault(b.Id),
                Content: profile.ContentScore(useKey ? keyFit : (double?)null,
                                              labelFit, genreFit, artistFit, cfg),
                // .rounded() в Swift — округление половины ОТ нуля; Math.Round(double) в C#
                // по умолчанию банковское (ToEven) и на .5 дало бы другое число, чем macOS.
                BpmDelta: Math.Round(Math.Abs(bpm - profile.BpmCenter) * 10, MidpointRounding.AwayFromZero) / 10,
                KeyRel:  keyRel,
                Label:   labelFit  > 0,
                Genre:   genreFit  > 0,
                Artist:  artistFit > 0,
                Duration: profile.DurationMatches(b.Duration, cfg),
                Known:   graph.Knows(b.Id),
                DupKey:  dupKey,
                Cold:    b.Histories.Count == 0));
        }
        if (pool.Count == 0) return new List<SimilarResult>();

        // Приведение каналов к общей шкале — по 99-му перцентилю ПУЛА (тот же приём, которым
        // CoPlayGraph сводит свои два канала).
        //
        // ЗАЧЕМ. content — это ДОЛИ состава («лейбл встречается у 6 сидов из 75»), и они
        // сжимаются как ~1/N: замер на живой библиотеке дал content ∈ [0…0.28] у плейлиста на
        // 75 треков против [0…1] у одного сида, тогда как co живёт в [0…0.6]. Без приведения
        // веса coplay/content означали бы РАЗНОЕ для плейлиста на 5 и на 100 треков, а
        // холодные треки (у которых co нет вообще) не могли бы догнать тёплые никогда — при
        // том что по метаданным они даже чуть лучше (mean content 0.149 против 0.131).
        //
        // Порог у co (CoScaleFloor) — предохранитель: если у плейлиста связей почти нет
        // (max co = 0.02), делить на такой перцентиль нельзя, иначе единственная слабая связь
        // раздувается до 1.0 и вылезает на первое место. Ниже порога co НЕ растягивается —
        // «слабо» остаётся «слабо». У content такого порога нет: он определён всегда.
        var coScale      = Math.Max(Percentile(pool.Select(c => c.Co), 0.99), CoScaleFloor);
        var contentScale = Math.Max(Percentile(pool.Select(c => c.Content), 0.99), 0.0001);

        var scored = new List<Scored>(pool.Count);
        foreach (var c in pool)
        {
            var coHat      = Math.Min(1.0, c.Co / coScale);
            var contentHat = Math.Min(1.0, c.Content / contentScale);
            var total      = Blend(coHat, contentHat, c.Known, cfg);
            scored.Add(new Scored(
                Track: c.Track,
                Score: new MatchScore(
                    Total:         Math.Round(total * 10_000, MidpointRounding.AwayFromZero) / 10_000,
                    BpmDelta:      c.BpmDelta,
                    KeyRelation:   RelLabel(c.KeyRel),
                    LabelMatch:    c.Label,
                    GenreMatch:    c.Genre,
                    ArtistMatch:   c.Artist,
                    DurationMatch: c.Duration),
                Co: c.Co, Content: c.Content, DupKey: c.DupKey, Cold: c.Cold));
        }

        // Сортировка БЕЗ ΔBPM: он ничего не различает (75% библиотеки в окне 118–130) и именно
        // он был источником «случайного мусора».
        //
        // Тай-брейк идёт по СЫРЫМ каналам, а не по обрезанным: всё, что сильнее 99-го
        // перцентиля, в скоре схлопнуто в 1.0 (цена общей шкалы), и без сырых значений порядок
        // на самом верху решался бы по id. Последний ключ — id (Ordinal, как посимвольное
        // сравнение в Swift): без него выдача гуляла бы между запусками агента.
        // OrderBy стабилен, в отличие от List.Sort — при полностью равных ключах (в библиотеке
        // возможны два трека с одним id) порядок остаётся порядком библиотеки, т.е. тем же от
        // запуска к запуску.
        var ordered = scored
            .OrderByDescending(s => s.Score.Total)
            .ThenByDescending(s => s.Co)
            .ThenByDescending(s => s.Content)
            .ThenBy(s => s.Track.Id, StringComparer.Ordinal);

        // Дедуп ВНУТРИ выдачи. Обе копии дубля могут лежать вне плейлиста — тогда список
        // показал бы один и тот же трек дважды. Список уже отсортирован, поэтому первая
        // встреченная копия — лучшая.
        var seenDup = new HashSet<string>(StringComparer.Ordinal);
        var unique = new List<Scored>(scored.Count);
        foreach (var s in ordered)
        {
            if (s.DupKey != null && !seenDup.Add(s.DupKey)) continue;
            unique.Add(s);
        }

        var poolSize   = Math.Max(limit, cfg.candidate_pool);
        var quotaPer10 = quota ? Math.Max(0, Math.Min(10, cfg.cold_start_quota_per_10)) : 0;

        var baseList = unique.Take(poolSize).ToList();
        if (quotaPer10 > 0)
        {
            // Холодных в основном пуле может не быть ВОВСЕ: потолок холодного трека
            // (0.5·0.65 + 0.35 = 0.675 против 1.0 у тёплого) на плотных кластерах не даёт ему
            // пролезть никогда. Поэтому кандидатов на квоту добираем из хвоста: они уже прошли
            // гейты по BPM и тональности, а между собой отсортированы по content (у холодного
            // трека total монотонен по content) — то есть это лучшие РЕЛЕВАНТНЫЕ открытия, а
            // не случайные треки. Берём с запасом: часть срежут лимиты «не больше N одного
            // артиста/лейбла».
            var need = (poolSize + 9) / 10 * quotaPer10;
            var have = baseList.Count(s => s.Cold);
            if (have < need)
                baseList.AddRange(unique.Skip(poolSize).Where(s => s.Cold).Take(2 * (need - have)));
        }

        var kept = baseList;
        var overflow = new List<Scored>();
        if (diversify)
            (kept, overflow) = SplitByDiversity(baseList, cfg, s => (s.Track.Artist, s.Track.Label));

        // Квота — ПОСЛЕ лимитов по артисту/лейблу и только внутри `kept`. Переставлять внутри
        // kept безопасно: лимит там соблюдён на всём списке, а значит и на любом его куске.
        // Тянуть же треки из overflow вперёд нельзя — это и есть нарушение лимита.
        if (quotaPer10 > 0) kept = InterleaveCold(kept, quotaPer10, s => s.Cold);

        var ranked = new List<Scored>(kept.Count + overflow.Count);
        ranked.AddRange(kept);
        ranked.AddRange(overflow);

        var start = Math.Min(Math.Max(0, offset), ranked.Count);
        var end   = Math.Min(start + limit, ranked.Count);
        if (start >= end) return new List<SimilarResult>();

        var result = new List<SimilarResult>(end - start);
        for (var i = start; i < end; i++) result.Add(new SimilarResult(ranked[i].Track, ranked[i].Score));
        return result;
    }

    /// Смесь двух путей.
    ///
    /// ПОЧЕМУ ИМЕННО ТАК (холодный старт). У 17% библиотеки co-play == 0 просто потому, что
    /// трек ни разу не игрался и не лежит ни в одном ручном плейлисте — граф о нём НЕ ЗНАЕТ.
    /// Но ровно такой же 0 получает трек, который граф знает отлично и который с этим
    /// плейлистом никак не связан. Это два РАЗНЫХ факта: «нет данных» и «есть данные, и они
    /// против». Складывая их в одну формулу, мы бы навсегда утопили непроигранные треки — и
    /// «новые треки не рекомендуются» стало бы новой жалобой.
    ///
    /// Поэтому для НЕИЗВЕСТНЫХ графу треков co-play не обнуляется, а ИМПУТИРУЕТСЯ из
    /// content-скора с дисконтом cold_start_backoff (0.5): это оценка, а не факт, и стоить она
    /// должна вдвое дешевле факта. Итог: холодный трек с идеальным контентом обгоняет тёплый
    /// трек с плохим контентом, но проигрывает тёплому с реальной историей совместных
    /// проигрываний. Ровно то поведение, которого мы хотим.
    private static double Blend(double co, double content, bool known, SimilarityConfig cfg)
    {
        var wCo = Math.Max(0, cfg.coplay_weight);
        var wCt = Math.Max(0, cfg.content_weight);
        var norm = wCo + wCt;
        if (norm <= 0) return content;
        var coEff = known ? co : Math.Max(0, Math.Min(1, cfg.cold_start_backoff)) * content;
        return (wCo * coEff + wCt * content) / norm;
    }

    /// Разнообразие: не больше max_per_artist треков одного артиста и max_per_label — одного
    /// лейбла. Лишние НЕ выбрасываются, а уезжают в overflow — хвост ранжированного списка.
    /// Иначе они пропали бы и со следующих страниц (Refresh), а это потеря кандидатов.
    ///
    /// Возвращает две части раздельно (а не склеенный список) ровно затем, чтобы квота
    /// открытий могла переставлять треки ВНУТРИ kept, не втягивая туда overflow.
    private static (List<T> Kept, List<T> Overflow) SplitByDiversity<T>(
        List<T> items, SimilarityConfig cfg, Func<T, (string Artist, string Label)> keys)
    {
        var artistCap = cfg.max_per_artist;
        var labelCap  = cfg.max_per_label;
        if (artistCap <= 0 && labelCap <= 0) return (items, new List<T>());

        var artistCount = new Dictionary<string, int>(StringComparer.Ordinal);
        var labelCount  = new Dictionary<string, int>(StringComparer.Ordinal);
        var kept = new List<T>(items.Count);
        var overflow = new List<T>();

        foreach (var it in items)
        {
            var (rawArtist, rawLabel) = keys(it);
            var a = Norm(rawArtist);
            var l = Norm(rawLabel);
            // Пустой артист/лейбл (тег не заполнен) — не «один и тот же» артист, лимит не применяем.
            var artistOver = artistCap > 0 && a.Length > 0 && artistCount.GetValueOrDefault(a) >= artistCap;
            var labelOver  = labelCap  > 0 && l.Length > 0 && labelCount.GetValueOrDefault(l)  >= labelCap;
            if (artistOver || labelOver)
            {
                overflow.Add(it);
            }
            else
            {
                if (a.Length > 0) artistCount[a] = artistCount.GetValueOrDefault(a) + 1;
                if (l.Length > 0) labelCount[l]  = labelCount.GetValueOrDefault(l)  + 1;
                kept.Add(it);
            }
        }
        return (kept, overflow);
    }

    /// КВОТА ОТКРЫТИЙ: в каждой десятке позиций — не меньше `quota` треков, которые никогда не
    /// игрались.
    ///
    /// ПОЧЕМУ КВОТА, А НЕ ВЕС. Холодный трек получает co-play не фактом, а оценкой с дисконтом,
    /// поэтому его потолок структурно ниже тёплого (0.675 против 1.0 при дефолтном конфиге).
    /// На плотных кластерах — а плейлист по определению плотный кластер — он не пролезает в топ
    /// НИКОГДА, и замер это подтвердил: 0 непроигранных треков в топ-10 при 47% непроигранных в
    /// библиотеке. Подкрутка весов лечит симптом на одном плейлисте и ломает другой; гарантия
    /// же формулируется прямо: блок называется «что ДОБАВИТЬ», значит открытия в нём обязаны БЫТЬ.
    ///
    /// Тёплый порядок при этом не перетасовывается: холодного добираем только тогда, когда в
    /// текущей десятке позиций уже впритык — то есть открытия садятся в хвост десятки, а топ
    /// остаётся за настоящими совпадениями. Квота считается по позиции в РАНЖИРОВАННОМ списке, а
    /// не в странице, поэтому работает и на offset-страницах (вторая десятка — такая же
    /// десятка). Полностью детерминированно: рандома нет.
    private static List<T> InterleaveCold<T>(List<T> items, int quota, Func<T, bool> isCold)
    {
        if (quota <= 0 || items.Count == 0) return items;
        var coldIdx = new List<int>();
        for (var i = 0; i < items.Count; i++) if (isCold(items[i])) coldIdx.Add(i);
        if (coldIdx.Count == 0) return items;

        var outList = new List<T>(items.Count);
        var emitted = new bool[items.Count];
        var next = 0;            // следующий по рангу невыданный
        var cold = 0;            // следующий невыданный холодный
        var coldInBlock = 0;

        while (outList.Count < items.Count)
        {
            var pos = outList.Count % 10;
            if (pos == 0) coldInBlock = 0;
            while (cold < coldIdx.Count && emitted[coldIdx[cold]]) cold += 1;

            int idx;
            if (quota - coldInBlock >= 10 - pos && cold < coldIdx.Count)
            {
                idx = coldIdx[cold];                       // мест в десятке ровно под дефицит
            }
            else
            {
                while (next < items.Count && emitted[next]) next += 1;
                if (next >= items.Count) break;
                idx = next;
            }
            emitted[idx] = true;
            if (isCold(items[idx])) coldInBlock += 1;
            outList.Add(items[idx]);
        }
        return outList;
    }

    /// Нормализация тега. ToLowerInvariant, а НЕ ToLower(): под турецкой локалью 'I'
    /// схлопывается в 'ı', и «ILLENIUM» перестал бы совпадать сам с собой. Trim() в .NET
    /// режет и пробелы, и переводы строк — это ровно .whitespacesAndNewlines из Swift.
    /// Ключ сравнения для лейбла/артиста в профиле сид-набора и в лимитах разнообразия.
    ///
    /// ⚠️ NFC обязателен по той же причине, что и в TrackIdentity/GenreCanon: Swift
    /// сравнивает String КАНОНИЧЕСКИ, поэтому у него "Lubó" в NFC и в NFD — один ключ
    /// словаря. В .NET Dictionary сравнивает ординально, и без нормализации один и тот
    /// же артист, записанный в разных формах юникода (а в живой библиотеке он именно так
    /// и записан — см. трек 62017310), разъехался бы на ДВЕ корзины профиля: доля
    /// каждой вдвое меньше настоящей, а лимит max_per_artist перестал бы его ловить.
    private static string Norm(string? s) =>
        TextNorm.Nfc((s ?? "").Trim().ToLowerInvariant());

    /// Минимальный масштаб co-канала. Ниже него канал НЕ растягивается: у плейлиста, про
    /// который граф почти ничего не знает, единственная слабая связь не должна превращаться в
    /// «сильнейшую связь этого плейлиста» и уезжать на первое место. Значение — в шкале
    /// CoPlayGraph, где 1.0 = связь силы топ-1% канала.
    private const double CoScaleFloor = 0.2;

    /// p-й перцентиль БЕЗ интерполяции. Максимум брать нельзя — это выброс.
    private static double Percentile(IEnumerable<double> xs, double p)
    {
        var sorted = xs.ToArray();
        if (sorted.Length == 0) return 0;
        Array.Sort(sorted);
        var idx = Math.Min(sorted.Length - 1, Math.Max(0, (int)((sorted.Length - 1) * p)));
        return sorted[idx];
    }

    // ── Профиль сид-набора ───────────────────────────────────────────────────

    /// То, ОТ ЧЕГО считаются рекомендации: темповый коридор, палитра тональностей и доли
    /// лейблов/жанров/артистов во всём составе плейлиста. Строится один раз на запрос.
    ///
    /// Все content-фичи — ДОЛИ сидов (0…1), а не булевы флаги. Это принципиально: булевы бонусы
    /// давали сотни кандидатов с одинаковым total, и порядок внутри них решал ΔBPM, то есть шум.
    /// Доля же различает «лейбл, на котором 15 треков из 40» и «лейбл, встретившийся один раз».
    private sealed class SeedProfile
    {
        public double BpmCenter { get; }      // медиана темпа (после свёртки half/double)
        private readonly double _bpmLow;      // p10 − допуск
        private readonly double _bpmHigh;     // p90 + допуск
        private readonly bool   _hasBpm;

        /// Слот Camelot (0…23) → доля сидов в этой тональности. Хранится МАССИВОМ, отсортированным
        /// по слоту, а не словарём: KeyAffinity складывает доли в double, и порядок слагаемых
        /// меняет последние биты суммы. Фиксированный порядок обхода = детерминированный скор.
        private readonly (int Slot, double Share)[] _keySlots;
        public bool HasKeys { get; }

        public Dictionary<string, double> LabelShare  { get; }
        public Dictionary<string, double> GenreShare  { get; }
        public Dictionary<string, double> ArtistShare { get; }
        private readonly bool _hasLabels;
        private readonly bool _hasGenres;
        private readonly bool _hasArtists;

        private readonly double? _medianDuration;

        public SeedProfile(List<Track> seeds, SimilarityConfig cfg)
        {
            // --- темп -----------------------------------------------------
            var rawBpms = seeds.Select(t => t.Bpm).Where(b => b > 0).OrderBy(b => b).ToList();
            _hasBpm = rawBpms.Count > 0;
            if (_hasBpm)
            {
                var median0 = rawBpms[rawBpms.Count / 2];
                // Сначала сворачиваем сами сиды: в плейлисте может лежать и 62, и 124 — без
                // свёртки коридор растянулся бы на всю библиотеку.
                var folded = rawBpms
                    .Select(b => cfg.bpm_allow_half_double ? Fold(b, median0) : b)
                    .OrderBy(b => b)
                    .ToList();
                var center = folded[folded.Count / 2];
                var tol = cfg.bpm_tolerance_abs > 0
                    ? cfg.bpm_tolerance_abs
                    : center * cfg.bpm_tolerance_pct / 100.0;
                // p10…p90, а не min…max: один затесавшийся даунтемпо-трек не должен раскрывать
                // коридор всего плейлиста. Индексы — усечение к нулю, как Int(...) в Swift.
                var loIdx = Math.Min(folded.Count - 1, (int)((folded.Count - 1) * 0.10));
                var hiIdx = Math.Min(folded.Count - 1, (int)((folded.Count - 1) * 0.90 + 0.9999));
                BpmCenter = center;
                _bpmLow   = folded[loIdx] - tol;
                _bpmHigh  = folded[hiIdx] + tol;
            }
            else
            {
                BpmCenter = 0; _bpmLow = 0; _bpmHigh = 0;
            }

            // --- тональности ----------------------------------------------
            var slots = new Dictionary<int, double>();
            var keyed = 0;
            foreach (var t in seeds)
            {
                var c = KeyNormalizer.Components(t.Key);
                if (c == null) continue;
                keyed += 1;
                var s = Slot(c.Value);
                slots[s] = slots.GetValueOrDefault(s) + 1;
            }
            HasKeys = keyed > 0;
            _keySlots = keyed > 0
                ? slots.OrderBy(kv => kv.Key).Select(kv => (kv.Key, kv.Value / keyed)).ToArray()
                : Array.Empty<(int, double)>();

            // --- лейбл / жанр / артист ------------------------------------
            // Знаменатель — число сидов С ЗАПОЛНЕННЫМ полем, а не весь состав: иначе в
            // плейлисте, где у половины треков нет лейбла, максимум labelFit был бы 0.5.
            LabelShare  = Share(seeds.Select(t => Norm(t.Label)));
            ArtistShare = Share(seeds.Select(t => Norm(t.Artist)));
            GenreShare  = Share(seeds.Select(t => GenreCanon.Canon(t.Genre)));
            _hasLabels  = LabelShare.Count  > 0;
            _hasArtists = ArtistShare.Count > 0;
            _hasGenres  = GenreShare.Count  > 0;

            var durs = seeds.Where(t => t.Duration is > 0).Select(t => t.Duration!.Value)
                            .OrderBy(d => d).ToList();
            _medianDuration = durs.Count == 0 ? null : durs[durs.Count / 2];
        }

        private static Dictionary<string, double> Share(IEnumerable<string> values)
        {
            var counts = new Dictionary<string, double>(StringComparer.Ordinal);
            var total = 0.0;
            foreach (var v in values)
            {
                if (string.IsNullOrEmpty(v)) continue;
                counts[v] = counts.GetValueOrDefault(v) + 1;
                total += 1;
            }
            if (total <= 0) return new Dictionary<string, double>(StringComparer.Ordinal);
            foreach (var k in counts.Keys.ToList()) counts[k] /= total;
            return counts;
        }

        /// Camelot → индекс 0…23 (номер × 2 + сторона). Гистограмма по 24 слотам считается один
        /// раз, поэтому KeyAffinity кандидата — это ≤24 операции, а не проход по всем сидам.
        private static int Slot(KeyNormalizer.Camelot c) => (c.Number - 1) * 2 + (c.Letter == 'A' ? 0 : 1);
        private static (int Num, char Letter) Unslot(int s) => (s / 2 + 1, s % 2 == 0 ? 'A' : 'B');

        /// Свёртка half/double-time к октаве центра: 62 → 124, 248 → 124. Порог √2 ≈ 1.414 —
        /// естественная граница между «в два раза медленнее» и «просто медленнее».
        public static double Fold(double bpm, double center)
        {
            if (bpm <= 0 || center <= 0) return bpm;
            var x = bpm;
            var guardCount = 0;
            while (x < center / 1.414 && guardCount < 4) { x *= 2; guardCount += 1; }
            while (x > center * 1.414 && guardCount < 8) { x /= 2; guardCount += 1; }
            return x;
        }

        /// Гейт по темпу. null → кандидат отсеян. Иначе — BPM кандидата, свёрнутый в октаву
        /// плейлиста (его же кладём в bpm_delta ответа).
        public double? FoldedBpm(double bpm, SimilarityConfig cfg)
        {
            if (bpm <= 0) return null;               // трек без темпа не рекомендуем (как и раньше)
            if (!_hasBpm) return bpm;                // у сидов нет темпа — гейт нечем применить
            var x = cfg.bpm_allow_half_double ? Fold(bpm, BpmCenter) : bpm;
            if (x < _bpmLow || x > _bpmHigh) return null;
            return x;
        }

        /// Гармоническая близость кандидата к ПАЛИТРЕ тональностей плейлиста: сумма долей сидов,
        /// взвешенная качеством перехода. Для одного сида вырождается ровно в старое
        /// exact/relative/compatible. Возвращает и лучшее отношение — для поля key_relation.
        public (double Fit, KeyRel Rel) KeyAffinity(KeyNormalizer.Camelot? cand, SimilarityConfig cfg)
        {
            if (cand == null || !HasKeys) return (0, KeyRel.Unknown);
            var c = cand.Value;
            var fit = 0.0;
            var best = KeyRel.Incompatible;
            foreach (var (s, share) in _keySlots)
            {
                var (num, letter) = Unslot(s);
                var diff  = Math.Abs(num - c.Number);
                var steps = Math.Min(diff, 12 - diff);
                KeyRel rel;
                if (num == c.Number && letter == c.Letter)                    rel = KeyRel.Exact;
                else if (num == c.Number)                                     rel = KeyRel.Relative;
                else if (letter == c.Letter && steps <= cfg.key_max_steps)    rel = KeyRel.Compatible;
                else                                                          rel = KeyRel.Incompatible;
                fit += RelAffinity(rel) * share;
                if (RelRank(rel) > RelRank(best)) best = rel;
            }
            return (fit, best);
        }

        /// Content-скор в [0…1]: взвешенное среднее активных фич. Признак, который в этом
        /// плейлисте не может сработать (например, ни у одного сида не заполнен лейбл), из
        /// знаменателя ИСКЛЮЧАЕТСЯ — иначе он молча штрафовал бы всех кандидатов разом.
        public double ContentScore(double? keyFit, double labelFit, double genreFit, double artistFit,
                                   SimilarityConfig cfg)
        {
            var w = cfg.weights;
            double num = 0, den = 0;
            if (keyFit != null && HasKeys && w.key > 0) { num += w.key    * keyFit.Value; den += w.key; }
            if (_hasLabels  && w.label  > 0)            { num += w.label  * labelFit;     den += w.label; }
            if (_hasGenres  && w.genre  > 0)            { num += w.genre  * genreFit;     den += w.genre; }
            if (_hasArtists && w.artist > 0)            { num += w.artist * artistFit;    den += w.artist; }
            if (den <= 0) return 0;
            return Math.Min(1.0, num / den);
        }

        /// Информационный флаг (в скор не входит): длина кандидата в окне от медианы состава.
        public bool DurationMatches(double? d, SimilarityConfig cfg)
        {
            if (d is not > 0) return false;
            if (_medianDuration is not > 0) return false;
            var m = _medianDuration.Value;
            return Math.Abs(d.Value - m) / m <= cfg.duration_tolerance_pct / 100.0;
        }
    }

    // ── Гармоническое отношение ──────────────────────────────────────────────

    private enum KeyRel
    {
        Exact,        // та же тональность
        Relative,     // тот же номер, другая сторона колеса (параллельный мажор/минор)
        Compatible,   // та же сторона, в пределах key_max_steps по колесу
        Incompatible,
        Unknown,      // ключ не распознан — НЕ повод отсеивать кандидата
    }

    /// Значение поля key_relation в ответе. Строки — часть контракта с iOS и веб-плеером,
    /// менять нельзя. "—" (em dash) — тот же символ, что и в Track.Key по умолчанию.
    private static string RelLabel(KeyRel r) => r switch
    {
        KeyRel.Exact        => "exact",
        KeyRel.Relative     => "relative",
        KeyRel.Compatible   => "compatible",
        KeyRel.Incompatible => "incompatible",
        _                   => "—",
    };

    /// Вклад в keyFit. Точное совпадение — эталон перехода; параллельная тональность почти так
    /// же хороша; соседняя по колесу — рабочий, но заметно более слабый ход.
    private static double RelAffinity(KeyRel r) => r switch
    {
        KeyRel.Exact      => 1.0,
        KeyRel.Relative   => 0.7,
        KeyRel.Compatible => 0.5,
        _                 => 0.0,
    };

    private static int RelRank(KeyRel r) => r switch
    {
        KeyRel.Exact        => 4,
        KeyRel.Relative     => 3,
        KeyRel.Compatible   => 2,
        KeyRel.Unknown      => 1,
        KeyRel.Incompatible => 0,
        _                   => 0,
    };
}
