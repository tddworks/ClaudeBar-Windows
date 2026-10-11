using System.Runtime.InteropServices;
using System.Text.Json;
using System.Text.Json.Nodes;
using Microsoft.UI;
using Microsoft.UI.Text;
using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Shapes;
using Windows.Graphics;
using Windows.UI;

namespace ClaudeBar;

/// What the app itself remembers, apart from the membership (which ClaudeBar's
/// package keeps in settings.json): `%LOCALAPPDATA%\ClaudeBar\app.json`.
internal static class Preferences
{
    private static string File => System.IO.Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "ClaudeBar", "app.json");

    /// The tray icon, an option, off by default (design-concept/leaderboard).
    internal static bool TrayIcon
    {
        get => Read()?["trayIcon"]?.GetValue<bool>() == true;
        set
        {
            var contents = Read() ?? new JsonObject();
            contents["trayIcon"] = value;
            System.IO.Directory.CreateDirectory(System.IO.Path.GetDirectoryName(File)!);
            System.IO.File.WriteAllText(File, contents.ToJsonString(new JsonSerializerOptions { WriteIndented = true }));
        }
    }

    private static JsonObject? Read()
    {
        try { return JsonNode.Parse(System.IO.File.ReadAllText(File)) as JsonObject; }
        catch (Exception) { return null; }
    }
}

/// The tray icon, for people who want one: a click opens a small flyout with
/// your place; right-click offers Open, Upload now and Quit. While it's on,
/// closing the window keeps ClaudeBar in the tray.
internal sealed class Tray : IDisposable
{
    private const uint Id = 1;
    private readonly IntPtr _window;
    private readonly IntPtr _icon;
    private bool _added;

    internal Action? OpenWindow;
    internal Action? OpenFlyout;
    internal Action? UploadNow;
    internal Action? Quit;

    internal Tray(IntPtr window)
    {
        _window = window;
        var dpi = Win32.GetDpiForWindow(window);
        var size = (int)(16 * dpi / 96.0);
        _icon = Win32.LoadImageW(IntPtr.Zero, System.IO.Path.Combine(AppContext.BaseDirectory, "Assets", "ClaudeBar.ico"), Win32.IMAGE_ICON, size, size, Win32.LR_LOADFROMFILE);
    }

    internal bool IsShown => _added;

    internal void Show()
    {
        if (_added) return;
        var data = Data();
        _added = Win32.Shell_NotifyIconW(Win32.NIM_ADD, ref data);
        data.VersionOrTimeout = Win32.NOTIFYICON_VERSION_4;
        Win32.Shell_NotifyIconW(Win32.NIM_SETVERSION, ref data);
    }

    internal void Hide()
    {
        if (!_added) return;
        var data = Data();
        Win32.Shell_NotifyIconW(Win32.NIM_DELETE, ref data);
        _added = false;
    }

    /// Where the icon is on screen, in physical pixels; the flyout opens above it.
    internal Win32.RECT? Bounds()
    {
        var identifier = new Win32.NOTIFYICONIDENTIFIER { Size = (uint)Marshal.SizeOf<Win32.NOTIFYICONIDENTIFIER>(), Window = _window, Id = Id };
        return Win32.Shell_NotifyIconGetRect(ref identifier, out var rect) == 0 ? rect : null;
    }

    /// The window's messages from the icon: answers whether it handled one.
    internal bool Handle(uint message, IntPtr wParam, IntPtr lParam)
    {
        if (message != Win32.WM_APP_TRAY) return false;
        switch ((uint)Win32.LowWord(lParam))
        {
            case Win32.NIN_SELECT:
            case Win32.NIN_KEYSELECT:
                OpenFlyout?.Invoke();
                break;
            case Win32.WM_CONTEXTMENU:
                Menu(Win32.LowWord(wParam), Win32.HighWord(wParam));
                break;
        }
        return true;
    }

