using System.Net.Http;
using System.Text.Json;
using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using RimeoAgent.Config;
using RimeoAgent.Models;

namespace RimeoAgent.Views;

// Mirror of macOS AccountTabView (login model): signed-in status + Sign out +
// active-session note. No token linking — the agent signs in on the gate.
public sealed partial class AccountPage : Page
{
    private readonly StackPanel _statusHost = new() { Orientation = Orientation.Vertical, Spacing = 16 };
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
            "You're signed in to Rimeo. Devices on the same account connect automatically."));

        stack.Children.Add(UI.SectionLabel("Account"));
        stack.Children.Add(UI.Card(_statusHost));

        stack.Children.Add(UI.SectionLabel("Active session"));
        stack.Children.Add(UI.Card(BuildSessionRow()));

        return scroll;
    }

    private static FrameworkElement BuildSessionRow()
    {
        var iconBox = new Border
        {
            Width = 40, Height = 40, CornerRadius = new CornerRadius(11),
            Background = UI.AccSoft, VerticalAlignment = VerticalAlignment.Center,
            Child = UI.Icon(20, UI.AccText, 2,
                "M4 5H20A1 1 0 0 1 21 6V16A1 1 0 0 1 20 17H4A1 1 0 0 1 3 16V6A1 1 0 0 1 4 5Z", "M8 21h8M12 17v4")
        };
        var textStack = new StackPanel { Orientation = Orientation.Vertical, Spacing = 3, VerticalAlignment = VerticalAlignment.Center };
        textStack.Children.Add(new TextBlock { Text = "This computer", FontSize = 15, FontWeight = FontWeights.SemiBold, Foreground = UI.Text });
        textStack.Children.Add(new TextBlock
        {
            Text = "One agent stays active per account — signing in on another computer signs this one out.",
            FontSize = 13, Foreground = UI.Secondary, TextWrapping = TextWrapping.Wrap
        });
        return UI.HStack(13, iconBox, textStack);
    }

    private void RebuildStatus()
    {
        _statusHost.Children.Clear();

        var color = _linked ? UI.Green : UI.Red;
        var icon = new FontIcon
        {
            Glyph = _linked ? "" : "",   // CheckMark / Error
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
            await http.PostAsync($"http://127.0.0.1:{AppConfig.Port}/api/unlink_account", new StringContent(""));
            await RefreshAccount();
        }
        catch (Exception ex) { Log.Error($"Sign out failed: {ex.Message}"); }
    }
}
