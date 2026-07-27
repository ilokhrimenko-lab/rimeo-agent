using System.Net.Http;
using System.Text;
using System.Text.Json;
using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using RimeoAgent.Config;
using RimeoAgent.Models;
using RimeoAgent.Services;
using Windows.ApplicationModel.DataTransfer;

namespace RimeoAgent.Views;

// 1:1 mirror of macOS LogsTabView ("Settings"): appearance + agent settings +
// in-app updates + report a bug + cache management.
public sealed partial class LogsPage : Page
{
    private readonly TextBlock  _settingsStatus = new() { FontSize = 12, Visibility = Visibility.Collapsed };
    private readonly StackPanel _updateHost     = new() { Orientation = Orientation.Vertical, Spacing = 10 };

    private readonly TextBox    _bugBox         = new() { PlaceholderText = "Describe the issue…", AcceptsReturn = true, TextWrapping = TextWrapping.Wrap, Height = 110, FontSize = 13 };
    private readonly TextBlock  _bugStatus      = new() { FontSize = 13, Visibility = Visibility.Collapsed, TextWrapping = TextWrapping.Wrap };
    private readonly StackPanel _bugButtonHost  = new() { Orientation = Orientation.Horizontal, Spacing = 10, VerticalAlignment = VerticalAlignment.Center };

    private readonly TextBlock    _cacheUsage   = new() { FontSize = 22, FontWeight = FontWeights.ExtraBold, Foreground = UI.Text, Text = "0.00 GB used" };
    private readonly ProgressBar  _cacheBar     = new() { Minimum = 0, Maximum = 3, Value = 0, Height = 8, HorizontalAlignment = HorizontalAlignment.Stretch };
    private readonly TextBlock    _cacheMax     = new() { FontSize = 13, FontWeight = FontWeights.Medium, Foreground = UI.Dim, Text = "of 3 GB max", VerticalAlignment = VerticalAlignment.Center };
    // Число в поле «Max cache» висело выше и правее центра: WinUI растягивает TextBox
    // по высоте строки, но content-alignment у него Top, а дефолтный TextControlThemePadding
    // несимметричен по горизонтали — центрирование считалось от смещённой области.
    private readonly TextBox      _cacheMaxBox  = new()
    {
        Width = 64, Text = "3", FontSize = 14,
        TextAlignment = TextAlignment.Center,
        VerticalContentAlignment = VerticalAlignment.Center,
        Padding = new Thickness(0)
    };
    // Сообщение живёт в звёздной колонке между «Clear Cache» и группой «Max cache»:
    // текст ошибки произвольной длины без обрезки резало по глифу.
    private readonly TextBlock    _cacheStatus  = new()
    {
        FontSize = 12, Visibility = Visibility.Collapsed,
        TextTrimming = TextTrimming.CharacterEllipsis
    };

    private readonly StackPanel _themeHost = new() { Orientation = Orientation.Horizontal, Spacing = 4 };

    // Ход установки берём ТОЛЬКО опросом AgentUpdateService.Status() — он же отвечает
    // телефону на GET /api/agent/update/status. Колбэк DownloadAndApply как источник
    // прогресса не годится: он виден лишь этому окну, и телефон, опрашивающий статус
    // во время UI-обновления, получал бы "idle" ("обновлений нет") прямо под замену
    // агента. Один источник правды → одна картинка на обоих экранах.
    private DispatcherTimer? _updatePoll;
    private readonly TextBlock   _updateStage = new() { FontSize = 14, Foreground = UI.Secondary, VerticalAlignment = VerticalAlignment.Center, TextWrapping = TextWrapping.Wrap };
    private readonly ProgressBar _updateBar   = new() { Minimum = 0, Maximum = 1, Value = 0, Height = 6, HorizontalAlignment = HorizontalAlignment.Stretch };

    public LogsPage()
    {
        InitializeComponent();
        Content = Build();
        BuildUpdateIdle();
        RebuildThemeSegmented();
        RefreshCacheSize();

        // Таймер живёт дольше страницы, если его не погасить: после ухода со Settings
        // он продолжал бы дёргать Status() и писать в отсоединённые TextBlock'и.
        Unloaded += (_, _) => StopUpdatePolling();
    }