    private void Menu(int x, int y)
    {
        var menu = Win32.CreatePopupMenu();
        Win32.AppendMenuW(menu, Win32.MF_STRING, (UIntPtr)1, "Open ClaudeBar");
        Win32.AppendMenuW(menu, Win32.MF_STRING, (UIntPtr)2, "Upload now");
        Win32.AppendMenuW(menu, Win32.MF_SEPARATOR, UIntPtr.Zero, null);
        Win32.AppendMenuW(menu, Win32.MF_STRING, (UIntPtr)3, "Quit ClaudeBar");
        Win32.SetForegroundWindow(_window);
        var choice = Win32.TrackPopupMenuEx(menu, Win32.TPM_RETURNCMD | Win32.TPM_RIGHTBUTTON | Win32.TPM_BOTTOMALIGN, x, y, _window, IntPtr.Zero);
        Win32.DestroyMenu(menu);
        switch (choice)
        {
            case 1: OpenWindow?.Invoke(); break;
            case 2: UploadNow?.Invoke(); break;
            case 3: Quit?.Invoke(); break;
        }
    }

    private Win32.NOTIFYICONDATAW Data() => new()
    {
        Size = (uint)Marshal.SizeOf<Win32.NOTIFYICONDATAW>(),
        Window = _window,
        Id = Id,
        Flags = Win32.NIF_MESSAGE | Win32.NIF_ICON | Win32.NIF_TIP | Win32.NIF_SHOWTIP,
        CallbackMessage = Win32.WM_APP_TRAY,
        Icon = _icon,
        Tip = "ClaudeBar",
        Info = "",
        InfoTitle = "",
    };

    public void Dispose()
    {
        Hide();
        if (_icon != IntPtr.Zero) Win32.DestroyIcon(_icon);
    }
}

/// The tray icon's flyout: Acrylic, above the icon, your place and the places
/// above you, with Open ClaudeBar. It closes when it loses focus.
internal sealed class TrayFlyout
{
    private readonly Window _window = new();
    private readonly StackPanel _body = new() { Spacing = 10 };
    internal Action? OpenWindow;
    internal Action? OpenSettings;

    internal TrayFlyout()
    {
        _window.SystemBackdrop = new DesktopAcrylicBackdrop();
        _window.AppWindow.SetPresenter(OverlappedPresenter.CreateForContextMenu());
        _window.AppWindow.IsShownInSwitchers = false;
        _window.Title = "ClaudeBar";
        _window.Content = new Grid { Padding = new Thickness(14), Children = { _body } };
        _window.Activated += (_, e) =>
        {
            if (e.WindowActivationState == WindowActivationState.Deactivated) _window.AppWindow.Hide();
        };
    }

    internal void Close() => _window.Close();

    /// Opens above `anchor` (the tray icon, physical pixels), inside the work area.
    internal void Open(Win32.RECT? anchor, FrameworkElement content)
    {
        _body.Children.Clear();
        _body.Children.Add(content);
        var footer = new Grid { ColumnSpacing = 8 };
        footer.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        footer.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        var open = new Button { Content = "Open ClaudeBar", HorizontalAlignment = HorizontalAlignment.Stretch };
        open.Click += (_, _) => { _window.AppWindow.Hide(); OpenWindow?.Invoke(); };
        var settings = new Button { Content = new FontIcon { Glyph = "\uE713", FontSize = 14 }, Width = 36 };
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(settings, "Settings");
        settings.Click += (_, _) => { _window.AppWindow.Hide(); OpenSettings?.Invoke(); };
        Grid.SetColumn(settings, 1);
        footer.Children.Add(open);
        footer.Children.Add(settings);
        _body.Children.Add(footer);

        var display = DisplayArea.GetFromWindowId(_window.AppWindow.Id, DisplayAreaFallback.Primary);
        var scale = Win32.GetDpiForWindow(WinRT.Interop.WindowNative.GetWindowHandle(_window)) / 96.0;
        var width = (int)(340 * scale);
        var height = (int)(400 * scale);
        var work = display.WorkArea;
        var right = anchor is { } icon ? Math.Min(icon.Right + width / 3, work.X + work.Width) : work.X + work.Width;
        var x = Math.Max(work.X, right - width - (int)(12 * scale));
        var y = work.Y + work.Height - height - (int)(12 * scale);
        _window.AppWindow.MoveAndResize(new RectInt32(x, y, width, height));
        _window.AppWindow.Show();
        _window.Activate();
    }
}
