using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Windows.Foundation;

namespace ClaudeBar;

/// Settings → Tools in WSL (docs/plans/2026-11-03-wsl-design.md): each
/// distro `wsl.exe` lists, whether it runs, its switch, and from its last
/// reading the tools and where, the sources left out, and what to know; and
/// the Leaderboard notice, said once (The person is told once).
public sealed partial class MainWindow
{
    /// The notice's copy at the top of Tools in WSL, while it's drawn.
    private InfoBar? _wslBoardNote;

    /// Draws the group from the HUD's last reply and app.json, as `ShowLimits` draws the Limits page.
    private void ShowWsl()
    {
        _showing = true;
        try
        {
            WslList.Children.Clear();
            var wsl = _hud.Wsl;
            var notice = WslSettings.Board(wsl, _state);
            ShowWslBoardBar(notice);
            _wslBoardNote = WslSettings.BoardNoteShows(notice, Preferences.WslBoardNotice) ? WslBoardNote(notice!) : null;
            if (_wslBoardNote is not null) WslList.Children.Add(_wslBoardNote);
            if (WslSettings.Empty(wsl) is { } empty)
            {
                WslList.Children.Add(WslCard(new TextBlock { Text = empty, VerticalAlignment = VerticalAlignment.Center }, null));
                return;
            }
            var names = _providers.DistinctBy(provider => provider.Id).ToDictionary(provider => provider.Id, provider => provider.Name);
            foreach (var row in WslSettings.Rows(wsl, Preferences.Wsl, names)) WslList.Children.Add(WslDistro(row));
        }
        finally
        {
            _showing = false;
            MarkWslBoardShown();
        }
    }

    /// The bar opens once; it stays open this run until closed, seen, or there's nothing to tell.
    private void ShowWslBoardBar(WslSettings.BoardNotice? notice)
    {
        if (notice is null || Preferences.WslBoardNotice == "seen")
        {
            WslBoardBar.IsOpen = false;
            return;
        }
        if (!WslBoardBar.IsOpen && !WslSettings.BoardBarOpens(notice, Preferences.WslBoardNotice)) return;
        WslBoardBar.Title = notice.Title;
        WslBoardBar.Message = notice.Message;
        WslBoardBar.IsOpen = true;
    }

    /// The same words at the top of Tools in WSL, without the button.
    private InfoBar WslBoardNote(WslSettings.BoardNotice notice)
    {
        var note = new InfoBar
        {
            Title = notice.Title, Message = notice.Message, Severity = InfoBarSeverity.Informational,
            IsOpen = true, IsClosable = true, Margin = new Thickness(0, 0, 0, 2),
        };
        note.Closed += (_, args) =>
        {
            if (args.Reason == InfoBarCloseReason.CloseButton) SeenWslBoard();
        };
        return note;
    }

    /// `shown` once the window has been visible with the bar open.
    private void MarkWslBoardShown()
    {
        if (WslBoardBar.IsOpen && AppWindow.IsVisible) Preferences.WslBoardNotice ??= "shown";
    }

    /// Closing either copy, or changing a distro's switch while the notice is up: neither shows again.
    private void SeenWslBoard()
    {
        Preferences.WslBoardNotice = "seen";
        WslBoardBar.IsOpen = false;
        if (_wslBoardNote is not null) _wslBoardNote.IsOpen = false;
    }

    private void OnWslWindowChanged(AppWindow sender, AppWindowChangedEventArgs args)
    {
        if (args.DidVisibilityChange) MarkWslBoardShown();
    }

    private void OnWslBoardBarClosed(InfoBar sender, InfoBarClosedEventArgs args)
    {
        if (args.Reason == InfoBarCloseReason.CloseButton) SeenWslBoard();
    }

