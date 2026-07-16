using System.Collections.Concurrent;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace RimeoAgent.Config;

public enum LogLevel
{
    Debug = 0,
    Info  = 1,
    Warn  = 2,
    Error = 3,
}

/// <summary>
/// Файловый лог агента (порт macOS AgentLogger.swift).
///
/// ⚠️ ГРАБЛИ, СТОИВШИЕ ПОЛДНЯ АРХЕОЛОГИИ (13.07.2026):
/// Прошлая версия держала кольцевой буфер на 500 строк и **переписывала весь файл
/// целиком** (File.WriteAllText) на КАЖДУЮ строку лога. Три последствия, каждое
/// из которых кусалось:
///   1. Глубина памяти ~17 минут (91% строк съедал debug-спам relay-поллинга) —
///      расследовать вчерашний инцидент было физически нечем.
///   2. Рестарт агента затирал улики о рестарте агента.
///   3. Полная перезапись файла на каждую строку. Во время стрима (range-шторм
///      AVPlayer) это десятки лишних записей на диск в секунду.
///
/// Теперь: append через StreamWriter + ротация по размеру. Файл переживает
/// рестарт, история не теряется, диск не насилуется.
/// </summary>
public sealed class AgentLogger
{
    public static readonly AgentLogger Shared = new();

    // MARK: - Диск

    private const int MaxBytes    = 5 * 1024 * 1024;  // 5 МБ на файл
    private const int Generations = 3;                // agent.log + .1 + .2 → максимум 15 МБ

    private readonly string _logPath;
    private StreamWriter? _writer;
    private long _fileBytes;                          // ведём сами, чтобы не звать stat на каждой строке

    /// Один писатель — вместо serial DispatchQueue из macOS. Всё, что трогает
    /// _writer / _fileBytes (включая ротацию), живёт ТОЛЬКО на этом потоке, поэтому
    /// файловая часть вообще не нуждается в блокировках — и не может сцепиться
    /// с чтением из UI.
    private readonly BlockingCollection<Entry> _queue = new();
    private readonly Thread _pump;

    private readonly record struct Entry(string? Line, ManualResetEventSlim? Done);

    // MARK: - Память (только для UI и report_bug — от файла отвязано)

    /// Отдельный lock на кольцо, а НЕ общий с записью: ротация живёт на потоке-писателе,
    /// и LastLines() из UI-потока мог бы с ней сцепиться в дедлок.
    private readonly object _ringLock = new();
    private readonly Queue<string> _ring = new();
    private const int RingCap = 1000;                 // ApiRouter просит 800 — в 500 они физически не влезали

    /// Порог отсечки. Debug гасится по умолчанию: relay-поллинг генерит его каждые
    /// пару секунд и раньше вытеснял из лога всё полезное.
    /// На macOS это UserDefaults (`defaults write app.rimeo.agent rimeo_verbose_logging`);
    /// на Windows аналога «домена настроек процесса» нет — реестр/AppData для одного
    /// булева флага избыточен и требует UI, поэтому включаем переменной окружения:
    ///   setx RIMEO_VERBOSE_LOGGING 1  + перезапуск агента.
    public LogLevel MinLevel { get; set; } = VerboseEnabled ? LogLevel.Debug : LogLevel.Info;

    /// ЕДИНСТВЕННЫЙ разбор флага на весь агент.
    ///
    /// ⚠️ Раньше их было два: здесь ("1"/"true"/"TRUE", без trim) и в access-логе
    /// HttpServer ("1"/"true"/"yes", с trim+lowercase). При RIMEO_VERBOSE_LOGGING=yes
    /// они РАСХОДИЛИСЬ: access-лог начинал честно генерить Log.Debug, а логгер их тут
    /// же выбрасывал по MinLevel — работа делалась, строк в файле не появлялось, и
    /// понять почему было невозможно.
    public static bool VerboseEnabled =>
        (Environment.GetEnvironmentVariable("RIMEO_VERBOSE_LOGGING") ?? "")
            .Trim().ToLowerInvariant() is "1" or "true" or "yes" or "on";

    private const string TimeFormat = "yyyy-MM-dd HH:mm:ss";

