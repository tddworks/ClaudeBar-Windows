using System.Globalization;
using System.Runtime.InteropServices;
using System.Text.Json.Nodes;
using System.Text.RegularExpressions;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Text;
using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using Windows.Graphics;

namespace ClaudeBar;

public sealed partial class MainWindow : Window
{
    /// The server's username rule (`Username` in ClaudeBar's package), so Join
    /// is offered only for a name it would take.
    private static readonly Regex UsernameRule = new("^[A-Za-z0-9_-]{3,20}$");

    private readonly DispatcherQueueTimer _pump;
    private string _period = "7d";
    private bool _shown;
    private bool _joining;
    /// True while the window sets its own switches, so their events don't call back.
    private bool _showing;
    /// Counts board reads, so an answer for a period no longer picked is dropped.
    private int _boardRead;

    public MainWindow()
    {
        InitializeComponent();
        Place();
        // Swift's main actor runs on this UI thread only when it drains Swift's main queue.
        _pump = DispatcherQueue.CreateTimer();
        _pump.Interval = TimeSpan.FromMilliseconds(16);
        _pump.Tick += (_, _) => Native.cbw_drain_main_queue();
        _pump.Start();
        Activated += OnActivated;
    }

    /// 480 × 760 effective pixels, centred, never taller than the work area:
    /// `AppWindow` sizes in physical pixels, so the display's scale is applied here.
    private void Place()
    {
        var scale = GetDpiForWindow(WinRT.Interop.WindowNative.GetWindowHandle(this)) / 96.0;
        var work = DisplayArea.GetFromWindowId(AppWindow.Id, DisplayAreaFallback.Primary).WorkArea;
        var width = Math.Min((int)(480 * scale), work.Width);
        var height = Math.Min((int)(760 * scale), work.Height);
        AppWindow.MoveAndResize(new RectInt32(work.X + (work.Width - width) / 2, work.Y + (work.Height - height) / 2, width, height));
    }

    [LibraryImport("user32.dll")]
    private static partial uint GetDpiForWindow(nint window);

    private async void OnActivated(object sender, WindowActivatedEventArgs e)
    {
        if (_shown) return;
        _shown = true;
        await Guarded(async () => Show(await Swift.State()));
    }

    // MARK: - Showing

    private void Show(JsonObject reply)
    {
        if (reply["error"] is JsonNode error) Tell(error.GetValue<string>(), InfoBarSeverity.Error);
        if (reply["state"] is not JsonObject state) return;
        var joined = state["joined"]?.GetValue<bool>() == true;
        Caption.Text = $"{state["label"]} · ClaudeBar for Windows {state["version"]}";
        JoinPanel.Visibility = joined ? Visibility.Collapsed : Visibility.Visible;
        MemberNav.Visibility = joined ? Visibility.Visible : Visibility.Collapsed;
        if (joined)
        {
            ShowMember(state);
            if (!Uploads.IsScheduled && !Uploads.Schedule())
                Tell("The hourly upload couldn't be set up. Use Upload now until it is.", InfoBarSeverity.Warning);
            MemberNav.SelectedItem ??= BoardItem;
            _ = LoadBoard(keepList: Standings.Children.Count > 0);
        }
        else
        {
            Uploads.Unschedule();
            Standings.Children.Clear();
            MemberNav.SelectedItem = null;
            _ = Guarded(LoadPreview);
        }
    }

    private void ShowMember(JsonObject state)
    {
        _showing = true;
        try
        {
            MemberName.Text = $"@{state["username"]}";
            var uploaded = state["lastUpload"] is JsonNode at
                ? $"Uploaded {Ago(DateTimeOffset.Parse(at.GetValue<string>(), CultureInfo.InvariantCulture))}"
                : "Not uploaded yet";
            var refused = state["refused"]?.GetValue<int>() ?? 0;
            UploadText.Text = $"{uploaded} · hourly"
                + (refused > 0 ? $" · {Count(refused, "day")} refused, sent again with each upload" : "");
            VisibleSwitch.IsOn = state["visible"]?.GetValue<bool>() == true;
            MemberProviders.Children.Clear();
            foreach (var provider in Providers(state)) MemberProviders.Children.Add(ProviderRow(provider));
        }
        finally { _showing = false; }
    }

