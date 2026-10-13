# HUD: what Windows does, measured and sourced (2026-10-13)

The facts the HUD design ([index.html](index.html)) stands on. Each one is either measured on a Windows PC with the spike in [`spikes/hud-window`](../../spikes/hud-window) or quoted from Microsoft's documentation, with the link. Anything not yet measured says so.

The research gathered on 2026-10-08 for the first Windows client (UI stacks, every taskbar surface, similar apps, autostart and scheduled uploads) was lost with a temporary folder. What of it the HUD needs is re-established here. The rest isn't needed again: the UI stack was decided in [#2](https://github.com/tddworks/ClaudeBar-Windows/issues/2) with its prototype's results on the `spike/ui-stack-b` branch, the tray icon stays an option, and the hourly upload is built (#4).

## Measured on the PC

Windows 11 25H2, build 26200.9457, x64. Two screens: 3840 × 2160 at 150% (primary) and 2560 × 1440. The spike uses the Windows App SDK packages `app/ClaudeBar.csproj` uses (WinUI 2.3.9, InteractiveExperiences 2.1.9, Runtime 2.5.1), unpackaged and self-contained like the app.

**How:** `HudProbe.exe` opens an ordinary window painted red | blue over black-and-white stripes, and a HUD window over the red/blue seam and the stripes. The HUD is borderless, always on top (`OverlappedPresenter.IsAlwaysOnTop`), and has `WS_EX_NOACTIVATE | WS_EX_TOOLWINDOW` unless the mode says otherwise. `probe.ps1` brings another window to the front, waits 2.5 s, captures the screen, and averages the pixels in boxes inside and outside the HUD. Outside the HUD the capture reads red `rgb(255,0,0)`, blue `rgb(0,0,255)` and stripes with a luminance spread of 127.5, so the capture is sound.

### Acrylic on a window that isn't active

| Backdrop | HUD over red | HUD over blue | HUD over stripes |
|---|---|---|---|
| `DesktopAcrylicBackdrop` (the XAML backdrop the tray flyout uses) | `rgb(44,44,44)` | `rgb(44,44,44)` | `rgb(44,44,44)`, spread 0 |
| `DesktopAcrylicController` with the framework's configuration | `rgb(44,44,44)` | `rgb(44,44,44)` | `rgb(44,44,44)`, spread 0 |
| `DesktopAcrylicBackdrop`, **without** `WS_EX_NOACTIVATE`, activated once, then another window in front | `rgb(44,44,44)` | `rgb(44,44,44)` | `rgb(44,44,44)`, spread 0 |
| `DesktopAcrylicController` with its own `SystemBackdropConfiguration { IsInputActive = true }` | `rgb(135,7,8)` | `rgb(22,21,223)` | `rgb(47,47,47)`, spread 0 |
| the same, with another app's window in front (a KakaoTalk window, another process) | `rgb(135,7,8)` | `rgb(22,21,223)` | `rgb(47,47,47)`, spread 0 |

- **The flat grey is Acrylic's inactive look, by design, not something `WS_EX_NOACTIVATE` breaks.** Microsoft's Acrylic page says background acrylic *"will replace its translucency and texture with a solid color … when an app window on desktop deactivates"* ([Acrylic](https://learn.microsoft.com/en-us/windows/apps/design/style/acrylic#usability-and-adaptability)). A HUD that can be activated looks the same once another window is in front. Acrylic follows `SystemBackdropConfiguration.IsInputActive`, which the framework's configuration ties to activation. A window that never activates therefore never gets the blur. That is what [microsoft-ui-xaml#10570](https://github.com/microsoft/microsoft-ui-xaml/issues/10570) reports.
- **A controller whose configuration stays active keeps the blur.** The two colours show through the HUD on each side of the seam. The stripes, whose luminance spreads by 127.5 outside the HUD, come out as one even tone under it. So this is blur, not plain transparency. The result is the same with another process's window in front. This is the answer given on #10570 and the pattern in Microsoft's [backdrop controller guide](https://learn.microsoft.com/en-us/windows/apps/windows-app-sdk/system-backdrop-controller): the guide sets `IsInputActive` from the window's activation, and the HUD keeps it `true`.
- [`research-acrylic.png`](research-acrylic.png): the capture from the first row on the left and the fourth on the right.

### The rest of the window

| Check | Result |
|---|---|
| On top | With the other window brought to the front under it, the window at the HUD's centre is still the HUD (`WindowFromPoint`), and `WS_EX_TOPMOST` is set |
| Corners | `SetBorderAndTitleBar(true, false)` with `DWMWA_WINDOW_CORNER_PREFERENCE = DWMWCP_ROUND`: rounded corners and the 1 px system border, no title bar |
| UI Automation | The HUD's tree is there: a Text named *"Claude, 5-hour limit: 62% left, resets in 2 hours 14 minutes"* (from `AutomationProperties.Name`) and a Button *"Retry reading Gemini"*, keyboard-focusable |
| UI Automation Invoke | Runs the button's handler, **and makes the HUD the foreground window**. `SetFocus` does too. Programmatic access can activate it even though the style says it shouldn't be |
| No taskbar button | With the ordinary window and the HUD both open, the taskbar reads *"HudProbe - 1 running window"* |
| **A mouse click on the HUD's button** | **Runs the handler, and makes the HUD the foreground window**, every time (5 of 5 runs with the probe's own window in front). `WS_EX_NOACTIVATE` keeps Windows from activating it on click; WinUI's input handling activates it anyway |
| …with `AllowFocusOnInteraction = false` on the button and the root | Still activates |
| …with `WM_MOUSEACTIVATE` answered `MA_NOACTIVATE` on the HUD and on all four of its child windows (`InputNonClientPointerSource`, `ReunionWindowingCaptionControls`, `Microsoft.UI.Content.DesktopChildSiteBridge`, `InputSiteWindowClass`) | Still activates. This rules out only mouse activation: pointer input has its own activation message, `WM_POINTERACTIVATE`, answered with `PA_NOACTIVATE` ([WM_POINTERACTIVATE](https://learn.microsoft.com/en-us/windows/win32/inputmsg/wm-pointeractivate)), which this run didn't handle |
| …handing the foreground back on `WM_ACTIVATE` (`SetForegroundWindow` on the window `lParam` names) | **The handler runs and the window that was in front is in front again** (checked 0.9 s after the click) |
| Full screen with `FullScreenPresenter` on the primary screen | `SHQueryUserNotificationState` reads `BUSY`, and the HUD is still drawn over it |
| A borderless window covering the primary screen | `BUSY`, and the HUD is still drawn over it |
| `FullScreenPresenter` on the second screen (2560 × 1440), the HUD on the primary | `ACCEPTS_NOTIFICATIONS`. The shell's state didn't see it. The window's rectangle equals its screen's, as on the primary |

### Not measured

- **`WM_POINTERACTIVATE`.** Which activation messages reach the HUD and its children on a click, whether mouse input arrives as pointer input (`IsMouseInPointerEnabled`), and whether answering `PA_NOACTIVATE` keeps the HUD from activating. If it does, the HUD needs no focus hand-back. The spike's `trace` and `active-pointer` modes do this.
- **Mica as the HUD's backdrop,** as the system draws it and kept active (modes `mica`, `mica-active`). See *Which material* below.
- **Handing focus back when the window in front belongs to another process,** which is the real case (an editor). Two attempts were spoiled: someone was using the PC, other windows came forward during the runs, and both clicks read `clicked=False` with foreground windows the probe didn't open. Windows' rule allows the hand-back: after the click, ClaudeBar *"is the foreground process"* and *"received the last input event"*, either of which lets it call `SetForegroundWindow` ([SetForegroundWindow, Remarks](https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-setforegroundwindow#remarks)). The same page warns that a process *"can be denied … even if it meets these conditions"*, so this is acceptance check 2.
- **Alt+Tab** wasn't checked on screen; the documentation below says a tool window isn't in it.

## From Microsoft's documentation

| Fact | Source |
|---|---|
| `WS_EX_NOACTIVATE`: doesn't become the foreground window when clicked, isn't brought forward when the foreground window closes, and *"should not be activated through programmatic access or via keyboard navigation by accessible technology, such as Narrator"*. It doesn't appear on the taskbar by default | [Extended Window Styles](https://learn.microsoft.com/en-us/windows/win32/winmsg/extended-window-styles) |
| `WS_EX_TOOLWINDOW`: *"does not appear in the taskbar or in the dialog that appears when the user presses ALT+TAB"* | same |
| `WS_EX_TOPMOST`: above all non-topmost windows, *"even when the window is deactivated"* | same |
| `AppWindow.IsShownInSwitchers`: whether the window appears in Alt+Tab and the taskbar | [AppWindow.IsShownInSwitchers](https://learn.microsoft.com/en-us/windows/windows-app-sdk/api/winrt/microsoft.ui.windowing.appwindow.isshowninswitchers) |
| `CompactOverlayPresenter`: always on top, 16:9 by default, any size through `Resize`. The HUD uses `OverlappedPresenter.IsAlwaysOnTop` instead, which has no aspect ratio | [Manage app windows](https://learn.microsoft.com/en-us/windows/apps/develop/ui/manage-app-windows) |
| Taskbar overlay icon: set on *"a valid HWND"* of the process that owns the button. Ignored when the taskbar uses small icons. Lost if Explorer restarts, so it is set again on `TaskbarButtonCreated` | [ITaskbarList3::SetOverlayIcon](https://learn.microsoft.com/en-us/windows/win32/api/shobjidl_core/nf-shobjidl_core-itaskbarlist3-setoverlayicon) |
| Badge on the taskbar button: shown *"regardless of whether the app is running"*. System glyphs or 1–99 only. The Windows App SDK's `BadgeNotificationManager` *"requires package identity"* | [Badge notifications](https://learn.microsoft.com/en-us/windows/apps/develop/notifications/badges), [BadgeNotifications spec](https://github.com/microsoft/WindowsAppSDK/blob/main/specs/BadgeNotifications/BadgeNotifications-spec.md) |
| Start at sign-in, packaged: `StartupTask`. A packaged desktop app gets no consent dialog. The user can turn it off on Settings' Startup page at any time | [StartupTask](https://learn.microsoft.com/en-us/uwp/api/windows.applicationmodel.startuptask) |
| `SHQueryUserNotificationState`: `QUNS_BUSY` (a full-screen app, or presentation settings), `QUNS_RUNNING_D3D_FULL_SCREEN`, `QUNS_PRESENTATION_MODE`, `QUNS_ACCEPTS_NOTIFICATIONS`. It names no screen; measured above, it missed a full-screen window on the second screen | [QUERY_USER_NOTIFICATION_STATE](https://learn.microsoft.com/en-us/windows/win32/api/shellapi/ne-shellapi-query_user_notification_state) |
| `SetForegroundWindow` works for a process that is the foreground process or received the last input event, among other conditions, and *"can be denied … even if it meets these conditions"* | [SetForegroundWindow](https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-setforegroundwindow) |
| Do not disturb silences banners; missed notifications wait in the notification centre. It turns on by hand, with Focus, or automatically under conditions the user sets | [Notifications and Do Not Disturb](https://support.microsoft.com/en-us/windows/notifications-and-do-not-disturb-in-windows-feeca47f-0baf-5680-16f0-8801db1a8466) |

### Which material

Microsoft's guidance doesn't put Acrylic on a window that stays open:

- Acrylic *"is used only for transient, light-dismiss surfaces such as flyouts and context menus"*, and *"rendering acrylic surfaces is GPU-intensive, which can increase device power consumption and shorten battery life"* ([System backdrops](https://learn.microsoft.com/en-us/windows/apps/develop/ui/system-backdrops), [Acrylic](https://learn.microsoft.com/en-us/windows/apps/design/style/acrylic)).
- Mica is *"an opaque, dynamic material that incorporates theme and desktop wallpaper to paint the background of long-lived windows"*, designed for performance because it *"capture[s] the background wallpaper only once"*. Like Acrylic, it turns into a solid colour (`SolidBackgroundFillColorBase`) *"when … an app window on desktop deactivates"* ([Mica](https://learn.microsoft.com/en-us/windows/apps/design/style/mica)).

So keeping Acrylic active works (measured above), but it puts a transient material on a long-lived window at a continuous GPU cost. The choice is open until the Mica arms are measured:

| Backdrop | Look while another app is in front | Against the guidance |
|---|---|---|
| Acrylic kept active | Blurs what's behind it | Material for transient surfaces; GPU cost all day |
| Mica kept active | Wallpaper-tinted, opaque | Long-lived window: as intended. Shows the active look on a window that isn't |
| The system's own (Mica or Acrylic, not overridden) | Solid `SolidBackgroundFillColorBase`, like every inactive window | As intended. But a click activates the HUD for a moment (measured), so it would flash to the active look and back |

## Similar apps (2026-10-13)

| App | What it is |
|---|---|
| [Win-CodexBar](https://github.com/Finesssee/Win-CodexBar) (1,147★, updated 2026-10-12) | Tauri, tray first. A grid of 20-odd provider abbreviations over one card per provider. Every bar the same blue whatever is left, and the share shown is *used* |
| [Yogitmeister/Win-CodexBar](https://github.com/Yogitmeister/Win-CodexBar) | Adds a *Floating Bar*: an always-on-top capacity strip with orientation, opacity and click-through settings |
| [CodexBar-Win](https://github.com/babakarto/CodexBar-Win) (106★) | customtkinter tray popup, Claude and Codex, each in its brand palette. Its README tells people who can't find the popup to look in the tray's overflow |
| [CodexBarWin](https://github.com/nek0der/CodexBarWin) (23★) | WinUI 3 with Mica, a tray wrapper for the CodexBar CLI |
| [CodexBar](https://codexbar.app/) (macOS) | Its card reads *"73% left · On pace · Resets in 5d 4h · Runs out in 4d 21h"* |

## What the design takes from this

1. **The HUD's backdrop is open:** Acrylic kept active (measured to work), Mica kept active, or the system's solid colour. See *Which material*. The tray flyout's `DesktopAcrylicBackdrop` would show the flat panel. Measured.
2. **Everything the HUD offers is also in the window.** Keyboard and Narrator users don't reach a no-activate window by navigation, so the window has every reading and every action. The HUD exposes full sentences to UI Automation for anyone who points at it. Documented, and the tree is measured.
3. **The taskbar dot is an overlay icon while ClaudeBar's window exists,** open or minimized. With the window closed, only a packaged build can mark the pinned button, with a badge glyph. Documented, and it depends on packaging, which is still open.
4. **Starting at sign-in is offered once,** after the first reading, and is off until accepted. Packaged builds use `StartupTask`; unpackaged ones use a Run entry. Either way the user can turn it off in Settings → Apps → Startup.
5. **The HUD hides when the foreground window covers the HUD's own screen,** which catches `FullScreenPresenter` and borderless full screen alike, and when the shell reports `PRESENTATION_MODE`. It doesn't hide for the shell's `BUSY`, which missed the second screen and doesn't say which screen it means. Measured: the HUD otherwise stays drawn over full-screen windows, so it must hide itself.
6. **A click on the HUD mustn't keep the focus.** A click activates the HUD despite `WS_EX_NOACTIVATE` and `MA_NOACTIVATE` (measured). First choice, not yet measured: answer `WM_POINTERACTIVATE` with `PA_NOACTIVATE`. Fallback, measured with a window of the same process: remember the last window outside ClaudeBar to be in front and give the foreground back to it after a click. Windows' rule allows that for another process too; that is acceptance check 2.
