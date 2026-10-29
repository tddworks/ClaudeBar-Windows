using Microsoft.UI.Input;
using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Windows.Graphics;
using WinRT.Interop;

namespace ClaudeBar;

/// The HUD (docs/plans/2026-10-13-hud-design.md): a borderless tool window,
/// always on top, never activated to show anything, Mica kept active,
/// snapped to a corner of its screen, hidden for full-screen windows.
internal sealed class HudWindow
{
    private const int MarginDip = 12;
    private readonly Window _window = new() { Title = "ClaudeBar HUD" };
    private readonly Grid _root = new();
    private readonly IntPtr _hwnd;
    private readonly ForegroundTracker _foreground;
    private readonly OverlappedPresenter _presenter;
    private readonly DispatcherTimer _watch = new() { Interval = TimeSpan.FromSeconds(1) };
    private readonly Win32.SubclassProc _subclass;
    private double _widthDip = 320;
    private double _heightDip = 200;
    private bool _wanted;
    private bool _hiddenForFullScreen;
    private bool _closing;
    private FrameworkElement[] _captions = Array.Empty<FrameworkElement>();
    private FrameworkElement[] _passthrough = Array.Empty<FrameworkElement>();

    /// Asked to close (Alt+F4 after a click, or the system menu): the HUD hides instead.
    internal Action? CloseRequested;

    /// Its theme changed: Windows' own, or high contrast.
    internal Action? ThemeChanged;

    internal HudWindow(ForegroundTracker foreground)
    {
        _foreground = foreground;
        _window.Content = _root;
        _window.SystemBackdrop = new KeptActiveMica();
        _presenter = OverlappedPresenter.Create();
        _presenter.IsAlwaysOnTop = Preferences.HudOnTop;
        _presenter.IsResizable = false;
        _presenter.IsMaximizable = false;
        _presenter.IsMinimizable = false;
        _presenter.SetBorderAndTitleBar(true, false);
        _window.AppWindow.SetPresenter(_presenter);
        _window.AppWindow.IsShownInSwitchers = false;
        _window.AppWindow.Closing += (_, e) =>
        {
            if (_closing) return;
            e.Cancel = true;
            CloseRequested?.Invoke();
        };

        _hwnd = WindowNative.GetWindowHandle(_window);
        var ex = (long)Win32.GetWindowLongPtrW(_hwnd, Win32.GWL_EXSTYLE);
        Win32.SetWindowLongPtrW(_hwnd, Win32.GWL_EXSTYLE, (IntPtr)(ex | Win32.WS_EX_NOACTIVATE | Win32.WS_EX_TOOLWINDOW));
        var round = Win32.DWMWCP_ROUND;
        Win32.DwmSetWindowAttribute(_hwnd, Win32.DWMWA_WINDOW_CORNER_PREFERENCE, ref round, sizeof(int));

        // Dragged by its caption regions (SetDragRegions); snapped when the drag
        // ends, then the foreground goes back to the person's window, as after a
        // click. Screens, scaling or the taskbar changing put it back in place.
        _subclass = (window, message, wParam, lParam, id, data) =>
        {
            switch (message)
            {
                case Win32.WM_EXITSIZEMOVE:
                    Snap();
                    _foreground.GiveBack();
                    break;
                case Win32.WM_DPICHANGED:
                case Win32.WM_DISPLAYCHANGE:
                case Win32.WM_SETTINGCHANGE:
                    _window.DispatcherQueue.TryEnqueue(() => { if (_wanted) Place(); });
                    break;
            }
            return Win32.DefSubclassProc(window, message, wParam, lParam);
        };
        Win32.SetWindowSubclass(_hwnd, _subclass, (UIntPtr)1, UIntPtr.Zero);
        _watch.Tick += (_, _) => FollowFullScreen();
        _root.SizeChanged += (_, _) => UpdateDragRegions();
        _root.ActualThemeChanged += (_, _) => ThemeChanged?.Invoke();
        // Esc after UI Automation or a click made it active: back to the person's window.
        _root.KeyDown += (_, e) =>
        {
            if (e.Key != Windows.System.VirtualKey.Escape) return;
            e.Handled = true;
            _foreground.GiveBack();
        };
    }

    internal IntPtr Handle => _hwnd;

    internal bool IsShown => _wanted;

    /// The HUD's theme: Windows' own unless set (the check's `--theme`).
    internal ElementTheme Theme
    {
        get => _root.RequestedTheme;
        set => _root.RequestedTheme = value;
    }

    internal ElementTheme ActualTheme => _root.ActualTheme;

    internal XamlRoot? XamlRoot => _root.XamlRoot;

    internal bool OnTop
    {
        set => _presenter.IsAlwaysOnTop = value;
    }

    /// Puts `content` in the HUD, sized to it: `widthDip` wide, or as wide as
    /// it asks when that is null (the strip), and as tall as it asks, up to the
    /// work area less the margins.
    internal void SetContent(FrameworkElement content, double? widthDip)
    {
        _root.Children.Clear();
        _root.Children.Add(content);
        content.Measure(new Windows.Foundation.Size(widthDip ?? double.PositiveInfinity, double.PositiveInfinity));
        _widthDip = Math.Ceiling(widthDip ?? content.DesiredSize.Width);
        _heightDip = Math.Ceiling(content.DesiredSize.Height);
        if (_wanted) Place();
    }

    /// The parts a drag starts from, and the controls inside them that stay clickable.
    internal void SetDragRegions(IEnumerable<FrameworkElement> captions, IEnumerable<FrameworkElement> passthrough)
    {
        _captions = captions.ToArray();
        _passthrough = passthrough.ToArray();
        _window.DispatcherQueue.TryEnqueue(Microsoft.UI.Dispatching.DispatcherQueuePriority.Low, UpdateDragRegions);
    }