    /// A provider and its switch on one line, the switch named for screen readers.
    private Grid ProviderRow((string Id, string Name, bool Shared) provider)
    {
        var row = new Grid { MinHeight = 40 };
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        var name = new TextBlock { Text = provider.Name, VerticalAlignment = VerticalAlignment.Center };
        var toggle = new ToggleSwitch
        {
            IsOn = provider.Shared, Tag = provider.Id, OnContent = null, OffContent = null, MinWidth = 0,
            VerticalAlignment = VerticalAlignment.Center,
        };
        AutomationProperties.SetName(toggle, $"Share {provider.Name}");
        toggle.Toggled += OnSharingToggled;
        Grid.SetColumn(toggle, 1);
        row.Children.Add(name);
        row.Children.Add(toggle);
        return row;
    }

    private async Task LoadPreview()
    {
        var reply = await Swift.Preview();
        JoinProviders.Children.Clear();
        foreach (var provider in reply["providers"]?.AsArray() ?? new JsonArray())
        {
            var tokens = provider!["tokens"]!.GetValue<long>();
            var days = provider["days"]!.GetValue<int>();
            var box = new CheckBox
            {
                Content = $"{provider["name"]} · " + (tokens > 0 ? $"{Tokens(tokens)} tokens on {Count(days, "day")}" : "no tokens yet"),
                IsChecked = tokens > 0,
                Tag = provider["id"]!.GetValue<string>(),
            };
            box.Checked += (_, _) => UpdateJoinButton();
            box.Unchecked += (_, _) => UpdateJoinButton();
            JoinProviders.Children.Add(box);
        }
        UpdateJoinButton();
    }

