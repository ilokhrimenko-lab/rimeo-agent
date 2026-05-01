using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using RimeoAgent.Config;
using RimeoAgent.Services;
using RimeoAgent.Views;
using System.Runtime.InteropServices;

namespace RimeoAgent;

public sealed partial class MainWindow : Window
{
    private const int SwRestore = 9;
    private const int GwlStyle = -16;
    private const int GwlExStyle = -20;
    private const uint MbOk = 0x00000000;

    private readonly NavigationView _navView;
    private readonly Frame _contentFrame;
    private bool _defaultPageRequested;
    private bool _navigatingProgrammatically;

    public MainWindow()
    {
        // Comfortable startup size
        ConfigurePresenter();
        AppWindow.MoveAndResize(new Windows.Graphics.RectInt32(80, 80, 900, 680));
        AppWindow.SetIcon("Assets/rimeo.ico");
        Title = $"Rimeo Agent — {AppConfig.Shared.DisplayVersion}";

        // Provide DispatcherQueue to AppState
        AppState.Shared.SetDispatcherQueue(Microsoft.UI.Dispatching.DispatcherQueue.GetForCurrentThread());

        _contentFrame = new Frame
        {
            Content = CreateStatusView("Rimeo Agent is starting...")
        };

        _navView = new NavigationView
        {
            IsBackButtonVisible = NavigationViewBackButtonVisible.Collapsed,
            PaneDisplayMode = NavigationViewPaneDisplayMode.Left,
            IsPaneToggleButtonVisible = true,
            OpenPaneLength = 200,
            Content = _contentFrame
        };
        _navView.MenuItems.Add(CreateNavItem("Library", "Library"));
        _navView.MenuItems.Add(CreateNavItem("Analysis", "Analysis"));
        _navView.MenuItems.Add(CreateNavItem("Pairing", "Pairing"));
        _navView.MenuItems.Add(CreateNavItem("Account", "Account"));
        _navView.MenuItems.Add(CreateNavItem("Logs", "Logs"));
        _navView.FooterMenuItems.Add(CreateNavItem("Quit", "Quit"));
        _navView.SelectionChanged += NavView_SelectionChanged;

        Content = _navView;
    }

    private void NavView_SelectionChanged(NavigationView sender, NavigationViewSelectionChangedEventArgs args)
    {
        if (args.IsSettingsSelected) return;

        if (_navigatingProgrammatically) return;

        var tag = (args.SelectedItem as NavigationViewItem)?.Tag?.ToString();
        switch (tag)
        {
            case "Library":  NavigateSafely(typeof(LibraryPage), "Library");   break;
            case "Analysis": NavigateSafely(typeof(AnalysisPage), "Analysis"); break;
            case "Pairing":  NavigateSafely(typeof(PairingPage), "Pairing");   break;
            case "Account":  NavigateSafely(typeof(AccountPage), "Account");   break;
            case "Logs":     NavigateSafely(typeof(LogsPage), "Logs");         break;
            case "Quit":
                ((App)Application.Current).TrayQuit_Click(sender, new RoutedEventArgs());
                break;
        }
    }

    public void NavigateToDefaultPage()
    {
        if (_defaultPageRequested) return;
        _defaultPageRequested = true;

        var libraryItem = _navView.MenuItems.OfType<NavigationViewItem>()
            .FirstOrDefault(item => item.Tag?.ToString() == "Library");
        if (libraryItem != null)
        {
            _navigatingProgrammatically = true;
            try { _navView.SelectedItem = libraryItem; }
            finally { _navigatingProgrammatically = false; }
        }
        NavigateSafely(typeof(LibraryPage), "Library");
    }

