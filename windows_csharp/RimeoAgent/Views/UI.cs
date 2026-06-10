using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Shapes;
using Windows.UI;

namespace RimeoAgent.Views;

/// <summary>
/// Shared design system — a 1:1 mirror of the macOS agent's ContentView.swift
/// (ColorPalette + shared components), ported from the Paper redesign.
/// Tokens are adaptive: light values in light mode, dark values in dark mode,
/// switched by <see cref="IsDark"/> (set by MainWindow from the resolved theme).
/// </summary>
internal static class UI
{
    /// <summary>Active resolved theme. MainWindow sets this before navigating.</summary>
    public static bool IsDark = true;

    private static Color FromRgb(uint hex) =>
        Color.FromArgb(255, (byte)(hex >> 16), (byte)(hex >> 8), (byte)hex);

    private static Color Pick(uint light, uint dark) => FromRgb(IsDark ? dark : light);

    // ── Tokens (light, dark) ────────────────────────────────────────────────
    public static SolidColorBrush Bg        => new(Pick(0xF5F6F8, 0x141519)); // page background
    public static SolidColorBrush Sidebar   => new(Pick(0xF4F5F8, 0x1B1D23)); // sidebar surface
    public static SolidColorBrush Surf       => new(Pick(0xFFFFFF, 0x1E2128)); // card surface
    public static SolidColorBrush Acc        => new(Pick(0x2563EB, 0x3B82F6)); // primary blue
    public static SolidColorBrush AccSoft    => new(Pick(0xEAF0FE, 0x1E2E4F)); // blue tint
    public static SolidColorBrush AccText    => new(Pick(0x2563EB, 0x6BA1FF)); // accent text/icon
    public static SolidColorBrush Text       => new(Pick(0x0A0A0B, 0xF2F3F5)); // primary ink
    public static SolidColorBrush BodyTxt    => new(Pick(0x2B3445, 0xC7CCD6)); // step / body
    public static SolidColorBrush Secondary  => new(Pick(0x5C616B, 0xAEB4BE)); // secondary text
    public static SolidColorBrush Dim        => new(Pick(0x9499A3, 0x8B919B)); // muted labels
    public static SolidColorBrush Faint      => new(Pick(0xAEB2BA, 0x6B7079)); // faint / disabled
    public static SolidColorBrush Brd        => new(Pick(0xE6E8EC, 0x2E323B)); // hairline border
    public static SolidColorBrush CardBrd    => new(Pick(0xECEEF1, 0x2E323B)); // card border
    public static SolidColorBrush Field      => new(Pick(0xF3F4F6, 0x23262E)); // input fill
    public static SolidColorBrush Chip       => new(Pick(0xEEF0F3, 0x2A2E37)); // chip / pill fill
    public static SolidColorBrush Green      => new(Pick(0x2FAE73, 0x34C77E));
    public static SolidColorBrush GreenSoft  => new(Pick(0xEBF7F0, 0x14271C));
    public static SolidColorBrush Red        => new(Pick(0xE5484D, 0xFF5A60));
    public static SolidColorBrush RedSoft    => new(Pick(0xFEF2F2, 0x2A1618));
    public static SolidColorBrush RedBrd     => new(Pick(0xF7D4D5, 0x4A2326));
    public static SolidColorBrush Amber      => new(Pick(0xF59E0B, 0xFBB540));
    public static SolidColorBrush Btn2       => new(Pick(0xFFFFFF, 0x2A2F39));
    public static SolidColorBrush Btn2Brd    => new(Pick(0xE1E4E9, 0x2E323B));
    public static SolidColorBrush Btn2Txt    => new(Pick(0x2B3445, 0xE6E8EC));
    public static SolidColorBrush SegTrack   => new(Pick(0xEBEDF1, 0x23262E));
    public static SolidColorBrush SegActive  => new(Pick(0xFFFFFF, 0x363C46));
    public static SolidColorBrush White      => new(Microsoft.UI.Colors.White);

    public static Color Hex(string hex)
    {
        var h = hex.TrimStart('#');
        byte r = Convert.ToByte(h.Substring(0, 2), 16);
        byte g = Convert.ToByte(h.Substring(2, 2), 16);
        byte b = Convert.ToByte(h.Substring(4, 2), 16);
        return Color.FromArgb(255, r, g, b);
    }

    // ── Scaffold & typography ───────────────────────────────────────────────
    public static (ScrollViewer scroll, StackPanel stack) Page(double spacing = 26)
    {
        var stack = new StackPanel
        {
            Orientation = Orientation.Vertical,
            Spacing = spacing,
            Margin = new Thickness(34, 30, 34, 30),
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
        FontSize = 30,
        FontWeight = FontWeights.ExtraBold,
        Foreground = Text
    };

    public static TextBlock Subtitle(string text) => new()
    {
        Text = text,
        FontSize = 14,
        Foreground = Secondary,
        TextWrapping = TextWrapping.Wrap
    };

    public static TextBlock Body(string text, SolidColorBrush? color = null, double size = 14) => new()
    {
        Text = text,
        FontSize = size,
        Foreground = color ?? Text,
        TextWrapping = TextWrapping.Wrap
    };

    public static TextBlock Mono(string text, SolidColorBrush? color = null, double size = 13) => new()
    {
        Text = text,
        FontSize = size,
        FontFamily = new FontFamily("Consolas"),
        Foreground = color ?? Secondary,
        TextTrimming = TextTrimming.CharacterEllipsis
    };

    public static TextBlock SectionLabel(string text) => new()
    {
        Text = text.ToUpperInvariant(),
        FontSize = 12,
        FontWeight = FontWeights.Bold,
        CharacterSpacing = 80,                 // ~0.08em
        Foreground = Dim,
        Margin = new Thickness(0, 6, 0, 0)
    };

    /// <summary>Screen header: big title with optional trailing element (e.g. version).</summary>
    public static Grid ScreenHeader(string title, string? subtitle = null, FrameworkElement? trailing = null)
    {
        var grid = new Grid();
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });

