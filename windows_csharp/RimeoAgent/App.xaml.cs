using H.NotifyIcon;
using Microsoft.UI.Xaml;
using RimeoAgent.Config;
using RimeoAgent.HttpServer;
using RimeoAgent.Services;

namespace RimeoAgent;

public partial class App : Application
{
    private MainWindow?      _window;
    private AgentHttpServer? _server;
    private TaskbarIcon?     _trayIcon;

    public App()
    {
        InitializeComponent();
    }

    protected override void OnLaunched(LaunchActivatedEventArgs args)
    {
        Log.Info($"Rimeo Agent starting — {AppConfig.Shared.DisplayVersion}");

        // Start HTTP server
        _server = new AgentHttpServer();
        _server.Start();

        // Start cloud relay if linked
        CloudRelay.Shared.StartIfLinked();

        // Auto-start tunnel
        TunnelManager.Shared.AutoStartIfAvailable();

        // Check for updates (background)
        UpdateChecker.Shared.CheckAsync(info =>
        {
            if (info != null) Log.Info($"Update available: {info.Version}");
        });

        // Create main window
        _window = new MainWindow();

        // Set up tray icon
        _trayIcon = (TaskbarIcon)Resources["TrayIcon"];
        _trayIcon.ForceCreate();

        // Attach tray click → show window
        _trayIcon.TrayMouseDoubleClick += (_, _) => ShowWindow();

        _window.Activate();

        Log.Info("Rimeo Agent started");
    }

    private void ShowWindow()
    {
        _window ??= new MainWindow();
        _window.Show();
        _window.Activate();
    }

    internal void TrayOpen_Click(object sender, RoutedEventArgs e) => ShowWindow();

    internal void TrayQuit_Click(object sender, RoutedEventArgs e)
    {
        Log.Info("Rimeo Agent shutting down");
        _server?.Stop();
        TunnelManager.Shared.Stop();
        CloudRelay.Shared.Stop();
        _trayIcon?.Dispose();
        Environment.Exit(0);
    }
}