    public void ShowAndFocus()
    {
        ConfigurePresenter();
        AppWindow.MoveAndResize(new Windows.Graphics.RectInt32(80, 80, 900, 680));
        AppWindow.Show();
        Activate();

        var hwnd = WinRT.Interop.WindowNative.GetWindowHandle(this);
        Log.Info($"Main window HWND: 0x{hwnd.ToInt64():X}");
        if (hwnd != IntPtr.Zero)
        {
            LogWindowDiagnostics(hwnd, "before restore");
            var showResult = ShowWindow(hwnd, SwRestore);
            var foregroundResult = SetForegroundWindow(hwnd);
            Log.Info($"ShowWindow(SW_RESTORE) result: {showResult}");
            Log.Info($"SetForegroundWindow result: {foregroundResult}");
            LogWindowDiagnostics(hwnd, "after restore");
            Log.Info("Showing temporary debug MessageBoxW");
            MessageBox(hwnd, "Rimeo Agent window startup reached", "Rimeo Agent Debug", MbOk);
        }
    }

    private static NavigationViewItem CreateNavItem(string content, string tag) =>
        new() { Content = content, Tag = tag };

    private void NavigateSafely(Type pageType, string pageName)
    {
        try
        {
            Log.Info($"Navigating to {pageName}");
            _contentFrame.Navigate(pageType);
        }
        catch (Exception ex)
        {
            Log.Error($"Navigation failed: {pageName}: {ex}");
            _contentFrame.Content = CreateStatusView($"{pageName} failed to load.\n\n{ex.Message}");
        }
    }

    private static Grid CreateStatusView(string message)
    {
        var text = new TextBlock
        {
            Text = message,
            FontSize = 18,
            TextWrapping = TextWrapping.Wrap,
            Foreground = new SolidColorBrush(Microsoft.UI.Colors.Gray),
            Margin = new Thickness(24)
        };

        return new Grid
        {
            Children = { text }
        };
    }

    private void ConfigurePresenter()
    {
        if (AppWindow.Presenter is OverlappedPresenter presenter)
        {
            presenter.IsMinimizable = true;
            presenter.IsMaximizable = true;
            presenter.IsResizable = true;
            presenter.Restore();
        }
    }

    private static void LogWindowDiagnostics(IntPtr hwnd, string phase)
    {
        var isWindow = IsWindow(hwnd);
        var isVisible = IsWindowVisible(hwnd);
        var rectOk = GetWindowRect(hwnd, out var rect);
        var style = GetWindowLongPtr(hwnd, GwlStyle);
        var exStyle = GetWindowLongPtr(hwnd, GwlExStyle);
        Log.Info(
            $"Window diagnostics ({phase}): is_window={isWindow}, visible={isVisible}, " +
            $"rect_ok={rectOk}, rect=({rect.Left},{rect.Top},{rect.Right},{rect.Bottom}), " +
            $"style=0x{style.ToInt64():X}, exstyle=0x{exStyle.ToInt64():X}, " +
            $"pid={Environment.ProcessId}, session={System.Diagnostics.Process.GetCurrentProcess().SessionId}");
    }

    [DllImport("user32.dll")]
    private static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);

    [DllImport("user32.dll")]
    private static extern bool SetForegroundWindow(IntPtr hWnd);

    [DllImport("user32.dll")]
    private static extern bool IsWindow(IntPtr hWnd);

    [DllImport("user32.dll")]
    private static extern bool IsWindowVisible(IntPtr hWnd);

    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool GetWindowRect(IntPtr hWnd, out WindowRect lpRect);

    [DllImport("user32.dll", EntryPoint = "GetWindowLongPtrW", SetLastError = true)]
    private static extern IntPtr GetWindowLongPtr(IntPtr hWnd, int nIndex);

    [DllImport("user32.dll", EntryPoint = "MessageBoxW", CharSet = CharSet.Unicode)]
    private static extern int MessageBox(IntPtr hWnd, string text, string caption, uint type);

    [StructLayout(LayoutKind.Sequential)]
    private struct WindowRect
    {
        public int Left;
        public int Top;
        public int Right;
        public int Bottom;
    }
}