    /// *Tools in WSL*: Settings, scrolled to the group with its title.
    private void OnWslBoardOpen(object sender, RoutedEventArgs e)
    {
        Navigate("settings");
        DispatcherQueue.TryEnqueue(Microsoft.UI.Dispatching.DispatcherQueuePriority.Low, () =>
            WslList.StartBringIntoView(new BringIntoViewOptions
            {
                VerticalAlignmentRatio = 0,
                TargetRect = new Rect(0, -GroupTitleSpace, WslList.ActualWidth, GroupTitleSpace + WslList.ActualHeight),
            }));
    }

    /// Room above the list for the group's title, "Tools in WSL", when it's brought into view.
    private const double GroupTitleSpace = 40;

    /// One distro: its name and whether it runs, its switch, then a line for
    /// each source and note, and why its last run failed.
    private Border WslDistro(WslSettings.Row row)
    {
        var title = new StackPanel { VerticalAlignment = VerticalAlignment.Center };
        title.Children.Add(new TextBlock { Text = row.Name });
        title.Children.Add(new TextBlock { Text = row.Running ? "Running" : "Not running", Style = (Style)Root.Resources["Secondary"] });
        var toggle = new ToggleSwitch { IsOn = row.On, Tag = row.Name, OnContent = "On", OffContent = "Off", MinWidth = 0, VerticalAlignment = VerticalAlignment.Center };
        AutomationProperties.SetName(toggle, $"Read tools in {row.Name}");
        toggle.Toggled += OnWslToggled;
        var lines = new StackPanel { Spacing = 2 };
        foreach (var source in row.Sources)
            lines.Children.Add(new TextBlock { Text = $"{source.Tool} · {source.Where}" + (source.Note is { } note ? $" ({note})" : ""), Style = (Style)Root.Resources["Secondary"] });
        foreach (var note in row.Notes) lines.Children.Add(new TextBlock { Text = note, Style = (Style)Root.Resources["Secondary"] });
        if (row.Error is { } error)
        {
            var failed = new TextBlock { Text = error, Style = (Style)Root.Resources["Secondary"] };
            failed.Foreground = Resource("SystemFillColorCriticalBrush");
            lines.Children.Add(failed);
        }
        return WslCard(title, toggle, lines.Children.Count > 0 ? lines : null);
    }

    /// A settings card: the Linux icon, the text, and the switch, if any; the lines below them.
    private Border WslCard(FrameworkElement text, ToggleSwitch? toggle, FrameworkElement? below = null)
    {
        var grid = new Grid { Padding = new Thickness(16, 10, 16, 10), ColumnSpacing = 14, RowSpacing = 6, MinHeight = 64 };
        foreach (var width in new[] { GridLength.Auto, new GridLength(1, GridUnitType.Star), GridLength.Auto })
            grid.ColumnDefinitions.Add(new ColumnDefinition { Width = width });
        grid.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        grid.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        grid.Children.Add(new FontIcon { Glyph = "\uE756", FontSize = 18, VerticalAlignment = VerticalAlignment.Center });
        Grid.SetColumn(text, 1);
        grid.Children.Add(text);
        if (toggle is not null)
        {
            Grid.SetColumn(toggle, 2);
            grid.Children.Add(toggle);
        }
        if (below is not null)
        {
            Grid.SetRow(below, 1);
            Grid.SetColumn(below, 1);
            Grid.SetColumnSpan(below, 2);
            grid.Children.Add(below);
        }
        return new Border { Style = (Style)Root.Resources["Card"], Child = grid };
    }

    /// A distro's switch: kept in app.json, handed to Swift, then the HUD read again with it.
    private async void OnWslToggled(object sender, RoutedEventArgs e)
    {
        if (_showing || sender is not ToggleSwitch { Tag: string distro } toggle) return;
        if (WslSettings.BoardNoteShows(WslSettings.Board(_hud.Wsl, _state), Preferences.WslBoardNotice)) SeenWslBoard();
        toggle.IsEnabled = false;
        Preferences.Wsl = WslSettings.WithOn(Preferences.Wsl, distro, toggle.IsOn);
        await Guarded(() => Swift.WslConfigure(Preferences.Wsl));
        toggle.IsEnabled = true;
        _ = _hud.Read(refresh: false);
    }
}
