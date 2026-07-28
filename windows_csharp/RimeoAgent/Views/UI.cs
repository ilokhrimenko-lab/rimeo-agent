using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Markup;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Shapes;
using Windows.UI;
// Disambiguate from System.IO.Path (pulled in by ImplicitUsings).
using Path = Microsoft.UI.Xaml.Shapes.Path;

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
    public static SolidColorBrush SwitchOff  => new(Pick(0xD7DAE0, 0x3A3F49)); // выключенный тумблер
    public static SolidColorBrush White      => new(Microsoft.UI.Colors.White);
    public static SolidColorBrush Clear      => new(Microsoft.UI.Colors.Transparent);

    /// <summary>Тот же цвет с другой альфой — для мягких подложек и ховеров.</summary>
    public static SolidColorBrush Alpha(SolidColorBrush b, byte alpha)
    {
        var c = b.Color;
        return new SolidColorBrush(Color.FromArgb(alpha, c.R, c.G, c.B));
    }

    // ── Link Device gate (custom window chrome + code cells) ─────────────────
    public static SolidColorBrush WinChrome  => new(Pick(0xFFFFFF, 0x16181C)); // titlebar strip
    public static SolidColorBrush LockBg      => new(Pick(0xEAF0FE, 0x17243F)); // lock emblem fill
    public static SolidColorBrush LockBrd     => new(Pick(0xDCE7FD, 0x2A3A5C)); // lock emblem border
    public static SolidColorBrush CellBrd     => new(Pick(0xE3E6EB, 0x2E323B)); // idle code-cell border
    public static SolidColorBrush TitleInk    => new(Pick(0x3A3F49, 0xC9CDD4)); // titlebar "Rimeo"
    public static SolidColorBrush TitleDim    => new(Pick(0xA2A7B0, 0x6E747E)); // titlebar "Agent"
    public static SolidColorBrush WinCtrl     => new(Pick(0x6B7280, 0x8B919B)); // window control glyphs
    /// <summary>Soft accent ring behind the focused code cell (#2563EB / #3B82F6 @ ~14%).</summary>
    public static SolidColorBrush AccGlow =>
        new(Color.FromArgb(0x24, (byte)(IsDark ? 0x3B : 0x25), (byte)(IsDark ? 0x82 : 0x63), (byte)(IsDark ? 0xF6 : 0xEB)));

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
        Foreground = Text,
        // Без переноса заголовок обрезается в узком окне и на 150% системном масштабе.
        TextWrapping = TextWrapping.Wrap
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

    /// <summary>
    /// Путь моноширинным: длинный урезается ПО СЕРЕДИНЕ, чтобы осталось имя файла.
    /// Обычное многоточие в конце (единственный режим WinUI) съедало ровно то, ради
    /// чего путь и показан — macOS для путей использует `.truncationMode(.middle)`.
    /// </summary>
    public static TextBlock MonoPath(string path, SolidColorBrush? color = null, double size = 13)
    {
        const int max = 62, head = 16;
        var text = path;
        if (path.Length > max)
        {
            var tail = path[^(max - head - 1)..];
            text = $"{path[..head]}…{tail}";
        }
        var tb = Mono(text, color, size);
        tb.TextTrimming = TextTrimming.CharacterEllipsis;   // страховка на узком окне
        return tb;
    }

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
            // По верхней строке заголовка, а не по низу блока: с Bottom пилюля версии
            // на Settings вставала на уровень подзаголовка. macOS выравнивает по базовой
            // линии тайтла (`HStack(alignment: .firstTextBaseline)`).
            trailing.VerticalAlignment = VerticalAlignment.Top;
            trailing.Margin = new Thickness(12, 10, 0, 0);
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

    /// <summary>
    /// Пришпиливает заливку/текст/обводку кнопки ко всем визуальным состояниям.
    /// Без этого шаблон WinUI в PointerOver/Pressed подменяет фон `ContentPresenter`
    /// на системный (почти белый) — у Primary белый текст оказывался на белом фоне,
    /// то есть кнопка «исчезала» под курсором. Точечный обход уже жил в LinkDevicePage;
    /// теперь он общий для всей дизайн-системы.
    /// </summary>
    private static void PinStates(Button b, SolidColorBrush bg, SolidColorBrush fg,
                                  SolidColorBrush? border = null, SolidColorBrush? hoverBg = null)
    {
        var over = hoverBg ?? bg;
        b.Resources["ButtonBackground"]             = bg;
        b.Resources["ButtonBackgroundPointerOver"]  = over;
        b.Resources["ButtonBackgroundPressed"]      = over;
        b.Resources["ButtonBackgroundDisabled"]     = bg;
        b.Resources["ButtonForeground"]             = fg;
        b.Resources["ButtonForegroundPointerOver"]  = fg;
        b.Resources["ButtonForegroundPressed"]      = fg;
        b.Resources["ButtonForegroundDisabled"]     = fg;
        b.Resources["ButtonBorderBrush"]            = border ?? Clear;
        b.Resources["ButtonBorderBrushPointerOver"] = border ?? Clear;
        b.Resources["ButtonBorderBrushPressed"]     = border ?? Clear;
        b.Resources["ButtonBorderBrushDisabled"]    = border ?? Clear;
    }

    public static Button PrimaryButton(string title, RoutedEventHandler onClick, SolidColorBrush? bg = null)
    {
        var fill = bg ?? Acc;
        var b = new Button
        {
            Content = new TextBlock { Text = title, FontSize = 14, FontWeight = FontWeights.SemiBold, Foreground = White },
            Background = fill,
            BorderThickness = new Thickness(0),
            CornerRadius = new CornerRadius(13),
            Padding = new Thickness(20, 11, 20, 11),
            HorizontalAlignment = HorizontalAlignment.Left
        };
        // Ховер — тот же акцент чуть светлее/темнее, а не системный белый.
        PinStates(b, fill, White, null, Alpha(fill, 0xE0));
        b.Click += onClick;
        return b;
    }

    public static Button SecondaryButton(string title, RoutedEventHandler onClick, SolidColorBrush? fg = null)
    {
        var ink = fg ?? Btn2Txt;
        var b = new Button
        {
            Content = new TextBlock { Text = title, FontSize = 14, FontWeight = FontWeights.SemiBold, Foreground = ink },
            Background = Btn2,
            BorderBrush = Btn2Brd,
            BorderThickness = new Thickness(1),
            CornerRadius = new CornerRadius(12),
            // Вертикальный padding 11, как у Primary: иначе в одной строке (Settings →
            // «Clear Cache» рядом с «Save») кнопки разной высоты.
            Padding = new Thickness(16, 11, 16, 11),
            HorizontalAlignment = HorizontalAlignment.Left
        };
        PinStates(b, Btn2, ink, Btn2Brd, Chip);
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
            Padding = new Thickness(16, 11, 16, 11),
            HorizontalAlignment = HorizontalAlignment.Left
        };
        PinStates(b, RedSoft, Red, RedBrd, Alpha(Red, 0x22));
        b.Click += onClick;
        return b;
    }

    /// <summary>Кнопка-ссылка: только текст акцентом, без фона и рамки во всех состояниях.</summary>
    public static Button LinkButton(UIElement content, RoutedEventHandler onClick)
    {
        var b = new Button
        {
            Content = content,
            Background = Clear,
            BorderThickness = new Thickness(0),
            Padding = new Thickness(2, 6, 2, 6),
            HorizontalAlignment = HorizontalAlignment.Left,
            HorizontalContentAlignment = HorizontalAlignment.Left
        };
        PinStates(b, Clear, AccText, Clear, Chip);
        b.Click += onClick;
        return b;
    }

    public static ToggleSwitch Toggle(bool on, Action<bool> changed)
    {
        var t = new ToggleSwitch { IsOn = on, OnContent = null, OffContent = null, MinWidth = 0 };
        // Включённый тумблер по умолчанию красится ЛИЧНЫМ акцентом Windows (у кого-то
        // розовым) — в дизайн-системе он обязан быть Acc, а выключенный — SwitchOff
        // (macOS `RimeoSwitchStyle`).
        foreach (var key in new[] { "ToggleSwitchFillOn", "ToggleSwitchFillOnPointerOver", "ToggleSwitchFillOnPressed" })
            t.Resources[key] = Acc;
        foreach (var key in new[] { "ToggleSwitchStrokeOn", "ToggleSwitchStrokeOnPointerOver", "ToggleSwitchStrokeOnPressed" })
            t.Resources[key] = Acc;
        foreach (var key in new[] { "ToggleSwitchFillOff", "ToggleSwitchFillOffPointerOver", "ToggleSwitchFillOffPressed" })
            t.Resources[key] = SwitchOff;
        foreach (var key in new[] { "ToggleSwitchStrokeOff", "ToggleSwitchStrokeOffPointerOver", "ToggleSwitchStrokeOffPressed" })
            t.Resources[key] = SwitchOff;
        t.Resources["ToggleSwitchKnobFillOn"]  = White;
        t.Resources["ToggleSwitchKnobFillOnPointerOver"] = White;
        t.Resources["ToggleSwitchKnobFillOnPressed"] = White;
        t.Toggled += (s, _) => changed(((ToggleSwitch)s).IsOn);
        return t;
    }

    /// <summary>Чекбокс в акценте Rimeo вместо системного (macOS `RimeoCheckboxStyle`).</summary>
    public static CheckBox Checkbox(bool on, string label, Action<bool> changed)
    {
        var c = new CheckBox
        {
            IsChecked = on,
            Content = new TextBlock { Text = label, FontSize = 15, FontWeight = FontWeights.Medium, Foreground = Text }
        };
        foreach (var key in new[]
        {
            "CheckBoxCheckBackgroundFillChecked", "CheckBoxCheckBackgroundFillCheckedPointerOver",
            "CheckBoxCheckBackgroundFillCheckedPressed",
            "CheckBoxCheckBackgroundStrokeChecked", "CheckBoxCheckBackgroundStrokeCheckedPointerOver",
            "CheckBoxCheckBackgroundStrokeCheckedPressed",
        })
            c.Resources[key] = Acc;
        c.Resources["CheckBoxCheckGlyphForegroundChecked"] = White;
        c.Checked   += (_, _) => changed(true);
        c.Unchecked += (_, _) => changed(false);
        return c;
    }

    /// <summary>Спиннер в акценте Rimeo (по умолчанию берёт системный акцент Windows).</summary>
    public static ProgressRing Spinner(double size = 18) =>
        new() { IsActive = true, Width = size, Height = size, Foreground = Acc };

    /// <summary>
    /// Снимает системный хром с TextBox/PasswordBox (внутренняя заливка, рамка,
    /// акцентное подчёркивание при фокусе), чтобы виден был только наш контейнер.
    /// Локальных Background/BorderThickness мало: состояния PointerOver/Focused
    /// заново применяют TextControl*-кисти темы.
    /// </summary>
    public static void StripFieldChrome(Control c)
    {
        foreach (var key in new[]
        {
            "TextControlBackground", "TextControlBackgroundPointerOver",
            "TextControlBackgroundFocused", "TextControlBackgroundDisabled",
            "TextControlBorderBrush", "TextControlBorderBrushPointerOver",
            "TextControlBorderBrushFocused", "TextControlBorderBrushDisabled",
        })
            c.Resources[key] = Clear;
        c.Resources["TextControlBorderThemeThickness"] = new Thickness(0);
        c.Resources["TextControlBorderThemeThicknessFocused"] = new Thickness(0);
        // Внутренние кнопки поля («глазок» у пароля, крестик очистки у TextBox) иначе
        // остаются системного цвета и выпадают из поля.
        c.Resources["TextControlButtonForeground"] = Dim;
        c.Resources["TextControlButtonForegroundPointerOver"] = AccText;
        c.Resources["TextControlButtonBackground"] = Clear;
        c.Resources["TextControlButtonBackgroundPointerOver"] = Chip;
        c.CornerRadius = new CornerRadius(0);
    }

    /// <summary>
    /// Однострочное поле, текст которого обязан стоять РОВНО по центру контейнера.
    ///
    /// Почему не работает «очевидное» `VerticalContentAlignment = Center` (проверено по
    /// шаблонам WinUI, `CommonStyles/TextBox_themeresources.xaml` и `PasswordBox_…`):
    /// текст живёт в `ScrollViewer x:Name="ContentElement"`, и в шаблоне у него
    /// НЕТ привязки к `VerticalContentAlignment` — только
    /// `Padding="{TemplateBinding Padding}"`. То есть свойство контрола не участвует
    /// в раскладке вообще, а ScrollViewer прижимает содержимое к верху.
    ///
    /// Поэтому единственный честный способ — не растягивать контрол на высоту поля, а
    /// сжать его до высоты строки и центрировать целиком. Мешают этому две вещи:
    /// у TextBox минимумы приходят Style-сеттерами (`MinHeight`/`MinWidth` контрола),
    /// а у PasswordBox `BorderElement` привязан к ThemeResource НАПРЯМУЮ
    /// (`MinHeight="{ThemeResource TextControlThemeMinHeight}"`), мимо свойств контрола.
    /// Гасим оба пути, иначе поле не станет ниже 32 и текст снова уедет вверх.
    /// </summary>
    public static void CenterFieldText(Control c)
    {
        c.Resources["TextControlThemeMinHeight"] = 0.0;   // PasswordBox: BorderElement ← ThemeResource
        c.Resources["TextControlThemeMinWidth"]  = 0.0;   // без этого узкое поле не уже 64
        c.MinHeight = 0;                                   // TextBox: BorderElement ← TemplateBinding
        c.MinWidth  = 0;
        c.Padding   = new Thickness(0);
        c.VerticalAlignment = VerticalAlignment.Center;    // ключевое: НЕ Stretch
        c.VerticalContentAlignment = VerticalAlignment.Center;
    }

    /// <summary>
    /// Прячет системную кнопку очистки («крестик») внутри TextBox.
    /// В шаблоне она живёт в колонке Auto шириной 30 и всплывает при фокусе с
    /// непустым текстом — в узком поле (лимит кэша, 34px) она бы отъела почти всю
    /// ширину и раздавила цифру ровно в момент редактирования. Это же 30px и есть
    /// причина, по которой тема держит `TextControlThemeMinWidth = 64`.
    /// </summary>
    public static void HideClearButton(TextBox t)
    {
        var s = new Style(typeof(Button));
        s.Setters.Add(new Setter(UIElement.VisibilityProperty, Visibility.Collapsed));
        s.Setters.Add(new Setter(FrameworkElement.WidthProperty, 0.0));
        s.Setters.Add(new Setter(FrameworkElement.MinWidthProperty, 0.0));
        t.Resources["DeleteButtonStyle"] = s;
    }

    /// <summary>
    /// Поле ввода в оформлении Rimeo: наша заливка/рамка/радиус вместо системных,
    /// системный хром снят. Для полей, которые живут БЕЗ внешнего контейнера
    /// (баг-репорт, лимит кэша) — в отличие от `InputRow` на экране входа.
    /// </summary>
    public static void StyleField(Control c, double radius = 12)
    {
        StripFieldChrome(c);
        c.Background  = Field;
        c.BorderBrush = Brd;
        c.BorderThickness = new Thickness(1);
        c.CornerRadius = new CornerRadius(radius);
        c.Foreground = Text;
        c.Resources["TextControlButtonForeground"] = Dim;              // «глазок» / крестик очистки
        c.Resources["TextControlButtonForegroundPointerOver"] = AccText;
        c.Resources["TextControlButtonBackground"] = Clear;
        c.Resources["TextControlButtonBackgroundPointerOver"] = Chip;
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

    // ── Stroke icons (SVG path data on a 0–24 viewBox, scaled into `size`) ────
    private static string HexOf(Color c) => $"#{c.A:X2}{c.R:X2}{c.G:X2}{c.B:X2}";

    private static Path StrokePath(string data, Color stroke, double thickness)
    {
        // WinUI has no Geometry.Parse; round-trip the path mini-language through XAML.
        var xaml =
            "<Path xmlns=\"http://schemas.microsoft.com/winfx/2006/xaml/presentation\" " +
            $"Data=\"{data}\" Stroke=\"{HexOf(stroke)}\" StrokeThickness=\"{thickness.ToString(System.Globalization.CultureInfo.InvariantCulture)}\" " +
            "StrokeStartLineCap=\"Round\" StrokeEndLineCap=\"Round\" StrokeLineJoin=\"Round\" />";
        return (Path)XamlReader.Load(xaml);
    }

    /// <summary>Builds a stroked icon from one or more SVG path strings drawn on a 24×24 grid.</summary>
    public static Viewbox Icon(double size, SolidColorBrush stroke, double thickness, params string[] paths)
    {
        var canvas = new Canvas { Width = 24, Height = 24 };
        foreach (var d in paths) canvas.Children.Add(StrokePath(d, stroke.Color, thickness));
        return new Viewbox { Width = size, Height = size, Stretch = Stretch.Uniform, Child = canvas };
    }
}
