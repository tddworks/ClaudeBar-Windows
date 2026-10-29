# The HUD (design, 2026-10-13)

A small window you leave on screen while you code, showing each signed-in AI tool's limits. Mockup: [`design-concept/hud/index.html`](../../design-concept/hud/index.html). Evidence: [`design-concept/hud/research.md`](../../design-concept/hud/research.md).

## Decisions

- **Direction A:** a small HUD that snaps to a screen corner, plus the window and the taskbar button. Rejected: B, a docked sidebar (`SHAppBarMessage`), which narrows every other window and is fragile across screens and DPI. Rejected: C, the taskbar and notifications only, where every reading takes a hover.
- **The HUD is on by default,** after the first reading, with one switch to turn it off (Settings → HUD → *Show the HUD*, or *Hide the HUD* on its right-click menu). This replaces the handoff's earlier principle that the app never puts itself on top uninvited. The person asked for an app that lives beside their work.
- **Starting at sign-in is offered, not taken:** once, after the first reading, and off until accepted.

## What it shows

One question per glance: *can I keep going, and until when.*

- **What stops you first, not every limit.** On real data one tool can have 13 limits, so the HUD shows each tool by its *headline*: the limit that will stop the person first, by ClaudeBar's rule (the worst status, then running hot, then the lowest share, then the soonest reset; Swift picks it, the HUD never ranks again). The window's *Limits* page lists every limit; a click on any row opens it.
  - **A row for each tool that needs you** (its headline isn't healthy, or runs hot): `● Claude  5h  [bar]  12%  · 1h 40m  +2 low`. The window label shows only for a tool with more than one limit; `+12` counts its other limits, `+2 low` the ones of those that aren't healthy. Out: `out · back 4:10 PM` in red. Running hot: `↑ runs out ~3:40 PM` in amber for the countdown, from ClaudeBar's forecast.
  - **Every fine tool in one quiet row:** `✓ Codex · Gemini · omp   lowest 62%`. When every tool is fine, that row is the whole HUD: `✓ All fine · lowest Claude 62%`.
  - **A tool without live numbers** gets a dimmed row: `○ Cursor  signed out`, what to do in its tooltip and its sentence. One that has numbers *and* is signed out, or whose read failed, keeps them dimmed and says since when: `signed out · numbers from 14:05`; stale numbers never pass for live ones. A tool whose CLI is gone while its numbers stay is one whose read failed. A tool whose limits have no share to draw (a balance only) gets a dimmed row too: `○ Amp  no limits to show`.
  - Tools keep the person's order. A footer has today's tokens and, when joined, the Leaderboard place, then when the numbers were read; while the pointer is over the HUD it holds *Refresh*, *Keep on top*, *Collapse to the strip* and *Open ClaudeBar* instead.
- **The pace tick** sits on each bar where the bar's end would be if the limit were used evenly (100% minus the share of the window gone). A bar ending left of its tick means the tool says *Running hot*.
- **Colour means trouble.**
  - Healthy bars use the Windows accent, as a `ProgressBar` does.
  - Amber is WinUI's caution colour; red is its critical colour.
  - The thresholds are the Mac app's `QuotaStatus` and `StatusPolicy`: warning under 50% (or, with the pace setting, only while running hot), critical under 20%, depleted at 0.
  - A limit at 0 says when it's *back*, as a clock time.
- **Every piece of text is readable in both themes:** at least WinUI's secondary text colour, 4.5:1 or more against the HUD. Tertiary text isn't used, because it measures 3.3:1 on light Mica. Offline numbers turn secondary instead of fading. Measured in the mockup with `design-concept/hud/contrast.js`: 236 text runs on the HUD, the strip and the window, light and dark, none under 4.5:1, the lowest *Running hot* in amber at 4.63:1. Before this rule, 27 failed: the window names, reset times and footer at 3.28:1 in light, and offline numbers at 4.36:1 in dark.
- **The words carry the meaning without the colour:** *runs out ~15:40*, *out · back 14:30*, *signed out*, *couldn't read*, *+2 low*. These are the Mac app's words where it has them (`UsagePace.displayName`).
- **The strip** is the same HUD, one line high: the worst tool's headline, then a dot per other tool in its status colour (a ring for one without live numbers). When everything is fine, `✓ All fine · lowest Claude 62%`. Click it for the card.
- **States:** reading for the first time (a row per tool it showed last, at its final size), all fine, running hot, low, out, offline (the last numbers faded, with their time, and *Retry*), signed out or couldn't read (with or without the numbers it had), and nothing found (one sentence and *Choose tools*). Light, dark and high contrast all follow Windows.
- **The window** has *Limits* (every limit by its full name, the reset as a clock time, the account, a link to the tool's usage page), *Usage* (today's tokens and cost from the local logs), *Leaderboard* (today's board) and *Settings*, in a `NavigationView`.

## How it behaves

| Concern | Rule | Basis |
|---|---|---|
| Window | A second WinUI `Window`. `OverlappedPresenter` with `IsAlwaysOnTop`, `SetBorderAndTitleBar(true, false)`, not resizable. `IsShownInSwitchers = false`. `WS_EX_NOACTIVATE \| WS_EX_TOOLWINDOW`. `DWMWCP_ROUND` | Measured: on top, rounded, bordered |
| Backdrop | Mica kept active: a custom `SystemBackdrop` that attaches a `MicaController` with its own `SystemBackdropConfiguration { IsInputActive = true }`, its theme following the HUD's `ActualTheme`. Microsoft gives Mica to long-lived windows and keeps Acrylic, GPU-intensive, for transient ones; opaque, it also keeps the text's contrast whatever is behind (research.md, *Which material*) | Measured: the same wallpaper tint while another app is in front, and no flicker when a click activates the HUD |
| Focus | It never activates itself to show anything. A click on one of its buttons does activate it, despite `WS_EX_NOACTIVATE`, `AllowFocusOnInteraction = false` and `MA_NOACTIVATE` (all measured). `PA_NOACTIVATE` on `WM_POINTERACTIVATE` doesn't stop it either: no activation message reaches the HUD's windows, WinUI sets the focus itself (measured, traced). So the HUD tracks the last window outside ClaudeBar to be in front (`SetWinEventHook(EVENT_SYSTEM_FOREGROUND)`) and call `SetForegroundWindow` on it after a click's action; menus and the shortcut hand it back when they close. UI Automation's Invoke and `SetFocus` activate it too (measured); there `Esc` hands focus back | Measured with a window of the same process. Another process: Windows' rule, acceptance check 2 |
| Place | Snaps to the nearest corner of the screen it's dropped on, its frame 12 effective pixels from the work area's edge. Remembers the corner and the screen. Moves back inside the work area when screens or DPI change | Measured: a window's rectangle includes an invisible resize border, 9 px left, right and below at 150%, so the frame (`DWMWA_EXTENDED_FRAME_BOUNDS`) is what's placed, and the content gets its size inside the border |
| Hiding | Hidden while the foreground window's rectangle covers the HUD's screen (`FullScreenPresenter` and borderless full screen both do), and while `SHQueryUserNotificationState` reports `PRESENTATION_MODE`. Not for `BUSY`, which missed a full-screen window on the second screen and doesn't say which screen it means. Shown again when that ends | Measured: the HUD otherwise stays over full-screen windows; `BUSY` on the primary screen only |
| Time | Countdowns tick once a minute from the reset times, online or not. Readings follow the app's refresh interval and run on demand from *Refresh* | — |
| Motion | None on entry. A bar eases to a new length when a reading changes it | — |
| Size | 340 effective pixels wide. Height from the rows, up to the work area's height minus the margins, then it scrolls | — |

## Keyboard and Narrator

A window that never activates isn't reached by keyboard navigation or by Narrator's navigation (`WS_EX_NOACTIVATE`'s documentation). So the HUD is never the only way to do anything.

| HUD | In the window |
|---|---|
| A tool's headline, and its other limits behind `+12` | *Limits*, in the same order, every limit with its full name |
| A tool that couldn't read | *Try again* on that tool's card in *Limits* |
| *Refresh* (its footer, or right-click) | *Refresh* in *Limits* |
| Keep on top, strip or card, hide | Settings → HUD |
| Open ClaudeBar | The taskbar button, Start, a jump list task, and the shortcut |

Every HUD element also has a full sentence for UI Automation (*"Claude, 5-hour limit: 62% left, resets in 2 hours 14 minutes"*), so pointing at it with Narrator reads it. The tree is measured.

## Taskbar and notifications

- **Overlay icon:** the worst status as a dot on ClaudeBar's taskbar button (none, amber, red), with alt text. It exists while ClaudeBar's window is open or minimized; it is set again on `TaskbarButtonCreated`, and the small-icon taskbar ignores it.
  - With the window closed there is no button to mark.
  - A packaged (MSIX) build could badge the pinned button with a system glyph. That waits on the packaging decision.
- **Hover preview** (exists today for the Leaderboard): the three limits closest to running out, then today and the place.
- **Jump list:** *Show the HUD*, *Refresh now*, *Leaderboard*.
- **Notifications:** per limit, once on crossing 20%, once at 0%, and once when it's back. Never twice for the same crossing, and nothing else. They carry *Show the HUD* and *Quiet until reset*. Do not disturb and Focus keep them in the notification centre, as Windows decides.

## Settings → HUD

*Show the HUD* (on), *Style* (Card, Strip), *Corner*, *Keep it on top* (on; hidden for full-screen apps), *Tools on the HUD*, *Shortcut to show or hide it* (none set). Starting with Windows is under General.

## Where the limits come from

ClaudeBar's package, on this PC: its `QuotaMonitor` over every provider it finds here, made as the Mac makes them, with the person's provider settings from ClaudeBar's own `settings.json`, read only (`HudMonitor`, `ClaudeBarSettings`). The C interface sends one reading (`cbw_hud_reading`, at once from the snapshots the monitor holds; `cbw_hud_refresh` reads every login first), each tool with its headline and its other limits counted. A provider that doesn't read here says why: not set up, signed out, or couldn't read.

The footer's tokens and place come from the data the Leaderboard client reads. `ClaudeBar.exe --hud-check` draws the HUD on sample readings (`tests/hud-check.json`, `tests/hud-check-fine.json`) for `scripts/check-hud.ps1` and the screenshots.

## Native acceptance checks

On a Windows 11 PC, with the HUD built into the app:

1. With another app in front, the HUD keeps Mica's active tint, the same over any content (the spike's red/blue/stripes capture), and doesn't change when it is clicked.
2. With an editor (another process) in front, a mouse click on each HUD button runs it, and the editor is the foreground window again afterwards.
3. The HUD has no taskbar button and isn't in Alt+Tab.
4. A `FullScreenPresenter` window and a borderless window covering the HUD's screen each hide the HUD, and it comes back after.
5. A full-screen window on the other screen leaves the HUD on this one alone, and the other way round.
6. Every action in the table above works from the window with the keyboard alone, and Narrator reads every HUD element's sentence.
7. Light, dark and high contrast follow Windows while it runs.
8. At 100%, 150% and 200% scaling, and after moving between screens with different scaling, the HUD keeps its corner and stays inside the work area.
9. Signed out, offline and nothing-found render as in the mockup, from sample snapshots.
10. In light and in dark theme, on the real Mica, every text run on the HUD and the strip measures 4.5:1 or more against the HUD around it, from a capture. High contrast mode doesn't count as the remedy.

The spike measured 1, 3's taskbar half, 4 on the primary screen and 5's first half (research.md). Check 2 with another process is the one the spike couldn't finish: the PC was in use.
