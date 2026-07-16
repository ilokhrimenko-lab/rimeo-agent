using System.Diagnostics;
using System.Globalization;
using System.Text.Json.Serialization;
using RimeoAgent.Models;

namespace RimeoAgent.Services;

// Граф совместности треков — «что с чем реально играется/лежит вместе».
// Порт macos_arm64/Sources/RimeoAgentMac/Services/CoPlayGraph.swift, число в число.
//
// Два независимых канала, оба строятся из уже разобранной библиотеки (LibraryData):
//
//   1) HISTORY — упорядоченные сеты Rekordbox (djmdHistory). У трека есть
//      HistoryIndices["hist:<id>"] = TrackNo, то есть позиция в сете. Соседние
//      позиции = реальный, проверенный человеком переход. Это сильнейший сигнал
//      в библиотеке, и метаданными Beatport он не выражается.
//
//   2) PLAYLIST — co-occurrence в РУЧНЫХ плейлистах (Track.Playlists). SMART-
//      плейлисты исключены намеренно: их состав порождён правилом («genre = Afro
//      House»), учиться на них = переучивать модель на тот же жанровый фильтр,
//      который мы и пытаемся заменить. Канал важен потому, что покрывает те треки,
//      которых нет в истории (никогда не игрались).
//
// Оба канала дают ЧИСЛО в [0…1] на пару треков; шкалы каналов приведены друг к
// другу нормировкой по 99-му перцентилю (см. Rescale), поэтому их можно складывать
// с весами.
//
// Класс не знает ни про SimilarityEngine, ни про HTTP: чистая функция от LibraryData.
public sealed class CoPlayGraph
{
    public static readonly CoPlayGraph Shared = new();
    private CoPlayGraph() { }

    // ── Параметры (осознанные константы, не конфиг) ──────────────────────────

    /// Сессии короче этого — мусор: Rekordbox сам режет историю на огрызки
    /// (открыл деку, дёрнул трек, закрыл). На реальной библиотеке отсечение
    /// оставляет ~60% сессий, но ~90% переходов.
    public const int MinSessionTracks = 10;

    /// Окно соседства в сете: вес по смещению позиции. [0] — прямой сосед (i,i+1),
    /// [1] — «через один». Треки через один тоже связаны (диджей уже был в этой
    /// зоне вечера), но втрое слабее.
    public static readonly double[] NeighborWeights = { 1.0, 0.4 };

    /// Демпфер редких пар (shrinkage). Косинус сам по себе даёт 1.0 паре, которая
    /// встретилась ОДИН раз у двух треков, больше нигде не игравшихся, — это
    /// переоценка одиночного наблюдения. Множитель c/(c+k) гасит такие пары:
    /// одно соседство → ×0.5, три → ×0.75.
    public const double HistoryShrinkK = 1.0;
    /// Для плейлистов вклад пары дробный (1/(n-1)), поэтому и k меньше.
    public const double PlaylistShrinkK = 0.25;

    /// Плейлисты-свалки (архив/«всё подряд») кураторским сигналом не являются и
    /// дают квадратичный взрыв пар. На реальной библиотеке максимум — 136 треков.
    public const int MaxManualPlaylistSize = 400;

    /// Верхняя граница строки графа. Хвост слабых связей не влияет на топ-50, но
    /// удваивает память на хабах.
    public const int MaxNeighbors = 250;

    /// Веса каналов по умолчанию. История точнее (это ФАКТ проигрывания), но
    /// покрывает ~53% библиотеки; плейлисты слабее, зато покрывают ~81%.
    public const double DefaultHistoryWeight = 1.0;
    public const double DefaultPlaylistWeight = 0.6;

    /// Полунасыщение агрегата по плейлисту: raw=2.0 → 0.5. Насыщающая нормировка
    /// (raw/(raw+h)) монотонна, поэтому НЕ меняет ранжирование, но держит выход в
    /// (0…1) независимо от размера плейлиста — иначе плейлист на 200 треков давал
    /// бы кандидатов со скором 15, а на 5 треков — 0.3, и общий вес графа в
    /// SimilarityEngine пришлось бы подбирать под каждый размер.
    public const double PlaylistHalfSaturation = 2.0;

    /// Предохранитель: у совсем гигантских плейлистов берём каждый k-й трек как сид.
    public const int MaxSeeds = 500;

