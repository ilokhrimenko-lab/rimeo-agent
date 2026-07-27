using System;
using System.Collections.Generic;
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
using Windows.System;

namespace RimeoAgent.Views;

// Port of the Paper "Agent — Sign In / Create Account — Win" gate (light + dark).
// Shown before the agent is signed in to a Rimeo account: a custom window
// titlebar, an account emblem, an email + password form, and a Sign in /
// Create account action. On success it hands control back to the main shell via
// the supplied callback. (Renamed file kept as LinkDevicePage for call sites.)
public sealed partial class LinkDevicePage : Page
{
    private readonly Action _onLinked;
    private bool _isSignIn = true;
    private bool _busy;

    private readonly TextBox     _emailBox    = new();
    private readonly PasswordBox _passwordBox = new();

    private readonly TextBlock _title = new()
    {
        FontSize = 26, FontWeight = FontWeights.ExtraBold, Foreground = UI.Text,
        CharacterSpacing = -20, TextAlignment = TextAlignment.Center, TextWrapping = TextWrapping.Wrap
    };
    private readonly TextBlock _subtitle = new()
    {
        FontSize = 14, Foreground = UI.Secondary, CharacterSpacing = -10, LineHeight = 20,
        TextAlignment = TextAlignment.Center, TextWrapping = TextWrapping.Wrap
    };
    private Button   _forgotBtn = null!;
    private TextBlock _helper   = null!;
    private readonly TextBlock _primaryLabel = new() { FontSize = 15, FontWeight = FontWeights.SemiBold, Foreground = UI.White };
    private readonly TextBlock _footerLead   = new() { FontSize = 13, FontWeight = FontWeights.Medium, Foreground = UI.Secondary, VerticalAlignment = VerticalAlignment.Center };
    private readonly TextBlock _footerLinkLabel = new() { FontSize = 13, FontWeight = FontWeights.SemiBold, Foreground = UI.AccText };
    private Border   _sessionNote = null!;
    private Border   _emblem      = null!;
    private Button   _primaryBtn  = null!;
    private readonly ProgressRing _primarySpinner = new()
    {
        IsActive = true, Width = 16, Height = 16, Foreground = UI.White,
        VerticalAlignment = VerticalAlignment.Center, Visibility = Visibility.Collapsed
    };
    private Viewbox _primaryArrow = null!;
    // Подсказка («Your session ended…») и ошибка входа — РАЗНЫЕ сообщения. Пока они
    // делили один TextBlock, первая же ошибка стирала объяснение, зачем вообще
    // показан экран входа. macOS держит их раздельно (infoMsg + statusMsg).
    private readonly TextBlock _info = new()
    {
        FontSize = 13, FontWeight = FontWeights.Medium, TextWrapping = TextWrapping.Wrap,
        TextAlignment = TextAlignment.Center, HorizontalAlignment = HorizontalAlignment.Center,
        Foreground = UI.Secondary, Width = 374, Visibility = Visibility.Collapsed
    };
    private readonly TextBlock _status = new()
    {
        FontSize = 13, FontWeight = FontWeights.Medium, TextWrapping = TextWrapping.Wrap,
        TextAlignment = TextAlignment.Center, HorizontalAlignment = HorizontalAlignment.Center,
        Width = 374, Visibility = Visibility.Collapsed
    };

    /// <summary>The draggable titlebar lane — MainWindow passes it to SetTitleBar.</summary>
    public FrameworkElement TitleBarDragRegion { get; private set; } = new Grid();

    public LinkDevicePage(Action onLinked)
    {
        _onLinked = onLinked;
        InitializeComponent();
        Content = Build();
        ApplyMode();
        // If a previous session was signed out involuntarily (account claimed on
        // another computer, or a relay eviction cleared the token), CloudUserId is
        // kept — prefill the email so reconnecting is a one-tap password re-entry
        // instead of a blank gate. An explicit Sign out clears it, so this hint only
        // appears after an involuntary de-auth.
        var lastEmail = RimeoAgent.Models.DataStore.Shared.Data.CloudUserId;
        if (!string.IsNullOrEmpty(lastEmail))
        {
            _emailBox.Text = lastEmail;
            ShowInfo("Your session ended — sign in to reconnect this agent.");
            Loaded += (_, _) => _passwordBox.Focus(FocusState.Programmatic);
        }
        else
        {
            Loaded += (_, _) => _emailBox.Focus(FocusState.Programmatic);
        }
    }

