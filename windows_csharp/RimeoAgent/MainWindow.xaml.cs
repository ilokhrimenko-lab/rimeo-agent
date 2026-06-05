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
        _navView.FooterMenuItems.Add(CreateNavItem("Quit", "Quit"));
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
            catch (Exception ex) { Log.Error($"Selecting default nav item failed: {ex}"); }
            finally { _navigatingProgrammatically = false; }
        }
        NavigateSafely(typeof(LibraryPage), "Library");
    }

    public void ShowAndFocus()
    {
        Title = $"Rimeo Agent — {AppConfig.Shared.DisplayVersion}";
        AppWindow.SetIcon("Assets/rimeo.ico");

        if (AppWindow.Presenter is OverlappedPresenter presenter)
        {
            presenter.IsMinimizable = true;
            presenter.IsMaximizable = true;
            presenter.IsResizable = true;
        }

        AppWindow.MoveAndResize(new Windows.Graphics.RectInt32(80, 80, 900, 680));
        Activate();

        var hwnd = WinRT.Interop.WindowNative.GetWindowHandle(this);
        Hwnd = hwnd;
        Log.Info($"Main window HWND: 0x{hwnd.ToInt64():X}");
        if (hwnd != IntPtr.Zero)
            SetForegroundWindow(hwnd);
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