        var left = new StackPanel { Orientation = Orientation.Vertical, Spacing = 7 };
        left.Children.Add(Heading(title));
        if (subtitle != null) left.Children.Add(Subtitle(subtitle));
        Grid.SetColumn(left, 0);
        grid.Children.Add(left);

        if (trailing != null)
        {
            trailing.VerticalAlignment = VerticalAlignment.Bottom;
            Grid.SetColumn(trailing, 1);
            grid.Children.Add(trailing);
        }
        return grid;
    }

    public static Border Card(UIElement content, double pad = 20) => new()
    {
        Background = Surf,
        CornerRadius = new CornerRadius(18),
        BorderBrush = CardBrd,
        BorderThickness = new Thickness(1),
        Padding = new Thickness(pad),
        Child = content,
        HorizontalAlignment = HorizontalAlignment.Stretch
    };

    // ── Buttons ─────────────────────────────────────────────────────────────
    public static Button PrimaryButton(string title, RoutedEventHandler onClick, SolidColorBrush? bg = null)
    {
        var b = new Button
        {
            Content = new TextBlock { Text = title, FontSize = 14, FontWeight = FontWeights.SemiBold, Foreground = White },
            Background = bg ?? Acc,
            BorderThickness = new Thickness(0),
            CornerRadius = new CornerRadius(13),
            Padding = new Thickness(20, 11, 20, 11),
            HorizontalAlignment = HorizontalAlignment.Left
        };
        b.Click += onClick;
        return b;
    }

    public static Button SecondaryButton(string title, RoutedEventHandler onClick, SolidColorBrush? fg = null)
    {
        var b = new Button
        {
            Content = new TextBlock { Text = title, FontSize = 14, FontWeight = FontWeights.SemiBold, Foreground = fg ?? Btn2Txt },
            Background = Btn2,
            BorderBrush = Btn2Brd,
            BorderThickness = new Thickness(1),
            CornerRadius = new CornerRadius(12),
            Padding = new Thickness(16, 9, 16, 9),
            HorizontalAlignment = HorizontalAlignment.Left
        };
        b.Click += onClick;
        return b;
    }

    /// <summary>Destructive outlined button (soft-red fill, red border + text).</summary>
    public static Button DestructiveButton(string title, RoutedEventHandler onClick)
    {
        var b = new Button
        {
            Content = new TextBlock { Text = title, FontSize = 14, FontWeight = FontWeights.SemiBold, Foreground = Red },
            Background = RedSoft,
            BorderBrush = RedBrd,
            BorderThickness = new Thickness(1),
            CornerRadius = new CornerRadius(12),
            Padding = new Thickness(16, 9, 16, 9),
            HorizontalAlignment = HorizontalAlignment.Left
        };
        b.Click += onClick;
        return b;
    }

    public static ToggleSwitch Toggle(bool on, Action<bool> changed)
    {
        var t = new ToggleSwitch { IsOn = on, OnContent = null, OffContent = null, MinWidth = 0 };
        t.Toggled += (s, _) => changed(((ToggleSwitch)s).IsOn);
        return t;
    }

    // ── Status & steps ──────────────────────────────────────────────────────
    public static StackPanel StatusDot(SolidColorBrush color, string text, SolidColorBrush textColor)
    {
        var row = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6, VerticalAlignment = VerticalAlignment.Center };
        row.Children.Add(new Ellipse { Width = 6, Height = 6, Fill = color, VerticalAlignment = VerticalAlignment.Center });
        row.Children.Add(new TextBlock { Text = text, FontSize = 13, FontWeight = FontWeights.Medium, Foreground = textColor, VerticalAlignment = VerticalAlignment.Center, TextWrapping = TextWrapping.Wrap });
        return row;
    }

    public static StackPanel StatusRow(bool ok, string text, SolidColorBrush? okColor = null, SolidColorBrush? badColor = null)
    {
        var color = ok ? (okColor ?? Green) : (badColor ?? Red);
        return StatusDot(color, text, color);
    }

    public static Grid StepRow(string number, string text)
    {
        var grid = new Grid();
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });

        var badge = new Border
        {
            Width = 25,
            Height = 25,
            CornerRadius = new CornerRadius(13),
            Background = AccSoft,
            VerticalAlignment = VerticalAlignment.Top,
            Margin = new Thickness(0, 0, 13, 0),
            Child = new TextBlock
            {
                Text = number,
                FontSize = 13,
                FontWeight = FontWeights.Bold,
                Foreground = AccText,
                HorizontalAlignment = HorizontalAlignment.Center,
                VerticalAlignment = VerticalAlignment.Center
            }
        };
        Grid.SetColumn(badge, 0);
        grid.Children.Add(badge);

        var t = new TextBlock { Text = text, FontSize = 14, FontWeight = FontWeights.Medium, Foreground = BodyTxt, TextWrapping = TextWrapping.Wrap, VerticalAlignment = VerticalAlignment.Center };
        Grid.SetColumn(t, 1);
        grid.Children.Add(t);
        return grid;
    }

    /// <summary>Vertical list of step rows (no inset box — steps sit directly on the card).</summary>
    public static StackPanel StepsList(params UIElement[] steps)
    {
        var inner = new StackPanel { Orientation = Orientation.Vertical, Spacing = 11 };
        foreach (var s in steps) inner.Children.Add(s);
        return inner;
    }

    public static StackPanel VStack(double spacing = 14, params UIElement[] children)
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