    private const double TitleBarHeight = 52;

    private Grid Build()
    {
        var root = new Grid();
        root.RowDefinitions.Add(new RowDefinition { Height = new GridLength(TitleBarHeight) });
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
            Orientation = Orientation.Horizontal, Spacing = 7, VerticalAlignment = VerticalAlignment.Center,
            Padding = new Thickness(18, 0, 0, 0),
            Background = new SolidColorBrush(Microsoft.UI.Colors.Transparent)
        };
        // Логотип в титлбаре: без него гейт выглядел «чужим» рядом с оболочкой, где
        // системный титлбар показывает иконку приложения.
        var logoPath = System.IO.Path.Combine(System.AppContext.BaseDirectory, "Assets", "rimeo1024.png");
        if (System.IO.File.Exists(logoPath))
            brand.Children.Add(new Border
            {
                Width = 18, Height = 18, CornerRadius = new CornerRadius(5),
                VerticalAlignment = VerticalAlignment.Center, Background = UI.Clear,
                Margin = new Thickness(0, 0, 2, 0),
                Child = new Microsoft.UI.Xaml.Controls.Image
                {
                    Width = 18, Height = 18, Stretch = Microsoft.UI.Xaml.Media.Stretch.UniformToFill,
                    Source = new Microsoft.UI.Xaml.Media.Imaging.BitmapImage(new Uri(logoPath))
                }
            });
        brand.Children.Add(new TextBlock { Text = "Rimeo", FontSize = 13, FontWeight = FontWeights.Bold, Foreground = UI.TitleInk, CharacterSpacing = -10 });
        brand.Children.Add(new TextBlock { Text = "Agent", FontSize = 13, FontWeight = FontWeights.Medium, Foreground = UI.TitleDim, CharacterSpacing = -10 });
        Grid.SetColumn(brand, 0);
        grid.Children.Add(brand);
        TitleBarDragRegion = brand;

        var controls = new StackPanel { Orientation = Orientation.Horizontal, VerticalAlignment = VerticalAlignment.Stretch };
        controls.Children.Add(WindowButton(UI.Icon(12, UI.WinCtrl, 1.6, "M5 12L19 12"),
            (_, _) => MainWindow.Instance?.MinimizeGate()));
        controls.Children.Add(WindowButton(UI.Icon(12, UI.WinCtrl, 1.6,
            "M6.5 5H17.5A1.5 1.5 0 0 1 19 6.5V17.5A1.5 1.5 0 0 1 17.5 19H6.5A1.5 1.5 0 0 1 5 17.5V6.5A1.5 1.5 0 0 1 6.5 5Z"),
            (_, _) => MainWindow.Instance?.ToggleMaximizeGate()));
        controls.Children.Add(WindowButton(UI.Icon(12, UI.WinCtrl, 1.6, "M6 6L18 18", "M18 6L6 18"),
            (_, _) => MainWindow.Instance?.CloseGate(), close: true));
        Grid.SetColumn(controls, 1);
        grid.Children.Add(controls);

