using System.Text.Json;
using System.Text.Json.Nodes;
using Microsoft.UI;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Shapes;
using Microsoft.Windows.AppNotifications;
using Windows.Graphics;
using Path = System.IO.Path;

namespace ClaudeBar;

/// A test entry point, like the hourly upload's: `ClaudeBar.exe --hud-check
/// [--theme light|dark] [--style strip] [--sample fine] [--calibrate]` opens
/// the real HUD on the sample reading in tests/hud-check.json, or every tool
/// fine in tests/hud-check-fine.json (built into the exe), with the
/// spike's red | blue over stripes window behind it, for scripts/check-hud.ps1
/// and the screenshots. It reads no limits, opens no membership, keeps its
/// settings in its own folder, and isn't offered in the Start menu or the
/// jump list.
///
/// The script drives it through files in %TEMP%\claudebar-hud-check: it
/// writes cmd.txt, the check answers ack-<command>.txt; ready.json carries
/// the windows' handles, and clicked.txt records each action a click ran.
internal sealed class HudCheck
{
    internal static readonly string Folder = Path.Combine(Path.GetTempPath(), "claudebar-hud-check");
    private readonly Window _behind = new() { Title = "ClaudeBar HUD check" };
    private readonly Hud _hud;
    private readonly DispatcherQueueTimer _commands;
    private readonly DispatcherQueue _queue;

    internal HudCheck(string[] arguments)
    {
        Directory.CreateDirectory(Folder);
        foreach (var file in Directory.GetFiles(Folder)) File.Delete(file);
        // What went wrong, for the script to print: a crash otherwise leaves only an Application Error event.
        Application.Current.UnhandledException += (_, e) => File.AppendAllText(Path.Combine(Folder, "crash.txt"), e.Exception + "\n");
        Preferences.UseFile(Path.Combine(Folder, "app.json"));
        if (Value(arguments, "--style") == "strip") Preferences.HudStyle = "strip";

        var queue = DispatcherQueue.GetForCurrentThread();
        _queue = queue;
        _sample = Value(arguments, "--sample") == "fine" ? "hud-check-fine.json" : "hud-check.json";
        // Before any window, as App.OnLaunched does: registering once a window
        // is up ended the process in CoreMessagingXP (0xc000027b) on the PC.
        AppNotificationManager.Default.NotificationInvoked += (_, invoked) => _queue.TryEnqueue(() => Activated(invoked.Argument));
        try
        {
            AppNotificationManager.Default.Register();
            _notifying = true;
        }
        catch (Exception exception) { File.AppendAllText(Path.Combine(Folder, "crash.txt"), "notifications: " + exception + "\n"); }
        _hud = new Hud(queue, Sample)
        {
            OpenWindow = () => Clicked("open"),
            OpenSettings = () => Clicked("settings"),
            OpenLimits = () => Clicked("limits"),
            ChooseTools = () => Clicked("choose-tools"),
            Quit = () => Application.Current.Exit(),
            Theme = Value(arguments, "--theme") switch { "light" => ElementTheme.Light, "dark" => ElementTheme.Dark, _ => ElementTheme.Default },
            Calibrate = arguments.Contains("--calibrate"),
            TodayTokens = 3_400_000,
            Place = "#18 this week",
        };
        _hud.Start();
        BuildBehind();
        _commands = queue.CreateTimer();
        _commands.Interval = TimeSpan.FromMilliseconds(150);
        _commands.Tick += (_, _) => Poll();
        _commands.Start();
        queue.TryEnqueue(DispatcherQueuePriority.Low, () => queue.TryEnqueue(DispatcherQueuePriority.Low, WriteReady));
    }

    /// The sample (`--sample fine`: every tool fine), read now: its dates moved by the time since it was taken.
    /// A refresh is a click's action: it's recorded.
    private static string _sample = "hud-check.json";

    private static Task<JsonObject> Sample(bool refresh)
    {
        if (refresh) Clicked("refresh");
        using var stream = typeof(HudCheck).Assembly.GetManifestResourceStream(_sample)!;
        var reply = (JsonObject)JsonNode.Parse(stream)!;
        var readAt = reply["readAt"]!.GetValue<double>();
        var shift = DateTimeOffset.Now.ToUnixTimeSeconds() - readAt;
        Shift(reply, shift);
        return Task.FromResult(reply);
    }

