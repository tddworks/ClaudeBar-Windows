using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;

namespace ClaudeBar;

/// Settings → Tools in WSL (docs/plans/2026-11-03-wsl-design.md): each
/// distro `wsl.exe` lists, whether it runs, its switch, and from its last
/// reading the tools and where, the sources left out, and what to know.
public sealed partial class MainWindow
{
    /// Draws the group from the HUD's last reply and app.json, as `ShowLimits` draws the Limits page.
    private void ShowWsl()
    {
        _showing = true;
        try
        {
            WslList.Children.Clear();
            var wsl = _hud.Wsl;
            if (WslSettings.Empty(wsl) is { } empty)
            {
                WslList.Children.Add(WslCard(new TextBlock { Text = empty, VerticalAlignment = VerticalAlignment.Center }, null));
                return;
            }
            foreach (var row in WslSettings.Rows(wsl, Preferences.Wsl, TimeZoneInfo.Local)) WslList.Children.Add(WslDistro(row));
        }
        finally { _showing = false; }
    }

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
        toggle.IsEnabled = false;
        Preferences.Wsl = WslSettings.WithOn(Preferences.Wsl, distro, toggle.IsOn);
        await Guarded(() => Swift.WslConfigure(Preferences.Wsl));
        toggle.IsEnabled = true;
        _ = _hud.Read(refresh: false);
    }
}
