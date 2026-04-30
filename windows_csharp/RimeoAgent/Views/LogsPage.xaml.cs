using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using RimeoAgent.Config;

namespace RimeoAgent.Views;

public sealed partial class LogsPage : Page
{
    private DispatcherQueueTimer? _timer;

    public LogsPage()
    {
        InitializeComponent();
        Loaded   += (_, _) => StartPolling();
        Unloaded += (_, _) => _timer?.Stop();
        RefreshLogs();
    }

    private void StartPolling()
    {
        _timer = DispatcherQueue.GetForCurrentThread().CreateTimer();
        _timer.Interval = TimeSpan.FromSeconds(2);
        _timer.Tick += (_, _) => RefreshLogs();
        _timer.Start();
    }

    private void RefreshLogs()
    {
        try
        {
            var path = AppConfig.Shared.LogFile;
            if (!File.Exists(path)) return;

            // Read last 200 lines
            var lines = File.ReadLines(path).TakeLast(200);
            LogText.Text = string.Join("\n", lines);

            if (AutoScrollToggle.IsChecked == true)
                LogScroll.ChangeView(null, LogScroll.ScrollableHeight, null);
        }
        catch { }
    }

    private void Refresh_Click(object sender, RoutedEventArgs e) => RefreshLogs();

    private void OpenFile_Click(object sender, RoutedEventArgs e)
    {
        try { System.Diagnostics.Process.Start("notepad.exe", AppConfig.Shared.LogFile); }
        catch { }
    }
}
