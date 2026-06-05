using System.Diagnostics;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using RimeoAgent.Config;
using RimeoAgent.Models;
using RimeoAgent.Services;

namespace RimeoAgent.Views;

// 1:1 mirror of macOS PairingTabView: web-browser steps + iOS-app steps.
public sealed partial class PairingPage : Page
{
    public PairingPage()
    {
        InitializeComponent();
        Content = Build();
    }

    private ScrollViewer Build()
    {
        var (scroll, stack) = UI.Page();

        stack.Children.Add(UI.Heading("Pairing"));

        // WEB BROWSER
        stack.Children.Add(UI.SectionLabel("Web browser"));
        stack.Children.Add(UI.Card(UI.VStack(10,
            UI.Body("To listen to your music from any web browser:"),
            UI.StepsBox(
                UI.StepRow("1", "Open rimeo.app and log in to your account."),
                UI.StepRow("2", "Go to Account → click «Generate Link Token»."),
                UI.StepRow("3", "Enter the token in the Agent's Account tab and press Link.")
            ),
            BrowserStatus()
        )));

        // iOS APP
        stack.Children.Add(UI.SectionLabel("iOS app"));
        stack.Children.Add(UI.Card(UI.VStack(10,
            UI.Body("To use the Rimeo iOS app on your iPhone:"),
            UI.StepsBox(
                UI.StepRow("1", "Open the Rimeo iOS app on your iPhone."),
                UI.StepRow("2", "Tap «Pair» and scan the QR code shown on rimeo.app."),
                UI.StepRow("3", "Log in to your account — your library will sync automatically.")
            ),
            UI.SecondaryButton("Open rimeo.app", OpenRimeoApp_Click, fg: UI.Acc)
        )));

        return scroll;
    }

    private Border BrowserStatus()
    {
        var linked = AppState.Shared.CloudLinked;
        var who = !string.IsNullOrEmpty(AppState.Shared.CloudEmail)
            ? AppState.Shared.CloudEmail
            : DataStore.Shared.Data.CloudUrl;

        var dot = new Microsoft.UI.Xaml.Shapes.Ellipse
        {
            Width = 10, Height = 10,
            Fill = linked ? UI.Green : UI.Dim,
            VerticalAlignment = VerticalAlignment.Center
        };
        var label = new TextBlock
        {
            Text = linked ? $"Connected as {who}" : "Not connected — link your agent in the Account tab",
            FontSize = 12,
            Foreground = linked ? UI.Green : UI.Dim,
            VerticalAlignment = VerticalAlignment.Center,
            TextWrapping = TextWrapping.Wrap
        };
        var row = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6, VerticalAlignment = VerticalAlignment.Center };
        row.Children.Add(dot);
        row.Children.Add(label);

        return new Border
        {
            Background = linked ? new Microsoft.UI.Xaml.Media.SolidColorBrush(UI.Hex("#052e16")) : new Microsoft.UI.Xaml.Media.SolidColorBrush(UI.Hex("#1c1917")),
            BorderBrush = linked ? new Microsoft.UI.Xaml.Media.SolidColorBrush(UI.Hex("#166534")) : UI.Brd,
            BorderThickness = new Thickness(1),
            CornerRadius = new CornerRadius(12),
            Padding = new Thickness(12, 6, 12, 6),
            HorizontalAlignment = HorizontalAlignment.Left,
            Child = row
        };
    }

    private void OpenRimeoApp_Click(object sender, RoutedEventArgs e)
    {
        try { Process.Start(new ProcessStartInfo(AppConfig.RimeoAppUrl) { UseShellExecute = true }); }
        catch (Exception ex) { Log.Error($"Open rimeo.app failed: {ex.Message}"); }
    }
}