    /// Shows it at its corner, without activating it.
    internal void Show()
    {
        _wanted = true;
        _hiddenForFullScreen = false;
        Place();
        _window.AppWindow.Show(false);
        // Again once shown: DWM may not report the frame of a window it isn't drawing.
        Place();
        _watch.Start();
        FollowFullScreen();
    }

    internal void Hide()
    {
        _wanted = false;
        _watch.Stop();
        _window.AppWindow.Hide();
    }

    internal void Close()
    {
        _closing = true;
        _watch.Stop();
        _window.Close();
    }

    /// After any action a click on the HUD runs: the person's window again.
    internal void AfterClick() => _foreground.GiveBack();

    private double Scale => Win32.GetDpiForWindow(_hwnd) / 96.0;

    /// The screen the HUD is on now.
    private DisplayArea Screen => DisplayArea.GetFromWindowId(_window.AppWindow.Id, DisplayAreaFallback.Nearest);

    /// The screen it was snapped to, while it's still connected; else the primary.
    private static DisplayArea Chosen()
    {
        if (Preferences.HudScreen is ulong id)
        {
            // Indexed, not enumerated: enumerating FindAll()'s result throws in C# (the spike).
            var all = DisplayArea.FindAll();
            for (var index = 0; index < all.Count; index++)
                if (all[index].DisplayId.Value == id) return all[index];
        }
        return DisplayArea.Primary;
    }

    /// At its corner of its screen, its frame `MarginDip` in from the work
    /// area's edges, and its content the size it asked for inside the borders.
    private void Place()
    {
        var work = Chosen().WorkArea;
        Win32.GetWindowRect(_hwnd, out var w);
        if (Win32.DwmGetWindowAttribute(_hwnd, Win32.DWMWA_EXTENDED_FRAME_BOUNDS, out var f, System.Runtime.InteropServices.Marshal.SizeOf<Win32.RECT>()) != 0) f = w;
        Win32.GetClientRect(_hwnd, out var c);
        var origin = new Win32.POINT();
        Win32.ClientToScreen(_hwnd, ref origin);
        var box = HudGeometry.Place(Preferences.HudCorner, (int)Math.Ceiling(_widthDip * Scale), (int)Math.Ceiling(_heightDip * Scale),
                                    new Box(work.X, work.Y, work.Width, work.Height), (int)(MarginDip * Scale),
                                    window: new Box(w.Left, w.Top, w.Right - w.Left, w.Bottom - w.Top),
                                    frame: new Box(f.Left, f.Top, f.Right - f.Left, f.Bottom - f.Top),
                                    client: new Box(origin.X, origin.Y, c.Right, c.Bottom));
        _window.AppWindow.MoveAndResize(new RectInt32(box.X, box.Y, box.Width, box.Height));
    }

    /// A drag ended: the nearest corner of the screen it ended on.
    private void Snap()
    {
        var screen = Screen;
        var work = screen.WorkArea;
        var p = _window.AppWindow.Position;
        var s = _window.AppWindow.Size;
        Preferences.HudCorner = HudGeometry.Nearest(new Box(p.X, p.Y, s.Width, s.Height), new Box(work.X, work.Y, work.Width, work.Height));
        Preferences.HudScreen = screen.DisplayId.Value;
        Place();
    }

    private void FollowFullScreen()
    {
        if (!_wanted) return;
        var foreground = Win32.GetForegroundWindow();
        Win32.GetWindowRect(foreground, out var r);
        var name = new System.Text.StringBuilder(64);
        Win32.GetClassNameW(foreground, name, 64);
        var isDesktop = name.ToString() is "Progman" or "WorkerW";
        Win32.SHQueryUserNotificationState(out var state);
        var screen = Screen.OuterBounds;
        var hide = HudGeometry.ShouldHide(new Box(r.Left, r.Top, r.Right - r.Left, r.Bottom - r.Top), isDesktop,
                                          new Box(screen.X, screen.Y, screen.Width, screen.Height), state == Win32.QUNS_PRESENTATION_MODE);
        if (hide == _hiddenForFullScreen) return;
        _hiddenForFullScreen = hide;
        if (hide) _window.AppWindow.Hide(); else _window.AppWindow.Show(false);
    }

    /// The caption regions a drag starts from, in the window's physical pixels,
    /// with the controls inside them passed through so they stay clickable.
    private void UpdateDragRegions()
    {
        if (_root.XamlRoot is null) return;
        var source = InputNonClientPointerSource.GetForWindowId(_window.AppWindow.Id);
        source.SetRegionRects(NonClientRegionKind.Caption, Rects(_captions));
        source.SetRegionRects(NonClientRegionKind.Passthrough, Rects(_passthrough));
    }

    private RectInt32[] Rects(IEnumerable<FrameworkElement> elements)
    {
        var scale = _root.XamlRoot?.RasterizationScale ?? Scale;
        var rects = new List<RectInt32>();
        foreach (var element in elements)
        {
            if (element.XamlRoot is null || element.ActualWidth <= 0 || element.Visibility != Visibility.Visible) continue;
            var bounds = element.TransformToVisual(null).TransformBounds(new Windows.Foundation.Rect(0, 0, element.ActualWidth, element.ActualHeight));
            rects.Add(new RectInt32((int)(bounds.X * scale), (int)(bounds.Y * scale), (int)Math.Ceiling(bounds.Width * scale), (int)Math.Ceiling(bounds.Height * scale)));
        }
        return rects.ToArray();
    }
}
