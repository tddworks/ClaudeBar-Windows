using System.Text.Json;
using System.Text.Json.Nodes;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;

namespace ClaudeBar;

/// The HUD as the app runs it (docs/plans/2026-10-13-hud-design.md): reads
/// the limits on a timer and on *Refresh*, ticks the countdowns once a minute
/// from the reset times without asking again, draws the card or the strip in
/// the HUD's window, and says when a limit crosses into trouble or comes back.
internal sealed class Hud : IDisposable
{
    private const double CardWidth = 340;
    private readonly Func<bool, Task<JsonObject>> _read;
    private readonly ForegroundTracker _foreground = new();
    private readonly HudWindow _window;
    private readonly HudView _view = new();
    private readonly DispatcherQueueTimer _poll;
    private readonly DispatcherQueueTimer _tick;
    private HudData? _data;
    private string? _lastReading;
    private bool _offline;
    private bool _reading;
    /// The strip, clicked: the card until the pointer leaves it.
    private bool _peek;
    /// Nothing found was shown once this run; after that the HUD waits for a tool.
    private bool _shownEmpty;

    /// The reading changed, or whether it's offline: for the window's Limits page and the taskbar dot.
    internal Action? Changed;
    /// A limit crossed into trouble or came back (Task 11): the app notifies.
    internal Action<HudData.Tool, HudData.Line, Crossing>? Crossed;
    internal Action? OpenWindow;
    internal Action? OpenSettings;
    /// A click on one of the card's rows: the window's Limits page.
    internal Action? OpenLimits;
    internal Action? ChooseTools;
    internal Action? Quit;
    /// Shown or hidden from the HUD itself (its menu, or closing it): Settings follows.
    internal Action? ShownChanged;

    /// `read(refresh)`: `Swift.HudRefresh()` when asked to refresh, else
    /// `Swift.HudReading()`, which answers from the last numbers at once.
    internal Hud(DispatcherQueue queue, Func<bool, Task<JsonObject>> read)
    {
        _read = read;
        _window = new HudWindow(_foreground) { CloseRequested = () => SetShown(false) };
        // Drawn again after the theme change has gone through the tree: replacing
        // the content inside ActualThemeChanged crashes XAML (seen with --theme light on a dark PC).
        _window.ThemeChanged = () => queue.TryEnqueue(DispatcherQueuePriority.Low, Render);
        _view.Refresh = () => _ = Read(refresh: true);
        _view.ToggleOnTop = () => SetOnTop(!Preferences.HudOnTop);
        _view.ShowStrip = () => { _peek = false; SetStyle("strip"); };
        _view.ShowCard = () => { _peek = true; Render(); };
        _view.OpenWindow = () => OpenWindow?.Invoke();
        _view.OpenSettings = () => OpenSettings?.Invoke();
        _view.OpenLimits = () => OpenLimits?.Invoke();
        _view.ChooseTools = () => ChooseTools?.Invoke();
        _view.HideHud = () => SetShown(false);
        _view.Quit = () => Quit?.Invoke();
        _view.AfterClick = _window.AfterClick;
        // The buttons are passed through the footer's drag region only while they show.
        _view.RegionsChanged = () => _window.SetDragRegions(_view.Captions, _view.Passthrough);
        _poll = queue.CreateTimer();
        _poll.Interval = TimeSpan.FromSeconds(30);
        _poll.Tick += (_, _) => _ = Read(refresh: false);
        _tick = queue.CreateTimer();
        _tick.Tick += (_, _) =>
        {
            Render();
            _tick.Interval = UntilNextMinute();
        };
    }

    internal HudData? Data => _data;

    internal bool Offline => _offline;

    internal bool IsShown => _window.IsShown;

    /// Today's tokens and the place, for the footer, from what the window reads.
    internal long? TodayTokens { get; set; }

    internal string? Place { get; set; }

    /// The check's theme and calibration (`--hud-check`).
    internal ElementTheme Theme { set => _window.Theme = value; }

    internal bool Calibrate { set => _view.Calibrate = value; }

    internal IntPtr Handle => _window.Handle;

    internal void Start()
    {
        Render();
        _ = Read(refresh: false);
        _poll.Start();
        _tick.Interval = UntilNextMinute();
        _tick.Start();
    }

