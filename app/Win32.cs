using System.Runtime.InteropServices;

namespace ClaudeBar;

/// The Win32 calls the taskbar glance, the tray icon and the HUD need, which
/// WinUI doesn't wrap: window subclassing, DWM's iconic thumbnails, GDI to draw
/// them, the notification area, a popup menu, the jump list's COM objects, and
/// the HUD's window styles and the foreground window.
internal static class Win32
{
    internal delegate IntPtr SubclassProc(IntPtr window, uint message, IntPtr wParam, IntPtr lParam, UIntPtr id, UIntPtr data);

    [DllImport("comctl32.dll")] internal static extern bool SetWindowSubclass(IntPtr window, SubclassProc proc, UIntPtr id, UIntPtr data);
    [DllImport("comctl32.dll")] internal static extern IntPtr DefSubclassProc(IntPtr window, uint message, IntPtr wParam, IntPtr lParam);

    internal const uint WM_DWMSENDICONICTHUMBNAIL = 0x0323;
    internal const uint WM_DWMSENDICONICLIVEPREVIEWBITMAP = 0x0326;
    internal const uint WM_COMMAND = 0x0111;
    internal const uint WM_APP_TRAY = 0x8000 + 1;
    internal const int DWMWA_FORCE_ICONIC_REPRESENTATION = 7;
    internal const int DWMWA_HAS_ICONIC_BITMAP = 10;

    [DllImport("dwmapi.dll")] internal static extern int DwmSetWindowAttribute(IntPtr window, int attribute, ref int value, int size);
    [DllImport("dwmapi.dll")] internal static extern int DwmSetIconicThumbnail(IntPtr window, IntPtr bitmap, uint flags);
    [DllImport("dwmapi.dll")] internal static extern int DwmSetIconicLivePreviewBitmap(IntPtr window, IntPtr bitmap, IntPtr offset, uint flags);
    [DllImport("dwmapi.dll")] internal static extern int DwmInvalidateIconicBitmaps(IntPtr window);

    [StructLayout(LayoutKind.Sequential)]
    internal struct BITMAPINFOHEADER
    {
        public uint Size; public int Width; public int Height; public ushort Planes; public ushort BitCount;
        public uint Compression; public uint SizeImage; public int XPelsPerMeter; public int YPelsPerMeter;
        public uint ClrUsed; public uint ClrImportant;
    }

    [StructLayout(LayoutKind.Sequential)]
    internal struct RECT { public int Left, Top, Right, Bottom; }

    [StructLayout(LayoutKind.Sequential)]
    internal struct POINT { public int X, Y; }

