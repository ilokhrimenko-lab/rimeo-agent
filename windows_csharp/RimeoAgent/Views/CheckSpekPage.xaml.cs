using System.Globalization;
using System.Runtime.InteropServices.WindowsRuntime;
using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Imaging;
using Microsoft.UI.Xaml.Shapes;
using RimeoAgent.Config;   // Log
using RimeoAgent.Services;
using Windows.ApplicationModel.DataTransfer;
using Windows.Storage;

namespace RimeoAgent.Views;

// 1:1 mirror of the macOS "Check spek" tab (CheckSpekTabView + SpekResultView +
// SpekChart): drop or open any audio file → Spek-style spectrogram with frequency /
// time / dB axes in the agent's design language, plus a genuine/limited fidelity verdict.
// DSP lives in Services/SpectrumAnalyzer.cs (a port of Spek's pipeline).
public sealed partial class CheckSpekPage : Page
{
    // ⚠️ Никаких MaxWidth/HorizontalAlignment здесь. `MaxWidth = 760` + `Left` на этом
    // StackPanel схлопнули drop-зону в квадратик ~300px (build 261): при выравнивании
    // Left панель меряется ПО СОДЕРЖИМОМУ, а содержимое — текст «WAV · AIFF …», так что
    // MaxWidth не разворачивал её обратно. Да и на macOS предел 760 висит только на
    // карточке РЕЗУЛЬТАТА, а drop-зона там `.frame(maxWidth: .infinity)`.
    private readonly StackPanel _content = new() { Spacing = 14 };

    /// <summary>Предел ширины карточки результата — как `maxWidth: 760` на macOS.</summary>
    private const double ResultMaxWidth = 760;
    private string _fileName = "";

    // Пунктирная рамка и иконка drop-зоны: перекрашиваются, пока файл висит над окном.
    private Rectangle? _dropFrame;
    private Viewbox?   _dropIcon;

    // Time axis is laid out against the live spectrogram width (it's a Star column),
    // so it's repositioned on the image's SizeChanged.
    private Canvas? _timeCanvas;
    private double _durationSec;

    public CheckSpekPage()
    {
        InitializeComponent();

        var (scroll, stack) = UI.Page(22);
        stack.Children.Add(UI.ScreenHeader(
            "Check spek",
            "Frequency analysis · spek — check whether a track is genuine lossless or a re-encode."));
        stack.Children.Add(_content);
        Content = scroll;

        // Приём файла вешаем И на Page, И на корневой ScrollViewer. На «голой» Page
        // (весь Content — ScrollViewer) WinUI не регистрировал окно как OLE-drop-target,
        // и перетаскивание не давало никакой реакции. ScrollViewer hit-testable
        // (Background = Bg) и надёжно принимает drop; Page оставляем как fallback.
        // Хэндлеры ставят e.Handled, поэтому дважды один drop не обрабатывается.
        foreach (var target in new UIElement[] { this, scroll })
        {
            target.AllowDrop  = true;
            target.DragOver  += OnDragOver;
            target.DragLeave += OnDragLeave;
            target.Drop      += OnDrop;
        }

        ShowIdle();
    }

    // ── States ────────────────────────────────────────────────────────────────

    private void ShowIdle()
    {
        _content.Children.Clear();
        _content.Children.Add(BuildDropZone());
    }

    private void ShowLoading()
    {
        _content.Children.Clear();
        var v = new StackPanel { Spacing = 14, HorizontalAlignment = HorizontalAlignment.Center, Margin = new Thickness(0, 44, 0, 44) };
        v.Children.Add(UI.Spinner(40));
        v.Children.Add(new TextBlock { Text = "Analyzing audio…", FontSize = 14, FontWeight = FontWeights.Medium, Foreground = UI.Secondary, HorizontalAlignment = HorizontalAlignment.Center });
        _content.Children.Add(UI.Card(v, 20));
    }

