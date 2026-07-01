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
        Loaded += (_, _) => _emailBox.Focus(FocusState.Programmatic);
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
            Orientation = Orientation.Horizontal, Spacing = 7, VerticalAlignment = VerticalAlignment.Center,
            Padding = new Thickness(22, 0, 0, 0),
            Background = new SolidColorBrush(Microsoft.UI.Colors.Transparent)
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
            Width = 46, Height = 46, Padding = new Thickness(0), CornerRadius = new CornerRadius(0),
            BorderThickness = new Thickness(0), Background = new SolidColorBrush(Microsoft.UI.Colors.Transparent),
            Content = icon
        };
        b.Click += onClick;
        return b;
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

        // Account emblem
        gate.Children.Add(new Border
        {
            Width = 60, Height = 60, CornerRadius = new CornerRadius(17),
            Background = UI.LockBg, BorderBrush = UI.LockBrd, BorderThickness = new Thickness(1),
            HorizontalAlignment = HorizontalAlignment.Center,
            Child = UI.Icon(28, UI.Acc, 2, "M12 12a4 4 0 1 0 0-8 4 4 0 0 0 0 8Z", "M5 20a7 7 0 0 1 14 0")
        });

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
        form.Children.Add(_status);
        gate.Children.Add(form);

        host.Children.Add(gate);
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
        _emailBox.VerticalAlignment = VerticalAlignment.Center;
        _emailBox.KeyDown += (_, e) => { if (e.Key == VirtualKey.Enter) Submit(); };

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

        _forgotBtn = new Button
        {
            Background = new SolidColorBrush(Microsoft.UI.Colors.Transparent), BorderThickness = new Thickness(0), Padding = new Thickness(0),
            Content = new TextBlock { Text = "Forgot password?", FontSize = 13, FontWeight = FontWeights.Medium, Foreground = UI.AccText }
        };
        _forgotBtn.Click += (_, _) => OpenForgot();
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
        _passwordBox.VerticalAlignment = VerticalAlignment.Center;
        _passwordBox.KeyDown += (_, e) => { if (e.Key == VirtualKey.Enter) Submit(); };

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

        control.VerticalAlignment = VerticalAlignment.Center;
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

    private Button BuildPrimaryButton()
    {
        var content = new StackPanel
        {
            Orientation = Orientation.Horizontal, Spacing = 9,
            HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center
        };
        content.Children.Add(_primaryLabel);
        content.Children.Add(UI.Icon(17, UI.White, 2.1, "M5 12H19", "M13 6l6 6-6 6"));

        var b = new Button
        {
            Width = 374, Height = 46, CornerRadius = new CornerRadius(12), BorderThickness = new Thickness(0),
            Background = UI.Acc, HorizontalContentAlignment = HorizontalAlignment.Center, VerticalContentAlignment = VerticalAlignment.Center,
            Content = content
        };
        b.Click += (_, _) => Submit();
        return b;
    }

    private StackPanel BuildFooter()
    {
        var stack = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 5, HorizontalAlignment = HorizontalAlignment.Center };
        stack.Children.Add(_footerLead);
        var linkBtn = new Button
        {
            Background = new SolidColorBrush(Microsoft.UI.Colors.Transparent), BorderThickness = new Thickness(0), Padding = new Thickness(0),
            Content = _footerLinkLabel
        };
        linkBtn.Click += (_, _) => ToggleMode();
        stack.Children.Add(linkBtn);
        return stack;
    }

    private Border BuildSessionNote()
    {
        var row = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 9, VerticalAlignment = VerticalAlignment.Center };
        row.Children.Add(UI.Icon(15, UI.Dim, 2, "M12 21a9 9 0 1 0 0-18 9 9 0 0 0 0 18Z", "M12 16v-4", "M12 8h.01"));
        row.Children.Add(new TextBlock
        {
            Text = "One agent per account — signing in here signs out any other.",
            FontSize = 13, Foreground = UI.Secondary, TextWrapping = TextWrapping.Wrap,
            VerticalAlignment = VerticalAlignment.Center, Width = 320
        });
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
}
