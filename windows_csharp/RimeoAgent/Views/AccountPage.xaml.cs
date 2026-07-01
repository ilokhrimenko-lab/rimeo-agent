using System;
using System.ComponentModel;
using System.Net.Http;
using System.Text.Json;
using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using RimeoAgent.Config;
using RimeoAgent.Models;
using RimeoAgent.Services;
using Windows.System;

namespace RimeoAgent.Views;

// Mirror of macOS AccountTabView (login model): signed-in status + Sign out, then
// the merged "Connected" device list (this computer / rimeo.app / phone). The old
// standalone Devices (PairingPage) tab is folded in here. No token linking.
public sealed partial class AccountPage : Page
{
    private static readonly string[] MonitorIcon =
        { "M4 5H20A1 1 0 0 1 21 6V16A1 1 0 0 1 20 17H4A1 1 0 0 1 3 16V6A1 1 0 0 1 4 5Z", "M8 21h8M12 17v4" };
    private static readonly string[] GlobeIcon =
        { "M12 21a9 9 0 1 0 0-18 9 9 0 0 0 0 18Z", "M3 12h18M12 3c2.5 2.5 2.5 15 0 18M12 3c-2.5 2.5-2.5 15 0 18" };
    private static readonly string[] PhoneIcon =
        { "M9 2H15A2 2 0 0 1 17 4V20A2 2 0 0 1 15 22H9A2 2 0 0 1 7 20V4A2 2 0 0 1 9 2Z", "M11 18h2" };

    private readonly StackPanel _statusHost  = new() { Orientation = Orientation.Vertical, Spacing = 16 };
    private readonly StackPanel _devicesHost = new() { Orientation = Orientation.Vertical, Spacing = 11 };
    private bool _linked;
    private string _who = "";

    public AccountPage()
    {
        InitializeComponent();
        Content = Build();
        RebuildStatus();
        RebuildDevices();
        _ = RefreshAccount();
        AppState.Shared.PropertyChanged += OnAppStateChanged;
        Unloaded += (_, _) => AppState.Shared.PropertyChanged -= OnAppStateChanged;
    }

    private void OnAppStateChanged(object? sender, PropertyChangedEventArgs e)
    {
        if (e.PropertyName == nameof(AppState.PhoneConnected) ||
            e.PropertyName == nameof(AppState.CloudLinked))
        {
            DispatcherQueue.TryEnqueue(() =>
            {
                RebuildDevices();
                _ = RefreshAccount();   // link state changed → refresh top status too
            });
        }
    }

    private ScrollViewer Build()
    {
        var (scroll, stack) = UI.Page();

        stack.Children.Add(UI.ScreenHeader("Account",
            "Everything signed in to your Rimeo account connects automatically — no codes, no QR."));

        stack.Children.Add(UI.SectionLabel("Account"));
        stack.Children.Add(UI.Card(_statusHost));

        stack.Children.Add(UI.SectionLabel("Connected"));
        stack.Children.Add(_devicesHost);

        return scroll;
    }

