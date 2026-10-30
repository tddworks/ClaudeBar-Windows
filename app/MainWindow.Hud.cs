using System.Globalization;
using System.Text.Json.Nodes;
using Microsoft.UI.Input;
using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Shapes;
using Windows.System;
using Windows.UI.Core;

namespace ClaudeBar;

/// The window's side of the HUD (docs/plans/2026-10-13-hud-design.md): the
/// Limits page, which has every reading and action the HUD has for the
/// keyboard and Narrator; Usage; Settings → HUD and starting with Windows;
/// the taskbar dot; and the crossing notifications.
public sealed partial class MainWindow
{
    // MARK: - Limits

    /// Every limit by its full name, the share left, and the reset as a time
    /// and a clock time; a tool that needs you says so, with *Try again*.
    private void ShowLimits()
    {
        LimitsList.Children.Clear();
        var data = _hud.Data;
        LimitsSubtitle.Text = data is null ? (_hud.Error is { } error ? $"Couldn't read the limits. {error}" : "Reading limits…")
            : _hud.Offline ? $"Offline · as of {(data.ReadAt is { } read ? HudText.Clock(read, CultureInfo.CurrentCulture) : "–")}"
            : data.ReadAt is { } at ? $"Read {HudText.Ago(DateTimeOffset.Now - at)}" : "Reading limits…";
        if (data is null) return;
        if (data.IsEmpty)
        {
            var empty = new StackPanel { Spacing = 8 };
            empty.Children.Add(new TextBlock { Text = "No AI tools signed in here yet", Style = (Style)Application.Current.Resources["BodyStrongTextBlockStyle"] });
            empty.Children.Add(new TextBlock
            {
                Text = "ClaudeBar shows the limits of Claude Code, Codex, Gemini CLI and the other tools it knows, once one is signed in on this PC.",
                Style = (Style)Root.Resources["Secondary"],
            });
            var choose = new Button { Content = "Choose tools" };
            choose.Click += (_, _) => { Navigate("settings"); OnChooseTools(HudToolsButton, new RoutedEventArgs()); };
            empty.Children.Add(choose);
            LimitsList.Children.Add(new Border { Style = (Style)Root.Resources["Card"], Padding = new Thickness(16, 12, 16, 12), Child = empty });
            return;
        }
        // In the HUD's order: the tools with numbers, the ones without, then those with no share to draw.
        foreach (var tool in data.Tools.Where(tool => tool.Lines.Count > 0)) LimitsList.Children.Add(LimitsCard(data, tool.Id, tool, data.Stale(tool.Id)));
        foreach (var problem in data.Alone) LimitsList.Children.Add(LimitsCard(data, problem.Id, null, problem));
        foreach (var tool in data.Tools.Where(tool => tool.Lines.Count == 0 && data.Problems.All(problem => problem.Id != tool.Id)))
            LimitsList.Children.Add(LimitsCard(data, tool.Id, tool, null));
    }

