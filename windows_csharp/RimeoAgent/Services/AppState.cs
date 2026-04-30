using System.ComponentModel;
using System.Runtime.CompilerServices;
using Microsoft.UI.Dispatching;
using RimeoAgent.Config;
using RimeoAgent.Models;

namespace RimeoAgent.Services;

public sealed class AppState : INotifyPropertyChanged
{
    public static readonly AppState Shared = new();
    public event PropertyChangedEventHandler? PropertyChanged;

    private DispatcherQueue? _dispatcherQueue;

    public void SetDispatcherQueue(DispatcherQueue queue) => _dispatcherQueue = queue;

    private void OnUI(Action action)
    {
        if (_dispatcherQueue != null)
            _dispatcherQueue.TryEnqueue(() => action());
        else
            action();
    }

    private void Set<T>(ref T field, T value, [CallerMemberName] string? name = null)
    {
        if (EqualityComparer<T>.Default.Equals(field, value)) return;
        field = value;
        OnUI(() => PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(name)));
    }

    // Onboarding
    private bool _isOnboarding;
    public bool IsOnboarding { get => _isOnboarding; set => Set(ref _isOnboarding, value); }

    // Analysis progress
    private bool   _analysisRunning;
    private int    _analysisDone;
    private int    _analysisTotal;
    private string _analysisCurrent = "";
    private int    _analysisErrors;
    private int    _analysisUnavailable;

    public bool   AnalysisRunning     { get => _analysisRunning;     set => Set(ref _analysisRunning, value); }
    public int    AnalysisDone        { get => _analysisDone;        set => Set(ref _analysisDone, value); }
    public int    AnalysisTotal       { get => _analysisTotal;       set => Set(ref _analysisTotal, value); }
    public string AnalysisCurrent     { get => _analysisCurrent;     set => Set(ref _analysisCurrent, value); }
    public int    AnalysisErrors      { get => _analysisErrors;      set => Set(ref _analysisErrors, value); }
    public int    AnalysisUnavailable { get => _analysisUnavailable; set => Set(ref _analysisUnavailable, value); }

    // Tunnel
    private bool   _tunnelActive;
    private string _tunnelUrl = "";
    public bool   TunnelActive { get => _tunnelActive; set => Set(ref _tunnelActive, value); }
    public string TunnelUrl    { get => _tunnelUrl;    set => Set(ref _tunnelUrl, value); }

    // Cloud
    private bool   _cloudLinked;
    private string _cloudEmail = "";
    public bool   CloudLinked { get => _cloudLinked; set => Set(ref _cloudLinked, value); }
    public string CloudEmail  { get => _cloudEmail;  set => Set(ref _cloudEmail, value); }

    private AppState()
    {
        var cfg = AppConfig.Shared;
        _isOnboarding = !cfg.HasAnyLibrarySource;

        var d = DataStore.Shared.Data;
        _cloudLinked = !string.IsNullOrEmpty(d.CloudUrl);
        _cloudEmail  = d.CloudUserId ?? "";
        _tunnelUrl   = d.TunnelUrl;
        _tunnelActive = !string.IsNullOrEmpty(d.TunnelUrl);
    }

    public void RefreshFromData()
    {
        var d = DataStore.Shared.Data;
        CloudLinked = !string.IsNullOrEmpty(d.CloudUrl);
        CloudEmail  = d.CloudUserId ?? "";
        TunnelUrl   = d.TunnelUrl;
    }

    public void FinishOnboarding(string xmlPath)
    {
        AppConfig.Shared.SetXmlPath(xmlPath);
        RekordboxParser.Shared.InvalidateCache();
        IsOnboarding = false;
    }

    public void RefreshLibrarySource()
    {
        IsOnboarding = !AppConfig.Shared.HasAnyLibrarySource;
    }
}