    private void ShowFailed()
    {
        _content.Children.Clear();
        var v = new StackPanel { Spacing = 12, HorizontalAlignment = HorizontalAlignment.Center, Margin = new Thickness(0, 30, 0, 30) };
        v.Children.Add(new TextBlock { Text = "Couldn't analyze this file", FontSize = 16, FontWeight = FontWeights.SemiBold, Foreground = UI.Text, HorizontalAlignment = HorizontalAlignment.Center });
        v.Children.Add(new TextBlock { Text = "The file couldn't be decoded. Try another audio file.", FontSize = 13, Foreground = UI.Secondary, HorizontalAlignment = HorizontalAlignment.Center, TextWrapping = TextWrapping.Wrap });
        v.Children.Add(CenteredOpenButton());
        _content.Children.Add(UI.Card(v, 20));
    }

    private void ShowResult(SpectrumResult r)
    {
        _content.Children.Clear();

        // Toolbar: file name + "Open another".
        var toolbar = new Grid();
        toolbar.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        toolbar.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        // Иконка волны перед именем файла — как на macOS-тулбаре.
        var fnIcon = UI.Icon(14, UI.AccText, 2, "M3 12h2M7 8v8M11 5v14M15 9v6M19 11h2");
        fnIcon.VerticalAlignment = VerticalAlignment.Center;
        var fn = new TextBlock { Text = _fileName, FontSize = 13, FontWeight = FontWeights.Medium, Foreground = UI.Secondary, TextTrimming = TextTrimming.CharacterEllipsis, VerticalAlignment = VerticalAlignment.Center };
        var fnRow = UI.HStack(10, fnIcon, fn);
        Grid.SetColumn(fnRow, 0);
        toolbar.Children.Add(fnRow);
        var another = UI.SecondaryButton("Open another", (_, _) => OpenPicker());
        Grid.SetColumn(another, 1);
        toolbar.Children.Add(another);

        // Card body.
        var body = new StackPanel { Spacing = 0 };
        var head = new StackPanel { Spacing = 11 };
        head.Children.Add(new TextBlock
        {
            Text = string.IsNullOrEmpty(_fileName) ? "Untitled" : _fileName,
            FontSize = 17, FontWeight = FontWeights.SemiBold, Foreground = UI.Text,
            TextWrapping = TextWrapping.Wrap, MaxLines = 2
        });
        head.Children.Add(BuildChips(r));
        body.Children.Add(head);

        var verdict = BuildVerdict(r); verdict.Margin = new Thickness(0, 18, 0, 0); body.Children.Add(verdict);
        var chart   = BuildChart(r);   chart.Margin   = new Thickness(0, 18, 0, 0); body.Children.Add(chart);
        var howto   = BuildHowTo();    howto.Margin   = new Thickness(0, 16, 0, 0); body.Children.Add(howto);

        // Предел ширины — только на результате (тулбар + карточка), а не на всей
        // странице: спектрограмма на широком мониторе иначе расползается, но пустая
        // drop-зона обязана занимать всю ширину.
        _content.Children.Add(LimitWidth(toolbar));
        _content.Children.Add(LimitWidth(UI.Card(body, 22)));
    }

