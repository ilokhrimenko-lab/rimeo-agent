using H.NotifyIcon;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media.Imaging;
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
    private TaskbarIcon?    _trayIcon;

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

        SafeStart("cloud relay", () => CloudRelay.Shared.StartIfLinked());

        SafeStart("cache prune", () => Services.CacheManager.Shared.ScheduleEnforce());

        // Ensure cloudflared/ffmpeg are present, THEN bring up the tunnel and
        // provision the per-user named tunnel — the server only accepts named
        // tunnels for audio streaming (quick trycloudflare tunnels are rejected).
        SafeStart("components + tunnel", () => _ = EnsureComponentsThenTunnel());

        SafeStart("update check", () => UpdateChecker.Shared.CheckAsync(info =>
        {
            if (info != null) Log.Info($"Update available: {info.Version}");
        }));

        SafeStart("system tray", SetupTray);

        Log.Info("Background services started");
    }

    private static async Task EnsureComponentsThenTunnel()
    {
        // First-run download: cloudflared/ffmpeg/ffprobe are no longer bundled in
        // the installer, so they're fetched here on first launch. A transient
        // network failure must NOT leave the agent permanently tunnel-less (and
        // AIFF-silent) until the next restart — retry with backoff until all
        // components are present, then bring the tunnel up.
        int attempt = 0;
        while (true)
        {
            await ComponentManager.Shared.EnsureAllAsync(msg => Log.Info($"[components] {msg}"));
            if (ComponentManager.Shared.AllPresent()) break;

            attempt++;
            int delaySec = Math.Min(300, 15 * attempt); // 15s, 30s, … capped at 5 min
            Log.Warn($"[components] not all present (attempt {attempt}) — retrying in {delaySec}s");
            await Task.Delay(TimeSpan.FromSeconds(delaySec));
        }

        TunnelManager.Shared.AutoStartIfAvailable();
        TunnelProvisioner.Shared.ProvisionIfNeeded();
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

    // System-tray icon: the agent keeps running when the window is closed; the tray
    // icon brings it back (left-click) or quits it (right-click → Quit).
    private void SetupTray()
    {
        if (_trayIcon != null) return;

        var open = new MenuFlyoutItem { Text = "Open Rimeo Agent", Command = new RelayCommand(ShowWindow) };
        var quit = new MenuFlyoutItem { Text = "Quit",            Command = new RelayCommand(Quit) };
        var menu = new MenuFlyout();
        menu.Items.Add(open);
        menu.Items.Add(quit);

        _trayIcon = new TaskbarIcon
        {
            ToolTipText      = "Rimeo Agent",
            IconSource       = new BitmapImage(new Uri("ms-appx:///Assets/rimeo.ico")),
            ContextFlyout    = menu,
            LeftClickCommand = new RelayCommand(ShowWindow),
        };
        _trayIcon.ForceCreate();
        Log.Info("System tray icon created");
    }

    internal void TrayOpen_Click(object sender, RoutedEventArgs e) => ShowWindow();

    internal void TrayQuit_Click(object sender, RoutedEventArgs e) => Quit();

    private void Quit()
    {
        Log.Info("Rimeo Agent shutting down");
        _trayIcon?.Dispose();
        _server?.Stop();
        TunnelManager.Shared.Stop();
        CloudRelay.Shared.Stop();
        _singleInstanceMutex?.ReleaseMutex();
        _singleInstanceMutex?.Dispose();
        Environment.Exit(0);
    }
}

// Minimal ICommand so tray-menu items (which H.NotifyIcon invokes as Commands, not
// Click handlers) can run plain actions.
internal sealed class RelayCommand : System.Windows.Input.ICommand
{
    private readonly Action _execute;
    public RelayCommand(Action execute) => _execute = execute;
    public event EventHandler? CanExecuteChanged;
    public bool CanExecute(object? parameter) => true;
    public void Execute(object? parameter) => _execute();
}
