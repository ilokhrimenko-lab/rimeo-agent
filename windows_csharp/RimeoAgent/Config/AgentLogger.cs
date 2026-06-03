namespace RimeoAgent.Config;

public sealed class AgentLogger
{
    public static readonly AgentLogger Shared = new();

    private readonly object _lock = new();
    private readonly Queue<string> _buffer = new();
    private const int BufferSize = 500;
    private StreamWriter? _writer;

    private AgentLogger()
    {
        try
        {
            _writer = new StreamWriter(AppConfig.Shared.LogFile, append: true, System.Text.Encoding.UTF8)
            {
                AutoFlush = true
            };
        }
        catch { }
    }

    public void Info(string msg)    => Write("INFO ", msg);
    public void Warning(string msg) => Write("WARN ", msg);
    public void Error(string msg)   => Write("ERROR", msg);
    public void Debug(string msg)   => Write("DEBUG", msg);

    private void Write(string level, string msg)
    {
        var line = $"{DateTime.Now:yyyy-MM-dd HH:mm:ss} [{level}] {msg}";
        lock (_lock)
        {
            _buffer.Enqueue(line);
            while (_buffer.Count > BufferSize) _buffer.Dequeue();
            try { _writer?.WriteLine(line); }
            catch { }
        }
        System.Diagnostics.Debug.WriteLine(line);
    }

    public string LastLines(int n)
    {
        lock (_lock)
        {
            var lines = _buffer.TakeLast(n);
            return string.Join("\n", lines);
        }
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
            Info($"[diag] log={AppConfig.Shared.LogFile}");
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