    /// Reads the board for the picked period. A new period starts from an empty
    /// list that says it is loading; a refresh keeps the list until the answer.
    private async Task LoadBoard(bool keepList)
    {
        var read = ++_boardRead;
        var period = _period;
        RankCaption.Text = $"YOUR RANK · {PeriodName(period).ToUpperInvariant()}";
        RefreshButton.IsEnabled = false;
        if (!keepList)
        {
            Standings.Children.Clear();
            RankText.Text = "–";
            TokensText.Text = "Loading…";
            GapText.Text = "";
            BoardNote.Visibility = Visibility.Collapsed;
            ShowBoardStatus("Loading the board…", busy: true);
        }

        JsonObject reply;
        try { reply = await Swift.Board(period, ""); }
        catch (Exception failure) { reply = new JsonObject { ["error"] = failure.Message }; }
        if (read != _boardRead) return;
        RefreshButton.IsEnabled = true;

        if (reply["error"] is JsonNode error)
        {
            if (Standings.Children.Count == 0)
            {
                TokensText.Text = "–";
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
        var members = (reply["members"]?.AsArray() ?? new JsonArray())
            .Select(member => (Rank: member!["rank"]!.GetValue<int>(), Name: member["username"]!.GetValue<string>(),
                               Total: member["total"]!.GetValue<long>(), IsYou: member["you"]?.GetValue<bool>() == true))
            .ToList();
        Standings.Children.Clear();
        foreach (var member in members) Standings.Children.Add(Row(member.Rank, member.Name, member.Total, member.IsYou));
        if (members.Count == 0) ShowBoardStatus("No one is on this board yet.", busy: false);
        else BoardStatus.Visibility = Visibility.Collapsed;

        var hidden = reply["state"]?["visible"]?.GetValue<bool>() == false;
        if (reply["you"] is JsonObject you)
        {
            var rank = you["rank"]!.GetValue<int>();
            var total = you["total"]!.GetValue<long>();
            RankText.Text = $"#{rank}";
            TokensText.Text = $"{Tokens(total)} tokens";
            var lines = new List<string>();
            if (Gap(rank, total, members) is string gap) lines.Add(gap);
            // A hidden member is still ranked for themselves (design §4), just
            // absent from the list everyone reads.
            if (hidden) lines.Add("Hidden: only you see this place.");
            GapText.Text = string.Join("\n", lines);
        }
        else
        {
            RankText.Text = "–";
            TokensText.Text = "Nothing uploaded for this board yet.";
            GapText.Text = "";
        }
    }

    /// How far to the place above, or how far ahead of the one below, as the Mac says it.
    private static string? Gap(int rank, long total, List<(int Rank, string Name, long Total, bool IsYou)> members)
    {
        if (rank > 1)
        {
            var above = members.FirstOrDefault(member => member.Rank == rank - 1 && !member.IsYou);
            return above.Name is null || above.Total < total ? null : $"{Tokens(above.Total - total)} behind #{above.Rank}";
        }
        var next = members.FirstOrDefault(member => member.Rank == 2 && !member.IsYou);
        return next.Name is null || next.Total > total ? "Top of the board" : $"{Tokens(total - next.Total)} ahead of #2";
    }

    private void ShowBoardStatus(string text, bool busy)
    {
        BoardStatusText.Text = text;
        BoardBusy.IsActive = busy;
        BoardBusy.Visibility = busy ? Visibility.Visible : Visibility.Collapsed;
        BoardStatus.Visibility = Visibility.Visible;
    }

    /// One member of a board: rank, name and tokens, the person's own row set apart.
    private static Grid Row(int rank, string name, long total, bool isYou)
    {
        var weight = isYou ? FontWeights.SemiBold : FontWeights.Normal;
        var row = new Grid { ColumnSpacing = 12, Padding = new Thickness(8, 6, 8, 6), CornerRadius = new CornerRadius(4) };
        if (isYou && Application.Current.Resources.TryGetValue("SubtleFillColorSecondaryBrush", out var fill)) row.Background = fill as Brush;
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(40) });
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        var cells = new[]
        {
            new TextBlock { Text = $"#{rank}", FontWeight = weight, Opacity = 0.7 },
            new TextBlock { Text = name, FontWeight = weight, TextTrimming = TextTrimming.CharacterEllipsis },
            new TextBlock { Text = Tokens(total), FontWeight = weight, HorizontalAlignment = HorizontalAlignment.Right },
        };
        for (var column = 0; column < cells.Length; column++)
        {
            Grid.SetColumn(cells[column], column);
            row.Children.Add(cells[column]);
        }
        AutomationProperties.SetName(row, $"Rank {rank}, {name}, {Tokens(total)} tokens" + (isYou ? ", you" : ""));
        return row;
    }

    // MARK: - Acting

    private void OnJoinInputChanged(object sender, TextChangedEventArgs e) => UpdateJoinButton();

    private void UpdateJoinButton() =>
        JoinButton.IsEnabled = !_joining && UsernameRule.IsMatch(UsernameBox.Text.Trim())
                               && JoinProviders.Children.OfType<CheckBox>().Any(box => box.IsChecked == true);

    private void OnUsernameKeyDown(object sender, KeyRoutedEventArgs e)
    {
        if (e.Key != Windows.System.VirtualKey.Enter || !JoinButton.IsEnabled) return;
        e.Handled = true;
        OnJoin(sender, e);
    }

    private async void OnJoin(object sender, RoutedEventArgs e)
    {
        var sharing = JoinProviders.Children.OfType<CheckBox>().Where(box => box.IsChecked == true).Select(box => (string)box.Tag).ToList();
        _joining = true;
        UpdateJoinButton();
        JoinBusy.IsActive = true;
        await Guarded(async () =>
        {
            var reply = await Swift.Join(UsernameBox.Text.Trim(), sharing);
            if (reply["error"] is null)
            {
                Notice.IsOpen = false;
                if (!Uploads.Schedule()) Tell("Joined, but the hourly upload couldn't be set up.", InfoBarSeverity.Warning);
            }
            Show(reply);
        });
        _joining = false;
        JoinBusy.IsActive = false;
        UpdateJoinButton();
    }

