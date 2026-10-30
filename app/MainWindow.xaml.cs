using System.Globalization;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.Json.Nodes;
using System.Text.RegularExpressions;
using Microsoft.UI;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Text;
using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Controls.Primitives;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Shapes;
using Windows.Graphics;
using Windows.Storage.Pickers;
using Windows.UI;

namespace ClaudeBar;

public sealed partial class MainWindow : Window
{
    /// The server's username rule (`Username` in ClaudeBar's package), so Join
    /// is offered only for a name it would take.
    private static readonly Regex UsernameRule = new("^[A-Za-z0-9_-]{3,20}$");

    /// A provider as the app shows it, with its colour in each theme.
    private sealed record Provider(string Id, string Name, string Light, string Dark);

    /// One member of a board, as `/board` and the C interface send it.
    private sealed record Member(int Rank, string Name, long Total, Dictionary<string, long> ByProvider, bool IsYou);

    private readonly DispatcherQueueTimer _pump;
    private List<Provider> _providers = new();
    private JsonObject? _state;
    private JsonObject? _preview;
    private string _period = "7d";
    private string _provider = "";
    private bool _joining;
    private bool _uploading;
    /// The page picked on the left: `limits`, `usage`, `leaderboard` or `settings`.
    private string _section = "limits";
    /// True while the Join page adds this PC to a member instead of making one.
    private bool _addingDevice;
    /// The member the code was approved for; joining waits for it.
    private string? _deviceMember;
    /// Counts code requests, so an answer for one cancelled or replaced is dropped.
    private int _deviceAsk;
    /// True while the window sets its own switches, so their events don't call back.
    private bool _showing;
    /// Counts board reads, so an answer for a board no longer picked is dropped.
    private int _boardRead;
    /// Your row in the list, to pin it at the bottom while it's scrolled away.
    private FrameworkElement? _youRow;
    private readonly Taskbar _taskbar;
    private readonly Tray _tray;
    /// Made on first use: a window that never opens would outlive this one.
    private TrayFlyout? _flyout;
    /// A launch's arguments that came before the window had read the membership.
    private string? _pending;
    /// The last board read and your place on it, for the tray's flyout.
    private (List<Member> Members, JsonObject? You, bool Hidden)? _lastBoard;
    /// Quit from the tray or the HUD: close for real instead of hiding there.
    private bool _quitting;
    /// The HUD, and the limits the Limits page shows.
    private readonly Hud _hud;
    /// Today's tokens read again now and then, for the HUD's footer and Usage.
    private readonly DispatcherQueueTimer _usage;
    /// The id `RegisterHotKey` knows the HUD's shortcut by.
    private const int ShortcutId = 1;

    public MainWindow()
    {
        InitializeComponent();
        ExtendsContentIntoTitleBar = true;
        SetTitleBar(TitleBarArea);
        AppWindow.SetIcon(System.IO.Path.Combine(AppContext.BaseDirectory, "Assets", "ClaudeBar.ico"));
        Place();
        BuildMiniPodium();
        // Swift's main actor runs on this UI thread only when it drains Swift's main queue.
        _pump = DispatcherQueue.CreateTimer();
        _pump.Interval = TimeSpan.FromMilliseconds(16);
        _pump.Tick += (_, _) => Native.cbw_drain_main_queue();
        _pump.Start();
        Root.ActualThemeChanged += (_, _) =>
        {
            BuildMiniPodium();
            BuildPills();
            ShowLimits();
            ShowUsage();
            if (BoardPage.Visibility == Visibility.Visible) _ = LoadBoard(keepList: false);
        };

        var handle = WinRT.Interop.WindowNative.GetWindowHandle(this);
        _taskbar = new Taskbar(handle);
        _tray = new Tray(handle)
        {
            OpenWindow = () => Open(""),
            OpenFlyout = OpenTrayFlyout,
            UploadNow = () => Open("--upload"),
            Quit = Quit,
        };
        _taskbar.OnMessage = (message, wParam, lParam) => _tray.Handle(message, wParam, lParam) || OnShortcut(message, wParam);
        if (Preferences.TrayIcon) _tray.Show();
        Taskbar.SetJumpList();
        _hud = new Hud(DispatcherQueue, refresh => refresh ? Swift.HudRefresh() : Swift.HudReading())
        {
            OpenWindow = () => Open(""),
            OpenSettings = () => { Open(""); Navigate("settings"); },
            OpenLimits = () => { Open(""); Navigate("limits"); },
            ChooseTools = () => { Open(""); Navigate("settings"); OnChooseTools(HudToolsButton, new RoutedEventArgs()); },
            Quit = Quit,
            Changed = OnHudChanged,
            Crossed = OnCrossed,
            SettingsChanged = ShowHudSettings,
        };
        _usage = DispatcherQueue.CreateTimer();
        _usage.Interval = TimeSpan.FromMinutes(30);
        _usage.Tick += (_, _) => _ = ReadUsage();
        RegisterShortcut();
        AppWindow.Closing += (_, e) =>
        {
            // With the tray icon or the HUD on, closing keeps ClaudeBar running there.
            if ((_tray.IsShown || _hud.IsShown) && !_quitting)
            {
                e.Cancel = true;
                AppWindow.Hide();
            }
        };
        Closed += (_, _) =>
        {
            _tray.Dispose();
            _flyout?.Close();
            _usage.Stop();
            _hud.Dispose();
            Win32.UnregisterHotKey(handle, ShortcutId);
        };
        ShowHudSettings();
        Navigate("limits");
    }

    /// Reads the membership, the limits and today's tokens. The window may stay
    /// hidden meanwhile: started with Windows, the HUD is enough.
    internal void Start()
    {
        _ = Guarded(async () => Show(await Swift.State()));
        Startup.Adopt();
        _hud.Start();
        _ = ReadUsage();
        _usage.Start();
    }

    /// A launch's arguments, this one's or a second launch's handed over, or a
    /// notification's: `--startup` (signed in: the window waits behind the HUD
    /// or the tray), `--hud` (show the HUD), `--refresh`, `--quiet=<limit>`,
    /// `--upload`, `--settings`, `--board`, or just the window.
    internal void Open(string arguments)
    {
        var words = LaunchArguments.Words(arguments);
        // These need no window, while ClaudeBar shows somewhere: the HUD, the tray or the window itself.
        var shownElsewhere = Preferences.Hud || _tray.IsShown || AppWindow.IsVisible;
        if (LaunchArguments.Quiet(arguments) is { } quiet)
        {
            _hud.Quiet(quiet);
            if (shownElsewhere) return;
        }
        else if (words.Contains("--hud"))
        {
            _hud.SetShown(true);
            return;
        }
        else if (words.Contains("--refresh"))
        {
            _ = _hud.Read(refresh: true);
            if (shownElsewhere) return;
        }
        else if (words.Contains("--startup") && shownElsewhere) return;
        AppWindow.Show();
        Activate();
        if (words.Contains("--settings")) Navigate("settings");
        else if (words.Contains("--board")) Navigate("leaderboard");
        if (_state is null)
        {
            _pending = arguments;
            return;
        }
        if (_state["joined"]?.GetValue<bool>() != true) return;
        if (words.Contains("--upload")) OnUploadNow(this, new RoutedEventArgs());
    }

    private void Quit()
    {
        _quitting = true;
        Close();
        Application.Current.Exit();
    }

