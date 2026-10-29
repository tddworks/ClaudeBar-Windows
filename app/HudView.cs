using System.Globalization;
using System.Numerics;
using Microsoft.UI;
using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Automation.Peers;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Documents;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Shapes;
using Windows.UI;

namespace ClaudeBar;

/// What the HUD draws (docs/plans/2026-10-13-hud-design.md, the mockup's
/// section 2): the card and the strip, from a reading, in code. Colours come
/// from WinUI's theme brushes through the `Hud*` styles in App.xaml, so light,
/// dark and high contrast follow Windows; no text uses the tertiary colour,
/// which measures 3.3:1 on light Mica.
internal sealed class HudView
{
    /// What the HUD is drawing: the reading, or the tools it showed last while
    /// it reads for the first time, and whether the last read failed.
    internal sealed record Input(
        HudData? Data,
        IReadOnlyList<(HudData.Look Look, IReadOnlyList<string> Windows)> Pending,
        bool Offline,
        long? TodayTokens,
        string? Place,
        DateTimeOffset Now,
        bool Dark,
        bool OnTop,
        bool PointerOver);

    internal Action? Refresh;
    internal Action? ToggleOnTop;
    internal Action? ShowStrip;
    internal Action? ShowCard;
    internal Action? OpenWindow;
    internal Action? OpenSettings;
    internal Action? ChooseTools;
    /// A click on a row: the window's Limits page, where every limit is.
    internal Action? OpenLimits;
    internal Action? HideHud;
    internal Action? Quit;
    /// After an action a click on the HUD ran: the person's window again.
    internal Action? AfterClick;
    /// The footer's buttons showed or hid: where a drag starts changed.
    internal Action? RegionsChanged;

    /// Draws one label in the tertiary colour: the check's proof that its
    /// contrast measure finds a label under 4.5:1 (plan, Task 7).
    internal bool Calibrate;

    private readonly CultureInfo _culture = CultureInfo.CurrentCulture;
    /// Each bar's fill and the track it was last in, kept between readings so it
    /// eases to its new length. Taken out of that track, not `fill.Parent`: after
    /// card -> strip -> card that left it in the old card's track, and adding it
    /// to the new one threw 0x800F1000, so the card never came back.
    private readonly Dictionary<string, (Border Fill, Panel Track)> _fills = new();
    private readonly List<FrameworkElement> _captions = new();
    private readonly List<FrameworkElement> _passthrough = new();

    /// Where a drag starts in the last view drawn, and what stays clickable inside it.
    internal IReadOnlyList<FrameworkElement> Captions => _captions;
    internal IReadOnlyList<FrameworkElement> Passthrough => _passthrough;

    // MARK: - The card

