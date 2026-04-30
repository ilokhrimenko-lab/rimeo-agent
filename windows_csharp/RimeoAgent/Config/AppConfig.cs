using System.Net.Sockets;
using System.Text.RegularExpressions;

namespace RimeoAgent.Config;

public sealed class AppConfig
{
    public static readonly AppConfig Shared = new();

    public const string AppName = "Rimeo Desktop Agent";
    public const string RimeoAppUrl = "https://rimeo.app";
    public const string GithubRepo  = "ilokhrimenko-lab/rimeo-agent";
    public const int    Port        = 8000;

    public string Version       { get; private set; } = "1.0";
    public string BuildNumber   { get; private set; } = "dev";
    public string ReleaseTag    { get; private set; } = "v1.0-dev";
    public string DisplayVersion { get; private set; } = "1.0";

    public string BaseDir      { get; }
    public string CacheDir     { get; }
    public string DataFile     { get; }
    public string LogFile      { get; }
    public string AnalysisFile { get; }
    public string AgentId      { get; private set; }

    private string _xmlPath = "";
    private string _dbPath  = "";
    private readonly object _lock = new();

    public string XmlPath { get { lock (_lock) return _xmlPath; } }
    public string DbPath  { get { lock (_lock) return _dbPath;  } }

    public bool XmlExists => !string.IsNullOrEmpty(XmlPath) && File.Exists(XmlPath);
    public bool DbExists  => !string.IsNullOrEmpty(DbPath)  && File.Exists(DbPath);
    public bool HasAnyLibrarySource => XmlExists || DbExists;

    private AppConfig()
    {
        var appData = Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData);
        BaseDir      = Path.Combine(appData, "RimeoAgent");
        CacheDir     = Path.Combine(BaseDir, "cache");
        DataFile     = Path.Combine(BaseDir, "rimo_data.json");
        LogFile      = Path.Combine(BaseDir, "agent.log");
        AnalysisFile = Path.Combine(BaseDir, "analysis_data.json");

        Directory.CreateDirectory(BaseDir);
        Directory.CreateDirectory(CacheDir);

        // Persistent agent ID
        var idFile = Path.Combine(BaseDir, "agent_id");
        if (File.Exists(idFile))
        {
            AgentId = File.ReadAllText(idFile).Trim();
            if (string.IsNullOrEmpty(AgentId)) AgentId = GenerateAndSaveId(idFile);
        }
        else
        {
            AgentId = GenerateAndSaveId(idFile);
        }

        LoadBuildInfo();

        // Pioneer rekordbox master.db default path
        _dbPath = DetectDbPath();

        // Load .env for overrides
        var envFile = Path.Combine(BaseDir, ".env");
        if (File.Exists(envFile))
        {
            foreach (var line in File.ReadAllLines(envFile))
            {
                var parts = line.Split('=', 2);
                if (parts.Length < 2) continue;
                var key = parts[0].Trim();
                var val = parts[1].Trim();
                if (key == "RIMEO_XML_PATH") _xmlPath = val;
                else if (key == "RIMEO_DB_PATH" && !string.IsNullOrEmpty(val)) _dbPath = val;
            }
        }
    }

    public void SetXmlPath(string path)
    {
        lock (_lock) { _xmlPath = path; }
        UpdateEnvVar("RIMEO_XML_PATH", path);
    }

    public void SetDbPath(string path)
    {
        lock (_lock) { _dbPath = path; }
        UpdateEnvVar("RIMEO_DB_PATH", path);
    }

    public string GetLocalIp()
    {
        try
        {
            using var socket = new Socket(AddressFamily.InterNetwork, SocketType.Dgram, ProtocolType.Udp);
            socket.Connect("8.8.8.8", 80);
            return (socket.LocalEndPoint as System.Net.IPEndPoint)?.Address.ToString() ?? "127.0.0.1";
        }
        catch
        {
            return "127.0.0.1";
        }
    }

    public string LocalAgentUrl() => $"http://{GetLocalIp()}:{Port}";

    public void ApplyCloudHeaders(HttpRequestMessage req, string? contentType = null)
    {
        if (contentType != null)
            req.Content!.Headers.ContentType = new System.Net.Http.Headers.MediaTypeHeaderValue(contentType);
        req.Headers.TryAddWithoutValidation("User-Agent",
            "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36");
        req.Headers.Accept.ParseAdd("application/json");
    }

    private void LoadBuildInfo()
    {
        var searchDirs = new[]
        {
            AppContext.BaseDirectory,
            Path.GetDirectoryName(AppContext.BaseDirectory) ?? "",
            Path.GetDirectoryName(Environment.ProcessPath ?? "") ?? "",
        };

        foreach (var dir in searchDirs.Where(d => !string.IsNullOrEmpty(d)))
        {
            var candidate = Path.Combine(dir, "build_info.py");
            if (!File.Exists(candidate)) continue;
            var text = File.ReadAllText(candidate);
            Version     = ExtractPyStr(text, "VERSION")     ?? "1.0";
            BuildNumber = ExtractPyStr(text, "BUILD_NUMBER") ?? "dev";
            ReleaseTag  = ExtractPyStr(text, "RELEASE_TAG") ?? "v1.0-dev";
            var b = BuildNumber.Trim();
            DisplayVersion = (string.IsNullOrEmpty(b) || b.ToLower() == "dev")
                ? Version
                : $"{Version} (build {b})";
            return;
        }
    }

    private static string? ExtractPyStr(string text, string key)
    {
        var m = Regex.Match(text, $@"{key}\s*=\s*""([^""]+)""");
        return m.Success ? m.Groups[1].Value : null;
    }

    private static string DetectDbPath()
    {
        var appData = Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData);
        var path = Path.Combine(appData, "Pioneer", "rekordbox", "master.db");
        return File.Exists(path) ? path : "";
    }

    private static string GenerateAndSaveId(string idFile)
    {
        var id = Guid.NewGuid().ToString().ToUpper();
        File.WriteAllText(idFile, id);
        return id;
    }

    private void UpdateEnvVar(string key, string value)
    {
        var envFile = Path.Combine(BaseDir, ".env");
        var lines = File.Exists(envFile)
            ? File.ReadAllLines(envFile).Where(l => !l.TrimStart().StartsWith($"{key}=")).ToList()
            : new List<string>();
        lines.Add($"{key}={value}");
        File.WriteAllLines(envFile, lines);
    }
}
