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
    // State (plain values) + references to the CURRENT rendered blocks. The blocks
    // are recreated fresh on every Rebuild — never reused across trees — so we never
    // hit WinUI's "element already has a parent". The references only exist so async
    // work (Reload / age refresh) can live-update whatever block is on screen now.
    private string _dbAgeText = "";
    private string _statusText = "";
    private string? _masterDbError;
    private TextBlock? _dbAgeBlock;
    private TextBlock? _statusBlock;
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

    // Repopulate the stable root. Every child (incl. the age/status blocks) is
    // created fresh here — nothing is reused across rebuilds — so re-adding can
    // never hit WinUI's "element already has a parent". Always call this deferred
    // (DispatcherQueue) from event handlers, never synchronously inside them.
    private void Rebuild()
    {
        _stack.Children.Clear();

        _stack.Children.Add(UI.ScreenHeader("Library",
            "Turn on the sources Rimeo reads your tracks from — you can use both at once."));

        _stack.Children.Add(TopTabs());
        if (_masterDbError != null) _stack.Children.Add(MasterDbWarning(_masterDbError));
        _stack.Children.Add(DbCard());
        _stack.Children.Add(XmlCard());
    }

    // Карточка «master.db не читается» — паритет с macOS. Без неё единственным следом
    // сломанной базы была строка «0 tracks…» под кнопкой Reload: человек не понимал,
    // что делать, хотя выход есть — экспортировать XML и включить его ниже.
    private static Border MasterDbWarning(string err)
    {
        var head = UI.HStack(8,
            UI.Icon(16, UI.Amber, 2, "M12 4.5 2.8 20h18.4L12 4.5Z", "M12 10v4.5", "M12 17.4h.01"),
            new TextBlock { Text = "master.db could not be read", FontSize = 14, FontWeight = FontWeights.SemiBold, Foreground = UI.Amber, VerticalAlignment = VerticalAlignment.Center });

        var detail = new TextBlock
        {
            Text = err.Length > 200 ? err[..200] : err,
            FontSize = 12, FontFamily = new FontFamily("Consolas"), Foreground = UI.Dim,
            TextWrapping = TextWrapping.Wrap, MaxLines = 3, TextTrimming = TextTrimming.CharacterEllipsis
        };

        var hint = new TextBlock
        {
            Text = "Rimeo could not open the Rekordbox database. As a workaround, export XML from Rekordbox and enable it below.",
            FontSize = 13, Foreground = UI.Secondary, TextWrapping = TextWrapping.Wrap
        };

        return UI.Card(UI.VStack(8, head, hint, detail), 18);
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
            // Defer to the next tick: rebuilding clears the tree that holds this
            // very ToggleSwitch, and doing that inside its own Toggled handler
            // crashes WinUI. Let the event finish first.
            DispatcherQueue.TryEnqueue(() => { Rebuild(); RefreshDatabaseAge(); });
        });

        var dotColor    = !enabled ? UI.Dim : (exists ? UI.Green : UI.Red);
        var statusText  = !enabled ? "Off" : (exists ? "Connected" : "Not found");

        var header = SourceHeader(DbIcon, UI.AccText, UI.AccSoft, "Rekordbox database", dotColor, statusText, dotColor, toggle);

        _dbAgeBlock = new TextBlock
        {
            FontSize = 13, Foreground = UI.Dim, TextWrapping = TextWrapping.Wrap,
            Text = _dbAgeText,
            Visibility = string.IsNullOrEmpty(_dbAgeText) ? Visibility.Collapsed : Visibility.Visible
        };
        _statusBlock = new TextBlock
        {
            FontSize = 13, Foreground = UI.Secondary, TextWrapping = TextWrapping.Wrap,
            Text = _statusText,
            Visibility = string.IsNullOrEmpty(_statusText) ? Visibility.Collapsed : Visibility.Visible
        };

        var body = UI.VStack(14,
            UI.MonoPath(string.IsNullOrEmpty(AppConfig.Shared.DbPath) ? "—" : AppConfig.Shared.DbPath),
            _dbAgeBlock,
            _statusBlock,
            UI.PrimaryButton("Reload library", Reload_Click));
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
            // Defer to the next tick: rebuilding clears the tree that holds this
            // very ToggleSwitch, and doing that inside its own Toggled handler
            // crashes WinUI. Let the event finish first.
            DispatcherQueue.TryEnqueue(() => { Rebuild(); RefreshDatabaseAge(); });
        });

        string statusText;
        SolidColorBrush dotColor;
        if (!enabled)              { statusText = "Off"; dotColor = UI.Dim; }
        else if (exists)           { statusText = "Configured"; dotColor = UI.Green; }
        else if (string.IsNullOrEmpty(xmlPath)) { statusText = "No file selected"; dotColor = UI.Dim; }
        else                       { statusText = "File not found"; dotColor = UI.Red; }

        var header = SourceHeader(XmlIcon, UI.Dim, UI.Chip, "Exported XML file", dotColor, statusText, dotColor, toggle);

        var bodyChildren = new List<UIElement>();
        if (!string.IsNullOrEmpty(xmlPath)) bodyChildren.Add(UI.MonoPath(xmlPath));
        bodyChildren.Add(UI.SecondaryButton(
            string.IsNullOrEmpty(xmlPath) ? "Select rekordbox.xml" : "Change XML path",
            PickXml_Click));
        var body = UI.VStack(14, bodyChildren.ToArray());
        body.Opacity = enabled ? 1.0 : 0.5;

        return UI.Card(UI.VStack(14, header, body));
    }

    // ── Source card header: icon + title + status + toggle ──────────────────
    // Иконки источников: векторные пути на 24×24, как везде в UI (`UI.Icon`).
    // Раньше это были единственные FontIcon/Segoe MDL2 в интерфейсе — чужие по
    // стилистике штриховым иконкам остальных экранов; семантика взята с macOS
    // (цилиндр БД / текстовый документ).
    private static readonly string[] DbIcon =
        { "M12 7.5c4.4 0 8-1.1 8-2.5S16.4 2.5 12 2.5 4 3.6 4 5s3.6 2.5 8 2.5Z",
          "M20 5v14c0 1.4-3.6 2.5-8 2.5S4 20.4 4 19V5", "M20 12c0 1.4-3.6 2.5-8 2.5S4 13.4 4 12" };
    private static readonly string[] XmlIcon =
        { "M6 2.5h7L19 8v13.5H6z", "M13 2.5V8h6", "M9 13h6M9 17h4" };

    private static Grid SourceHeader(string[] iconPaths, SolidColorBrush iconTint, SolidColorBrush iconBg,
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
            Child = UI.Icon(18, iconTint, 2, iconPaths)
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
        if (string.IsNullOrEmpty(path) || !File.Exists(path))
        {
            _dbAgeText = "";
        }
        else
        {
            var mdate = File.GetLastWriteTime(path);
            var age = DateTime.Now - mdate;
            string ageLabel = age.TotalHours < 1 ? $"{(int)age.TotalMinutes} min ago"
                : age.TotalDays < 1 ? $"{(int)age.TotalHours} h ago"
                : $"{(int)age.TotalDays} days ago";
            _dbAgeText = $"Last modified {mdate:dd MMM yyyy, HH:mm}  ·  {ageLabel}";
        }

        if (_dbAgeBlock != null)
        {
            _dbAgeBlock.Text = _dbAgeText;
            _dbAgeBlock.Visibility = string.IsNullOrEmpty(_dbAgeText) ? Visibility.Collapsed : Visibility.Visible;
        }
    }

    private void SetStatus(string text)
    {
        _statusText = text;
        if (_statusBlock != null)
        {
            _statusBlock.Text = text;
            _statusBlock.Visibility = string.IsNullOrEmpty(text) ? Visibility.Collapsed : Visibility.Visible;
        }
    }

    private void Reload_Click(object sender, RoutedEventArgs e)
    {
        SetStatus("Loading…");
        _ = Task.Run(() =>
        {
            RekordboxParser.Shared.InvalidateCache();
            var result = RekordboxParser.Shared.Parse();
            var err    = RekordboxParser.Shared.MasterDbError;
            var source = result.Source ?? (AppConfig.Shared.DbExists ? "db" : "xml");
            DispatcherQueue.TryEnqueue(() =>
            {
                // Три исхода, а не два: пустой Rekordbox — это НЕ ошибка чтения.
                // Раньше человек с пустой библиотекой получал ложную тревогу
                // «library source could not be read» (macOS различает их).
                if (result.Tracks.Count > 0)
                    SetStatus($"✓ {result.Tracks.Count} tracks, {result.Playlists.Count} playlists  ({source})");
                else if (err != null)
                    SetStatus("0 tracks — library source could not be read");
                else
                    SetStatus("0 tracks loaded");

                _masterDbError = err;
                Rebuild();
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
