using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Shapes;
using Windows.UI;

namespace RimeoAgent.Views;

/// <summary>
/// Shared dark-theme palette and component factories — a 1:1 mirror of the macOS
/// agent's ContentView.swift shared components (SectionLabel, SurfaceCard, StatusBadge,
/// StepRow, RimeoButton) so the Windows pages match button-for-button and text-for-text.
/// </summary>
internal static class UI
{
    // Palette (matches macOS ColorPalette in ContentView.swift)
    public static readonly Color BgColor    = Hex("#0b1120");
    public static readonly Color SurfColor  = Hex("#151c2c");
    public static readonly Color AccColor   = Hex("#3b82f6");
    public static readonly Color TextColor  = Hex("#f1f3f4");
    public static readonly Color BrdColor   = Hex("#1e293b");
    public static readonly Color DimColor   = Hex("#64748b");
    public static readonly Color GreenColor = Hex("#4ade80");
    public static readonly Color RedColor   = Hex("#f87171");
    public static readonly Color AmberColor = Hex("#f59e0b");

    public static SolidColorBrush Bg    => new(BgColor);
    public static SolidColorBrush Surf  => new(SurfColor);
    public static SolidColorBrush Acc   => new(AccColor);
    public static SolidColorBrush Text  => new(TextColor);
    public static SolidColorBrush Brd   => new(BrdColor);
    public static SolidColorBrush Dim   => new(DimColor);
    public static SolidColorBrush Green => new(GreenColor);
    public static SolidColorBrush Red   => new(RedColor);
    public static SolidColorBrush Amber => new(AmberColor);
    public static SolidColorBrush White => new(Microsoft.UI.Colors.White);

    public static Color Hex(string hex)
    {
        var h = hex.TrimStart('#');
        byte r = Convert.ToByte(h.Substring(0, 2), 16);
        byte g = Convert.ToByte(h.Substring(2, 2), 16);
        byte b = Convert.ToByte(h.Substring(4, 2), 16);
        return Color.FromArgb(255, r, g, b);
    }

    // Page scaffold: a dark ScrollViewer with a left-aligned vertical stack.
    public static (ScrollViewer scroll, StackPanel stack) Page(double spacing = 12)
    {
        var stack = new StackPanel
        {
            Orientation = Orientation.Vertical,
            Spacing = spacing,
            Margin = new Thickness(36, 32, 36, 24),
            HorizontalAlignment = HorizontalAlignment.Stretch
        };
        var scroll = new ScrollViewer
        {
            Content = stack,
            Background = Bg,
            VerticalScrollBarVisibility = ScrollBarVisibility.Auto,
            HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled
        };
        return (scroll, stack);
    }

    public static TextBlock Heading(string text) => new()
    {
        Text = text,
        FontSize = 24,
        FontWeight = FontWeights.Bold,
        Foreground = Text
    };

    public static TextBlock Subtitle(string text) => new()
    {
        Text = text,
        FontSize = 13,
        Foreground = Dim,
        TextWrapping = TextWrapping.Wrap
    };

    public static TextBlock Body(string text, SolidColorBrush? color = null, double size = 13) => new()
    {
        Text = text,
        FontSize = size,
        Foreground = color ?? Text,
        TextWrapping = TextWrapping.Wrap
    };

    public static TextBlock SectionLabel(string text) => new()
    {
        Text = text.ToUpperInvariant(),
        FontSize = 10,
        FontWeight = FontWeights.Black,
        Foreground = Dim,
        Margin = new Thickness(0, 4, 0, 0)
    };

    public static Border Card(UIElement content, double pad = 20) => new()
    {
        Background = Surf,
        CornerRadius = new CornerRadius(12),
        BorderBrush = Brd,
        BorderThickness = new Thickness(1),
        Padding = new Thickness(pad),
        Child = content,
        HorizontalAlignment = HorizontalAlignment.Stretch
    };

