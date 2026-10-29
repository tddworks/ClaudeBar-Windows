using System.Runtime.InteropServices;
using Microsoft.Windows.BadgeNotifications;
using Windows.UI;

namespace ClaudeBar;

/// Your place, as the taskbar shows it: the rank, the board it's on, your
/// tokens, the gap to the place above and each provider's share.
internal sealed record Glance(int? Rank, string Period, long Tokens, string? Gap, IReadOnlyList<(Color Color, long Tokens)> Mix, bool Hidden);

/// The window's taskbar button, the glance by default (design-concept/leaderboard):
/// hovering it shows your place, drawn by the app as the button's thumbnail
/// (`DwmSetIconicThumbnail`), and right-clicking it offers *Upload now*,
/// *Open the board* and *Settings* (a jump list, which works with the app closed).
/// Where Windows allows it, the button also carries your place as a badge.
internal sealed class Taskbar
{
    private readonly IntPtr _window;
    private readonly Win32.SubclassProc _proc;
    private Glance? _glance;
    private bool _dark;
    private Color _accent;
    /// The taskbar button's dot: the worst status of every limit, and its sentence.
    private (string Worst, string Sentence) _dot = ("healthy", "");
    private ITaskbarList3? _list;
    private static readonly uint TaskbarButtonCreated = Win32.RegisterWindowMessageW("TaskbarButtonCreated");

    /// Other messages to the window, for the tray icon: handled when it answers.
    internal Func<uint, IntPtr, IntPtr, bool>? OnMessage;

    internal Taskbar(IntPtr window)
    {
        _window = window;
        _proc = Proc;
        Win32.SetWindowSubclass(window, _proc, (UIntPtr)1, UIntPtr.Zero);
        var on = 1;
        Win32.DwmSetWindowAttribute(window, Win32.DWMWA_FORCE_ICONIC_REPRESENTATION, ref on, sizeof(int));
        Win32.DwmSetWindowAttribute(window, Win32.DWMWA_HAS_ICONIC_BITMAP, ref on, sizeof(int));
    }

    /// The place to show, in the window's theme; the next hover draws it.
    internal void Show(Glance glance, bool dark, Color accent)
    {
        (_glance, _dark, _accent) = (glance, dark, accent);
        Win32.DwmInvalidateIconicBitmaps(_window);
        try
        {
            if (glance.Rank is int rank and <= 99) BadgeNotificationManager.Current.SetBadgeAsCount((uint)rank);
            else BadgeNotificationManager.Current.ClearBadge();
        }
        catch (Exception)
        {
            // Without package identity Windows may refuse a badge; the hover card still shows the place.
        }
    }

    /// The worst status of every limit as a dot on the taskbar button (none,
    /// amber or red), with the worst limit's sentence as its alt text (Task 10).
    /// Windows shows it while the window is open or minimized, not with small
    /// taskbar icons; it's set again when Explorer makes the button again.
    internal void ShowWorst(string worst, string sentence)
    {
        _dot = (worst, sentence);
        ApplyDot();
    }

    private void ApplyDot()
    {
        try
        {
            if (_list is null)
            {
                _list = (ITaskbarList3)Activator.CreateInstance(Type.GetTypeFromCLSID(new Guid("56FDF344-FD6D-11D0-958A-006097C9A090"))!)!;
                _list.HrInit();
            }
            var color = _dot.Worst switch
            {
                "warning" => Color.FromArgb(255, 0xFC, 0xE1, 0x00),
                "critical" or "depleted" => Color.FromArgb(255, 0xE8, 0x11, 0x23),
                _ => (Color?)null,
            };
            var icon = color is { } fill ? Dot(fill, (int)Math.Round(16 * Win32.GetDpiForWindow(_window) / 96.0)) : IntPtr.Zero;
            _list.SetOverlayIcon(_window, icon, color is null ? null : _dot.Sentence);
            if (icon != IntPtr.Zero) Win32.DestroyIcon(icon);
        }
        catch (Exception)
        {
            // The dot is a glance; the HUD and the window show every limit.
        }
    }

    /// A filled circle `size` pixels across, edged so it reads on a light or a dark taskbar.
    private static IntPtr Dot(Color fill, int size)
    {
        var info = new Win32.BITMAPINFOHEADER { Size = 40, Width = size, Height = -size, Planes = 1, BitCount = 32 };
        var color = Win32.CreateDIBSection(IntPtr.Zero, ref info, 0, out var bits, IntPtr.Zero, 0);
        if (color == IntPtr.Zero) return IntPtr.Zero;
        var pixels = new int[size * size];
        var centre = (size - 1) / 2.0;
        var radius = size / 2.0 - 0.5;
        for (var y = 0; y < size; y++)
        {
            for (var x = 0; x < size; x++)
            {
                var distance = Math.Sqrt((x - centre) * (x - centre) + (y - centre) * (y - centre));
                var cover = Math.Clamp(radius - distance + 0.5, 0, 1);
                if (cover <= 0) continue;
                // The outer pixel darkened: a one-pixel edge.
                var edge = Math.Clamp(distance - (radius - 1.2), 0, 1) * 0.45;
                var r = (byte)(fill.R * (1 - edge));
                var g = (byte)(fill.G * (1 - edge));
                var b = (byte)(fill.B * (1 - edge));
                var a = (byte)(255 * cover);
                // Premultiplied, as a 32-bit icon's colour bitmap is.
                pixels[y * size + x] = (a << 24) | ((r * a / 255) << 16) | ((g * a / 255) << 8) | (b * a / 255);
            }
        }
        Marshal.Copy(pixels, 0, bits, pixels.Length);
        var mask = Win32.CreateBitmap(size, size, 1, 1, IntPtr.Zero);
        var iconInfo = new Win32.ICONINFO { IsIcon = true, Mask = mask, Color = color };
        var icon = Win32.CreateIconIndirect(ref iconInfo);
        Win32.DeleteObject(mask);
        Win32.DeleteObject(color);
        return icon;
    }