    /// Every date in the reply moved by `seconds`: `readAt`, `resetsAt`, `outUntil`.
    private static void Shift(JsonNode? node, double seconds)
    {
        switch (node)
        {
            case JsonObject obj:
                foreach (var key in obj.Select(pair => pair.Key).ToList())
                {
                    if (key is "readAt" or "resetsAt" or "outUntil" or "runsOutAt" && obj[key] is JsonValue value)
                        obj[key] = value.GetValue<double>() + seconds;
                    else Shift(obj[key], seconds);
                }
                break;
            case JsonArray array:
                foreach (var item in array) Shift(item, seconds);
                break;
        }
    }

    private readonly bool _notifying;
    private const string QuietKey = "omp/Kimi 7d";

    /// The crossing notification for `omp/Kimi 7d`, sent as the app sends it
    /// (`App.Notify`, `MainWindow.OnCrossed`). Its *Quiet until reset* button
    /// comes back through Windows, is read as `MainWindow.Open` reads it, and
    /// quiets that limit; activated.txt says what arrived and what was kept,
    /// notify.txt whether Windows took it.
    private async void Notify()
    {
        var failed = _notifying
            ? App.Notify("omp is at 31%", "It resets on Thursday.", ("Show the HUD", "--hud"), ("Quiet until reset", $"--quiet={Uri.EscapeDataString(QuietKey)}"))
            : "not registered for notifications (crash.txt)";
        var kept = failed is null ? (await AppNotificationManager.Default.GetAllAsync()).Count : 0;
        File.WriteAllText(Path.Combine(Folder, "notify.txt"), failed ?? $"shown, {kept} in the notification centre, notifications {AppNotificationManager.Default.Setting}");
    }

    private void Activated(string argument)
    {
        var action = LaunchArguments.NotificationAction(argument) ?? "";
        if (LaunchArguments.Quiet(action) is { } quiet) _hud.Quiet(quiet);
        var kept = Preferences.HudLines.TryGetValue(QuietKey, out var line) ? line.QuietUntil?.ToString("o") ?? "none" : "no such limit";
        File.WriteAllText(Path.Combine(Folder, "activated.txt"), $"argument={argument}\naction={action}\nquiet={LaunchArguments.Quiet(action)}\nquietUntil={kept}\n");
    }

    private static Windows.UI.Color Color(byte r, byte g, byte b) => Windows.UI.Color.FromArgb(255, r, g, b);

    private static void Clicked(string action) => File.AppendAllText(Path.Combine(Folder, "clicked.txt"), action + "\n");

    private static string? Value(string[] arguments, string name)
    {
        var index = Array.IndexOf(arguments, name);
        return index >= 0 && index + 1 < arguments.Length ? arguments[index + 1] : null;
    }

    private double Scale(Window window) => Win32.GetDpiForWindow(WinRT.Interop.WindowNative.GetWindowHandle(window)) / 96.0;

