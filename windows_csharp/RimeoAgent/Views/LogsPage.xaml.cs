using System.Net.Http;
using System.Text;
using System.Text.Json;
using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using RimeoAgent.Config;
using RimeoAgent.Models;
using RimeoAgent.Services;
using Windows.ApplicationModel.DataTransfer;

namespace RimeoAgent.Views;

// 1:1 mirror of macOS LogsTabView ("Settings"): agent settings + in-app updates +
// report a bug + cache management.
public sealed partial class LogsPage : Page
{
    private readonly TextBlock  _settingsStatus = new() { FontSize = 12, Visibility = Visibility.Collapsed };
    private readonly StackPanel _updateHost     = new() { Orientation = Orientation.Vertical, Spacing = 10 };

    private readonly TextBox    _bugBox         = new() { PlaceholderText = "Describe the issue…", AcceptsReturn = true, TextWrapping = TextWrapping.Wrap, Height = 110, FontSize = 13 };
    private readonly TextBlock  _bugStatus      = new() { FontSize = 13, Visibility = Visibility.Collapsed, TextWrapping = TextWrapping.Wrap };
    private readonly StackPanel _bugButtonHost  = new() { Orientation = Orientation.Horizontal, Spacing = 10, VerticalAlignment = VerticalAlignment.Center };

    private readonly TextBlock    _cacheUsage   = new() { FontSize = 22, FontWeight = FontWeights.Bold, Foreground = UI.Text, Text = "0.00 GB used" };
    private readonly ProgressBar  _cacheBar     = new() { Width = 280, Minimum = 0, Maximum = 3, Value = 0 };
    private readonly TextBlock    _cacheMax     = new() { FontSize = 12, Foreground = UI.Dim, Text = "of 3 GB max" };
    private readonly TextBox      _cacheMaxBox  = new() { Width = 72, Text = "3", TextAlignment = TextAlignment.Center };
    private readonly TextBlock    _cacheStatus  = new() { FontSize = 12, Visibility = Visibility.Collapsed };

    public LogsPage()
    {
        InitializeComponent();
        Content = Build();
        BuildUpdateIdle();
        RefreshCacheSize();
    }

    private ScrollViewer Build()
    {
        var (scroll, stack) = UI.Page();

        // Header: "Settings" + version on the right
        var header = new Grid();
        header.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        header.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        var h = UI.Heading("Settings");
        Grid.SetColumn(h, 0); header.Children.Add(h);
        var ver = new TextBlock { Text = AppConfig.Shared.DisplayVersion, FontSize = 12, Foreground = UI.Dim, VerticalAlignment = VerticalAlignment.Bottom };
        Grid.SetColumn(ver, 1); header.Children.Add(ver);
        stack.Children.Add(header);

        // AGENT SETTINGS
        stack.Children.Add(UI.SectionLabel("Agent settings"));
        var launchToggle = new ToggleSwitch { IsOn = AgentSettings.LaunchAtLogin };
        launchToggle.Header = new TextBlock { Text = "Open RimeoAgent at system startup", FontSize = 13, Foreground = UI.Text };
        launchToggle.Toggled += (_, _) =>
        {
            AgentSettings.LaunchAtLogin = launchToggle.IsOn;
            _settingsStatus.Visibility = Visibility.Visible;
            _settingsStatus.Text = launchToggle.IsOn ? "✓ Launch at startup enabled" : "✓ Launch at startup disabled";
            _settingsStatus.Foreground = UI.Green;
        };
        stack.Children.Add(UI.Card(UI.VStack(12, launchToggle, _settingsStatus)));

        // CHECK FOR UPDATES
        stack.Children.Add(UI.SectionLabel("Check for updates"));
        stack.Children.Add(UI.Card(_updateHost));

        // REPORT A BUG
        stack.Children.Add(UI.SectionLabel("Report a bug"));
        _bugButtonHost.Children.Add(UI.PrimaryButton("Send Report", SendBug_Click));
        var bugCard = UI.VStack(12,
            UI.Body("The last 200 log lines will be attached automatically.", UI.Dim, 12),
            _bugBox,
            UI.HStack(10,
                _bugButtonHost,
                UI.SecondaryButton("Copy Log", CopyLog_Click),
                UI.SecondaryButton("Open Log", OpenLog_Click)),
            _bugStatus
        );
        stack.Children.Add(UI.Card(bugCard));

        // CACHE
        stack.Children.Add(UI.SectionLabel("Cache"));
        _cacheBar.Foreground = UI.Acc;
        var saveBtn = UI.PrimaryButton("Save", SaveMaxCache_Click);
        var clearBtn = new Button
        {
            Content = new TextBlock { Text = "Clear Cache", FontSize = 13, FontWeight = FontWeights.Medium, Foreground = UI.Red },
            Background = UI.Surf,
            BorderBrush = new SolidColorBrush(UI.Hex("#7f1d1d")),
            BorderThickness = new Thickness(1),
            CornerRadius = new CornerRadius(12),
            Padding = new Thickness(20, 10, 20, 10),
            HorizontalAlignment = HorizontalAlignment.Left
        };
        clearBtn.Click += ClearCache_Click;

        var cacheTop = new Grid();
        cacheTop.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        cacheTop.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        var left = UI.VStack(6, _cacheUsage, _cacheBar, _cacheMax);
        Grid.SetColumn(left, 0); cacheTop.Children.Add(left);
        var right = UI.VStack(4,
            new TextBlock { Text = "Max cache (GB)", FontSize = 11, Foreground = UI.Dim, HorizontalAlignment = HorizontalAlignment.Right },
            UI.HStack(8, _cacheMaxBox, saveBtn));
        right.VerticalAlignment = VerticalAlignment.Center;
        Grid.SetColumn(right, 1); cacheTop.Children.Add(right);

        var cacheCard = UI.VStack(12,
            UI.Body("The cache stores converted audio (WAV), waveform data and artwork so tracks load faster on repeat plays.", UI.Dim, 12),
            cacheTop,
            UI.HStack(12, clearBtn, _cacheStatus)
        );
        stack.Children.Add(UI.Card(cacheCard));

        return scroll;
    }

