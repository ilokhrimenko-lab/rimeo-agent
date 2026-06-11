using System;
using System.Linq;
using System.Net.Http;
using System.Text;
using System.Text.Json;
using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using RimeoAgent.Config;
using RimeoAgent.Services;
using Windows.ApplicationModel.DataTransfer;
using Windows.System;

namespace RimeoAgent.Views;

// Port of the Paper "Agent — Link Device — Win" gate (light + dark). Shown before
// the agent is linked to a Rimeo account: a custom window titlebar, a lock emblem,
// a 6-cell pairing-code input and a Link-device action. On a successful link it
// hands control back to the main shell via the supplied callback.
public sealed partial class LinkDevicePage : Page
{
    private const int CodeLength = 8;   // pairing token length (matches iOS / web dashboard)

    // Glyph paths on a 0–24 viewBox (mirrors the SVG icons in the Paper export).
    private static readonly string[] LinkGlyph =
    {
        "M10 13a5 5 0 0 0 7.07 0l3-3a5 5 0 0 0-7.07-7.07l-1.72 1.71",
        "M14 11a5 5 0 0 0-7.07 0l-3 3a5 5 0 0 0 7.07 7.07l1.71-1.71"
    };

    private readonly Action _onLinked;
    private readonly TextBlock[] _cellText = new TextBlock[CodeLength];
    private readonly Border[]    _cellBox  = new Border[CodeLength];
    private readonly Border[]    _cursor   = new Border[CodeLength];
    private readonly TextBox     _input    = new();
    private readonly TextBlock   _status   = new()
    {
        FontSize = 13, FontWeight = FontWeights.Medium, TextWrapping = TextWrapping.Wrap,
        HorizontalAlignment = HorizontalAlignment.Center, Visibility = Visibility.Collapsed
    };

    private bool _updatingInput;

    /// <summary>The draggable titlebar lane — MainWindow passes it to SetTitleBar.</summary>
    public FrameworkElement TitleBarDragRegion { get; private set; } = new Grid();

    public LinkDevicePage(Action onLinked)
    {
        _onLinked = onLinked;
        InitializeComponent();
        Content = Build();
        Loaded += (_, _) => _input.Focus(FocusState.Programmatic);
    }

