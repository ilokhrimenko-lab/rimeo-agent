using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Shapes;
using RimeoAgent.Config;
using RimeoAgent.Services;
using Windows.Storage.Pickers;

namespace RimeoAgent.Views;

// 1:1 mirror of macOS LibraryTabView: Rekordbox tab + two independent source
// cards (database / exported XML), each with its own enable toggle.
public sealed partial class LibraryPage : Page
{
    private readonly TextBlock _dbAge     = new() { FontSize = 13, Foreground = UI.Dim, Visibility = Visibility.Collapsed };
    private readonly TextBlock _statusMsg = new() { FontSize = 13, Foreground = UI.Secondary, Visibility = Visibility.Collapsed, TextWrapping = TextWrapping.Wrap };
    private readonly StackPanel _stack;

    public LibraryPage()
    {
        InitializeComponent();
        var (scroll, stack) = UI.Page();
        _stack = stack;
        Content = scroll;
        Rebuild();
        RefreshDatabaseAge();
    }

    // Repopulate the stable root. Clearing first detaches the shared _dbAge /
    // _statusMsg TextBlocks before they are re-added, so we never hit WinUI's
    // "element already has a parent" (the bug that broke the source toggles).
    private void Rebuild()
    {
        _stack.Children.Clear();

        _stack.Children.Add(UI.ScreenHeader("Library",
            "Turn on the sources Rimeo reads your tracks from — you can use both at once."));

        _stack.Children.Add(TopTabs());
        _stack.Children.Add(DbCard());
        _stack.Children.Add(XmlCard());
    }

    // ── Top tabs: Rekordbox (active) / Other DJ software (SOON) ──────────────
    private UIElement TopTabs()
    {
        var rekordbox = UI.VStack(12,
            new TextBlock { Text = "Rekordbox", FontSize = 15, FontWeight = FontWeights.Bold, Foreground = UI.Text, HorizontalAlignment = HorizontalAlignment.Center },
            new Border { Height = 2, CornerRadius = new CornerRadius(2), Background = UI.Acc });

        var soonPill = new Border
        {
            Background = UI.Chip,
            CornerRadius = new CornerRadius(6),
            Padding = new Thickness(7, 2, 7, 2),
            Child = new TextBlock { Text = "SOON", FontSize = 10, FontWeight = FontWeights.Bold, CharacterSpacing = 60, Foreground = UI.Dim }
        };
        var otherLabel = UI.HStack(8,
            new TextBlock { Text = "Other DJ software", FontSize = 15, FontWeight = FontWeights.SemiBold, Foreground = UI.Faint, VerticalAlignment = VerticalAlignment.Center },
            soonPill);
        var other = UI.VStack(12, otherLabel, new Border { Height = 2, Background = new SolidColorBrush(Microsoft.UI.Colors.Transparent) });

        var row = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 28, VerticalAlignment = VerticalAlignment.Bottom };
        row.Children.Add(rekordbox);
        row.Children.Add(other);