    // ── Update checker UI ──────────────────────────────────────────────────
    private void BuildUpdateIdle()
    {
        _updateHost.Children.Clear();
        _updateHost.Children.Add(UI.SecondaryButton("Check for Updates", (_, _) => RunUpdateCheck()));
    }

    private void RunUpdateCheck()
    {
        _updateHost.Children.Clear();
        _updateHost.Children.Add(UI.HStack(10,
            new ProgressRing { IsActive = true, Width = 18, Height = 18 },
            new TextBlock { Text = "Checking for updates…", FontSize = 13, Foreground = UI.Dim, VerticalAlignment = VerticalAlignment.Center }));

        UpdateChecker.Shared.ForceCheckAsync(info =>
            DispatcherQueue.TryEnqueue(() =>
            {
                if (info != null) BuildUpdateAvailable(info);
                else BuildUpToDate();
            }));
    }

    private void BuildUpToDate()
    {
        _updateHost.Children.Clear();
        _updateHost.Children.Add(UI.HStack(10,
            new Microsoft.UI.Xaml.Shapes.Ellipse { Width = 12, Height = 12, Fill = UI.Green, VerticalAlignment = VerticalAlignment.Center },
            new TextBlock { Text = "You're up to date", FontSize = 13, Foreground = UI.Text, VerticalAlignment = VerticalAlignment.Center },
            UI.SecondaryButton("Check Again", (_, _) => RunUpdateCheck())));
    }

    private void BuildUpdateAvailable(UpdateInfo info)
    {
        _updateHost.Children.Clear();
        var lines = UI.VStack(2,
            new TextBlock { Text = $"Update available: {info.Version}", FontSize = 13, FontWeight = FontWeights.Medium, Foreground = UI.Text });
        if (!string.IsNullOrEmpty(info.Notes))
            lines.Children.Add(new TextBlock { Text = info.Notes, FontSize = 11, Foreground = UI.Dim, TextWrapping = TextWrapping.Wrap });

        _updateHost.Children.Add(lines);
        _updateHost.Children.Add(UI.PrimaryButton("Update Now", (_, _) => UpdateNow(info)));
    }

    private void UpdateNow(UpdateInfo info)
    {
        _updateHost.Children.Clear();
        var progress = new TextBlock { Text = "Downloading update… 0%", FontSize = 13, Foreground = UI.Dim };
        _updateHost.Children.Add(UI.HStack(10,
            new ProgressRing { IsActive = true, Width = 18, Height = 18 }, progress));

        Task.Run(() =>
        {
            try
            {
                UpdateChecker.Shared.DownloadAndApply(info, p =>
                    DispatcherQueue.TryEnqueue(() => progress.Text = $"Downloading update… {(int)(p * 100)}%"));
                // DownloadAndApply calls Environment.Exit on success.
            }
            catch (Exception ex)
            {
                Log.Error($"Update failed: {ex.Message}");
                DispatcherQueue.TryEnqueue(() =>
                {
                    _updateHost.Children.Clear();
                    _updateHost.Children.Add(new TextBlock { Text = $"Update failed: {ex.Message}", FontSize = 13, Foreground = UI.Red, TextWrapping = TextWrapping.Wrap });
                    _updateHost.Children.Add(UI.SecondaryButton("Try Again", (_, _) => RunUpdateCheck()));
                });
            }
        });
    }

