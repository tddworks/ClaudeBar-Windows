<#
Runs the app's self-test and checks its report. Exits non-zero if a check fails.

  .\selftest.ps1 -Exe .\out\win-x64-aot\ClaudeBarSpike.exe
  .\selftest.ps1 -Alias -Report out\report-msix.json   # the registered MSIX package, via its execution alias
  -ScanRoot <folder>   the folder the async scan walks (default: ~\.omp\agent\sessions)
  -Screenshot <png>    also capture the window (needs an interactive desktop)
#>
param(
    [string] $Exe,
    [switch] $Alias,
    [string] $Report = (Join-Path $PSScriptRoot 'out\selftest.json'),
    [string] $ScanRoot,
    [string] $Screenshot
)

$ErrorActionPreference = 'Stop'
$Report = [IO.Path]::GetFullPath($Report)
Remove-Item $Report -ErrorAction SilentlyContinue
$arguments = @('--selftest', "`"$Report`"", '--hold', '3')
if ($ScanRoot) { $arguments += @('--scan-root', "`"$([IO.Path]::GetFullPath($ScanRoot))`"") }
$target = if ($Alias) { 'claudebar-spike.exe' } else { (Resolve-Path $Exe).Path }
$started = Get-Date
Start-Process $target -ArgumentList $arguments | Out-Null

$deadline = $started.AddSeconds(120)
while (-not (Test-Path $Report) -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 250 }
if (-not (Test-Path $Report)) { throw 'the app wrote no report within 120 s' }
'report after {0:N1} s' -f ((Get-Date) - $started).TotalSeconds
Start-Sleep -Milliseconds 500

if ($Screenshot) {
    Add-Type -AssemblyName System.Drawing
    Add-Type @'
using System; using System.Runtime.InteropServices;
public static class SpikeWindow {
  public struct RECT { public int L, T, R, B; }
  [DllImport("user32.dll")] public static extern bool SetProcessDpiAwarenessContext(IntPtr v);
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
  [DllImport("dwmapi.dll")] public static extern int DwmGetWindowAttribute(IntPtr h, int a, out RECT r, int s);
}
'@
    [SpikeWindow]::SetProcessDpiAwarenessContext([IntPtr](-4)) | Out-Null
    $window = Get-Process ClaudeBarSpike -ErrorAction SilentlyContinue | Where-Object MainWindowHandle -ne 0 | Select-Object -First 1
    if ($window) {
        [SpikeWindow]::SetForegroundWindow($window.MainWindowHandle) | Out-Null
        Start-Sleep -Milliseconds 300
        $r = New-Object SpikeWindow+RECT
        [SpikeWindow]::DwmGetWindowAttribute($window.MainWindowHandle, 9, [ref]$r, 16) | Out-Null
        $bitmap = New-Object Drawing.Bitmap ($r.R - $r.L), ($r.B - $r.T)
        $graphics = [Drawing.Graphics]::FromImage($bitmap)
        $graphics.CopyFromScreen($r.L, $r.T, 0, 0, $bitmap.Size)
        $bitmap.Save([IO.Path]::GetFullPath($Screenshot), [Drawing.Imaging.ImageFormat]::Png)
        $graphics.Dispose(); $bitmap.Dispose()
        "screenshot: $Screenshot"
    } else {
        'screenshot skipped: no window handle'
    }
}

$deadline = (Get-Date).AddSeconds(30)
while ((Get-Process ClaudeBarSpike -ErrorAction SilentlyContinue) -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 250 }
$stillRunning = [bool](Get-Process ClaudeBarSpike -ErrorAction SilentlyContinue)
Get-Process ClaudeBarSpike -ErrorAction SilentlyContinue | Stop-Process -Force

$r = Get-Content $Report -Raw | ConvertFrom-Json
if ($r.error) { throw "the self-test threw: $($r.error)" }
$appDirectory = $r.appDirectory.TrimEnd('\')
$modules = @($r.loadedModules)
$loaded = $modules | ForEach-Object { ($_ -split ' <- ')[0].ToLowerInvariant() }
$required = 'claudebarkitnative.dll', 'swiftcore.dll', 'swift_concurrency.dll', 'foundation.dll', '_foundationicu.dll', 'dispatch.dll', 'microsoft.ui.xaml.dll'
$checks = [ordered]@{
    'Quotas: statuses for 85/35/10/0 % left' = (($r.quotaDescribe | ForEach-Object status) -join ',') -eq 'healthy,warning,critical,depleted'
    'ICU: relative retry time'               = $r.rateLimitedText1799s -eq 'Rate limited. Retrying in 30 minutes.'
    'async: scan found files'                = $r.scan.result.files -gt 0 -and -not $r.scan.result.error
    'async: callback on a Swift thread'      = $r.scan.callbackNativeThread -ne $r.uiNativeThread
    'async: await resumed on the UI thread'  = $r.scan.resumedOnUiThread -eq $true
    'cancel: slow scan cancelled at 300 ms'  = $r.slowScanCancelledAfter300ms.result.cancelled -eq $true
    'MainActor: ran on the UI thread with the drain pump' = $r.mainActor.drainPump.ranOnMainActor -eq $true -and $r.mainActor.drainPump.nativeThread -eq $r.uiNativeThread
    'no callback left waiting'               = $r.pendingCallbacks -eq 0
    'every Swift/WinUI DLL from the app folder' = -not ($required | Where-Object { $loaded -notcontains $_ }) -and -not ($modules | Where-Object { -not $_.EndsWith($appDirectory) })
    'theme brush resolved'                   = $r.themeBrushLookup -eq 'C# cast' -or $r.themeBrushLookup -like '*As<SolidColorBrush>() worked'
    'exited after the hold'                  = -not $stillRunning
}
'packaged={0} windowShownMs={1} workingSetMB={2} privateMB={3} swift="{4}" os="{5}"' -f $r.packaged, $r.windowShownMsAfterProcessStart, $r.workingSetMB, $r.privateMB, $r.version.swift, $r.version.os
$failed = 0
foreach ($check in $checks.GetEnumerator()) {
    '{0}  {1}' -f $(if ($check.Value) { 'PASS' } else { 'FAIL' }), $check.Key
    if (-not $check.Value) { $failed++ }
}
if ($failed) { throw "$failed check(s) failed; report: $Report" }
