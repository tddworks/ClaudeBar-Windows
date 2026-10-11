<#
Builds ClaudeBar for Windows on Windows, for this PC's architecture:
  1. the Swift side with SwiftPM (native/): ClaudeBarNative.dll and claudebar-upload.exe,
     over ClaudeBar's package at the commit native/Package.swift pins;
  2. stages them with the Swift runtime DLLs they import and ClaudeBar's resource
     bundles (the provider definitions) into native-out/win-<arch>;
  3. publishes the C# WinUI 3 app, self-contained, with those beside ClaudeBar.exe.

  .\build.ps1             # out\win-<arch>\ClaudeBar.exe
  .\build.ps1 -SkipApp    # the Swift side only
#>
param([switch] $SkipApp)

$ErrorActionPreference = 'Continue'
$root = $PSScriptRoot
$arch = @{ AMD64 = 'x64'; ARM64 = 'arm64' }[(Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Environment').PROCESSOR_ARCHITECTURE]
if (-not $arch) { throw 'unsupported architecture' }
$env:DOTNET_CLI_TELEMETRY_OPTOUT = '1'
$env:DOTNET_NOLOGO = '1'
$dotnet = Join-Path $env:LOCALAPPDATA 'Microsoft\dotnet10\dotnet.exe'
if (-not (Test-Path $dotnet)) { $dotnet = 'dotnet' }

function Assert-Exit([string] $step) {
    if ($LASTEXITCODE -ne 0) { throw "$step failed (exit $LASTEXITCODE)" }
}

# 1. The Swift side. SwiftPM needs MSVC's `link` on PATH, so load the build tools' environment first.
$vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
$vcComponents = 'Microsoft.VisualStudio.Component.VC.Tools.x86.x64', 'Microsoft.VisualStudio.Component.VC.Tools.ARM64'
$vcvars = & $vswhere -latest -products * -requiresAny -requires $vcComponents -find 'VC\Auxiliary\Build\vcvarsall.bat' | Select-Object -First 1
if (-not $vcvars) { throw 'vcvarsall.bat not found (MSVC build tools)' }
cmd /c "`"$vcvars`" $arch >nul && set" | ForEach-Object {
    if ($_ -match '^([^=]+)=(.*)$') { Set-Item -Path "env:$($Matches[1])" -Value $Matches[2] }
}
$native = Join-Path $root 'native'
$clock = [Diagnostics.Stopwatch]::StartNew()
swift build -c release --package-path $native; Assert-Exit 'swift build'
"swift build: {0:N0} s" -f $clock.Elapsed.TotalSeconds
$bin = (swift build -c release --package-path $native --show-bin-path | Select-Object -Last 1).Trim()

# 2. Stage the DLL and the uploader, the Swift runtime DLLs they import (transitively), and the resource bundles.
$runtime = $env:Path -split ';' | Where-Object { $_ -and (Test-Path (Join-Path $_ 'swiftCore.dll')) } | Select-Object -First 1
if (-not $runtime) { throw 'Swift runtime DLLs (swiftCore.dll) not found on PATH' }
$dumpbin = & $vswhere -latest -products * -requiresAny -requires $vcComponents -find 'VC\Tools\MSVC\**\dumpbin.exe' | Select-Object -First 1
if (-not $dumpbin) { throw 'dumpbin.exe not found (MSVC build tools)' }
$stage = Join-Path $root "native-out\win-$arch"
Remove-Item $stage -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Path $stage | Out-Null
$queue = [System.Collections.Generic.Queue[string]]::new()
foreach ($name in 'ClaudeBarNative.dll', 'claudebar-upload.exe') {
    Copy-Item (Join-Path $bin $name) $stage
    $queue.Enqueue((Join-Path $stage $name))
}
while ($queue.Count -gt 0) {
    $file = $queue.Dequeue()
    $imports = & $dumpbin /nologo /dependents $file | ForEach-Object { $_.Trim() } | Where-Object { $_ -match '\.dll$' }
    foreach ($name in $imports) {
        $target = Join-Path $stage $name
        if (Test-Path $target) { continue }
        foreach ($source in (Join-Path $bin $name), (Join-Path $runtime $name)) {
            if (Test-Path $source) {
                Copy-Item $source $target
                $queue.Enqueue($target)
                break
            }
        }
    }
}
Get-ChildItem $bin -Directory -Filter '*.resources' | ForEach-Object { Copy-Item $_.FullName (Join-Path $stage $_.Name) -Recurse }
$staged = Get-ChildItem $stage -Recurse -File
"staged {0} files, {1:N1} MB" -f $staged.Count, (($staged | Measure-Object Length -Sum).Sum / 1MB)
if ($SkipApp) { return }

# 3. The C# WinUI 3 app, self-contained.
$rid = "win-$arch"
$platform = @{ x64 = 'x64'; arm64 = 'ARM64' }[$arch]
$out = Join-Path $root "out\$rid"
Remove-Item $out -Recurse -Force -ErrorAction SilentlyContinue
$clock.Restart()
& $dotnet publish (Join-Path $root 'app\ClaudeBar.csproj') -c Release -r $rid "-p:Platform=$platform" -o $out; Assert-Exit 'dotnet publish'
"dotnet publish: {0:N0} s" -f $clock.Elapsed.TotalSeconds
$files = Get-ChildItem $out -Recurse -File | Where-Object Extension -ne '.pdb'
"published to $out : {0} files, {1:N1} MB" -f $files.Count, (($files | Measure-Object Length -Sum).Sum / 1MB)
