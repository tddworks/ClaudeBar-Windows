# Checks Tools in WSL on a Windows PC (docs/plans/2026-11-03-wsl-design.md,
# docs/plans/2026-11-04-wsl.md Task 19, docs/plans/2026-11-12-wsl-phase2.md
# Task 11): the probe as the app runs it, in Windows' zone, what it leaves
# behind, the days the running app kept for the Leaderboard and the zone the
# distro's kept days are counted in, --wsl-end-all, a folder with a space, the
# environment import's cost, and, read from the screen's UI Automation tree
# without changing it, the HUD's WSL rows.
# It never moves the mouse, raises or focuses a window, invokes a control or
# switches the theme: the HUD checks only read the tree of a ClaudeBar that is
# already running, so they can run while someone uses the PC.
# It starts no distro, unless -Start names one: then it says when it started
# it, and stops it again (wsl.exe --terminate) at the end. A distro that was
# running before is left running; one that was stopped is stopped after.
# `endall` runs `ClaudeBar.exe --wsl-end-all`, which ends every probe in every
# running distro, as an uninstall does, so a running ClaudeBar's own read in
# that moment ends too, and is read again at its next refresh.
# It prints PASS or FAIL per check, and UNVERIFIED for a check it couldn't
# make (no distro running, no HUD open): those never count as a pass. It exits
# 1 on any FAIL, 2 when nothing failed but something went unverified, and 0
# only when every check ran and passed. Windows PowerShell 5.1 or PowerShell 7.
#   .\scripts\check-wsl.ps1 [-Exe out\win-x64\ClaudeBar.exe] [-Distro <name>] [-Start <name>] [-Tests probe,...] [-Minutes 11] [-KeepAnswer <file>] [-Upload]
# -KeepAnswer keeps the probe check's answer, as it came, in that file: it
# holds the distro's limits and days, so keep it off anything shared.
# `hud` waits up to -Minutes for the running ClaudeBar's next HUD refresh to
# show the distro's tools; `stopped` (only with -Start) stops the distro and
# watches it stay stopped for -Minutes, then looks for *WSL isn't running*.
# `kept` waits up to -Minutes for the running ClaudeBar's next HUD refresh of
# the distro to keep its days (wsl\days\<distro>.json), and prints them as
# counts, never the file. `zonefile` reads the zone the distro's kept days are
# counted in. `upload` runs only when named, with -Upload: it runs
# claudebar-upload.exe once, a real upload of this PC's days, as the hourly
# task does.
# The zone checks compare with Windows' zone by the name the app sends a
# distro in TZ, derived here as the app derives it; with daylight saving's
# automatic adjustment off, the app sends a fixed offset, and they say UNVERIFIED.
param(
  [string]$Exe = (Join-Path $PSScriptRoot '..\out\win-x64\ClaudeBar.exe'),
  [string]$Distro,
  [string]$Start,
  [string[]]$Tests = @('probe', 'marker', 'kept', 'zonefile', 'space', 'endall', 'cost', 'hud', 'stopped'),
  [int]$Minutes = 11,
  [string]$KeepAnswer,
  [switch]$Upload
)

$ErrorActionPreference = 'Continue'
# `powershell -File` hands `-Tests a,b` over as one string.
$Tests = @($Tests | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })
$known = 'probe', 'marker', 'kept', 'zonefile', 'upload', 'space', 'endall', 'cost', 'hud', 'stopped'
$unknown = @($Tests | Where-Object { $known -notcontains $_ })
if ($unknown) { "no such check: $($unknown -join ', ') (the checks: $($known -join ', '))"; exit 1 }
$results = New-Object System.Collections.Generic.List[string]
function Result([string]$verdict, [string]$name, [string]$detail) {
  $line = "{0,-10} {1}: {2}" -f $verdict, $name, $detail
  $results.Add($line); $line
}
function Pass([string]$n, [string]$d) { Result 'PASS' $n $d }
function Fail([string]$n, [string]$d) { Result 'FAIL' $n $d }
function Unverified([string]$n, [string]$d) { Result 'UNVERIFIED' $n $d }
$dot = [string][char]0x00B7

$wsl = Join-Path $env:SystemRoot 'System32\wsl.exe'
$Exe = (Resolve-Path $Exe -ErrorAction SilentlyContinue).Path
if (-not $Exe) { 'no ClaudeBar.exe at -Exe'; exit 1 }
$probeWin = Join-Path (Split-Path $Exe) 'linux\x64\claudebar-probe'
$version = ((Get-Item $Exe).VersionInfo.ProductVersion -split '\+')[0]
"ClaudeBar: $Exe ($version)"
$checkStarted = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()