    // ── Report a bug ───────────────────────────────────────────────────────
    private async void SendBug_Click(object sender, RoutedEventArgs e)
    {
        var desc = _bugBox.Text.Trim();
        if (string.IsNullOrEmpty(desc)) { ShowBug("Please describe the issue.", ok: false); return; }

        ShowBug("Sending…", ok: true);
        try
        {
            using var http = new HttpClient();
            var payload = JsonSerializer.Serialize(new { description = desc });
            var resp = await http.PostAsync($"http://127.0.0.1:{AppConfig.Port}/api/report_bug",
                new StringContent(payload, Encoding.UTF8, "application/json"));
            if (resp.IsSuccessStatusCode)
            {
                ShowBug("✓ Bug report sent!", ok: true);
                _bugBox.Text = "";
            }
            else ShowBug($"Error {(int)resp.StatusCode}", ok: false);
        }
        catch (Exception ex) { ShowBug($"Error: {ex.Message}", ok: false); }
    }

    private void CopyLog_Click(object sender, RoutedEventArgs e)
    {
        try
        {
            var text = File.Exists(AppConfig.Shared.LogFile)
                ? string.Join("\n", File.ReadLines(AppConfig.Shared.LogFile).TakeLast(200))
                : "";
            var dp = new DataPackage();
            dp.SetText(text);
            Clipboard.SetContent(dp);
            ShowBug("✓ Log copied", ok: true);
        }
        catch (Exception ex) { ShowBug($"Error: {ex.Message}", ok: false); }
    }

    private void OpenLog_Click(object sender, RoutedEventArgs e)
    {
        try { System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo(AppConfig.Shared.LogFile) { UseShellExecute = true }); }
        catch { try { System.Diagnostics.Process.Start("notepad.exe", AppConfig.Shared.LogFile); } catch { } }
    }

    private void ShowBug(string text, bool ok)
    {
        _bugStatus.Visibility = Visibility.Visible;
        _bugStatus.Text = text;
        _bugStatus.Foreground = ok ? UI.Green : UI.Red;
    }

    // ── Cache ──────────────────────────────────────────────────────────────
    private void RefreshCacheSize()
    {
        var stored = (int)DataStore.Shared.Data.MaxCacheGb;
        if (stored > 0) { _cacheMaxBox.Text = stored.ToString(); _cacheBar.Maximum = stored; _cacheMax.Text = $"of {stored} GB max"; }

        var dir = AppConfig.Shared.CacheDir;
        Task.Run(() =>
        {
            long total = 0;
            try
            {
                if (Directory.Exists(dir))
                    foreach (var f in Directory.EnumerateFiles(dir, "*", SearchOption.AllDirectories))
                        try { total += new FileInfo(f).Length; } catch { }
            }
            catch { }
            var gb = total / 1_073_741_824.0;
            DispatcherQueue.TryEnqueue(() =>
            {
                _cacheUsage.Text = $"{gb:F2} GB used";
                _cacheBar.Value = Math.Min(gb, _cacheBar.Maximum);
            });
        });
    }

    private void SaveMaxCache_Click(object sender, RoutedEventArgs e)
    {
        var value = Math.Max(1, int.TryParse(_cacheMaxBox.Text, out var v) ? v : 3);
        DataStore.Shared.Update(d => d.MaxCacheGb = value);
        _cacheMaxBox.Text = value.ToString();
        _cacheBar.Maximum = value;
        _cacheMax.Text = $"of {value} GB max";
        _cacheStatus.Visibility = Visibility.Visible;
        _cacheStatus.Text = $"✓ Max cache set to {value} GB";
        _cacheStatus.Foreground = UI.Green;
    }

    private void ClearCache_Click(object sender, RoutedEventArgs e)
    {
        _cacheStatus.Visibility = Visibility.Visible;
        _cacheStatus.Text = "Clearing…";
        _cacheStatus.Foreground = UI.Dim;
        Task.Run(() =>
        {
            try
            {
                var dir = AppConfig.Shared.CacheDir;
                if (Directory.Exists(dir))
                    foreach (var f in Directory.EnumerateFiles(dir, "*", SearchOption.AllDirectories))
                        try { File.Delete(f); } catch { }
                DispatcherQueue.TryEnqueue(() =>
                {
                    _cacheStatus.Text = "✓ Cache cleared";
                    _cacheStatus.Foreground = UI.Green;
                    RefreshCacheSize();
                });
            }
            catch (Exception ex)
            {
                DispatcherQueue.TryEnqueue(() =>
                {
                    _cacheStatus.Text = $"Error: {ex.Message}";
                    _cacheStatus.Foreground = UI.Red;
                });
            }
        });
    }
}
