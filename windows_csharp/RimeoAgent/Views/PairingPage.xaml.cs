using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media.Imaging;
using System.Net.Http;
using System.Text.Json;
using RimeoAgent.Config;

namespace RimeoAgent.Views;

public sealed partial class PairingPage : Page
{
    public PairingPage()
    {
        InitializeComponent();
        _ = LoadPairingInfo();
    }

    private async Task LoadPairingInfo()
    {
        try
        {
            using var http = new HttpClient();
            var json = await http.GetStringAsync($"http://127.0.0.1:{AppConfig.Port}/api/pairing_info");
            var obj  = JsonSerializer.Deserialize<Dictionary<string, JsonElement>>(json);
            if (obj == null) return;

            var code   = obj.TryGetValue("code",   out var c) ? c.GetString() ?? "—" : "—";
            var qrUrl  = obj.TryGetValue("qr_url", out var q) ? q.GetString() ?? "" : "";
            var locUrl = obj.TryGetValue("local_url", out var l) ? l.GetString() ?? "" : "";

            PairingCodeLabel.Text = code;
            QrUrlLabel.Text       = locUrl;

            if (!string.IsNullOrEmpty(qrUrl))
            {
                var imgBytes = await http.GetByteArrayAsync(qrUrl);
                using var ms = new MemoryStream(imgBytes);
                var bmp = new BitmapImage();
                await bmp.SetSourceAsync(ms.AsRandomAccessStream());
                QrImage.Source = bmp;
            }
        }
        catch (Exception ex) { Log.Error($"PairingPage load failed: {ex.Message}"); }
    }

    private void GenCode_Click(object sender, RoutedEventArgs e) => _ = LoadPairingInfo();
}