    private AgentLogger()
    {
        _logPath = AppConfig.Shared.LogFile;

        // Кольцо НЕ засеваем хвостом файла (в отличие от старой версии): читать до 5 МБ
        // на старте незачем, а «что было до рестарта» и так достаёт Tail() прямо из файла.
        OpenWriter();

        _pump = new Thread(Pump)
        {
            IsBackground = true,
            Name = "rimeo.logger",
            Priority = ThreadPriority.BelowNormal,
        };
        _pump.Start();
    }

    // MARK: - Запись

    public void Log(LogLevel level, string msg)
    {
        if (level < MinLevel) return;                  // отсечка ДО форматирования
        var line = $"{DateTime.Now.ToString(TimeFormat)} [{Tag(level)}] {msg}";
        System.Diagnostics.Debug.WriteLine(line);
        try { _queue.Add(new Entry(line, null)); }
        catch (InvalidOperationException) { /* очередь закрыта: агент уже выключается */ }
    }

    public void Info(string msg)    => Log(LogLevel.Info,  msg);
    public void Warning(string msg) => Log(LogLevel.Warn,  msg);
    public void Error(string msg)   => Log(LogLevel.Error, msg);
    public void Debug(string msg)   => Log(LogLevel.Debug, msg);

    private static string Tag(LogLevel l) => l switch
    {
        LogLevel.Debug => "DEBUG",
        LogLevel.Info  => "INFO",
        LogLevel.Warn  => "WARN",
        _              => "ERROR",
    };

    private void Pump()
    {
        foreach (var entry in _queue.GetConsumingEnumerable())
        {
            if (entry.Line is { } line)
            {
                lock (_ringLock)
                {
                    _ring.Enqueue(line);
                    while (_ring.Count > RingCap) _ring.Dequeue();
                }
                Append(line);
            }
            entry.Done?.Set();                         // сигнал дренажа для MarkCleanExit
        }
    }

    /// ⚠️ Вызывается ТОЛЬКО с потока-писателя. Внутри нельзя звать Log() — это
    /// рекурсия и вечное самозацикливание очереди. Все ошибки уходят в Debug/stderr.
    private void Append(string line)
    {
        try
        {
            if (_writer == null) OpenWriter();
            if (_writer == null) return;

            _writer.Write(line);
            _writer.Write('\n');                       // \n, а не \r\n: байты обязаны совпадать с macOS-логом
            _fileBytes += Encoding.UTF8.GetByteCount(line) + 1;
            RotateIfNeeded();
        }
        catch (Exception ex)
        {
            Console.Error.WriteLine($"rimeo-logger: append failed: {ex.Message}");
            CloseWriter();                             // handle протух (диск отвалился / файл удалён) — переоткроем на след. строке
        }
    }

    private void OpenWriter()
    {
        try
        {
            Directory.CreateDirectory(Path.GetDirectoryName(_logPath)!);
            // FileShare.ReadWrite | Delete — обязательно на Windows: без Delete
            // внешний tail/Notepad, открывший файл, заблокировал бы нашу ротацию
            // (в POSIX rename поверх открытого fd проходит всегда, тут — нет).
            var fs = new FileStream(_logPath, FileMode.Append, FileAccess.Write,
                                    FileShare.ReadWrite | FileShare.Delete);
            _fileBytes = fs.Length;
            _writer = new StreamWriter(fs, new UTF8Encoding(encoderShouldEmitUTF8Identifier: false))
            {
                AutoFlush = true,                      // строка должна лежать на диске ДО падения агента
            };
        }
        catch (Exception ex)
        {
            Console.Error.WriteLine($"rimeo-logger: open {_logPath} failed: {ex.Message}");
            _writer = null;
        }
    }

    private void CloseWriter()
    {
        try { _writer?.Dispose(); } catch { }
        _writer = null;
    }

    private void RotateIfNeeded()
    {
        if (_fileBytes < MaxBytes) return;
        CloseWriter();

        var b = _logPath;
        // agent.log.2 (самый старый) выбрасываем, остальные сдвигаем вниз.
        try { File.Delete($"{b}.{Generations - 1}"); } catch { }
        for (var gen = Generations - 1; gen >= 1; gen--)
        {
            var from = gen == 1 ? b : $"{b}.{gen - 1}";
            var to   = $"{b}.{gen}";
            if (!File.Exists(from)) continue;
            try
            {
                // overwrite: true — на Windows File.Move без него падает, если цель
                // существует (POSIX rename молча перетирает). Цели тут быть не должно,
                // но если прошлая ротация оборвалась на полпути — не встаём колом.
                File.Move(from, to, overwrite: true);
            }
            catch (Exception ex)
            {
                Console.Error.WriteLine($"rimeo-logger: rotate {from} -> {to} failed: {ex.Message}");
            }
        }

        OpenWriter();                                   // FileMode.Append сам создаст новый agent.log
        _fileBytes = 0;
        if (_writer == null) return;
        var head = $"{DateTime.Now.ToString(TimeFormat)} [INFO] [ROTATE] предыдущий файл → agent.log.1";
        try
        {
            _writer.Write(head);
            _writer.Write('\n');
            _fileBytes += Encoding.UTF8.GetByteCount(head) + 1;
        }
        catch { }
    }