    /// Reads the limits: refreshes every signed-in tool first when asked.
    /// A failed read keeps the last numbers, as offline.
    internal async Task Read(bool refresh)
    {
        if (_reading && !refresh) return;
        _reading = true;
        JsonObject reply;
        try { reply = await _read(refresh); }
        catch (Exception error) { reply = new JsonObject { ["error"] = error.Message }; }
        finally { _reading = false; }
        Error = reply["error"]?.GetValue<string>();
        if (HudData.Parse(reply) is not { } data)
        {
            var offline = _data is not null;
            if (offline != _offline || refresh)
            {
                _offline = offline;
                Render();
            }
            Changed?.Invoke();
            return;
        }
        var text = reply["reading"]!.ToJsonString() + reply["problems"]?.ToJsonString() + reply["readAt"]?.ToJsonString();
        if (!_offline && text == _lastReading)
        {
            if (refresh) Render();
            return;
        }
        _offline = false;
        _data = data;
        _lastReading = text;
        Remember(data);
        Cross(data);
        Render();
        Changed?.Invoke();
    }

    /// Why the last read failed, if it did.
    internal string? Error { get; private set; }

    internal void SetShown(bool shown)
    {
        Preferences.Hud = shown;
        if (shown) _shownEmpty = false;
        Render();
        ShownChanged?.Invoke();
    }

    internal void SetStyle(string style)
    {
        Preferences.HudStyle = style;
        Render();
    }

    internal void SetOnTop(bool onTop)
    {
        Preferences.HudOnTop = onTop;
        _window.OnTop = onTop;
        Render();
    }

    internal void SetCorner(Corner corner)
    {
        Preferences.HudCorner = corner;
        Render();
    }

    /// *Quiet until reset* on a notification: nothing more about that limit until it resets.
    internal void Quiet(string key)
    {
        var kept = KeptLines();
        if (!kept.TryGetValue(key, out var line)) return;
        kept[key] = line with { QuietUntil = line.ResetsAt ?? DateTimeOffset.Now.AddHours(5) };
        Preferences.HudLines = kept;
    }

    /// Draws the HUD again: the countdowns from the reset times, as of now.
    internal void Render()
    {
        var hidden = Preferences.HudHiddenTools;
        var data = _data?.Without(hidden);
        var pending = Preferences.HudPending.Where(tool => !hidden.Contains(tool.Look.Id)).ToList();
        var empty = data is { IsEmpty: true };
        var wanted = Preferences.Hud && (data is not null || pending.Count > 0) && !(empty && _shownEmpty);
        if (!wanted)
        {
            if (_window.IsShown) _window.Hide();
            return;
        }
        if (data is { IsEmpty: true }) _shownEmpty = true;
        var input = new HudView.Input(data, pending, _offline, TodayTokens, Place, DateTimeOffset.Now,
                                      _window.ActualTheme == ElementTheme.Dark, Preferences.HudOnTop, _window.PointerOver);
        var strip = Preferences.HudStyle == "strip" && !_peek;
        var content = strip ? _view.Strip(input) : _view.Card(input);
        if (_peek) content.PointerExited += (_, _) => { _peek = false; Render(); };
        _window.SetContent(content, strip ? null : CardWidth);
        _window.SetDragRegions(_view.Captions, _view.Passthrough);
        if (!_window.IsShown) _window.Show();
    }

    /// The tools and their windows, so the next start draws their rows while it reads.
    private static void Remember(HudData data)
    {
        if (data.Tools.Count == 0) return;
        Preferences.HudPending = data.Tools.Select(tool => (data.LookOf(tool.Id), (IReadOnlyList<string>)tool.Lines.Select(line => line.Window).ToList())).ToList();
    }

    /// Notifies each limit that crossed into critical or depleted, or came
    /// back, once per crossing (HudCrossings), and keeps where each one is.
    private void Cross(HudData data)
    {
        var lines = data.Tools.SelectMany(tool => tool.Lines.Select(line => (tool, line))).ToList();
        var (notify, kept) = HudCrossings.Next(KeptLines(),
            lines.Select(pair => new LineNow(HudData.Key(pair.tool, pair.line), pair.line.Status, pair.line.ResetsAt)), DateTimeOffset.Now);
        Preferences.HudLines = kept;
        foreach (var (key, crossing) in notify)
        {
            var (tool, line) = lines.First(pair => HudData.Key(pair.tool, pair.line) == key);
            Crossed?.Invoke(tool, line, crossing);
        }
    }

    private static Dictionary<string, KeptLine> KeptLines() => new(Preferences.HudLines);

    private static TimeSpan UntilNextMinute()
    {
        var now = DateTime.Now;
        return TimeSpan.FromSeconds(60 - now.Second) - TimeSpan.FromMilliseconds(now.Millisecond) + TimeSpan.FromMilliseconds(50);
    }

    public void Dispose()
    {
        _poll.Stop();
        _tick.Stop();
        _window.Close();
        _foreground.Dispose();
    }
}