    /// The spike's window: red | blue, over black and white stripes, under the
    /// HUD, with the seam at the HUD's centre and the stripes under its lower half.
    private void BuildBehind()
    {
        var work = DisplayArea.Primary.WorkArea;
        Win32.GetWindowRect(_hud.Handle, out var hud);
        var scale = Scale(_behind);
        var width = (int)(760 * scale);
        var height = (int)(560 * scale);
        var x = Math.Clamp((hud.Left + hud.Right) / 2 - width / 2, work.X, work.X + work.Width - width);
        var y = Math.Clamp((hud.Top + hud.Bottom) / 2 - height / 2, work.Y, work.Y + work.Height - height);
        var seam = ((hud.Left + hud.Right) / 2 - x) / scale;
        var stripesTop = ((hud.Top + hud.Bottom) / 2 - y) / scale;

        var colors = new Grid();
        colors.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(Math.Max(1, seam)) });
        colors.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        var red = new Rectangle { Fill = new SolidColorBrush(Colors.Red) };
        var blue = new Rectangle { Fill = new SolidColorBrush(Colors.Blue) };
        Grid.SetColumn(blue, 1);
        colors.Children.Add(red);
        colors.Children.Add(blue);
        var stripes = new StackPanel { Orientation = Orientation.Horizontal };
        for (var index = 0; index < 400; index++)
            stripes.Children.Add(new Rectangle { Width = 4, Fill = new SolidColorBrush(index % 2 == 0 ? Colors.Black : Colors.White) });
        var root = new Grid();
        root.RowDefinitions.Add(new RowDefinition { Height = new GridLength(Math.Max(1, stripesTop)) });
        root.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
        Grid.SetRow(stripes, 1);
        root.Children.Add(colors);
        root.Children.Add(stripes);
        _behind.Content = root;
        _behind.ExtendsContentIntoTitleBar = true;
        _behind.AppWindow.MoveAndResize(new RectInt32(x, y, width, height));
        _behind.Activate();
    }

    private void WriteReady()
    {
        var ready = new Dictionary<string, object>
        {
            ["behind"] = (long)WinRT.Interop.WindowNative.GetWindowHandle(_behind),
            ["hud"] = (long)_hud.Handle,
            ["dpi"] = Win32.GetDpiForWindow(_hud.Handle),
            ["corner"] = Preferences.HudCorner.ToString(),
        };
        File.WriteAllText(Path.Combine(Folder, "ready.json"), JsonSerializer.Serialize(ready));
    }

    /// The script's commands: full screen in the ways research.md measured,
    /// back to a window, the HUD at a corner or on the other screen, hidden and
    /// shown again, a plain colour behind it for screenshots, and exit.
    private void Poll()
    {
        var file = Path.Combine(Folder, "cmd.txt");
        if (!File.Exists(file)) return;
        string command;
        try { command = File.ReadAllText(file).Trim(); File.Delete(file); }
        catch (IOException) { return; }
        var window = _behind.AppWindow;
        switch (command)
        {
            case "fullscreen":
                window.SetPresenter(AppWindowPresenterKind.FullScreen);
                _behind.Activate();
                break;
            case "fullscreen-other-screen":
            {
                var hudScreen = DisplayArea.GetFromWindowId(Win32Interop.GetWindowIdFromWindow(_hud.Handle), DisplayAreaFallback.Primary).DisplayId.Value;
                var all = DisplayArea.FindAll();
                DisplayArea? other = null;
                for (var index = 0; index < all.Count; index++) if (all[index].DisplayId.Value != hudScreen) { other = all[index]; break; }
                if (other is null) break;
                window.Move(new PointInt32(other.WorkArea.X + 100, other.WorkArea.Y + 100));
                window.SetPresenter(AppWindowPresenterKind.FullScreen);
                _behind.Activate();
                break;
            }
            case "cover":
            {
                // Borderless and the size of its screen, as most games and video players are.
                var cover = OverlappedPresenter.Create();
                cover.SetBorderAndTitleBar(false, false);
                window.SetPresenter(cover);
                window.MoveAndResize(DisplayArea.GetFromWindowId(window.Id, DisplayAreaFallback.Primary).OuterBounds);
                _behind.Activate();
                break;
            }
            case "restore":
                window.SetPresenter(AppWindowPresenterKind.Overlapped);
                BuildBehind();
                break;
            case "exit":
                File.WriteAllText(Path.Combine(Folder, "ack-exit.txt"), "");
                if (_notifying) try { AppNotificationManager.Default.Unregister(); } catch (Exception) { }
                _hud.Dispose();
                Application.Current.Exit();
                return;
            case "notify":
                Notify();
                break;
            case "reshow":
                // Hidden and shown again, as the switch and the shortcut do: it mustn't take the focus.
                _hud.SetShown(false);
                _hud.SetShown(true);
                break;
            case "plain-light":
            case "plain-dark":
                // A plain desktop-like colour behind, for the screenshots.
                _behind.Content = new Grid { Background = new SolidColorBrush(command == "plain-light" ? Color(0xF3, 0xF3, 0xF3) : Color(0x20, 0x20, 0x20)) };
                break;
            case "hud-other-screen":
            case "hud-primary":
            {
                // The HUD on a screen that isn't the primary, or back: full screen on the primary mustn't hide it.
                var all = DisplayArea.FindAll();
                var primary = DisplayArea.Primary.DisplayId.Value;
                Preferences.HudScreen = null;
                for (var index = 0; index < all.Count && command == "hud-other-screen"; index++)
                    if (all[index].DisplayId.Value != primary) { Preferences.HudScreen = all[index].DisplayId.Value; break; }
                _hud.Render();
                break;
            }
            default:
                if (command.StartsWith("corner:") && Enum.TryParse<Corner>(command["corner:".Length..], out var corner)) _hud.SetCorner(corner);
                else if (command is "style:card" or "style:strip") _hud.SetStyle(command["style:".Length..]);
                break;
        }
        File.WriteAllText(Path.Combine(Folder, $"ack-{command.Replace(':', '-')}.txt"),
                          $"presenter={window.Presenter.Kind} pos={window.Position.X},{window.Position.Y} size={window.Size.Width}x{window.Size.Height} corner={Preferences.HudCorner}");
    }
}
