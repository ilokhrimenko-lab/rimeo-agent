using Microsoft.UI.Xaml;
using RimeoAgent.Config;
using RimeoAgent.HttpServer;
using RimeoAgent.Services;

namespace RimeoAgent;

public partial class App : Application
{
    private const string SingleInstanceMutexName = "Local\\RimeoAgent.Windows.SingleInstance";

    private MainWindow?      _window;
    private AgentHttpServer? _server;
    private Mutex?           _singleInstanceMutex;
    private bool            _backgroundStarted;

    public App()
    {
        AppDomain.CurrentDomain.UnhandledException += (_, e) =>
            Log.Error($"Unhandled exception: {e.ExceptionObject}");
        TaskScheduler.UnobservedTaskException += (_, e) =>
        {
            Log.Error($"Unobserved task exception: {e.Exception}");
            e.SetObserved();
        };
        UnhandledException += (_, e) =>
            Log.Error($"Application unhandled exception: {e.Exception}");

        InitializeComponent();
    }

    protected override void OnLaunched(LaunchActivatedEventArgs args)
    {
        Log.Info($"Rimeo Agent starting — {AppConfig.Shared.DisplayVersion}");
        AgentLogger.Shared.LogStartupDiagnostics();

        _singleInstanceMutex = new Mutex(initiallyOwned: true, SingleInstanceMutexName, out var isFirstInstance);
        if (!isFirstInstance)
        {
            Log.Warn("Another Rimeo Agent instance is already running");
            Environment.Exit(0);
            return;
        }

        // Bring up the window FIRST and let it become stable before touching any
        // heavy background work. Spinning up the HTTP server, the 62 MB component
        // download (Defender risk), the cloudflared subprocess and the relay
        // long-poll on the launch path was a likely cause of the early native crash.
        try
        {
            Log.Info("Creating main window shell");
            _window = new MainWindow();
            Log.Info("Main window shell created");

            // Defer background services until the window has actually been activated
            // (first render done) so the UI thread is stable when they start.
            _window.Activated += OnWindowFirstActivated;

            Log.Info("Activating main window");
            _window.ShowAndFocus();
            _window.NavigateToDefaultPage();

            Log.Info("Rimeo Agent started");
        }
        catch (Exception ex)
        {
            Log.Error($"Main window startup failed: {ex}");
            throw;
        }
    }

    private void OnWindowFirstActivated(object sender, WindowActivatedEventArgs args)
    {
        if (_backgroundStarted) return;
        _backgroundStarted = true;
        if (_window != null) _window.Activated -= OnWindowFirstActivated;

        // Give the first frame a moment, then start services off the launch path.
        _window?.DispatcherQueue.TryEnqueue(StartBackgroundServices);
    }

    private void StartBackgroundServices()
    {
        Log.Info("Starting background services");

        SafeStart("HTTP server", () =>
        {
            _server = new AgentHttpServer();
            _server.Start();
        });

        // Ensure ffmpeg, ffprobe, cloudflared are present (bundled or downloaded)
        SafeStart("component manager", () =>
            _ = ComponentManager.Shared.EnsureAllAsync(msg => Log.Info($"[components] {msg}")));

        SafeStart("cloud relay", () => CloudRelay.Shared.StartIfLinked());

        SafeStart("tunnel", () => TunnelManager.Shared.AutoStartIfAvailable());

        SafeStart("update check", () => UpdateChecker.Shared.CheckAsync(info =>
        {
            if (info != null) Log.Info($"Update available: {info.Version}");
        }));

        Log.Info("Background services started");
    }

    private static void SafeStart(string name, Action start)
    {
        try { start(); }
        catch (Exception ex) { Log.Error($"Background service '{name}' failed to start: {ex}"); }
    }

    private void ShowWindow()
    {
        _window ??= new MainWindow();
        _window.ShowAndFocus();
        _window.NavigateToDefaultPage();
    }

    internal void TrayOpen_Click(object sender, RoutedEventArgs e) => ShowWindow();

    internal void TrayQuit_Click(object sender, RoutedEventArgs e) => Quit();

    private void Quit()
    {
        Log.Info("Rimeo Agent shutting down");
        _server?.Stop();
        TunnelManager.Shared.Stop();
        CloudRelay.Shared.Stop();
        _singleInstanceMutex?.ReleaseMutex();
        _singleInstanceMutex?.Dispose();
        Environment.Exit(0);
    }
}