    // ── Состояние ───────────────────────────────────────────────────────────

    /// Ключи JSON заданы явно (camelCase) — ровно то, что отдаёт Codable на macOS.
    /// Без атрибутов System.Text.Json написал бы PascalCase, и диагностический
    /// /api/*-ответ разъехался бы с маком на пустом месте.
    public sealed record Stats(
        [property: JsonPropertyName("tracks")]            int    Tracks,
        [property: JsonPropertyName("sessionsTotal")]     int    SessionsTotal,     // сессий в истории всего
        [property: JsonPropertyName("sessionsUsed")]      int    SessionsUsed,      // из них >= MinSessionTracks
        [property: JsonPropertyName("historyPairs")]      int    HistoryPairs,      // уникальных пар A–B (симметричных)
        [property: JsonPropertyName("manualPlaylists")]   int    ManualPlaylists,   // ручных непустых плейлистов
        [property: JsonPropertyName("playlistPairs")]     int    PlaylistPairs,
        [property: JsonPropertyName("historyCoverage")]   int    HistoryCoverage,   // треков с хотя бы одной связью по истории
        [property: JsonPropertyName("playlistCoverage")]  int    PlaylistCoverage,
        [property: JsonPropertyName("coldTracks")]        int    ColdTracks,        // ни истории, ни ручных плейлистов
        [property: JsonPropertyName("buildMs")]           double BuildMs,
        [property: JsonPropertyName("version")]           string Version);

    // lock в C# реентерабелен (Monitor), в отличие от NSLock. Поэтому обёртки
    // «EnsureBuilt → взять лок → читать строки» безопасны даже при вложенном взятии,
    // и городить lock-free-чтение, как пришлось бы на Swift, не нужно.
    private readonly object _lock = new();

    private string _version = "";
    private List<string> _ids = new();
    private Dictionary<string, int> _indexOf = new();
    /// Нормированные строки графа: rows[i][j] = сила связи i↔j в [0…1].
    private List<Dictionary<int, double>> _histRows = new();
    private List<Dictionary<int, double>> _histNext = new();   // направленная A→B (что играют ПОСЛЕ A)
    private List<Dictionary<int, double>> _plRows = new();
    private Stats? _lastStats;

    // ── Публичный API ───────────────────────────────────────────────────────

    /// Ключ версии графа = ключ кэша парсера. XmlDate — это mtime master.db
    /// (max по db/-wal), см. RekordboxParser. Значит граф протухает ровно тогда,
    /// когда протухает кэш парса, и не пересобирается, пока библиотека не изменилась.
    ///
    /// InvariantCulture обязателен: у пользователя с русской/немецкой локалью
    /// double.ToString() дал бы запятую, и ключ версии зависел бы от настроек
    /// Windows. Сам по себе он никуда не уезжает, но сравнивать его с ключом,
    /// посчитанным в другом потоке/культуре, было бы нельзя.
    public static string VersionKey(LibraryData lib) =>
        FormattableString.Invariant($"{lib.XmlDate}|{lib.Tracks.Count}|{lib.Playlists.Count}");

    /// Ленивая сборка: no-op, если граф уже построен на этой версии библиотеки.
    /// Строим ПОД ТЕМ ЖЕ локом, что и читаем: параллельные HTTP-запросы не должны
    /// собирать граф дважды.
    public Stats EnsureBuilt(LibraryData lib)
    {
        var key = VersionKey(lib);
        lock (_lock)
        {
            if (_version == key && _lastStats is { } s) return s;
            return Build(lib, key);
        }
    }

    public void Invalidate()
    {
        lock (_lock)
        {
            _version = "";
            _ids = new();
            _indexOf = new();
            _histRows = new();
            _histNext = new();
            _plRows = new();
            _lastStats = null;
        }
    }

    public Stats? StatsSnapshot()
    {
        lock (_lock) return _lastStats;
    }

    /// Знает ли граф про этот трек хоть что-нибудь (не «холодный» ли он).
    public bool Knows(string trackId)
    {
        lock (_lock)
        {
            if (!_indexOf.TryGetValue(trackId, out var i)) return false;
            return _histRows[i].Count > 0 || _plRows[i].Count > 0;
        }
    }

