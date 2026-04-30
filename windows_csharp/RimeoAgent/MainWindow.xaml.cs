using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using RimeoAgent.Config;
using RimeoAgent.Services;
using RimeoAgent.Views;

namespace RimeoAgent;

public sealed partial class MainWindow : Window
{
    public MainWindow()
    {
        InitializeComponent();

        // Comfortable startup size
        AppWindow.Resize(new Windows.Graphics.SizeInt32(900, 680));
        AppWindow.SetIcon("Assets/rimeo.ico");
        Title = $"Rimeo Agent — {AppConfig.Shared.DisplayVersion}";

        // Provide DispatcherQueue to AppState
        AppState.Shared.SetDispatcherQueue(Microsoft.UI.Dispatching.DispatcherQueue.GetForCurrentThread());

        // Close → hide to tray instead of exit
        AppWindow.Closing += (_, e) =>
        {
            e.Cancel = true;
            AppWindow.Hide();
        };

        // Navigate to Library by default
        NavView.SelectedItem = NavView.MenuItems[0];
        ContentFrame.Navigate(typeof(LibraryPage));
    }

    private void NavView_SelectionChanged(NavigationView sender, NavigationViewSelectionChangedEventArgs args)
    {
        if (args.IsSettingsSelected) return;

        var tag = (args.SelectedItem as NavigationViewItem)?.Tag?.ToString();
        switch (tag)
        {
            case "Library":  ContentFrame.Navigate(typeof(LibraryPage));  break;
            case "Analysis": ContentFrame.Navigate(typeof(AnalysisPage)); break;
            case "Pairing":  ContentFrame.Navigate(typeof(PairingPage));  break;
            case "Account":  ContentFrame.Navigate(typeof(AccountPage));  break;
            case "Logs":     ContentFrame.Navigate(typeof(LogsPage));     break;
            case "Quit":
                ((App)Application.Current).TrayQuit_Click(sender, new RoutedEventArgs());
                break;
        }
    }

    public void Show()
    {
        AppWindow.Show();
        Activate();
    }
}