    private Border LimitsCard(HudData data, string id, HudData.Tool? tool, HudData.Problem? problem)
    {
        var look = data.LookOf(id);
        var now = DateTimeOffset.Now;
        var culture = CultureInfo.CurrentCulture;
        var card = new StackPanel { Spacing = 10 };
        var header = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
        header.Children.Add(new Ellipse { Width = 10, Height = 10, Fill = Brush(Hex(IsDark ? look.Dark : look.Light)), VerticalAlignment = VerticalAlignment.Center });
        header.Children.Add(new TextBlock { Text = look.Name, FontWeight = FontWeights.SemiBold, VerticalAlignment = VerticalAlignment.Center });
        // Numbers that aren't live say since when.
        var since = tool is not null && (tool.ReadAt ?? data.ReadAt) is { } from ? $" · numbers from {HudText.Clock(from, culture)}" : "";
        var flag = problem?.Kind switch
        {
            "signedOut" => ("Signed out" + since, "TextFillColorSecondaryBrush"),
            "failed" => ("Couldn't read" + since, "TextFillColorSecondaryBrush"),
            "reading" => ("Reading…", "TextFillColorSecondaryBrush"),
            _ when tool?.OutUntil is { } back => ($"Out until {HudText.Clock(back, culture)}", "SystemFillColorCriticalBrush"),
            _ when tool?.RunningHot == true => ("Running hot", "SystemFillColorCautionBrush"),
            _ => ((string, string)?)null,
        };
        if (flag is ({ } words, { } brush))
            header.Children.Add(new TextBlock { Text = words, FontSize = 12, Foreground = Resource(brush), VerticalAlignment = VerticalAlignment.Center });
        card.Children.Add(header);
        foreach (var line in tool?.Lines ?? Array.Empty<HudData.Line>()) card.Children.Add(LimitsRow(look, line, now, culture, stale: problem is not null));
        if (tool is { Lines.Count: 0 } && problem is null)
            card.Children.Add(new TextBlock { Text = "No limit with a share left to show.", Style = (Style)Root.Resources["Secondary"] });
        if (problem is { Kind: "signedOut" or "failed" })
        {
            var note = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
            note.Children.Add(new TextBlock { Text = problem.Message, Style = (Style)Root.Resources["Secondary"], VerticalAlignment = VerticalAlignment.Center, MaxWidth = 420 });
            if (problem.Kind == "failed")
            {
                var retry = new Button { Content = "Try again" };
                AutomationProperties.SetName(retry, $"Try reading {look.Name} again");
                retry.Click += OnRefreshLimits;
                note.Children.Add(retry);
            }
            card.Children.Add(note);
        }
        return new Border { Style = (Style)Root.Resources["Card"], Padding = new Thickness(16, 12, 16, 12), Child = card };
    }