    /// The card (design, What it shows): a row for each tool that needs the
    /// person, every fine tool in one quiet row, so a glance answers *can I
    /// keep going, and until when?* A click on a row opens the Limits page,
    /// which lists every limit.
    internal FrameworkElement Card(Input input)
    {
        _calibrated = false;
        _captions.Clear();
        _passthrough.Clear();
        var root = new Grid { Background = new SolidColorBrush(Colors.Transparent) };
        root.RowDefinitions.Add(new RowDefinition { Height = new GridLength(12) });
        root.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
        root.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });

        // The top 12 px drag the HUD.
        var grip = new Border { Background = new SolidColorBrush(Colors.Transparent) };
        root.Children.Add(grip);
        _captions.Add(grip);

        var body = new StackPanel { Spacing = 10, Padding = new Thickness(14, 0, 14, 12) };
        if (input.Data is { IsEmpty: true })
        {
            body.Children.Add(Empty());
        }
        else if (input.Data is { } data)
        {
            var summary = data.Summary();
            Measure(data, summary);
            foreach (var row in summary.Rows)
                body.Children.Add(Clickable(row.Tool is null ? DownRow(data.LookOf(row.Problem!.Id), row.Problem, input.Dark) : ToolRow(data, row, input)));
            if (summary.Fine is { } fine) body.Children.Add(Clickable(QuietRow(data, fine)));
        }
        else
        {
            _nameWidth = 0;
            _labelWidth = 0;
            foreach (var (look, _) in input.Pending) body.Children.Add(PendingRow(look, input.Dark));
        }
        var scroll = new ScrollViewer { Content = body, VerticalScrollBarVisibility = ScrollBarVisibility.Auto, HorizontalScrollMode = ScrollMode.Disabled };
        Grid.SetRow(scroll, 1);
        root.Children.Add(scroll);

        // The footer, where the buttons show while the pointer is over the card.
        var (footer, age) = Footer(input);
        Grid.SetRow(footer, 2);
        root.Children.Add(footer);
        _captions.Add(footer);
        var tools = Toolbar(input.OnTop);
        Grid.SetColumn(tools, 1);
        footer.Children.Add(tools);
        // Drawn again (each read, the minute's tick) with the pointer already on
        // it, its buttons show at once: XAML says the pointer entered the new card
        // only a frame or more later, or not until it moves, and a press before
        // that fell on the footer and was lost.
        void Hover(bool over)
        {
            tools.Visibility = over ? Visibility.Visible : Visibility.Collapsed;
            if (age is not null) age.Visibility = over ? Visibility.Collapsed : Visibility.Visible;
        }
        Hover(input.PointerOver);
        root.PointerEntered += (_, _) => { Hover(true); RegionsChanged?.Invoke(); };
        root.PointerExited += (_, _) => { Hover(false); RegionsChanged?.Invoke(); };
        root.ContextFlyout = Menu();
        return root;
    }

    /// The names' and the window labels' columns: as wide as the widest of
    /// the rows drawn, so the bars line up; a long one ends in an ellipsis.
    private double _nameWidth;
    private double _labelWidth;

    private void Measure(HudData data, HudSummary summary)
    {
        _nameWidth = 0;
        _labelWidth = 0;
        foreach (var row in summary.Rows.Where(row => row.Tool is not null))
        {
            _nameWidth = Math.Max(_nameWidth, Width(data.LookOf(row.Tool!.Id).Name, "HudStrong"));
            if (row.Tool.Lines.Count > 1) _labelWidth = Math.Max(_labelWidth, Width(row.Headline!.Window, "HudSecondary"));
        }
        _nameWidth = Math.Min(_nameWidth, 96);
        _labelWidth = Math.Min(_labelWidth, 64);
    }

    private static double Width(string text, string style)
    {
        var probe = new TextBlock { Text = text, Style = Style(style) };
        probe.Measure(new Windows.Foundation.Size(double.PositiveInfinity, double.PositiveInfinity));
        return Math.Ceiling(probe.DesiredSize.Width);
    }

    /// One tool by its headline: `● Claude  5h  [bar]  12%  · 1h 40m  +2 low`.
    /// Out: `out · back 4:10 PM`, in the critical colour. Running hot: when it
    /// runs out at this pace, in the caution colour, for the countdown. Its
    /// numbers not live (signed out, or the read failed): dimmed, and since when.
    private HudRow ToolRow(HudData data, HudSummary.Row summary, Input input)
    {
        var tool = summary.Tool!;
        var line = summary.Headline!;
        var look = data.LookOf(tool.Id);
        var stale = summary.Problem;
        var dim = input.Offline || stale is not null;
        var row = Row(look, input.Dark, hollow: false, look.Name, dim ? "HudStrongSecondary" : "HudStrong");
        if (tool.Lines.Count > 1) Place(row, Trimmed(Text(line.Window, "HudSecondary"), _labelWidth), 2);
        string sentence;
        if (stale is not null)
        {
            // The numbers it had, dimmed, and why they aren't live.
            var words = stale.Kind == "signedOut" ? "signed out" : "couldn't read";
            var from = tool.ReadAt ?? data.ReadAt;
            var since = from is { } at ? $" · numbers from {HudText.Clock(at, _culture)}" : "";
            // A grid, not a stack panel: the words get what's left of the row and end in an ellipsis.
            var parts = new Grid { ColumnSpacing = 8 };
            parts.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            parts.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            var percent = Tabular(Text($"{Math.Max(0, line.PercentLeft)}%", "HudStrongSecondary"));
            var why = Trimmed(Text(words + since, Tail("HudSecondary")), double.NaN);
            percent.VerticalAlignment = why.VerticalAlignment = VerticalAlignment.Center;
            Grid.SetColumn(why, 1);
            parts.Children.Add(percent);
            parts.Children.Add(why);
            Place(row, parts, 3, span: 3);
            sentence = $"{look.Name}: {words}{(from is { } read ? $". Numbers from {HudText.Clock(read, _culture)}" : "")}. " + HudText.Sentence(look.Name, line, input.Now, _culture);
            ToolTipService.SetToolTip(row, stale.Message);
        }
        else if (line.Status == "depleted")
        {
            var back = tool.OutUntil ?? line.ResetsAt;
            var text = back is { } at ? $"out · back {HudText.Clock(at, _culture)}" : "out";
            Place(row, Text(text, Tail(dim ? "HudSecondary" : "HudCritical")), 3, span: 3);
            sentence = HudText.Sentence(look.Name, line, input.Now, _culture);
        }
        else
        {
            var bar = Bar(HudData.Key(tool, line), line);
            if (dim) bar.Opacity = 0.45;
            bar.MinWidth = 24;
            Place(row, bar, 3);
            Place(row, Tabular(Text($"{Math.Max(0, line.PercentLeft)}%", dim ? "HudStrongSecondary" : "HudStrong")), 4);
            sentence = HudText.Sentence(look.Name, line, input.Now, _culture);
            if (line.RunsOutAt is { } runsOut)
            {
                Place(row, Text($"↑ runs out ~{HudText.When(runsOut, input.Now, _culture)}", Tail(dim ? "HudSecondary" : "HudCaution")), 5);
                sentence += $". At this pace it runs out {HudText.SpokenWhen(runsOut, input.Now, _culture)}";
            }
            else
            {
                Place(row, Tabular(Text("· " + HudText.Reset(line.PercentLeft, line.ResetsAt, input.Now, _culture), Tail("HudSecondary"))), 5);
            }
        }
        var others = HudText.Others(tool.OthersCount, tool.OthersAttention);
        if (others != "")
        {
            Place(row, Text(others, "HudSecondary"), 6);
            sentence += tool.OthersAttention > 0
                ? $". {tool.OthersAttention} of its {tool.OthersCount} other limits {(tool.OthersAttention == 1 ? "is" : "are")} low"
                : $". {tool.OthersCount} other {(tool.OthersCount == 1 ? "limit" : "limits")}, fine";
        }
        AutomationProperties.SetName(row, sentence);
        return row;
    }

    /// A tool without numbers, dimmed: `○ Cursor  signed out`; what to do is its tooltip and its sentence.
    private HudRow DownRow(HudData.Look look, HudData.Problem problem, bool dark)
    {
        var row = Row(look, dark, hollow: true, look.Name, "HudStrongSecondary");
        var words = problem.Kind switch { "signedOut" => "signed out", "reading" => "reading…", _ => "couldn't read" };
        Place(row, Text(words, Tail("HudSecondary")), 3, span: 4);
        AutomationProperties.SetName(row, problem.Message == "" ? $"{look.Name}: {words.TrimEnd('…')}" : $"{look.Name}: {words.TrimEnd('…')}. {problem.Message}");
        if (problem.Message != "") ToolTipService.SetToolTip(row, problem.Message);
        return row;
    }

    /// Every fine tool in one row, and the lowest of them: `✓ Codex · Gemini   lowest 62%`;
    /// when that's every tool, `✓ All fine · lowest Claude 62%`.
    private HudRow QuietRow(HudData data, HudSummary.Quiet fine)
    {
        var row = new HudRow { ColumnSpacing = 8, Background = new SolidColorBrush(Colors.Transparent) };
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        var check = Text("\uE73E", "HudSecondary");
        check.FontFamily = new FontFamily("Segoe Fluent Icons");
        check.FontSize = 12;
        Place(row, check, 0);
        var names = fine.Ids.Select(id => data.LookOf(id).Name).ToList();
        var lowest = data.LookOf(fine.LowestId).Name;
        Place(row, Trimmed(Text(fine.All ? "All fine" : string.Join(" · ", names), "HudBody"), double.NaN), 1);
        Place(row, Tabular(Text(fine.All ? $"lowest {lowest} {fine.LowestPercent}%" : $"lowest {fine.LowestPercent}%", Tail("HudSecondary"))), 2);
        AutomationProperties.SetName(row, fine.All
            ? $"All fine. Lowest: {lowest}, {fine.LowestPercent}% left"
            : $"Fine: {string.Join(", ", names)}. Lowest: {lowest}, {fine.LowestPercent}% left");
        return row;
    }

    /// Reading for the first time: a row for each tool it showed last, at its final height.
    private HudRow PendingRow(HudData.Look look, bool dark)
    {
        var row = Row(look, dark, hollow: false, look.Name, "HudStrong");
        var bone = new Border { Style = Style("HudSkeleton"), VerticalAlignment = VerticalAlignment.Center };
        Place(row, bone, 3, span: 4);
        AutomationProperties.SetName(row, $"{look.Name}: reading");
        return row;
    }

    /// A row's columns: the dot, the name, the window label, the bar, the
    /// share, the time and the other limits.
    private HudRow Row(HudData.Look look, bool dark, bool hollow, string name, string nameStyle)
    {
        var row = new HudRow { ColumnSpacing = 6, MinHeight = 20, Background = new SolidColorBrush(Colors.Transparent) };
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = _nameWidth > 0 ? new GridLength(_nameWidth) : GridLength.Auto });
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = _labelWidth > 0 ? new GridLength(_labelWidth) : new GridLength(0) });
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        for (var column = 4; column < 7; column++) row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        Place(row, hollow ? Ring(look, dark) : Dot(look, dark), 0);
        Place(row, Trimmed(Text(name, nameStyle), double.NaN), 1);
        return row;
    }

    private static void Place(Grid row, FrameworkElement element, int column, int span = 1)
    {
        element.VerticalAlignment = VerticalAlignment.Center;
        Grid.SetColumn(element, column);
        if (span > 1) Grid.SetColumnSpan(element, span);
        row.Children.Add(element);
    }

    private static TextBlock Trimmed(TextBlock text, double maxWidth)
    {
        text.TextTrimming = TextTrimming.CharacterEllipsis;
        if (!double.IsNaN(maxWidth)) text.MaxWidth = maxWidth;
        return text;
    }

    /// The first time column drawn in the tertiary colour, for the check's calibration.
    private string Tail(string style)
    {
        if (!Calibrate || _calibrated) return style;
        _calibrated = true;
        return "HudCalibrationTertiary";
    }

    /// A click on a row opens the Limits page.
    private HudRow Clickable(HudRow row)
    {
        row.Tapped += (_, _) => OpenLimits?.Invoke();
        return row;
    }

    private bool _calibrated;

    /// A 4 px track, its fill in the accent, caution or critical colour, and a
    /// 2 × 10 px tick where an even pace would end.
    private Grid Bar(string key, HudData.Line line)
    {
        var bar = new Grid { Height = 10 };
        var track = new Grid { Height = 4, VerticalAlignment = VerticalAlignment.Center, Style = Style("HudTrack") };
        Border fill;
        if (_fills.Remove(key, out var kept))
        {
            fill = kept.Fill;
            kept.Track.Children.Remove(fill);
        }
        else
        {
            fill = new Border { CornerRadius = new CornerRadius(2) };
            fill.Scale = new Vector3(Fraction(line.PercentLeft), 1, 1);
            // Set after the first length, so a new bar doesn't animate in.
            fill.ScaleTransition = new Vector3Transition();
        }
        _fills[key] = (fill, track);
        fill.Style = Style(line.Status switch { "warning" => "HudFillCaution", "critical" or "depleted" => "HudFillCritical", _ => "HudFillAccent" });
        fill.Scale = new Vector3(Fraction(line.PercentLeft), 1, 1);
        track.Children.Add(fill);
        bar.Children.Add(track);
        if (line.Tick is double tick && line.PercentLeft > 0)
        {
            var at = Math.Clamp(tick, 0, 100);
            bar.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(Math.Max(at, 0.001), GridUnitType.Star) });
            bar.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(Math.Max(100 - at, 0.001), GridUnitType.Star) });
            Grid.SetColumnSpan(track, 2);
            var mark = new Border { Style = Style("HudTick"), HorizontalAlignment = HorizontalAlignment.Left, Margin = new Thickness(-1, 0, 0, 0) };
            Grid.SetColumn(mark, 1);
            bar.Children.Add(mark);
        }
        return bar;
    }

    private static float Fraction(int percent) => Math.Clamp(percent, 0, 100) / 100f;

    /// Nothing found: one sentence and one button.
    private FrameworkElement Empty()
    {
        var panel = new StackPanel { Spacing = 8, Padding = new Thickness(0, 4, 0, 0) };
        var title = new HudRow();
        title.Children.Add(Text("No AI tools signed in here yet", "HudStrong"));
        AutomationProperties.SetName(title, "No AI tools signed in here yet");
        panel.Children.Add(title);
        var sentence = new HudRow();
        var text = Text("The HUD shows the limits of Claude Code, Codex, Gemini CLI and the other tools ClaudeBar knows, once one is signed in on this PC.", "HudSecondary");
        text.TextWrapping = TextWrapping.Wrap;
        sentence.Children.Add(text);
        AutomationProperties.SetName(sentence, text.Text);
        panel.Children.Add(sentence);
        var choose = new Button { Content = "Choose tools", HorizontalAlignment = HorizontalAlignment.Left };
        choose.Click += (_, _) => ChooseTools?.Invoke();
        _passthrough.Add(choose);
        panel.Children.Add(choose);
        return panel;
    }

    /// Today's tokens and the place, then when the numbers were read; offline,
    /// the time of the last numbers and *Retry*. Its right column also holds
    /// the buttons while the pointer is over the card: the age, the text they
    /// replace, is returned with it.
    private (HudRow Footer, FrameworkElement? Age) Footer(Input input)
    {
        var footer = new HudRow { Padding = new Thickness(14, 6, 10, 6), ColumnSpacing = 8, MinHeight = 38, Style = Style("HudDivider") };
        footer.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        footer.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        var left = Text("", "HudSecondary");
        left.TextTrimming = TextTrimming.CharacterEllipsis;
        left.VerticalAlignment = VerticalAlignment.Center;
        Tabular(left);
        footer.Children.Add(left);
        string sentence;
        FrameworkElement? age = null;
        if (input.Data is null)
        {
            left.Text = "Reading limits…";
            sentence = "Reading limits";
        }
        else if (input.Offline)
        {
            var asOf = input.Data.ReadAt is { } read ? HudText.Clock(read, _culture) : "–";
            left.Text = $"Offline · as of {asOf}";
            var retry = Link("Retry", "Retry reading the limits", () => Refresh?.Invoke());
            retry.VerticalAlignment = VerticalAlignment.Center;
            Grid.SetColumn(retry, 1);
            footer.Children.Add(retry);
            age = retry;
            sentence = $"Offline. These are the limits as of {asOf}";
        }
        else
        {
            var parts = new List<string>();
            if (input.TodayTokens is long tokens)
            {
                left.Inlines.Add(new Run { Text = "Today " });
                left.Inlines.Add(new Run { Text = MainWindow.Tokens(tokens), FontWeight = FontWeights.SemiBold });
                left.Inlines.Add(new Run { Text = " tokens" });
                parts.Add($"Today {MainWindow.Tokens(tokens)} tokens");
            }
            if (input.Place is { } place)
            {
                if (left.Inlines.Count > 0) left.Inlines.Add(new Run { Text = " · " });
                var space = place.IndexOf(' ');
                left.Inlines.Add(new Run { Text = space > 0 ? place[..space] : place, FontWeight = FontWeights.SemiBold });
                if (space > 0) left.Inlines.Add(new Run { Text = place[space..] });
                parts.Add(place);
            }
            var ago = input.Data.ReadAt is { } read ? HudText.Ago(input.Now - read) : "";
            var right = Tabular(Text(ago, "HudSecondary"));
            right.VerticalAlignment = VerticalAlignment.Center;
            Grid.SetColumn(right, 1);
            footer.Children.Add(right);
            age = right;
            parts.Add($"read {ago}");
            sentence = string.Join(", ", parts);
        }
        AutomationProperties.SetName(footer, sentence);
        return (footer, age);
    }

    /// Refresh, keep on top, the strip, and ClaudeBar's window.
    private FrameworkElement Toolbar(bool onTop)
    {
        var tools = new StackPanel
        {
            Orientation = Orientation.Horizontal, Spacing = 2, HorizontalAlignment = HorizontalAlignment.Right,
            VerticalAlignment = VerticalAlignment.Center, Visibility = Visibility.Collapsed,
        };
        tools.Children.Add(IconButton("\uE72C", "Refresh the limits", () => { Refresh?.Invoke(); AfterClick?.Invoke(); }));
        tools.Children.Add(IconButton(onTop ? "\uE718" : "\uE77A", onTop ? "Keep on top: on" : "Keep on top: off", () => { ToggleOnTop?.Invoke(); AfterClick?.Invoke(); }));
        tools.Children.Add(IconButton("\uE73F", "Collapse to the strip", () => { ShowStrip?.Invoke(); AfterClick?.Invoke(); }));
        tools.Children.Add(IconButton("\uE8A7", "Open ClaudeBar", () => OpenWindow?.Invoke()));
        return tools;
    }

    /// Right-click: Refresh, Hide the HUD, Settings, and quitting.
    private MenuFlyout Menu()
    {
        var menu = new MenuFlyout();
        var givesBack = true;
        void Add(string text, string glyph, Action? action, bool keepsFocus = false)
        {
            var item = new MenuFlyoutItem { Text = text, Icon = new FontIcon { Glyph = glyph } };
            item.Click += (_, _) =>
            {
                givesBack = !keepsFocus;
                action?.Invoke();
            };
            menu.Items.Add(item);
        }
        Add("Refresh", "\uE72C", Refresh);
        Add("Hide the HUD", "\uE8F9", HideHud);
        Add("Settings", "\uE713", OpenSettings, keepsFocus: true);
        menu.Items.Add(new MenuFlyoutSeparator());
        Add("Quit ClaudeBar", "\uE711", Quit, keepsFocus: true);
        menu.Opening += (_, _) => givesBack = true;
        menu.Closed += (_, _) => { if (givesBack) AfterClick?.Invoke(); };
        return menu;
    }

    // MARK: - The strip

    /// One line: the worst tool's headline, then a dot per other tool in its
    /// status colour. A click shows the card.
    internal FrameworkElement Strip(Input input)
    {
        _captions.Clear();
        _passthrough.Clear();
        var row = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8, Padding = new Thickness(12, 8, 12, 8), Background = new SolidColorBrush(Colors.Transparent) };
        var item = new HudRow();
        var parts = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6 };
        item.Children.Add(parts);
        row.Children.Add(item);
        var sentences = new List<string>();
        if (input.Data is { IsEmpty: false } data)
        {
            var summary = data.Summary();
            // The worst: the first live row at the reading's worst status, else the first live row.
            var live = summary.Rows.Where(r => r.Tool is not null && r.Problem is null).ToList();
            var lead = live.FirstOrDefault(r => r.Headline!.Status == data.Worst) ?? live.FirstOrDefault();
            if (lead is not null)
            {
                var look = data.LookOf(lead.Tool!.Id);
                var line = lead.Headline!;
                parts.Children.Add(Dot(look, input.Dark));
                parts.Children.Add(Text(look.Name, "HudBody"));
                if (lead.Tool.Lines.Count > 1) parts.Children.Add(Text(line.Window, "HudSecondary"));
                if (line.Status == "depleted")
                {
                    var back = lead.Tool.OutUntil ?? line.ResetsAt;
                    parts.Children.Add(Text(back is { } at ? $"out · back {HudText.Clock(at, _culture)}" : "out", input.Offline ? "HudSecondary" : "HudCritical"));
                }
                else
                {
                    parts.Children.Add(Tabular(Text($"{Math.Max(0, line.PercentLeft)}%", input.Offline ? "HudStrongSecondary" : line.Status switch
                    {
                        "warning" => "HudStrongCaution",
                        "critical" => "HudStrongCritical",
                        _ => "HudStrong",
                    })));
                    parts.Children.Add(line.RunsOutAt is { } runsOut
                        ? Text($"↑ runs out ~{HudText.When(runsOut, input.Now, _culture)}", input.Offline ? "HudSecondary" : "HudCaution")
                        : Tabular(Text(HudText.Reset(line.PercentLeft, line.ResetsAt, input.Now, _culture), "HudSecondary")));
                }
                sentences.Add(HudText.Sentence(look.Name, line, input.Now, _culture));
            }
            else if (summary.Fine is { } fine)
            {
                var lowest = data.LookOf(fine.LowestId).Name;
                var check = Text("\uE73E", "HudSecondary");
                check.FontFamily = new FontFamily("Segoe Fluent Icons");
                check.FontSize = 12;
                parts.Children.Add(check);
                parts.Children.Add(Text(fine.All ? "All fine" : "Fine", "HudBody"));
                parts.Children.Add(Tabular(Text($"lowest {lowest} {fine.LowestPercent}%", "HudSecondary")));
                sentences.Add($"{(fine.All ? "All fine" : "Fine")}. Lowest: {lowest}, {fine.LowestPercent}% left");
            }
            // A dot for every other tool: fine, low, critical or out; a ring for one without live numbers.
            var dots = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 4, Margin = new Thickness(4, 0, 0, 0) };
            var others = new List<string>();
            foreach (var tool in data.Tools.Where(tool => tool.Lines.Count > 0 && tool.Id != lead?.Tool!.Id))
            {
                var name = data.LookOf(tool.Id).Name;
                var stale = data.Stale(tool.Id);
                var status = tool.HeadlineLine.Status;
                if (lead is null && stale is null && status == "healthy" && !tool.HeadlineLine.RunningHot) continue;
                var words = stale is not null ? (stale.Kind == "signedOut" ? "signed out" : "couldn't read")
                    : status switch { "warning" => "low", "critical" => "critical", "depleted" => "out", _ => tool.HeadlineLine.RunningHot ? "running hot" : "fine" };
                dots.Children.Add(StatusDot(stale is not null ? "HudDotDown" : status switch
                {
                    "warning" => "HudDotCaution",
                    "critical" or "depleted" => "HudDotCritical",
                    _ => tool.HeadlineLine.RunningHot ? "HudDotCaution" : "HudDotFine",
                }, $"{name}: {words}"));
                others.Add($"{name} {words}");
            }
            foreach (var problem in data.Alone)
            {
                var name = data.LookOf(problem.Id).Name;
                var words = problem.Kind switch { "signedOut" => "signed out", "reading" => "reading", _ => "couldn't read" };
                dots.Children.Add(StatusDot("HudDotDown", $"{name}: {words}"));
                others.Add($"{name} {words}");
            }
            if (dots.Children.Count > 0) parts.Children.Add(dots);
            if (others.Count > 0) sentences.Add(string.Join(", ", others));
        }
        else
        {
            var text = Text(input.Data is null ? "Reading limits…" : "No AI tools signed in here yet", "HudSecondary");
            parts.Children.Add(text);
            sentences.Add(text.Text);
        }
        if (input.Offline)
        {
            var asOf = input.Data?.ReadAt is { } read ? HudText.Clock(read, _culture) : "–";
            parts.Children.Add(Text($"· offline, as of {asOf}", "HudSecondary"));
            sentences.Add($"Offline. These are the limits as of {asOf}");
        }
        foreach (var child in parts.Children.OfType<FrameworkElement>()) child.VerticalAlignment = VerticalAlignment.Center;
        AutomationProperties.SetName(item, string.Join(". ", sentences));
        // A click on it opens the card. It has no caption region, so it doesn't
        // drag: the card does, and the strip keeps the card's corner.
        row.Tapped += (_, _) => { ShowCard?.Invoke(); AfterClick?.Invoke(); };
        row.ContextFlyout = Menu();
        return row;
    }

    /// An 8 px dot in a status colour, named for the tooltip and the strip's sentence.
    private static Border StatusDot(string style, string name)
    {
        var dot = new Border { Width = 8, Height = 8, CornerRadius = new CornerRadius(4), Style = Style(style), VerticalAlignment = VerticalAlignment.Center };
        ToolTipService.SetToolTip(dot, name);
        AutomationProperties.SetAccessibilityView(dot, AccessibilityView.Raw);
        return dot;
    }

    // MARK: - Pieces

    private static Style Style(string key) => (Style)Application.Current.Resources[key];

    /// A text whose words are drawn but not read: the row it's in reads its sentence.
    private static TextBlock Text(string text, string style, double leftMargin = 0)
    {
        var block = new TextBlock { Text = text, Style = Style(style), Margin = new Thickness(leftMargin, 0, 0, 0) };
        AutomationProperties.SetAccessibilityView(block, AccessibilityView.Raw);
        return block;
    }

    private static TextBlock Tabular(TextBlock text)
    {
        Typography.SetNumeralAlignment(text, FontNumeralAlignment.Tabular);
        return text;
    }

    private static Ellipse Dot(HudData.Look look, bool dark) => new()
    {
        Width = 8, Height = 8, VerticalAlignment = VerticalAlignment.Center,
        Fill = new SolidColorBrush(Hex(dark ? look.Dark : look.Light)),
    };

    /// A tool without live numbers: a ring in its colour.
    private static Ellipse Ring(HudData.Look look, bool dark) => new()
    {
        Width = 8, Height = 8, VerticalAlignment = VerticalAlignment.Center, StrokeThickness = 1.5,
        Stroke = new SolidColorBrush(Hex(dark ? look.Dark : look.Light)),
    };

    private HyperlinkButton Link(string text, string name, Action action)
    {
        var link = new HyperlinkButton { Content = text, Padding = new Thickness(4, 0, 4, 0), FontSize = 12, MinHeight = 0 };
        AutomationProperties.SetName(link, name);
        link.Click += (_, _) => { action(); AfterClick?.Invoke(); };
        _passthrough.Add(link);
        return link;
    }

    private Button IconButton(string glyph, string name, Action action)
    {
        var button = new Button
        {
            Content = new FontIcon { Glyph = glyph, FontSize = 12 }, Width = 26, Height = 26, Padding = new Thickness(0),
            Background = new SolidColorBrush(Colors.Transparent), BorderThickness = new Thickness(0),
        };
        AutomationProperties.SetName(button, name);
        ToolTipService.SetToolTip(button, name);
        button.Click += (_, _) => action();
        _passthrough.Add(button);
        return button;
    }

    private static Color Hex(string hex)
    {
        var value = Convert.ToUInt32(hex.TrimStart('#'), 16);
        return Color.FromArgb(255, (byte)(value >> 16), (byte)(value >> 8), (byte)value);
    }
}

/// A row the HUD reads as one sentence: its texts are drawn but left out of
/// UI Automation's control view, and the row carries the full sentence
/// (`AutomationProperties.Name`), as a Text element, for anyone who points at it.
internal sealed partial class HudRow : Grid
{
    protected override AutomationPeer OnCreateAutomationPeer() => new Peer(this);

    private sealed partial class Peer(HudRow owner) : FrameworkElementAutomationPeer(owner)
    {
        protected override AutomationControlType GetAutomationControlTypeCore() => AutomationControlType.Text;
        protected override string GetClassNameCore() => nameof(HudRow);
        protected override bool IsControlElementCore() => true;
        protected override bool IsContentElementCore() => true;
    }
}