    internal void Clear()
    {
        _glance = null;
        Win32.DwmInvalidateIconicBitmaps(_window);
        try { BadgeNotificationManager.Current.ClearBadge(); } catch (Exception) { }
    }

    private IntPtr Proc(IntPtr window, uint message, IntPtr wParam, IntPtr lParam, UIntPtr id, UIntPtr data)
    {
        if (message == TaskbarButtonCreated && TaskbarButtonCreated != 0)
        {
            // Explorer restarted, or the button was made again: the dot is gone with the old one.
            _list = null;
            ApplyDot();
        }
        switch (message)
        {
            case Win32.WM_DWMSENDICONICTHUMBNAIL:
            {
                // The largest size the taskbar asks for, as unsigned words; drawn no larger.
                var width = Math.Clamp((int)(((long)lParam >> 16) & 0xFFFF), 1, 1024);
                var height = Math.Clamp(Math.Min((int)((long)lParam & 0xFFFF), (int)(width * 0.56)), 1, 1024);
                var bitmap = Draw(width, height);
                if (bitmap != IntPtr.Zero)
                {
                    Win32.DwmSetIconicThumbnail(window, bitmap, 0);
                    Win32.DeleteObject(bitmap);
                }
                return IntPtr.Zero;
            }
            case Win32.WM_DWMSENDICONICLIVEPREVIEWBITMAP:
            {
                Win32.GetClientRect(window, out var client);
                var bitmap = Draw(Math.Clamp(client.Right, 1, 8192), Math.Clamp(client.Bottom, 1, 8192));
                if (bitmap != IntPtr.Zero)
                {
                    Win32.DwmSetIconicLivePreviewBitmap(window, bitmap, IntPtr.Zero, 0);
                    Win32.DeleteObject(bitmap);
                }
                return IntPtr.Zero;
            }
        }
        if (OnMessage?.Invoke(message, wParam, lParam) == true) return IntPtr.Zero;
        return Win32.DefSubclassProc(window, message, wParam, lParam);
    }

    /// The hover card: your place large, the board under it, then tokens, the
    /// gap and the mix; `IntPtr.Zero` when the bitmap couldn't be made.
    private IntPtr Draw(int width, int height)
    {
        var info = new Win32.BITMAPINFOHEADER { Size = 40, Width = width, Height = -height, Planes = 1, BitCount = 32 };
        var bitmap = Win32.CreateDIBSection(IntPtr.Zero, ref info, 0, out var bits, IntPtr.Zero, 0);
        if (bitmap == IntPtr.Zero || bits == IntPtr.Zero)
        {
            if (bitmap != IntPtr.Zero) Win32.DeleteObject(bitmap);
            return IntPtr.Zero;
        }
        var dc = Win32.CreateCompatibleDC(IntPtr.Zero);
        var old = Win32.SelectObject(dc, bitmap);
        var background = _dark ? Color.FromArgb(255, 0x20, 0x20, 0x20) : Color.FromArgb(255, 0xF3, 0xF3, 0xF3);
        var text = _dark ? Color.FromArgb(255, 0xFF, 0xFF, 0xFF) : Color.FromArgb(255, 0x1A, 0x1A, 0x1A);
        var muted = _dark ? Color.FromArgb(255, 0x9A, 0x9A, 0x9A) : Color.FromArgb(255, 0x6B, 0x6B, 0x6B);
        Fill(dc, 0, 0, width, height, background);
        Win32.SetBkMode(dc, 1 /* TRANSPARENT */);
        var pad = Math.Max(8, height / 9);
        var glance = _glance;
        var big = (int)(height * 0.34);
        var small = Math.Max(11, (int)(height * 0.1));
        var rankText = glance?.Rank is int rank ? $"#{rank}" : "–";
        var rankWidth = Text(dc, rankText, pad, pad, width - 2 * pad, big, 600, "Segoe UI Variable Display", glance?.Rank is null ? muted : _accent);
        Text(dc, glance is null ? "Leaderboard" : glance.Period, pad + rankWidth + small / 2, pad + big - (int)(small * 1.6), width, small, 400, "Segoe UI Variable Text", muted);
        var line = glance switch
        {
            null => "Open ClaudeBar to see your place",
            { Rank: null } => "Not on this board yet",
            _ => $"{MainWindow.Tokens(glance.Tokens)} tokens" + (glance.Gap is null ? "" : $" · {glance.Gap}") + (glance.Hidden ? " · hidden" : ""),
        };
        var lineTop = pad + big + small / 2;
        Text(dc, line, pad, lineTop, width - 2 * pad, small, 400, "Segoe UI Variable Text", text);
        if (glance is { Mix.Count: > 0 })
        {
            var barTop = lineTop + (int)(small * 1.8);
            var barHeight = Math.Max(3, height / 30);
            var total = glance.Mix.Sum(part => part.Tokens);
            var x = (double)pad;
            var span = width - 2 * pad - 2 * (glance.Mix.Count - 1);
            foreach (var (color, tokens) in glance.Mix)
            {
                var length = span * tokens / (double)Math.Max(1, total);
                Fill(dc, (int)x, barTop, (int)(x + length), barTop + barHeight, color);
                x += length + 2;
            }
        }
        Win32.SelectObject(dc, old);
        Win32.DeleteDC(dc);
        // GDI leaves alpha at 0 where it drew; the card is opaque.
        var pixels = new int[width * height];
        Marshal.Copy(bits, pixels, 0, pixels.Length);
        for (var index = 0; index < pixels.Length; index++) pixels[index] |= unchecked((int)0xFF000000);
        Marshal.Copy(pixels, 0, bits, pixels.Length);
        return bitmap;
    }

