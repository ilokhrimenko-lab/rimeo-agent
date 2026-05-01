using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using RimeoAgent.Config;
using RimeoAgent.Services;
using RimeoAgent.Views;

namespace RimeoAgent;

public sealed partial class MainWindow : Window
{
    private readonly NavigationView _navView;
    private readonly Frame _contentFrame;
    private bool _defaultPageRequested;

    public MainWindow()
    {
        // Comfortable startup size
        AppWindow.Resize(new Windows.Graphics.SizeInt32(900, 680));
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

        Log.Info("Navigating to Library");
        var libraryItem = _navView.MenuItems.OfType<NavigationViewItem>()
            .FirstOrDefault(item => item.Tag?.ToString() == "Library");
        if (libraryItem != null) _navView.SelectedItem = libraryItem;
        NavigateSafely(typeof(LibraryPage), "Library");
    }

    public void Show()
    {
        AppWindow.Show();
        Activate();
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
}
