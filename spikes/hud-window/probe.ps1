# SPIKE driver: runs HudProbe.exe in each mode and measures, from the screen,
# what the HUD window really does. Windows PowerShell 5.1, interactive session.
#   .\probe.ps1 -Exe out\HudProbe.exe [-Shots dir]
param([string]$Exe, [string]$Shots = (Join-Path $env:TEMP 'hudprobe-shots'), [string[]]$Modes = @('default', 'follow', 'activatable', 'active'), [string[]]$Tests = @('measure', 'other-app', 'click', 'topmost', 'taskbar', 'fullscreen'))

Add-Type -AssemblyName System.Drawing, System.Windows.Forms
Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes
Add-Type @"
using System; using System.Runtime.InteropServices; using System.Text;
public static class P {
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int L, T, R, B; }
  [StructLayout(LayoutKind.Sequential)] public struct POINT { public int X, Y; }
  [StructLayout(LayoutKind.Sequential)] public struct MONITORINFO { public int cbSize; public RECT rcMonitor; public RECT rcWork; public uint dwFlags; }
  [DllImport("user32.dll")] public static extern bool SetProcessDpiAwarenessContext(IntPtr v);
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
  [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
  [DllImport("user32.dll")] public static extern void keybd_event(byte vk, byte scan, uint flags, UIntPtr extra);
  [DllImport("user32.dll")] public static extern IntPtr WindowFromPoint(POINT p);
  [DllImport("user32.dll")] public static extern IntPtr GetAncestor(IntPtr h, uint flags);
  [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
  [DllImport("user32.dll")] public static extern bool GetCursorPos(out POINT p);
  [DllImport("user32.dll")] public static extern void mouse_event(uint f, int dx, int dy, uint d, UIntPtr e);
  [DllImport("user32.dll")] public static extern IntPtr GetWindowLongPtrW(IntPtr h, int i);
  [DllImport("user32.dll")] public static extern IntPtr MonitorFromWindow(IntPtr h, uint f);
  [DllImport("user32.dll")] public static extern bool GetMonitorInfoW(IntPtr m, ref MONITORINFO mi);
  [DllImport("user32.dll")] public static extern bool MoveWindow(IntPtr h, int x, int y, int w, int hh, bool repaint);
  [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetWindowTextW(IntPtr h, StringBuilder s, int n);
  [DllImport("shell32.dll")] public static extern int SHQueryUserNotificationState(out int state);
  [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern IntPtr FindWindowW(string cls, string title);
  // The usual way a test harness gets past the foreground lock: an Alt key event first.
  public static bool Front(IntPtr h) { keybd_event(0x12, 0, 0, UIntPtr.Zero); var ok = SetForegroundWindow(h); keybd_event(0x12, 0, 2, UIntPtr.Zero); return ok; }
  public static string Title(IntPtr h) { var s = new StringBuilder(256); GetWindowTextW(h, s, 256); return s.ToString(); }
  public static IntPtr RootAt(int x, int y) { var p = new POINT { X = x, Y = y }; return GetAncestor(WindowFromPoint(p), 2); }
  public static RECT Monitor(IntPtr h) { var mi = new MONITORINFO(); mi.cbSize = Marshal.SizeOf(mi); GetMonitorInfoW(MonitorFromWindow(h, 2), ref mi); return mi.rcMonitor; }
}
"@
$aware = [P]::SetProcessDpiAwarenessContext([IntPtr](-4))
$dir = Join-Path $env:TEMP 'hudprobe'
New-Item -ItemType Directory -Force -Path $Shots | Out-Null
$quns = @{ 1 = 'NOT_PRESENT'; 2 = 'BUSY'; 3 = 'RUNNING_D3D_FULL_SCREEN'; 4 = 'PRESENTATION_MODE'; 5 = 'ACCEPTS_NOTIFICATIONS'; 6 = 'QUIET_TIME'; 7 = 'APP' }
function Quns { $s = 0; [void][P]::SHQueryUserNotificationState([ref]$s); $quns[$s] }
function Rect($h) { $r = New-Object P+RECT; [void][P]::GetWindowRect($h, [ref]$r); $r }
function Fg { $f = [P]::GetForegroundWindow(); '{0} "{1}"' -f $f, [P]::Title($f) }
function Command($c) {
  Set-Content -Path (Join-Path $dir 'cmd.txt') -Value $c
  $ack = Join-Path $dir "ack-$c.txt"
  for ($i = 0; $i -lt 50 -and -not (Test-Path $ack); $i++) { Start-Sleep -Milliseconds 100 }
  Test-Path $ack
}
function Grab($r, $name) {
  $w = $r.R - $r.L; $h = $r.B - $r.T
  $bmp = New-Object Drawing.Bitmap $w, $h
  $g = [Drawing.Graphics]::FromImage($bmp)
  $g.CopyFromScreen($r.L, $r.T, 0, 0, (New-Object Drawing.Size $w, $h))
  $g.Dispose()
  $bmp.Save((Join-Path $Shots "$name.png"), [Drawing.Imaging.ImageFormat]::Png)
  $bmp
}
# Mean colour and the spread of luminance over a box of the capture.
function Stats($bmp, $x0, $y0, $x1, $y1) {
  $n = 0; $sr = 0; $sg = 0; $sb = 0; $sl = 0; $sl2 = 0
  for ($y = [int]$y0; $y -lt [int]$y1; $y += 2) { for ($x = [int]$x0; $x -lt [int]$x1; $x += 2) {
    $c = $bmp.GetPixel($x, $y); $sr += $c.R; $sg += $c.G; $sb += $c.B
    $l = 0.2126 * $c.R + 0.7152 * $c.G + 0.0722 * $c.B; $sl += $l; $sl2 += $l * $l; $n++ } }
  $m = $sl / $n
  'rgb({0},{1},{2}) lumStd={3:N1}' -f [math]::Round($sr / $n), [math]::Round($sg / $n), [math]::Round($sb / $n), [math]::Sqrt([math]::Max(0, $sl2 / $n - $m * $m))
}
# What shows through the HUD, against the same pattern outside it.
function Measure-Hud($behind, $hud, $s, $name) {
  $b = Rect $behind; $h = Rect $hud
  $bmp = Grab $b $name
  $ox = $h.L - $b.L; $oy = $h.T - $b.T
  "  outside, red    : " + (Stats $bmp (50 * $s) (60 * $s) (200 * $s) (200 * $s))
  "  outside, blue   : " + (Stats $bmp (580 * $s) (60 * $s) (640 * $s) (200 * $s))
  "  outside, stripes: " + (Stats $bmp (600 * $s) (280 * $s) (780 * $s) (370 * $s))
  "  HUD over red    : " + (Stats $bmp ($ox + 20 * $s) ($oy + 40 * $s) ($ox + 120 * $s) ($oy + 120 * $s))
  "  HUD over blue   : " + (Stats $bmp ($ox + 180 * $s) ($oy + 40 * $s) ($ox + 280 * $s) ($oy + 120 * $s))
  "  HUD over stripes: " + (Stats $bmp ($ox + 20 * $s) ($oy + 200 * $s) ($ox + 190 * $s) ($oy + 285 * $s))
  $bmp.Dispose()
}
function Start-Probe($mode) {
  Remove-Item $dir -Recurse -Force -ErrorAction SilentlyContinue
  New-Item -ItemType Directory -Path $dir | Out-Null
  $p = Start-Process $Exe -ArgumentList $mode -PassThru
  $ready = Join-Path $dir 'ready.json'
  for ($i = 0; $i -lt 200 -and -not (Test-Path $ready); $i++) { Start-Sleep -Milliseconds 100 }
  if (-not (Test-Path $ready)) { "  no ready.json; exited=$($p.HasExited)"; return $null }
  Start-Sleep -Milliseconds 300
  $r = Get-Content $ready | ConvertFrom-Json
  [pscustomobject]@{ Process = $p; Behind = [IntPtr][long]$r.behind; Hud = [IntPtr][long]$r.hud; Scale = $r.dpi / 96.0; Ready = $r }
}
function Stop-Probe($probe) {
  [void](Command 'exit')
  if (-not $probe.Process.WaitForExit(5000)) { $probe.Process.Kill() }
}

"== machine: " + (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' | ForEach-Object { "$($_.DisplayVersion) build $($_.CurrentBuild).$($_.UBR)" })
"== per-monitor DPI aware: $aware; notification state before: " + (Quns)
foreach ($mode in $Modes) {
  "== mode $mode"
  $probe = Start-Probe $mode
  if (-not $probe) { continue }
  "  ready: exStyle=0x{0:X} dpi={1} acrylicSupported={2} children={3}" -f $probe.Ready.hudExStyle, $probe.Ready.dpi, $probe.Ready.acrylicSupported, $probe.Ready.children
  Start-Sleep -Seconds 1
  "  behind to front: " + [P]::Front($probe.Behind)
  Start-Sleep -Milliseconds 2500
  "  foreground: " + (Fg)
  if ($Tests -contains 'measure') { Measure-Hud $probe.Behind $probe.Hud $probe.Scale "$mode-inactive" }

  $form = 'Add-Type -AssemblyName System.Windows.Forms; $f = New-Object Windows.Forms.Form; $f.Text = ''Other app''; $f.StartPosition = ''Manual''; $f.Location = New-Object Drawing.Point 1300, 700; $f.Size = New-Object Drawing.Size 420, 260; [Windows.Forms.Application]::Run($f)'
  if ($mode -like 'active*') {
    if ($Tests -contains 'other-app') {
    # Another process in front, as an editor would be.
    # (Windows 11's Notepad hands off to a packaged process, so a plain WinForms window in its own process.)
    $form = 'Add-Type -AssemblyName System.Windows.Forms; $f = New-Object Windows.Forms.Form; $f.Text = ''Other app''; $f.StartPosition = ''Manual''; $f.Location = New-Object Drawing.Point 1300, 700; $f.Size = New-Object Drawing.Size 420, 260; [Windows.Forms.Application]::Run($f)'
    $np = Start-Process powershell -ArgumentList '-NoProfile', '-Command', $form -PassThru -WindowStyle Hidden
    $other = [IntPtr]::Zero
    for ($i = 0; $i -lt 100 -and $other -eq [IntPtr]::Zero; $i++) { Start-Sleep -Milliseconds 100; $other = [P]::FindWindowW($null, 'Other app') }
    "  other app to front: " + [P]::Front($other)
    Start-Sleep -Milliseconds 2500
    "  foreground: " + (Fg)
    Measure-Hud $probe.Behind $probe.Hud $probe.Scale 'active-other-app'
    $np.Kill()
    }

    if ($Tests -contains 'click-other') {
      $np = Start-Process powershell -ArgumentList '-NoProfile', '-Command', $form -PassThru -WindowStyle Hidden
      $other = [IntPtr]::Zero
      for ($i = 0; $i -lt 100 -and $other -eq [IntPtr]::Zero; $i++) { Start-Sleep -Milliseconds 100; $other = [P]::FindWindowW($null, 'Other app') }
      [void][P]::Front($other); Start-Sleep -Milliseconds 800
      $root = [Windows.Automation.AutomationElement]::FromHandle($probe.Hud)
      $cond = New-Object Windows.Automation.PropertyCondition([Windows.Automation.AutomationElement]::NameProperty, 'Retry reading Gemini')
      $br = $root.FindFirst([Windows.Automation.TreeScope]::Descendants, $cond).Current.BoundingRectangle
      $cx = [int]($br.X + $br.Width / 2); $cy = [int]($br.Y + $br.Height / 2)
      if ([P]::RootAt($cx, $cy) -ne $probe.Hud) { "  click with another app in front skipped: the point isn't on the HUD" }
      else {
        Remove-Item (Join-Path $dir 'clicked.txt') -ErrorAction SilentlyContinue
        $before = Fg
        $saved = New-Object P+POINT; [void][P]::GetCursorPos([ref]$saved)
        [void][P]::SetCursorPos($cx, $cy); Start-Sleep -Milliseconds 120
        [P]::mouse_event(2, 0, 0, 0, [UIntPtr]::Zero); Start-Sleep -Milliseconds 60; [P]::mouse_event(4, 0, 0, 0, [UIntPtr]::Zero)
        Start-Sleep -Milliseconds 120
        [void][P]::SetCursorPos($saved.X, $saved.Y)
        Start-Sleep -Milliseconds 900
        "  click with another app in front: clicked={0} foreground before={1} after={2}" -f (Test-Path (Join-Path $dir 'clicked.txt')), $before, (Fg)
      }
      $np.Kill()
    }
    if ($Tests -contains 'click') {
    # Clicking the HUD's button: does it run, and does focus stay where it was?
    [void][P]::Front($probe.Behind); Start-Sleep -Milliseconds 800
    $root = [Windows.Automation.AutomationElement]::FromHandle($probe.Hud)
    "  UIA tree of the HUD:"
    $all = $root.FindAll([Windows.Automation.TreeScope]::Descendants, [Windows.Automation.Condition]::TrueCondition)
    foreach ($e in $all) { "    {0} | {1} | keyboardFocusable={2}" -f $e.Current.ControlType.ProgrammaticName, $e.Current.Name, $e.Current.IsKeyboardFocusable }
    $cond = New-Object Windows.Automation.PropertyCondition([Windows.Automation.AutomationElement]::NameProperty, 'Retry reading Gemini')
    $btn = $root.FindFirst([Windows.Automation.TreeScope]::Descendants, $cond)
    $br = $btn.Current.BoundingRectangle
    $cx = [int]($br.X + $br.Width / 2); $cy = [int]($br.Y + $br.Height / 2)
    $h = Rect $probe.Hud
    "  HUD rect=({0},{1},{2},{3}) Retry rect=({4:N0},{5:N0},{6:N0},{7:N0})" -f $h.L, $h.T, $h.R, $h.B, $br.X, $br.Y, $br.Width, $br.Height
    # Click only where the HUD itself is: never on someone's window.
    $at = [P]::RootAt($cx, $cy)
    if ($at -ne $probe.Hud) { "  mouse click skipped: the window at ($cx,$cy) is {0} ""{1}"", not the HUD" -f $at, [P]::Title($at) }
    else {
      $before = Fg
      $saved = New-Object P+POINT; [void][P]::GetCursorPos([ref]$saved)
      [void][P]::SetCursorPos($cx, $cy); Start-Sleep -Milliseconds 120
      [P]::mouse_event(2, 0, 0, 0, [UIntPtr]::Zero); Start-Sleep -Milliseconds 60; [P]::mouse_event(4, 0, 0, 0, [UIntPtr]::Zero)
      Start-Sleep -Milliseconds 120
      [void][P]::SetCursorPos($saved.X, $saved.Y)
      Start-Sleep -Milliseconds 800
      "  mouse click on Retry: clicked={0} foreground before={1} after={2}" -f (Test-Path (Join-Path $dir 'clicked.txt')), $before, (Fg)
    }
    Remove-Item (Join-Path $dir 'clicked.txt') -ErrorAction SilentlyContinue
    $before = Fg
    try { $btn.GetCurrentPattern([Windows.Automation.InvokePattern]::Pattern).Invoke(); $inv = 'ok' } catch { $inv = "failed: $_" }
    Start-Sleep -Milliseconds 900
    "  UIA Invoke on Retry: {0} clicked={1} foreground before={2} after={3}" -f $inv, (Test-Path (Join-Path $dir 'clicked.txt')), $before, (Fg)
    try { $btn.SetFocus(); $sf = 'ok' } catch { $sf = "failed: $($_.Exception.GetType().Name)" }
    Start-Sleep -Milliseconds 500
    "  UIA SetFocus on Retry: {0}, foreground after={1}" -f $sf, (Fg)
    [void][P]::Front($probe.Behind); Start-Sleep -Milliseconds 500
    }

    # On top of a window brought to the front under it.
    $h = Rect $probe.Hud
    $root2 = [P]::RootAt([int](($h.L + $h.R) / 2), [int](($h.T + $h.B) / 2))
    "  topmost: window at the HUD's centre is the HUD = {0}; WS_EX_TOPMOST={1}" -f ($root2 -eq $probe.Hud), (([long][P]::GetWindowLongPtrW($probe.Hud, -20) -band 0x8) -ne 0)

    # The taskbar: which buttons name the probe?
    $trayCond = New-Object Windows.Automation.PropertyCondition([Windows.Automation.AutomationElement]::ClassNameProperty, 'Shell_TrayWnd')
    $tray = [Windows.Automation.AutomationElement]::RootElement.FindFirst([Windows.Automation.TreeScope]::Children, $trayCond)
    if ($tray) {
      $buttons = $tray.FindAll([Windows.Automation.TreeScope]::Descendants, (New-Object Windows.Automation.PropertyCondition([Windows.Automation.AutomationElement]::ControlTypeProperty, [Windows.Automation.ControlType]::Button)))
      "  taskbar buttons naming HudProbe: " + (($buttons | Where-Object { $_.Current.Name -match 'HudProbe' } | ForEach-Object { '"' + $_.Current.Name + '"' }) -join ', ')
    } else { "  taskbar: Shell_TrayWnd not found" }

    # Full screen: what the shell reports, and whether the HUD still covers it.
    "  notification state, windowed: " + (Quns)
    $hows = @(); if ($Tests -contains 'fullscreen') { $hows += 'fullscreen', 'cover' }; if ($Tests -contains 'screen2') { $hows += 'fullscreen-other-screen' }
    foreach ($how in $hows) {
      [void](Command $how)
      "  $how ack: " + (Get-Content (Join-Path $dir "ack-$how.txt") -ErrorAction SilentlyContinue)
      if (-not (Get-Process -Id $probe.Process.Id -ErrorAction SilentlyContinue)) { "  the probe exited"; break }
      [void][P]::Front($probe.Behind); Start-Sleep -Seconds 2
      $b = Rect $probe.Behind; $m = [P]::Monitor($probe.Behind)
      "  $how : behind=({0},{1},{2},{3}) monitor=({4},{5},{6},{7}) foreground={8}" -f $b.L, $b.T, $b.R, $b.B, $m.L, $m.T, $m.R, $m.B, (Fg)
      "  notification state, $how : " + (Quns)
      $h = Rect $probe.Hud
      "  HUD still drawn over it: " + ([P]::RootAt([int](($h.L + $h.R) / 2), [int](($h.T + $h.B) / 2)) -eq $probe.Hud)
      [void](Grab (Rect $probe.Hud) "active-over-$how")
      [void](Command 'restore'); Start-Sleep -Seconds 1
      "  notification state, restored: " + (Quns)
    }
  }
  Stop-Probe $probe
}
"== screens: " + (([System.Windows.Forms.Screen]::AllScreens | ForEach-Object { "$($_.DeviceName) $($_.Bounds) primary=$($_.Primary)" }) -join '; ')
