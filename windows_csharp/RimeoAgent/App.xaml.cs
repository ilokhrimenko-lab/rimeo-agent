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

        _singleInstanceMutex = new Mutex(initiallyOwned: true, SingleInstanceMutexName, out var isFirstInstance);
        if (!isFirstInstance)
        {
            Log.Warn("Another Rimeo Agent instance is already running");
            Environment.Exit(0);
            return;
        }

        // Start HTTP server
        _server = new AgentHttpServer();
        _server.Start();

        // Ensure ffmpeg, ffprobe, cloudflared are downloaded
        _ = ComponentManager.Shared.EnsureAllAsync(msg => Log.Info($"[components] {msg}"));

        // Start cloud relay if linked
        CloudRelay.Shared.StartIfLinked();

        // Auto-start tunnel
        TunnelManager.Shared.AutoStartIfAvailable();

        // Check for updates (background)
        UpdateChecker.Shared.CheckAsync(info =>
        {
            if (info != null) Log.Info($"Update available: {info.Version}");
        });

        try
        {
            Log.Info("Creating main window shell");
            _window = new MainWindow();
            Log.Info("Main window shell created");

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
