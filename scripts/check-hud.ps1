# Checks the HUD's window on a Windows PC, as the spike's probe did
# (spikes/hud-window/probe.ps1, design-concept/hud/research.md): it opens the
# real HUD on the sample reading (`ClaudeBar.exe --hud-check`), beside a
# ClaudeBar that may be running, and measures from the screen what it does.
# It moves the mouse, clicks the HUD and brings windows to the front, so run
# it on a PC nobody is using. Windows PowerShell 5.1 or PowerShell 7.
# It prints PASS or FAIL per check, and UNVERIFIED for a check it couldn't
# make (a skipped click, a group with nothing to measure): those never count
# as a pass. It exits 1 on any FAIL, 2 when nothing failed but something went
# unverified, and 0 only when every check ran and passed.
#   .\scripts\check-hud.ps1 [-Exe out\win-x64\ClaudeBar.exe] [-Shots dir] [-Themes light,dark] [-Tests theme,...]
# The `theme` step switches the Windows apps theme (and puts it back), as Settings does.
param(
  [string]$Exe = (Join-Path $PSScriptRoot '..\out\win-x64\ClaudeBar.exe'),
  [string]$Shots = (Join-Path $env:TEMP 'claudebar-hud-shots'),
  [string[]]$Themes = @('light', 'dark'),
  [string[]]$Tests = @('focus', 'measure', 'click', 'style', 'drag', 'topmost', 'taskbar', 'fullscreen', 'screens', 'contrast', 'calibrate', 'notify', 'shots', 'theme')
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
  [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern IntPtr FindWindowExW(IntPtr parent, IntPtr after, string cls, string title);
  // Every top-level window of a class. A notification's CoreWindow isn't among
  // the UI Automation root's children, but FromHandle on it finds its buttons.
  public static System.Collections.Generic.List<IntPtr> OfClass(string cls) {
    var all = new System.Collections.Generic.List<IntPtr>(); var h = IntPtr.Zero;
    while ((h = FindWindowExW(IntPtr.Zero, h, cls, null)) != IntPtr.Zero) all.Add(h);
    return all; }
  [DllImport("shell32.dll")] public static extern int SHQueryUserNotificationState(out int state);
  [DllImport("dwmapi.dll")] public static extern int DwmGetWindowAttribute(IntPtr h, int attribute, out RECT r, int size);
  // The window as drawn, without the invisible resize borders GetWindowRect includes.
  public static RECT Frame(IntPtr h) { RECT r; if (DwmGetWindowAttribute(h, 9, out r, 16) != 0) GetWindowRect(h, out r); return r; }
  [DllImport("user32.dll")] public static extern bool GetClientRect(IntPtr h, out RECT r);
  [DllImport("user32.dll")] public static extern bool ClientToScreen(IntPtr h, ref POINT p);
  // The content, inside the frame's border, in screen pixels.
  public static RECT Client(IntPtr h) { RECT c; GetClientRect(h, out c); var o = new POINT(); ClientToScreen(h, ref o); return new RECT { L = o.X, T = o.Y, R = o.X + c.R, B = o.Y + c.B }; }
  // The usual way a test harness gets past the foreground lock: an Alt key event first.
  public static bool Front(IntPtr h) { keybd_event(0x12, 0, 0, UIntPtr.Zero); var ok = SetForegroundWindow(h); keybd_event(0x12, 0, 2, UIntPtr.Zero); return ok; }
  public static string Title(IntPtr h) { var s = new StringBuilder(256); GetWindowTextW(h, s, 256); return s.ToString(); }
  [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetClassNameW(IntPtr h, StringBuilder s, int n);
  public static string ClassOf(IntPtr h) { var s = new StringBuilder(256); GetClassNameW(h, s, 256); return s.ToString(); }
  public static IntPtr RootAt(int x, int y) { var p = new POINT { X = x, Y = y }; return GetAncestor(WindowFromPoint(p), 2); }
  [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern IntPtr SendMessageTimeoutW(IntPtr h, uint m, UIntPtr w, string l, uint f, uint t, out UIntPtr r);
  // WM_SETTINGCHANGE to every top-level window, as Settings sends it ("ImmersiveColorSet" for the theme).
  public static void SettingChange(string what) { UIntPtr r; SendMessageTimeoutW((IntPtr)0xffff, 0x1A, UIntPtr.Zero, what, 2, 5000, out r); }

  // WCAG contrast from a BGRA capture. The background is the median luminance
  // of a 2 px ring around the box; the text is the 98th percentile of contrast
  // among the box's pixels that differ from it, so a ClearType fringe doesn't decide.
  // Only the HUD's content counts (cx, cy, cw, ch, in the capture): not the
  // frame's border, nor what shows past its rounded corners (a square of
  // `corner` px in each), which the last row's box reaches.
  static double Linear(byte c) { var v = c / 255.0; return v <= 0.04045 ? v / 12.92 : Math.Pow((v + 0.055) / 1.055, 2.4); }
  static double Luminance(byte[] p, int i) { return 0.2126 * Linear(p[i + 2]) + 0.7152 * Linear(p[i + 1]) + 0.0722 * Linear(p[i]); }
  static double Ratio(double a, double b) { return (Math.Max(a, b) + 0.05) / (Math.Min(a, b) + 0.05); }
  static bool Content(int xx, int yy, int cx, int cy, int cw, int ch, int corner) {
    if (xx < cx || yy < cy || xx >= cx + cw || yy >= cy + ch) return false;
    var nearX = xx < cx + corner || xx >= cx + cw - corner; var nearY = yy < cy + corner || yy >= cy + ch - corner;
    return !(nearX && nearY); }
  public static double TextContrast(byte[] p, int stride, int x, int y, int w, int h, int cx, int cy, int cw, int ch, int corner) {
    var ring = new System.Collections.Generic.List<double>();
    for (int yy = y - 2; yy < y + h + 2; yy++) for (int xx = x - 2; xx < x + w + 2; xx++) {
      if (xx >= x && xx < x + w && yy >= y && yy < y + h) continue;
      if (!Content(xx, yy, cx, cy, cw, ch, corner)) continue;
      ring.Add(Luminance(p, yy * stride + xx * 4)); }
    if (ring.Count == 0) return -1;
    ring.Sort(); var background = ring[ring.Count / 2];
    var inside = new System.Collections.Generic.List<double>();
    for (int yy = y; yy < y + h; yy++) for (int xx = x; xx < x + w; xx++) {
      if (!Content(xx, yy, cx, cy, cw, ch, corner)) continue;
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
$script:unverified = 0
function Unverified($what) { $script:unverified++; "  UNVERIFIED $what" }
# A command to the check, and whether it was done, looked for every `every` ms for 5 s.
function Command($c, $every = 100) {
  $ack = Join-Path $dir ("ack-{0}.txt" -f $c.Replace(':', '-'))
  Remove-Item $ack -ErrorAction SilentlyContinue
  Set-Content -Path (Join-Path $dir 'cmd.txt') -Value $c
  for ($i = 0; $i -lt 5000 / $every -and -not (Test-Path $ack); $i++) { Start-Sleep -Milliseconds $every }
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
# The mean luminance (0-255) of the HUD's left margin, where only the material shows.
function Margin-Luminance($hud, $s) {
  $h = Rect $hud
  $l = $h.L + [int](2 * $s); $t = $h.T + [int](40 * $s); $w = [int](8 * $s); $hh = [math]::Max(4, ($h.B - $h.T) - [int](80 * $s))
  $bmp = New-Object Drawing.Bitmap $w, $hh
  $g = [Drawing.Graphics]::FromImage($bmp); $g.CopyFromScreen($l, $t, 0, 0, (New-Object Drawing.Size $w, $hh)); $g.Dispose()
  $sum = 0; $n = 0
  for ($y = 0; $y -lt $hh; $y += 2) { for ($x = 0; $x -lt $w; $x += 2) { $c = $bmp.GetPixel($x, $y); $sum += 0.2126 * $c.R + 0.7152 * $c.G + 0.0722 * $c.B; $n++ } }
  $bmp.Dispose()
  $sum / $n
}
# The Windows apps theme (1 light, 0 dark), as Settings switches it.
function Set-AppsTheme($light) {
  Set-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize' AppsUseLightTheme ([int]$light)
  [H]::SettingChange('ImmersiveColorSet')
}
function Other-App {
  # Another process in front, as an editor would be. (Windows 11's Notepad hands
  # off to a packaged process, so a plain WinForms window in its own process.)
  $form = 'Add-Type -AssemblyName System.Windows.Forms; $f = New-Object Windows.Forms.Form; $f.Text = ''Other app''; $f.StartPosition = ''Manual''; $f.Location = New-Object Drawing.Point 200, 200; $f.Size = New-Object Drawing.Size 420, 260; [Windows.Forms.Application]::Run($f)'
  $p = Start-Process powershell -ArgumentList '-NoProfile', '-Command', $form -PassThru -WindowStyle Hidden
  $other = [IntPtr]::Zero
  for ($i = 0; $i -lt 100 -and $other -eq [IntPtr]::Zero; $i++) { Start-Sleep -Milliseconds 100; $other = [H]::FindWindowW([NullString]::Value, 'Other app') }
  [void][H]::Front($other); Start-Sleep -Milliseconds 800
  # Without it in front, the focus checks after this compare nothing: unverified, not passed.
  if ([H]::GetForegroundWindow() -ne $other) { Write-Host (Unverified "focus handed back to another process: the other app didn't come to the front ($(Fg))") }
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
# A click at (x, y); $script:under says which window was there as the button went down.
function Click-At($x, $y) {
  $saved = New-Object H+POINT; [void][H]::GetCursorPos([ref]$saved)
  [void][H]::SetCursorPos($x, $y); Start-Sleep -Milliseconds 120
  $at = [H]::RootAt($x, $y); $script:under = '{0} "{1}" {2}' -f $at, [H]::Title($at), [H]::ClassOf($at); $script:at = (Get-Date).ToString('HH:mm:ss.fff')
  [H]::mouse_event(2, 0, 0, 0, [UIntPtr]::Zero); Start-Sleep -Milliseconds 60; [H]::mouse_event(4, 0, 0, 0, [UIntPtr]::Zero)
  Start-Sleep -Milliseconds 120
  [void][H]::SetCursorPos($saved.X, $saved.Y)
}
# Every text run on the HUD, against the HUD around it (design, acceptance check 10).
# Each row reads as one sentence, its texts left out of UI Automation's control
# view, so the runs come from the raw view: a TextBlock or a link each, not the row.
function Contrast($check, $name) {
  $h = Rect $check.Hud
  $bmp = Grab $h $name 4
  $data = $bmp.LockBits((New-Object Drawing.Rectangle 0, 0, $bmp.Width, $bmp.Height), [Drawing.Imaging.ImageLockMode]::ReadOnly, [Drawing.Imaging.PixelFormat]::Format32bppArgb)
  $bytes = New-Object byte[] ($data.Stride * $bmp.Height)
  [Runtime.InteropServices.Marshal]::Copy($data.Scan0, $bytes, 0, $bytes.Length)
  $bmp.UnlockBits($data)
  $root = [Windows.Automation.AutomationElement]::FromHandle($check.Hud)
  # The content in the capture, and the rounded corner's size (8 effective px, DWMWCP_ROUND).
  $c = [H]::Client($check.Hud); $cx = $c.L - $h.L + 4; $cy = $c.T - $h.T + 4; $corner = [int][math]::Ceiling(8 * $check.Scale)
  $types = New-Object Windows.Automation.OrCondition(
    (New-Object Windows.Automation.PropertyCondition([Windows.Automation.AutomationElement]::ControlTypeProperty, [Windows.Automation.ControlType]::Text)),
    (New-Object Windows.Automation.PropertyCondition([Windows.Automation.AutomationElement]::ControlTypeProperty, [Windows.Automation.ControlType]::Hyperlink)))
  $raw = New-Object Windows.Automation.CacheRequest
  $raw.TreeFilter = [Windows.Automation.Automation]::RawViewCondition
  foreach ($p in 'NameProperty', 'BoundingRectangleProperty', 'ClassNameProperty') { $raw.Add([Windows.Automation.AutomationElement]::$p) }
  $raw.Push()
  try { $all = $root.FindAll([Windows.Automation.TreeScope]::Descendants, $types) } finally { $raw.Pop() }
  $results = foreach ($e in $all) {
    $r = $e.Cached.BoundingRectangle
    if ($e.Cached.ClassName -eq 'HudRow' -or $r.IsEmpty -or $r.Width -lt 2 -or $r.Height -lt 2 -or -not $e.Cached.Name) { continue }
    $x = [int]$r.X - $h.L + 4; $y = [int]$r.Y - $h.T + 4
    $ratio = [H]::TextContrast($bytes, $data.Stride, $x, $y, [int]$r.Width, [int]$r.Height, $cx, $cy, $c.R - $c.L, $c.B - $c.T, $corner)
    [pscustomobject]@{ Name = $e.Cached.Name; Ratio = $ratio }
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
    [void][H]::SetCursorPos([int]($h.L + 20 * $check.Scale), [int]($h.B - 12 * $check.Scale))
    # The footer's buttons show once the pointer is over the card: wait for them.
    $refresh = $null
    for ($i = 0; $i -lt 30 -and -not $refresh; $i++) { Start-Sleep -Milliseconds 100; $refresh = Find-Named $root 'Refresh the limits' }
    if (-not $refresh) { "  {0} no 'Refresh the limits' button on the HUD" -f (Pass $false) }
    else {
      $br = $refresh.Current.BoundingRectangle
      $cx = [int]($br.X + $br.Width / 2); $cy = [int]($br.Y + $br.Height / 2)
      # Click only where the HUD itself is: never on someone's window.
      $at = [H]::RootAt($cx, $cy)
      if ($at -ne $check.Hud) { Unverified ("mouse click on 'Refresh the limits': the window at ($cx,$cy) is {0} ""{1}"", not the HUD" -f $at, [H]::Title($at)) }
      else {
        # Twenty times each: the hand-back raced WinUI's own activation, and a redraw (each
        # read, each minute) could land under the pointer, so a few clicks could pass by luck.
        $results = for ($n = 0; $n -lt 20; $n++) {
          [void][H]::Front($other.Window); Start-Sleep -Milliseconds 400
          Remove-Item (Join-Path $dir 'clicked.txt') -ErrorAction SilentlyContinue
          $before = Fg
          Click-At $cx $cy; Start-Sleep -Milliseconds 900
          $clicked = (Get-Content (Join-Path $dir 'clicked.txt') -ErrorAction SilentlyContinue) -contains 'refresh'
          $after = Fg
          [pscustomobject]@{ Ok = $clicked -and $before -eq $after; Text = "#$n at $script:at clicked=$clicked under=$script:under before=$before after=$after" }
        }
        $bad = @($results | Where-Object { -not $_.Ok })
        "  {0} mouse click on 'Refresh the limits' ran it and handed the focus back, 20 times: {1} failed{2}" -f (Pass ($bad.Count -eq 0)), $bad.Count, $(if ($bad) { " (" + (($bad | ForEach-Object Text) -join '; ') + ")" } else { "" })
      }
      $results = for ($n = 0; $n -lt 20; $n++) {
        [void][H]::Front($other.Window); Start-Sleep -Milliseconds 400
        Remove-Item (Join-Path $dir 'clicked.txt') -ErrorAction SilentlyContinue
        $before = Fg
        # A refresh draws the card again: the button found before it is gone, so find it each time.
        $button = $null
        for ($i = 0; $i -lt 30 -and -not $button; $i++) { $button = Find-Named $root 'Refresh the limits'; if (-not $button) { Start-Sleep -Milliseconds 100 } }
        try { $button.GetCurrentPattern([Windows.Automation.InvokePattern]::Pattern).Invoke(); $inv = 'ok' } catch { $inv = "failed: $_" }
        Start-Sleep -Milliseconds 900
        $clicked = (Get-Content (Join-Path $dir 'clicked.txt') -ErrorAction SilentlyContinue) -contains 'refresh'
        $after = Fg
        [pscustomobject]@{ Ok = $clicked -and $before -eq $after; Text = "$inv clicked=$clicked before=$before after=$after" }
      }
      $bad = @($results | Where-Object { -not $_.Ok })
      "  {0} UIA Invoke on 'Refresh the limits', 20 times: {1} failed{2}" -f (Pass ($bad.Count -eq 0)), $bad.Count, $(if ($bad) { " (" + $bad[0].Text + ")" } else { "" })
      # A redraw (each read, the minute's tick) with the pointer resting on Refresh, and a
      # press at once, before XAML tells the new card the pointer is over it: the click runs.
      $button = Find-Named $root 'Refresh the limits'
      if (-not $button) { Unverified "a press just after a redraw: no 'Refresh the limits' on the HUD" }
      else {
        $br = $button.Current.BoundingRectangle
        $bx = [int]($br.X + $br.Width / 2); $by = [int]($br.Y + $br.Height / 2)
        [void][H]::SetCursorPos($bx, $by); Start-Sleep -Milliseconds 500
        $results = for ($n = 0; $n -lt 10; $n++) {
          [void][H]::Front($other.Window); Start-Sleep -Milliseconds 400
          Remove-Item (Join-Path $dir 'clicked.txt') -ErrorAction SilentlyContinue
          $before = Fg
          $acked = Command 'render' 5
          [H]::mouse_event(2, 0, 0, 0, [UIntPtr]::Zero); Start-Sleep -Milliseconds 60; [H]::mouse_event(4, 0, 0, 0, [UIntPtr]::Zero)
          Start-Sleep -Milliseconds 900
          $clicked = (Get-Content (Join-Path $dir 'clicked.txt') -ErrorAction SilentlyContinue) -contains 'refresh'
          $after = Fg
          [pscustomobject]@{ Ok = $clicked -and $acked -and $before -eq $after; Text = "#$n clicked=$clicked redraw asked=$acked before=$before after=$after" }
        }
        $bad = @($results | Where-Object { -not $_.Ok })
        "  {0} a press on 'Refresh the limits' just after a redraw under the resting pointer, 10 times: {1} failed{2}" -f (Pass ($bad.Count -eq 0)), $bad.Count, $(if ($bad) { " (" + (($bad | ForEach-Object Text) -join '; ') + ")" } else { "" })
      }
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
      } else { Unverified "a click on Claude's row: the point isn't on the HUD" }
    } else { "  {0} no row for Claude on the HUD" -f (Pass $false) }
    $other.Process.Kill()
  }

  if ($Tests -contains 'style') {
    # Card, strip, card again (Settings -> HUD -> Style, or the footer's Collapse then a click):
    # the card comes back at the size it had, its bars drawn again.
    $card = Rect $check.Hud
    [void](Command 'style:strip'); Start-Sleep -Milliseconds 800
    $strip = Rect $check.Hud
    [void](Command 'style:card'); Start-Sleep -Milliseconds 800
    $again = Rect $check.Hud
    $ok = ($strip.B - $strip.T) -lt ($card.B - $card.T) -and ($again.B - $again.T) -eq ($card.B - $card.T) -and ($again.R - $again.L) -eq ($card.R - $card.L)
    " {0} card -> strip -> card: heights {1} -> {2} -> {3}, widths {4} -> {5}" -f (Pass $ok), ($card.B - $card.T), ($strip.B - $strip.T), ($again.B - $again.T), ($card.R - $card.L), ($again.R - $again.L)
    Get-Content (Join-Path $dir 'crash.txt') -ErrorAction SilentlyContinue | Select-Object -First 6 | ForEach-Object { "    crash.txt: $_" }
  }

  if ($Tests -contains 'drag') {
    # A drag by the caption region (the top edge) snaps to the nearest corner, and the focus goes back.
    $other = Other-App
    $h = Rect $check.Hud
    $gx = [int](($h.L + $h.R) / 2); $gy = $h.T + [int](5 * $check.Scale)
    $work = [System.Windows.Forms.Screen]::FromHandle($check.Hud).WorkingArea
    if ([H]::RootAt($gx, $gy) -ne $check.Hud) { Unverified "drag: the HUD's top edge isn't the HUD at ($gx,$gy)" }
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
    } else { Unverified "no taskbar button of its own: Shell_TrayWnd not found" }
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

  if ($Tests -contains 'screens' -and [System.Windows.Forms.Screen]::AllScreens.Count -lt 2) { Unverified "full screen on the other screen: this PC has one screen" }
  if ($Tests -contains 'screens' -and [System.Windows.Forms.Screen]::AllScreens.Count -gt 1) {
    # Full screen on the other screen leaves the HUD alone.
    [void](Command 'fullscreen-other-screen'); [void][H]::Front($check.Behind); Start-Sleep -Seconds 2
    $shown = [H]::IsWindowVisible($check.Hud)
    "  {0} still shown with a full-screen window on the other screen: visible={1}" -f (Pass $shown), $shown
    [void](Command 'restore'); Start-Sleep -Seconds 1
  }

  if ($Tests -contains 'notify' -and $theme -eq $Themes[0]) {
    # A crossing notification, through Windows and back: its *Quiet until reset* quiets that limit.
    [void](Command 'notify')
    $cond = New-Object Windows.Automation.PropertyCondition([Windows.Automation.AutomationElement]::NameProperty, 'Quiet until reset')
    $button = $null
    for ($i = 0; $i -lt 16 -and -not $button; $i++) {
      Start-Sleep -Milliseconds 500
      foreach ($w in [H]::OfClass('Windows.UI.Core.CoreWindow')) {
        try { $button = [Windows.Automation.AutomationElement]::FromHandle($w).FindFirst([Windows.Automation.TreeScope]::Descendants, $cond) } catch { }
        if ($button) { break }
      }
    }
    $sent = Get-Content (Join-Path $dir 'notify.txt') -ErrorAction SilentlyContinue
    "  notification: $sent; notification state: " + (Quns)
    # Windows took it, while accepting banners: the banner must be there. Turned
    # off by the person, or Do not disturb: nothing to click. Else the app failed to send it.
    if (-not $button) {
      if ($sent -like '*Disabled*' -or (Quns) -ne 'ACCEPTS_NOTIFICATIONS') { Unverified "'Quiet until reset' on the notification: no banner ($sent; $(Quns))" }
      elseif ($sent -like 'shown*') { "  {0} 'Quiet until reset' on the notification: Windows took it, but no banner with it is on screen" -f (Pass $false) }
      else { "  {0} the notification wasn't sent: {1}" -f (Pass $false), $sent }
    }
    else {
      Remove-Item (Join-Path $dir 'activated.txt') -ErrorAction SilentlyContinue
      try { $button.GetCurrentPattern([Windows.Automation.InvokePattern]::Pattern).Invoke() } catch { "  invoke failed: $_" }
      for ($i = 0; $i -lt 50 -and -not (Test-Path (Join-Path $dir 'activated.txt')); $i++) { Start-Sleep -Milliseconds 100 }
      $got = Get-Content (Join-Path $dir 'activated.txt') -ErrorAction SilentlyContinue
      $got | ForEach-Object { "    $_" }
      $quiet = ($got -match '^quiet=omp/Kimi 7d$').Count -eq 1 -and -not ($got -match '^quietUntil=(none|no such limit)$')
      "  {0} 'Quiet until reset' on the notification quiets omp's Kimi 7d" -f (Pass $quiet)
    }
  }

  if ($Tests -contains 'contrast') {
    # On the real Mica, the HUD inactive behind another window.
    [void][H]::Front($check.Behind); Start-Sleep -Milliseconds 1500
    $runs = @(Contrast $check "$theme-contrast")
    $low = @($runs | Where-Object { $_.Ratio -lt 4.5 })
    if ($runs.Count -eq 0) { Unverified "text contrast: no text runs found on the HUD" }
    else { "  {0} text contrast, {1} runs: lowest {2:N2}:1" -f (Pass ($low.Count -eq 0)), $runs.Count, (($runs | Measure-Object Ratio -Minimum).Minimum) }
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
      if ($runs.Count -eq 0) { Unverified "calibration: no text runs found on the HUD" }
      else { "  {0} calibration, one label in TextFillColorTertiaryBrush: lowest {1:N2}:1 ""{2}"" (about 3.3:1 expected)" -f (Pass $caught), $lowest.Ratio, $lowest.Name }
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

if ($Tests -contains 'theme') {
  # Windows switching between light and dark with the HUD up, twice each way: the HUD
  # follows Windows here (no --theme), stays up, and draws on the new theme's Mica
  # in that theme's text (the contrast holds only with dark text on light Mica).
  "== theme switch"
  $was = (Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize').AppsUseLightTheme
  $check = Start-Check 'system' $null
  if ($check) {
    try {
      foreach ($light in @((1 - $was), $was, (1 - $was), $was)) {
        $name = if ($light -eq 1) { 'light' } else { 'dark' }
        Set-AppsTheme $light; Start-Sleep -Seconds 4
        $alive = -not $check.Process.HasExited
        $shown = $alive -and [H]::IsWindowVisible($check.Hud)
        if (-not $shown) {
          "  {0} switched to {1}: the check process alive={2}, HUD shown={3}{4}" -f (Pass $false), $name, $alive, $shown, $(if (-not $alive) { ' exit=0x{0:X}' -f $check.Process.ExitCode } else { '' })
          Get-Content (Join-Path $dir 'crash.txt') -ErrorAction SilentlyContinue | Select-Object -First 15 | ForEach-Object { "    crash.txt: $_" }
          break
        }
        [void][H]::Front($check.Behind); Start-Sleep -Milliseconds 1500
        $lum = Margin-Luminance $check.Hud $check.Scale
        $mica = if ($light -eq 1) { $lum -gt 170 } else { $lum -lt 90 }
        $runs = @(Contrast $check "theme-switched-$name")
        $low = @($runs | Where-Object { $_.Ratio -lt 4.5 })
        "  {0} switched to {1}: HUD still up, Mica luminance {2:N0} ({3}), text contrast over {4} runs lowest {5:N2}:1, screenshot theme-switched-{1}.png" -f (Pass ($mica -and $runs.Count -gt 0 -and $low.Count -eq 0)), $name, $lum, $(if ($light -eq 1) { 'light: over 170' } else { 'dark: under 90' }), $runs.Count, (($runs | Measure-Object Ratio -Minimum).Minimum)
      }
    }
    finally { Set-AppsTheme $was }
    if (-not $check.Process.HasExited) { Stop-Check $check }
  }
}
"== {0} failed, {1} unverified" -f $script:failures, $script:unverified
if ($script:failures -gt 0) { exit 1 }
if ($script:unverified -gt 0) { exit 2 }
