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
}

public static class Log
{
    public static void Info(string msg)    => AgentLogger.Shared.Info(msg);
    public static void Warn(string msg)    => AgentLogger.Shared.Warning(msg);
    public static void Error(string msg)   => AgentLogger.Shared.Error(msg);
    public static void Debug(string msg)   => AgentLogger.Shared.Debug(msg);
}
