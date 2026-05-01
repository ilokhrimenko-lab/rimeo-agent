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
        _searchBox = new TextBox
        {
            PlaceholderText = "Search...",
            Width = 320
        };
        _searchBox.TextChanged += SearchBox_TextChanged;

        _statusLabel = new TextBlock
        {
            VerticalAlignment = VerticalAlignment.Center,
            Foreground = new Microsoft.UI.Xaml.Media.SolidColorBrush(Microsoft.UI.Colors.Gray),
            FontSize = 12
        };

        _trackList = new ListView
        {
            SelectionMode = ListViewSelectionMode.Single,
            IsItemClickEnabled = true
        };

        Content = CreateLayout();
        _ = LoadLibrary();
    }

    private async Task LoadLibrary()
    {
        _statusLabel.Text = "Loading...";
        var lib = await Task.Run(() => RekordboxParser.Shared.Parse());
        _allTracks = lib.Tracks.Select(t => new TrackRow(t)).ToList();
        ApplyFilter(_searchBox.Text);
        _statusLabel.Text = $"{lib.Tracks.Count} tracks";
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
        {
            _trackList.Items.Add(CreateTrackRow(track));
        }
    }

    private void SearchBox_TextChanged(object sender, TextChangedEventArgs e) =>
        ApplyFilter(_searchBox.Text);

    private void Reload_Click(object sender, Microsoft.UI.Xaml.RoutedEventArgs e)
    {
        RekordboxParser.Shared.InvalidateCache();
        _ = LoadLibrary();
    }

    private Grid CreateLayout()
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

        var reloadButton = new Button { Content = "Reload" };
        reloadButton.Click += Reload_Click;

        var toolbar = new StackPanel
        {
            Orientation = Orientation.Horizontal,
            Spacing = 8,
            Margin = new Thickness(0, 0, 0, 8)
        };
        toolbar.Children.Add(_searchBox);
        toolbar.Children.Add(reloadButton);
        toolbar.Children.Add(_statusLabel);
        Grid.SetRow(toolbar, 1);
        root.Children.Add(toolbar);

        Grid.SetRow(_trackList, 2);
        root.Children.Add(_trackList);

        return root;
    }

    private static Grid CreateTrackRow(TrackRow track)
    {
        var grid = new Grid { Padding = new Thickness(4, 2, 4, 2) };
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(200) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(80) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(60) });

        var title = new TextBlock
        {
            Text = track.Title,
            FontWeight = Microsoft.UI.Text.FontWeights.SemiBold,
            TextTrimming = TextTrimming.CharacterEllipsis
        };
        var artist = new TextBlock
        {
            Text = track.Artist,
            Foreground = new SolidColorBrush(Microsoft.UI.Colors.Gray),
            FontSize = 12,
            TextTrimming = TextTrimming.CharacterEllipsis
        };
        var titleStack = new StackPanel();
        titleStack.Children.Add(title);
        titleStack.Children.Add(artist);
        Grid.SetColumn(titleStack, 0);
        grid.Children.Add(titleStack);

        var genre = new TextBlock
        {
            Text = track.Genre,
            Foreground = new SolidColorBrush(Microsoft.UI.Colors.Gray),
            FontSize = 12,
            TextTrimming = TextTrimming.CharacterEllipsis,
            VerticalAlignment = VerticalAlignment.Center
        };
        Grid.SetColumn(genre, 1);
        grid.Children.Add(genre);

        var key = new TextBlock
        {
            Text = track.Key,
            VerticalAlignment = VerticalAlignment.Center,
            HorizontalAlignment = HorizontalAlignment.Center,
            FontSize = 12
        };
        Grid.SetColumn(key, 2);
        grid.Children.Add(key);

        var bpm = new TextBlock
        {
            Text = track.BpmDisplay,
            VerticalAlignment = VerticalAlignment.Center,
            HorizontalAlignment = HorizontalAlignment.Right,
            FontSize = 12
        };
        Grid.SetColumn(bpm, 3);
        grid.Children.Add(bpm);

        return grid;
    }
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
