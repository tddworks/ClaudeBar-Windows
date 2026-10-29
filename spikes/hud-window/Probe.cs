using System.Runtime.InteropServices;
using System.Text.Json;
using Microsoft.UI;
using Microsoft.UI.Composition;
using Microsoft.UI.Composition.SystemBackdrops;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Shapes;
using Windows.Graphics;
using WinRT.Interop;
using Path = System.IO.Path;

namespace HudProbe;

/// SPIKE: does a HUD window keep its Acrylic while it never activates?
///
/// Two windows. *Behind* is an ordinary window painted red | blue over
/// black/white stripes. *HUD* sits over the red/blue seam and the stripes:
/// borderless, always on top, and, unless the mode says otherwise,
/// WS_EX_NOACTIVATE | WS_EX_TOOLWINDOW. probe.ps1 measures what shows through.
///
/// Modes (first argument):
///   default      DesktopAcrylicBackdrop, the XAML backdrop (what microsoft-ui-xaml#10570 reports)
///   follow       DesktopAcrylicController with the framework's configuration, which follows activation
///   active       DesktopAcrylicController with its own configuration, IsInputActive kept true
///   activatable  DesktopAcrylicBackdrop on a HUD without NOACTIVATE, activated once, then left inactive
///
/// probe.ps1 drives it through files in %TEMP%\hudprobe: it writes cmd.txt, the
/// probe answers ack-<command>.txt. ready.json carries the handles.
internal sealed class Probe
{
    private static readonly string Dir = Path.Combine(Path.GetTempPath(), "hudprobe");
    private readonly Window _behind = new() { Title = "HudProbe Behind" };
    private readonly Window _hud = new() { Title = "HudProbe HUD" };
    private readonly string _mode;
    private readonly DispatcherQueueTimer _timer;
    private SubclassProc? _mouseActivate;
    private SubclassProc? _trace;
    private readonly List<string> _traced = new();

    internal Probe(string mode)
    {
        _mode = mode;
        Directory.CreateDirectory(Dir);
        BuildBehind();
        BuildHud();
        _timer = _behind.DispatcherQueue.CreateTimer();
        _timer.Interval = TimeSpan.FromMilliseconds(150);
        _timer.Tick += (_, _) => Poll();
        _timer.Start();
        _behind.DispatcherQueue.TryEnqueue(DispatcherQueuePriority.Low, WriteReady);
    }

    private static double Scale(Window window) => GetDpiForWindow(WindowNative.GetWindowHandle(window)) / 96.0;

    private void BuildBehind()
    {
        var colors = new Grid();
        colors.ColumnDefinitions.Add(new ColumnDefinition());
        colors.ColumnDefinitions.Add(new ColumnDefinition());
        var red = new Rectangle { Fill = new SolidColorBrush(Colors.Red) };
        var blue = new Rectangle { Fill = new SolidColorBrush(Colors.Blue) };
        Grid.SetColumn(blue, 1);
        colors.Children.Add(red);
        colors.Children.Add(blue);

        var stripes = new StackPanel { Orientation = Orientation.Horizontal };
        for (var i = 0; i < 300; i++)
            stripes.Children.Add(new Rectangle { Width = 4, Fill = new SolidColorBrush(i % 2 == 0 ? Colors.Black : Colors.White) });

        var root = new Grid();
        root.RowDefinitions.Add(new RowDefinition());
        root.RowDefinitions.Add(new RowDefinition());
        Grid.SetRow(stripes, 1);
        root.Children.Add(colors);
        root.Children.Add(stripes);
        _behind.Content = root;
        _behind.ExtendsContentIntoTitleBar = true;

        var s = Scale(_behind);
        _behind.AppWindow.MoveAndResize(new RectInt32(200, 200, (int)(800 * s), (int)(500 * s)));
        _behind.Activate();
    }

