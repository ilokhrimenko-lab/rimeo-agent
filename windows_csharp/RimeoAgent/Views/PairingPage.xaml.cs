using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using RimeoAgent.Services;

namespace RimeoAgent.Views;

// Devices page (login model): everything signed in to the account connects
// automatically — no pairing codes, no QR. Mirrors macOS PairingTabView.
public sealed partial class PairingPage : Page
{
    private static readonly string[] MonitorIcon =
        { "M4 5H20A1 1 0 0 1 21 6V16A1 1 0 0 1 20 17H4A1 1 0 0 1 3 16V6A1 1 0 0 1 4 5Z", "M8 21h8M12 17v4" };
    private static readonly string[] GlobeIcon =
        { "M12 21a9 9 0 1 0 0-18 9 9 0 0 0 0 18Z", "M3 12h18M12 3c2.5 2.5 2.5 15 0 18M12 3c-2.5 2.5-2.5 15 0 18" };
    private static readonly string[] PhoneIcon =
        { "M9 2H15A2 2 0 0 1 17 4V20A2 2 0 0 1 15 22H9A2 2 0 0 1 7 20V4A2 2 0 0 1 9 2Z", "M11 18h2" };

    public PairingPage()
    {
        InitializeComponent();
        Content = Build();
    }

    private ScrollViewer Build()
    {
        var (scroll, stack) = UI.Page();

        stack.Children.Add(UI.ScreenHeader("Devices",
            "Everything signed in to your Rimeo account connects automatically — no codes, no QR."));

        stack.Children.Add(UI.SectionLabel("Connected"));

        var list = new StackPanel { Orientation = Orientation.Vertical, Spacing = 0 };
        list.Children.Add(DeviceRow(MonitorIcon, "This computer", "Your library lives here", "Active", true));
        list.Children.Add(Divider());

        var linked = AppState.Shared.CloudLinked;
        list.Children.Add(DeviceRow(GlobeIcon, "rimeo.app", "Player in your account",
            linked ? "Connected" : "Not connected", linked));
        list.Children.Add(Divider());

        list.Children.Add(DeviceRow(PhoneIcon, "Your phone", "Sign in with the Rimeo app to connect",
            "Not signed in", false));

        stack.Children.Add(new Border
        {
            Background = UI.Surf, BorderBrush = UI.CardBrd, BorderThickness = new Thickness(1),
            CornerRadius = new CornerRadius(18), Child = list
        });

        return scroll;
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
}
