using System.Diagnostics;
using System.Net.Http;
using System.Text.Json;
using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Imaging;
using RimeoAgent.Config;
using RimeoAgent.Models;
using RimeoAgent.Services;

namespace RimeoAgent.Views;

// 1:1 mirror of macOS PairingTabView: web-browser steps + iOS-app steps with a
// scannable pairing QR (from /api/pairing_info) and a refresh action.
public sealed partial class PairingPage : Page
{
    private readonly Image _qr = new() { Width = 132, Height = 132, Stretch = Stretch.Uniform };

    public PairingPage()
    {
        InitializeComponent();
        Content = Build();
        _ = RefreshQr();
    }

    private ScrollViewer Build()
    {
        var (scroll, stack) = UI.Page();

        stack.Children.Add(UI.ScreenHeader("Pairing",
            "Connect your music to the web player and the Rimeo iOS app."));

        // WEB BROWSER
        stack.Children.Add(UI.SectionLabel("Web browser"));
        stack.Children.Add(UI.Card(UI.VStack(16,
            BodyBold("To listen to your music from any web browser"),
            UI.StepsList(
                UI.StepRow("1", "Open rimeo.app and log in to your account."),
                UI.StepRow("2", "Go to Account, then click Generate Link Token."),
                UI.StepRow("3", "Enter the token in the Agent's Account tab and press Link.")),
            BrowserStatus())));

        // RIMEO iOS APP
        stack.Children.Add(UI.SectionLabel("Rimeo iOS app"));

        var left = UI.VStack(16,
            BodyBold("To use the Rimeo iOS app on your iPhone"),
            UI.StepsList(
                UI.StepRow("1", "Open the Rimeo iOS app on your iPhone."),
                UI.StepRow("2", "Tap Pair and scan the QR code shown here."),
                UI.StepRow("3", "Log in to your account — your library syncs automatically.")));

        var qrBox = new Border
        {
            Background = new SolidColorBrush(Microsoft.UI.Colors.White),
            CornerRadius = new CornerRadius(16),
            BorderBrush = UI.Brd,
            BorderThickness = new Thickness(1),
            Padding = new Thickness(14),
            Child = _qr
        };
        var right = UI.VStack(12, qrBox, UI.SecondaryButton("Refresh QR", (_, _) => _ = RefreshQr()));
        right.Width = 164;

        var grid = new Grid();
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        Grid.SetColumn(left, 0); grid.Children.Add(left);
        var rightWrap = new Border { Margin = new Thickness(24, 0, 0, 0), Child = right };
        Grid.SetColumn(rightWrap, 1); grid.Children.Add(rightWrap);

        stack.Children.Add(UI.Card(grid));

        return scroll;
    }

    private static TextBlock BodyBold(string text) => new()
    {
        Text = text,
        FontSize = 15,
        FontWeight = FontWeights.SemiBold,
        Foreground = UI.Text,
        TextWrapping = TextWrapping.Wrap
    };

    private Border BrowserStatus()
    {
        var linked = AppState.Shared.CloudLinked;
        var who = !string.IsNullOrEmpty(AppState.Shared.CloudEmail)
            ? AppState.Shared.CloudEmail
            : DataStore.Shared.Data.CloudUrl;

        var text = linked ? $"Connected as {who}" : "Not connected — link your agent in the Account tab";
        var color = linked ? UI.Green : UI.Secondary;
        var row = UI.StatusDot(linked ? UI.Green : UI.Dim, text, color);

        return new Border
        {
            Background = linked ? UI.GreenSoft : UI.Chip,
            CornerRadius = new CornerRadius(11),
            Padding = new Thickness(14, 9, 14, 9),
            HorizontalAlignment = HorizontalAlignment.Left,
            Child = row
        };
    }

    // Fetches a fresh pairing code from the agent and shows the QR it returns.
    private async Task RefreshQr()
    {
        try
        {
            using var http = new HttpClient();
            var json = await http.GetStringAsync($"http://127.0.0.1:{AppConfig.Port}/api/pairing_info");
            var obj = JsonSerializer.Deserialize<Dictionary<string, JsonElement>>(json);
            if (obj != null && obj.TryGetValue("qr_url", out var q) && q.GetString() is string url && !string.IsNullOrEmpty(url))
            {
                DispatcherQueue.TryEnqueue(() => _qr.Source = new BitmapImage(new Uri(url)));
            }
        }
        catch (Exception ex)
        {
            Log.Error($"Pairing QR refresh failed: {ex.Message}");
        }
    }

    private void OpenRimeoApp_Click(object sender, RoutedEventArgs e)
    {
        try { Process.Start(new ProcessStartInfo(AppConfig.RimeoAppUrl) { UseShellExecute = true }); }
        catch (Exception ex) { Log.Error($"Open rimeo.app failed: {ex.Message}"); }
    }
}