    private void RebuildDevices()
    {
        _devicesHost.Children.Clear();

        var list = new StackPanel { Orientation = Orientation.Vertical, Spacing = 0 };
        list.Children.Add(DeviceRow(MonitorIcon, "This computer", "Your library lives here", "Active", true));
        list.Children.Add(Divider());

        var linked = AppState.Shared.CloudLinked;
        list.Children.Add(DeviceRow(GlobeIcon, "rimeo.app", "Player in your account",
            linked ? "Connected" : "Not connected", linked));
        list.Children.Add(Divider());

        var phone = AppState.Shared.PhoneConnected;
        list.Children.Add(DeviceRow(PhoneIcon, "Your phone",
            phone ? "Signed in to the Rimeo app" : "Sign in with the Rimeo app to connect",
            phone ? "Connected" : "Not connected", phone));

        _devicesHost.Children.Add(new Border
        {
            Background = UI.Surf, BorderBrush = UI.CardBrd, BorderThickness = new Thickness(1),
            CornerRadius = new CornerRadius(18), Child = list
        });

        if (!phone)
            _devicesHost.Children.Add(GetAppButton());

        _devicesHost.Children.Add(new TextBlock
        {
            Text = "One agent stays active per account — signing in on another computer signs this one out.",
            FontSize = 12, Foreground = UI.Dim, TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0, 2, 0, 0)
        });
    }

    private static string PhoneAppUrl => $"{AppConfig.RimeoAppUrl}/open";

    private static FrameworkElement GetAppButton()
    {
        var row = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 7 };
        row.Children.Add(UI.Icon(13, UI.AccText, 2,
            "M4 4h6v6H4zM14 4h6v6h-6zM4 14h6v6H4zM14 14h2v2h-2zM18 14h2v2h-2zM14 18h2v2h-2zM18 18h2v2h-2z"));  // qr glyph
        row.Children.Add(new TextBlock
        {
            Text = "Get the app for your phone", FontSize = 13,
            FontWeight = FontWeights.SemiBold, Foreground = UI.AccText,
            VerticalAlignment = VerticalAlignment.Center
        });
        var btn = new Button
        {
            Background = new SolidColorBrush(Microsoft.UI.Colors.Transparent),
            BorderThickness = new Thickness(0), Padding = new Thickness(2, 6, 2, 0), Content = row
        };
        var flyout = new Flyout { Content = BuildQRFlyout() };
        btn.Click += (_, _) =>
        {
            try { flyout.ShowAt(btn); }
            catch (Exception ex) { Log.Error($"Show QR flyout failed: {ex.Message}"); }
        };
        return btn;
    }

    // QR popover mirroring macOS: a code that points at rimeo.app/open so the user
    // scans it with a phone. Falls back to just the browser link if the bundled
    // QR asset is missing (e.g. a local dev build that didn't generate it).
    private static FrameworkElement BuildQRFlyout()
    {
        var panel = new StackPanel { Spacing = 12, Width = 220, HorizontalAlignment = HorizontalAlignment.Center };
        panel.Children.Add(new TextBlock { Text = "Get the Rimeo app", FontSize = 15, FontWeight = FontWeights.Bold, Foreground = UI.Text, HorizontalAlignment = HorizontalAlignment.Center });
        panel.Children.Add(new TextBlock { Text = "Scan with your phone's camera", FontSize = 12, Foreground = UI.Secondary, HorizontalAlignment = HorizontalAlignment.Center, TextWrapping = TextWrapping.Wrap, TextAlignment = TextAlignment.Center });

        var qrPath = System.IO.Path.Combine(System.AppContext.BaseDirectory, "Assets", "qr_open.png");
        if (System.IO.File.Exists(qrPath))
        {
            panel.Children.Add(new Border
            {
                Background = new SolidColorBrush(Microsoft.UI.Colors.White),
                CornerRadius = new CornerRadius(10), Padding = new Thickness(8),
                HorizontalAlignment = HorizontalAlignment.Center,
                Child = new Microsoft.UI.Xaml.Controls.Image
                {
                    Width = 180, Height = 180,
                    Source = new Microsoft.UI.Xaml.Media.Imaging.BitmapImage(new Uri(qrPath))
                }
            });
        }

        var openBtn = new Button
        {
            Background = new SolidColorBrush(Microsoft.UI.Colors.Transparent),
            BorderThickness = new Thickness(0), HorizontalAlignment = HorizontalAlignment.Center,
            Content = new TextBlock { Text = "Open in browser instead", FontSize = 12, FontWeight = FontWeights.SemiBold, Foreground = UI.AccText }
        };
        openBtn.Click += async (_, _) =>
        {
            try { await Launcher.LaunchUriAsync(new Uri(PhoneAppUrl)); }
            catch (Exception ex) { Log.Error($"Open phone-app link failed: {ex.Message}"); }
        };
        panel.Children.Add(openBtn);

        return panel;
    }

    private static Border Divider() => new() { Height = 1, Background = UI.CardBrd };

    private static FrameworkElement DeviceRow(string[] iconPaths, string title, string subtitle, string pillText, bool ok)
    {
        var grid = new Grid { Padding = new Thickness(18, 15, 18, 15) };
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });

        var iconBox = new Border
        {
            Width = 38, Height = 38, CornerRadius = new CornerRadius(11),
            Background = ok ? UI.AccSoft : UI.Chip, VerticalAlignment = VerticalAlignment.Center,
            Margin = new Thickness(0, 0, 13, 0),
            Child = UI.Icon(17, ok ? UI.AccText : UI.Dim, 2, iconPaths)
        };
        Grid.SetColumn(iconBox, 0);
        grid.Children.Add(iconBox);

        var textStack = new StackPanel { Orientation = Orientation.Vertical, Spacing = 2, VerticalAlignment = VerticalAlignment.Center };
        textStack.Children.Add(new TextBlock { Text = title, FontSize = 15, FontWeight = FontWeights.SemiBold, Foreground = UI.Text });
        textStack.Children.Add(new TextBlock { Text = subtitle, FontSize = 13, Foreground = UI.Secondary, TextWrapping = TextWrapping.Wrap });
        Grid.SetColumn(textStack, 1);
        grid.Children.Add(textStack);

        var pill = StatusPill(pillText, ok);
        pill.VerticalAlignment = VerticalAlignment.Center;
        Grid.SetColumn(pill, 2);
        grid.Children.Add(pill);

        return grid;
    }

    private static Border StatusPill(string text, bool ok)
    {
        var row = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6, VerticalAlignment = VerticalAlignment.Center };
        if (ok)
            row.Children.Add(new Border { Width = 7, Height = 7, CornerRadius = new CornerRadius(4), Background = UI.Green, VerticalAlignment = VerticalAlignment.Center });
        row.Children.Add(new TextBlock { Text = text, FontSize = 12, FontWeight = FontWeights.SemiBold, Foreground = ok ? UI.Green : UI.Dim });
        return new Border
        {
            Background = ok ? UI.GreenSoft : UI.Chip, CornerRadius = new CornerRadius(9),
            Padding = new Thickness(12, 6, 12, 6), Child = row
        };
    }

    private void RebuildStatus()
    {
        _statusHost.Children.Clear();

        var color = _linked ? UI.Green : UI.Red;
        var icon = new FontIcon
        {
            Glyph = _linked ? "" : "",   // CheckMark / Error
            FontFamily = new FontFamily("Segoe MDL2 Assets"),
            FontSize = 20,
            Foreground = color,
            VerticalAlignment = VerticalAlignment.Center
        };

        var textStack = new StackPanel { Orientation = Orientation.Vertical, Spacing = 2, VerticalAlignment = VerticalAlignment.Center };
        textStack.Children.Add(new TextBlock
        {
            Text = _linked ? "Signed in to Rimeo" : "Not signed in",
            FontSize = 17, FontWeight = FontWeights.Bold, Foreground = UI.Text, TextWrapping = TextWrapping.Wrap
        });
        if (_linked)
            textStack.Children.Add(new TextBlock { Text = _who, FontSize = 13, FontWeight = FontWeights.Medium, Foreground = UI.Secondary, TextWrapping = TextWrapping.Wrap });

        _statusHost.Children.Add(UI.HStack(11, icon, textStack));

        if (_linked)
            _statusHost.Children.Add(UI.DestructiveButton("Sign out", Unlink_Click));
    }

    private async Task RefreshAccount()
    {
        try
        {
            using var http = new HttpClient();
            var json = await http.GetStringAsync($"http://127.0.0.1:{AppConfig.Port}/api/account");
            var obj = JsonSerializer.Deserialize<Dictionary<string, JsonElement>>(json);
            if (obj == null) return;

            _linked = obj.TryGetValue("is_linked", out var l) && l.GetBoolean();
            var email = obj.TryGetValue("cloud_user_id", out var e) ? e.GetString() ?? "" : "";
            _who = !string.IsNullOrEmpty(email) ? email : DataStore.Shared.Data.CloudUrl;

            DispatcherQueue.TryEnqueue(RebuildStatus);
        }
        catch { }
    }

    private async void Unlink_Click(object sender, RoutedEventArgs e)
    {
        try
        {
            using var http = new HttpClient();
            await http.PostAsync($"http://127.0.0.1:{AppConfig.Port}/api/unlink_account?lan_token={Uri.EscapeDataString(RimeoAgent.Models.DataStore.Shared.Data.LanSecret)}", new StringContent(""));
            await RefreshAccount();
        }
        catch (Exception ex) { Log.Error($"Sign out failed: {ex.Message}"); }
    }
}
