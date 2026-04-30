using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using System.Net.Http;
using System.Text;
using System.Text.Json;
using RimeoAgent.Config;
using RimeoAgent.Services;

namespace RimeoAgent.Views;

public sealed partial class AccountPage : Page
{
    public AccountPage()
    {
        InitializeComponent();
        _ = Refresh();

        AgentIdLabel.Text  = AppConfig.Shared.AgentId;
        AgentUrlLabel.Text = AppConfig.Shared.LocalAgentUrl();
        VersionLabel.Text  = AppConfig.Shared.DisplayVersion;
    }

    private async Task Refresh()
    {
        try
        {
            using var http = new HttpClient();
            var json = await http.GetStringAsync($"http://127.0.0.1:{AppConfig.Port}/api/account");
            var obj  = JsonSerializer.Deserialize<Dictionary<string, JsonElement>>(json);
            if (obj == null) return;

            var isLinked  = obj.TryGetValue("is_linked", out var lEl) && lEl.GetBoolean();
            var email     = obj.TryGetValue("cloud_user_id", out var eEl) ? eEl.GetString() ?? "" : "";
            var tunnelUrl = obj.TryGetValue("tunnel_url",    out var tEl) ? tEl.GetString() ?? "" : "";
            var tunnelOn  = obj.TryGetValue("tunnel_active", out var taEl) && taEl.GetBoolean();
            var cfFound   = obj.TryGetValue("cloudflared_found", out var cfEl) && cfEl.GetBoolean();

            LinkStatusLabel.Text = isLinked ? "✓ Linked to rimeo.app" : "Not linked";
            EmailLabel.Text      = isLinked && !string.IsNullOrEmpty(email) ? email : "";
            LinkForm.Visibility  = isLinked ? Visibility.Collapsed  : Visibility.Visible;
            UnlinkBtn.Visibility = isLinked ? Visibility.Visible    : Visibility.Collapsed;

            TunnelStatusLabel.Text = tunnelOn ? "Active" : (cfFound ? "Stopped" : "cloudflared not found");
            TunnelUrlLabel.Text    = tunnelUrl;
        }
        catch { }
    }

    private async void Link_Click(object sender, RoutedEventArgs e)
    {
        var token = TokenBox.Text.Trim();
        if (string.IsNullOrEmpty(token)) return;
        try
        {
            using var http = new HttpClient();
            var body = new StringContent(JsonSerializer.Serialize(new { token }), Encoding.UTF8, "application/json");
            var resp = await http.PostAsync($"http://127.0.0.1:{AppConfig.Port}/api/link_account", body);
            await Refresh();
        }
        catch (Exception ex) { Log.Error($"Link failed: {ex.Message}"); }
    }

    private async void Unlink_Click(object sender, RoutedEventArgs e)
    {
        using var http = new HttpClient();
        await http.PostAsync($"http://127.0.0.1:{AppConfig.Port}/api/unlink_account",
            new StringContent(""));
        await Refresh();
    }

    private async void TunnelStart_Click(object sender, RoutedEventArgs e)
    {
        using var http = new HttpClient();
        await http.PostAsync($"http://127.0.0.1:{AppConfig.Port}/api/tunnel/start",
            new StringContent(""));
        await Task.Delay(2000);
        await Refresh();
    }

    private async void TunnelStop_Click(object sender, RoutedEventArgs e)
    {
        using var http = new HttpClient();
        await http.PostAsync($"http://127.0.0.1:{AppConfig.Port}/api/tunnel/stop",
            new StringContent(""));
        await Refresh();
    }
}