    /// Связность одного трека: кандидат → сила в [0…1] (сумма каналов, приведённая
    /// к единице). Пустой словарь = граф про этот трек ничего не знает.
    public Dictionary<string, double> Relatedness(string trackId, LibraryData lib,
                                                  double historyWeight = DefaultHistoryWeight,
                                                  double playlistWeight = DefaultPlaylistWeight)
    {
        EnsureBuilt(lib);
        lock (_lock)
        {
            if (!_indexOf.TryGetValue(trackId, out var i)) return new();
            var norm = Math.Max(historyWeight + playlistWeight, 0.0001);
            var outMap = new Dictionary<string, double>(_histRows[i].Count + _plRows[i].Count);
            foreach (var (j, v) in _histRows[i]) outMap[_ids[j]] = v * historyWeight / norm;
            foreach (var (j, v) in _plRows[i])
            {
                outMap.TryGetValue(_ids[j], out var prev);
                outMap[_ids[j]] = prev + v * playlistWeight / norm;
            }
            return outMap;
        }
    }

    /// Агрегат по всему составу плейлиста: кандидат → сила в (0…1).
    /// Сами члены плейлиста из выдачи исключены. Ранжирование = ранжирование по
    /// сырой сумме (нормировка монотонна), значение — сравнимо между плейлистами.
    public Dictionary<string, double> RelatednessToPlaylist(IReadOnlyList<string> trackIds, LibraryData lib,
                                                            double historyWeight = DefaultHistoryWeight,
                                                            double playlistWeight = DefaultPlaylistWeight)
    {
        var raw = RawRelatednessToPlaylist(trackIds, lib, historyWeight, playlistWeight);
        if (raw.Count == 0) return new();
        var outMap = new Dictionary<string, double>(raw.Count);
        foreach (var (id, v) in raw) outMap[id] = v / (v + PlaylistHalfSaturation);
        return outMap;
    }

    /// Сырая сумма вкладов сидов (не насыщена). Полезна для диагностики и для
    /// потребителя, которому нужна «поддержка» кандидата, а не шкала.
    public Dictionary<string, double> RawRelatednessToPlaylist(IReadOnlyList<string> trackIds, LibraryData lib,
                                                               double historyWeight = DefaultHistoryWeight,
                                                               double playlistWeight = DefaultPlaylistWeight)
    {
        EnsureBuilt(lib);
        lock (_lock)
        {
            if (_ids.Count == 0) return new();

            var seedIdx = new List<int>();
            var member = new HashSet<int>();
            foreach (var id in trackIds)
            {
                if (!_indexOf.TryGetValue(id, out var i)) continue;
                if (member.Add(i)) seedIdx.Add(i);
            }
            if (seedIdx.Count == 0) return new();
            seedIdx = Sample(seedIdx, MaxSeeds);

            var acc = new Dictionary<int, double>();
            foreach (var i in seedIdx)
            {
                foreach (var (j, v) in _histRows[i])
                {
                    if (member.Contains(j)) continue;
                    acc.TryGetValue(j, out var prev);
                    acc[j] = prev + v * historyWeight;
                }
                foreach (var (j, v) in _plRows[i])
                {
                    if (member.Contains(j)) continue;
                    acc.TryGetValue(j, out var prev);
                    acc[j] = prev + v * playlistWeight;
                }
            }

            var outMap = new Dictionary<string, double>(acc.Count);
            foreach (var (j, v) in acc) outMap[_ids[j]] = v;
            return outMap;
        }
    }

    /// Направленный канал: что по истории играют ПОСЛЕ этого трека. Для «добавить
    /// в плейлист» не нужен, но это тот же граф, и он нужен для «что поставить
    /// следующим» — отдаём отдельно, чтобы не смешивать с симметричной близостью.
    public Dictionary<string, double> Successors(string trackId, LibraryData lib)
    {
        EnsureBuilt(lib);
        lock (_lock)
        {
            if (!_indexOf.TryGetValue(trackId, out var i)) return new();
            var outMap = new Dictionary<string, double>(_histNext[i].Count);
            foreach (var (j, v) in _histNext[i]) outMap[_ids[j]] = v;
            return outMap;
        }
    }

    // ── Сборка ──────────────────────────────────────────────────────────────