    private ScrollViewer Build()
    {
        var (scroll, stack) = UI.Page();

        var ver = new Border
        {
            Background = UI.Chip,
            CornerRadius = new CornerRadius(9),
            Padding = new Thickness(11, 6, 11, 6),
            Child = new TextBlock { Text = AppConfig.Shared.DisplayVersion, FontSize = 12, FontFamily = new FontFamily("Consolas"), Foreground = UI.Secondary }
        };
        stack.Children.Add(UI.ScreenHeader("Settings", "Manage how the Rimeo agent runs on this PC.", ver));

        // APPEARANCE
        stack.Children.Add(UI.SectionLabel("Appearance"));
        var seg = new Border { Background = UI.SegTrack, CornerRadius = new CornerRadius(14), Padding = new Thickness(4), Child = _themeHost, HorizontalAlignment = HorizontalAlignment.Left };
        stack.Children.Add(UI.VStack(11, seg,
            UI.Body("Auto follows your Windows appearance. Light or Dark forces a fixed theme.", UI.Dim, 13)));

        // AGENT SETTINGS
        stack.Children.Add(UI.SectionLabel("Agent settings"));
        var launch = UI.Checkbox(AgentSettings.LaunchAtLogin, "Open Rimeo agent at system startup", SetLaunch);
        stack.Children.Add(UI.Card(UI.VStack(8, launch, _settingsStatus)));

        // SOFTWARE UPDATE
        stack.Children.Add(UI.SectionLabel("Software update"));
        stack.Children.Add(UI.Card(_updateHost));

        // REPORT A BUG
        stack.Children.Add(UI.SectionLabel("Report a bug"));
        // Раньше задавались только локальные кисти: состояния PointerOver/Focused
        // перекрашивали поле в системный белый и рисовали акцентное подчёркивание.
        UI.StyleField(_bugBox);
        _bugBox.BorderBrush = UI.CardBrd;
        _bugBox.Padding = new Thickness(12, 10, 12, 10);
        _bugButtonHost.Children.Add(UI.PrimaryButton("Send report", SendBug_Click));
        var bugCard = UI.VStack(14,
            UI.Body("Describe the issue — the last 200 log lines are attached automatically.", UI.Secondary, 13),
            _bugBox,
            UI.HStack(10,
                _bugButtonHost,
                UI.SecondaryButton("Copy log", CopyLog_Click),
                UI.SecondaryButton("Open log", OpenLog_Click)),
            _bugStatus);
        stack.Children.Add(UI.Card(bugCard));

        // CACHE
        stack.Children.Add(UI.SectionLabel("Cache"));
        _cacheBar.Foreground = UI.Acc;
        _cacheBar.Background = UI.Chip;

        var usageTop = new Grid();
        usageTop.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        usageTop.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        Grid.SetColumn(_cacheUsage, 0); usageTop.Children.Add(_cacheUsage);
        Grid.SetColumn(_cacheMax, 1); usageTop.Children.Add(_cacheMax);

        var divider = new Border { Height = 1, Background = UI.CardBrd };

        var controls = new Grid { VerticalAlignment = VerticalAlignment.Center };
        controls.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        controls.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        controls.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        var clearBtn = UI.DestructiveButton("Clear cache", ClearCache_Click);
        Grid.SetColumn(clearBtn, 0); controls.Children.Add(clearBtn);
        _cacheStatus.VerticalAlignment = VerticalAlignment.Center;
        _cacheStatus.Margin = new Thickness(12, 0, 0, 0);
        Grid.SetColumn(_cacheStatus, 1); controls.Children.Add(_cacheStatus);

        UI.StyleField(_cacheMaxBox);
        // «GB» рядом с числом: в голом боксе на 64px «3» не говорило, гигабайты это
        // или проценты (macOS кладёт единицу прямо в поле).
        var maxBox = new Border
        {
            Background = UI.Field, BorderBrush = UI.Brd, BorderThickness = new Thickness(1),
            CornerRadius = new CornerRadius(12), Padding = new Thickness(12, 0, 12, 0),
            VerticalAlignment = VerticalAlignment.Stretch,
            Child = UI.HStack(6,
                _cacheMaxBox,
                new TextBlock { Text = "GB", FontSize = 12, FontWeight = FontWeights.Medium, Foreground = UI.Dim, VerticalAlignment = VerticalAlignment.Center })
        };
        _cacheMaxBox.Background = UI.Clear;
        _cacheMaxBox.BorderThickness = new Thickness(0);
        _cacheMaxBox.Width = 34;
        _cacheMaxBox.MaxLength = 3;

        var right = UI.HStack(10,
            new TextBlock { Text = "Max cache", FontSize = 13, FontWeight = FontWeights.Medium, Foreground = UI.Secondary, VerticalAlignment = VerticalAlignment.Center },
            maxBox,
            UI.PrimaryButton("Save", SaveMaxCache_Click));
        Grid.SetColumn(right, 2); controls.Children.Add(right);

        var cacheCard = UI.VStack(16,
            UI.Body("Converted audio, waveforms and artwork are stored here so tracks load instantly on repeat plays.", UI.Secondary, 13),
            UI.VStack(9, usageTop, _cacheBar),
            divider,
            controls);
        stack.Children.Add(UI.Card(cacheCard));

        return scroll;
    }