    private void BuildHud()
    {
        var root = new Grid { Background = new SolidColorBrush(Colors.Transparent), RequestedTheme = ElementTheme.Dark };
        var line = new TextBlock { Text = "Claude 62% left, resets in 2h 14m", Margin = new Thickness(12, 8, 0, 0), FontSize = 12 };
        AutomationProperties.SetName(line, "Claude, 5-hour limit: 62% left, resets in 2 hours 14 minutes");
        root.Children.Add(line);
        var retry = new Button
        {
            Content = "Retry",
            HorizontalAlignment = HorizontalAlignment.Right,
            VerticalAlignment = VerticalAlignment.Bottom,
            Margin = new Thickness(0, 0, 8, 8),
        };
        AutomationProperties.SetName(retry, "Retry reading Gemini");
        retry.Click += (_, _) => File.WriteAllText(Path.Combine(Dir, "clicked.txt"), DateTime.Now.ToString("O"));
        root.Children.Add(retry);
        _hud.Content = root;

        if (_mode == "active-nofocus")
        {
            // Pointer presses don't move keyboard focus into the HUD.
            root.AllowFocusOnInteraction = false;
            retry.AllowFocusOnInteraction = false;
        }

        _hud.SystemBackdrop = _mode switch
        {
            "follow" => new ControlledAcrylic(keepActive: false),
            "default" or "activatable" or "trace" => new DesktopAcrylicBackdrop(),
            "mica" => new MicaBackdrop(),
            "mica-active" => new ControlledMica(),
            _ => new ControlledAcrylic(keepActive: _mode.StartsWith("active")),
        };

        var presenter = OverlappedPresenter.Create();
        presenter.IsAlwaysOnTop = true;
        presenter.IsResizable = false;
        presenter.IsMaximizable = false;
        presenter.IsMinimizable = false;
        presenter.SetBorderAndTitleBar(true, false);
        _hud.AppWindow.SetPresenter(presenter);
        _hud.AppWindow.IsShownInSwitchers = false;

        var hwnd = WindowNative.GetWindowHandle(_hud);
        if (_mode != "activatable")
        {
            var ex = GetWindowLongPtrW(hwnd, GWL_EXSTYLE);
            SetWindowLongPtrW(hwnd, GWL_EXSTYLE, (IntPtr)((long)ex | WS_EX_NOACTIVATE | WS_EX_TOOLWINDOW));
        }
        if (_mode is "active-mouseactivate" or "active-childnoact")
        {
            _mouseActivate = (window, message, wParam, lParam, id, data) =>
                message == WM_MOUSEACTIVATE ? (IntPtr)MA_NOACTIVATE : DefSubclassProc(window, message, wParam, lParam);
            SetWindowSubclass(hwnd, _mouseActivate, (UIntPtr)1, UIntPtr.Zero);
        }
        if (_mode is "trace" or "active-pointer")
        {
            var answer = _mode == "active-pointer";
            _trace = (window, message, wParam, lParam, id, data) =>
            {
                if (message is WM_MOUSEACTIVATE or WM_POINTERACTIVATE or WM_ACTIVATE or WM_NCACTIVATE or WM_SETFOCUS or WM_POINTERDOWN or WM_LBUTTONDOWN)
                {
                    var name = new System.Text.StringBuilder(128);
                    GetClassNameW(window, name, 128);
                    lock (_traced) _traced.Add($"{DateTime.Now:HH:mm:ss.fff} {name} 0x{message:X4} wParam=0x{(long)wParam:X}");
                    if (answer && message == WM_POINTERACTIVATE) return (IntPtr)PA_NOACTIVATE;
                    if (answer && message == WM_MOUSEACTIVATE) return (IntPtr)MA_NOACTIVATE;
                }
                return DefSubclassProc(window, message, wParam, lParam);
            };
            SetWindowSubclass(hwnd, _trace, (UIntPtr)2, UIntPtr.Zero);
        }
        if (_mode == "active-giveback")
        {
            // Let a click activate the HUD, then hand the foreground straight back
            // to the window that had it (WM_ACTIVATE's lParam names it).
            _mouseActivate = (window, message, wParam, lParam, id, data) =>
            {
                if (message == WM_ACTIVATE && ((long)wParam & 0xFFFF) != 0 && lParam != IntPtr.Zero && lParam != window)
                {
                    var previous = lParam;
                    _hud.DispatcherQueue.TryEnqueue(DispatcherQueuePriority.Low, () => SetForegroundWindow(previous));
                }
                return DefSubclassProc(window, message, wParam, lParam);
            };
            SetWindowSubclass(hwnd, _mouseActivate, (UIntPtr)1, UIntPtr.Zero);
        }
        var round = DWMWCP_ROUND;
        DwmSetWindowAttribute(hwnd, DWMWA_WINDOW_CORNER_PREFERENCE, ref round, sizeof(int));

        var s = Scale(_hud);
        _hud.AppWindow.MoveAndResize(new RectInt32(200 + (int)(250 * s), 200 + (int)(80 * s), (int)(300 * s), (int)(340 * s)));
        if (_mode == "activatable") _hud.Activate();
        else _hud.AppWindow.Show(false);
    }