# Windows' IANA zone for its key, as ICU (and .NET) has it: CLDR's windowsZones,
# the table ClaudeBar's WindowsZones is made from.
function IanaOf([string]$id) {
  $method = [TimeZoneInfo].GetMethod('TryConvertWindowsIdToIanaId', [Type[]]@([string], [string].MakeByRefType()))
  if ($method) {
    $arguments = [object[]]@($id, $null)
    if ($method.Invoke($null, $arguments)) { return [string]$arguments[1] }
    return $null
  }
  if (-not ('CheckWsl.Icu' -as [type])) {
    Add-Type -Namespace CheckWsl -Name Icu -MemberDefinition @'
[DllImport("icu.dll", CharSet = CharSet.Unicode)]
public static extern int ucal_getTimeZoneIDForWindowsID(string winid, int len, [MarshalAs(UnmanagedType.LPStr)] string region, System.Text.StringBuilder id, int capacity, ref int status);
'@
  }
  $found = New-Object Text.StringBuilder 128
  $status = 0
  $n = [CheckWsl.Icu]::ucal_getTimeZoneIDForWindowsID($id, $id.Length, $null, $found, $found.Capacity, [ref]$status)
  if ($status -gt 0 -or $n -le 0) { return $null }
  $found.ToString().Substring(0, $n)
}
# The name the app sends a distro in TZ (WslZone.name of DataSources.timeZone()):
# the key's IANA zone; the OS's offset, fixed, when daylight saving's adjustment
# is off, the key has no zone or it's one Foundation on Windows can't format in
# (WindowsZones.unformattable); CLDR's seven old names by tzdata's; a fixed
# offset of whole hours as Etc/GMT-9 (POSIX's sign), 0 as Etc/UTC, else none.
function WindowsZone {
  $local = [TimeZoneInfo]::Local
  $dstOff = $false
  try { $dstOff = [int](Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\TimeZoneInformation' -Name DynamicDaylightTimeDisabled -ErrorAction Stop).DynamicDaylightTimeDisabled -ne 0 } catch { }
  $iana = IanaOf $local.Id
  $unformattable = 'America/Mazatlan', 'America/Whitehorse', 'Asia/Qyzylorda', 'Etc/UTC', 'Europe/Volgograd'
  $renamed = @{ 'America/Buenos_Aires' = 'America/Argentina/Buenos_Aires'; 'America/Godthab' = 'America/Nuuk'
    'America/Indianapolis' = 'America/Indiana/Indianapolis'; 'Asia/Calcutta' = 'Asia/Kolkata'; 'Asia/Katmandu' = 'Asia/Kathmandu'
    'Asia/Rangoon' = 'Asia/Yangon'; 'Europe/Kiev' = 'Europe/Kyiv' }
  $name = $null; $fixed = $false
  if (-not $dstOff -and $iana -and $unformattable -notcontains $iana) {
    $name = if ($renamed.ContainsKey($iana)) { $renamed[$iana] } else { $iana }
  } else {
    $fixed = $true
    $seconds = [int]$(if ($dstOff) { $local.BaseUtcOffset.TotalSeconds } else { $local.GetUtcOffset([DateTime]::UtcNow).TotalSeconds })
    $hours = [int][Math]::Truncate($seconds / 3600)
    if ($seconds % 3600 -eq 0) {
      if ($hours -eq 0) { $name = 'Etc/UTC' }
      elseif ($hours -ge -12 -and $hours -le 14) { $name = if ($hours -gt 0) { "Etc/GMT-$hours" } else { "Etc/GMT+$(-$hours)" } }
    }
  }
  [pscustomobject]@{ Key = $local.Id; Iana = $iana; Name = $name; Fixed = $fixed; DstOff = $dstOff }
}
$zone = WindowsZone
"Windows' zone: $($zone.Key) -> $(if ($zone.Iana) { $zone.Iana } else { 'no IANA zone' }); the app sends TZ=$(if ($zone.Name) { $zone.Name } else { '(none)' })$(if ($zone.DstOff) { ", a fixed offset: daylight saving's adjustment is off" } elseif ($zone.Fixed) { ', a fixed offset' })"
# Each zone check's verdict on a mismatch: with the adjustment off, unverified.
function ZoneVerdict([string]$n, [bool]$ok, [string]$detail) {
  if ($zone.DstOff) { Unverified $n "daylight saving's adjustment is off; $detail" }
  elseif ($ok) { Pass $n $detail } else { Fail $n $detail }
}

# wsl.exe's own text is UTF-16LE (no BOM), or UTF-8 with WSL_UTF8=1; the Linux
# side's is UTF-8. The same rule as WslCommand.text(in:).
function Text([byte[]]$bytes) {
  if ($bytes.Length -ge 2 -and $bytes[0] -eq 0xFF -and $bytes[1] -eq 0xFE) { return [Text.Encoding]::Unicode.GetString($bytes, 2, $bytes.Length - 2) }
  if ($bytes.Length -ge 2 -and $bytes.Length % 2 -eq 0 -and $bytes[1] -eq 0) { return [Text.Encoding]::Unicode.GetString($bytes) }
  $skip = if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) { 3 } else { 0 }
  [Text.Encoding]::UTF8.GetString($bytes, $skip, $bytes.Length - $skip)
}
# An argument as the C runtime parses it back, as WslCommand.commandLine quotes it.
function Quote([string]$a) {
  if ($a -ne '' -and $a -notmatch '[ \t\n\v"]') { return $a }
  $r = '"'; $bs = 0
  foreach ($c in $a.ToCharArray()) {
    if ($c -eq '\') { $bs++; continue }
    if ($c -eq '"') { $r += ('\' * ($bs * 2 + 1)) + '"' } else { $r += ('\' * $bs) + $c }
    $bs = 0
  }
  $r + ('\' * ($bs * 2)) + '"'
}
function Start-Wsl([string[]]$arguments) {
  $psi = New-Object Diagnostics.ProcessStartInfo $wsl
  $psi.Arguments = ($arguments | ForEach-Object { Quote $_ }) -join ' '
  $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
  $psi.RedirectStandardInput = $true; $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
  $p = [Diagnostics.Process]::Start($psi)
  $p.StandardInput.Close()
  $out = New-Object IO.MemoryStream; $err = New-Object IO.MemoryStream
  $copies = @($p.StandardOutput.BaseStream.CopyToAsync($out), $p.StandardError.BaseStream.CopyToAsync($err))
  [pscustomobject]@{ Process = $p; Out = $out; Err = $err; Copies = $copies; Clock = [Diagnostics.Stopwatch]::StartNew() }
}
function Wait-Wsl($run, [int]$seconds) {
  $done = $run.Process.WaitForExit($seconds * 1000)
  if (-not $done) { try { $run.Process.Kill() } catch { } }
  foreach ($c in $run.Copies) { [void]$c.Wait(5000) }
  $exit = if ($done) { $run.Process.ExitCode } else { $null }
  [pscustomobject]@{ Exit = $exit; Seconds = $run.Clock.Elapsed.TotalSeconds
    Bytes = $run.Out.ToArray(); Out = (Text $run.Out.ToArray()); Err = (Text $run.Err.ToArray()) }
}
function Wsl([string[]]$arguments, [int]$seconds = 60) { Wait-Wsl (Start-Wsl $arguments) $seconds }
function Lines([string]$text) { @($text -split "`r?`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ }) }
function Running { Lines (Wsl @('-l', '--running', '-q') 15).Out }
function Readable([string[]]$names) { @($names | Where-Object { $_ -notmatch '^(docker-desktop|rancher-desktop)' }) }
# The processes in the distro carrying a marker: `id` one run's, '' any run's.
function Marked([string]$d, [string]$id) {
  $pattern = if ($id) { "CLAUDEBAR_WSL_RUN=$id" } else { 'CLAUDEBAR_WSL_RUN=' }
  $r = Wsl @('-d', $d, '-e', 'sh', '-c', "for f in /proc/[0-9]*/environ; do tr '\0' '\n' < `"`$f`" 2>/dev/null | grep -q '^$pattern' && echo `"`${f#/proc/}`"; done | cut -d/ -f1") 30
  @(Lines $r.Out)
}
function LinuxPath([string]$d, [string]$windowsPath) { (Wsl @('-d', $d, '-e', 'wslpath', '-u', $windowsPath) 30).Out.Trim() }
function NewRun { [Guid]::NewGuid().ToString('N') }
# Emails and long hex ids out of anything printed from an answer.
function Redact([string]$s) { ($s -replace '[\w.+-]+@[\w-]+(\.[\w-]+)+', '<email>') -replace '\b[0-9a-f]{16,}\b', '<id>' }

# The roots file the app writes for a run (WslWindowsRoots): Claude's and
# Codex's default roots here, which is what the skip check compares.
function WriteRoots([string]$d, [string]$run) {
  $folder = Join-Path $env:LOCALAPPDATA 'ClaudeBar\wsl'
  New-Item -ItemType Directory -Path $folder -Force | Out-Null
  $h = $env:USERPROFILE
  $roots = [ordered]@{ distro = $d; providers = @(
      [ordered]@{ credentials = @("$h\.claude"); logs = @("$h\.claude\projects"); provider = 'claude' },
      [ordered]@{ credentials = @("$h\.codex"); logs = @("$h\.codex\sessions"); provider = 'codex' }); version = $version }
  $file = Join-Path $folder "windows-roots-$run.json"
  [IO.File]::WriteAllText($file, ($roots | ConvertTo-Json -Depth 5), (New-Object Text.UTF8Encoding $false))
  $file
}
# One run as WslProbe makes it: `wsl.exe -d <d> -e env CLAUDEBAR_WSL_RUN=<id> [TZ=<zone>] <probe> --json --windows-roots <file> --deadline 60`.
function Probe([string]$d, [string]$probe, [string]$run) {
  $roots = WriteRoots $d $run
  try {
    $tz = if ($zone.Name) { @("TZ=$($zone.Name)") } else { @() }
    $argv = @('-d', $d, '-e', 'env', "CLAUDEBAR_WSL_RUN=$run") + $tz + @($probe, '--json', '--windows-roots', (LinuxPath $d $roots), '--deadline', '60')
    Write-Host ("  argv: wsl.exe " + (($argv | ForEach-Object { Quote $_ }) -join ' '))
    $r = Wsl $argv 240
    $answer = $null
    try { $answer = $r.Out | ConvertFrom-Json } catch { }
    [pscustomobject]@{ Run = $r; Answer = $answer }
  } finally { Remove-Item $roots -ErrorAction SilentlyContinue }
}

# Every Name in ClaudeBar's own top-level windows, read only.
function HudNames {
  Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes
  $ids = @(Get-Process ClaudeBar -ErrorAction SilentlyContinue | Where-Object { $_.Path -eq $Exe -or -not $_.Path } | ForEach-Object { $_.Id })
  if (-not $ids) { $ids = @(Get-Process ClaudeBar -ErrorAction SilentlyContinue | ForEach-Object { $_.Id }) }
  $root = [Windows.Automation.AutomationElement]::RootElement
  $names = New-Object System.Collections.Generic.List[string]
  $windows = 0
  foreach ($w in $root.FindAll([Windows.Automation.TreeScope]::Children, [Windows.Automation.Condition]::TrueCondition)) {
    if ($ids -notcontains $w.Current.ProcessId) { continue }
    $windows++
    foreach ($e in $w.FindAll([Windows.Automation.TreeScope]::Descendants, [Windows.Automation.Condition]::TrueCondition)) {
      $n = $e.Current.Name; if ($n) { $names.Add($n) }
    }
  }
  [pscustomobject]@{ Windows = $windows; Names = $names; Processes = $ids.Count }
}

# --- which distro, and starting it only when asked -------------------------
$before = @(Running)
"running before: [$($before -join ', ')]"
$d = if ($Start) { $Start } elseif ($Distro) { $Distro } else { @(Readable $before)[0] }
$keeper = $null; $started = $false
if ($Start -and $before -notcontains $Start) {
  "starting $Start at $(Get-Date -Format o), for these checks; it's stopped again at the end"
  $keeper = Start-Wsl @('-d', $Start, '-e', 'sleep', '86400')
  $started = $true
  foreach ($i in 1..60) { Start-Sleep -Seconds 1; if ((Running) -contains $Start) { break } }
}
$up = $d -and ((Running) -contains $d)
if ($d) { "distro: $d ($(if ($up) { 'running' } else { 'not running' }))" }
$probe = $null
if ($up) {
  if (-not (Test-Path $probeWin)) { Fail 'probe' "no claudebar-probe at $probeWin (build with -Probe)"; $up = $false }
  else { $probe = LinuxPath $d $probeWin; "probe: $probe" }
}
$ourRuns = New-Object System.Collections.Generic.List[string]
$answer = $null

# --- the probe as the app runs it, and what it leaves ----------------------
if ($Tests -contains 'probe') {
  if (-not $up) { Unverified 'probe' 'no distro running: name one with -Start' }
  else {
    $run = NewRun; $ourRuns.Add($run)
    $p = Probe $d $probe $run
    $r = $p.Run; $answer = $p.Answer
    "  exit $($r.Exit) in {0:N1} s, {1:N0} bytes" -f $r.Seconds, $r.Bytes.Length
    if ($r.Err.Trim()) { (Lines $r.Err) | Select-Object -First 3 | ForEach-Object { "  stderr: " + (Redact $_) } }
    if ($r.Exit -ne 0) { Fail 'probe' "exit $($r.Exit)" }
    elseif (-not $answer) { Fail 'probe' 'its answer is not JSON' }
    elseif ($answer.version -ne $version) { Fail 'probe' "version $($answer.version), the app's is $version" }
    else {
      Pass 'probe' ("exit 0 in {0:N1} s, version {1}" -f $r.Seconds, $answer.version)
      if ($KeepAnswer) { [IO.File]::WriteAllBytes($KeepAnswer, $r.Bytes) }
      $home_ = ((Wsl @('-d', $d, '-e', 'sh', '-c', 'echo $HOME') 15).Out).Trim()
      foreach ($t in $answer.tools) { "  tool: {0}  cli {1}  logs {2}" -f $t.id, ($(if ($t.cli) { $t.cli.Replace($home_, '~') } else { '-' })), $t.logs }
      if ($answer.hud) {
        "  hud: {0} tools read, problems: {1}" -f @($answer.hud.reading.tools).Count, ((@($answer.hud.problems) | ForEach-Object { "$($_.id) $($_.kind)" }) -join ', ')
        "  hud looks: " + (Redact ((@($answer.hud.looks) | ForEach-Object { $_.name }) -join ', '))
      }
      $days = @($answer.days)
      if ($days) {
        $byProvider = $days | Group-Object provider | ForEach-Object { "$($_.Name) $($_.Count)" }
        "  days: {0} ({1}), {2} to {3}" -f $days.Count, ($byProvider -join ', '), (($days | Sort-Object day)[0].day), (($days | Sort-Object day)[-1].day)
      } else { '  days: none' }
      "  skipped: " + ((@($answer.skipped) | ForEach-Object { "$($_.provider) $($_.kind) $($_.reason)" }) -join ', ')
      "  timeZone {0}, timedOut {1}, environmentImport {2} [{3}]{4}" -f $answer.timeZone, $answer.timedOut, $answer.environmentImport.state, (@($answer.environmentImport.names) -join ', '), $(if ($answer.environmentImport.reason) { " ($($answer.environmentImport.reason))" } else { '' })
      foreach ($line in @($answer.diagnostics)) { "  diagnostic: " + (Redact $line) }
      if (-not $zone.Name) { Unverified 'probe zone' "Windows' zone has no name Linux knows: the app sends no TZ" }
      else {
        $hasDays = $null -ne $answer.PSObject.Properties['days'] -and $null -ne $answer.days
        $noData = @(@($answer.diagnostics) | Where-Object { $_ -like 'no time zone data*' })
        ZoneVerdict 'probe zone' ($answer.timeZone -eq $zone.Name -and $hasDays -and -not $noData) ("timeZone {0} (sent {1}), days {2}, {3}" -f $answer.timeZone, $zone.Name, $(if ($hasDays) { 'present' } else { 'absent' }), $(if ($noData) { 'a no time zone data diagnostic' } else { 'no time zone data diagnostic' }))
      }
    }
  }
}
if ($Tests -contains 'marker') {
  if (-not $up -or -not $ourRuns.Count) { Unverified 'marker' 'no probe run to check after' }
  else {
    $left = @(Marked $d $ourRuns[0])
    $others = @(Marked $d '')
    "  any run's marked processes now: $($others.Count)"
    if ($left.Count -eq 0) { Pass 'marker' "no process carries run $($ourRuns[0].Substring(0, 8))... after it" }
    else { Fail 'marker' "$($left.Count) processes still carry the run's marker: $($left -join ', ')" }
  }
}
# The days the running app keeps for the Leaderboard: each provider's days, and
# those with a day of tokens in the last 30 days in Windows' zone (what
# wsl.leaderboard lists for the distro when no other distro reads its folders).
function KeptSummary($entry) {
  # Gregorian labels whatever the person's calendar, as the kept days write them.
  $iso = [Globalization.CultureInfo]::InvariantCulture
  $first = (Get-Date).Date.AddDays(-29).ToString('yyyy-MM-dd', $iso); $last = (Get-Date).Date.ToString('yyyy-MM-dd', $iso)
  $days = @($entry.days)
  $inWindow = @($days | Where-Object { $_.day -ge $first -and $_.day -le $last -and ($_.input + $_.output + $_.cacheWrite + $_.cacheRead + $_.unsplit) -gt 0 })
  [pscustomobject]@{
    Counts = (($days | Group-Object provider | ForEach-Object { "$($_.Name) $($_.Count)" }) -join ', ')
    Span = $(if ($days) { "$(($days | Sort-Object day)[0].day) to $(($days | Sort-Object day)[-1].day)" } else { '-' })
    Window = @($inWindow | ForEach-Object { $_.provider } | Sort-Object -Unique)
    WindowDays = $inWindow.Count
  }
}
function KeptFile([string]$d) { Join-Path $env:LOCALAPPDATA "ClaudeBar\wsl\days\$d.json" }
function ReadKept([string]$d) {
  $file = KeptFile $d
  if (-not (Test-Path $file)) { return $null }
  try { [IO.File]::ReadAllText($file) | ConvertFrom-Json } catch { $null }
}
if ($Tests -contains 'kept') {
  if (-not $up) { Unverified 'kept' 'no distro running' }
  elseif (-not $zone.Name) { Unverified 'kept' "Windows' zone has no name Linux knows: the app keeps no new days" }
  elseif (-not (Get-Process ClaudeBar -ErrorAction SilentlyContinue)) { Unverified 'kept' 'no ClaudeBar running to keep them' }
  else {
    $deadline = (Get-Date).AddMinutes($Minutes)
    do {
      $entry = ReadKept $d
      if ($entry -and [long]$entry.answeredAt -ge $checkStarted) { break }
      Start-Sleep -Seconds 30
    } while ((Get-Date) -lt $deadline)
    if (-not $entry) { Fail 'kept' "no $(KeptFile $d) after $Minutes min" }
    else {
      $summary = KeptSummary $entry
      $at = [DateTimeOffset]::FromUnixTimeSeconds([long]$entry.answeredAt).ToLocalTime().ToString('o')
      "  kept: answeredAt $at, timeZone $($entry.timeZone), days $(@($entry.days).Count) ($($summary.Counts)), $($summary.Span)"
      "  kept log roots: " + ((@($entry.logRoots) | ForEach-Object { "$($_.provider) $($_.windowsPath)" }) -join '; ')
      "  with a day of tokens in the last 30 days: $(if ($summary.Window) { $summary.Window -join ', ' } else { 'none' }) ($($summary.WindowDays) days)"
      if ([long]$entry.answeredAt -lt $checkStarted) { Fail 'kept' "the newest is from $at, before this check started, after $Minutes min" }
      else { ZoneVerdict 'kept' ($entry.timeZone -eq $zone.Name) "kept at $at in $($entry.timeZone) (sent $($zone.Name))" }
    }
  }
}
if ($Tests -contains 'zonefile') {
  if (-not $up) { Unverified 'zonefile' 'no distro running' }
  else {
    # -e runs no shell, so ~ would reach cat as it is: --cd ~ starts in the Linux home instead.
    $r = Wsl @('-d', $d, '--cd', '~', '-e', 'cat', '.local/share/ClaudeBar/wsl-zone') 30
    $text = $r.Out.Trim()
    if ($r.Exit -ne 0) { Fail 'zonefile' "no ~/.local/share/ClaudeBar/wsl-zone (exit $($r.Exit)): $(Redact (Lines $r.Err | Select-Object -First 1))" }
    elseif (-not $zone.Name) { Unverified 'zonefile' "it says $text; Windows' zone has no name Linux knows, so it is the distro's own" }
    else { ZoneVerdict 'zonefile' ($text -eq $zone.Name) "it says $text (sent $($zone.Name))" }
  }
}
if ($Tests -contains 'upload') {
  if (-not $Upload) { Unverified 'upload' "only with -Upload: it's a real upload of this PC's days" }
  else {
    $uploader = Join-Path (Split-Path $Exe) 'claudebar-upload.exe'
    $log = Join-Path $env:LOCALAPPDATA 'ClaudeBar\Logs\ClaudeBar.log'
    $runningBefore = @(Running | Sort-Object)
    $from = if (Test-Path $log) { (Get-Item $log).Length } else { 0 }
    $clock = [Diagnostics.Stopwatch]::StartNew()
    $u = Start-Process -FilePath $uploader -PassThru -Wait -WindowStyle Hidden
    $seconds = $clock.Elapsed.TotalSeconds
    $runningAfter = @(Running | Sort-Object)
    # The lines added since, from the file's new start if it rolled over to ClaudeBar.old.log.
    $stream = [IO.File]::Open($log, 'Open', 'Read', 'ReadWrite')
    try { $copy = New-Object IO.MemoryStream; $stream.CopyTo($copy); $bytes = $copy.ToArray() } finally { $stream.Dispose() }
    $start = if ($bytes.Length -ge $from) { $from } else { 0 }
    $added = @(Lines ([Text.Encoding]::UTF8.GetString($bytes, $start, $bytes.Length - $start)))
    $done = @($added | Where-Object { $_ -like '*Leaderboard uploaded by the scheduled task*' })
    $wslLines = @($added | Where-Object { $_ -like '*Leaderboard: WSL *' })
    "  claudebar-upload.exe exit $($u.ExitCode) in {0:N1} s; running before [$($runningBefore -join ', ')], after [$($runningAfter -join ', ')]" -f $seconds
    foreach ($line in $wslLines) { "  log: " + (Redact $line) }
    # Each distro whose kept days have a day in the window and that wasn't read
    # says so: that its kept days went, or, counted in another zone than
    # Windows' now, that they were left out (WslKeptDays.current); a distro
    # whose every provider is read by Windows or another distro now only says
    # what was left out.
    $unread = @()
    foreach ($file in @(Get-ChildItem (Join-Path $env:LOCALAPPDATA 'ClaudeBar\wsl\days') -Filter *.json -ErrorAction SilentlyContinue)) {
      $name = $file.BaseName
      $entry = ReadKept $name
      if ($entry -and (KeptSummary $entry).WindowDays -gt 0 -and $runningAfter -notcontains $name) {
        $unread += [pscustomobject]@{ Name = $name; Zone = [string]$entry.timeZone }
      }
    }
    $missing = @($unread | Where-Object {
      $n = $_.Name; $z = $_.Zone
      $said = if ($z -ne $zone.Name) { @($wslLines | Where-Object { $_ -like "*WSL ${n}: kept days left out: counted in ${z},*" }) }
              else { @($wslLines | Where-Object { $_ -like "*WSL ${n}: *its kept days go*" -or $_ -like "*WSL ${n}: kept * days left out: *" }) }
      -not $said
    } | ForEach-Object { $_.Name })
    if ($u.ExitCode -ne 0) { Fail 'upload' "exit $($u.ExitCode)" }
    elseif (-not $done) { Fail 'upload' 'no *Leaderboard uploaded by the scheduled task* in the lines it added' }
    elseif (($runningBefore -join ',') -ne ($runningAfter -join ',')) { Fail 'upload' "running before [$($runningBefore -join ', ')], after [$($runningAfter -join ', ')]" }
    elseif ($missing) { Fail 'upload' "no line says these distros' kept days went: $($missing -join ', ')" }
    else { Pass 'upload' ("exit 0 in {0:N1} s, uploaded; {1} WSL lines; the running distros are as they were" -f $seconds, $wslLines.Count) }
  }
}
if ($Tests -contains 'space') {
  if (-not $up) { Unverified 'space' 'no distro running' }
  else {
    $spaced = Join-Path $env:TEMP 'claudebar check wsl'
    Remove-Item $spaced -Recurse -Force -ErrorAction SilentlyContinue
    New-Item -ItemType Directory -Path $spaced -Force | Out-Null
    Copy-Item (Split-Path $probeWin) (Join-Path $spaced 'x64') -Recurse
    $linux = LinuxPath $d (Join-Path $spaced 'x64\claudebar-probe')
    "  from: $linux"
    $run = NewRun; $ourRuns.Add($run)
    $p = Probe $d $linux $run
    if ($p.Run.Exit -eq 0 -and $p.Answer -and $p.Answer.version -eq $version) { Pass 'space' ("exit 0 in {0:N1} s from a folder with a space" -f $p.Run.Seconds) }
    else { Fail 'space' "exit $($p.Run.Exit), answer $(if ($p.Answer) { 'decoded' } else { 'not JSON' }); stderr: $(Redact (Lines $p.Run.Err | Select-Object -First 1))" }
    [void](Wsl @('-d', $d, '-e', $linux, '--end', $run) 30)
    Remove-Item $spaced -Recurse -Force -ErrorAction SilentlyContinue
  }
}
if ($Tests -contains 'endall') {
  if (-not $up) { Unverified 'endall' 'no distro running' }
  else {
    $id = 'check' + (NewRun).Substring(0, 8)
    $standIn = Start-Wsl @('-d', $d, '-e', 'env', "CLAUDEBAR_WSL_RUN=$id", 'sleep', '300')
    $seen = @()
    foreach ($i in 1..20) { Start-Sleep -Milliseconds 500; $seen = @(Marked $d $id); if ($seen.Count) { break } }
    if (-not $seen.Count) { Unverified 'endall' 'the stand-in marked process never showed up' }
    else {
      $clock = [Diagnostics.Stopwatch]::StartNew()
      $e = Start-Process -FilePath $Exe -ArgumentList '--wsl-end-all' -PassThru -Wait -WindowStyle Hidden
      $left = @(Marked $d $id)
      if ($left.Count -eq 0) { Pass 'endall' ("ClaudeBar.exe --wsl-end-all exit {0} in {1:N1} s; the stand-in is gone" -f $e.ExitCode, $clock.Elapsed.TotalSeconds) }
      else { Fail 'endall' "exit $($e.ExitCode); $($left.Count) marked processes left" }
    }
    [void](Wait-Wsl $standIn 10)
  }
}
if ($Tests -contains 'cost') {
  if (-not $up) { Unverified 'cost' 'no distro running' }
  else {
    # The probe's import (EnvironmentImport.command): the login shell, interactive, writing env -0 to a file.
    $shell = ((Wsl @('-d', $d, '-e', 'sh', '-c', 'getent passwd "$(id -un)" | cut -d: -f7') 15).Out).Trim()
    if (-not $shell) { $shell = '/bin/bash' }
    $inside = "f=`$(mktemp); a=`$(date +%s%N); $shell -l -i -c `"/usr/bin/env -0 > `$f && printf %s @@CLAUDEBAR_ENV_END@@ >> `$f`" </dev/null >/dev/null 2>&1; b=`$(date +%s%N); rm -f `$f; echo `$(( (b - a) / 1000000 ))"
    $shellMs = @(); $importS = @(); $trueS = @()
    foreach ($i in 1..5) {
      $t = Wsl @('-d', $d, '-e', 'true') 30; $trueS += $t.Seconds
      $r = Wsl @('-d', $d, '-e', 'sh', '-c', $inside) 30; $importS += $r.Seconds; $shellMs += [int]($r.Out.Trim())
    }
    "  login shell: $shell"
    "  the import inside the distro, ms: " + ($shellMs -join ', ')
    "  wsl.exe -e <the import>, s: " + (($importS | ForEach-Object { '{0:N2}' -f $_ }) -join ', ')
    "  wsl.exe -e true, s: " + (($trueS | ForEach-Object { '{0:N2}' -f $_ }) -join ', ')
    Pass 'cost' ("measured, not judged: median {0} ms in the distro" -f (($shellMs | Sort-Object)[2]))
  }
}

# --- the HUD, read from the tree ------------------------------------------
if ($Tests -contains 'hud') {
  $expected = @()
  if ($answer -and $answer.hud) {
    # As WslLineup.merge: not notSetUp, nor a source Linux can't read at all (WslLineup.unavailableOnLinux).
    $shown = @(@($answer.hud.reading.tools) | ForEach-Object { $_.id }) + @(@($answer.hud.problems) | Where-Object { $_.kind -ne 'notSetUp' -and -not ($_.kind -eq 'failed' -and $_.message.Contains("isn't available on Linux yet")) } | ForEach-Object { $_.id })
    $expected = @(@($answer.hud.looks) | Where-Object { $shown -contains $_.id } | ForEach-Object { "$($_.name) $dot WSL" } | Select-Object -Unique)
  }
  if (-not $expected) { Unverified 'hud' 'no probe answer with tools to look for' }
  else {
    $deadline = (Get-Date).AddMinutes($Minutes)
    do {
      $tree = HudNames
      $missing = @($expected | Where-Object { $x = $_; -not ($tree.Names | Where-Object { $_.Contains($x) }) })
      if (-not $missing -or $tree.Windows -eq 0) { break }
      Start-Sleep -Seconds 30
    } while ((Get-Date) -lt $deadline)
    if ($tree.Windows -eq 0) { Unverified 'hud' 'no ClaudeBar window is open to read' }
    elseif (-not $missing) { Pass 'hud' ("each tool as its own row: " + (Redact ($expected -join '; '))) }
    elseif ($tree.Names | Where-Object { $_ -like 'All fine*' }) { Unverified 'hud' ("the HUD shows *All fine*, which names no tool; not seen: " + (Redact ($missing -join '; '))) }
    else { Fail 'hud' ("not in the tree after $Minutes min: " + (Redact ($missing -join '; '))) }
  }
}
if ($Tests -contains 'stopped') {
  if (-not $started) { Unverified 'stopped' 'only with -Start, for a distro this check started' }
  elseif (-not $answer) { Unverified 'stopped' 'no reading was kept to show' }
  else {
    [void](Wsl @('--terminate', $d) 30)
    if ($keeper) { [void](Wait-Wsl $keeper 10); $keeper = $null }
    $stoppedAt = Get-Date
    "  stopped $d at $(Get-Date $stoppedAt -Format o)"
    $woke = $null; $notRunning = $false
    $deadline = $stoppedAt.AddMinutes($Minutes)
    while ((Get-Date) -lt $deadline) {
      Start-Sleep -Seconds 30
      if ((Running) -contains $d) { $woke = Get-Date; break }
      $tree = HudNames
      if ($tree.Names | Where-Object { $_ -like "*WSL isn't running*" }) { $notRunning = $true }
    }
    if ($woke) { Fail 'stopped' "$d was running again at $(Get-Date $woke -Format o)" }
    elseif ($notRunning) { Pass 'stopped' "stayed stopped for $Minutes min, and the HUD says WSL isn't running" }
    elseif ($tree.Windows -eq 0) { Unverified 'stopped' "stayed stopped for $Minutes min; no ClaudeBar window open to read" }
    else { Fail 'stopped' "stayed stopped for $Minutes min, but no WSL isn't running in the tree" }
  }
}

# --- leave each distro as it was -------------------------------------------
foreach ($run in $ourRuns) { if ($up -and (Running) -contains $d) { [void](Wsl @('-d', $d, '-e', $probe, '--end', $run) 30) } }
if ($started) {
  if ($keeper) { [void](Wsl @('--terminate', $d) 30); [void](Wait-Wsl $keeper 10) }
  "stopped $d again at $(Get-Date -Format o)"
}
$after = @(Running)
"running after: [$($after -join ', ')]"
$woken = @($after | Where-Object { $before -notcontains $_ })
if ($woken) { Fail 'distros' "running now and not before: $($woken -join ', ')" } else { Pass 'distros' 'each distro stopped before is stopped after' }

''
$results
if ($results | Where-Object { $_ -like 'FAIL*' }) { exit 1 }
if ($results | Where-Object { $_ -like 'UNVERIFIED*' }) { exit 2 }
exit 0