    private static void Fill(IntPtr dc, int left, int top, int right, int bottom, Color color)
    {
        var rect = new Win32.RECT { Left = left, Top = top, Right = right, Bottom = bottom };
        var brush = Win32.CreateSolidBrush(Win32.ColorRef(color));
        Win32.FillRect(dc, ref rect, brush);
        Win32.DeleteObject(brush);
    }

    /// Draws one line and answers its width.
    private static int Text(IntPtr dc, string text, int left, int top, int width, int size, int weight, string face, Color color)
    {
        var font = Win32.CreateFontW(-size, 0, 0, 0, weight, 0, 0, 0, 1, 0, 0, 5 /* CLEARTYPE_QUALITY */, 0, face);
        var old = Win32.SelectObject(dc, font);
        Win32.SetTextColor(dc, Win32.ColorRef(color));
        var measure = new Win32.RECT { Left = left, Top = top, Right = left + width, Bottom = top + size * 2 };
        Win32.DrawTextW(dc, text, -1, ref measure, 0x20 | 0x800 | 0x400 /* SINGLELINE | NOPREFIX | CALCRECT */);
        var rect = new Win32.RECT { Left = left, Top = top, Right = left + width, Bottom = top + size * 2 };
        Win32.DrawTextW(dc, text, -1, ref rect, 0x20 | 0x800 | 0x8000 /* SINGLELINE | NOPREFIX | END_ELLIPSIS */);
        Win32.SelectObject(dc, old);
        Win32.DeleteObject(font);
        return measure.Right - measure.Left;
    }

    /// Right-click on the taskbar button: its tasks, run through this app's one
    /// instance, which hands them to the open window or opens one.
    internal static void SetJumpList()
    {
        try
        {
            var exe = Environment.ProcessPath!;
            var list = (ICustomDestinationList)Activator.CreateInstance(Type.GetTypeFromCLSID(new Guid("77F10CF0-3DB5-4966-B520-B7C54FD35ED6"))!)!;
            var arrayId = typeof(IObjectArray).GUID;
            list.BeginList(out _, ref arrayId, out _);
            var tasks = (IObjectCollection)Activator.CreateInstance(Type.GetTypeFromCLSID(new Guid("2D3468C1-36A7-43B6-AC24-D3F02FD9607A"))!)!;
            tasks.AddObject(Link(exe, "--hud", "Show the HUD"));
            tasks.AddObject(Link(exe, "--refresh", "Refresh now"));
            tasks.AddObject(Link(exe, "--board", "Leaderboard"));
            tasks.AddObject(Link(exe, "--upload", "Upload now"));
            tasks.AddObject(Link(exe, "--settings", "Settings"));
            list.AddUserTasks((IObjectArray)tasks);
            list.CommitList();
        }
        catch (COMException)
        {
            // A jump list is a convenience; the window has every action.
        }
    }

    private static IShellLinkW Link(string exe, string arguments, string title)
    {
        var link = (IShellLinkW)Activator.CreateInstance(Type.GetTypeFromCLSID(new Guid("00021401-0000-0000-C000-000000000046"))!)!;
        link.SetPath(exe);
        link.SetArguments(arguments);
        link.SetIconLocation(exe, 0);
        var store = (IPropertyStore)link;
        var key = PropertyKey.Title;
        var value = PropVariant.FromString(title);
        store.SetValue(ref key, ref value);
        store.Commit();
        Marshal.FreeCoTaskMem(value.Pointer);
        return link;
    }
}