    private readonly List<string> _children = new();

    private void WriteReady()
    {
        var hud = WindowNative.GetWindowHandle(_hud);
        EnumChildWindows(hud, (child, _) =>
        {
            var name = new System.Text.StringBuilder(128);
            GetClassNameW(child, name, 128);
            _children.Add(name.ToString());
            if (_mode == "active-childnoact" && _mouseActivate is not null) SetWindowSubclass(child, _mouseActivate, (UIntPtr)1, UIntPtr.Zero);
            if (_trace is not null) _children.Add("subclassed=" + SetWindowSubclass(child, _trace, (UIntPtr)2, UIntPtr.Zero));
            return true;
        }, IntPtr.Zero);
        var ready = new Dictionary<string, object>
        {
            ["mode"] = _mode,
            ["behind"] = (long)WindowNative.GetWindowHandle(_behind),
            ["hud"] = (long)hud,
            ["hudExStyle"] = (long)GetWindowLongPtrW(hud, GWL_EXSTYLE),
            ["dpi"] = GetDpiForWindow(hud),
            ["acrylicSupported"] = DesktopAcrylicController.IsSupported(),
            ["children"] = string.Join(",", _children),
            ["mouseInPointer"] = IsMouseInPointerEnabled(),
        };
        File.WriteAllText(Path.Combine(Dir, "ready.json"), JsonSerializer.Serialize(ready));
    }

    private void Poll()
    {
        var file = Path.Combine(Dir, "cmd.txt");
        if (!File.Exists(file)) return;
        string command;
        try { command = File.ReadAllText(file).Trim(); File.Delete(file); }
        catch (IOException) { return; }
        switch (command)
        {
            case "fullscreen":
                _behind.AppWindow.SetPresenter(AppWindowPresenterKind.FullScreen);
                _behind.Activate();
                break;
            case "fullscreen-other-screen":
            {
                // Full screen on a screen that isn't the HUD's.
                var hudScreen = DisplayArea.GetFromWindowId(_hud.AppWindow.Id, DisplayAreaFallback.Primary).DisplayId.Value;
                // Indexed, not enumerated: enumerating FindAll()'s result throws in C#.
                var all = DisplayArea.FindAll();
                DisplayArea? other = null;
                for (var i = 0; i < all.Count; i++) if (all[i].DisplayId.Value != hudScreen) { other = all[i]; break; }
                if (other is null) break;
                _behind.AppWindow.Move(new PointInt32(other.WorkArea.X + 100, other.WorkArea.Y + 100));
                _behind.AppWindow.SetPresenter(AppWindowPresenterKind.FullScreen);
                _behind.Activate();
                break;
            }
            case "cover":
            {
                // Borderless and the size of its monitor, as most games and video players do.
                var cover = OverlappedPresenter.Create();
                cover.SetBorderAndTitleBar(false, false);
                _behind.AppWindow.SetPresenter(cover);
                var bounds = DisplayArea.GetFromWindowId(_behind.AppWindow.Id, DisplayAreaFallback.Primary).OuterBounds;
                _behind.AppWindow.MoveAndResize(bounds);
                _behind.Activate();
                break;
            }
            case "restore":
                _behind.AppWindow.SetPresenter(AppWindowPresenterKind.Overlapped);
                _behind.AppWindow.MoveAndResize(new RectInt32(200, 200, (int)(800 * Scale(_behind)), (int)(500 * Scale(_behind))));
                break;
            case "trace":
                lock (_traced) File.WriteAllLines(Path.Combine(Dir, "trace.txt"), _traced);
                break;
            case "exit":
                File.WriteAllText(Path.Combine(Dir, "ack-exit.txt"), "");
                Application.Current.Exit();
                return;
        }
        var w = _behind.AppWindow;
        File.WriteAllText(Path.Combine(Dir, $"ack-{command}.txt"), $"presenter={w.Presenter.Kind} pos={w.Position.X},{w.Position.Y} size={w.Size.Width}x{w.Size.Height}");
    }