    private void OpenTrayFlyout()
    {
        var content = new StackPanel { Spacing = 8 };
        var title = new Grid();
        title.Children.Add(new TextBlock { Text = "ClaudeBar", FontWeight = FontWeights.SemiBold });
        title.Children.Add(new TextBlock { Text = PeriodName(_period), HorizontalAlignment = HorizontalAlignment.Right, Style = (Style)Root.Resources["Tertiary"] });
        content.Children.Add(title);
        if (_lastBoard is { } board && _state?["joined"]?.GetValue<bool>() == true)
        {
            var you = board.You;
            var card = new StackPanel { Spacing = 2 };
            var rank = new TextBlock { FontFamily = new FontFamily("Segoe UI Variable Display"), Foreground = Resource("AccentTextFillColorPrimaryBrush") };
            rank.Inlines.Add(new Microsoft.UI.Xaml.Documents.Run { Text = you is null ? "" : "#", FontSize = 22, Foreground = Resource("TextFillColorTertiaryBrush") });
            rank.Inlines.Add(new Microsoft.UI.Xaml.Documents.Run { Text = you is null ? "–" : $"{you["rank"]}", FontSize = 40, FontWeight = FontWeights.SemiBold });
            card.Children.Add(new TextBlock { Text = "YOUR RANK", Style = (Style)Root.Resources["Eyebrow"] });
            card.Children.Add(rank);
            card.Children.Add(new TextBlock { Text = you is null ? "Nothing uploaded for this board yet" : $"{Tokens(you["total"]!.GetValue<long>())} tokens", FontWeight = FontWeights.SemiBold });
            if (you is not null)
            {
                var mix = new Grid { Height = 5, ColumnSpacing = 2, Margin = new Thickness(0, 6, 0, 0) };
                FillMix(mix, Mix(you["byProvider"]));
                card.Children.Add(mix);
                if (Gap(you["rank"]!.GetValue<int>(), you["total"]!.GetValue<long>(), board.Members) is string gap)
                    card.Children.Add(new TextBlock { Text = gap + (board.Hidden ? " · only you see this place" : ""), Style = (Style)Root.Resources["Secondary"] });
            }
            content.Children.Add(new Border { Style = (Style)Root.Resources["Card"], Padding = new Thickness(14, 10, 14, 12), Child = card });
            var list = new StackPanel();
            foreach (var member in board.Members.Take(4)) list.Children.Add(CompactRow(member));
            if (board.Members.FirstOrDefault(member => member.IsYou) is { Rank: > 4 } yours) list.Children.Add(CompactRow(yours));
            content.Children.Add(list);
        }
        else
        {
            content.Children.Add(new TextBlock { Text = "Join the leaderboard in ClaudeBar to see your place here.", Style = (Style)Root.Resources["Secondary"] });
        }
        _flyout ??= new TrayFlyout { OpenWindow = () => Open(""), OpenSettings = () => Open("--settings") };
        _flyout.Open(_tray.Bounds(), content);
        if (_state?["joined"]?.GetValue<bool>() == true) _ = LoadBoard(keepList: true);
    }