    /// <summary>
    /// «Не шире 760, но прижато влево» — аналог `.frame(maxWidth: 760, alignment: .leading)`.
    /// Через `MaxWidth` на самом элементе не выходит: со `Stretch` WinUI центрирует
    /// остаток, а с `Left` элемент меряется по содержимому и схлопывается (ровно это
    /// и случилось с drop-зоной в 261). Ограничение вешаем на КОЛОНКУ сетки.
    /// </summary>
    private static Grid LimitWidth(FrameworkElement child)
    {
        var grid = new Grid();
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star), MaxWidth = ResultMaxWidth });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        Grid.SetColumn(child, 0);
        grid.Children.Add(child);
        return grid;
    }

    // ── Drop zone ───────────────────────────────────────────────────────────────

    // UI.PrimaryButton по умолчанию прижат влево (HorizontalAlignment.Left) — так он и
    // стоит в карточках-списках. В центрированных блоках (drop-зона, экран ошибки)
    // ширину колонки задаёт самая длинная строка текста, и кнопка съезжала к её левому
    // краю вместо оси текста.
    private Button CenteredOpenButton()
    {
        var b = UI.PrimaryButton("Open audio file…", (_, _) => OpenPicker());
        b.HorizontalAlignment = HorizontalAlignment.Center;
        return b;
    }

    private FrameworkElement BuildDropZone()
    {
        var v = new StackPanel { Spacing = 18, HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center };

        // Крупная иконка над заголовком — macOS ставит `waveform.badge.magnifyingglass`.
        // Пути ОБЯЗАНЫ умещаться в сетку 24×24: в 261 лупа уходила за границу (ручка до
        // 22.5,22.5) и налезала на правые столбики — иконка читалась как каша из чёрточек.
        // Волна сдвинута влево, лупа целиком внутри поля и столбиков не касается.
        _dropIcon = UI.Icon(48, UI.Dim, 1.7,
            "M1.8 11.2v1.6", "M5.4 7.6v8.8", "M9 3.8v16.4", "M12.6 8.6v6.8",
            "M17.9 17.6a3.3 3.3 0 1 0 0-6.6 3.3 3.3 0 0 0 0 6.6Z",
            "M20.4 17.1 22.4 19.1");
        _dropIcon.HorizontalAlignment = HorizontalAlignment.Center;
        v.Children.Add(_dropIcon);

        var titles = new StackPanel { Spacing = 6, HorizontalAlignment = HorizontalAlignment.Center };
        titles.Children.Add(new TextBlock { Text = "Drop an audio file here", FontSize = 17, FontWeight = FontWeights.SemiBold, Foreground = UI.Text, HorizontalAlignment = HorizontalAlignment.Center });
        titles.Children.Add(new TextBlock { Text = "WAV · AIFF · MP3 · FLAC · M4A — or click to choose", FontSize = 13, Foreground = UI.Secondary, HorizontalAlignment = HorizontalAlignment.Center });
        v.Children.Add(titles);
        v.Children.Add(CenteredOpenButton());

        _dropFrame = new Rectangle
        {
            RadiusX = 18, RadiusY = 18,
            StrokeThickness = 1.5,
            Stroke = UI.CardBrd,
            StrokeDashArray = new DoubleCollection { 8, 6 },
            Fill = UI.Surf
        };
        var grid = new Grid { Height = 300 };
        grid.Children.Add(_dropFrame);
        var centered = new Grid { HorizontalAlignment = HorizontalAlignment.Stretch, VerticalAlignment = VerticalAlignment.Center };
        centered.Children.Add(v);
        grid.Children.Add(centered);
        return grid;
    }

    // Обратная связь на перетаскивание: раньше DragOver только разрешал операцию, и
    // зона никак не откликалась на файл под курсором (macOS красит фон в accSoft,
    // рамку и иконку — в acc).
    private void HighlightDropZone(bool active)
    {
        if (_dropFrame != null)
        {
            _dropFrame.Stroke = active ? UI.Acc : UI.CardBrd;
            _dropFrame.Fill   = active ? UI.AccSoft : UI.Surf;
        }
        if (_dropIcon?.Child is Canvas canvas)
            foreach (var child in canvas.Children)
                if (child is Microsoft.UI.Xaml.Shapes.Path p)
                    p.Stroke = active ? UI.Acc : UI.Dim;
    }

    // ── Metadata chips ───────────────────────────────────────────────────────────

    private static StackPanel BuildChips(SpectrumResult r)
    {
        var items = new List<string>();
        if (!string.IsNullOrEmpty(r.FormatLabel)) items.Add(r.FormatLabel);
        items.Add($"{(r.SampleRate / 1000).ToString("0.0", CultureInfo.InvariantCulture)} kHz");
        if (r.BitDepth is int bd) items.Add($"{bd}-bit");
        if (r.DurationSec > 0) items.Add(Fmt(r.DurationSec));

        var row = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 7 };
        foreach (var s in items)
        {
            row.Children.Add(new Border
            {
                Background = UI.Chip,
                CornerRadius = new CornerRadius(8),
                Padding = new Thickness(11, 6, 11, 6),
                Child = new TextBlock { Text = s, FontSize = 12, FontFamily = new FontFamily("Consolas"), Foreground = UI.BodyTxt }
            });
        }
        return row;
    }

    // ── Verdict badge ────────────────────────────────────────────────────────────

    private static Border BuildVerdict(SpectrumResult r)
    {
        bool genuine = r.Verdict == SpekVerdict.Genuine;
        var accent = genuine ? UI.Green : UI.Amber;

        // Векторная галочка / восклицательный знак вместо текстовых «✓» и «!»:
        // текстовый «!» в круге 40px читался слабо и зависел от системного шрифта.
        var glyph = genuine
            ? UI.Icon(19, UI.White, 2.4, "M5 12.5l4.5 4.5L19 7.5")
            : UI.Icon(19, UI.White, 2.4, "M12 6.5v7", "M12 17.2h.01");
        glyph.HorizontalAlignment = HorizontalAlignment.Center;
        glyph.VerticalAlignment = VerticalAlignment.Center;
        var circle = new Border { Width = 40, Height = 40, CornerRadius = new CornerRadius(20), Background = accent, Child = glyph };

        var texts = new StackPanel { Spacing = 2, VerticalAlignment = VerticalAlignment.Center };
        texts.Children.Add(new TextBlock { Text = genuine ? "Genuine lossless" : "High frequencies limited", FontSize = 16, FontWeight = FontWeights.SemiBold, Foreground = UI.Text });
        texts.Children.Add(new TextBlock
        {
            Text = genuine ? "Extends well above 16 kHz" : $"Energy rolls off around {Math.Round(r.CutoffHz / 1000)} kHz",
            FontSize = 13, FontWeight = FontWeights.Medium, Foreground = UI.Secondary
        });

        var row = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 13, VerticalAlignment = VerticalAlignment.Center };
        row.Children.Add(circle);
        row.Children.Add(texts);

        var fill = accent.Color; fill.A = 0x1F;   // ~12%
        var brd  = accent.Color; brd.A  = 0x52;    // ~32%
        return new Border
        {
            Background = new SolidColorBrush(fill),
            BorderBrush = new SolidColorBrush(brd),
            BorderThickness = new Thickness(1),
            CornerRadius = new CornerRadius(15),
            Padding = new Thickness(15),
            Child = row
        };
    }

    // ── How to read ──────────────────────────────────────────────────────────────

    private static Border BuildHowTo()
    {
        var v = new StackPanel { Spacing = 8 };
        v.Children.Add(UI.SectionLabel("How to read"));
        v.Children.Add(new TextBlock
        {
            Text = "Top of the chart = highest frequencies. Real lossless reaches well above 16 kHz. If a file doesn't go past ~16 kHz, it's most likely a re-encoded (lossy) version.",
            FontSize = 13, Foreground = UI.Secondary, TextWrapping = TextWrapping.Wrap
        });
        return new Border
        {
            Background = UI.Surf, BorderBrush = UI.CardBrd, BorderThickness = new Thickness(1),
            CornerRadius = new CornerRadius(13), Padding = new Thickness(14), Child = v
        };
    }

    // ── Chart (spectrogram + frequency / time / dB axes) ─────────────────────────

    private FrameworkElement BuildChart(SpectrumResult r)
    {
        const double chartH = 248;
        const double axisW = 34, legendW = 46, timeH = 16;

        // Spectrogram bitmap from the analyzer's BGRA pixels.
        var wb = new WriteableBitmap(r.Width, r.Height);
        using (var stream = wb.PixelBuffer.AsStream())
            stream.Write(r.PixelsBgra, 0, r.PixelsBgra.Length);

        var img = new Image { Source = wb, Stretch = Stretch.Fill };
        var imgBorder = new Border
        {
            CornerRadius = new CornerRadius(8),
            BorderBrush = UI.CardBrd,
            BorderThickness = new Thickness(1),
            Child = img,
            Margin = new Thickness(7, 0, 7, 0)
        };

        _timeCanvas = new Canvas { Height = timeH, Margin = new Thickness(7, 3, 7, 0), HorizontalAlignment = HorizontalAlignment.Stretch };
        _durationSec = r.DurationSec;
        img.SizeChanged += (_, e) => LayoutTimeAxis(e.NewSize.Width);

        var grid = new Grid();
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(axisW) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(legendW) });
        grid.RowDefinitions.Add(new RowDefinition { Height = new GridLength(chartH) });
        grid.RowDefinitions.Add(new RowDefinition { Height = new GridLength(timeH) });

        var freq = BuildFreqAxis(chartH, axisW, r.CeilingHz);
        Grid.SetColumn(freq, 0); Grid.SetRow(freq, 0); grid.Children.Add(freq);

        Grid.SetColumn(imgBorder, 1); Grid.SetRow(imgBorder, 0); grid.Children.Add(imgBorder);
        Grid.SetColumn(_timeCanvas, 1); Grid.SetRow(_timeCanvas, 1); grid.Children.Add(_timeCanvas);

        var legend = BuildDbLegend(chartH, legendW);
        Grid.SetColumn(legend, 2); Grid.SetRow(legend, 0); grid.Children.Add(legend);

        return grid;
    }

    private static Canvas BuildFreqAxis(double h, double w, double ceilingHz)
    {
        var c = new Canvas { Width = w, Height = h };
        var ticks = new List<(double f, string label, bool emph)>();
        for (double f = 0; f <= ceilingHz - 1500; f += 4000)
        {
            int k = (int)Math.Round(f / 1000);
            ticks.Add((f, f < 1 ? "0" : $"{k}k", Math.Abs(f - 16000) < 1));
        }
        ticks.Add((ceilingHz, $"{(int)Math.Round(ceilingHz / 1000)}k", false));

        foreach (var t in ticks)
        {
            double y = (1 - t.f / ceilingHz) * h;
            y = Math.Min(Math.Max(y, 6), h - 6);
            var tb = new TextBlock
            {
                Text = t.label, FontSize = 9.5, FontFamily = new FontFamily("Consolas"),
                Foreground = t.emph ? UI.Secondary : UI.Dim,
                FontWeight = t.emph ? FontWeights.SemiBold : FontWeights.Medium,
                Width = w - 4, TextAlignment = TextAlignment.Right
            };
            Canvas.SetLeft(tb, 0);
            Canvas.SetTop(tb, y - 7);
            c.Children.Add(tb);
        }
        return c;
    }

    private static FrameworkElement BuildDbLegend(double h, double w)
    {
        var grad = new LinearGradientBrush { StartPoint = new Windows.Foundation.Point(0.5, 0), EndPoint = new Windows.Foundation.Point(0.5, 1) };
        const int n = 24;
        for (int i = 0; i <= n; i++)
        {
            double loc = (double)i / n;                                   // 0 = top (0 dB, bright)
            var (r, g, b) = SpectrumAnalyzer.SpekPalette(1 - loc);
            grad.GradientStops.Add(new GradientStop
            {
                Offset = loc,
                Color = Windows.UI.Color.FromArgb(255, (byte)(r * 255), (byte)(g * 255), (byte)(b * 255))
            });
        }

        var bar = new Border { Width = 7, CornerRadius = new CornerRadius(3), Background = grad, BorderBrush = UI.CardBrd, BorderThickness = new Thickness(0.5), VerticalAlignment = VerticalAlignment.Stretch };

        var labels = new Canvas();
        int[] dbs = { 0, -20, -40, -60, -80, -100, -120 };
        foreach (var db in dbs)
        {
            double y = (-db / 120.0) * h;
            var tb = new TextBlock { Text = db == 0 ? "0" : db.ToString(), FontSize = 8, FontFamily = new FontFamily("Consolas"), Foreground = UI.Dim };
            Canvas.SetLeft(tb, 4);
            Canvas.SetTop(tb, Math.Min(Math.Max(y, 5), h - 5) - 6);
            labels.Children.Add(tb);
        }

        var grid = new Grid { Width = w, Height = h };
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(7) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        Grid.SetColumn(bar, 0); grid.Children.Add(bar);
        Grid.SetColumn(labels, 1); grid.Children.Add(labels);
        return grid;
    }

    private void LayoutTimeAxis(double width)
    {
        if (_timeCanvas == null) return;
        _timeCanvas.Children.Clear();
        if (_durationSec <= 0 || width <= 0) return;

        double step = _durationSec <= 780 ? 60 : (_durationSec <= 1560 ? 120 : 300);
        for (double t = 0; t <= _durationSec + 0.5; t += step)
        {
            double x = (t / _durationSec) * width;
            x = Math.Min(Math.Max(x, 15), width - 15);
            var tb = new TextBlock { Text = Fmt(t), FontSize = 8.5, FontFamily = new FontFamily("Consolas"), Foreground = UI.Dim };
            Canvas.SetLeft(tb, x - 14);
            Canvas.SetTop(tb, 1);
            _timeCanvas.Children.Add(tb);
        }
    }

    private static string Fmt(double s) => $"{(int)s / 60}:{((int)s % 60):00}";

    // ── File open + drag/drop ────────────────────────────────────────────────────

    // Нативный Win32-диалог вместо WinRT FileOpenPicker: последний в этой конфигурации
    // (unpackaged + self-contained WinUI 3) на Windows 11 24H2/25H2 кидал
    // COMException 0x80004005 из PickSingleFileAsync() — кнопка «срабатывала», окно
    // выбора не появлялось, «нет реакции» (баг nikolasleeman, build 265, 2026-09-04).
    private async void OpenPicker()
    {
        string? path;
        try
        {
            path = Win32FileDialog.PickFile(
                MainWindow.Hwnd,
                "Audio files\0*.wav;*.aiff;*.aif;*.mp3;*.m4a;*.aac;*.flac;*.ogg;*.wma;*.opus\0All files\0*.*\0",
                "Choose an audio file");
        }
        catch (Exception ex)
        {
            Log.Warn($"Check spek open-file failed: {ex.Message}");
            return;
        }
        if (string.IsNullOrEmpty(path)) return;
        await Analyze(path);
    }

    private void OnDragOver(object sender, DragEventArgs e)
    {
        try
        {
            if (!e.DataView.Contains(StandardDataFormats.StorageItems)) return;
            e.AcceptedOperation = DataPackageOperation.Copy;
            if (e.DragUIOverride != null)
            {
                e.DragUIOverride.Caption = "Analyze in Rimeo";
                e.DragUIOverride.IsGlyphVisible = false;
            }
            HighlightDropZone(true);
            e.Handled = true;   // не даём тому же событию всплыть на Page и обработаться дважды
        }
        catch (Exception ex) { Log.Warn($"Check spek drag-over failed: {ex.Message}"); }
    }

    private void OnDragLeave(object sender, DragEventArgs e) => HighlightDropZone(false);

    private async void OnDrop(object sender, DragEventArgs e)
    {
        HighlightDropZone(false);
        e.Handled = true;
        if (!e.DataView.Contains(StandardDataFormats.StorageItems)) return;   // не файл — тихо игнорируем

        // Deferral: DataView должен жить, пока идёт await. try/catch — потому что на
        // сломанном WinRT-брокере (та же машина, что валит FileOpenPicker)
        // GetStorageItemsAsync() тоже может кинуть. Тогда — реакция (ShowFailed),
        // а не молчание, и рабочая кнопка «Open audio file…» рядом.
        var deferral = e.GetDeferral();
        string? path = null;
        bool retrievalFailed = false;
        try
        {
            var items = await e.DataView.GetStorageItemsAsync();
            path = items.OfType<StorageFile>().FirstOrDefault()?.Path;
        }
        catch (Exception ex) { retrievalFailed = true; Log.Warn($"Check spek drop failed: {ex.Message}"); }
        finally { deferral.Complete(); }

        if (!string.IsNullOrEmpty(path)) await Analyze(path);
        else if (retrievalFailed) ShowFailed();   // брокер упал — реакция вместо тишины
        // иначе (папка / не-аудио в drop) — молча оставляем текущий экран, не затирая результат
    }

    private async Task Analyze(string path)
    {
        // Fully-qualified: `Microsoft.UI.Xaml.Shapes` (imported for Rectangle) also
        // exposes a `Path` type, which would collide with System.IO.Path here.
        _fileName = System.IO.Path.GetFileNameWithoutExtension(path);
        ShowLoading();
        var result = await Task.Run(() => SpectrumAnalyzer.Analyze(path));
        if (result == null) { ShowFailed(); return; }
        ShowResult(result);
    }
}
