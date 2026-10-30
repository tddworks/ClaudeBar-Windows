# Spike: the HUD's window (2026-10-13)

Throwaway. It answers what [`design-concept/hud`](../../design-concept/hud) needs from Windows before the HUD's window is written: does Acrylic survive a window that never activates, does a click take focus, does the window stay on top and off the taskbar, and what does a full-screen app look like to it. Results and sources: [`design-concept/hud/research.md`](../../design-concept/hud/research.md).

- `HudProbe.exe <mode>`: an ordinary window painted red | blue over stripes, and a HUD over it. Modes: `default`, `follow`, `activatable`, `active`, `active-nofocus`, `active-mouseactivate`, `active-childnoact`, `active-giveback` (see `Probe.cs`).
- `probe.ps1 -Exe <HudProbe.exe> [-Modes …] [-Tests …]`: Windows PowerShell 5.1 in the signed-in session. Captures the screen, clicks only where the HUD is (and puts the cursor back), reads UI Automation, the taskbar and `SHQueryUserNotificationState`. It moves the cursor, takes focus and covers a screen for a few seconds: run it on a PC nobody is using.

```powershell
dotnet publish spikes\hud-window\HudProbe.csproj -c Release -r win-x64 -p:Platform=x64 -o out\hudprobe
spikes\hud-window\probe.ps1 -Exe out\hudprobe\HudProbe.exe
```
