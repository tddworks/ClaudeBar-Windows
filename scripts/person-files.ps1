# What a test run must leave alone: ClaudeBar's folders in the home of the
# account running it, %USERPROFILE%\.claudebar (the kept days and the scan
# caches of the token logs) and %LOCALAPPDATA%\ClaudeBar (the settings file,
# the log, app.json). On CI they are the runner's; on a PC, the person's.
# -Save writes each file's size and SHA-256 to a file; -Compare reads it back,
# names every file added, removed or changed since, and exits 1 if any.
# Windows PowerShell 5.1 or PowerShell 7.
#   .\scripts\person-files.ps1 -Save $env:TEMP\before.json
#   swift test --package-path native ...; dotnet test tests/ClaudeBar.Tests
#   .\scripts\person-files.ps1 -Compare $env:TEMP\before.json
# Bytes, not times: a ClaudeBar running on the PC saves app.json every half
# minute, unchanged. What it changes meanwhile, a line in its log, is named
# too; CI runs no ClaudeBar.
param([string]$Save, [string]$Compare)

if ([bool]$Save -eq [bool]$Compare) { throw 'give -Save <file> or -Compare <file>' }
# Full paths: .NET resolves a relative one against the process's folder, not this session's.
if ($Save) { $Save = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Save) }
if ($Compare) { $Compare = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Compare) }

function Get-PersonFiles {
    # Where ClaudeBar's package finds them: the account's profile folder
    # (FileManager.homeDirectoryForCurrentUser), and %LOCALAPPDATA%.
    $roots = (Join-Path ([Environment]::GetFolderPath('UserProfile')) '.claudebar'),
             (Join-Path $(if ($env:LOCALAPPDATA) { $env:LOCALAPPDATA } else { [Environment]::GetFolderPath('LocalApplicationData') }) 'ClaudeBar')
    $files = [ordered]@{}
    foreach ($root in $roots) {
        $files[$root] = if (Test-Path -LiteralPath $root) { 'folder' } else { 'absent' }
        if (-not (Test-Path -LiteralPath $root)) { continue }
        foreach ($item in Get-ChildItem -LiteralPath $root -Recurse -Force) {
            if ($item.PSIsContainer) { $files[$item.FullName] = 'folder'; continue }
            $hash = try { (Get-FileHash -Algorithm SHA256 -LiteralPath $item.FullName -ErrorAction Stop).Hash } catch { 'unreadable' }
            $files[$item.FullName] = '{0} bytes, {1}' -f $item.Length, $hash
        }
    }
    $files
}

$now = Get-PersonFiles
if ($Save) {
    # A line a path: the path, a tab, what it was.
    [IO.File]::WriteAllLines($Save, [string[]]@($now.GetEnumerator() | ForEach-Object { "$($_.Key)`t$($_.Value)" }))
    "{0} entries under ClaudeBar's folders, saved to {1}" -f $now.Count, $Save
    exit 0
}

$before = @{}
foreach ($line in [IO.File]::ReadAllLines($Compare)) {
    $tab = $line.IndexOf("`t")
    if ($tab -gt 0) { $before[$line.Substring(0, $tab)] = $line.Substring($tab + 1) }
}
$changes = @()
foreach ($path in $before.Keys | Sort-Object) {
    if (-not $now.Contains($path)) { $changes += "removed  $path ($($before[$path]))" }
    elseif ($now[$path] -ne $before[$path]) { $changes += "changed  $path ($($before[$path]) -> $($now[$path]))" }
}
foreach ($path in $now.Keys | Sort-Object) {
    if (-not $before.ContainsKey($path)) { $changes += "added    $path ($($now[$path]))" }
}
if ($changes.Count -eq 0) {
    "ClaudeBar's folders are as they were: {0} entries" -f $now.Count
    exit 0
}
"The run changed ClaudeBar's folders in this account's home:"
$changes
exit 1