    // ── Appearance segmented ────────────────────────────────────────────────
    private void RebuildThemeSegmented()
    {
        _themeHost.Children.Clear();
        _themeHost.Children.Add(ThemeSeg(AppTheme.Auto, "Auto"));
        _themeHost.Children.Add(ThemeSeg(AppTheme.Light, "Light"));
        _themeHost.Children.Add(ThemeSeg(AppTheme.Dark, "Dark"));
    }

    private Button ThemeSeg(AppTheme value, string label)
    {
        var active = ThemeManager.Theme == value;
        var fill   = active ? UI.SegActive : UI.Clear;
        var ink    = active ? UI.Text : UI.Secondary;
        var btn = new Button
        {
            Content = new TextBlock { Text = label, FontSize = 14, FontWeight = active ? FontWeights.SemiBold : FontWeights.Medium, Foreground = ink },
            Background = fill,
            BorderThickness = new Thickness(0),
            CornerRadius = new CornerRadius(11),
            Padding = new Thickness(18, 9, 18, 9)
        };
        // Иначе шаблон подставит системный почти-белый ховер прямо внутрь тёмной
        // сегмент-дорожки.
        btn.Resources["ButtonBackground"]            = fill;
        btn.Resources["ButtonBackgroundPointerOver"] = active ? UI.SegActive : UI.Chip;
        btn.Resources["ButtonBackgroundPressed"]     = active ? UI.SegActive : UI.Chip;
        btn.Resources["ButtonForeground"]            = ink;
        btn.Resources["ButtonForegroundPointerOver"] = UI.Text;
        btn.Resources["ButtonForegroundPressed"]     = UI.Text;
        btn.Resources["ButtonBorderBrush"]            = UI.Clear;
        btn.Resources["ButtonBorderBrushPointerOver"] = UI.Clear;
        btn.Resources["ButtonBorderBrushPressed"]     = UI.Clear;
        btn.Click += (_, _) =>
        {
            ThemeManager.Theme = value;
            MainWindow.Instance?.ApplyTheme();
        };
        return btn;
    }

    private void SetLaunch(bool on)
    {
        AgentSettings.LaunchAtLogin = on;
        _settingsStatus.Visibility = Visibility.Visible;
        _settingsStatus.Text = on ? "✓ Launch at startup enabled" : "✓ Launch at startup disabled";
        _settingsStatus.Foreground = UI.Green;
    }

    // ── Update checker UI ───────────────────────────────────────────────────
    private void BuildUpdateIdle()
    {
        // Установку мог запустить телефон (POST /api/agent/update) ещё до того, как
        // открыли Settings. Показывать в этот момент "Check for updates" — врать:
        // спрашиваем состояние у сервиса и, если он занят, сразу рисуем прогресс.
        var st = AgentUpdateService.Shared.Status();
        if (IsActiveStage(st.Stage)) { ShowUpdateProgress(st); StartUpdatePolling(); return; }
        if (st.Stage == AgentUpdateService.StageError)
        {
            BuildUpdateFailed(st.Error ?? "Update failed");
            return;
        }

        // Тихий фоновой апдейтер мог УЖЕ скачать новый билд (CheckAndStageSilently) —
        // он поставится на следующем запуске. Молчать об этом и показывать «Check for
        // Updates» значит врать: билд лежит на диске, а UI об этом ни слова.
        var staged = UpdateChecker.Shared.StagedVersion;
        if (!string.IsNullOrEmpty(staged)) { BuildUpdateStaged(staged); return; }

        _updateHost.Children.Clear();
        _updateHost.Children.Add(UpdateRow(
            IconRefresh, UI.AccText, UI.AccSoft,
            "Software updates", "Check whether a newer build is available",
            UI.SecondaryButton("Check for updates", (_, _) => RunUpdateCheck())));
    }

