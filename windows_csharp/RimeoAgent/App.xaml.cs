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
    // Именованное событие, которым второй запуск просит уже работающий (в т.ч.
    // запущенный автостартом и невидимый) экземпляр показать своё окно.
    private const string ShowWindowEventName     = "Local\\RimeoAgent.Windows.ShowWindow";

    private MainWindow?      _window;
    private AgentHttpServer? _server;
    private Mutex?           _singleInstanceMutex;
    private EventWaitHandle? _showWindowEvent;
    private System.Threading.Timer? _updateTimer;
    private bool            _backgroundStarted;
    private TaskbarIcon?    _trayIcon;

    public App()
    {
        // Флаш ПОСЛЕ Log.Error здесь обязателен: рантайм убивает процесс сразу же
        // после AppDomain.UnhandledException (событие уведомительное, предотвратить
        // завершение нельзя), а запись в лог асинхронна — без синхронного слива
        // самая важная строка, причина краша, рисковала не долететь до диска (см.
        // инцидент 16.07: реальный процесс агента исчез без единой строки в логе).
        AppDomain.CurrentDomain.UnhandledException += (_, e) =>
        {
            Log.Error($"Unhandled exception: {e.ExceptionObject}");
            AgentLogger.Shared.Flush(TimeSpan.FromSeconds(2));
        };
        TaskScheduler.UnobservedTaskException += (_, e) =>
        {
            Log.Error($"Unobserved task exception: {e.Exception}");
            e.SetObserved();
        };
        UnhandledException += (_, e) =>
        {
            Log.Error($"Application unhandled exception: {e.Exception}");
            AgentLogger.Shared.Flush(TimeSpan.FromSeconds(2));
        };

        InitializeComponent();
    }

    protected override void OnLaunched(LaunchActivatedEventArgs args)
    {
        // Автозапуск подставляет --background (см. AgentSettings.RunCommand): агент
        // должен подняться в трее, без окна и без кражи фокуса при входе в систему.
        var background = AgentSettings.IsBackgroundCommandLine(Environment.GetCommandLineArgs());
        AgentSettings.LaunchedInBackground = background;

        // [BOOT]-строка с данными о ПРЕДЫДУЩЕМ запуске (pid, uptime, exit=clean|unclean).
        // Именно она отвечает на вопрос «агент упал или его перезапустили руками» —
        // без неё в баг-репорте видно только, что агент стартовал, но не почему.
        // Зовём ДО mutex-проверки: второй инстанс тоже обязан оставить след, иначе
        // «клик по ярлыку ничего не сделал» нечем расследовать.
        AgentLogger.Shared.Boot();
        Log.Info($"Rimeo Agent starting — {AppConfig.Shared.DisplayVersion}{(background ? " (background)" : "")}");
        AgentLogger.Shared.LogStartupDiagnostics();

        _singleInstanceMutex = new Mutex(initiallyOwned: true, SingleInstanceMutexName, out var isFirstInstance);
        if (!isFirstInstance)
        {
            // Раньше второй запуск просто молча умирал. С фоновым автостартом это
            // означало бы «клик по ярлыку ничего не делает» — поэтому будим первый.
            // Не зовём MarkCleanExit()/BeginTracking() — этот процесс ничего не писал
            // в run_state.json (см. AgentLogger.Boot), поэтому и чистить за собой
            // нечего.
            Log.Warn("Another Rimeo Agent instance is already running — asking it to show its window");
            SignalRunningInstance();
            Environment.Exit(0);
            return;
        }

        // Только победитель mutex'а ведёт run_state.json — см. AgentLogger.Boot.
        AgentLogger.Shared.BeginTracking();

        // Silent auto-update: install a build staged (downloaded) in the background
        // during the previous session BEFORE the UI/services come up, then relaunch.
        // ApplyStagedUpdateIfPresent() exits the process on success → launch stops here.
        try { if (UpdateChecker.Shared.ApplyStagedUpdateIfPresent()) return; }
        catch (Exception ex) { Log.Warn($"Staged update apply failed: {ex.Message}"); }

        AgentSettings.EnsureAutostartConfiguredOnce();

        // Bring up the window FIRST and let it become stable before touching any
        // heavy background work. Spinning up the HTTP server, the 62 MB component
        // download (Defender risk), the cloudflared subprocess and the relay
        // long-poll on the launch path was a likely cause of the early native crash.
        try
        {
            Log.Info("Creating main window shell");
            _window = new MainWindow();
            Log.Info("Main window shell created");

            StartShowWindowListener();

            if (background)
            {
                // Окно создано, но НЕ активировано — WinUI показывает окно только по
                // Activate(), так что на экране ничего не появляется. Activated тут не
                // сработает, поэтому сервисы (и трей) поднимаем сами.
                _backgroundStarted = true;
                _window.DispatcherQueue.TryEnqueue(StartBackgroundServices);
                Log.Info("Rimeo Agent started in background (tray only)");
                return;
            }

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

    // Второй экземпляр не может показать окно первого напрямую (разные процессы) —
    // он взводит именованное событие, которое слушает первый.
    private static void SignalRunningInstance()
    {
        try
        {
            if (!EventWaitHandle.TryOpenExisting(ShowWindowEventName, out var ev)) return;
            using (ev) ev.Set();
        }
        catch (Exception ex) { Log.Warn($"Could not signal the running instance: {ex.Message}"); }
    }

    private void StartShowWindowListener()
    {
        try
        {
            _showWindowEvent = new EventWaitHandle(false, EventResetMode.AutoReset, ShowWindowEventName);
            var queue = _window!.DispatcherQueue;
            var thread = new Thread(() =>
            {
                try
                {
                    while (_showWindowEvent!.WaitOne())
                        queue.TryEnqueue(ShowWindow);
                }
                catch (Exception ex) { Log.Warn($"Show-window listener stopped: {ex.Message}"); }
            })
            { IsBackground = true, Name = "RimeoShowWindowListener" };
            thread.Start();
        }
        catch (Exception ex) { Log.Warn($"Show-window listener failed to start: {ex.Message}"); }
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

        // 6004: make sure the LAN PSK exists before the server accepts requests, so
        // the WinUI control calls (127.0.0.1 with ?lan_token=) can authenticate.
        SafeStart("lan secret", () => RimeoAgent.Models.DataStore.Shared.EnsureLanSecret());

        SafeStart("HTTP server", () =>
        {
            _server = new AgentHttpServer();
            _server.Start();
        });

        SafeStart("cloud relay", () => CloudRelay.Shared.StartIfLinked());

        // Веса движка рекомендаций приезжают из админки (GET /api/similarity_config,
        // синк раз в 600 с). Без ЭТОЙ строки метод StartCloudSync существовал, но его
        // никто не звал: агент вечно сидел на встроенных дефолтах, и подкрутка весов в
        // админке до Windows не доезжала вообще — при том что PARITY.md уже утверждал
        // обратное. Классический мёртвый код: скомпилировано, покрыто комментарием,
        // не вызвано.
        SafeStart("similarity config sync", () => SimilarityEngine.Shared.StartCloudSync());

        SafeStart("cache prune", () => Services.CacheManager.Shared.ScheduleEnforce());

        // Ensure cloudflared/ffmpeg are present, THEN bring up the tunnel and
        // provision the per-user named tunnel — the server only accepts named
        // tunnels for audio streaming (quick trycloudflare tunnels are rejected).
        SafeStart("components + tunnel", () => _ = EnsureComponentsThenTunnel());

        // Silent auto-update: check shortly after launch and every hour, downloading
        // any newer build to a staging file in the background. It installs itself on
        // the NEXT launch (ApplyStagedUpdateIfPresent at the top of OnLaunched) —
        // no prompt.
        SafeStart("update check", () =>
        {
            UpdateChecker.Shared.CheckAndStageSilently();
            _updateTimer = new System.Threading.Timer(
                _ => UpdateChecker.Shared.CheckAndStageSilently(),
                null, TimeSpan.FromHours(1), TimeSpan.FromHours(1));
        });

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
        // Помечаем выход ШТАТНЫМ и дожидаемся слива очереди лога. Без этого следующий
        // старт увидит exit=unclean и будет врать, что агент падал, — а падение и
        // «пользователь вышел через трей» надо различать. Строго ПЕРЕД Exit(0):
        // после него дописать в лог уже некому.
        AgentLogger.Shared.MarkCleanExit();
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