    private const int GWL_EXSTYLE = -20;
    private const uint WM_MOUSEACTIVATE = 0x0021;
    private const int MA_NOACTIVATE = 3;
    private const uint WM_ACTIVATE = 0x0006;
    private const uint WM_SETFOCUS = 0x0007;
    private const uint WM_NCACTIVATE = 0x0086;
    private const uint WM_LBUTTONDOWN = 0x0201;
    private const uint WM_POINTERDOWN = 0x0246;
    private const uint WM_POINTERACTIVATE = 0x024B;
    private const int PA_NOACTIVATE = 3;
    private const long WS_EX_NOACTIVATE = 0x08000000L;
    private const long WS_EX_TOOLWINDOW = 0x00000080L;
    private const int DWMWA_WINDOW_CORNER_PREFERENCE = 33;
    private const int DWMWCP_ROUND = 2;

    [DllImport("user32.dll")] private static extern uint GetDpiForWindow(IntPtr window);
    [DllImport("user32.dll")] private static extern IntPtr GetWindowLongPtrW(IntPtr window, int index);
    [DllImport("user32.dll")] private static extern IntPtr SetWindowLongPtrW(IntPtr window, int index, IntPtr value);
    [DllImport("dwmapi.dll")] private static extern int DwmSetWindowAttribute(IntPtr window, int attribute, ref int value, int size);
    internal delegate IntPtr SubclassProc(IntPtr window, uint message, IntPtr wParam, IntPtr lParam, UIntPtr id, UIntPtr data);
    [DllImport("comctl32.dll")] private static extern bool SetWindowSubclass(IntPtr window, SubclassProc proc, UIntPtr id, UIntPtr data);
    [DllImport("comctl32.dll")] private static extern IntPtr DefSubclassProc(IntPtr window, uint message, IntPtr wParam, IntPtr lParam);
    private delegate bool EnumProc(IntPtr window, IntPtr data);
    [DllImport("user32.dll")] private static extern bool EnumChildWindows(IntPtr parent, EnumProc proc, IntPtr data);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] private static extern int GetClassNameW(IntPtr window, System.Text.StringBuilder name, int size);
    [DllImport("user32.dll")] private static extern bool SetForegroundWindow(IntPtr window);
    [DllImport("user32.dll")] private static extern bool IsMouseInPointerEnabled();
}

/// Desktop Acrylic through its controller, as Microsoft's backdrop-controller
/// guide does, either with the framework's configuration (which follows the
/// window's activation) or with one that stays active.
internal sealed class ControlledAcrylic : SystemBackdrop
{
    private readonly bool _keepActive;
    private DesktopAcrylicController? _controller;

    internal ControlledAcrylic(bool keepActive) => _keepActive = keepActive;

    protected override void OnTargetConnected(ICompositionSupportsSystemBackdrop target, XamlRoot xamlRoot)
    {
        base.OnTargetConnected(target, xamlRoot);
        var configuration = _keepActive
            ? new SystemBackdropConfiguration { IsInputActive = true, Theme = SystemBackdropTheme.Dark }
            : GetDefaultSystemBackdropConfiguration(target, xamlRoot);
        _controller = new DesktopAcrylicController();
        _controller.AddSystemBackdropTarget(target);
        _controller.SetSystemBackdropConfiguration(configuration);
    }

    protected override void OnTargetDisconnected(ICompositionSupportsSystemBackdrop target)
    {
        base.OnTargetDisconnected(target);
        _controller?.RemoveSystemBackdropTarget(target);
        _controller?.Dispose();
        _controller = null;
    }
}

/// Mica through its controller with a configuration that stays active, so a
/// window that never activates still gets Mica's active look.
internal sealed class ControlledMica : SystemBackdrop
{
    private MicaController? _controller;

    protected override void OnTargetConnected(ICompositionSupportsSystemBackdrop target, XamlRoot xamlRoot)
    {
        base.OnTargetConnected(target, xamlRoot);
        _controller = new MicaController();
        _controller.AddSystemBackdropTarget(target);
        _controller.SetSystemBackdropConfiguration(new SystemBackdropConfiguration { IsInputActive = true, Theme = SystemBackdropTheme.Dark });
    }

    protected override void OnTargetDisconnected(ICompositionSupportsSystemBackdrop target)
    {
        base.OnTargetDisconnected(target);
        _controller?.RemoveSystemBackdropTarget(target);
        _controller?.Dispose();
        _controller = null;
    }
}