    /// Вызывается ПОД ЛОКОМ.
    private Stats Build(LibraryData lib, string key)
    {
        // Stopwatch, а не DateTime.Now: buildMs — измерение длительности, а системные
        // часы на Windows умеют прыгать назад (NTP-синк), давая отрицательное время.
        var sw = Stopwatch.StartNew();
        var tracks = lib.Tracks;
        var n = tracks.Count;

        _ids = new List<string>(n);
        _indexOf = new Dictionary<string, int>(n);
        for (var i = 0; i < n; i++)
        {
            _ids.Add(tracks[i].Id);
            // Дубликат id (битая библиотека) перетирает предыдущий индекс — ровно как
            // в Swift. Молча «чинить» это здесь нельзя: индексы строк графа обязаны
            // соответствовать позициям в lib.Tracks, иначе _ids[j] отдаст чужой трек.
            _indexOf[tracks[i].Id] = i;
        }

        // ── Канал 1: история сетов ──────────────────────────────────────────

        var sessions = new Dictionary<string, List<(int No, int Idx)>>();
        for (var i = 0; i < n; i++)
        {
            foreach (var (path, no) in tracks[i].HistoryIndices)
            {
                if (!sessions.TryGetValue(path, out var list))
                {
                    list = new List<(int, int)>();
                    sessions[path] = list;
                }
                list.Add((no, i));
            }
        }

        var histC = NewRows(n);   // симметричные веса
        var histD = NewRows(n);   // направленные A→B
        var sessionsUsed = 0;

        foreach (var rows in sessions.Values)
        {
            if (rows.Count < MinSessionTracks) continue;
            sessionsUsed++;
            // ThenBy(Idx), которого нет в Swift: сортировка в Swift НЕ стабильна, и при
            // двух треках с одинаковым TrackNo (битая история) порядок был бы случайным.
            // Тай-брейк по индексу трека делает порядок соседства детерминированным.
            var seq = rows.OrderBy(r => r.No).ThenBy(r => r.Idx).Select(r => r.Idx).ToList();
            for (var i = 0; i < seq.Count; i++)
            {
                for (var d = 1; d <= NeighborWeights.Length; d++)
                {
                    var j = i + d;
                    if (j >= seq.Count) break;
                    int a = seq[i], b = seq[j];
                    if (a == b) continue;   // трек могли поставить дважды за сет
                    var w = NeighborWeights[d - 1];
                    Add(histC[a], b, w);
                    Add(histC[b], a, w);
                    Add(histD[a], b, w);
                }
            }
        }

        // Нормировка по популярности. Берём косинус (association strength):
        //     sim(A,B) = c(A,B) / sqrt(deg(A) * deg(B))
        // где deg — суммарный вес соседств трека. Трек, который стоит в каждом
        // сете, имеет огромный deg, и его связи автоматически обесцениваются —
        // иначе он бы «похож на всё».
        // Почему не PMI: PMI взрывается на редких парах (два трека, сыгранных
        // рядом ровно один раз, получают максимальный балл) и требует отдельного
        // порога по частоте. Косинус деградирует плавно, а одиночные наблюдения
        // додавливаем shrinkage-множителем c/(c+k).
        var histDeg = Degrees(histC);
        var histScore = NewRows(n);
        var histSamples = new List<double>(4096);
        for (var a = 0; a < n; a++)
        {
            if (!(histDeg[a] > 0)) continue;
            var row = new Dictionary<int, double>(histC[a].Count);
            foreach (var (b, c) in histC[a])
            {
                if (!(histDeg[b] > 0)) continue;
                var cosine = c / Math.Sqrt(histDeg[a] * histDeg[b]);
                var shrink = c / (c + HistoryShrinkK);
                var s = cosine * shrink;
                if (!(s > 0)) continue;
                row[b] = s;
                if (a < b) histSamples.Add(s);   // уникальные пары для перцентиля
            }
            histScore[a] = row;
        }
        var histPairs = histSamples.Count;
        Rescale(histScore, histSamples);

        // Направленный канал — та же формула, но по out/in-степеням.
        var outDeg = new double[n];
        var inDeg = new double[n];
        for (var a = 0; a < n; a++)
        {
            foreach (var (b, c) in histD[a]) { outDeg[a] += c; inDeg[b] += c; }
        }
        var dirScore = NewRows(n);
        var dirSamples = new List<double>();
        for (var a = 0; a < n; a++)
        {
            if (!(outDeg[a] > 0)) continue;
            var row = new Dictionary<int, double>(histD[a].Count);
            foreach (var (b, c) in histD[a])
            {
                if (!(inDeg[b] > 0)) continue;
                var s = (c / Math.Sqrt(outDeg[a] * inDeg[b])) * (c / (c + HistoryShrinkK));
                if (!(s > 0)) continue;
                row[b] = s;
                dirSamples.Add(s);
            }
            dirScore[a] = row;
        }
        Rescale(dirScore, dirSamples);

        // ── Канал 2: co-occurrence в РУЧНЫХ плейлистах ──────────────────────

        // Ручной = не папка, не smart, не история. Парсер отдаёт IsSmart/IsFolder,
        // legacy-`Smart` дублирует IsSmart — проверяем ОБА, чтобы старый кэш парса
        // (в нём заполнено только `smart`) тоже фильтровался правильно.
        var manualPaths = new HashSet<string>();
        foreach (var pl in lib.Playlists)
        {
            if (pl.History == true || pl.IsFolder == true || pl.IsSmart == true || pl.Smart == true) continue;
            manualPaths.Add(pl.Path);
        }

        var members = new Dictionary<string, List<int>>();
        for (var i = 0; i < n; i++)
        {
            foreach (var p in tracks[i].Playlists)
            {
                if (!manualPaths.Contains(p)) continue;
                if (!members.TryGetValue(p, out var list))
                {
                    list = new List<int>();
                    members[p] = list;
                }
                list.Add(i);
            }
        }

        var plC = NewRows(n);
        var manualUsed = 0;
        foreach (var m in members.Values)
        {
            var size = m.Count;
            if (size < 2 || size > MaxManualPlaylistSize) continue;
            manualUsed++;
            // Гашение размером: каждый трек раздаёт РОВНО единицу веса своим
            // соседям по плейлисту → пара из плейлиста на 12 весит 1/11 = 0.091,
            // а из плейлиста на 100 — 1/99 = 0.010 (в 9 раз меньше). Побочный
            // приятный эффект: deg(X) в этом канале ≈ числу плейлистов с X,
            // поэтому косинус ниже читается как «доля общих плейлистов».
            var w = 1.0 / (size - 1);
            for (var x = 0; x < size; x++)
            {
                var a = m[x];
                for (var y = x + 1; y < size; y++)
                {
                    var b = m[y];
                    Add(plC[a], b, w);
                    Add(plC[b], a, w);
                }
            }
        }

        var plDeg = Degrees(plC);
        var plScore = NewRows(n);
        var plSamples = new List<double>(1 << 16);
        for (var a = 0; a < n; a++)
        {
            if (!(plDeg[a] > 0)) continue;
            var row = new Dictionary<int, double>(plC[a].Count);
            foreach (var (b, c) in plC[a])
            {
                if (!(plDeg[b] > 0)) continue;
                var s = (c / Math.Sqrt(plDeg[a] * plDeg[b])) * (c / (c + PlaylistShrinkK));
                if (!(s > 0)) continue;
                row[b] = s;
                if (a < b) plSamples.Add(s);
            }
            plScore[a] = row;
        }
        var plPairs = plSamples.Count;
        Rescale(plScore, plSamples);

        // ── Обрезка хвостов и публикация ────────────────────────────────────

        Prune(histScore);
        Prune(dirScore);
        Prune(plScore);

        _histRows = histScore;
        _histNext = dirScore;
        _plRows = plScore;
        _version = key;

        int histCov = 0, plCov = 0, cold = 0;
        for (var i = 0; i < n; i++)
        {
            var h = _histRows[i].Count > 0;
            var p = _plRows[i].Count > 0;
            if (h) histCov++;
            if (p) plCov++;
            if (!h && !p) cold++;
        }

        var s2 = new Stats(
            Tracks: n,
            SessionsTotal: sessions.Count,
            SessionsUsed: sessionsUsed,
            HistoryPairs: histPairs,
            ManualPlaylists: manualUsed,
            PlaylistPairs: plPairs,
            HistoryCoverage: histCov,
            PlaylistCoverage: plCov,
            ColdTracks: cold,
            BuildMs: Math.Round(sw.Elapsed.TotalMilliseconds * 100, MidpointRounding.AwayFromZero) / 100,
            Version: key);
        _lastStats = s2;
        return s2;
    }