        return new Border { Background = UI.WinChrome, Child = grid };
    }

    // Высота ровно по полосе титлбара (52): при 46 сверху и снизу оставалось по 3px
    // пустоты, тогда как нативные caption-кнопки занимают полную высоту. У «закрыть» —
    // красная подсветка на наведении, как в системном чроме Windows.
    private static Button WindowButton(UIElement icon, RoutedEventHandler onClick, bool close = false)
    {
        var b = new Button
        {
            Width = 46, Height = TitleBarHeight, Padding = new Thickness(0), CornerRadius = new CornerRadius(0),
            BorderThickness = new Thickness(0), Background = UI.Clear,
            VerticalAlignment = VerticalAlignment.Stretch,
            Content = icon
        };
        var hover = close ? UI.Red : UI.Chip;
        b.Resources["ButtonBackground"]             = UI.Clear;
        b.Resources["ButtonBackgroundPointerOver"]  = hover;
        b.Resources["ButtonBackgroundPressed"]      = hover;
        b.Resources["ButtonBorderBrush"]            = UI.Clear;
        b.Resources["ButtonBorderBrushPointerOver"] = UI.Clear;
        b.Resources["ButtonBorderBrushPressed"]     = UI.Clear;
        if (close)
            b.PointerEntered += (_, _) => RecolorIcon(icon, UI.White);
        if (close)
            b.PointerExited += (_, _) => RecolorIcon(icon, UI.WinCtrl);
        b.Click += onClick;
        return b;
    }

    private static void RecolorIcon(UIElement icon, SolidColorBrush brush)
    {
        if (icon is Viewbox { Child: Canvas canvas })
            foreach (var child in canvas.Children)
                if (child is Microsoft.UI.Xaml.Shapes.Path p)
                    p.Stroke = brush;
    }

    // ── Centered sign-in / create-account card ────────────────────────────────
    private Grid BuildGate()
    {
        var host = new Grid();
        var gate = new StackPanel
        {
            Orientation = Orientation.Vertical, Width = 430,
            HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center
        };

        // Account emblem (в режиме Create account получает «плюс» — как на macOS)
        _emblem = new Border
        {
            Width = 60, Height = 60, CornerRadius = new CornerRadius(17),
            Background = UI.LockBg, BorderBrush = UI.LockBrd, BorderThickness = new Thickness(1),
            HorizontalAlignment = HorizontalAlignment.Center
        };
        gate.Children.Add(_emblem);

        var headingBlock = new StackPanel
        {
            Orientation = Orientation.Vertical, Spacing = 9, Width = 360,
            HorizontalAlignment = HorizontalAlignment.Center, Margin = new Thickness(0, 22, 0, 0)
        };
        headingBlock.Children.Add(_title);
        headingBlock.Children.Add(_subtitle);
        gate.Children.Add(headingBlock);

        var form = new StackPanel
        {
            Orientation = Orientation.Vertical, Spacing = 16, Width = 374,
            HorizontalAlignment = HorizontalAlignment.Center, Margin = new Thickness(0, 28, 0, 0)
        };
        form.Children.Add(BuildEmailField());
        form.Children.Add(BuildPasswordField());
        form.Children.Add(BuildPrimaryButton());
        form.Children.Add(BuildFooter());
        _sessionNote = BuildSessionNote();
        form.Children.Add(_sessionNote);
        form.Children.Add(_info);
        form.Children.Add(_status);
        gate.Children.Add(form);

        // Форма живёт на фиксированных ширинах и высоте ~600: при 150% системном
        // масштабе в невысоком окне низ (кнопка входа) просто обрезался без шанса
        // доскроллить.
        host.Children.Add(new ScrollViewer
        {
            Content = gate,
            VerticalScrollBarVisibility = ScrollBarVisibility.Auto,
            HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled,
            // Content-alignment обязателен: без него ScrollViewer прижимает форму к
            // верху, и на большом окне она перестала бы стоять по центру.
            VerticalContentAlignment = VerticalAlignment.Center,
            HorizontalContentAlignment = HorizontalAlignment.Center,
            Padding = new Thickness(0, 24, 0, 24)
        });
        return host;
    }

    private StackPanel BuildEmailField()
    {
        var label = new TextBlock { Text = "Email", FontSize = 13, FontWeight = FontWeights.Medium, Foreground = UI.Secondary };

        _emailBox.PlaceholderText = "you@email.com";
        _emailBox.FontSize = 14;
        _emailBox.Foreground = UI.Text;
        _emailBox.Background = new SolidColorBrush(Microsoft.UI.Colors.Transparent);
        _emailBox.BorderThickness = new Thickness(0);
        _emailBox.Padding = new Thickness(0);
        _emailBox.KeyDown += (_, e) => { if (e.Key == VirtualKey.Enter) Submit(); };
        UI.StripFieldChrome(_emailBox);

        var icon = UI.Icon(17, UI.Dim, 2,
            "M4 5H20A1 1 0 0 1 21 6V18A1 1 0 0 1 20 19H4A1 1 0 0 1 3 18V6A1 1 0 0 1 4 5Z", "M3 7l9 6 9-6");

        var stack = new StackPanel { Orientation = Orientation.Vertical, Spacing = 7, Width = 374 };
        stack.Children.Add(label);
        stack.Children.Add(InputRow(icon, _emailBox));
        return stack;
    }

    private StackPanel BuildPasswordField()
    {
        var headerRow = new Grid();
        headerRow.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        headerRow.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });

        var pwLabel = new TextBlock { Text = "Password", FontSize = 13, FontWeight = FontWeights.Medium, Foreground = UI.Secondary, VerticalAlignment = VerticalAlignment.Center };
        Grid.SetColumn(pwLabel, 0);
        headerRow.Children.Add(pwLabel);

        _forgotBtn = UI.LinkButton(
            new TextBlock { Text = "Forgot password?", FontSize = 13, FontWeight = FontWeights.Medium, Foreground = UI.AccText },
            (_, _) => OpenForgot());
        _forgotBtn.Padding = new Thickness(0);
        _helper = new TextBlock { Text = "Use 8+ characters", FontSize = 13, Foreground = UI.Dim, VerticalAlignment = VerticalAlignment.Center, Visibility = Visibility.Collapsed };

        var right = new Grid { HorizontalAlignment = HorizontalAlignment.Right };
        right.Children.Add(_forgotBtn);
        right.Children.Add(_helper);
        Grid.SetColumn(right, 1);
        headerRow.Children.Add(right);

        _passwordBox.PlaceholderText = "Your password";
        _passwordBox.FontSize = 14;
        _passwordBox.Foreground = UI.Text;
        _passwordBox.Background = new SolidColorBrush(Microsoft.UI.Colors.Transparent);
        _passwordBox.BorderThickness = new Thickness(0);
        _passwordBox.Padding = new Thickness(0);
        _passwordBox.KeyDown += (_, e) => { if (e.Key == VirtualKey.Enter) Submit(); };
        UI.StripFieldChrome(_passwordBox);
        // Peek, а не Hidden: встроенный «глазок» был выключен, и при опечатке
        // пользователь не мог себя проверить — только «Sign-in failed». На macOS
        // кнопка показа пароля есть. Красим её в наш Dim, чтобы не выпадала из поля.
        _passwordBox.PasswordRevealMode = PasswordRevealMode.Peek;
        _passwordBox.Resources["TextControlButtonForeground"] = UI.Dim;
        _passwordBox.Resources["TextControlButtonForegroundPointerOver"] = UI.AccText;
        _passwordBox.Resources["TextControlButtonBackground"] = UI.Clear;
        _passwordBox.Resources["TextControlButtonBackgroundPointerOver"] = UI.Chip;

        var lockIcon = UI.Icon(17, UI.Dim, 2,
            "M5 11H19A1 1 0 0 1 20 12V20A1 1 0 0 1 19 21H5A1 1 0 0 1 4 20V12A1 1 0 0 1 5 11Z", "M8 11V8a4 4 0 0 1 8 0v3");

        var stack = new StackPanel { Orientation = Orientation.Vertical, Spacing = 7, Width = 374 };
        stack.Children.Add(headerRow);
        stack.Children.Add(InputRow(lockIcon, _passwordBox));
        return stack;
    }

    // Field shell: leading icon + control inside a rounded, bordered box.
    private static Border InputRow(FrameworkElement icon, FrameworkElement control)
    {
        var grid = new Grid();
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });

        icon.Margin = new Thickness(0, 0, 10, 0);
        icon.VerticalAlignment = VerticalAlignment.Center;
        Grid.SetColumn(icon, 0);
        grid.Children.Add(icon);

        // Текст сидел ВЫШЕ середины поля: `VerticalAlignment.Center` центрирует сам
        // контрол (его MinHeight 32 в поле высотой 46), но текст ВНУТРИ контрола
        // WinUI прижимает к верху — `VerticalContentAlignment` по умолчанию Top.
        // Ровно та же болячка, что была у поля «Max cache» на Settings.
        control.VerticalAlignment = VerticalAlignment.Stretch;
        if (control is Control c)
        {
            c.VerticalContentAlignment = VerticalAlignment.Center;
            c.MinHeight = 0;
        }
        Grid.SetColumn(control, 1);
        grid.Children.Add(control);

        return new Border
        {
            Height = 46, CornerRadius = new CornerRadius(10),
            Background = UI.Field, BorderBrush = UI.Brd, BorderThickness = new Thickness(1),
            Padding = new Thickness(14, 0, 12, 0),
            Child = grid
        };
    }

    // Снятие системного хрома с полей переехало в UI.StripFieldChrome — тем же приёмом
    // теперь лечатся поля на Settings (баг-репорт, лимит кэша).

    private Button BuildPrimaryButton()
    {
        var content = new StackPanel
        {
            Orientation = Orientation.Horizontal, Spacing = 9,
            HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center
        };
        _primaryArrow = UI.Icon(17, UI.White, 2.1, "M5 12H19", "M13 6l6 6-6 6");
        content.Children.Add(_primarySpinner);
        content.Children.Add(_primaryLabel);
        content.Children.Add(_primaryArrow);

        var b = new Button
        {
            Width = 374, Height = 46, CornerRadius = new CornerRadius(12), BorderThickness = new Thickness(0),
            Background = UI.Acc, HorizontalContentAlignment = HorizontalAlignment.Center, VerticalContentAlignment = VerticalAlignment.Center,
            Content = content
        };
        // The default WinUI Button template swaps ContentPresenter.Background to the
        // near-white ButtonBackgroundPointerOver on hover; behind the white label that
        // makes the accent button look like it vanishes. Pin fill + white content
        // across Normal/PointerOver/Pressed on the button's own Resources.
        var clearBrush = new SolidColorBrush(Microsoft.UI.Colors.Transparent);
        b.Resources["ButtonBackground"]             = UI.Acc;
        b.Resources["ButtonBackgroundPointerOver"]  = UI.Acc;
        b.Resources["ButtonBackgroundPressed"]      = UI.Acc;
        b.Resources["ButtonForeground"]             = UI.White;
        b.Resources["ButtonForegroundPointerOver"]  = UI.White;
        b.Resources["ButtonForegroundPressed"]      = UI.White;
        b.Resources["ButtonBorderBrushPointerOver"] = clearBrush;
        b.Resources["ButtonBorderBrushPressed"]     = clearBrush;
        b.Resources["ButtonBackgroundDisabled"]     = UI.Alpha(UI.Acc, 0xB0);
        b.Resources["ButtonForegroundDisabled"]     = UI.White;
        b.Click += (_, _) => Submit();
        _primaryBtn = b;
        return b;
    }

    private StackPanel BuildFooter()
    {
        var stack = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 5, HorizontalAlignment = HorizontalAlignment.Center };
        stack.Children.Add(_footerLead);
        var linkBtn = UI.LinkButton(_footerLinkLabel, (_, _) => ToggleMode());
        linkBtn.Padding = new Thickness(0);
        stack.Children.Add(linkBtn);
        return stack;
    }

    private Border BuildSessionNote()
    {
        // Grid, а не горизонтальный StackPanel: в StackPanel текст меряется бесконечной
        // шириной и НЕ переносится, поэтому раньше стояла жёсткая `Width = 320` — она и
        // упирала строку в правый край карточки, отрывая «other.» на вторую строку.
        var row = new Grid { VerticalAlignment = VerticalAlignment.Center };
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });

        var noteIcon = UI.Icon(15, UI.Dim, 2, "M12 21a9 9 0 1 0 0-18 9 9 0 0 0 0 18Z", "M12 16v-4", "M12 8h.01");
        noteIcon.VerticalAlignment = VerticalAlignment.Center;
        noteIcon.Margin = new Thickness(0, 0, 9, 0);
        Grid.SetColumn(noteIcon, 0);
        row.Children.Add(noteIcon);

        var noteText = new TextBlock
        {
            Text = "One agent per account — signing in here signs out any other.",
            FontSize = 13, Foreground = UI.Secondary, TextWrapping = TextWrapping.Wrap,
            VerticalAlignment = VerticalAlignment.Center
        };
        Grid.SetColumn(noteText, 1);
        row.Children.Add(noteText);
        return new Border
        {
            Background = UI.Surf, BorderBrush = UI.CardBrd, BorderThickness = new Thickness(1),
            CornerRadius = new CornerRadius(12), Padding = new Thickness(15, 11, 15, 11),
            Child = row
        };
    }

    private void ApplyMode()
    {
        _title.Text = _isSignIn ? "Sign in to Rimeo" : "Create your account";
        _subtitle.Text = _isSignIn
            ? "Use your Rimeo account to connect this agent. Your library stays in sync everywhere you listen."
            : "Set up a Rimeo account to sync your library everywhere you listen.";
        _forgotBtn.Visibility = _isSignIn ? Visibility.Visible : Visibility.Collapsed;
        _helper.Visibility    = _isSignIn ? Visibility.Collapsed : Visibility.Visible;
        _passwordBox.PlaceholderText = _isSignIn ? "Your password" : "Create a password";
        _primaryLabel.Text = _busy
            ? (_isSignIn ? "Signing in…" : "Creating…")
            : (_isSignIn ? "Sign in" : "Create account");
        _footerLead.Text = _isSignIn ? "New to Rimeo?" : "Already have an account?";
        _footerLinkLabel.Text = _isSignIn ? "Create account" : "Sign in";
        _sessionNote.Visibility = _isSignIn ? Visibility.Visible : Visibility.Collapsed;

        // В busy менялся только текст: стрелка «→» оставалась, спиннера не было, и
        // кнопка выглядела нажимаемой (macOS: ProgressView + скрытая стрелка + disabled).
        _primarySpinner.Visibility = _busy ? Visibility.Visible : Visibility.Collapsed;
        _primaryArrow.Visibility   = _busy ? Visibility.Collapsed : Visibility.Visible;
        if (_primaryBtn != null) _primaryBtn.IsEnabled = !_busy;

        // Эмблема в режиме создания аккаунта получает «плюс».
        _emblem.Child = _isSignIn
            ? UI.Icon(28, UI.Acc, 2, "M12 12a4 4 0 1 0 0-8 4 4 0 0 0 0 8Z", "M5 20a7 7 0 0 1 14 0")
            : UI.Icon(28, UI.Acc, 2, "M11 12a4 4 0 1 0 0-8 4 4 0 0 0 0 8Z", "M4 20a7 7 0 0 1 12.5-4.3",
                                     "M18 15.5v6", "M15 18.5h6");
    }

    private void ToggleMode()
    {
        _isSignIn = !_isSignIn;
        _status.Visibility = Visibility.Collapsed;
        ApplyMode();
    }

    private async void OpenForgot()
    {
        try { await Launcher.LaunchUriAsync(new Uri($"{AppConfig.RimeoAppUrl}/forgot-password")); }
        catch (Exception ex) { Log.Error($"Open forgot-password failed: {ex.Message}"); }
    }

    private async void Submit()
    {
        if (_busy) return;

        var email = _emailBox.Text.Trim().ToLowerInvariant();
        var password = _passwordBox.Password;
        if (!email.Contains('@') || string.IsNullOrEmpty(password))
        { ShowStatus("Enter your email and password.", ok: false); return; }
        if (!_isSignIn && password.Length < 8)
        { ShowStatus("Password must be at least 8 characters.", ok: false); return; }

        _busy = true;
        ApplyMode();
        ShowStatus(_isSignIn ? "Signing in…" : "Creating account…", ok: true);

        var path = _isSignIn ? "/api/agent_login" : "/api/agent_signup";
        try
        {
            using var http = new HttpClient();
            var payload = JsonSerializer.Serialize(new { email, password });
            var resp = await http.PostAsync($"http://127.0.0.1:{AppConfig.Port}{path}?lan_token={Uri.EscapeDataString(RimeoAgent.Models.DataStore.Shared.Data.LanSecret)}",
                new StringContent(payload, Encoding.UTF8, "application/json"));
            var resultStr = await resp.Content.ReadAsStringAsync();

            if (resp.IsSuccessStatusCode)
            {
                AppState.Shared.RefreshFromData();
                _onLinked();
                return;
            }

            var msg = _isSignIn ? "Sign-in failed. Check your email and password." : "Could not create the account.";
            try
            {
                var err = JsonSerializer.Deserialize<Dictionary<string, JsonElement>>(resultStr);
                if (err?.TryGetValue("error", out var errEl) == true) msg = errEl.GetString() ?? msg;
            }
            catch { }
            _busy = false; ApplyMode();
            ShowStatus(msg, ok: false);
        }
        catch (Exception ex)
        {
            Log.Error($"Agent sign-in failed: {ex.Message}");
            _busy = false; ApplyMode();
            ShowStatus($"Error: {ex.Message}", ok: false);
        }
    }

    private void ShowStatus(string text, bool ok)
    {
        _status.Visibility = Visibility.Visible;
        _status.Text = text;
        _status.Foreground = ok ? UI.Secondary : UI.Red;
    }

    private void ShowInfo(string text)
    {
        _info.Visibility = Visibility.Visible;
        _info.Text = text;
    }
}
