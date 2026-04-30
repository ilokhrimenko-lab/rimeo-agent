using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using RimeoAgent.Services;

namespace RimeoAgent.Views;

public sealed partial class AnalysisPage : Page
{
    private DispatcherQueueTimer? _timer;

    public AnalysisPage()
    {
        InitializeComponent();
        Loaded   += (_, _) => StartPolling();
        Unloaded += (_, _) => StopPolling();
        UpdateUi();
    }

    private void StartPolling()
    {
        _timer = DispatcherQueue.GetForCurrentThread().CreateTimer();
        _timer.Interval = TimeSpan.FromSeconds(1);
        _timer.Tick += (_, _) => UpdateUi();
        _timer.Start();
    }

    private void StopPolling() => _timer?.Stop();

    private void UpdateUi()
    {
        var s = AppState.Shared;
        StartBtn.IsEnabled   = !s.AnalysisRunning;
        StopBtn.IsEnabled    = s.AnalysisRunning;
        RecheckBtn.IsEnabled = !s.AnalysisRunning;

        var total = Math.Max(1, s.AnalysisTotal);
        ProgressBar.Value  = s.AnalysisRunning ? (double)s.AnalysisDone / total * 100 : 0;
        ProgressLabel.Text = s.AnalysisRunning
            ? $"{s.AnalysisDone} / {s.AnalysisTotal}"
            : "Idle";
        CurrentTrack.Text  = s.AnalysisCurrent;

        var store = AnalysisEngine.Shared.AllIds().Count;
        StatAnalyzed.Text    = $"Analyzed: {store}";
        StatUnavailable.Text = $"Unavailable: {s.AnalysisUnavailable}";
        StatErrors.Text      = s.AnalysisErrors > 0 ? $"Errors: {s.AnalysisErrors}" : "";
    }

    private async void Start_Click(object sender, RoutedEventArgs e)
    {
        using var http = new System.Net.Http.HttpClient();
        await http.PostAsync($"http://127.0.0.1:{Config.AppConfig.Port}/api/analysis/start",
            new System.Net.Http.StringContent(""));
    }

    private async void Stop_Click(object sender, RoutedEventArgs e)
    {
        using var http = new System.Net.Http.HttpClient();
        await http.PostAsync($"http://127.0.0.1:{Config.AppConfig.Port}/api/analysis/stop",
            new System.Net.Http.StringContent(""));
    }

    private async void Recheck_Click(object sender, RoutedEventArgs e)
    {
        using var http = new System.Net.Http.HttpClient();
        await http.PostAsync($"http://127.0.0.1:{Config.AppConfig.Port}/api/analysis/recheck",
            new System.Net.Http.StringContent(""));
    }
}