    // ── Хелперы ─────────────────────────────────────────────────────────────

    private static List<Dictionary<int, double>> NewRows(int n)
    {
        var rows = new List<Dictionary<int, double>>(n);
        for (var i = 0; i < n; i++) rows.Add(new Dictionary<int, double>());
        return rows;
    }

    private static void Add(Dictionary<int, double> row, int key, double w)
    {
        row.TryGetValue(key, out var prev);
        row[key] = prev + w;
    }

    /// Степень узла = сумма весов его соседств.
    ///
    /// Сумму НЕ сортируем перед свёрткой — как и Swift. В C# порядок обхода
    /// Dictionary детерминирован при одинаковой последовательности вставок, а она
    /// здесь детерминирована (обход lib.Tracks и sessions идёт по фиксированному
    /// порядку). Сортировка ключей дала бы другую последовательность сложений
    /// double и, значит, другой результат в 16-м знаке — то есть уводила бы нас ОТ
    /// macOS, а не к нему. Остаточный дрейф в последних битах в любом случае
    /// стирается округлением до 1e-6 в Rescale.
    private static double[] Degrees(List<Dictionary<int, double>> rows)
    {
        var deg = new double[rows.Count];
        for (var a = 0; a < rows.Count; a++)
        {
            double sum = 0;
            foreach (var v in rows[a].Values) sum += v;
            deg[a] = sum;
        }
        return deg;
    }

