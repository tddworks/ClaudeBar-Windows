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
        bool OnTop);

    internal Action? Refresh;
    internal Action? ToggleOnTop;
    internal Action? ShowStrip;
    internal Action? ShowCard;
    internal Action? OpenWindow;
    internal Action? OpenSettings;
    internal Action? ChooseTools;
    internal Action? HideHud;
    internal Action? Quit;
    /// After an action a click on the HUD ran: the person's window again.
    internal Action? AfterClick;

    /// Draws one label in the tertiary colour: the check's proof that its
    /// contrast measure finds a label under 4.5:1 (plan, Task 7).
    internal bool Calibrate;

    private readonly CultureInfo _culture = CultureInfo.CurrentCulture;
    /// Each bar's fill, kept between readings so it eases to its new length.
    private readonly Dictionary<string, Border> _fills = new();
    private readonly List<FrameworkElement> _captions = new();
    private readonly List<FrameworkElement> _passthrough = new();

    /// Where a drag starts in the last view drawn, and what stays clickable inside it.
    internal IReadOnlyList<FrameworkElement> Captions => _captions;
    internal IReadOnlyList<FrameworkElement> Passthrough => _passthrough;

    // MARK: - The card

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

        var body = new StackPanel { Spacing = 12, Padding = new Thickness(14, 0, 14, 12) };
        _windowWidth = WindowColumn(input.Data);
        FrameworkElement? firstFlag = null;
        if (input.Data is { IsEmpty: true })
        {
            body.Children.Add(Empty());
        }
        else if (input.Data is { } data)
        {
            foreach (var tool in data.Tools)
            {
                var look = data.LookOf(tool.Id);
                var (block, flag) = ToolBlock(look, tool, data.Failed(tool.Id), input);
                firstFlag ??= flag;
                body.Children.Add(block);
            }
            foreach (var problem in data.Alone)
            {
                var (block, flag) = problem.Kind == "reading"
                    ? (PendingBlock(data.LookOf(problem.Id), new[] { "" }, input.Dark), null)
                    : ProblemBlock(data.LookOf(problem.Id), problem, input.Dark);
                firstFlag ??= flag;
                body.Children.Add(block);
            }
        }
        else
        {
            foreach (var (look, windows) in input.Pending) body.Children.Add(PendingBlock(look, windows, input.Dark));
        }
        var scroll = new ScrollViewer { Content = body, VerticalScrollBarVisibility = ScrollBarVisibility.Auto, HorizontalScrollMode = ScrollMode.Disabled };
        Grid.SetRow(scroll, 1);
        root.Children.Add(scroll);

        var footer = Footer(input);
        Grid.SetRow(footer, 2);
        root.Children.Add(footer);
        _captions.Add(footer);

        // The three buttons, shown while the pointer is over the card, where the first tool's flag is.
        var tools = Toolbar(input.OnTop);
        Grid.SetRowSpan(tools, 2);
        root.Children.Add(tools);
        root.PointerEntered += (_, _) =>
        {
            tools.Visibility = Visibility.Visible;
            if (firstFlag is not null) firstFlag.Opacity = 0;
        };
        root.PointerExited += (_, _) =>
        {
            tools.Visibility = Visibility.Collapsed;
            if (firstFlag is not null) firstFlag.Opacity = 1;
        };
        root.ContextFlyout = Menu();
        return root;
    }

    /// A tool's limits. One whose last read failed shows its last numbers as
    /// offline, says it couldn't read, and offers a retry.
    private (FrameworkElement Block, FrameworkElement? Flag) ToolBlock(HudData.Look look, HudData.Tool tool, HudData.Problem? failed, Input input)
    {
        var block = new StackPanel { Spacing = 6 };
        string? flagText = null;
        var flagStyle = "HudSecondary";
        if (failed is not null)
        {
            flagText = "Couldn't read";
            input = input with { Offline = true };
        }
        else if (tool.OutUntil is { } back)
        {
            flagText = $"Out until {HudText.Clock(back, _culture)}";
            flagStyle = "HudCritical";
        }
        else if (tool.RunningHot)
        {
            flagText = "Running hot";
            flagStyle = "HudCaution";
        }
        var (header, flag) = Header(look, input.Dark, flagText, flagStyle);
        AutomationProperties.SetName(header, look.Name + (flagText is null ? "" : $": {flagText.ToLowerInvariant()}"));
        block.Children.Add(header);
        foreach (var line in tool.Lines) block.Children.Add(LineRow(look, tool, line, input));
        if (failed is not null) block.Children.Add(Note(look, failed, retry: true));
        return (block, flag);
    }

    private (HudRow Header, FrameworkElement? Flag) Header(HudData.Look look, bool dark, string? flagText, string flagStyle)
    {
        var header = new HudRow();
        header.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        header.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        var name = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
        name.Children.Add(Dot(look, dark));
        name.Children.Add(Text(look.Name, "HudStrong"));
        header.Children.Add(name);
        TextBlock? flag = null;
        if (flagText is not null)
        {
            flag = Text(flagText, flagStyle);
            flag.VerticalAlignment = VerticalAlignment.Center;
            Grid.SetColumn(flag, 1);
            header.Children.Add(flag);
        }
        return (header, flag);
    }

    /// One limit: its window, a bar of what's left with the even-pace tick,
    /// the share left and the time to its reset, in the same columns for every tool.
    private HudRow LineRow(HudData.Look look, HudData.Tool tool, HudData.Line line, Input input)
    {
        var row = new HudRow { ColumnSpacing = 8 };
        foreach (var width in new[] { new GridLength(_windowWidth), new GridLength(1, GridUnitType.Star), new GridLength(44), new GridLength(62) })
            row.ColumnDefinitions.Add(new ColumnDefinition { Width = width });
        var window = Text(line.Window, "HudSecondary");
        window.TextTrimming = TextTrimming.CharacterEllipsis;
        if (window.Text.Length > 4) ToolTipService.SetToolTip(window, line.Window);
        var bar = Bar(HudData.Key(tool, line), line);
        if (input.Offline) bar.Opacity = 0.45;
        var share = Text($"{Math.Max(0, line.PercentLeft)}%", input.Offline ? "HudStrongSecondary" : "HudStrong");
        share.HorizontalAlignment = HorizontalAlignment.Right;
        Tabular(share);
        var reset = Text(HudText.Reset(line.PercentLeft, line.ResetsAt, input.Now, _culture), Calibrate && !_calibrated ? "HudCalibrationTertiary" : "HudSecondary");
        _calibrated |= Calibrate;
        reset.HorizontalAlignment = HorizontalAlignment.Right;
        Tabular(reset);
        var cells = new FrameworkElement[] { window, bar, share, reset };
        for (var column = 0; column < cells.Length; column++)
        {
            cells[column].VerticalAlignment = VerticalAlignment.Center;
            Grid.SetColumn(cells[column], column);
            row.Children.Add(cells[column]);
        }
        AutomationProperties.SetName(row, HudText.Sentence(look.Name, line, input.Now, _culture));
        return row;
    }

    private bool _calibrated;

    /// The window names' column: as wide as the widest name (`5h`, or a quota's
    /// own title such as `Claude 5h · work`), from 22 up to 120 px, the same for
    /// every tool so the bars line up; longer names end in an ellipsis.
    private double _windowWidth = 22;

    private static double WindowColumn(HudData? data)
    {
        var widest = 22.0;
        foreach (var line in data?.Tools.SelectMany(tool => tool.Lines) ?? Enumerable.Empty<HudData.Line>())
        {
            var probe = new TextBlock { Text = line.Window, Style = Style("HudSecondary") };
            probe.Measure(new Windows.Foundation.Size(double.PositiveInfinity, double.PositiveInfinity));
            widest = Math.Max(widest, Math.Ceiling(probe.DesiredSize.Width));
        }
        return Math.Min(widest, 120);
    }

    /// A 4 px track, its fill in the accent, caution or critical colour, and a
    /// 2 × 10 px tick where an even pace would end.
    private Grid Bar(string key, HudData.Line line)
    {
        var bar = new Grid { Height = 10 };
        var track = new Grid { Height = 4, VerticalAlignment = VerticalAlignment.Center, Style = Style("HudTrack") };
        if (_fills.Remove(key, out var fill))
        {
            (fill.Parent as Panel)?.Children.Remove(fill);
        }
        else
        {
            fill = new Border { CornerRadius = new CornerRadius(2) };
            fill.Scale = new Vector3(Fraction(line.PercentLeft), 1, 1);
            // Set after the first length, so a new bar doesn't animate in.
            fill.ScaleTransition = new Vector3Transition();
        }
        _fills[key] = fill;
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

    /// Signed out says what to type; couldn't read says who failed and offers a retry.
    private (FrameworkElement Block, FrameworkElement? Flag) ProblemBlock(HudData.Look look, HudData.Problem problem, bool dark)
    {
        var signedOut = problem.Kind == "signedOut";
        var flagText = signedOut ? "Signed out" : "Couldn't read";
        var block = new StackPanel { Spacing = 4 };
        var (header, flag) = Header(look, dark, flagText, "HudSecondary");
        AutomationProperties.SetName(header, $"{look.Name}: {flagText.ToLowerInvariant()}");
        block.Children.Add(header);
        block.Children.Add(Note(look, problem, retry: !signedOut));
        return (block, flag);
    }

    /// What a problem says, and *Try again* for a read that failed.
    private HudRow Note(HudData.Look look, HudData.Problem problem, bool retry)
    {
        var flagText = problem.Kind == "signedOut" ? "Signed out" : "Couldn't read";
        var note = new HudRow { ColumnSpacing = 6 };
        note.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        note.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        var message = Text(problem.Message, "HudSecondary");
        message.TextWrapping = TextWrapping.Wrap;
        note.Children.Add(message);
        AutomationProperties.SetName(note, $"{look.Name}: {flagText.ToLowerInvariant()}. {problem.Message}");
        if (retry)
        {
            var link = Link("Try again", $"Try reading {look.Name} again", () => Refresh?.Invoke());
            link.VerticalAlignment = VerticalAlignment.Top;
            Grid.SetColumn(link, 1);
            note.Children.Add(link);
        }
        return note;
    }

    /// Reading for the first time: the rows it will fill, at their final size.
    private FrameworkElement PendingBlock(HudData.Look look, IReadOnlyList<string> windows, bool dark)
    {
        var block = new StackPanel { Spacing = 6 };
        var (header, _) = Header(look, dark, null, "HudSecondary");
        AutomationProperties.SetName(header, $"{look.Name}: reading");
        block.Children.Add(header);
        foreach (var window in windows)
        {
            var row = new HudRow { ColumnSpacing = 8, Height = 20 };
            foreach (var width in new[] { new GridLength(_windowWidth), new GridLength(1, GridUnitType.Star), new GridLength(44), new GridLength(62) })
                row.ColumnDefinitions.Add(new ColumnDefinition { Width = width });
            if (window != "") row.Children.Add(Text(window, "HudSecondary"));
            for (var column = 1; column < 4; column++)
            {
                var bone = new Border { Style = Style("HudSkeleton"), VerticalAlignment = VerticalAlignment.Center };
                Grid.SetColumn(bone, column);
                row.Children.Add(bone);
            }
            AutomationProperties.SetName(row, window == "" ? $"{look.Name}: reading" : $"{look.Name}, {HudText.LimitName(window, null)}: reading");
            block.Children.Add(row);
        }
        return block;
    }

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
    /// the time of the last numbers and *Retry*.
    private FrameworkElement Footer(Input input)
    {
        var footer = new HudRow { Padding = new Thickness(14, 8, 14, 8), ColumnSpacing = 8, Style = Style("HudDivider") };
        footer.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        footer.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        var left = Text("", "HudSecondary");
        left.TextTrimming = TextTrimming.CharacterEllipsis;
        Tabular(left);
        footer.Children.Add(left);
        string sentence;
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
            Grid.SetColumn(retry, 1);
            footer.Children.Add(retry);
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
            var age = input.Data.ReadAt is { } read ? HudText.Ago(input.Now - read) : "";
            var right = Text(age, "HudSecondary");
            Tabular(right);
            Grid.SetColumn(right, 1);
            footer.Children.Add(right);
            parts.Add($"read {age}");
            sentence = string.Join(", ", parts);
        }
        AutomationProperties.SetName(footer, sentence);
        return footer;
    }

    /// Keep on top, the strip, and ClaudeBar's window.
    private FrameworkElement Toolbar(bool onTop)
    {
        var tools = new StackPanel
        {
            Orientation = Orientation.Horizontal, Spacing = 2, HorizontalAlignment = HorizontalAlignment.Right,
            VerticalAlignment = VerticalAlignment.Top, Margin = new Thickness(0, 4, 8, 0), Visibility = Visibility.Collapsed,
        };
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

    /// One row: each tool's shortest limit, and its other limits only while
    /// they need you; a divider between tools only. A click shows the card.
    internal FrameworkElement Strip(Input input)
    {
        _captions.Clear();
        _passthrough.Clear();
        var row = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 12, Padding = new Thickness(12, 8, 12, 8), Background = new SolidColorBrush(Colors.Transparent) };
        var first = true;
        void Divider()
        {
            if (!first) row.Children.Add(new Border { Width = 1, Style = Style("HudStripDivider") });
            first = false;
        }
        if (input.Data is { IsEmpty: false } data)
        {
            foreach (var tool in data.Tools)
            {
                var look = data.LookOf(tool.Id);
                Divider();
                var item = new HudRow();
                var parts = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6 };
                parts.Children.Add(Dot(look, input.Dark));
                parts.Children.Add(Text(look.Name, "HudBody"));
                var shown = tool.Lines.Where(line => line.Strip).ToList();
                var sentences = new List<string>();
                for (var index = 0; index < shown.Count; index++)
                {
                    var line = shown[index];
                    if (index > 0) parts.Children.Add(Text(line.Window, "HudSecondary", leftMargin: 6));
                    var stale = input.Offline || data.Failed(tool.Id) is not null;
                    var share = Text($"{Math.Max(0, line.PercentLeft)}%", stale ? "HudStrongSecondary" : line.Status switch
                    {
                        "warning" => "HudStrongCaution",
                        "critical" or "depleted" => "HudStrongCritical",
                        _ => "HudStrong",
                    });
                    Tabular(share);
                    parts.Children.Add(share);
                    var reset = Text(HudText.Reset(line.PercentLeft, line.ResetsAt, input.Now, _culture), "HudSecondary");
                    Tabular(reset);
                    parts.Children.Add(reset);
                    sentences.Add(HudText.Sentence(look.Name, line, input.Now, _culture));
                }
                foreach (var child in parts.Children.OfType<FrameworkElement>()) child.VerticalAlignment = VerticalAlignment.Center;
                item.Children.Add(parts);
                AutomationProperties.SetName(item, string.Join(". ", sentences));
                row.Children.Add(item);
            }
            foreach (var problem in data.Alone)
            {
                var look = data.LookOf(problem.Id);
                Divider();
                var item = new HudRow();
                var parts = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6 };
                parts.Children.Add(Dot(look, input.Dark));
                parts.Children.Add(Text(look.Name, "HudBody"));
                var words = problem.Kind switch { "signedOut" => "Signed out", "reading" => "Reading…", _ => "Couldn't read" };
                parts.Children.Add(Text(words, "HudSecondary"));
                foreach (var child in parts.Children.OfType<FrameworkElement>()) child.VerticalAlignment = VerticalAlignment.Center;
                item.Children.Add(parts);
                AutomationProperties.SetName(item, $"{look.Name}: {words.ToLowerInvariant()}");
                row.Children.Add(item);
            }
        }
        else
        {
            var item = new HudRow();
            var text = Text(input.Data is null ? "Reading limits…" : "No AI tools signed in here yet", "HudSecondary");
            item.Children.Add(text);
            AutomationProperties.SetName(item, text.Text);
            row.Children.Add(item);
        }
        if (input.Offline)
        {
            Divider();
            var item = new HudRow();
            var asOf = input.Data?.ReadAt is { } read ? HudText.Clock(read, _culture) : "–";
            item.Children.Add(Text($"Offline · as of {asOf}", "HudSecondary"));
            AutomationProperties.SetName(item, $"Offline. These are the limits as of {asOf}");
            row.Children.Add(item);
        }
        // A click on it opens the card. It has no caption region, so it doesn't
        // drag: the card does, and the strip keeps the card's corner.
        row.Tapped += (_, _) => { ShowCard?.Invoke(); AfterClick?.Invoke(); };
        row.ContextFlyout = Menu();
        return row;
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

    private static void Tabular(TextBlock text) => Typography.SetNumeralAlignment(text, FontNumeralAlignment.Tabular);

    private static Ellipse Dot(HudData.Look look, bool dark) => new()
    {
        Width = 8, Height = 8, VerticalAlignment = VerticalAlignment.Center,
        Fill = new SolidColorBrush(Hex(dark ? look.Dark : look.Light)),
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
