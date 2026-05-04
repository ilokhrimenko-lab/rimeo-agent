using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Media;
using RimeoAgent.Models;
using RimeoAgent.Services;

namespace RimeoAgent.Views;

public sealed partial class LibraryPage : Page
{
    private List<TrackRow> _allTracks = new();
    private readonly TextBox _searchBox;
    private readonly TextBlock _statusLabel;
    private readonly ListView _trackList;

    public LibraryPage()
    {
        InitializeComponent();

        _searchBox = new TextBox { PlaceholderText = "Search...", Width = 320 };
        _searchBox.TextChanged += SearchBox_TextChanged;

        _statusLabel = new TextBlock
        {
            VerticalAlignment = VerticalAlignment.Center,
            Foreground = new SolidColorBrush(Microsoft.UI.Colors.Gray),
            FontSize = 12
        };

        _trackList = new ListView
        {
            SelectionMode = ListViewSelectionMode.Single,
            IsItemClickEnabled = true
        };

        Content = BuildLayout();
        _ = LoadLibrary();
    }

    private async Task LoadLibrary()
    {
        try
        {
            Log.Info("LoadLibrary: starting parse");
            _statusLabel.Text = "Loading...";
            var lib = await Task.Run(() => RekordboxParser.Shared.Parse());
            Log.Info($"LoadLibrary: parse complete, {lib.Tracks.Count} tracks");

            DispatcherQueue.TryEnqueue(() =>
            {
                _allTracks = lib.Tracks.Select(t => new TrackRow(t)).ToList();
                ApplyFilter(_searchBox.Text);
                _statusLabel.Text = $"{lib.Tracks.Count} tracks";
            });
        }
        catch (Exception ex)
        {
            Log.Error($"LoadLibrary failed: {ex}");
            DispatcherQueue.TryEnqueue(() => _statusLabel.Text = "Failed to load library");
        }
    }

    private void ApplyFilter(string q)
    {
        var filtered = string.IsNullOrWhiteSpace(q)
            ? _allTracks
            : _allTracks.Where(t =>
                t.Title.Contains(q, StringComparison.OrdinalIgnoreCase) ||
                t.Artist.Contains(q, StringComparison.OrdinalIgnoreCase) ||
                t.Genre.Contains(q, StringComparison.OrdinalIgnoreCase)).ToList();
        _trackList.Items.Clear();
        foreach (var track in filtered)
            _trackList.Items.Add(BuildTrackRow(track));
    }

    private void SearchBox_TextChanged(object sender, TextChangedEventArgs e) =>
        ApplyFilter(_searchBox.Text);

    private void Reload_Click(object sender, RoutedEventArgs e)
    {
        RekordboxParser.Shared.InvalidateCache();
        _ = LoadLibrary();
    }

    private Grid BuildLayout()
    {
        var root = new Grid { Margin = new Thickness(16) };
        root.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        root.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        root.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });

        var title = new TextBlock
        {
            Text = "Library",
            FontSize = 28,
            FontWeight = Microsoft.UI.Text.FontWeights.SemiBold,
            Margin = new Thickness(0, 0, 0, 8)
        };
        Grid.SetRow(title, 0);
        root.Children.Add(title);

        var reloadBtn = new Button { Content = "Reload" };
        reloadBtn.Click += Reload_Click;

        var toolbar = new StackPanel
        {
            Orientation = Orientation.Horizontal,
            Spacing = 8,
            Margin = new Thickness(0, 0, 0, 8)
        };
        toolbar.Children.Add(_searchBox);
        toolbar.Children.Add(reloadBtn);
        toolbar.Children.Add(_statusLabel);
        Grid.SetRow(toolbar, 1);
        root.Children.Add(toolbar);

        Grid.SetRow(_trackList, 2);
        root.Children.Add(_trackList);

        return root;
    }

    private static Grid BuildTrackRow(TrackRow t)
    {
        var grid = new Grid { Padding = new Thickness(4, 2, 4, 2) };
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(200) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(80) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(60) });

        var titleStack = new StackPanel();
        titleStack.Children.Add(new TextBlock
        {
            Text = t.Title,
            FontWeight = Microsoft.UI.Text.FontWeights.SemiBold,
            TextTrimming = TextTrimming.CharacterEllipsis
        });
        titleStack.Children.Add(new TextBlock
        {
            Text = t.Artist,
            Foreground = new SolidColorBrush(Microsoft.UI.Colors.Gray),
            FontSize = 12,
            TextTrimming = TextTrimming.CharacterEllipsis
        });
        Grid.SetColumn(titleStack, 0);
        grid.Children.Add(titleStack);

        Grid.SetColumn(MakeCell(t.Genre), 1); grid.Children.Add(MakeCell(t.Genre));
        Grid.SetColumn(MakeCell(t.Key, center: true), 2); grid.Children.Add(MakeCell(t.Key, center: true));
        Grid.SetColumn(MakeCell(t.BpmDisplay, right: true), 3); grid.Children.Add(MakeCell(t.BpmDisplay, right: true));

        return grid;
    }

    private static TextBlock MakeCell(string text, bool center = false, bool right = false) => new()
    {
        Text = text,
        Foreground = new SolidColorBrush(Microsoft.UI.Colors.Gray),
        FontSize = 12,
        TextTrimming = TextTrimming.CharacterEllipsis,
        VerticalAlignment = VerticalAlignment.Center,
        HorizontalAlignment = center ? HorizontalAlignment.Center : right ? HorizontalAlignment.Right : HorizontalAlignment.Left
    };
}

public class TrackRow(Track t)
{
    public string Title      { get; } = t.Title;
    public string Artist     { get; } = t.Artist;
    public string Genre      { get; } = t.Genre;
    public string Key        { get; } = t.Key;
    public string BpmDisplay { get; } = t.Bpm > 0 ? t.Bpm.ToString("F0") : "—";
    public string Location   { get; } = t.Location;
    public string Id         { get; } = t.Id;
}