    /// Приводим канал к общей шкале: делим на 99-й перцентиль его же пар и режем
    /// по 1.0. Медиану/максимум брать нельзя: максимум — это выброс (одна пара
    /// «два трека, игравшихся только друг с другом»), он бы прижал весь канал к
    /// нулю. После этого 1.0 читается одинаково в обоих каналах: «связь силы
    /// топ-1% в своём канале», и каналы можно складывать с весами.
    private static void Rescale(List<Dictionary<int, double>> rows, List<double> samples)
    {
        if (samples.Count == 0) return;
        double scale;
        if (samples.Count < 20)
        {
            scale = samples.Max();
        }
        else
        {
            var sorted = samples.ToArray();
            Array.Sort(sorted);
            // Int(...) в Swift — усечение к нулю, приведение (int) в C# — тоже.
            var idx = Math.Min(sorted.Length - 1, (int)(sorted.Length * 0.99));
            scale = sorted[idx];
        }
        if (!(scale > 0)) return;

        // Округление до 1e-6 — не косметика: степени треков считаются суммой по
        // словарю, а порядок обхода Dictionary в Swift зависит от seed процесса.
        // Без округления скоры гуляли бы в 16-м знаке между перезапусками агента и
        // ничьи в топе схлопывались бы по-разному. Округлили — выдача бит-в-бит
        // одинаковая, и Windows совпадает с macOS.
        //
        // MidpointRounding.AwayFromZero обязателен: Swift .rounded() округляет
        // половину ОТ нуля, а Math.Round в .NET по умолчанию — к чётному
        // (банковское). На .5 в шестом знаке это разные числа.
        foreach (var row in rows)
        {
            if (row.Count == 0) continue;
            // Ключи копируем: словарь нельзя мутировать во время его же обхода.
            foreach (var b in row.Keys.ToArray())
            {
                var v = Math.Min(1.0, row[b] / scale);
                row[b] = Math.Round(v * 1_000_000.0, MidpointRounding.AwayFromZero) / 1_000_000.0;
            }
        }
    }

    private static void Prune(List<Dictionary<int, double>> rows)
    {
        for (var a = 0; a < rows.Count; a++)
        {
            if (rows[a].Count <= MaxNeighbors) continue;
            // ThenBy(Key) — тай-брейк, которого нет в Swift (там сортировка не
            // стабильна, и на границе отсечения при равных весах выживал случайный
            // сосед). Здесь равные веса режутся по индексу трека, поэтому состав
            // строки одинаков от запуска к запуску.
            rows[a] = rows[a]
                .OrderByDescending(kv => kv.Value)
                .ThenBy(kv => kv.Key)
                .Take(MaxNeighbors)
                .ToDictionary(kv => kv.Key, kv => kv.Value);
        }
    }

    /// Детерминированная выборка каждого k-го — стабильна между запросами.
    private static List<int> Sample(List<int> xs, int limit)
    {
        if (xs.Count <= limit || limit <= 0) return xs;
        var step = (int)Math.Ceiling((double)xs.Count / limit);
        var outList = new List<int>();
        for (var i = 0; i < xs.Count; i += step) outList.Add(xs[i]);
        return outList;
    }
}