    public static Button PrimaryButton(string title, RoutedEventHandler onClick, SolidColorBrush? bg = null)
    {
        var b = new Button
        {
            Content = new TextBlock { Text = title, FontSize = 13, FontWeight = FontWeights.Medium, Foreground = White },
            Background = bg ?? Acc,
            BorderThickness = new Thickness(0),
            CornerRadius = new CornerRadius(10),
            Padding = new Thickness(16, 8, 16, 8)
        };
        b.Click += onClick;
        return b;
    }

    public static Button SecondaryButton(string title, RoutedEventHandler onClick, SolidColorBrush? fg = null, SolidColorBrush? border = null)
    {
        var b = new Button
        {
            Content = new TextBlock { Text = title, FontSize = 12, FontWeight = FontWeights.Medium, Foreground = fg ?? Text },
            Background = Surf,
            BorderBrush = border ?? Brd,
            BorderThickness = new Thickness(1),
            CornerRadius = new CornerRadius(12),
            Padding = new Thickness(12, 7, 12, 7)
        };
        b.Click += onClick;
        return b;
    }

    // Coloured status row: filled dot + label (mirrors the SF Symbol status rows).
    public static StackPanel StatusRow(bool ok, string text, SolidColorBrush? okColor = null, SolidColorBrush? badColor = null)
    {
        var color = ok ? (okColor ?? Green) : (badColor ?? Red);
        var row = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8, VerticalAlignment = VerticalAlignment.Center };
        row.Children.Add(new Ellipse { Width = 10, Height = 10, Fill = color, VerticalAlignment = VerticalAlignment.Center });
        row.Children.Add(new TextBlock { Text = text, FontSize = 13, FontWeight = FontWeights.SemiBold, Foreground = color, VerticalAlignment = VerticalAlignment.Center, TextWrapping = TextWrapping.Wrap });
        return row;
    }

    // Numbered step (mirrors macOS StepRow): blue circle with number + dim text.
    public static Grid StepRow(string number, string text)
    {
        var grid = new Grid { Margin = new Thickness(0, 0, 0, 0) };
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });

        var badge = new Border
        {
            Width = 20,
            Height = 20,
            CornerRadius = new CornerRadius(10),
            Background = Acc,
            VerticalAlignment = VerticalAlignment.Top,
            Margin = new Thickness(0, 0, 10, 0),
            Child = new TextBlock
            {
                Text = number,
                FontSize = 11,
                FontWeight = FontWeights.Bold,
                Foreground = White,
                HorizontalAlignment = HorizontalAlignment.Center,
                VerticalAlignment = VerticalAlignment.Center
            }
        };
        Grid.SetColumn(badge, 0);
        grid.Children.Add(badge);

        var t = new TextBlock { Text = text, FontSize = 12, Foreground = Dim, TextWrapping = TextWrapping.Wrap, VerticalAlignment = VerticalAlignment.Center };
        Grid.SetColumn(t, 1);
        grid.Children.Add(t);
        return grid;
    }

    // Bordered block that groups step rows (the macOS "C.bg rounded" inset).
    public static Border StepsBox(params UIElement[] steps)
    {
        var inner = new StackPanel { Orientation = Orientation.Vertical, Spacing = 8 };
        foreach (var s in steps) inner.Children.Add(s);
        return new Border
        {
            Background = Bg,
            CornerRadius = new CornerRadius(12),
            Padding = new Thickness(14, 10, 14, 10),
            Child = inner
        };
    }

    public static StackPanel VStack(double spacing = 10, params UIElement[] children)
    {
        var s = new StackPanel { Orientation = Orientation.Vertical, Spacing = spacing };
        foreach (var c in children) s.Children.Add(c);
        return s;
    }

    public static StackPanel HStack(double spacing = 10, params UIElement[] children)
    {
        var s = new StackPanel { Orientation = Orientation.Horizontal, Spacing = spacing, VerticalAlignment = VerticalAlignment.Center };
        foreach (var c in children) s.Children.Add(c);
        return s;
    }
}