    [DllImport("gdi32.dll")] internal static extern IntPtr CreateDIBSection(IntPtr dc, ref BITMAPINFOHEADER info, uint usage, out IntPtr bits, IntPtr section, uint offset);
    [DllImport("gdi32.dll")] internal static extern IntPtr CreateCompatibleDC(IntPtr dc);
    [DllImport("gdi32.dll")] internal static extern IntPtr SelectObject(IntPtr dc, IntPtr gdiObject);
    [DllImport("gdi32.dll")] internal static extern bool DeleteObject(IntPtr gdiObject);
    [DllImport("gdi32.dll")] internal static extern bool DeleteDC(IntPtr dc);
    [DllImport("gdi32.dll")] internal static extern IntPtr CreateSolidBrush(uint color);
    [DllImport("gdi32.dll")] internal static extern int SetBkMode(IntPtr dc, int mode);
    [DllImport("gdi32.dll")] internal static extern uint SetTextColor(IntPtr dc, uint color);
    [DllImport("gdi32.dll", CharSet = CharSet.Unicode)]
    internal static extern IntPtr CreateFontW(int height, int width, int escapement, int orientation, int weight, uint italic, uint underline,
                                              uint strikeOut, uint charSet, uint outPrecision, uint clipPrecision, uint quality, uint pitchAndFamily, string face);
    [DllImport("user32.dll")] internal static extern int FillRect(IntPtr dc, ref RECT rect, IntPtr brush);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] internal static extern int DrawTextW(IntPtr dc, string text, int length, ref RECT rect, uint format);
    [DllImport("user32.dll")] internal static extern uint GetDpiForWindow(IntPtr window);
    [DllImport("user32.dll")] internal static extern bool GetClientRect(IntPtr window, out RECT rect);

    // The notification area.
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    internal struct NOTIFYICONDATAW
    {
        public uint Size; public IntPtr Window; public uint Id; public uint Flags; public uint CallbackMessage; public IntPtr Icon;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string Tip;
        public uint State; public uint StateMask;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 256)] public string Info;
        public uint VersionOrTimeout;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 64)] public string InfoTitle;
        public uint InfoFlags; public Guid Item; public IntPtr BalloonIcon;
    }

    [StructLayout(LayoutKind.Sequential)]
    internal struct NOTIFYICONIDENTIFIER { public uint Size; public IntPtr Window; public uint Id; public Guid Item; }

    internal const uint NIM_ADD = 0, NIM_DELETE = 2, NIM_SETVERSION = 4;
    internal const uint NIF_MESSAGE = 1, NIF_ICON = 2, NIF_TIP = 4, NIF_SHOWTIP = 0x80;
    internal const uint NOTIFYICON_VERSION_4 = 4;
    internal const uint NIN_SELECT = 0x400, NIN_KEYSELECT = 0x401, WM_CONTEXTMENU = 0x7B;

    [DllImport("shell32.dll", CharSet = CharSet.Unicode)] internal static extern bool Shell_NotifyIconW(uint message, ref NOTIFYICONDATAW data);
    [DllImport("shell32.dll")] internal static extern int Shell_NotifyIconGetRect(ref NOTIFYICONIDENTIFIER identifier, out RECT rect);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    internal static extern IntPtr LoadImageW(IntPtr instance, string name, uint type, int width, int height, uint flags);
    [DllImport("user32.dll")] internal static extern bool DestroyIcon(IntPtr icon);
    internal const uint IMAGE_ICON = 1, LR_LOADFROMFILE = 0x10;

    [DllImport("user32.dll")] internal static extern IntPtr CreatePopupMenu();
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] internal static extern bool AppendMenuW(IntPtr menu, uint flags, UIntPtr id, string? text);
    [DllImport("user32.dll")] internal static extern int TrackPopupMenuEx(IntPtr menu, uint flags, int x, int y, IntPtr window, IntPtr parameters);
    [DllImport("user32.dll")] internal static extern bool DestroyMenu(IntPtr menu);
    [DllImport("user32.dll")] internal static extern bool SetForegroundWindow(IntPtr window);
    [DllImport("user32.dll")] internal static extern bool GetCursorPos(out POINT point);
    internal const uint MF_STRING = 0, MF_SEPARATOR = 0x800, TPM_RETURNCMD = 0x100, TPM_RIGHTBUTTON = 2, TPM_BOTTOMALIGN = 0x20;

    // The HUD: the foreground window, and handing it back after a click.
    internal delegate void WinEventProc(IntPtr hook, uint eventType, IntPtr window, int objectId, int childId, uint thread, uint time);
    [DllImport("user32.dll")] internal static extern IntPtr SetWinEventHook(uint min, uint max, IntPtr module, WinEventProc proc, uint process, uint thread, uint flags);
    [DllImport("user32.dll")] internal static extern bool UnhookWinEvent(IntPtr hook);
    [DllImport("user32.dll")] internal static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] internal static extern uint GetWindowThreadProcessId(IntPtr window, out uint process);
    [DllImport("user32.dll")] internal static extern bool IsWindow(IntPtr window);
    internal const uint EVENT_SYSTEM_FOREGROUND = 0x0003, WINEVENT_OUTOFCONTEXT = 0;

    // The HUD's window: its styles, where the foreground window is, and whether it's full screen.
    [DllImport("user32.dll")] internal static extern IntPtr GetWindowLongPtrW(IntPtr window, int index);
    [DllImport("user32.dll")] internal static extern IntPtr SetWindowLongPtrW(IntPtr window, int index, IntPtr value);
    [DllImport("user32.dll")] internal static extern bool GetWindowRect(IntPtr window, out RECT rect);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] internal static extern int GetClassNameW(IntPtr window, System.Text.StringBuilder name, int size);
    [DllImport("shell32.dll")] internal static extern int SHQueryUserNotificationState(out int state);
    internal const int GWL_EXSTYLE = -20;
    internal const long WS_EX_NOACTIVATE = 0x08000000L, WS_EX_TOOLWINDOW = 0x00000080L;
    internal const int DWMWA_WINDOW_CORNER_PREFERENCE = 33, DWMWCP_ROUND = 2, DWMWA_EXTENDED_FRAME_BOUNDS = 9;
    [DllImport("dwmapi.dll")] internal static extern int DwmGetWindowAttribute(IntPtr window, int attribute, out RECT value, int size);
    [DllImport("user32.dll")] internal static extern bool ClientToScreen(IntPtr window, ref POINT point);
    internal const int QUNS_PRESENTATION_MODE = 4;
    internal const uint WM_ENTERSIZEMOVE = 0x0231, WM_EXITSIZEMOVE = 0x0232, WM_DPICHANGED = 0x02E0, WM_DISPLAYCHANGE = 0x007E, WM_SETTINGCHANGE = 0x001A;
    // The HUD: whether the pointer rests on it, and how far a press moves before it drags.
    [DllImport("user32.dll")] internal static extern IntPtr WindowFromPoint(POINT point);
    [DllImport("user32.dll")] internal static extern IntPtr GetAncestor(IntPtr window, uint flags);
    internal const uint GA_ROOT = 2;
    [DllImport("user32.dll")] internal static extern int GetSystemMetricsForDpi(int index, uint dpi);
    internal const int SM_CXDRAG = 68, SM_CYDRAG = 69;
    // A press on the HUD, followed until the primary button is up: the left one, or the right when swapped.
    [DllImport("user32.dll")] internal static extern int GetSystemMetrics(int index);
    [DllImport("user32.dll")] internal static extern short GetAsyncKeyState(int key);
    internal const int SM_SWAPBUTTON = 23, VK_LBUTTON = 1, VK_RBUTTON = 2;

    // The taskbar button's dot (an icon made from a bitmap) and the HUD's shortcut.
    [StructLayout(LayoutKind.Sequential)]
    internal struct ICONINFO { [MarshalAs(UnmanagedType.Bool)] public bool IsIcon; public int HotspotX; public int HotspotY; public IntPtr Mask; public IntPtr Color; }
    [DllImport("user32.dll")] internal static extern IntPtr CreateIconIndirect(ref ICONINFO info);
    [DllImport("gdi32.dll")] internal static extern IntPtr CreateBitmap(int width, int height, uint planes, uint bitCount, IntPtr bits);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] internal static extern uint RegisterWindowMessageW(string name);
    [DllImport("user32.dll")] internal static extern bool RegisterHotKey(IntPtr window, int id, uint modifiers, uint key);
    [DllImport("user32.dll")] internal static extern bool UnregisterHotKey(IntPtr window, int id);
    internal const uint WM_HOTKEY = 0x0312, MOD_ALT = 1, MOD_CONTROL = 2, MOD_SHIFT = 4, MOD_WIN = 8, MOD_NOREPEAT = 0x4000;

    internal static uint ColorRef(Windows.UI.Color color) => (uint)(color.R | (color.G << 8) | (color.B << 16));

    internal static int LowWord(IntPtr value) => (short)((long)value & 0xFFFF);
    internal static int HighWord(IntPtr value) => (short)(((long)value >> 16) & 0xFFFF);
}