    /// One limit: its full name, a bar with the even-pace tick, the share left,
    /// and when it resets, as a time and a clock time.
    private Grid LimitsRow(HudData.Look look, HudData.Line line, DateTimeOffset now, CultureInfo culture, bool stale)
    {
        var row = new Grid { ColumnSpacing = 12 };
        foreach (var width in new[] { new GridLength(150), new GridLength(1, GridUnitType.Star), new GridLength(44), new GridLength(130) })
            row.ColumnDefinitions.Add(new ColumnDefinition { Width = width });
        var name = new TextBlock { Text = Capitalized(HudText.LimitName(line.Window, line.WindowSeconds)), TextTrimming = TextTrimming.CharacterEllipsis, VerticalAlignment = VerticalAlignment.Center };
        ToolTipService.SetToolTip(name, line.Window);
        var bar = new Grid { VerticalAlignment = VerticalAlignment.Center, Opacity = stale ? 0.45 : 1 };
        // A ProgressBar's paused and error states are WinUI's caution and critical colours.
        var progress = new ProgressBar
        {
            Value = Math.Clamp(line.PercentLeft, 0, 100), Maximum = 100, VerticalAlignment = VerticalAlignment.Center,
            ShowPaused = line.Status == "warning", ShowError = line.Status is "critical" or "depleted",
        };
        bar.Children.Add(progress);
        if (line.Tick is double tick && line.PercentLeft > 0)
        {
            var at = Math.Clamp(tick, 0, 100);
            bar.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(Math.Max(at, 0.001), GridUnitType.Star) });
            bar.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(Math.Max(100 - at, 0.001), GridUnitType.Star) });
            Grid.SetColumnSpan(progress, 2);
            var mark = new Rectangle { Width = 2, Height = 10, RadiusX = 1, RadiusY = 1, Fill = Resource("TextFillColorSecondaryBrush"), HorizontalAlignment = HorizontalAlignment.Left, Margin = new Thickness(-1, 0, 0, 0) };
            Grid.SetColumn(mark, 1);
            bar.Children.Add(mark);
        }
        var share = new TextBlock
        {
            Text = $"{Math.Max(0, line.PercentLeft)}%", FontWeight = FontWeights.SemiBold, HorizontalAlignment = HorizontalAlignment.Right, VerticalAlignment = VerticalAlignment.Center,
            Foreground = Resource(stale ? "TextFillColorSecondaryBrush" : "TextFillColorPrimaryBrush"),
        };
        var meta = new StackPanel { VerticalAlignment = VerticalAlignment.Center };
        if (line.ResetsAt is { } reset)
        {
            var first = line.PercentLeft <= 0 ? $"back {ClockDay(reset, now, culture)}"
                : line.RunsOutAt is { } runsOut ? $"Running hot · runs out {ClockDay(runsOut, now, culture)}"
                : (line.RunningHot ? "Running hot · resets in " : "resets in ") + HudText.Until(reset - now);
            meta.Children.Add(new TextBlock { Text = first, FontSize = 12, Foreground = Resource(line.RunningHot && line.PercentLeft > 0 ? "SystemFillColorCautionBrush" : "TextFillColorSecondaryBrush") });
            if (line.PercentLeft > 0) meta.Children.Add(new TextBlock { Text = ClockDay(reset, now, culture), FontSize = 12, Foreground = Resource("TextFillColorSecondaryBrush") });
        }
        var cells = new FrameworkElement[] { name, bar, share, meta };
        for (var column = 0; column < cells.Length; column++)
        {
            Grid.SetColumn(cells[column], column);
            row.Children.Add(cells[column]);
        }
        AutomationProperties.SetName(row, HudText.Sentence(look.Name, line, now, culture));
        return row;
    }

    /// A reset as a clock time: `at 16:19` today, `Thu 20:00` on another day.
    private static string ClockDay(DateTimeOffset at, DateTimeOffset now, CultureInfo culture) =>
        at.ToLocalTime().Date == now.ToLocalTime().Date ? $"at {HudText.Clock(at, culture)}"
        : $"{at.ToLocalTime().ToString("ddd", culture)} {HudText.Clock(at, culture)}";

    private static string Capitalized(string text) => text.Length == 0 ? text : char.ToUpperInvariant(text[0]) + text[1..];

    /// *Refresh* and *Try again*: reads every tool again.
    private async void OnRefreshLimits(object sender, RoutedEventArgs e)
    {
        LimitsRefresh.IsEnabled = false;
        LimitsBusy.IsActive = true;
        await _hud.Read(refresh: true);
        LimitsBusy.IsActive = false;
        LimitsRefresh.IsEnabled = true;
        ShowLimits();
    }

    /// A new reading, or the read failed: the page, the dot, and the offer to start with Windows.
    private void OnHudChanged()
    {
        ShowLimits();
        ShowHudSettings();
        var data = _hud.Data;
        if (data is null) return;
        var worst = data.Worst;
        var sentence = data.Tools.SelectMany(tool => tool.Lines.Select(line => (tool, line)))
            .Where(pair => pair.line.Status == worst)
            .Select(pair => HudText.Sentence(data.LookOf(pair.tool.Id).Name, pair.line, DateTimeOffset.Now, CultureInfo.CurrentCulture))
            .FirstOrDefault() ?? "";
        _taskbar.ShowWorst(worst, sentence);
        if (data.Tools.Count > 0 && !Preferences.StartupOffered && !Startup.IsEnabled) StartupBar.IsOpen = true;
    }

    // MARK: - Notifications

    /// A limit crossed 20%, reached 0, or came back: once, with *Show the HUD*
    /// and *Quiet until reset* (design, Taskbar and notifications).
    private void OnCrossed(HudData.Tool tool, HudData.Line line, Crossing crossing)
    {
        var name = $"{_hud.Data?.LookOf(tool.Id).Name ?? tool.Id}'s {HudText.LimitName(line.Window, line.WindowSeconds)}";
        var culture = CultureInfo.CurrentCulture;
        var now = DateTimeOffset.Now;
        var when = line.ResetsAt is { } reset ? ClockDay(reset, now, culture) : null;
        var (title, body) = crossing switch
        {
            Crossing.Low => ($"{name} is at {line.PercentLeft}%", when is null ? "Running low." : $"It resets {when}."),
            Crossing.Out => ($"{name} is used up", when is null ? "It comes back when it resets." : $"It's back {when}."),
            _ => ($"{name} is back", $"{line.PercentLeft}% left."),
        };
        var show = ("Show the HUD", "--hud");
        if (crossing == Crossing.Back) App.Notify(title, body, show);
        else App.Notify(title, body, show, ("Quiet until reset", $"--quiet={Uri.EscapeDataString(HudData.Key(tool, line))}"));
    }

    // MARK: - Usage

    /// Reads today's tokens again: one read at a time, shared by every page that wants it.
    private async Task ReadUsage()
    {
        try { await ReadPreview(); }
        catch (Exception) { /* Usage says it's counting; the next read tries again. */ }
    }

    private Task<JsonObject>? _previewRead;

    private async Task ReadPreview()
    {
        _previewRead ??= Swift.Preview();
        try { _preview = await _previewRead; }
        finally { _previewRead = null; }
        ShowPreview();
    }

    /// Today's tokens on the HUD's footer and on Usage.
    private void ShowPreview()
    {
        _hud.TodayTokens = _preview is null ? null : TodayTokens(null);
        _hud.Render();
        ShowUsage();
    }

    /// Today's tokens from the logs: one provider's, or every provider's.
    private long TodayTokens(string? provider) =>
        (_preview?["rows"]?.AsArray() ?? new JsonArray()).OfType<JsonObject>()
            .Where(row => provider is null || row["provider"]?.GetValue<string>() == provider)
            .Sum(row => new[] { "input", "output", "cacheWrite", "cacheRead", "unsplit" }.Sum(part => row[part]?.GetValue<long>() ?? 0));

    private void ShowUsage()
    {
        UsageList.Children.Clear();
        if (_preview is null)
        {
            UsageToday.Text = "Counting…";
            return;
        }
        UsageToday.Text = $"{Tokens(TodayTokens(null))} tokens";
        foreach (var provider in (_preview["providers"]?.AsArray() ?? new JsonArray()).OfType<JsonObject>())
        {
            var id = provider["id"]?.GetValue<string>() ?? "";
            var row = new Grid { ColumnSpacing = 10, Padding = new Thickness(12, 8, 12, 8) };
            foreach (var width in new[] { GridLength.Auto, new GridLength(1, GridUnitType.Star), GridLength.Auto, new GridLength(120) })
                row.ColumnDefinitions.Add(new ColumnDefinition { Width = width });
            var today = TodayTokens(id);
            var week = provider["week"]?.GetValue<long>() ?? 0;
            var cells = new FrameworkElement[]
            {
                new Ellipse { Width = 8, Height = 8, Fill = Brush(ColorOf(id)), VerticalAlignment = VerticalAlignment.Center },
                new TextBlock { Text = provider["name"]?.GetValue<string>() ?? id, VerticalAlignment = VerticalAlignment.Center },
                new TextBlock { Text = $"{Tokens(today)} today", FontWeight = FontWeights.SemiBold, VerticalAlignment = VerticalAlignment.Center },
                new TextBlock { Text = $"{Tokens(week)} in 7 days", Style = (Style)Root.Resources["Secondary"], HorizontalAlignment = HorizontalAlignment.Right, VerticalAlignment = VerticalAlignment.Center },
            };
            for (var column = 0; column < cells.Length; column++)
            {
                Grid.SetColumn(cells[column], column);
                row.Children.Add(cells[column]);
            }
            AutomationProperties.SetName(row, $"{provider["name"]}: {Tokens(today)} tokens today, {Tokens(week)} in 7 days");
            UsageList.Children.Add(new Border { Style = (Style)Root.Resources["Card"], CornerRadius = new CornerRadius(6), Child = row });
        }
    }

    // MARK: - Settings → HUD

    /// The HUD's six settings, and starting with Windows, as they are now.
    private void ShowHudSettings()
    {
        _showing = true;
        try
        {
            HudSwitch.IsOn = Preferences.Hud;
            HudStyleBox.SelectedIndex = Preferences.HudStyle == "strip" ? 1 : 0;
            HudCornerBox.SelectedIndex = (int)Preferences.HudCorner;
            HudOnTopSwitch.IsOn = Preferences.HudOnTop;
            var hidden = Preferences.HudHiddenTools;
            var names = KnownTools().Where(tool => !hidden.Contains(tool.Id)).Select(tool => tool.Name).ToList();
            HudToolsText.Text = KnownTools().Count == 0 ? "Every tool signed in on this PC"
                : names.Count == 0 ? "None" : string.Join(", ", names);
            HudShortcutText.Text = Preferences.HudShortcut is { } shortcut ? ShortcutText(shortcut.Modifiers, shortcut.Key) : "None set";
            HudShortcutClear.Visibility = Preferences.HudShortcut is null ? Visibility.Collapsed : Visibility.Visible;
            StartupSwitch.IsOn = Startup.IsEnabled;
        }
        finally { _showing = false; }
    }

    /// Every tool the last reading named, in its order.
    private List<HudData.Look> KnownTools()
    {
        if (_hud.Data is not { } data) return new List<HudData.Look>();
        return data.Tools.Select(tool => tool.Id).Concat(data.Problems.Select(problem => problem.Id)).Distinct().Select(data.LookOf).ToList();
    }

    private void OnHudToggled(object sender, RoutedEventArgs e)
    {
        if (!_showing) _hud.SetShown(HudSwitch.IsOn);
    }

    private void OnHudStyleChanged(object sender, SelectionChangedEventArgs e)
    {
        if (!_showing && HudStyleBox.SelectedItem is ComboBoxItem { Tag: string style }) _hud.SetStyle(style);
    }

    private void OnHudCornerChanged(object sender, SelectionChangedEventArgs e)
    {
        if (!_showing && HudCornerBox.SelectedItem is ComboBoxItem { Tag: string tag } && Enum.TryParse<Corner>(tag, out var corner)) _hud.SetCorner(corner);
    }

    private void OnHudOnTopToggled(object sender, RoutedEventArgs e)
    {
        if (!_showing) _hud.SetOnTop(HudOnTopSwitch.IsOn);
    }

    /// *Choose*: a tick for each tool the HUD knows; the window keeps showing them all.
    private void OnChooseTools(object sender, RoutedEventArgs e)
    {
        var list = new StackPanel { Spacing = 2, MinWidth = 220 };
        var tools = KnownTools();
        if (tools.Count == 0) list.Children.Add(new TextBlock { Text = "No tools signed in on this PC yet.", Style = (Style)Root.Resources["Secondary"] });
        foreach (var tool in tools)
        {
            var box = new CheckBox { Content = tool.Name, IsChecked = !Preferences.HudHiddenTools.Contains(tool.Id) };
            box.Click += (_, _) =>
            {
                var hidden = Preferences.HudHiddenTools.ToHashSet();
                if (box.IsChecked == true) hidden.Remove(tool.Id); else hidden.Add(tool.Id);
                Preferences.HudHiddenTools = hidden;
                _hud.Render();
                ShowHudSettings();
            };
            list.Children.Add(box);
        }
        new Flyout { Content = list }.ShowAt(HudToolsButton);
    }

    // MARK: - The HUD's shortcut

    /// Registers the shortcut, if one is set; answers whether Windows took it.
    private bool RegisterShortcut()
    {
        var handle = WinRT.Interop.WindowNative.GetWindowHandle(this);
        Win32.UnregisterHotKey(handle, ShortcutId);
        return Preferences.HudShortcut is not { } shortcut
            || Win32.RegisterHotKey(handle, ShortcutId, shortcut.Modifiers | Win32.MOD_NOREPEAT, shortcut.Key);
    }

    /// The shortcut, pressed anywhere: the HUD shown or hidden.
    private bool OnShortcut(uint message, IntPtr wParam)
    {
        if (message != Win32.WM_HOTKEY || (int)wParam != ShortcutId) return false;
        _hud.SetShown(!Preferences.Hud);
        return true;
    }

    /// *Set*: press the keys; Ctrl, Alt or the Windows key with another key.
    private async void OnSetShortcut(object sender, RoutedEventArgs e)
    {
        (uint Modifiers, uint Key)? pressed = null;
        var shown = new TextBlock { Text = "Press the keys…", FontSize = 20, FontWeight = FontWeights.SemiBold, Margin = new Thickness(0, 8, 0, 0) };
        var dialog = new ContentDialog
        {
            XamlRoot = Content.XamlRoot,
            Title = "Shortcut to show or hide the HUD",
            Content = new StackPanel
            {
                Spacing = 4,
                Children = { new TextBlock { Text = "Hold Ctrl, Alt or the Windows key, and press another key.", Style = (Style)Root.Resources["Secondary"] }, shown },
            },
            PrimaryButtonText = "Save",
            CloseButtonText = "Cancel",
            DefaultButton = ContentDialogButton.Primary,
            IsPrimaryButtonEnabled = false,
        };
        dialog.PreviewKeyDown += (_, key) =>
        {
            if (key.Key is VirtualKey.Control or VirtualKey.Menu or VirtualKey.Shift or VirtualKey.LeftWindows or VirtualKey.RightWindows
                or VirtualKey.LeftControl or VirtualKey.RightControl or VirtualKey.LeftMenu or VirtualKey.RightMenu or VirtualKey.LeftShift or VirtualKey.RightShift
                or VirtualKey.Escape or VirtualKey.Tab or VirtualKey.Enter) return;
            bool Down(VirtualKey modifier) => InputKeyboardSource.GetKeyStateForCurrentThread(modifier).HasFlag(CoreVirtualKeyStates.Down);
            var modifiers = (Down(VirtualKey.Control) ? Win32.MOD_CONTROL : 0) | (Down(VirtualKey.Menu) ? Win32.MOD_ALT : 0)
                          | (Down(VirtualKey.Shift) ? Win32.MOD_SHIFT : 0) | (Down(VirtualKey.LeftWindows) || Down(VirtualKey.RightWindows) ? Win32.MOD_WIN : 0);
            key.Handled = true;
            if ((modifiers & (Win32.MOD_CONTROL | Win32.MOD_ALT | Win32.MOD_WIN)) == 0) return;
            pressed = (modifiers, (uint)key.Key);
            shown.Text = ShortcutText(modifiers, (uint)key.Key);
            dialog.IsPrimaryButtonEnabled = true;
        };
        if (await dialog.ShowAsync() != ContentDialogResult.Primary || pressed is not { } chosen) return;
        var previous = Preferences.HudShortcut;
        Preferences.HudShortcut = chosen;
        if (!RegisterShortcut())
        {
            Preferences.HudShortcut = previous;
            RegisterShortcut();
            Tell($"{ShortcutText(chosen.Modifiers, chosen.Key)} is taken by another app. Try another.", InfoBarSeverity.Warning);
        }
        ShowHudSettings();
    }

    private void OnClearShortcut(object sender, RoutedEventArgs e)
    {
        Preferences.HudShortcut = null;
        RegisterShortcut();
        ShowHudSettings();
    }

    private static string ShortcutText(uint modifiers, uint key)
    {
        var parts = new List<string>();
        if ((modifiers & Win32.MOD_CONTROL) != 0) parts.Add("Ctrl");
        if ((modifiers & Win32.MOD_ALT) != 0) parts.Add("Alt");
        if ((modifiers & Win32.MOD_SHIFT) != 0) parts.Add("Shift");
        if ((modifiers & Win32.MOD_WIN) != 0) parts.Add("Win");
        var name = ((VirtualKey)key).ToString();
        parts.Add(name.StartsWith("Number") && name.Length == 7 ? name[6..] : name);
        return string.Join("+", parts);
    }

    // MARK: - Starting with Windows

    private void OnStartupToggled(object sender, RoutedEventArgs e)
    {
        if (_showing) return;
        Startup.Set(StartupSwitch.IsOn);
        Preferences.StartupOffered = true;
        StartupBar.IsOpen = false;
    }

    private void OnAcceptStartup(object sender, RoutedEventArgs e)
    {
        Startup.Set(true);
        Preferences.StartupOffered = true;
        StartupBar.IsOpen = false;
        ShowHudSettings();
    }

    /// Offered once: closed or accepted, it isn't offered again.
    private void OnStartupBarClosed(InfoBar sender, InfoBarClosedEventArgs args) => Preferences.StartupOffered = true;
}