    // MARK: - Чтение

    /// Хвост из памяти — дёшево, для UI и «Report a problem».
    public string LastLines(int n)
    {
        lock (_ringLock)
        {
            return string.Join("\n", _ring.Skip(Math.Max(0, _ring.Count - n)));
        }
    }

    /// Хвост ФАЙЛА по байтам (переживает рестарт, в отличие от кольца) — именно он
    /// уезжает в диагностический бандл «Report a problem».
    /// Читается seek'ом с конца — файл целиком в RAM не поднимается. Собственный
    /// handle, никаких блокировок: с потоком-писателем и ротацией не пересекается.
    public string Tail(int bytes)
    {
        try
        {
            // FileShare.ReadWrite | Delete — читаем файл, который прямо сейчас пишет
            // наш же StreamWriter и который ротация может переименовать под нами.
            // Без Delete ротация получила бы sharing violation.
            using var fs = new FileStream(_logPath, FileMode.Open, FileAccess.Read,
                                          FileShare.ReadWrite | FileShare.Delete);
            var size = fs.Length;
            var from = Math.Max(0, size - bytes);
            fs.Seek(from, SeekOrigin.Begin);

            var buf = new byte[size - from];
            var read = 0;
            while (read < buf.Length)
            {
                var n = fs.Read(buf, read, buf.Length - read);
                if (n <= 0) break;
                read += n;
            }
            var text = Encoding.UTF8.GetString(buf, 0, read);

            // Срез мог попасть в середину строки (и даже в середину UTF-8-последовательности) —
            // выбрасываем огрызок вместе с его «крякозябрами».
            if (from > 0)
            {
                var nl = text.IndexOf('\n');
                text = nl >= 0 ? text[(nl + 1)..] : "";
            }
            return text;
        }
        catch
        {
            return "";
        }
    }

    // MARK: - Жизненный цикл (видимость рестартов)

    /// Состояние прошлого запуска. На macOS живёт в UserDefaults; на Windows у консольно-
    /// WinUI-процесса такого хранилища нет (а реестр ради четырёх полей — перебор),
    /// поэтому кладём маленький JSON рядом с логом.
    private sealed class RunState
    {
        [JsonPropertyName("pid")]        public int    Pid       { get; set; }
        [JsonPropertyName("started_at")] public string StartedAt { get; set; } = "";
        [JsonPropertyName("last_seen")]  public string LastSeen  { get; set; } = "";
        [JsonPropertyName("clean")]      public bool   Clean     { get; set; }
    }

    private string RunStatePath => Path.Combine(AppConfig.Shared.BaseDir, "run_state.json");
    private Timer? _heartbeat;
    private readonly object _stateLock = new();

    private RunState? ReadRunState()
    {
        try
        {
            if (!File.Exists(RunStatePath)) return null;
            return JsonSerializer.Deserialize<RunState>(File.ReadAllText(RunStatePath));
        }
        catch { return null; }   // битый/полузаписанный файл стоит ровно одну диагностическую строку — не падаем из-за него
    }

    private void WriteRunState(RunState s)
    {
        lock (_stateLock)
        {
            try
            {
                var tmp = RunStatePath + ".tmp";
                File.WriteAllText(tmp, JsonSerializer.Serialize(s));
                File.Move(tmp, RunStatePath, overwrite: true);
            }
            catch (Exception ex)
            {
                Console.Error.WriteLine($"rimeo-logger: run_state write failed: {ex.Message}");
            }
        }
    }

