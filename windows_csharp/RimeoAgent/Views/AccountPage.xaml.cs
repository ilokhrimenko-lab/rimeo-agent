using System.Net.Http;
using System.Text;
using System.Text.Json;
using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using RimeoAgent.Config;
using RimeoAgent.Models;

namespace RimeoAgent.Views;

// 1:1 mirror of macOS AccountTabView: connection status + link-to-account form.
public sealed partial class AccountPage : Page
{
    private readonly StackPanel _statusHost = new() { Orientation = Orientation.Vertical, Spacing = 12 };
    private readonly TextBox    _tokenBox   = new() { PlaceholderText = "8-character code from web dashboard", FontSize = 13 };
    private readonly TextBlock  _linkStatus = new() { FontSize = 13, Visibility = Visibility.Collapsed, TextWrapping = TextWrapping.Wrap };
    private readonly StackPanel _linkButtonHost = new() { Orientation = Orientation.Horizontal, Spacing = 16, VerticalAlignment = VerticalAlignment.Center };

    private bool _linked;
    private string _who = "";

    public AccountPage()
    {
        InitializeComponent();
        Content = Build();
        RebuildStatus();
        _ = RefreshAccount();
    }

    private ScrollViewer Build()
    {
        var (scroll, stack) = UI.Page();

        stack.Children.Add(UI.Heading("Account"));
        stack.Children.Add(UI.Subtitle("Link this agent to your Rimeo account so the web app knows it's online."));

        stack.Children.Add(UI.SectionLabel("Connection status"));
        stack.Children.Add(_statusHost);

        stack.Children.Add(UI.SectionLabel("Link to account"));

        _linkButtonHost.Children.Add(UI.PrimaryButton("Link Agent", Link_Click));
        var card = UI.VStack(14,
            UI.StepsBox(
                UI.StepRow("1", "Open rimeo.app → Account → click «Generate Link Token»."),
                UI.StepRow("2", "Enter the 8-character code below and click Link.")
            ),
            _tokenBox,
            UI.HStack(16, _linkButtonHost, _linkStatus)
        );
        stack.Children.Add(UI.Card(card));

        return scroll;
    }

    private void RebuildStatus()
    {
        _statusHost.Children.Clear();

        // Connection badge
        var color = _linked ? UI.Green : UI.Red;
        var bg = new SolidColorBrush(_linked ? UI.Hex("#14532d") : UI.Hex("#3b1717"));
        var dot = new Microsoft.UI.Xaml.Shapes.Ellipse { Width = 12, Height = 12, Fill = color, VerticalAlignment = VerticalAlignment.Center };
        var label = new TextBlock
        {
            Text = _linked ? $"Linked as {_who}" : "Not linked to a cloud account",
            FontSize = 13, Foreground = color, VerticalAlignment = VerticalAlignment.Center, TextWrapping = TextWrapping.Wrap
        };
        var row = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8, VerticalAlignment = VerticalAlignment.Center };
        row.Children.Add(dot); row.Children.Add(label);
        _statusHost.Children.Add(new Border
        {
            Background = bg, CornerRadius = new CornerRadius(12), Padding = new Thickness(12, 6, 12, 6),
            HorizontalAlignment = HorizontalAlignment.Left, Child = row
        });

        if (_linked)
        {
            var del = new Button
            {
                Content = new TextBlock { Text = "Delete Connection", FontSize = 13, FontWeight = FontWeights.Medium, Foreground = UI.Red },
                Background = new SolidColorBrush(UI.Hex("#3b1717")),
                BorderThickness = new Thickness(0),
                CornerRadius = new CornerRadius(12),
                Padding = new Thickness(20, 10, 20, 10),
                HorizontalAlignment = HorizontalAlignment.Left
            };
            del.Click += Unlink_Click;
            _statusHost.Children.Add(del);
        }
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

    private async void Link_Click(object sender, RoutedEventArgs e)
    {
        var token = _tokenBox.Text.Trim();
        if (string.IsNullOrEmpty(token))
        {
            ShowStatus("Please enter the link token.", ok: false);
            return;
        }

        ShowStatus("Linking…", ok: true);
        try
        {
            using var http = new HttpClient();
            var payload = JsonSerializer.Serialize(new { token, cloud_url = AppConfig.RimeoAppUrl });
            var resp = await http.PostAsync($"http://127.0.0.1:{AppConfig.Port}/api/link_account",
                new StringContent(payload, Encoding.UTF8, "application/json"));

            if (resp.IsSuccessStatusCode)
            {
                ShowStatus("✓ Linked successfully!", ok: true);
                _tokenBox.Text = "";
                await RefreshAccount();
            }
            else
            {
                ShowStatus($"Error {(int)resp.StatusCode}", ok: false);
            }
        }
        catch (Exception ex)
        {
            Log.Error($"Link failed: {ex.Message}");
            ShowStatus($"Error: {ex.Message}", ok: false);
        }
    }

    private async void Unlink_Click(object sender, RoutedEventArgs e)
    {
        try
        {
            using var http = new HttpClient();
            await http.PostAsync($"http://127.0.0.1:{AppConfig.Port}/api/unlink_account", new StringContent(""));
            await RefreshAccount();
        }
        catch (Exception ex) { Log.Error($"Unlink failed: {ex.Message}"); }
    }

    private void ShowStatus(string text, bool ok)
    {
        _linkStatus.Visibility = Visibility.Visible;
        _linkStatus.Text = text;
        _linkStatus.Foreground = ok ? UI.Green : UI.Red;
    }
}
