# Checks the HUD's window on a Windows PC, as the spike's probe did
# (spikes/hud-window/probe.ps1, design-concept/hud/research.md): it opens the
# real HUD on the sample reading (`ClaudeBar.exe --hud-check`), beside a
# ClaudeBar that may be running, and measures from the screen what it does.
# It moves the mouse, clicks the HUD and brings windows to the front, so run
# it on a PC nobody is using. Windows PowerShell 5.1 or PowerShell 7.
# It prints PASS or FAIL per check and exits 1 on any FAIL.
#   .\scripts\check-hud.ps1 [-Exe out\win-x64\ClaudeBar.exe] [-Shots dir] [-Themes light,dark]
param(
  [string]$Exe = (Join-Path $PSScriptRoot '..\out\win-x64\ClaudeBar.exe'),
  [string]$Shots = (Join-Path $env:TEMP 'claudebar-hud-shots'),
  [string[]]$Themes = @('light', 'dark'),
  [string[]]$Tests = @('focus', 'measure', 'click', 'drag', 'topmost', 'taskbar', 'fullscreen', 'screens', 'contrast', 'calibrate', 'shots')
)

Add-Type -AssemblyName System.Drawing, System.Windows.Forms
Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes
Add-Type @"
using System; using System.Runtime.InteropServices; using System.Text;
public static class H {
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int L, T, R, B; }
  [StructLayout(LayoutKind.Sequential)] public struct POINT { public int X, Y; }
  [DllImport("user32.dll")] public static extern bool SetProcessDpiAwarenessContext(IntPtr v);
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
  [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
  [DllImport("user32.dll")] public static extern void keybd_event(byte vk, byte scan, uint flags, UIntPtr extra);
  [DllImport("user32.dll")] public static extern IntPtr WindowFromPoint(POINT p);
  [DllImport("user32.dll")] public static extern IntPtr GetAncestor(IntPtr h, uint flags);
  [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
  [DllImport("user32.dll")] public static extern bool GetCursorPos(out POINT p);
  [DllImport("user32.dll")] public static extern void mouse_event(uint f, int dx, int dy, uint d, UIntPtr e);
  [DllImport("user32.dll")] public static extern IntPtr GetWindowLongPtrW(IntPtr h, int i);
  [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetWindowTextW(IntPtr h, StringBuilder s, int n);
  [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern IntPtr FindWindowW(string cls, string title);
  [DllImport("shell32.dll")] public static extern int SHQueryUserNotificationState(out int state);
  [DllImport("dwmapi.dll")] public static extern int DwmGetWindowAttribute(IntPtr h, int attribute, out RECT r, int size);
  // The window as drawn, without the invisible resize borders GetWindowRect includes.
  public static RECT Frame(IntPtr h) { RECT r; if (DwmGetWindowAttribute(h, 9, out r, 16) != 0) GetWindowRect(h, out r); return r; }
  // The usual way a test harness gets past the foreground lock: an Alt key event first.
  public static bool Front(IntPtr h) { keybd_event(0x12, 0, 0, UIntPtr.Zero); var ok = SetForegroundWindow(h); keybd_event(0x12, 0, 2, UIntPtr.Zero); return ok; }
  public static string Title(IntPtr h) { var s = new StringBuilder(256); GetWindowTextW(h, s, 256); return s.ToString(); }
  public static IntPtr RootAt(int x, int y) { var p = new POINT { X = x, Y = y }; return GetAncestor(WindowFromPoint(p), 2); }

  // WCAG contrast from a BGRA capture. The background is the median luminance
  // of a 2 px ring around the box; the text is the 98th percentile of contrast
  // among the box's pixels that differ from it, so a ClearType fringe doesn't decide.
  static double Linear(byte c) { var v = c / 255.0; return v <= 0.04045 ? v / 12.92 : Math.Pow((v + 0.055) / 1.055, 2.4); }
  static double Luminance(byte[] p, int i) { return 0.2126 * Linear(p[i + 2]) + 0.7152 * Linear(p[i + 1]) + 0.0722 * Linear(p[i]); }
  static double Ratio(double a, double b) { return (Math.Max(a, b) + 0.05) / (Math.Min(a, b) + 0.05); }
  public static double TextContrast(byte[] p, int stride, int width, int height, int x, int y, int w, int h) {
    var ring = new System.Collections.Generic.List<double>();
    for (int yy = y - 2; yy < y + h + 2; yy++) for (int xx = x - 2; xx < x + w + 2; xx++) {
      if (xx >= x && xx < x + w && yy >= y && yy < y + h) continue;
      if (xx < 0 || yy < 0 || xx >= width || yy >= height) continue;
      ring.Add(Luminance(p, yy * stride + xx * 4)); }
    if (ring.Count == 0) return -1;
    ring.Sort(); var background = ring[ring.Count / 2];
    var inside = new System.Collections.Generic.List<double>();
    for (int yy = Math.Max(0, y); yy < Math.Min(height, y + h); yy++) for (int xx = Math.Max(0, x); xx < Math.Min(width, x + w); xx++) {
      var r = Ratio(Luminance(p, yy * stride + xx * 4), background); if (r > 1.05) inside.Add(r); }
    if (inside.Count == 0) return 1;
    inside.Sort(); return inside[(int)(0.98 * (inside.Count - 1))];
  }
}
"@
[void][H]::SetProcessDpiAwarenessContext([IntPtr](-4))
$dir = Join-Path $env:TEMP 'claudebar-hud-check'
New-Item -ItemType Directory -Force -Path $Shots | Out-Null
$Exe = (Resolve-Path $Exe).Path
$quns = @{ 1 = 'NOT_PRESENT'; 2 = 'BUSY'; 3 = 'RUNNING_D3D_FULL_SCREEN'; 4 = 'PRESENTATION_MODE'; 5 = 'ACCEPTS_NOTIFICATIONS'; 6 = 'QUIET_TIME'; 7 = 'APP' }
function Quns { $s = 0; [void][H]::SHQueryUserNotificationState([ref]$s); $quns[$s] }
function Rect($h) { [H]::Frame($h) }
function Fg { $f = [H]::GetForegroundWindow(); '{0} "{1}"' -f $f, [H]::Title($f) }
$script:failures = 0
function Pass($ok) { if ($ok) { 'PASS' } else { $script:failures++; 'FAIL' } }
function Command($c) {
  $ack = Join-Path $dir ("ack-{0}.txt" -f $c.Replace(':', '-'))
  Remove-Item $ack -ErrorAction SilentlyContinue
  Set-Content -Path (Join-Path $dir 'cmd.txt') -Value $c
  for ($i = 0; $i -lt 50 -and -not (Test-Path $ack); $i++) { Start-Sleep -Milliseconds 100 }
  Test-Path $ack
}
function Grab($r, $name, $margin = 0) {
  $l = $r.L - $margin; $t = $r.T - $margin; $w = $r.R - $r.L + 2 * $margin; $h = $r.B - $r.T + 2 * $margin
  $bmp = New-Object Drawing.Bitmap $w, $h
  $g = [Drawing.Graphics]::FromImage($bmp)
  $g.CopyFromScreen($l, $t, 0, 0, (New-Object Drawing.Size $w, $h))
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
# The HUD's own pixels: its top edge strip (the header, no text at its left
# margin) and a box on its left margin, where only the material shows.
function Measure-Hud($hud, $s, $name) {
  $h = Rect $hud
  $bmp = Grab $h $name
  "  HUD left margin : " + (Stats $bmp (2 * $s) (40 * $s) (10 * $s) (($h.B - $h.T) - 40 * $s))
  $bmp.Dispose()
}
function Other-App {
  # Another process in front, as an editor would be. (Windows 11's Notepad hands
  # off to a packaged process, so a plain WinForms window in its own process.)
  $form = 'Add-Type -AssemblyName System.Windows.Forms; $f = New-Object Windows.Forms.Form; $f.Text = ''Other app''; $f.StartPosition = ''Manual''; $f.Location = New-Object Drawing.Point 200, 200; $f.Size = New-Object Drawing.Size 420, 260; [Windows.Forms.Application]::Run($f)'
  $p = Start-Process powershell -ArgumentList '-NoProfile', '-Command', $form -PassThru -WindowStyle Hidden
  $other = [IntPtr]::Zero
  for ($i = 0; $i -lt 100 -and $other -eq [IntPtr]::Zero; $i++) { Start-Sleep -Milliseconds 100; $other = [H]::FindWindowW([NullString]::Value, 'Other app') }
  [void][H]::Front($other); Start-Sleep -Milliseconds 800
  if ([H]::GetForegroundWindow() -ne $other) { Write-Host "  (the other app didn't come to the front: $(Fg))" }
  [pscustomobject]@{ Process = $p; Window = $other }
}
function Start-Check($theme, $style, $extra) {
  $arguments = @('--hud-check', '--theme', $theme)
  if ($style) { $arguments += '--style', $style }
  if ($extra) { $arguments += $extra }
  Remove-Item (Join-Path $dir 'ready.json') -ErrorAction SilentlyContinue
  $p = Start-Process $Exe -ArgumentList $arguments -PassThru
  $ready = Join-Path $dir 'ready.json'
  for ($i = 0; $i -lt 600 -and -not (Test-Path $ready) -and -not $p.HasExited; $i++) { Start-Sleep -Milliseconds 100 }
  if (-not (Test-Path $ready)) {
    Write-Host ("  FAIL the check didn't start ({0}): exited={1}" -f ($arguments -join ' '), $p.HasExited)
    Get-Content (Join-Path $dir 'crash.txt') -ErrorAction SilentlyContinue | Select-Object -First 15 | ForEach-Object { Write-Host "    $_" }
    $script:failures++
    if (-not $p.HasExited) { $p.Kill() }
    return $null
  }
  Start-Sleep -Milliseconds 800
  $r = Get-Content $ready | ConvertFrom-Json
  [pscustomobject]@{ Process = $p; Behind = [IntPtr][long]$r.behind; Hud = [IntPtr][long]$r.hud; Scale = $r.dpi / 96.0; Ready = $r }
}
function Stop-Check($check) {
  [void](Command 'exit')
  if (-not $check.Process.WaitForExit(5000)) { $check.Process.Kill() }
}
function Click-At($x, $y) {
  $saved = New-Object H+POINT; [void][H]::GetCursorPos([ref]$saved)
  [void][H]::SetCursorPos($x, $y); Start-Sleep -Milliseconds 120
  [H]::mouse_event(2, 0, 0, 0, [UIntPtr]::Zero); Start-Sleep -Milliseconds 60; [H]::mouse_event(4, 0, 0, 0, [UIntPtr]::Zero)
  Start-Sleep -Milliseconds 120
  [void][H]::SetCursorPos($saved.X, $saved.Y)
}
# Every text run on the HUD, against the HUD around it (design, acceptance check 10).
function Contrast($check, $name) {
  $h = Rect $check.Hud
  $bmp = Grab $h $name 4
  $data = $bmp.LockBits((New-Object Drawing.Rectangle 0, 0, $bmp.Width, $bmp.Height), [Drawing.Imaging.ImageLockMode]::ReadOnly, [Drawing.Imaging.PixelFormat]::Format32bppArgb)
  $bytes = New-Object byte[] ($data.Stride * $bmp.Height)
  [Runtime.InteropServices.Marshal]::Copy($data.Scan0, $bytes, 0, $bytes.Length)
  $bmp.UnlockBits($data)
  $root = [Windows.Automation.AutomationElement]::FromHandle($check.Hud)
  $types = New-Object Windows.Automation.OrCondition(
    (New-Object Windows.Automation.PropertyCondition([Windows.Automation.AutomationElement]::ControlTypeProperty, [Windows.Automation.ControlType]::Text)),
    (New-Object Windows.Automation.PropertyCondition([Windows.Automation.AutomationElement]::ControlTypeProperty, [Windows.Automation.ControlType]::Hyperlink)))
  $results = foreach ($e in $root.FindAll([Windows.Automation.TreeScope]::Descendants, $types)) {
    $r = $e.Current.BoundingRectangle
    if ($r.IsEmpty -or $r.Width -lt 2 -or $r.Height -lt 2 -or -not $e.Current.Name) { continue }
    $x = [int]$r.X - $h.L + 4; $y = [int]$r.Y - $h.T + 4
    $ratio = [H]::TextContrast($bytes, $data.Stride, $bmp.Width, $bmp.Height, $x, $y, [int]$r.Width, [int]$r.Height)
    [pscustomobject]@{ Name = $e.Current.Name; Ratio = $ratio }
  }
  $bmp.Dispose()
  $results
}
function Find-Named($root, $pattern) {
  $all = $root.FindAll([Windows.Automation.TreeScope]::Descendants, [Windows.Automation.Condition]::TrueCondition)
  foreach ($e in $all) { if ($e.Current.Name -like $pattern) { return $e } }
  $null
}

"== machine: " + (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' | ForEach-Object { "$($_.DisplayVersion) build $($_.CurrentBuild).$($_.UBR)" })
"== screens: " + (([System.Windows.Forms.Screen]::AllScreens | ForEach-Object { "$($_.DeviceName) $($_.Bounds) primary=$($_.Primary)" }) -join '; ')
foreach ($theme in $Themes) {
  "== theme $theme"
  $check = Start-Check $theme $null
  if (-not $check) { continue }
  $ex = [long][H]::GetWindowLongPtrW($check.Hud, -20)
  "  window: exStyle=0x{0:X} noactivate={1} toolwindow={2} topmost={3} dpi={4} corner={5}" -f $ex, (($ex -band 0x08000000) -ne 0), (($ex -band 0x80) -ne 0), (($ex -band 0x8) -ne 0), $check.Ready.dpi, $check.Ready.corner

  if ($Tests -contains 'focus') {
    # Shown, hidden and shown again with another app in front: the focus stays there.
    $other = Other-App
    $before = Fg
    [void](Command 'reshow'); Start-Sleep -Milliseconds 900
    $after = Fg
    "  {0} shown again without taking the focus: before={1} after={2} visible={3}" -f (Pass ($before -eq $after -and [H]::IsWindowVisible($check.Hud))), $before, $after, [H]::IsWindowVisible($check.Hud)
    $other.Process.Kill()
  }

  if ($Tests -contains 'measure') {
    # Kept-active Mica: the same tint with the HUD inactive and with another app in front.
    [void][H]::Front($check.Behind); Start-Sleep -Milliseconds 1500
    "  foreground: " + (Fg)
    Measure-Hud $check.Hud $check.Scale "$theme-inactive"
    $other = Other-App; Start-Sleep -Milliseconds 1500
    "  foreground: " + (Fg)
    Measure-Hud $check.Hud $check.Scale "$theme-other-app"
    $other.Process.Kill()
  }

  if ($Tests -contains 'click') {
    $other = Other-App
    $root = [Windows.Automation.AutomationElement]::FromHandle($check.Hud)
    "  UIA tree of the HUD:"
    $all = $root.FindAll([Windows.Automation.TreeScope]::Descendants, [Windows.Automation.Condition]::TrueCondition)
    foreach ($e in $all) { if ($e.Current.Name) { "    {0} | {1}" -f $e.Current.ControlType.ProgrammaticName, $e.Current.Name } }
    # The buttons show while the pointer is over the card: point at its footer first.
    $h = Rect $check.Hud
    $saved = New-Object H+POINT; [void][H]::GetCursorPos([ref]$saved)
    [void][H]::SetCursorPos([int]($h.L + 20 * $check.Scale), [int]($h.B - 12 * $check.Scale)); Start-Sleep -Milliseconds 700
    $refresh = Find-Named $root 'Refresh the limits'
    if (-not $refresh) { "  FAIL no 'Refresh the limits' button on the HUD" }
    else {
      $br = $refresh.Current.BoundingRectangle
      $cx = [int]($br.X + $br.Width / 2); $cy = [int]($br.Y + $br.Height / 2)
      # Click only where the HUD itself is: never on someone's window.
      $at = [H]::RootAt($cx, $cy)
      if ($at -ne $check.Hud) { "  mouse click skipped: the window at ($cx,$cy) is {0} ""{1}"", not the HUD" -f $at, [H]::Title($at) }
      else {
        Remove-Item (Join-Path $dir 'clicked.txt') -ErrorAction SilentlyContinue
        $before = Fg
        Click-At $cx $cy; Start-Sleep -Milliseconds 900
        $clicked = (Get-Content (Join-Path $dir 'clicked.txt') -ErrorAction SilentlyContinue) -contains 'refresh'
        $after = Fg
        "  {0} mouse click on 'Refresh the limits' ran it and handed the focus back: clicked={1} before={2} after={3}" -f (Pass ($clicked -and $before -eq $after)), $clicked, $before, $after
      }
      Remove-Item (Join-Path $dir 'clicked.txt') -ErrorAction SilentlyContinue
      $before = Fg
      try { $refresh.GetCurrentPattern([Windows.Automation.InvokePattern]::Pattern).Invoke(); $inv = 'ok' } catch { $inv = "failed: $_" }
      Start-Sleep -Milliseconds 900
      $clicked = (Get-Content (Join-Path $dir 'clicked.txt') -ErrorAction SilentlyContinue) -contains 'refresh'
      $after = Fg
      "  {0} UIA Invoke on 'Refresh the limits': {1} clicked={2} before={3} after={4}" -f (Pass ($clicked -and $before -eq $after)), $inv, $clicked, $before, $after
    }
    [void][H]::SetCursorPos($saved.X, $saved.Y)
    # A click on a row opens the Limits page (the check records it).
    $row = Find-Named $root 'Claude*'
    if ($row) {
      $br = $row.Current.BoundingRectangle
      $cx = [int]($br.X + 12 * $check.Scale); $cy = [int]($br.Y + $br.Height / 2)
      if ([H]::RootAt($cx, $cy) -eq $check.Hud) {
        Remove-Item (Join-Path $dir 'clicked.txt') -ErrorAction SilentlyContinue
        Click-At $cx $cy; Start-Sleep -Milliseconds 700
        $clicked = (Get-Content (Join-Path $dir 'clicked.txt') -ErrorAction SilentlyContinue) -contains 'limits'
        "  {0} a click on Claude's row asks for the Limits page: clicked={1}" -f (Pass $clicked), $clicked
      } else { "  row click skipped: the point isn't on the HUD" }
    } else { "  FAIL no row for Claude on the HUD" ; $script:failures++ }
    $other.Process.Kill()
  }

  if ($Tests -contains 'drag') {
    # A drag by the caption region (the top edge) snaps to the nearest corner, and the focus goes back.
    $other = Other-App
    $h = Rect $check.Hud
    $gx = [int](($h.L + $h.R) / 2); $gy = $h.T + [int](5 * $check.Scale)
    $work = [System.Windows.Forms.Screen]::FromHandle($check.Hud).WorkingArea
    if ([H]::RootAt($gx, $gy) -ne $check.Hud) { "  drag skipped: the HUD's top edge isn't the HUD at ($gx,$gy)" }
    else {
      $before = Fg
      $saved = New-Object H+POINT; [void][H]::GetCursorPos([ref]$saved)
      [void][H]::SetCursorPos($gx, $gy); Start-Sleep -Milliseconds 150
      [H]::mouse_event(2, 0, 0, 0, [UIntPtr]::Zero); Start-Sleep -Milliseconds 150
      $tx = $work.Left + [int]($work.Width * 0.3); $ty = $work.Top + [int]($work.Height * 0.3)
      for ($i = 1; $i -le 20; $i++) { [void][H]::SetCursorPos([int]($gx + ($tx - $gx) * $i / 20), [int]($gy + ($ty - $gy) * $i / 20)); Start-Sleep -Milliseconds 25 }
      Start-Sleep -Milliseconds 150
      [H]::mouse_event(4, 0, 0, 0, [UIntPtr]::Zero)
      [void][H]::SetCursorPos($saved.X, $saved.Y)
      Start-Sleep -Milliseconds 1200
      $h = Rect $check.Hud
      $m = [int](12 * $check.Scale)
      $snapped = [math]::Abs($h.L - ($work.Left + $m)) -le 2 -and [math]::Abs($h.T - ($work.Top + $m)) -le 2
      $after = Fg
      "  {0} dragged toward the top left: snapped there={1} rect=({2},{3},{4},{5}) work=({6},{7}) before={8} after={9}" -f (Pass ($snapped -and $before -eq $after)), $snapped, $h.L, $h.T, $h.R, $h.B, $work.Left, $work.Top, $before, $after
    }
    $other.Process.Kill()
    [void](Command 'corner:BottomRight'); Start-Sleep -Milliseconds 500
  }

  if ($Tests -contains 'topmost') {
    [void][H]::Front($check.Behind); Start-Sleep -Milliseconds 500
    $h = Rect $check.Hud
    $at = [H]::RootAt([int](($h.L + $h.R) / 2), [int](($h.T + $h.B) / 2))
    "  {0} on top of the window in front: window at the HUD's centre is the HUD = {1}" -f (Pass ($at -eq $check.Hud)), ($at -eq $check.Hud)
  }

  if ($Tests -contains 'taskbar') {
    $trayCond = New-Object Windows.Automation.PropertyCondition([Windows.Automation.AutomationElement]::ClassNameProperty, 'Shell_TrayWnd')
    $tray = [Windows.Automation.AutomationElement]::RootElement.FindFirst([Windows.Automation.TreeScope]::Children, $trayCond)
    if ($tray) {
      $buttons = $tray.FindAll([Windows.Automation.TreeScope]::Descendants, (New-Object Windows.Automation.PropertyCondition([Windows.Automation.AutomationElement]::ControlTypeProperty, [Windows.Automation.ControlType]::Button)))
      $named = @($buttons | Where-Object { $_.Current.Name -match 'ClaudeBar HUD' } | ForEach-Object { '"' + $_.Current.Name + '"' })
      "  {0} no taskbar button of its own: {1}" -f (Pass ($named.Count -eq 0)), ($(if ($named.Count) { $named -join ', ' } else { 'none' }))
    } else { "  taskbar: Shell_TrayWnd not found" }
  }

  if ($Tests -contains 'fullscreen') {
    # Full screen on the HUD's screen hides it; back to a window shows it.
    "  notification state, windowed: " + (Quns)
    foreach ($how in 'fullscreen', 'cover') {
      [void](Command $how)
      [void][H]::Front($check.Behind); Start-Sleep -Seconds 2
      $hidden = -not [H]::IsWindowVisible($check.Hud)
      "  {0} hidden over '{1}': hidden={2} foreground={3} notification state={4}" -f (Pass $hidden), $how, $hidden, (Fg), (Quns)
      [void](Command 'restore'); [void][H]::Front($check.Behind); Start-Sleep -Seconds 2
      $shown = [H]::IsWindowVisible($check.Hud)
      "  {0} shown again after '{1}': visible={2}" -f (Pass $shown), $how, $shown
    }
  }

  if ($Tests -contains 'screens' -and [System.Windows.Forms.Screen]::AllScreens.Count -gt 1) {
    # Full screen on the other screen leaves the HUD alone.
    [void](Command 'fullscreen-other-screen'); [void][H]::Front($check.Behind); Start-Sleep -Seconds 2
    $shown = [H]::IsWindowVisible($check.Hud)
    "  {0} still shown with a full-screen window on the other screen: visible={1}" -f (Pass $shown), $shown
    [void](Command 'restore'); Start-Sleep -Seconds 1
  }

  if ($Tests -contains 'contrast') {
    # On the real Mica, the HUD inactive behind another window.
    [void][H]::Front($check.Behind); Start-Sleep -Milliseconds 1500
    $runs = @(Contrast $check "$theme-contrast")
    $low = @($runs | Where-Object { $_.Ratio -lt 4.5 })
    "  {0} text contrast, {1} runs: lowest {2:N2}:1" -f (Pass ($runs.Count -gt 0 -and $low.Count -eq 0)), $runs.Count, (($runs | Measure-Object Ratio -Minimum).Minimum)
    foreach ($run in $low) { "    FAIL {0:N2}:1 ""{1}""" -f $run.Ratio, $run.Name }
  }

  if ($Tests -contains 'shots') {
    [void](Command "plain-$theme"); [void][H]::Front($check.Behind); Start-Sleep -Milliseconds 1500
    $s = [int](16 * $check.Scale)
    (Grab (Rect $check.Hud) "hud-$theme" $s).Dispose()
    "  screenshot: " + (Join-Path $Shots "hud-$theme.png")
  }
  Stop-Check $check

  if ($Tests -contains 'calibrate' -and $theme -eq 'light') {
    # The contrast check, trusted only if it catches the tertiary text (3.3:1 on light Mica, the design).
    $check = Start-Check $theme $null '--calibrate'
    if ($check) {
      [void][H]::Front($check.Behind); Start-Sleep -Milliseconds 1500
      $runs = @(Contrast $check 'calibrate')
      $lowest = $runs | Sort-Object Ratio | Select-Object -First 1
      $caught = $lowest -and $lowest.Ratio -lt 4.5
      "  {0} calibration, one label in TextFillColorTertiaryBrush: lowest {1:N2}:1 ""{2}"" (about 3.3:1 expected)" -f (Pass $caught), $lowest.Ratio, $lowest.Name
      Stop-Check $check
    }
  }

  if ($Tests -contains 'shots') {
    $check = Start-Check $theme $null @('--sample', 'fine')
    if ($check) {
      [void](Command "plain-$theme"); [void][H]::Front($check.Behind); Start-Sleep -Milliseconds 1500
      $s = [int](16 * $check.Scale)
      (Grab (Rect $check.Hud) "fine-$theme" $s).Dispose()
      "  screenshot: " + (Join-Path $Shots "fine-$theme.png")
      Stop-Check $check
    }
    $check = Start-Check $theme 'strip'
    if ($check) {
      [void](Command "plain-$theme"); [void][H]::Front($check.Behind); Start-Sleep -Milliseconds 1500
      $s = [int](16 * $check.Scale)
      (Grab (Rect $check.Hud) "strip-$theme" $s).Dispose()
      "  screenshot: " + (Join-Path $Shots "strip-$theme.png")
      Stop-Check $check
    }
  }
}
"== {0} failed" -f $script:failures
if ($script:failures -gt 0) { exit 1 }