    private Grid CompactRow(Member member)
    {
        var row = new Grid { Height = 32, ColumnSpacing = 10, Padding = new Thickness(8, 0, 8, 0), CornerRadius = new CornerRadius(4) };
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(30) });
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        var cells = new FrameworkElement[]
        {
            new TextBlock { Text = $"#{member.Rank}", FontSize = 12, Foreground = Resource("TextFillColorTertiaryBrush"), VerticalAlignment = VerticalAlignment.Center },
            new TextBlock { Text = $"@{member.Name}", FontWeight = member.IsYou ? FontWeights.SemiBold : FontWeights.Normal, TextTrimming = TextTrimming.CharacterEllipsis, VerticalAlignment = VerticalAlignment.Center },
            new TextBlock { Text = Tokens(member.Total), FontWeight = FontWeights.SemiBold, VerticalAlignment = VerticalAlignment.Center },
        };
        for (var column = 0; column < cells.Length; column++)
        {
            Grid.SetColumn(cells[column], column);
            row.Children.Add(cells[column]);
        }
        if (member.IsYou) row.Background = new SolidColorBrush(WithAlpha(AccentColor(), 0x1F));
        return row;
    }

    private void OnTrayToggled(object sender, RoutedEventArgs e)
    {
        if (_showing) return;
        Preferences.TrayIcon = TraySwitch.IsOn;
        if (TraySwitch.IsOn) _tray.Show(); else _tray.Hide();
    }

    /// 760 × 760 effective pixels, centred, never larger than the work area:
    /// `AppWindow` sizes in physical pixels, so the display's scale is applied here.
    private void Place()
    {
        var scale = GetDpiForWindow(WinRT.Interop.WindowNative.GetWindowHandle(this)) / 96.0;
        var work = DisplayArea.GetFromWindowId(AppWindow.Id, DisplayAreaFallback.Primary).WorkArea;
        var width = Math.Min((int)(760 * scale), work.Width);
        var height = Math.Min((int)(760 * scale), work.Height);
        AppWindow.MoveAndResize(new RectInt32(work.X + (work.Width - width) / 2, work.Y + (work.Height - height) / 2, width, height));
    }

    [LibraryImport("user32.dll")]
    private static partial uint GetDpiForWindow(nint window);

    // MARK: - Pages

    private void Show(JsonObject reply)
    {
        if (reply["error"] is JsonNode error) Tell(error.GetValue<string>(), InfoBarSeverity.Error);
        if (reply["state"] is not JsonObject state) return;
        _state = state;
        _providers = (state["providers"]?.AsArray() ?? new JsonArray()).Select(provider => new Provider(
            provider!["id"]!.GetValue<string>(), provider["name"]!.GetValue<string>(),
            provider["light"]?.GetValue<string>() ?? "#8A8A8A", provider["dark"]?.GetValue<string>() ?? "#8A8A8A")).ToList();
        VersionText.Text = $"ClaudeBar for Windows {state["version"]}";
        var joined = state["joined"]?.GetValue<bool>() == true;
        CopiedKeyBar.IsOpen = joined && state["copiedKey"]?.GetValue<bool>() == true;
        LeaderboardSettings.Visibility = joined ? Visibility.Visible : Visibility.Collapsed;
        NotJoinedSettings.Visibility = joined ? Visibility.Collapsed : Visibility.Visible;
        UpdatePages();
        if (!joined)
        {
            _ = Uploads.UnscheduleAsync();
            _taskbar.Clear();
            _lastBoard = null;
            _hud.Place = null;
            Standings.Children.Clear();
            Podium.Children.Clear();
            _ = Guarded(LoadPreview);
            return;
        }
        _ = EnsureScheduled();
        if (Pills.Children.Count == 0) BuildPills();
        ShowUploadStatus(state);
        ShowSettings(state);
        _ = LoadBoard(keepList: Standings.Children.Count > 0);
        if (_pending is { } pending)
        {
            _pending = null;
            Open(pending);
        }
    }

    /// Picks a page on the left, as a click there would.
    private void Navigate(string section)
    {
        Nav.SelectedItem = section switch
        {
            "usage" => UsageItem,
            "leaderboard" => LeaderboardItem,
            "settings" => Nav.SettingsItem,
            _ => LimitsItem,
        };
        _section = section;
        UpdatePages();
    }

    private void OnNavigate(NavigationView sender, NavigationViewSelectionChangedEventArgs e)
    {
        var section = e.IsSettingsSelected ? "settings" : (e.SelectedItem as NavigationViewItem)?.Tag as string ?? "limits";
        _section = section;
        UpdatePages();
        if (section == "settings")
        {
            ShowHudSettings();
            if (_state?["joined"]?.GetValue<bool>() == true) _ = Guarded(LoadWeek);
        }
        if (section == "usage") _ = ReadUsage();
    }

    /// The picked page; the Leaderboard is the board once joined, else joining.
    private void UpdatePages()
    {
        var joined = _state?["joined"]?.GetValue<bool>() == true;
        void Set(FrameworkElement page, bool shown) => page.Visibility = shown ? Visibility.Visible : Visibility.Collapsed;
        Set(LimitsPage, _section == "limits");
        Set(UsagePage, _section == "usage");
        Set(JoinPage, _section == "leaderboard" && _state is not null && !joined);
        Set(BoardPage, _section == "leaderboard" && joined);
        Set(SettingsPage, _section == "settings");
    }

    private void OnOpenSettings(object sender, RoutedEventArgs e) => Navigate("settings");

    private void OnOpenLeaderboard(object sender, RoutedEventArgs e) => Navigate("leaderboard");

    // MARK: - Board

    /// Reads the board for the picked period and provider. A new board starts
    /// from an empty list that says it is loading; a refresh keeps the list
    /// until the answer, and a failed one keeps it and says it couldn't update.
    private async Task LoadBoard(bool keepList)
    {
        var read = ++_boardRead;
        var period = _period;
        var provider = _provider;
        BoardSubtitle.Text = $"{(provider == "" ? "All providers" : NameOf(provider))} · {PeriodPhrase(period)}";
        RankCaption.Text = $"YOUR RANK · {PeriodName(period).ToUpperInvariant()}";
        RefreshButton.IsEnabled = false;
        if (!keepList)
        {
            Standings.Children.Clear();
            Podium.Children.Clear();
            _youRow = null;
            PinnedYou.Visibility = Visibility.Collapsed;
            RankHash.Text = "";
            RankNumber.Text = "–";
            TokensNumber.Text = "Loading…";
            TokensUnit.Text = "";
            RankMix.Children.Clear();
            RankMix.ColumnDefinitions.Clear();
            RankLegend.Children.Clear();
            GapLine.Visibility = Visibility.Collapsed;
            BoardNote.Visibility = Visibility.Collapsed;
            ShowBoardStatus("Loading the board…", busy: true);
        }

        JsonObject reply;
        try { reply = await Swift.Board(period, provider); }
        catch (Exception failure) { reply = new JsonObject { ["error"] = failure.Message }; }
        if (read != _boardRead) return;
        RefreshButton.IsEnabled = true;

        if (reply["error"] is JsonNode error)
        {
            if (Standings.Children.Count == 0)
            {
                RankHash.Text = "";
                TokensNumber.Text = "–";
                ShowBoardStatus($"Couldn't load the board. {error.GetValue<string>()}", busy: false);
            }
            else
            {
                BoardNote.Text = $"Couldn't update: {error.GetValue<string>()}";
                BoardNote.Visibility = Visibility.Visible;
            }
            return;
        }

        BoardNote.Visibility = Visibility.Collapsed;
        var members = (reply["members"]?.AsArray() ?? new JsonArray()).Select(member => new Member(
            member!["rank"]!.GetValue<int>(), member["username"]!.GetValue<string>(), member["total"]!.GetValue<long>(),
            Mix(member["byProvider"]), member["you"]?.GetValue<bool>() == true)).ToList();
        var hidden = reply["state"]?["visible"]?.GetValue<bool>() == false;
        ShowRank(reply["you"] as JsonObject, members, hidden);
        ShowStandings(members);
        if (members.Count == 0) ShowBoardStatus("No one is on this board yet.", busy: false);
        else BoardStatus.Visibility = Visibility.Collapsed;
        // Laid out first, so the pin can tell where your row is.
        DispatcherQueue.TryEnqueue(DispatcherQueuePriority.Low, UpdatePinnedYou);
        _lastBoard = (members, reply["you"] as JsonObject, hidden);
        _taskbar.Show(GlanceOf(reply["you"] as JsonObject, members, hidden), IsDark, AccentColor());
        _hud.Place = reply["you"]?["rank"]?.GetValue<int>() is int place ? $"#{place} {PlacePhrase(period)}" : null;
        _hud.Render();
    }

    private Glance GlanceOf(JsonObject? you, List<Member> members, bool hidden)
    {
        if (you is null) return new Glance(null, PeriodName(_period), 0, null, Array.Empty<(Color, long)>(), hidden);
        var rank = you["rank"]!.GetValue<int>();
        var total = you["total"]!.GetValue<long>();
        var mix = Mix(you["byProvider"]);
        var parts = _providers.Where(p => mix.GetValueOrDefault(p.Id) > 0).Select(p => (ColorOf(p.Id), mix[p.Id])).ToList();
        return new Glance(rank, PeriodName(_period), total, Gap(rank, total, members), parts, hidden);
    }

    private void ShowRank(JsonObject? you, List<Member> members, bool hidden)
    {
        RankName.Text = $"@{_state?["username"]}";
        HiddenChip.Visibility = hidden ? Visibility.Visible : Visibility.Collapsed;
        RankMix.Children.Clear();
        RankMix.ColumnDefinitions.Clear();
        RankLegend.Children.Clear();
        if (you is null)
        {
            RankHash.Text = "";
            RankNumber.Text = "–";
            TokensNumber.Text = "Nothing uploaded";
            TokensUnit.Text = " for this board yet";
            GapLine.Visibility = Visibility.Collapsed;
            return;
        }
        var rank = you["rank"]!.GetValue<int>();
        var total = you["total"]!.GetValue<long>();
        var mix = Mix(you["byProvider"]);
        RankHash.Text = "#";
        RankNumber.Text = rank.ToString(CultureInfo.InvariantCulture);
        TokensNumber.Text = Tokens(total);
        TokensUnit.Text = " tokens";
        FillMix(RankMix, mix);
        foreach (var (id, share) in Shares(mix).Take(3))
        {
            var item = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 5 };
            item.Children.Add(new Ellipse { Width = 8, Height = 8, Fill = Brush(ColorOf(id)), VerticalAlignment = VerticalAlignment.Center });
            item.Children.Add(new TextBlock { Text = $"{NameOf(id)} {share}%", FontSize = 11, Foreground = Resource("TextFillColorTertiaryBrush") });
            RankLegend.Children.Add(item);
        }
        var lines = new List<string>();
        if (Gap(rank, total, members) is string gap) lines.Add(gap);
        // A hidden member is still ranked for themselves (design §4), just absent from the list.
        if (hidden) lines.Add("only you see this place");
        GapText.Text = string.Join(" · ", lines);
        GapLine.Visibility = lines.Count > 0 ? Visibility.Visible : Visibility.Collapsed;
    }

    /// The top three on a podium, second and third either side of first, then the rest.
    private void ShowStandings(List<Member> members)
    {
        Standings.Children.Clear();
        Podium.Children.Clear();
        _youRow = null;
        _youMember = null;
        PinnedYou.Child = null;
        var podium = members.Count >= 3 ? members.Take(3).ToList() : new List<Member>();
        foreach (var (member, column) in podium.Zip(new[] { 1, 0, 2 }))
        {
            var step = Step(member, first: column == 1);
            Grid.SetColumn(step, column);
            Podium.Children.Add(step);
        }
        Podium.Visibility = podium.Count > 0 ? Visibility.Visible : Visibility.Collapsed;
        foreach (var member in members.Skip(podium.Count))
        {
            var row = Row(member);
            if (member.IsYou) (_youRow, _youMember) = (row, member);
            Standings.Children.Add(row);
        }
    }

    private FrameworkElement Step(Member member, bool first)
    {
        var medal = member.Rank switch { 1 => Medal("#F2C14E", "#D9A21B"), 2 => Medal("#C3CCD6", "#9AA5B1"), _ => Medal("#D9925F", "#C0723D") };
        var border = new Border
        {
            CornerRadius = new CornerRadius(8), BorderThickness = new Thickness(1),
            Padding = first ? new Thickness(6, 18, 6, 14) : new Thickness(6, 12, 6, 10),
            VerticalAlignment = VerticalAlignment.Bottom,
            Background = first
                ? new LinearGradientBrush
                {
                    StartPoint = new Windows.Foundation.Point(0, 0), EndPoint = new Windows.Foundation.Point(0, 1),
                    GradientStops = { new GradientStop { Color = WithAlpha(medal, 0x30), Offset = 0 }, new GradientStop { Color = Colors.Transparent, Offset = 0.75 } },
                }
                : Resource("CardBackgroundFillColorDefaultBrush"),
            BorderBrush = first ? new SolidColorBrush(WithAlpha(medal, 0x70)) : Resource("CardStrokeColorDefaultBrush"),
        };
        if (member.IsYou) border.BorderBrush = Resource("AccentFillColorDefaultBrush");
        var stack = new StackPanel { Spacing = 2 };
        var size = first ? 44 : 36;
        var avatar = Avatar(member.Name, size);
        var badge = new Border
        {
            Width = 18, Height = 18, CornerRadius = new CornerRadius(9), Background = new SolidColorBrush(medal),
            BorderThickness = new Thickness(2), BorderBrush = Resource("SolidBackgroundFillColorBaseBrush"),
            HorizontalAlignment = HorizontalAlignment.Right, VerticalAlignment = VerticalAlignment.Bottom, Margin = new Thickness(0, 0, -4, -3),
            Child = new TextBlock { Text = $"{member.Rank}", FontSize = 10, FontWeight = FontWeights.Bold, Foreground = new SolidColorBrush(Color.FromArgb(255, 0x1B, 0x1A, 0x19)), HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center },
        };
        var avatarGrid = new Grid { Width = size, Height = size, HorizontalAlignment = HorizontalAlignment.Center, Margin = new Thickness(0, 0, 0, 6) };
        avatarGrid.Children.Add(avatar);
        avatarGrid.Children.Add(badge);
        stack.Children.Add(avatarGrid);
        stack.Children.Add(new TextBlock { Text = $"@{member.Name}", FontSize = 12, FontWeight = FontWeights.SemiBold, TextTrimming = TextTrimming.CharacterEllipsis, HorizontalAlignment = HorizontalAlignment.Center });
        stack.Children.Add(new TextBlock { Text = Tokens(member.Total), FontSize = 15, FontWeight = FontWeights.SemiBold, FontFamily = new FontFamily("Segoe UI Variable Display"), HorizontalAlignment = HorizontalAlignment.Center });
        var mix = new Grid { Height = 4, ColumnSpacing = 2, Margin = new Thickness(8, 8, 8, 0) };
        FillMix(mix, member.ByProvider);
        stack.Children.Add(mix);
        border.Child = stack;
        AutomationProperties.SetName(border, $"Rank {member.Rank}, {member.Name}, {Tokens(member.Total)} tokens" + (member.IsYou ? ", you" : ""));
        return border;
    }

    /// One member of the list: rank, avatar, name, mix and tokens; your row set apart.
    private Grid Row(Member member)
    {
        var row = new Grid { Height = 44, ColumnSpacing = 10, Padding = new Thickness(10, 0, 10, 0), CornerRadius = new CornerRadius(6) };
        foreach (var width in new[] { new GridLength(34), new GridLength(28), new GridLength(1, GridUnitType.Star), new GridLength(64), new GridLength(62) })
            row.ColumnDefinitions.Add(new ColumnDefinition { Width = width });
        var rank = new TextBlock { Text = $"#{member.Rank}", FontSize = 13, Foreground = Resource("TextFillColorTertiaryBrush"), VerticalAlignment = VerticalAlignment.Center };
        var avatar = Avatar(member.Name, 28);
        var name = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6, VerticalAlignment = VerticalAlignment.Center };
        name.Children.Add(new TextBlock { Text = $"@{member.Name}", FontWeight = member.IsYou ? FontWeights.SemiBold : FontWeights.Normal, TextTrimming = TextTrimming.CharacterEllipsis });
        if (member.IsYou) name.Children.Add(new TextBlock { Text = "YOU", FontSize = 10, FontWeight = FontWeights.Bold, CharacterSpacing = 50, Foreground = Resource("AccentTextFillColorPrimaryBrush"), VerticalAlignment = VerticalAlignment.Center });
        var mix = new Grid { Height = 4, ColumnSpacing = 2, VerticalAlignment = VerticalAlignment.Center };
        FillMix(mix, member.ByProvider);
        var tokens = new TextBlock { Text = Tokens(member.Total), FontWeight = FontWeights.SemiBold, HorizontalAlignment = HorizontalAlignment.Right, VerticalAlignment = VerticalAlignment.Center };
        var cells = new FrameworkElement[] { rank, avatar, name, mix, tokens };
        for (var column = 0; column < cells.Length; column++)
        {
            Grid.SetColumn(cells[column], column);
            row.Children.Add(cells[column]);
        }
        if (member.IsYou)
        {
            row.Background = new SolidColorBrush(WithAlpha(AccentColor(), 0x1F));
            var bar = new Rectangle { Width = 3, HorizontalAlignment = HorizontalAlignment.Left, Fill = Resource("AccentFillColorDefaultBrush"), Margin = new Thickness(-10, 8, 0, 8), RadiusX = 1.5, RadiusY = 1.5 };
            Grid.SetColumnSpan(bar, 5);
            row.Children.Add(bar);
        }
        else
        {
            row.PointerEntered += (_, _) => row.Background = Resource("SubtleFillColorSecondaryBrush");
            row.PointerExited += (_, _) => row.Background = null;
        }
        AutomationProperties.SetName(row, $"Rank {member.Rank}, {member.Name}, {Tokens(member.Total)} tokens" + (member.IsYou ? ", you" : ""));
        return row;
    }

    private void OnBoardScrolled(object? sender, ScrollViewerViewChangedEventArgs e) => UpdatePinnedYou();

    /// Your row, pinned at the bottom of the board while the list has scrolled it away, as on the Mac.
    private void UpdatePinnedYou()
    {
        if (_youRow is null || _youMember is null || _youRow.ActualHeight == 0)
        {
            PinnedYou.Visibility = Visibility.Collapsed;
            return;
        }
        var top = _youRow.TransformToVisual(BoardScroll).TransformPoint(new Windows.Foundation.Point(0, 0)).Y;
        var inView = top >= 0 && top + _youRow.ActualHeight <= BoardScroll.ViewportHeight;
        if (inView)
        {
            PinnedYou.Visibility = Visibility.Collapsed;
            return;
        }
        PinnedYou.Child ??= Row(_youMember);
        PinnedYou.Visibility = Visibility.Visible;
    }

    /// You in the list below the podium, and your row there.
    private Member? _youMember;

    private void ShowBoardStatus(string text, bool busy)
    {
        BoardStatusText.Text = text;
        BoardBusy.IsActive = busy;
        BoardBusy.Visibility = busy ? Visibility.Visible : Visibility.Collapsed;
        BoardStatus.Visibility = Visibility.Visible;
    }

    private void BuildPills()
    {
        Pills.Children.Clear();
        Pills.Children.Add(Pill("", "All", null));
        foreach (var provider in _providers) Pills.Children.Add(Pill(provider.Id, provider.Name, ColorOf(provider.Id)));
    }

    private ToggleButton Pill(string id, string name, Color? color)
    {
        var content = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6 };
        if (color is Color dot) content.Children.Add(new Ellipse { Width = 8, Height = 8, Fill = Brush(dot), VerticalAlignment = VerticalAlignment.Center });
        content.Children.Add(new TextBlock { Text = name, FontSize = 13 });
        var pill = new ToggleButton { Content = content, IsChecked = id == _provider, CornerRadius = new CornerRadius(14), Padding = new Thickness(11, 4, 11, 5), Tag = id };
        AutomationProperties.SetName(pill, name);
        pill.Click += async (_, _) =>
        {
            _provider = id;
            foreach (var each in Pills.Children.OfType<ToggleButton>()) each.IsChecked = (string)each.Tag == id;
            await LoadBoard(keepList: false);
        };
        return pill;
    }

    private async void OnPeriodChanged(SelectorBar sender, SelectorBarSelectionChangedEventArgs e)
    {
        if (sender.SelectedItem?.Tag is not string period) return;
        _period = period;
        if (BoardPage.Visibility == Visibility.Visible) await LoadBoard(keepList: false);
    }

    private async void OnRefresh(object sender, RoutedEventArgs e) => await Guarded(async () => Show(await Swift.State()));

    // MARK: - Uploads

    private void ShowUploadStatus(JsonObject state)
    {
        var refused = state["refused"]?.GetValue<int>() ?? 0;
        DateTimeOffset? last = state["lastUpload"] is JsonNode at ? DateTimeOffset.Parse(at.GetValue<string>(), CultureInfo.InvariantCulture) : null;
        var stale = last is { } uploadedAt && DateTimeOffset.Now - uploadedAt > TimeSpan.FromDays(1);
        var copied = state["copiedKey"]?.GetValue<bool>() == true;
        var text = copied ? "Not uploading · the key is a copy"
            : last is { } uploaded ? $"Uploaded {Ago(uploaded)} · every hour" : "Not uploaded yet · every hour";
        if (refused > 0 && !copied) text += $" · {Count(refused, "day")} refused, sent again each hour";
        UploadStatus.Text = text;
        UploadIcon.Glyph = copied || stale || last is null ? "\uE7BA" : "\uE930";
        UploadIcon.Foreground = Resource(copied || stale ? "SystemFillColorCautionBrush" : last is null ? "TextFillColorTertiaryBrush" : "SystemFillColorSuccessBrush");
        UploadDetail.Text = (last is { } done ? $"Last upload {Ago(done)}." : "Nothing uploaded yet.") + " A missed hour is caught up next time.";
    }

    /// *Keep the key here*: the other PC is gone, or this is it after a repair.
    private async void OnKeepKeyHere(object sender, RoutedEventArgs e)
    {
        KeepKeyButton.IsEnabled = false;
        await Guarded(async () =>
        {
            var reply = await Swift.KeepKeyHere();
            if (reply["error"] is null) Tell("This PC keeps the key and uploads again.", InfoBarSeverity.Success);
            Show(reply);
        });
        KeepKeyButton.IsEnabled = true;
    }

    private async void OnUploadNow(object sender, RoutedEventArgs e)
    {
        if (_uploading) return;
        _uploading = true;
        UploadLink.IsEnabled = UploadButton.IsEnabled = false;
        UploadBusy.IsActive = true;
        await Guarded(async () =>
        {
            var reply = await Swift.UploadNow();
            if (reply["error"] is null) Tell("Uploaded.", InfoBarSeverity.Success);
            Show(reply);
        });
        UploadBusy.IsActive = false;
        UploadLink.IsEnabled = UploadButton.IsEnabled = true;
        _uploading = false;
    }

    // MARK: - Settings

    private void ShowSettings(JsonObject state)
    {
        _showing = true;
        try
        {
            var name = state["username"]?.GetValue<string>() ?? "";
            ProfileName.Text = $"@{name}";
            ProfileInitial.Text = name.Length > 0 ? name[..1].ToUpperInvariant() : "";
            ProfileAvatar.Fill = new SolidColorBrush(AvatarColor(name));
            ProfileDevice.Text = $"This PC · {state["label"]}";
            VisibleSwitch.IsOn = state["visible"]?.GetValue<bool>() == true;
            TraySwitch.IsOn = _tray.IsShown;
            MemberProviders.Children.Clear();
            var shared = (state["providers"]?.AsArray() ?? new JsonArray()).ToDictionary(p => p!["id"]!.GetValue<string>(), p => p!["shared"]!.GetValue<bool>());
            foreach (var provider in _providers) MemberProviders.Children.Add(ProviderSwitch(provider, shared.GetValueOrDefault(provider.Id)));
        }
        finally { _showing = false; }
    }

    /// A provider's line in Settings: its colour, name, what it sent this week, and its switch.
    private Grid ProviderSwitch(Provider provider, bool shared)
    {
        var week = WeekTokens(provider.Id);
        var none = week == 0 && !shared;
        var row = new Grid { Padding = new Thickness(48, 8, 16, 8), ColumnSpacing = 12, BorderThickness = new Thickness(0, 1, 0, 0), BorderBrush = Resource("DividerStrokeColorDefaultBrush"), Opacity = none ? 0.6 : 1 };
        foreach (var width in new[] { GridLength.Auto, new GridLength(1, GridUnitType.Star), GridLength.Auto, GridLength.Auto })
            row.ColumnDefinitions.Add(new ColumnDefinition { Width = width });
        var dot = new Ellipse { Width = 10, Height = 10, Fill = Brush(ColorOf(provider.Id)), VerticalAlignment = VerticalAlignment.Center };
        var name = new TextBlock { Text = provider.Name, VerticalAlignment = VerticalAlignment.Center };
        var amount = new TextBlock
        {
            Text = week is null ? "Counting…" : week > 0 ? $"{Tokens(week.Value)} this week" : "No tokens on this PC",
            Style = (Style)Root.Resources["Tertiary"], VerticalAlignment = VerticalAlignment.Center, TextWrapping = TextWrapping.NoWrap,
        };
        var toggle = new ToggleSwitch { IsOn = shared, Tag = provider.Id, OnContent = null, OffContent = null, MinWidth = 0, VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(0, 0, -12, 0) };
        AutomationProperties.SetName(toggle, $"Share {provider.Name}");
        toggle.Toggled += OnSharingToggled;
        var cells = new FrameworkElement[] { dot, name, amount, toggle };
        for (var column = 0; column < cells.Length; column++)
        {
            Grid.SetColumn(cells[column], column);
            row.Children.Add(cells[column]);
        }
        return row;
    }

    private long? WeekTokens(string id) =>
        (_preview?["providers"]?.AsArray() ?? new JsonArray()).FirstOrDefault(p => p!["id"]!.GetValue<string>() == id)?["week"]?.GetValue<long>();

    private async Task LoadWeek()
    {
        await ReadPreview();
        if (_state is not null) ShowSettings(_state);
    }

    private async void OnSharingToggled(object sender, RoutedEventArgs e)
    {
        if (_showing || sender is not ToggleSwitch toggle) return;
        toggle.IsEnabled = false;
        if (!await Guarded(async () => Show(await Swift.SetSharing((string)toggle.Tag, toggle.IsOn)))) RestoreSwitches();
        toggle.IsEnabled = true;
    }

    private async void OnVisibleToggled(object sender, RoutedEventArgs e)
    {
        if (_showing) return;
        VisibleSwitch.IsEnabled = false;
        if (!await Guarded(async () => Show(await Swift.SetVisible(VisibleSwitch.IsOn)))) RestoreSwitches();
        VisibleSwitch.IsEnabled = true;
    }

    /// The switches as the membership last said, after a call that threw and
    /// so brought no state to show: none keeps the position it was flipped to.
    private void RestoreSwitches()
    {
        if (_state is not null) ShowSettings(_state);
    }

    /// The hourly task, made when it's missing; off the UI thread, since `schtasks` can be slow.
    private async Task EnsureScheduled()
    {
        if (await Uploads.EnsureScheduledAsync()) return;
        Tell("The hourly upload couldn't be set up. Use Upload now until it is.", InfoBarSeverity.Warning);
    }

    private async void OnExport(object sender, RoutedEventArgs e)
    {
        ExportButton.IsEnabled = false;
        await Guarded(async () =>
        {
            var reply = await Swift.Export();
            if (reply["error"] is JsonNode error)
            {
                Tell(error.GetValue<string>(), InfoBarSeverity.Error);
                return;
            }
            var picker = new FileSavePicker { SuggestedStartLocation = PickerLocationId.DocumentsLibrary, SuggestedFileName = $"claudebar-leaderboard-{_state?["username"]}" };
            picker.FileTypeChoices.Add("JSON", new List<string> { ".json" });
            WinRT.Interop.InitializeWithWindow.Initialize(picker, WinRT.Interop.WindowNative.GetWindowHandle(this));
            if (await picker.PickSaveFileAsync() is not { } file) return;
            await System.IO.File.WriteAllTextAsync(file.Path, reply["export"]!.GetValue<string>(), new UTF8Encoding(false));
            Tell($"Saved {file.Name}.", InfoBarSeverity.Success);
        });
        ExportButton.IsEnabled = true;
    }

    private async void OnLeave(object sender, RoutedEventArgs e)
    {
        var dialog = new ContentDialog
        {
            XamlRoot = Content.XamlRoot,
            Title = "Leave the leaderboard?",
            Content = "Your username and every uploaded day are deleted from the server, then this PC's key. This can't be undone.",
            PrimaryButtonText = "Leave and delete my data",
            CloseButtonText = "Cancel",
            DefaultButton = ContentDialogButton.Close,
        };
        if (await dialog.ShowAsync() != ContentDialogResult.Primary) return;
        LeaveButton.IsEnabled = false;
        await Guarded(async () =>
        {
            var reply = await Swift.Leave();
            if (reply["error"] is null) Tell("You left the leaderboard. Your data was deleted.", InfoBarSeverity.Success);
            Show(reply);
        });
        LeaveButton.IsEnabled = true;
    }

    // MARK: - Join

    private void BuildMiniPodium()
    {
        MiniPodium.Children.Clear();
        foreach (var (rank, height, light, dark) in new[] { (2, 46, "#9AA5B1", "#C3CCD6"), (1, 66, "#D9A21B", "#F2C14E"), (3, 34, "#C0723D", "#D9925F") })
        {
            var color = Hex(IsDark ? dark : light);
            var column = new Grid { Width = 30, VerticalAlignment = VerticalAlignment.Bottom };
            column.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
            column.RowDefinitions.Add(new RowDefinition { Height = new GridLength(height) });
            var badge = new Border
            {
                Width = 20, Height = 20, CornerRadius = new CornerRadius(10), Background = new SolidColorBrush(color), Margin = new Thickness(0, 0, 0, 4),
                Child = new TextBlock { Text = $"{rank}", FontSize = 11, FontWeight = FontWeights.Bold, Foreground = new SolidColorBrush(Color.FromArgb(255, 0x1B, 0x1A, 0x19)), HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center },
            };
            var block = new Border { CornerRadius = new CornerRadius(6, 6, 3, 3), Background = new SolidColorBrush(WithAlpha(color, 0x99)) };
            Grid.SetRow(block, 1);
            column.Children.Add(badge);
            column.Children.Add(block);
            MiniPodium.Children.Add(column);
        }
    }

    private async Task LoadPreview()
    {
        // Reading the logs can take a minute on a PC with gigabytes of
        // sessions: until it answers, the providers are listed, counting.
        if (JoinProviders.Children.Count == 0)
        {
            foreach (var provider in _providers) JoinProviders.Children.Add(ProviderRow(provider.Id, provider.Name, "Counting tokens…", 0));
        }
        await ReadPreview();
        JoinProviders.Children.Clear();
        foreach (var provider in _preview?["providers"]?.AsArray() ?? new JsonArray())
        {
            var tokens = provider!["tokens"]!.GetValue<long>();
            var days = provider["days"]!.GetValue<int>();
            JoinProviders.Children.Add(ProviderRow(provider["id"]!.GetValue<string>(), provider["name"]!.GetValue<string>(),
                tokens > 0 ? $"{Tokens(tokens)} · {Count(days, "day")}" : "No tokens on this PC", tokens));
        }
        UpdateJoin();
    }

    /// A provider to share, ticked and offered only when it has tokens.
    private Border ProviderRow(string id, string providerName, string amountText, long tokens)
    {
        var line = new Grid { ColumnSpacing = 10 };
        line.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        line.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        line.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        line.Children.Add(new Ellipse { Width = 8, Height = 8, Fill = Brush(ColorOf(id)), VerticalAlignment = VerticalAlignment.Center });
        var name = new TextBlock { Text = providerName };
        Grid.SetColumn(name, 1);
        line.Children.Add(name);
        var amount = new TextBlock { Text = amountText, FontSize = 12, Foreground = Resource("TextFillColorSecondaryBrush"), VerticalAlignment = VerticalAlignment.Center };
        Grid.SetColumn(amount, 2);
        line.Children.Add(amount);
        var box = new CheckBox
        {
            Content = line, IsChecked = tokens > 0, IsEnabled = tokens > 0, Tag = id,
            HorizontalAlignment = HorizontalAlignment.Stretch, HorizontalContentAlignment = HorizontalAlignment.Stretch, MinWidth = 0,
        };
        AutomationProperties.SetName(box, $"Share {providerName}");
        box.Checked += (_, _) => UpdateJoin();
        box.Unchecked += (_, _) => UpdateJoin();
        return new Border { Style = (Style)Root.Resources["Card"], CornerRadius = new CornerRadius(6), Padding = new Thickness(12, 4, 12, 4), Child = box };
    }

    private IEnumerable<string> TickedProviders() =>
        JoinProviders.Children.OfType<Border>().Select(border => border.Child).OfType<CheckBox>().Where(box => box.IsChecked == true).Select(box => (string)box.Tag);

    private void OnJoinInputChanged(object sender, TextChangedEventArgs e) => UpdateJoin();

    /// Join is offered for a name the server would take and at least one
    /// provider; the payload shows exactly today's rows for what's ticked.
    /// Adding this PC, it is offered once the code is approved, as that member.
    private void UpdateJoin()
    {
        var ticked = TickedProviders().ToHashSet();
        if (_addingDevice)
        {
            JoinButton.Content = _deviceMember is { } member ? $"Join as @{member}" : "Join once the code is approved";
            JoinButton.IsEnabled = !_joining && _deviceMember is not null && ticked.Count > 0;
            PayloadText.Text = Payload(_deviceMember ?? "you", ticked);
            return;
        }
        var name = UsernameBox.Text.Trim();
        var valid = UsernameRule.IsMatch(name);
        UsernameOk.Visibility = valid ? Visibility.Visible : Visibility.Collapsed;
        JoinButton.Content = "Join leaderboard";
        JoinButton.IsEnabled = !_joining && valid && ticked.Count > 0;
        PayloadText.Text = Payload(valid ? name : "you", ticked);
    }

    private string Payload(string name, HashSet<string> ticked)
    {
        var today = _preview?["today"]?.GetValue<string>() ?? DateTime.Now.ToString("yyyy-MM-dd", CultureInfo.InvariantCulture);
        var rows = (_preview?["rows"]?.AsArray() ?? new JsonArray()).Where(row => ticked.Contains(row!["provider"]!.GetValue<string>())).ToList();
        var text = new StringBuilder($"PUT /usage   signed as @{name}\n{{ \"today\": \"{today}\",\n  \"days\": [");
        if (rows.Count == 0) text.Append(" ]");
        foreach (var (row, index) in rows.Select((row, index) => (row!, index)))
        {
            text.Append(index == 0 ? "\n" : ",\n");
            text.Append($"    {{ \"provider\": \"{row["provider"]}\",\n");
            text.Append($"      \"day\": \"{row["day"]}\",\n");
            text.Append($"      \"input\": {row["input"]},\n");
            text.Append($"      \"output\": {row["output"]},\n");
            text.Append($"      \"cacheWrite\": {row["cacheWrite"]},\n");
            text.Append($"      \"cacheRead\": {row["cacheRead"]}");
            if (row["unsplit"]?.GetValue<long>() is > 0) text.Append($",\n      \"unsplit\": {row["unsplit"]}");
            text.Append(" }");
        }
        if (rows.Count > 0) text.Append(" ]");
        text.Append(" }");
        return text.ToString();
    }

    private void OnUsernameKeyDown(object sender, KeyRoutedEventArgs e)
    {
        if (e.Key != Windows.System.VirtualKey.Enter || !JoinButton.IsEnabled) return;
        e.Handled = true;
        OnJoin(sender, e);
    }

    private async void OnJoin(object sender, RoutedEventArgs e)
    {
        var sharing = TickedProviders().ToList();
        var member = _addingDevice ? _deviceMember : null;
        if (_addingDevice && member is null) return;
        _joining = true;
        UpdateJoin();
        SetDeviceActions(false);
        JoinBusy.IsActive = true;
        await Guarded(async () =>
        {
            var name = member ?? UsernameBox.Text.Trim();
            var reply = member is null ? await Swift.Join(name, sharing) : await Swift.JoinDevice(sharing);
            if (reply["error"] is null)
            {
                if (member is not null) ForgetDeviceRequest();
                if (!await Uploads.ScheduleAsync()) Tell("Joined, but the hourly upload couldn't be set up.", InfoBarSeverity.Warning);
                else if (member is not null)
                {
                    Tell($"This PC is one of @{name}'s devices now and uploads every hour while you're signed in. For its first week it can't rename, hide or leave the membership; your other computer can.",
                         InfoBarSeverity.Success);
                    App.Notify("This PC is on the leaderboard", $"@{name} · this PC uploads every hour while you're signed in.");
                }
                else
                {
                    Tell("You're on the leaderboard. This PC uploads every hour while you're signed in.", InfoBarSeverity.Success);
                    App.Notify("You're on the leaderboard", $"@{name} · this PC uploads every hour while you're signed in.");
                }
            }
            Show(reply);
        });
        _joining = false;
        JoinBusy.IsActive = false;
        SetDeviceActions(true);
        UpdateJoin();
    }

    // MARK: - Adding this PC to a member (ClaudeBar design §2a)

    /// *Add this PC* or *Get a new code*: shows a code to type on a computer
    /// already on the leaderboard, and waits until it's approved there.
    private async void OnAddThisPc(object sender, RoutedEventArgs e)
    {
        var ask = ++_deviceAsk;
        _addingDevice = true;
        _deviceMember = null;
        ShowDevicePanel();
        DeviceCodeText.Text = "";
        DeviceStatus.Text = "Asking for a code…";
        DeviceBusy.IsActive = true;
        DeclineDeviceButton.Visibility = Visibility.Collapsed;
        NewCodeButton.Visibility = Visibility.Collapsed;
        UpdateJoin();
        await Guarded(async () =>
        {
            var reply = await Swift.RequestDevice();
            if (ask != _deviceAsk) return;
            if (reply["code"]?.GetValue<string>() is not { } code)
            {
                DeviceStatus.Text = reply["error"]?.GetValue<string>()
                    ?? (reply["cancelled"] is not null ? "That code was cancelled. Ask for a new one." : "The leaderboard didn't give a code.");
                NewCodeButton.Visibility = Visibility.Visible;
                return;
            }
            DeviceCodeText.Text = code;
            DeviceStatus.Text = "Waiting for it to be approved…";
            var answer = await Swift.WaitDevice();
            if (ask != _deviceAsk || answer["cancelled"] is not null) return;
            if (answer["member"]?.GetValue<string>() is { } member)
            {
                _deviceMember = member;
                DeviceStatus.Text = $"Approved for @{member}. If that's you, choose what this PC shares and join. If it isn't, this PC removes itself.";
                DeclineDeviceButton.Visibility = Visibility.Visible;
            }
            else
            {
                DeviceStatus.Text = answer["error"]?.GetValue<string>() ?? "The code stopped working. Ask for a new one.";
                NewCodeButton.Visibility = Visibility.Visible;
            }
            UpdateJoin();
        });
        if (ask == _deviceAsk) DeviceBusy.IsActive = false;
    }

    /// *That's not me*: this PC removes itself from the member it was approved
    /// for. Joining waits meanwhile, as this waits while joining.
    private async void OnDeclineDevice(object sender, RoutedEventArgs e)
    {
        _joining = true;
        UpdateJoin();
        SetDeviceActions(false);
        await Guarded(async () =>
        {
            var reply = await Swift.DeclineDevice();
            if (reply["error"] is JsonNode error)
            {
                Tell(error.GetValue<string>(), InfoBarSeverity.Error);
                return;
            }
            ForgetDeviceRequest();
            Tell("This PC removed itself from that membership and kept nothing.", InfoBarSeverity.Success);
        });
        _joining = false;
        SetDeviceActions(true);
        UpdateJoin();
    }

    /// The device panel's buttons, off while a join or a decline is under way,
    /// so the other can't start against a request that one is ending.
    private void SetDeviceActions(bool enabled)
    {
        DeclineDeviceButton.IsEnabled = enabled;
        CancelDeviceButton.IsEnabled = enabled;
        NewCodeButton.IsEnabled = enabled;
    }

    /// *Cancel*: stops waiting and forgets the code, back to joining.
    private async void OnCancelDevice(object sender, RoutedEventArgs e)
    {
        ForgetDeviceRequest();
        await Guarded(async () => await Swift.CancelDevice());
    }

    private void ForgetDeviceRequest()
    {
        _deviceAsk++;
        _addingDevice = false;
        _deviceMember = null;
        DeviceBusy.IsActive = false;
        ShowDevicePanel();
        UpdateJoin();
    }

    private void ShowDevicePanel()
    {
        DevicePanel.Visibility = _addingDevice ? Visibility.Visible : Visibility.Collapsed;
        NewMemberFields.Visibility = _addingDevice ? Visibility.Collapsed : Visibility.Visible;
        AddThisPcLink.Visibility = _addingDevice ? Visibility.Collapsed : Visibility.Visible;
    }

    // MARK: - Helpers

    private bool IsDark => Root.ActualTheme == ElementTheme.Dark;

    private string NameOf(string id) => _providers.FirstOrDefault(p => p.Id == id)?.Name ?? id;

    private Color ColorOf(string id) => _providers.FirstOrDefault(p => p.Id == id) is { } provider ? Hex(IsDark ? provider.Dark : provider.Light) : Color.FromArgb(255, 0x8A, 0x8A, 0x8A);

    private Color Medal(string dark, string light) => Hex(IsDark ? dark : light);

    private static Dictionary<string, long> Mix(JsonNode? node) =>
        (node as JsonObject)?.ToDictionary(pair => pair.Key, pair => pair.Value?.GetValue<long>() ?? 0) ?? new Dictionary<string, long>();

    /// Each provider's share of a mix in whole percent, largest first.
    private static IEnumerable<(string Id, int Share)> Shares(Dictionary<string, long> mix)
    {
        var total = mix.Values.Sum();
        return total <= 0 ? Enumerable.Empty<(string, int)>()
            : mix.Where(pair => pair.Value > 0).OrderByDescending(pair => pair.Value).Select(pair => (pair.Key, (int)Math.Max(1, Math.Round(100.0 * pair.Value / total))));
    }

    /// A bar split by provider, in each provider's colour, in the providers' order.
    private void FillMix(Grid bar, Dictionary<string, long> mix)
    {
        bar.Children.Clear();
        bar.ColumnDefinitions.Clear();
        var parts = _providers.Where(p => mix.GetValueOrDefault(p.Id) > 0).Select(p => (p.Id, mix[p.Id])).ToList();
        if (parts.Count == 0) parts.Add(("", 1));
        for (var index = 0; index < parts.Count; index++)
        {
            bar.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(parts[index].Item2, GridUnitType.Star) });
            var fill = parts[index].Item1 == "" ? Resource("ControlStrongFillColorDisabledBrush") : Brush(ColorOf(parts[index].Item1));
            var segment = new Rectangle { Fill = fill, RadiusX = 1.5, RadiusY = 1.5 };
            Grid.SetColumn(segment, index);
            bar.Children.Add(segment);
        }
    }

    private static readonly string[] AvatarColors = { "#C9B7F5", "#FFD99A", "#A8E6CF", "#9FD3FF", "#FFC4B8", "#FFE08A", "#B5E3B0", "#D6C8FF", "#FFD1E8" };

    /// A colour from the name, the same on every read; no picture is uploaded.
    private static Color AvatarColor(string name)
    {
        var hash = 0;
        foreach (var character in name) hash = (hash * 31 + char.ToLowerInvariant(character)) & 0x7FFFFFFF;
        return Hex(AvatarColors[hash % AvatarColors.Length]);
    }

    private static Grid Avatar(string name, double size)
    {
        var avatar = new Grid { Width = size, Height = size, VerticalAlignment = VerticalAlignment.Center };
        avatar.Children.Add(new Ellipse { Fill = new SolidColorBrush(AvatarColor(name)) });
        avatar.Children.Add(new TextBlock
        {
            Text = name.Length > 0 ? name[..1].ToUpperInvariant() : "?", FontSize = size * 0.42, FontWeight = FontWeights.SemiBold,
            Foreground = new SolidColorBrush(Color.FromArgb(255, 0x1B, 0x1A, 0x19)), HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center,
        });
        return avatar;
    }

    /// How far to the place above, or how far ahead of the one below, as the Mac says it.
    private static string? Gap(int rank, long total, List<Member> members)
    {
        if (rank > 1)
        {
            var above = members.FirstOrDefault(member => member.Rank == rank - 1 && !member.IsYou);
            return above is null || above.Total < total ? null : $"{Tokens(above.Total - total)} behind #{above.Rank}";
        }
        var next = members.FirstOrDefault(member => member.Rank == 2 && !member.IsYou);
        return next is null || next.Total > total ? "Top of the board" : $"{Tokens(total - next.Total)} ahead of #2";
    }

    private Brush Resource(string key) =>
        Root.Resources.TryGetValue(key, out var local) && local is Brush own ? own
        : Application.Current.Resources.TryGetValue(key, out var shared) && shared is Brush brush ? brush
        : new SolidColorBrush(Colors.Gray);

    private Color AccentColor() =>
        Application.Current.Resources.TryGetValue("SystemAccentColor", out var accent) && accent is Color color ? color : Color.FromArgb(255, 0x00, 0x5F, 0xB8);

    private static SolidColorBrush Brush(Color color) => new(color);

    private static Color WithAlpha(Color color, byte alpha) => Color.FromArgb(alpha, color.R, color.G, color.B);

    private static Color Hex(string hex)
    {
        var value = Convert.ToUInt32(hex.TrimStart('#'), 16);
        return Color.FromArgb(255, (byte)(value >> 16), (byte)(value >> 8), (byte)value);
    }

    /// Shows `message` above the page. A success closes itself after a few
    /// seconds, unless something else was said since; warnings and errors stay
    /// until closed.
    private async void Tell(string message, InfoBarSeverity severity)
    {
        Notice.Message = message;
        Notice.Severity = severity;
        Notice.IsOpen = true;
        if (severity != InfoBarSeverity.Success) return;
        await Task.Delay(TimeSpan.FromSeconds(4));
        if (Notice.Message == message && Notice.Severity == severity) Notice.IsOpen = false;
    }

    /// Runs `work`, showing what went wrong instead of losing it in an async
    /// void handler; answers whether it ran without throwing.
    private async Task<bool> Guarded(Func<Task> work)
    {
        try
        {
            await work();
            return true;
        }
        catch (Exception error)
        {
            Tell(error.Message, InfoBarSeverity.Error);
            return false;
        }
    }

    private static string PeriodName(string period) => period switch
    {
        "today" => "Today",
        "30d" => "30 days",
        _ => "7 days",
    };

    /// Your place's board, as the HUD's footer says it: `#18 this week`.
    private static string PlacePhrase(string period) => period switch
    {
        "today" => "today",
        "30d" => "in 30 days",
        _ => "this week",
    };

    private static string PeriodPhrase(string period) => period switch
    {
        "today" => "today",
        "30d" => "last 30 days",
        _ => "last 7 days",
    };

    private static string Count(long count, string noun) => count == 1 ? $"1 {noun}" : $"{count} {noun}s";

    /// When something happened, in the app's own words rather than the system's
    /// date format, so every line reads in one language.
    private static string Ago(DateTimeOffset at)
    {
        var since = DateTimeOffset.Now - at;
        if (since < TimeSpan.FromMinutes(1)) return "just now";
        if (since < TimeSpan.FromHours(1)) return $"{(long)since.TotalMinutes} min ago";
        if (since < TimeSpan.FromDays(1)) return $"{Count((long)since.TotalHours, "hour")} ago";
        return since < TimeSpan.FromDays(2) ? "yesterday" : $"{Count((long)since.TotalDays, "day")} ago";
    }

    internal static string Tokens(long count) => count switch
    {
        >= 1_000_000_000 => $"{(count / 1e9).ToString("0.#", CultureInfo.InvariantCulture)}B",
        >= 1_000_000 => $"{(count / 1e6).ToString("0.#", CultureInfo.InvariantCulture)}M",
        >= 1_000 => $"{(count / 1e3).ToString("0.#", CultureInfo.InvariantCulture)}K",
        _ => count.ToString(CultureInfo.InvariantCulture),
    };
}