    /// Пишет строку старта — с данными о ПРЕДЫДУЩЕМ запуске. Именно она отвечает на
    /// «агент падал или его перезапустили руками»: exit=unclean = MarkCleanExit() не
    /// звался, то есть процесс убит/упал (или его снёс апдейтер).
    public void Boot()
    {
        var prev = "prev=(нет данных)";
        var old = ReadRunState();
        if (old != null && DateTime.TryParse(old.StartedAt, out var started))
        {
            var seen = DateTime.TryParse(old.LastSeen, out var s) ? s : started;
            var up = Math.Max(0, (int)(seen - started).TotalSeconds);
            prev = $"prev=(pid={old.Pid} started={started.ToString(TimeFormat)} "
                 + $"uptime={up / 3600}h{(up % 3600) / 60}m last_seen={seen.ToString(TimeFormat)} "
                 + $"exit={(old.Clean ? "clean" : "unclean")})";
        }

        var pid = Environment.ProcessId;
        var now = DateTime.Now;
        WriteRunState(new RunState
        {
            Pid       = pid,
            StartedAt = now.ToString("o"),
            LastSeen  = now.ToString("o"),
            Clean     = false,
        });

        var cfg = AppConfig.Shared;
        Info($"[BOOT] ===== AGENT START pid={pid} build={cfg.BuildNumber} port={AppConfig.Port} "
           + $"log_max=5MB gens={Generations} {prev} =====");

        // last_seen раз в минуту → uptime упавшего процесса восстановим с точностью ~1 мин.
        _heartbeat = new Timer(_ =>
        {
            var st = ReadRunState();
            if (st == null || st.Pid != Environment.ProcessId) return;   // файл перехватил другой инстанс — не затираем его отметки
            st.LastSeen = DateTime.Now.ToString("o");
            WriteRunState(st);
        }, null, TimeSpan.FromMinutes(1), TimeSpan.FromMinutes(1));
    }

    /// Зовётся при закрытии приложения — помечает выход как штатный.
    public void MarkCleanExit()
    {
        _heartbeat?.Dispose();
        _heartbeat = null;

        var st = ReadRunState() ?? new RunState { Pid = Environment.ProcessId, StartedAt = DateTime.Now.ToString("o") };
        st.LastSeen = DateTime.Now.ToString("o");
        st.Clean    = true;
        WriteRunState(st);

        Info($"[BOOT] ===== AGENT STOP pid={Environment.ProcessId} (clean) =====");

        // Дождаться слива очереди — иначе строка не долетит до диска (поток-писатель
        // фоновый, рантайм убьёт его вместе с процессом). Таймаут: залипший диск не
        // имеет права вешать выключение агента.
        try
        {
            using var done = new ManualResetEventSlim(false);
            _queue.Add(new Entry(null, done));
            done.Wait(TimeSpan.FromSeconds(2));
        }
        catch { }
    }

    /// <summary>
    /// Dumps host/runtime context at startup. Helps tell apart a missing Windows App
    /// Runtime (self-contained issue) from a Defender-kill or a UI-thread crash when
    /// diagnosing the early native exit (ClickUp 4003).
    /// </summary>
    public void LogStartupDiagnostics()
    {
        try
        {
            var exePath = Environment.ProcessPath ?? AppContext.BaseDirectory;
            var baseDir = AppContext.BaseDirectory;
            // Self-contained WindowsAppSDK ships this bootstrap dll next to the exe.
            var bootstrap = Path.Combine(baseDir, "Microsoft.WindowsAppRuntime.Bootstrap.dll");
            Info($"[diag] exe={exePath}");
            Info($"[diag] baseDir={baseDir}");
            Info($"[diag] cwd={Environment.CurrentDirectory}");
            Info($"[diag] .NET={Environment.Version}, OS={Environment.OSVersion}, 64bit={Environment.Is64BitProcess}");
            Info($"[diag] WindowsAppRuntime bootstrap present={File.Exists(bootstrap)}");
            Info($"[diag] log={AppConfig.Shared.LogFile} level={MinLevel}");
        }
        catch (Exception ex)
        {
            Error($"[diag] startup diagnostics failed: {ex.Message}");
        }
    }
}

public static class Log
{
    public static void Info(string msg)    => AgentLogger.Shared.Info(msg);
    public static void Warn(string msg)    => AgentLogger.Shared.Warning(msg);
    public static void Error(string msg)   => AgentLogger.Shared.Error(msg);
    public static void Debug(string msg)   => AgentLogger.Shared.Debug(msg);
}
