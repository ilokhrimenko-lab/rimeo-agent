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
    private NavigationView _navView = null!;
    private Frame _contentFrame = null!;
    private bool _defaultPageRequested;
    private bool _navigatingProgrammatically;
    private bool _didInitialSetup;
    private bool _inGate;
    private string _currentTag = "Library";

    /// <summary>HWND of the main window — used by pages to host file pickers.</summary>
    internal static IntPtr Hwnd { get; private set; }

    /// <summary>Current window — used by pages to apply a theme change app-wide.</summary>
    internal static MainWindow? Instance { get; private set; }

    public MainWindow()
    {
        Instance = this;
        AppState.Shared.SetDispatcherQueue(Microsoft.UI.Dispatching.DispatcherQueue.GetForCurrentThread());
        UI.IsDark = ResolveDark(ThemeManager.CurrentElementTheme);

        // Until the agent is linked to a Rimeo account, show the Link-device gate
        // (custom titlebar + pairing-code entry); otherwise go straight to the shell.
        if (AppState.Shared.CloudLinked) BuildShell();
        else ShowLinkGate();
    }

    // ── Link-device gate ──────────────────────────────────────────────────────
    private void ShowLinkGate()
    {
        _inGate = true;
        var gate = new LinkDevicePage(onLinked: ExitLinkGate);
        try
        {
            ExtendsContentIntoTitleBar = true;
            Content = gate;
            SetTitleBar(gate.TitleBarDragRegion);
            // The gate draws its own min/max/close buttons (LinkDevicePage.BuildTitlebar).
            // ExtendsContentIntoTitleBar keeps the framework's system caption buttons on
            // top of them → two sets of buttons. Drop the system title bar (removes those
            // caption buttons) while keeping the resize border. SetTitleBar drag rectangles
            // are AppWindow-level and survive hasTitleBar:false, so the brand lane stays
            // draggable. Must run AFTER SetTitleBar so it isn't re-overridden.
            (AppWindow.Presenter as OverlappedPresenter)?.SetBorderAndTitleBar(true, false);
        }
        catch (Exception ex)
        {
            Log.Error($"Link gate setup failed: {ex}");
            ExtendsContentIntoTitleBar = false;
            Content = gate;
        }
    }

    // Called after a successful link: drop the custom chrome and bring up the shell.
    private void ExitLinkGate()
    {
        DispatcherQueue.TryEnqueue(() =>
        {
            _inGate = false;
            try
            {
                // Restore the standard system title bar (border + title bar + default
                // caption buttons) for the shell, then stop extending content into it.
                (AppWindow.Presenter as OverlappedPresenter)?.SetBorderAndTitleBar(true, true);
                ExtendsContentIntoTitleBar = false;
            }
            catch (Exception ex) { Log.Error($"Title bar reset failed: {ex}"); }
            _defaultPageRequested = false;
            BuildShell();
            SelectNav("Library");
            NavigateSafely(typeof(LibraryPage), "Library");
        });
    }

    internal void MinimizeGate() => (AppWindow.Presenter as OverlappedPresenter)?.Minimize();

    internal void ToggleMaximizeGate()
    {
        if (AppWindow.Presenter is OverlappedPresenter p)
        {
            if (p.State == OverlappedPresenterState.Maximized) p.Restore();
            else p.Maximize();
        }
    }

    // Mirror the window-close behaviour: hide to the tray, keep serving in the background.
    internal void CloseGate() => AppWindow.Hide();

    // Builds (or fully rebuilds) the nav shell for the current theme. Rebuilding
    // wholesale is the reliable way to re-theme on a live theme switch — the
    // NavigationView pane material and already-realized visuals don't re-theme
    // in place when RequestedTheme changes at runtime.
    private void BuildShell()
    {
        var theme = ThemeManager.CurrentElementTheme;

        _contentFrame = new Frame
        {
            Content = CreateStatusView("Rimeo Agent is starting...")
        };

        _navView = new NavigationView
        {
            IsBackButtonVisible = NavigationViewBackButtonVisible.Collapsed,
            PaneDisplayMode = NavigationViewPaneDisplayMode.Left,
            IsPaneToggleButtonVisible = false,
            OpenPaneLength = 212,
            IsSettingsVisible = false,   // hide the built-in gear (we have our own Settings)
            PaneHeader = BuildBrand(),
            PaneFooter = BuildFooter(),
            Content = _contentFrame,
            RequestedTheme = theme
        };
        // Mirror the macOS rail: Library / Account / Settings (Devices merged into Account).
        _navView.MenuItems.Add(CreateNavItem("Library", "Library")); // Folder
        _navView.MenuItems.Add(CreateNavItem("Account", "Account")); // Cloud (Devices merged in)
        _navView.MenuItems.Add(CreateNavItem("Settings", "Logs"));    // Settings gear
        _navView.SelectionChanged += NavView_SelectionChanged;
        ApplyPaneTheme();

        Content = _navView;
    }

    // The NavigationView pane material follows the window backdrop (system theme),
    // not RequestedTheme — so in a forced dark theme on a light Windows it stays
    // white and hides the white-on-white nav. Override the pane background brushes.
    private void ApplyPaneTheme()
    {
        _navView.Resources["NavigationViewDefaultPaneBackground"]  = UI.Sidebar;
        _navView.Resources["NavigationViewExpandedPaneBackground"] = UI.Sidebar;
        _navView.Resources["NavigationViewCompactPaneBackground"]  = UI.Sidebar;
        _navView.Background = UI.Sidebar;
    }

    private static bool ResolveDark(ElementTheme t) => t switch
    {
        ElementTheme.Light => false,
        ElementTheme.Dark  => true,
        _ => Application.Current.RequestedTheme == ApplicationTheme.Dark
    };

    /// <summary>Re-applies the saved theme app-wide by rebuilding the shell.</summary>
    public void ApplyTheme()
    {
        UI.IsDark = ResolveDark(ThemeManager.CurrentElementTheme);
        var tag = _currentTag;
        // Defer: this is called from a Button.Click inside the content we are about
        // to replace — rebuilding the shell synchronously from there can crash WinUI.
        DispatcherQueue.TryEnqueue(() =>
        {
            BuildShell();
            SelectNav(tag);
            NavigateSafely(PageTypeFor(tag), tag);
        });
    }

    private static Type PageTypeFor(string tag) => tag switch
    {
        "Account" => typeof(AccountPage),
        "Logs"    => typeof(LogsPage),
        _         => typeof(LibraryPage),
    };

    private void SelectNav(string tag)
    {
        var item = _navView.MenuItems.OfType<NavigationViewItem>()
            .FirstOrDefault(i => i.Tag?.ToString() == tag);
        if (item == null) return;
        _navigatingProgrammatically = true;
        try { _navView.SelectedItem = item; }
        catch (Exception ex) { Log.Error($"Select nav failed: {ex}"); }
        finally { _navigatingProgrammatically = false; }
    }

    private static StackPanel BuildBrand()
    {
        // Real Rimeo logo asset (Assets/rimeo1024.png, copied to output by the build).
        // Falls back to the drawn "R" badge only if the asset is missing, so the
        // brand mark is never blank.
        Microsoft.UI.Xaml.UIElement badge;
        var logoPath = System.IO.Path.Combine(System.AppContext.BaseDirectory, "Assets", "rimeo1024.png");
        if (System.IO.File.Exists(logoPath))
        {
            badge = new Microsoft.UI.Xaml.Controls.Image
            {
                Width = 30, Height = 30, VerticalAlignment = VerticalAlignment.Center,
                Source = new Microsoft.UI.Xaml.Media.Imaging.BitmapImage(new Uri(logoPath))
            };
        }
        else
        {
            badge = new Microsoft.UI.Xaml.Controls.Border
            {
                Width = 30, Height = 30, CornerRadius = new CornerRadius(9), Background = UI.Acc,
                VerticalAlignment = VerticalAlignment.Center,
                Child = new TextBlock { Text = "R", FontSize = 17, FontWeight = Microsoft.UI.Text.FontWeights.ExtraBold, Foreground = UI.White, HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center }
            };
        }
        var name = new TextBlock { Text = "Rimeo", FontSize = 17, FontWeight = Microsoft.UI.Text.FontWeights.ExtraBold, Foreground = UI.Text, VerticalAlignment = VerticalAlignment.Center };
        var tag = new TextBlock { Text = "Agent", FontSize = 11, FontWeight = Microsoft.UI.Text.FontWeights.SemiBold, Foreground = UI.Dim, VerticalAlignment = VerticalAlignment.Center };
        var row = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 10, Margin = new Thickness(14, 8, 14, 10) };
        row.Children.Add(badge); row.Children.Add(name); row.Children.Add(tag);
        return row;
    }

    private static StackPanel BuildFooter()
    {
        var dot = new Microsoft.UI.Xaml.Shapes.Ellipse { Width = 7, Height = 7, Fill = UI.Green, VerticalAlignment = VerticalAlignment.Center };
        var label = new TextBlock { Text = "Agent online", FontSize = 12, FontWeight = Microsoft.UI.Text.FontWeights.Medium, Foreground = UI.Secondary, VerticalAlignment = VerticalAlignment.Center };
        var row = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8, Margin = new Thickness(20, 11, 20, 11) };
        row.Children.Add(dot); row.Children.Add(label);
        return row;
    }

    private void NavView_SelectionChanged(NavigationView sender, NavigationViewSelectionChangedEventArgs args)
    {
        if (args.IsSettingsSelected) return;
        if (_navigatingProgrammatically) return;

        var tag = (args.SelectedItem as NavigationViewItem)?.Tag?.ToString();
        switch (tag)
        {
            case "Library":  NavigateSafely(typeof(LibraryPage), "Library");   break;
            case "Account":  NavigateSafely(typeof(AccountPage), "Account");   break;
            case "Logs":     NavigateSafely(typeof(LogsPage), "Logs");         break;
        }
    }

    public void NavigateToDefaultPage()
    {
        if (_inGate) return;                 // gate owns the window; no shell/nav yet
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

            // Adaptive first-launch size: a fraction of the work area, scaled by the
            // monitor DPI. A fixed pixel size (MoveAndResize is in *physical* pixels)
            // looks tiny on high-DPI displays — 1280px on a 4K/200% screen is a third
            // of the width and the content is scaled down on top of that.
            var area = Microsoft.UI.Windowing.DisplayArea.GetFromWindowId(
                AppWindow.Id, Microsoft.UI.Windowing.DisplayAreaFallback.Primary);
            var work = area.WorkArea;

            var hwndForDpi = WinRT.Interop.WindowNative.GetWindowHandle(this);
            uint dpi = GetDpiForWindow(hwndForDpi);
            double scale = dpi >= 72 ? dpi / 96.0 : 1.0;

            // Work area expressed in effective (DIP) pixels.
            double workWDip = work.Width  / scale;
            double workHDip = work.Height / scale;

            // Comfortable size: ~two thirds of the screen, clamped to sane bounds,
            // and never larger than the work area itself.
            double wDip = Math.Clamp(workWDip * 0.68, 1080, 1560);
            double hDip = Math.Clamp(workHDip * 0.84, 760, 1040);
            wDip = Math.Min(wDip, workWDip - 24);
            hDip = Math.Min(hDip, workHDip - 48);

            int w = (int)Math.Round(wDip * scale);
            int h = (int)Math.Round(hDip * scale);
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

    private static NavigationViewItem CreateNavItem(string content, string tag)
    {
        var symbol = tag switch
        {
            "Library" => Symbol.Library,
            "Account" => Symbol.Contact,
            _         => Symbol.Setting,
        };
        return new NavigationViewItem { Content = content, Tag = tag, Icon = new SymbolIcon(symbol) };
    }

    private void NavigateSafely(Type pageType, string pageName)
    {
        _currentTag = pageName;
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

    [DllImport("user32.dll")]
    private static extern uint GetDpiForWindow(IntPtr hWnd);
}
