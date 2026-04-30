using Microsoft.UI.Xaml.Controls;
using RimeoAgent.Models;
using RimeoAgent.Services;

namespace RimeoAgent.Views;

public sealed partial class LibraryPage : Page
{
    private List<TrackRow> _allTracks = new();

    public LibraryPage()
    {
        InitializeComponent();
        _ = LoadLibrary();
    }

    private async Task LoadLibrary()
    {
        StatusLabel.Text = "Loading…";
        var lib = await Task.Run(() => RekordboxParser.Shared.Parse());
        _allTracks = lib.Tracks.Select(t => new TrackRow(t)).ToList();
        ApplyFilter(SearchBox.Text);
        StatusLabel.Text = $"{lib.Tracks.Count} tracks";
    }

    private void ApplyFilter(string q)
    {
        var filtered = string.IsNullOrWhiteSpace(q)
            ? _allTracks
            : _allTracks.Where(t =>
                t.Title.Contains(q, StringComparison.OrdinalIgnoreCase) ||
                t.Artist.Contains(q, StringComparison.OrdinalIgnoreCase) ||
                t.Genre.Contains(q, StringComparison.OrdinalIgnoreCase)).ToList();
        TrackList.ItemsSource = filtered;
    }

    private void SearchBox_TextChanged(object sender, TextChangedEventArgs e) =>
        ApplyFilter(SearchBox.Text);

    private void Reload_Click(object sender, Microsoft.UI.Xaml.RoutedEventArgs e)
    {
        RekordboxParser.Shared.InvalidateCache();
        _ = LoadLibrary();
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