    // ── Строка состояния обновления: иконка в плашке 38×38 + два текста + действие ──
    private static readonly string[] IconRefresh =
        { "M20 12a8 8 0 1 1-2.34-5.66", "M20 4v4h-4" };
    private static readonly string[] IconCheck =
        { "M5 12.5l4.5 4.5L19 7.5" };
    private static readonly string[] IconDownload =
        { "M12 4v11", "M7.5 11l4.5 4.5 4.5-4.5", "M5 20h14" };
    private static readonly string[] IconClock =
        { "M12 21a9 9 0 1 0 0-18 9 9 0 0 0 0 18Z", "M12 7.5V12l3 2" };
    private static readonly string[] IconWarn =
        { "M12 4.5 2.8 20h18.4L12 4.5Z", "M12 10v4.5", "M12 17.4h.01" };

    private static Grid UpdateRow(string[] icon, SolidColorBrush tint, SolidColorBrush bg,
                                  string title, string? subtitle, FrameworkElement? action)
    {
        var grid = new Grid();
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });

        var box = new Border
        {
            Width = 38, Height = 38, CornerRadius = new CornerRadius(11), Background = bg,
            VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(0, 0, 14, 0),
            Child = UI.Icon(19, tint, 2, icon)
        };
        Grid.SetColumn(box, 0); grid.Children.Add(box);

        var texts = new StackPanel { Orientation = Orientation.Vertical, Spacing = 2, VerticalAlignment = VerticalAlignment.Center };
        texts.Children.Add(new TextBlock { Text = title, FontSize = 15, FontWeight = FontWeights.SemiBold, Foreground = UI.Text, TextWrapping = TextWrapping.Wrap });
        if (!string.IsNullOrEmpty(subtitle))
            texts.Children.Add(new TextBlock { Text = subtitle, FontSize = 13, Foreground = UI.Dim, TextWrapping = TextWrapping.Wrap });
        Grid.SetColumn(texts, 1); grid.Children.Add(texts);

        if (action != null)
        {
            action.VerticalAlignment = VerticalAlignment.Center;
            action.Margin = new Thickness(14, 0, 0, 0);
            Grid.SetColumn(action, 2); grid.Children.Add(action);
        }
        return grid;
    }

    private void BuildUpdateStaged(string version)
    {
        _updateHost.Children.Clear();
        _updateHost.Children.Add(UpdateRow(
            IconClock, UI.Amber, UI.Alpha(UI.Amber, 0x24),
            $"Will update to {version} on next launch", "Already downloaded — restart the agent to apply it now.",
            UI.SecondaryButton("Update now", (_, _) => UpdateNow())));
    }

    // "Check for updates" НЕ идёт через AgentUpdateService намеренно: он ничего не
    // ставит и не должен занимать слот _running (иначе проверка из UI блокировала бы
    // обновление с телефона). Единственная правка — честная обработка сбоя сети:
    // QueryLatest глотает исключения и возвращает null, поэтому null+LastCheckError
    // означает "не дозвонились до GitHub", а не "у вас последняя версия".
    private void RunUpdateCheck()
    {
        StopUpdatePolling();
        ShowUpdateBusy("Checking for updates…");

        UpdateChecker.Shared.ForceCheckAsync(info =>
        {
            var error = UpdateChecker.Shared.LastCheckError;
            DispatcherQueue.TryEnqueue(() =>
            {
                if (info != null) BuildUpdateAvailable(info);
                else if (error != null) BuildUpdateFailed($"Update check failed: {error}");
                else BuildUpToDate();
            });
        });
    }

    private void BuildUpToDate()
    {
        _updateHost.Children.Clear();
        // Номер текущего билда рядом — на macOS он есть, а на Windows «up to date»
        // было без единой цифры, и понять, ЧТО именно установлено, было нельзя.
        _updateHost.Children.Add(UpdateRow(
            IconCheck, UI.Green, UI.GreenSoft,
            "Rimeo agent is up to date", AppConfig.Shared.DisplayVersion,
            UI.SecondaryButton("Check again", (_, _) => RunUpdateCheck())));
    }

    private void BuildUpdateAvailable(UpdateInfo info)
    {
        _updateHost.Children.Clear();
        var notes = string.IsNullOrEmpty(info.Notes) ? null : info.Notes;
        _updateHost.Children.Add(UpdateRow(
            IconDownload, UI.AccText, UI.AccSoft,
            $"Update available: {info.Version}", notes, null));
        _updateHost.Children.Add(UI.PrimaryButton("Update now", (_, _) => UpdateNow()));
    }

    private void BuildUpdateFailed(string message)
    {
        _updateHost.Children.Clear();
        _updateHost.Children.Add(UpdateRow(
            IconWarn, UI.Red, UI.RedSoft, message, null,
            UI.SecondaryButton("Try again", (_, _) => RunUpdateCheck())));
    }

    /// Кнопка "Update now". Ставит НЕ сама, а через AgentUpdateService.Start():
    /// у него есть флаг _running (защита от двух одновременных установок — кнопка +
    /// запрос с телефона) и он же ведёт стадию/прогресс для /api/agent/update/status.
    /// `info` из BuildUpdateAvailable намеренно не передаём: Start() перепроверяет
    /// GitHub сам и возвращает актуальный релиз.
    private void UpdateNow()
    {
        ShowUpdateBusy("Starting update…");

        // Start() блокирующий: внутри ForceCheck() ходит в GitHub (таймаут 10 с).
        // На UI-потоке это фризило бы окно.
        Task.Run(() =>
        {
            UpdateStartResult r;
            try { r = AgentUpdateService.Shared.Start(); }
            catch (Exception ex)
            {
                Log.Error($"Update failed: {ex.Message}");
                DispatcherQueue.TryEnqueue(() => BuildUpdateFailed($"Update failed: {ex.Message}"));
                return;
            }

            DispatcherQueue.TryEnqueue(() =>
            {
                // Обновление уже идёт (его начал телефон) — вторую установку не
                // запускаем, просто подхватываем чужой прогресс.
                if (r.AlreadyRunning)
                {
                    ShowUpdateProgress(AgentUpdateService.Shared.Status(), "Update already in progress…");
                    StartUpdatePolling();
                    return;
                }
                // Сеть/GitHub отвалились. Показывать "у вас последняя версия" здесь —
                // ровно тот баг, из-за которого пользователь остаётся на старом билде.
                if (r.Error != null) { BuildUpdateFailed($"Update failed: {r.Error}"); return; }
                if (r.Info == null)  { BuildUpToDate(); return; }

                ShowUpdateProgress(AgentUpdateService.Shared.Status());
                StartUpdatePolling();
            });
        });
    }

    // ── Прогресс установки: опрос AgentUpdateService ─────────────────────────

    // "verifying" / "installing" констант в AgentUpdateService нет — эти стадии
    // приходят строками из UpdateChecker.ApplyZip через колбэк stage.
    private static bool IsActiveStage(string stage) =>
        stage is AgentUpdateService.StageDownloading
              or "verifying"
              or "installing"
              or AgentUpdateService.StageRestarting;

    private static string StageCaption(UpdateStatus st)
    {
        var target = string.IsNullOrEmpty(st.TargetVersion) ? "" : $" {st.TargetVersion}";
        return st.Stage switch
        {
            AgentUpdateService.StageDownloading => $"Downloading update{target}… {(int)(Math.Clamp(st.Progress, 0, 1) * 100)}%",
            "verifying"                         => "Verifying signature…",
            "installing"                        => "Installing…",
            AgentUpdateService.StageRestarting  => "Restarting agent…",
            _                                   => "Updating…",
        };
    }

    private void ShowUpdateBusy(string text)
    {
        _updateHost.Children.Clear();
        _updateHost.Children.Add(UI.HStack(10,
            UI.Spinner(),
            new TextBlock { Text = text, FontSize = 14, Foreground = UI.Secondary, VerticalAlignment = VerticalAlignment.Center }));
    }

    private void ShowUpdateProgress(UpdateStatus st, string? caption = null)
    {
        _updateHost.Children.Clear();
        _updateBar.Foreground = UI.Acc;
        _updateBar.Background = UI.Chip;
        _updateHost.Children.Add(UI.HStack(10,
            UI.Spinner(),
            _updateStage));
        _updateHost.Children.Add(_updateBar);
        ApplyUpdateStatus(st, caption);
    }

    private void ApplyUpdateStatus(UpdateStatus st, string? caption = null)
    {
        _updateStage.Text = caption ?? StageCaption(st);
        _updateBar.Value  = Math.Clamp(st.Progress, 0, 1);
    }

    private void StartUpdatePolling()
    {
        StopUpdatePolling();
        _updatePoll = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(400) };
        _updatePoll.Tick += (_, _) => PollUpdateStatus();
        _updatePoll.Start();
    }

    private void StopUpdatePolling()
    {
        _updatePoll?.Stop();
        _updatePoll = null;
    }

    private void PollUpdateStatus()
    {
        var st = AgentUpdateService.Shared.Status();

        if (IsActiveStage(st.Stage)) { ApplyUpdateStatus(st); return; }

        // Дальше — терминальные стадии. На "restarting" процесс уже умирает
        // (Environment.Exit в ApplyZip), так что сюда мы обычно просто не доживаем.
        StopUpdatePolling();
        switch (st.Stage)
        {
            case AgentUpdateService.StageError:
                BuildUpdateFailed($"Update failed: {st.Error ?? "unknown error"}");
                break;
            case AgentUpdateService.StageDone:
                BuildUpToDate();
                break;
            default:   // idle — установки нет, возвращаем карточку в исходное состояние
                BuildUpdateIdle();
                break;
        }
    }

    // ── Report a bug ────────────────────────────────────────────────────────
    private async void SendBug_Click(object sender, RoutedEventArgs e)
    {
        var desc = _bugBox.Text.Trim();
        if (string.IsNullOrEmpty(desc)) { ShowBug("Please describe the issue.", ok: false); return; }

        ShowBugProgress("Sending…");
        try
        {
            using var http = new HttpClient();
            var payload = JsonSerializer.Serialize(new { description = desc });
            var resp = await http.PostAsync($"http://127.0.0.1:{AppConfig.Port}/api/report_bug?lan_token={Uri.EscapeDataString(RimeoAgent.Models.DataStore.Shared.Data.LanSecret)}",
                new StringContent(payload, Encoding.UTF8, "application/json"));
            if (resp.IsSuccessStatusCode)
            {
                ShowBug("✓ Bug report sent!", ok: true);
                _bugBox.Text = "";
            }
            // Голое «Error 502» не говорит ничего: сервер присылает причину в теле —
            // показываем её (macOS достаёт `detail` из ответа).
            else ShowBug(await ErrorDetail(resp), ok: false);
        }
        catch (Exception ex) { ShowBug($"Error: {ex.Message}", ok: false); }
    }

    private static async Task<string> ErrorDetail(HttpResponseMessage resp)
    {
        var code = (int)resp.StatusCode;
        try
        {
            var body = (await resp.Content.ReadAsStringAsync()).Trim();
            if (string.IsNullOrEmpty(body)) return $"Error {code}";
            try
            {
                var obj = JsonSerializer.Deserialize<Dictionary<string, JsonElement>>(body);
                foreach (var key in new[] { "error", "detail", "message" })
                    if (obj?.TryGetValue(key, out var el) == true && el.ValueKind == JsonValueKind.String)
                        return $"Error {code}: {el.GetString()}";
            }
            catch { /* тело не JSON — покажем как есть */ }
            return $"Error {code}: {(body.Length > 160 ? body[..160] : body)}";
        }
        catch { return $"Error {code}"; }
    }

    private void CopyLog_Click(object sender, RoutedEventArgs e)
    {
        try
        {
            var text = File.Exists(AppConfig.Shared.LogFile)
                ? string.Join("\n", File.ReadLines(AppConfig.Shared.LogFile).TakeLast(200))
                : "";
            var dp = new DataPackage();
            dp.SetText(text);
            Clipboard.SetContent(dp);
            ShowBug("✓ Log copied", ok: true);
        }
        catch (Exception ex) { ShowBug($"Error: {ex.Message}", ok: false); }
    }

    private void OpenLog_Click(object sender, RoutedEventArgs e)
    {
        try { System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo(AppConfig.Shared.LogFile) { UseShellExecute = true }); }
        catch { try { System.Diagnostics.Process.Start("notepad.exe", AppConfig.Shared.LogFile); } catch { } }
    }

    private void ShowBug(string text, bool ok)
    {
        _bugStatus.Visibility = Visibility.Visible;
        _bugStatus.Text = text;
        _bugStatus.Foreground = ok ? UI.Green : UI.Red;
    }

    // Промежуточное состояние — нейтральным серым, как «Clearing…»/«Applying limit…»
    // в кэше. Зелёное «Sending…» читалось как «отправлено».
    private void ShowBugProgress(string text)
    {
        _bugStatus.Visibility = Visibility.Visible;
        _bugStatus.Text = text;
        _bugStatus.Foreground = UI.Dim;
    }

    // ── Cache ───────────────────────────────────────────────────────────────
    private void RefreshCacheSize()
    {
        var stored = (int)DataStore.Shared.Data.MaxCacheGb;
        if (stored > 0) { _cacheMaxBox.Text = stored.ToString(); _cacheBar.Maximum = stored; _cacheMax.Text = $"of {stored} GB max"; }

        var dir = AppConfig.Shared.CacheDir;
        Task.Run(() =>
        {
            long total = 0;
            try
            {
                if (Directory.Exists(dir))
                    foreach (var f in Directory.EnumerateFiles(dir, "*", SearchOption.AllDirectories))
                        try { total += new FileInfo(f).Length; } catch { }
            }
            catch { }
            var gb = total / 1_073_741_824.0;
            DispatcherQueue.TryEnqueue(() =>
            {
                _cacheUsage.Text = $"{gb:F2} GB used";
                _cacheBar.Value = Math.Min(gb, _cacheBar.Maximum);
                // Переполненный кэш выглядел так же спокойно, как пустой (macOS:
                // >90% красный, >70% янтарный).
                var fill = _cacheBar.Maximum > 0 ? gb / _cacheBar.Maximum : 0;
                _cacheBar.Foreground = fill > 0.9 ? UI.Red : fill > 0.7 ? UI.Amber : UI.Acc;
            });
        });
    }

    private void SaveMaxCache_Click(object sender, RoutedEventArgs e)
    {
        var value = Math.Max(1, int.TryParse(_cacheMaxBox.Text, out var v) ? v : 3);
        DataStore.Shared.Update(d => d.MaxCacheGb = value);
        _cacheMaxBox.Text = value.ToString();
        _cacheBar.Maximum = value;
        _cacheMax.Text = $"of {value} GB max";
        _cacheStatus.Visibility = Visibility.Visible;
        _cacheStatus.Text = "Applying limit…";
        _cacheStatus.Foreground = UI.Dim;
        Task.Run(() =>
        {
            CacheManager.Shared.EnforceLimit();
            DispatcherQueue.TryEnqueue(() =>
            {
                _cacheStatus.Text = $"✓ Max cache set to {value} GB";
                _cacheStatus.Foreground = UI.Green;
                RefreshCacheSize();
            });
        });
    }

    private void ClearCache_Click(object sender, RoutedEventArgs e)
    {
        _cacheStatus.Visibility = Visibility.Visible;
        _cacheStatus.Text = "Clearing…";
        _cacheStatus.Foreground = UI.Dim;
        Task.Run(() =>
        {
            try
            {
                var dir = AppConfig.Shared.CacheDir;
                if (Directory.Exists(dir))
                    foreach (var f in Directory.EnumerateFiles(dir, "*", SearchOption.AllDirectories))
                        try { File.Delete(f); } catch { }
                DispatcherQueue.TryEnqueue(() =>
                {
                    _cacheStatus.Text = "✓ Cache cleared";
                    _cacheStatus.Foreground = UI.Green;
                    RefreshCacheSize();
                });
            }
            catch (Exception ex)
            {
                DispatcherQueue.TryEnqueue(() =>
                {
                    _cacheStatus.Text = $"Error: {ex.Message}";
                    _cacheStatus.Foreground = UI.Red;
                });
            }
        });
    }
}
