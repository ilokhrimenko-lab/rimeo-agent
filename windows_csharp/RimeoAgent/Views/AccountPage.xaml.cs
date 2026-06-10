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
    private readonly StackPanel _statusHost = new() { Orientation = Orientation.Vertical, Spacing = 16 };
    private readonly TextBox    _tokenBox   = new() { PlaceholderText = "8-character code from web dashboard", FontSize = 15, FontFamily = new FontFamily("Consolas") };
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

        stack.Children.Add(UI.ScreenHeader("Account",
            "Link this agent to your Rimeo account so the web app knows it's online."));

        stack.Children.Add(UI.SectionLabel("Connection status"));
        stack.Children.Add(UI.Card(_statusHost));

        stack.Children.Add(UI.SectionLabel("Link to account"));

        _linkButtonHost.Children.Add(UI.PrimaryButton("Link Agent", Link_Click));

        _tokenBox.Background = UI.Field;
        _tokenBox.BorderBrush = UI.Brd;
        _tokenBox.CornerRadius = new CornerRadius(13);
        _tokenBox.Padding = new Thickness(14, 12, 14, 12);

        var card = UI.VStack(16,
            UI.StepsList(
                UI.StepRow("1", "On rimeo.app open Account and click Generate Link Token."),
                UI.StepRow("2", "Enter the 8-character code below and click Link Agent.")),
            _tokenBox,
            UI.HStack(16, _linkButtonHost, _linkStatus));
        stack.Children.Add(UI.Card(card));

        return scroll;
    }

    private void RebuildStatus()
    {
        _statusHost.Children.Clear();

        var color = _linked ? UI.Green : UI.Red;
        var icon = new FontIcon
        {
            Glyph = _linked ? "" : "",   // CheckMark / Error
            FontFamily = new FontFamily("Segoe MDL2 Assets"),
            FontSize = 20,
            Foreground = color,
            VerticalAlignment = VerticalAlignment.Center
        };

        var textStack = new StackPanel { Orientation = Orientation.Vertical, Spacing = 2, VerticalAlignment = VerticalAlignment.Center };
        textStack.Children.Add(new TextBlock
        {
            Text = _linked ? "Linked to your account" : "Not linked to a cloud account",
            FontSize = 17, FontWeight = FontWeights.Bold, Foreground = UI.Text, TextWrapping = TextWrapping.Wrap
        });
        if (_linked)
            textStack.Children.Add(new TextBlock { Text = _who, FontSize = 13, FontWeight = FontWeights.Medium, Foreground = UI.Secondary, TextWrapping = TextWrapping.Wrap });

        _statusHost.Children.Add(UI.HStack(11, icon, textStack));

        if (_linked)
            _statusHost.Children.Add(UI.DestructiveButton("Delete Connection", Unlink_Click));
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