        var wrap = new StackPanel { Orientation = Orientation.Vertical, Spacing = 0 };
        wrap.Children.Add(row);
        wrap.Children.Add(new Border { Height = 1, Background = UI.Brd });
        return wrap;
    }

    // ── Rekordbox database card ─────────────────────────────────────────────
    private Border DbCard()
    {
        var exists  = AppConfig.Shared.DbExists;
        var enabled = AppConfig.Shared.DbSourceEnabled;

        var toggle = UI.Toggle(enabled, on =>
        {
            AppConfig.Shared.SetDbSourceEnabled(on);
            RekordboxParser.Shared.InvalidateCache();
            Rebuild();
            RefreshDatabaseAge();
        });

        var dotColor    = !enabled ? UI.Dim : (exists ? UI.Green : UI.Red);
        var statusText  = !enabled ? "Off" : (exists ? "Connected" : "Not found");

        var header = SourceHeader("", UI.AccText, UI.AccSoft, "Rekordbox database", dotColor, statusText, dotColor, toggle);

        var body = UI.VStack(14,
            UI.Mono(string.IsNullOrEmpty(AppConfig.Shared.DbPath) ? "—" : AppConfig.Shared.DbPath),
            _dbAge,
            _statusMsg,
            UI.PrimaryButton("Reload Library", Reload_Click));
        body.Opacity = enabled ? 1.0 : 0.5;

        return UI.Card(UI.VStack(14, header, body));
    }

    // ── Exported XML card ───────────────────────────────────────────────────
    private Border XmlCard()
    {
        var xmlPath = AppConfig.Shared.XmlPath;
        var exists  = !string.IsNullOrEmpty(xmlPath) && File.Exists(xmlPath);
        var enabled = AppConfig.Shared.XmlSourceEnabled;

        var toggle = UI.Toggle(enabled, on =>
        {
            AppConfig.Shared.SetXmlSourceEnabled(on);
            RekordboxParser.Shared.InvalidateCache();
            Rebuild();
            RefreshDatabaseAge();
        });

        string statusText;
        SolidColorBrush dotColor;
        if (!enabled)              { statusText = "Off"; dotColor = UI.Dim; }
        else if (exists)           { statusText = "Configured"; dotColor = UI.Green; }
        else if (string.IsNullOrEmpty(xmlPath)) { statusText = "No file selected"; dotColor = UI.Dim; }
        else                       { statusText = "File not found"; dotColor = UI.Red; }

        var header = SourceHeader("", UI.Dim, UI.Chip, "Exported XML file", dotColor, statusText, dotColor, toggle);

        var bodyChildren = new List<UIElement>();
        if (!string.IsNullOrEmpty(xmlPath)) bodyChildren.Add(UI.Mono(xmlPath));
        bodyChildren.Add(UI.SecondaryButton(
            string.IsNullOrEmpty(xmlPath) ? "Select rekordbox.xml" : "Change XML Path",
            PickXml_Click));
        var body = UI.VStack(14, bodyChildren.ToArray());
        body.Opacity = enabled ? 1.0 : 0.5;

        return UI.Card(UI.VStack(14, header, body));
    }

    // ── Source card header: icon + title + status + toggle ──────────────────
    private static Grid SourceHeader(string glyph, SolidColorBrush iconTint, SolidColorBrush iconBg,
        string title, SolidColorBrush dotColor, string statusText, SolidColorBrush statusColor, ToggleSwitch toggle)
    {
        var grid = new Grid { VerticalAlignment = VerticalAlignment.Center };
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });

        var iconBox = new Border
        {
            Width = 40, Height = 40, CornerRadius = new CornerRadius(11), Background = iconBg,
            VerticalAlignment = VerticalAlignment.Center,
            Child = new FontIcon { Glyph = glyph, FontFamily = new FontFamily("Segoe MDL2 Assets"), FontSize = 18, Foreground = iconTint }
        };
        Grid.SetColumn(iconBox, 0);
        grid.Children.Add(iconBox);

        var titleStack = new StackPanel { Orientation = Orientation.Vertical, Spacing = 3, Margin = new Thickness(12, 0, 0, 0), VerticalAlignment = VerticalAlignment.Center };
        titleStack.Children.Add(new TextBlock { Text = title, FontSize = 16, FontWeight = FontWeights.Bold, Foreground = UI.Text });
        titleStack.Children.Add(UI.StatusDot(dotColor, statusText, statusColor));
        Grid.SetColumn(titleStack, 1);
        grid.Children.Add(titleStack);

        toggle.VerticalAlignment = VerticalAlignment.Center;
        Grid.SetColumn(toggle, 2);
        grid.Children.Add(toggle);

        return grid;
    }

    // ── Actions ─────────────────────────────────────────────────────────────
    private void RefreshDatabaseAge()
    {
        var path = AppConfig.Shared.DbPath;
        if (string.IsNullOrEmpty(path) || !File.Exists(path)) { _dbAge.Visibility = Visibility.Collapsed; return; }

        var mdate = File.GetLastWriteTime(path);
        var age = DateTime.Now - mdate;
        string ageLabel = age.TotalHours < 1 ? $"{(int)age.TotalMinutes} min ago"
            : age.TotalDays < 1 ? $"{(int)age.TotalHours} h ago"
            : $"{(int)age.TotalDays} days ago";
        _dbAge.Text = $"Last modified {mdate:dd MMM yyyy, HH:mm}  ·  {ageLabel}";
        _dbAge.Visibility = Visibility.Visible;
    }

    private void Reload_Click(object sender, RoutedEventArgs e)
    {
        _statusMsg.Visibility = Visibility.Visible;
        _statusMsg.Text = "Loading…";
        _ = Task.Run(() =>
        {
            RekordboxParser.Shared.InvalidateCache();
            var result = RekordboxParser.Shared.Parse();
            var source = result.Source ?? (AppConfig.Shared.DbExists ? "db" : "xml");
            DispatcherQueue.TryEnqueue(() =>
            {
                if (result.Tracks.Count > 0)
                    _statusMsg.Text = $"✓ {result.Tracks.Count} tracks, {result.Playlists.Count} playlists  ({source})";
                else
                    _statusMsg.Text = "0 tracks — library source could not be read";
                RefreshDatabaseAge();
            });
        });
    }

    private async void PickXml_Click(object sender, RoutedEventArgs e)
    {
        var picker = new FileOpenPicker();
        WinRT.Interop.InitializeWithWindow.Initialize(picker, MainWindow.Hwnd);
        picker.FileTypeFilter.Add(".xml");
        picker.SuggestedStartLocation = PickerLocationId.DocumentsLibrary;

        var file = await picker.PickSingleFileAsync();
        if (file == null) return;

        AppConfig.Shared.SetXmlPath(file.Path);
        if (!AppConfig.Shared.XmlSourceEnabled) AppConfig.Shared.SetXmlSourceEnabled(true);
        RekordboxParser.Shared.InvalidateCache();
        Rebuild();
        Reload_Click(sender, e);
    }
}