    private Grid Build()
    {
        var root = new Grid();
        root.RowDefinitions.Add(new RowDefinition { Height = new GridLength(52) });
        root.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });

        var titlebar = BuildTitlebar();
        Grid.SetRow(titlebar, 0);
        root.Children.Add(titlebar);

        var content = new Border { Background = UI.Bg, Child = BuildGate() };
        Grid.SetRow(content, 1);
        root.Children.Add(content);

        return root;
    }

    // ── Custom titlebar: brand on the left (drag lane), window controls right ──
    private Border BuildTitlebar()
    {
        var grid = new Grid();
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });

        var brand = new StackPanel
        {
            Orientation = Orientation.Horizontal,
            Spacing = 7,
            VerticalAlignment = VerticalAlignment.Center,
            Padding = new Thickness(22, 0, 0, 0),
            Background = new SolidColorBrush(Microsoft.UI.Colors.Transparent) // make the whole lane draggable
        };
        brand.Children.Add(new TextBlock { Text = "Rimeo", FontSize = 13, FontWeight = FontWeights.Bold, Foreground = UI.TitleInk, CharacterSpacing = -10 });
        brand.Children.Add(new TextBlock { Text = "Agent", FontSize = 13, FontWeight = FontWeights.Medium, Foreground = UI.TitleDim, CharacterSpacing = -10 });
        Grid.SetColumn(brand, 0);
        grid.Children.Add(brand);
        TitleBarDragRegion = brand;

        var controls = new StackPanel { Orientation = Orientation.Horizontal, VerticalAlignment = VerticalAlignment.Center };
        controls.Children.Add(WindowButton(UI.Icon(12, UI.WinCtrl, 1.6, "M5 12L19 12"),
            (_, _) => MainWindow.Instance?.MinimizeGate()));
        controls.Children.Add(WindowButton(UI.Icon(12, UI.WinCtrl, 1.6,
            "M6.5 5H17.5A1.5 1.5 0 0 1 19 6.5V17.5A1.5 1.5 0 0 1 17.5 19H6.5A1.5 1.5 0 0 1 5 17.5V6.5A1.5 1.5 0 0 1 6.5 5Z"),
            (_, _) => MainWindow.Instance?.ToggleMaximizeGate()));
        controls.Children.Add(WindowButton(UI.Icon(12, UI.WinCtrl, 1.6, "M6 6L18 18", "M18 6L6 18"),
            (_, _) => MainWindow.Instance?.CloseGate()));
        Grid.SetColumn(controls, 1);
        grid.Children.Add(controls);

        return new Border { Background = UI.WinChrome, Child = grid };
    }

    private static Button WindowButton(UIElement icon, RoutedEventHandler onClick)
    {
        var b = new Button
        {
            Width = 46, Height = 46,
            Padding = new Thickness(0),
            CornerRadius = new CornerRadius(0),
            BorderThickness = new Thickness(0),
            Background = new SolidColorBrush(Microsoft.UI.Colors.Transparent),
            Content = icon
        };
        b.Click += onClick;
        return b;
    }

    // ── The centered pairing card ─────────────────────────────────────────────
    private Grid BuildGate()
    {
        var host = new Grid();

        var gate = new StackPanel
        {
            Orientation = Orientation.Vertical,
            Width = 430,
            HorizontalAlignment = HorizontalAlignment.Center,
            VerticalAlignment = VerticalAlignment.Center
        };

        // Lock emblem
        var emblem = new Border
        {
            Width = 60, Height = 60,
            CornerRadius = new CornerRadius(17),
            Background = UI.LockBg,
            BorderBrush = UI.LockBrd,
            BorderThickness = new Thickness(1),
            HorizontalAlignment = HorizontalAlignment.Center,
            Child = UI.Icon(28, UI.Acc, 2, LinkGlyph)
        };
        gate.Children.Add(emblem);

        // Heading + subtitle
        var headingBlock = new StackPanel
        {
            Orientation = Orientation.Vertical, Spacing = 9, Width = 360,
            HorizontalAlignment = HorizontalAlignment.Center,
            Margin = new Thickness(0, 22, 0, 0)
        };
        headingBlock.Children.Add(new TextBlock
        {
            Text = "Let’s pair your device",
            FontSize = 26, FontWeight = FontWeights.ExtraBold, Foreground = UI.Text,
            CharacterSpacing = -20, TextAlignment = TextAlignment.Center, TextWrapping = TextWrapping.Wrap
        });
        headingBlock.Children.Add(new TextBlock
        {
            Text = "Start by linking this agent to your Rimeo account. Enter the pairing code from rimeo.app to set up the pair.",
            FontSize = 14, Foreground = UI.Secondary, CharacterSpacing = -10,
            LineHeight = 20, TextAlignment = TextAlignment.Center, TextWrapping = TextWrapping.Wrap
        });
        gate.Children.Add(headingBlock);

        // Code cells (with an invisible TextBox overlay capturing keystrokes)
        gate.Children.Add(BuildCells());

        // Actions: Link-device button + paste hint + inline status
        var actions = new StackPanel
        {
            Orientation = Orientation.Vertical, Spacing = 14, Width = 374,
            HorizontalAlignment = HorizontalAlignment.Center,
            Margin = new Thickness(0, 20, 0, 0)
        };
        actions.Children.Add(BuildLinkButton());
        actions.Children.Add(BuildPasteHint());
        actions.Children.Add(_status);
        gate.Children.Add(actions);

        // Info chip
        gate.Children.Add(BuildInfoChip());

        host.Children.Add(gate);
        return host;
    }

    private Grid BuildCells()
    {
        var overlay = new Grid { Margin = new Thickness(0, 26, 0, 0), HorizontalAlignment = HorizontalAlignment.Center };

        var row = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8, HorizontalAlignment = HorizontalAlignment.Center };
        for (int i = 0; i < CodeLength; i++)
        {
            var glyph = new TextBlock
            {
                FontSize = 22, FontWeight = FontWeights.SemiBold,
                FontFamily = new FontFamily("Consolas"), Foreground = UI.Text,
                HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center
            };
            var caret = new Border
            {
                Width = 2, Height = 24, CornerRadius = new CornerRadius(2), Background = UI.Acc,
                HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center,
                Visibility = Visibility.Collapsed
            };
            var inner = new Grid();
            inner.Children.Add(caret);
            inner.Children.Add(glyph);

            var box = new Border
            {
                Width = 46, Height = 58, CornerRadius = new CornerRadius(12),
                Background = UI.Surf, BorderBrush = UI.CellBrd, BorderThickness = new Thickness(1),
                Child = inner
            };
            _cellText[i] = glyph;
            _cursor[i]   = caret;
            _cellBox[i]  = box;
            row.Children.Add(box);
        }
        overlay.Children.Add(row);

        // Invisible input that owns the keyboard; sits on top so a tap focuses it.
        _input.MaxLength = CodeLength;
        _input.Opacity = 0;
        _input.Background = new SolidColorBrush(Microsoft.UI.Colors.Transparent);
        _input.BorderThickness = new Thickness(0);
        _input.HorizontalAlignment = HorizontalAlignment.Stretch;
        _input.VerticalAlignment = VerticalAlignment.Stretch;
        _input.TextChanged += Input_TextChanged;
        _input.KeyDown += (_, e) => { if (e.Key == VirtualKey.Enter) Submit(); };
        overlay.Children.Add(_input);

        RenderCells();
        return overlay;
    }

    private void Input_TextChanged(object sender, TextChangedEventArgs e)
    {
        if (_updatingInput) return;

        var clean = new string(_input.Text.Where(char.IsLetterOrDigit).ToArray())
            .ToUpperInvariant();
        if (clean.Length > CodeLength) clean = clean.Substring(0, CodeLength);

        if (clean != _input.Text)
        {
            _updatingInput = true;
            _input.Text = clean;
            _input.Select(clean.Length, 0);
            _updatingInput = false;
        }
        RenderCells();
    }

    private void RenderCells()
    {
        var text = _input.Text;
        int active = text.Length < CodeLength ? text.Length : -1;
        for (int i = 0; i < CodeLength; i++)
        {
            _cellText[i].Text = i < text.Length ? text[i].ToString() : "";
            bool isActive = i == active;
            _cellBox[i].BorderBrush = isActive ? UI.Acc : UI.CellBrd;
            _cellBox[i].BorderThickness = new Thickness(isActive ? 2 : 1);
            _cursor[i].Visibility = isActive ? Visibility.Visible : Visibility.Collapsed;
        }
    }

    private Button BuildLinkButton()
    {
        var content = new StackPanel
        {
            Orientation = Orientation.Horizontal, Spacing = 9,
            HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center
        };
        content.Children.Add(UI.Icon(17, UI.White, 2.1, LinkGlyph));
        content.Children.Add(new TextBlock { Text = "Link device", FontSize = 15, FontWeight = FontWeights.SemiBold, Foreground = UI.White });

        var b = new Button
        {
            Width = 374, Height = 46,
            CornerRadius = new CornerRadius(12),
            BorderThickness = new Thickness(0),
            Background = UI.Acc,
            HorizontalContentAlignment = HorizontalAlignment.Center,
            VerticalContentAlignment = VerticalAlignment.Center,
            Content = content
        };
        b.Click += (_, _) => Submit();
        return b;
    }

    private Button BuildPasteHint()
    {
        var content = new StackPanel
        {
            Orientation = Orientation.Horizontal, Spacing = 7,
            HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center
        };
        content.Children.Add(UI.Icon(14, UI.Secondary, 2,
            "M8 2H16A1 1 0 0 1 17 3V5A1 1 0 0 1 16 6H8A1 1 0 0 1 7 5V3A1 1 0 0 1 8 2Z",
            "M16 4h2a2 2 0 0 1 2 2v14a2 2 0 0 1-2 2H6a2 2 0 0 1-2-2V6a2 2 0 0 1 2-2h2"));
        content.Children.Add(new TextBlock { Text = "Paste from clipboard", FontSize = 13, FontWeight = FontWeights.Medium, Foreground = UI.Secondary });

        var b = new Button
        {
            Background = new SolidColorBrush(Microsoft.UI.Colors.Transparent),
            BorderThickness = new Thickness(0),
            Padding = new Thickness(6, 2, 6, 2),
            HorizontalAlignment = HorizontalAlignment.Center,
            Content = content
        };
        b.Click += async (_, _) => await PasteFromClipboard();
        return b;
    }

    private Border BuildInfoChip()
    {
        var row = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 10, VerticalAlignment = VerticalAlignment.Center };
        row.Children.Add(UI.Icon(15, UI.Dim, 2, "M12 21a9 9 0 1 0 0-18 9 9 0 0 0 0 18Z", "M12 16v-4", "M12 8h.01"));
        row.Children.Add(new TextBlock
        {
            Text = "Find your code at rimeo.app › Account › Pair a device",
            FontSize = 13, Foreground = UI.Acc, CharacterSpacing = -10, VerticalAlignment = VerticalAlignment.Center
        });
        return new Border
        {
            Background = UI.Surf,
            BorderBrush = UI.CardBrd,
            BorderThickness = new Thickness(1),
            CornerRadius = new CornerRadius(12),
            Padding = new Thickness(15, 11, 15, 11),
            HorizontalAlignment = HorizontalAlignment.Center,
            Margin = new Thickness(0, 22, 0, 0),
            Child = row
        };
    }

    private async System.Threading.Tasks.Task PasteFromClipboard()
    {
        try
        {
            var view = Clipboard.GetContent();
            if (!view.Contains(StandardDataFormats.Text)) return;
            var text = await view.GetTextAsync();
            var clean = new string((text ?? "").Where(char.IsLetterOrDigit).ToArray()).ToUpperInvariant();
            if (clean.Length > CodeLength) clean = clean.Substring(0, CodeLength);
            _input.Text = clean;
            _input.Select(clean.Length, 0);
            _input.Focus(FocusState.Programmatic);
        }
        catch (Exception ex) { Log.Error($"Clipboard paste failed: {ex.Message}"); }
    }

    private async void Submit()
    {
        var token = _input.Text.Trim();
        if (token.Length < CodeLength)
        {
            ShowStatus("Enter the full 8-character pairing code from rimeo.app.", ok: false);
            return;
        }

        ShowStatus("Linking…", ok: true);
        try
        {
            using var http = new HttpClient();
            var payload = JsonSerializer.Serialize(new { token, cloud_url = AppConfig.RimeoAppUrl });
            var resp = await http.PostAsync($"http://127.0.0.1:{AppConfig.Port}/api/link_account",
                new StringContent(payload, Encoding.UTF8, "application/json"));

            if (resp.IsSuccessStatusCode)
            {
                AppState.Shared.RefreshFromData();
                _onLinked();
            }
            else
            {
                ShowStatus($"Couldn’t link (error {(int)resp.StatusCode}). Check the code and try again.", ok: false);
            }
        }
        catch (Exception ex)
        {
            Log.Error($"Link device failed: {ex.Message}");
            ShowStatus($"Error: {ex.Message}", ok: false);
        }
    }

    private void ShowStatus(string text, bool ok)
    {
        _status.Visibility = Visibility.Visible;
        _status.Text = text;
        _status.Foreground = ok ? UI.Secondary : UI.Red;
    }
}
