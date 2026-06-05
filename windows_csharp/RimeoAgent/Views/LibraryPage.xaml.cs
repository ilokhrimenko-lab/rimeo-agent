using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using RimeoAgent.Config;
using RimeoAgent.Services;
using Windows.Storage.Pickers;

namespace RimeoAgent.Views;

// 1:1 mirror of macOS LibraryTabView: Rekordbox database status + XML alternative.
public sealed partial class LibraryPage : Page
{
    private readonly TextBlock _dbAge      = new() { FontSize = 12, Foreground = UI.Dim, Visibility = Visibility.Collapsed };
    private readonly TextBlock _statusMsg  = new() { FontSize = 13, Foreground = UI.Dim, Visibility = Visibility.Collapsed, TextWrapping = TextWrapping.Wrap };
    private readonly StackPanel _xmlCardHost = new() { Orientation = Orientation.Vertical, Spacing = 10 };

    public LibraryPage()
    {
        InitializeComponent();
        Content = Build();
        RefreshDatabaseAge();
    }

    private ScrollViewer Build()
    {
        var (scroll, stack) = UI.Page();

        stack.Children.Add(UI.Heading("Library"));
        stack.Children.Add(UI.Subtitle("Reads your Rekordbox library automatically and serves tracks to rimeo.app."));

        stack.Children.Add(UI.SectionLabel("Rekordbox database"));

        var dbExists = AppConfig.Shared.DbExists;
        var dbInner = UI.VStack(10,
            UI.StatusRow(dbExists, dbExists ? "Connected" : "Not found"),
            new TextBlock
            {
                Text = string.IsNullOrEmpty(AppConfig.Shared.DbPath) ? "—" : AppConfig.Shared.DbPath,
                FontSize = 11, Foreground = UI.Dim, TextTrimming = TextTrimming.CharacterEllipsis
            },
            _dbAge,
            _statusMsg,
            UI.PrimaryButton("Reload Library", Reload_Click)
        );
        stack.Children.Add(UI.Card(dbInner));

        stack.Children.Add(UI.SectionLabel("Rekordbox XML (alternative)"));
        BuildXmlCardInner();
        stack.Children.Add(UI.Card(_xmlCardHost));

        return scroll;
    }

    private void BuildXmlCardInner()
    {
        _xmlCardHost.Children.Clear();

        var xmlPath = AppConfig.Shared.XmlPath;
        var xmlExists = !string.IsNullOrEmpty(xmlPath) && File.Exists(xmlPath);

        string statusText = xmlExists ? "XML configured" : (string.IsNullOrEmpty(xmlPath) ? "Not configured" : "File not found");
        var row = UI.StatusRow(xmlExists, statusText, okColor: UI.Green, badColor: UI.Dim);
        _xmlCardHost.Children.Add(row);

        if (!string.IsNullOrEmpty(xmlPath))
        {
            _xmlCardHost.Children.Add(new TextBlock
            {
                Text = xmlPath, FontSize = 11, Foreground = UI.Dim, TextTrimming = TextTrimming.CharacterEllipsis
            });
        }

        _xmlCardHost.Children.Add(UI.PrimaryButton(
            string.IsNullOrEmpty(xmlPath) ? "Select rekordbox.xml" : "Change XML Path",
            PickXml_Click));
    }

    private void RefreshDatabaseAge()
    {
        var path = AppConfig.Shared.DbPath;
        if (string.IsNullOrEmpty(path) || !File.Exists(path)) { _dbAge.Visibility = Visibility.Collapsed; return; }

        var mdate = File.GetLastWriteTime(path);
        var age = DateTime.Now - mdate;
        string ageLabel = age.TotalHours < 1 ? $"{(int)age.TotalMinutes} min ago"
            : age.TotalDays < 1 ? $"{(int)age.TotalHours} h ago"
            : $"{(int)age.TotalDays} days ago";
        _dbAge.Text = $"Last modified: {mdate:dd MMM yyyy, HH:mm}  ·  {ageLabel}";
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
        RekordboxParser.Shared.InvalidateCache();
        BuildXmlCardInner();
        Reload_Click(sender, e);
    }
}