// MARK: - The taskbar button's overlay icon

[ComImport, Guid("EA1AFB91-9E28-4B86-90E9-9E9F8A5EEFAF"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
internal interface ITaskbarList3
{
    // ITaskbarList
    void HrInit();
    void AddTab(IntPtr window);
    void DeleteTab(IntPtr window);
    void ActivateTab(IntPtr window);
    void SetActiveAlt(IntPtr window);
    // ITaskbarList2
    void MarkFullscreenWindow(IntPtr window, [MarshalAs(UnmanagedType.Bool)] bool fullscreen);
    // ITaskbarList3
    void SetProgressValue(IntPtr window, ulong completed, ulong total);
    void SetProgressState(IntPtr window, int flags);
    void RegisterTab(IntPtr tab, IntPtr window);
    void UnregisterTab(IntPtr tab);
    void SetTabOrder(IntPtr tab, IntPtr insertBefore);
    void SetTabActive(IntPtr tab, IntPtr window, uint reserved);
    void ThumbBarAddButtons(IntPtr window, uint count, IntPtr buttons);
    void ThumbBarUpdateButtons(IntPtr window, uint count, IntPtr buttons);
    void ThumbBarSetImageList(IntPtr window, IntPtr images);
    void SetOverlayIcon(IntPtr window, IntPtr icon, [MarshalAs(UnmanagedType.LPWStr)] string? description);
    void SetThumbnailTooltip(IntPtr window, [MarshalAs(UnmanagedType.LPWStr)] string? tip);
    void SetThumbnailClip(IntPtr window, IntPtr clip);
}

// MARK: - The jump list's COM objects

[ComImport, Guid("6332DEBF-87B5-4670-90C0-5E57B408A49E"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
internal interface ICustomDestinationList
{
    void SetAppID([MarshalAs(UnmanagedType.LPWStr)] string appId);
    void BeginList(out uint minSlots, ref Guid riid, [MarshalAs(UnmanagedType.Interface)] out object removed);
    void AppendCategory([MarshalAs(UnmanagedType.LPWStr)] string category, [MarshalAs(UnmanagedType.Interface)] IObjectArray items);
    void AppendKnownCategory(int category);
    void AddUserTasks([MarshalAs(UnmanagedType.Interface)] IObjectArray tasks);
    void CommitList();
    void GetRemovedDestinations(ref Guid riid, [MarshalAs(UnmanagedType.Interface)] out object removed);
    void DeleteList([MarshalAs(UnmanagedType.LPWStr)] string? appId);
    void AbortList();
}

[ComImport, Guid("92CA9DCD-5622-4BBA-A805-5E9F541BD8C9"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
internal interface IObjectArray
{
    void GetCount(out uint count);
    void GetAt(uint index, ref Guid riid, [MarshalAs(UnmanagedType.Interface)] out object item);
}

[ComImport, Guid("5632B1A4-E38A-400A-928A-D4CD63230295"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
internal interface IObjectCollection
{
    void GetCount(out uint count);
    void GetAt(uint index, ref Guid riid, [MarshalAs(UnmanagedType.Interface)] out object item);
    void AddObject([MarshalAs(UnmanagedType.Interface)] object item);
    void AddFromArray([MarshalAs(UnmanagedType.Interface)] IObjectArray items);
    void RemoveObjectAt(uint index);
    void Clear();
}

[ComImport, Guid("000214F9-0000-0000-C000-000000000046"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
internal interface IShellLinkW
{
    void GetPath(IntPtr file, int size, IntPtr data, uint flags);
    void GetIDList(out IntPtr list);
    void SetIDList(IntPtr list);
    void GetDescription(IntPtr name, int size);
    void SetDescription([MarshalAs(UnmanagedType.LPWStr)] string name);
    void GetWorkingDirectory(IntPtr dir, int size);
    void SetWorkingDirectory([MarshalAs(UnmanagedType.LPWStr)] string dir);
    void GetArguments(IntPtr args, int size);
    void SetArguments([MarshalAs(UnmanagedType.LPWStr)] string args);
    void GetHotkey(out ushort hotkey);
    void SetHotkey(ushort hotkey);
    void GetShowCmd(out int show);
    void SetShowCmd(int show);
    void GetIconLocation(IntPtr path, int size, out int icon);
    void SetIconLocation([MarshalAs(UnmanagedType.LPWStr)] string path, int icon);
    void SetRelativePath([MarshalAs(UnmanagedType.LPWStr)] string path, uint reserved);
    void Resolve(IntPtr window, uint flags);
    void SetPath([MarshalAs(UnmanagedType.LPWStr)] string file);
}

[ComImport, Guid("886D8EEB-8CF2-4446-8D02-CDBA1DBDCF99"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
internal interface IPropertyStore
{
    void GetCount(out uint count);
    void GetAt(uint index, out PropertyKey key);
    void GetValue(ref PropertyKey key, out PropVariant value);
    void SetValue(ref PropertyKey key, ref PropVariant value);
    void Commit();
}

[StructLayout(LayoutKind.Sequential, Pack = 4)]
internal struct PropertyKey
{
    public Guid FormatId;
    public uint PropertyId;
    /// The title a jump list shows for a task.
    internal static PropertyKey Title => new() { FormatId = new Guid("F29F85E0-4FF9-1068-AB91-08002B27B3D9"), PropertyId = 2 };
}

[StructLayout(LayoutKind.Explicit, Size = 16)]
internal struct PropVariant
{
    [FieldOffset(0)] public ushort Type;
    [FieldOffset(8)] public IntPtr Pointer;

    internal static PropVariant FromString(string text) => new() { Type = 31 /* VT_LPWSTR */, Pointer = Marshal.StringToCoTaskMemUni(text) };
}