    private void OnMemberNavChanged(NavigationView sender, NavigationViewSelectionChangedEventArgs e)
    {
        var membership = (e.SelectedItem as NavigationViewItem)?.Tag as string == "membership";
        BoardView.Visibility = membership ? Visibility.Collapsed : Visibility.Visible;
        MembershipView.Visibility = membership ? Visibility.Visible : Visibility.Collapsed;
    }

    private async void OnSharingToggled(object sender, RoutedEventArgs e)
    {
        if (_showing || sender is not ToggleSwitch toggle) return;
        toggle.IsEnabled = false;
        await Guarded(async () => Show(await Swift.SetSharing((string)toggle.Tag, toggle.IsOn)));
        toggle.IsEnabled = true;
    }

    private async void OnVisibleToggled(object sender, RoutedEventArgs e)
    {
        if (_showing) return;
        VisibleSwitch.IsEnabled = false;
        await Guarded(async () => Show(await Swift.SetVisible(VisibleSwitch.IsOn)));
        VisibleSwitch.IsEnabled = true;
    }

    private async void OnUploadNow(object sender, RoutedEventArgs e)
    {
        UploadButton.IsEnabled = false;
        UploadBusy.IsActive = true;
        await Guarded(async () =>
        {
            var reply = await Swift.UploadNow();
            if (reply["error"] is null) Tell("Uploaded.", InfoBarSeverity.Success);
            Show(reply);
        });
        UploadBusy.IsActive = false;
        UploadButton.IsEnabled = true;
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

    private async void OnPeriodChanged(SelectorBar sender, SelectorBarSelectionChangedEventArgs e)
    {
        if (sender.SelectedItem?.Tag is not string period) return;
        _period = period;
        if (MemberNav.Visibility == Visibility.Visible) await LoadBoard(keepList: false);
    }

    private async void OnRefresh(object sender, RoutedEventArgs e) => await Guarded(async () => Show(await Swift.State()));

    // MARK: - Helpers

    private static IEnumerable<(string Id, string Name, bool Shared)> Providers(JsonObject state) =>
        (state["providers"]?.AsArray() ?? new JsonArray()).Select(provider =>
            (provider!["id"]!.GetValue<string>(), provider["name"]!.GetValue<string>(), provider["shared"]!.GetValue<bool>()));

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

    /// Runs `work`, showing what went wrong instead of losing it in an async void handler.
    private async Task Guarded(Func<Task> work)
    {
        try { await work(); }
        catch (Exception error) { Tell(error.Message, InfoBarSeverity.Error); }
    }

    private static string PeriodName(string period) => period switch
    {
        "today" => "Today",
        "30d" => "30 days",
        _ => "7 days",
    };

    private static string Count(long count, string noun) => count == 1 ? $"1 {noun}" : $"{count} {noun}s";

    /// When something happened, in the app's own words rather than the system's
    /// date format, so every line reads in one language.
    private static string Ago(DateTimeOffset at)
    {
        var since = DateTimeOffset.Now - at;
        if (since < TimeSpan.FromMinutes(1)) return "just now";
        if (since < TimeSpan.FromHours(1)) return $"{Count((long)since.TotalMinutes, "minute")} ago";
        if (since < TimeSpan.FromDays(1)) return $"{Count((long)since.TotalHours, "hour")} ago";
        return since < TimeSpan.FromDays(2) ? "yesterday" : $"{Count((long)since.TotalDays, "day")} ago";
    }

    private static string Tokens(long count) => count switch
    {
        >= 1_000_000_000 => $"{(count / 1e9).ToString("0.#", CultureInfo.InvariantCulture)}B",
        >= 1_000_000 => $"{(count / 1e6).ToString("0.#", CultureInfo.InvariantCulture)}M",
        >= 1_000 => $"{(count / 1e3).ToString("0.#", CultureInfo.InvariantCulture)}K",
        _ => count.ToString(CultureInfo.InvariantCulture),
    };
}
