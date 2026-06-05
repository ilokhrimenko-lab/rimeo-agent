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
    private readonly NavigationView _navView;
    private readonly Frame _contentFrame;
    private bool _defaultPageRequested;
    private bool _navigatingProgrammatically;
    private bool _didInitialSetup;

    /// <summary>HWND of the main window — used by pages to host file pickers.</summary>
    internal static IntPtr Hwnd { get; private set; }

    public MainWindow()
    {
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
        // Mirror the macOS rail: Library / Pairing / Account / Settings (no Analysis).
        _navView.MenuItems.Add(CreateNavItem("Library", "Library"));
        _navView.MenuItems.Add(CreateNavItem("Pairing", "Pairing"));
        _navView.MenuItems.Add(CreateNavItem("Account", "Account"));
        _navView.MenuItems.Add(CreateNavItem("Settings", "Logs"));
        _navView.IsSettingsVisible = false;   // hide the built-in gear (we have our own Settings)
        _navView.SelectionChanged += NavView_SelectionChanged;
        _navView.RequestedTheme = ElementTheme.Dark;
        _navView.Background = UI.Bg;

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
            case "Pairing":  NavigateSafely(typeof(PairingPage), "Pairing");   break;
            case "Account":  NavigateSafely(typeof(AccountPage), "Account");   break;
            case "Logs":     NavigateSafely(typeof(LogsPage), "Logs");         break;
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
            catch (Exception ex) { Log.Error($"Selecting default nav item failed: {ex}"); }
            finally { _navigatingProgrammatically = false; }
        }
        NavigateSafely(typeof(LibraryPage), "Library");
    }

    public void ShowAndFocus()
    {
        AppWindow.Show();  // restore if the window was hidden to the tray

        if (!_didInitialSetup)
        {
            _didInitialSetup = true;
            Title = $"Rimeo Agent — {AppConfig.Shared.DisplayVersion}";
            AppWindow.SetIcon("Assets/rimeo.ico");

            if (AppWindow.Presenter is OverlappedPresenter presenter)
            {
                presenter.IsMinimizable = true;
                presenter.IsMaximizable = true;
                presenter.IsResizable = true;
            }

            // Open at a comfortable size, centred on the work area (first launch).
            const int targetW = 1280, targetH = 860;
            var area = Microsoft.UI.Windowing.DisplayArea.GetFromWindowId(
                AppWindow.Id, Microsoft.UI.Windowing.DisplayAreaFallback.Primary);
            var work = area.WorkArea;
            int w = Math.Min(targetW, work.Width  - 40);
            int h = Math.Min(targetH, work.Height - 40);
            int x = work.X + (work.Width  - w) / 2;
            int y = work.Y + (work.Height - h) / 2;
            AppWindow.MoveAndResize(new Windows.Graphics.RectInt32(x, y, w, h));
            AppWindow.Closing += OnAppWindowClosing;
        }

        Activate();

        var hwnd = WinRT.Interop.WindowNative.GetWindowHandle(this);
        Hwnd = hwnd;
        Log.Info($"Main window HWND: 0x{hwnd.ToInt64():X}");
        if (hwnd != IntPtr.Zero)
            SetForegroundWindow(hwnd);
    }

    // Closing the window hides it to the system tray instead of quitting — the agent
    // keeps serving in the background. Real quit is via the tray context menu.
    private void OnAppWindowClosing(Microsoft.UI.Windowing.AppWindow sender, Microsoft.UI.Windowing.AppWindowClosingEventArgs args)
    {
        args.Cancel = true;
        AppWindow.Hide();
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

    [DllImport("user32.dll")]
    private static extern bool SetForegroundWindow(IntPtr hWnd);
}
