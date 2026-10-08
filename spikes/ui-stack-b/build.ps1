<#
Builds the UI stack B spike on Windows:
  1. checks out ClaudeBar's Quotas sources at a pinned commit,
  2. builds ClaudeBarKitNative.dll with SwiftPM,
  3. stages it with the Swift runtime DLLs it imports (followed through the import tables),
  4. publishes the C# WinUI 3 app (self-contained) with those DLLs next to the exe.

  .\build.ps1                    # x64, unpackaged
  .\build.ps1 -Aot               # x64, unpackaged, NativeAOT
  .\build.ps1 -Aot -Msix         # x64, MSIX layout; register with Add-AppxPackage -Register <out>\AppxManifest.xml
  .\build.ps1 -Arch arm64        # needs the MSVC ARM64 build tools
#>
param(
    [ValidateSet('x64', 'arm64')] [string] $Arch = 'x64',
    [switch] $Aot,
    [switch] $Msix,
    [switch] $SkipApp
)

$ErrorActionPreference = 'Continue'
$root = $PSScriptRoot
$claudeBarCommit = '721dc625081a040d426857d49328d8685300f26d'
$swiftVersion = '6.3.3'
$env:DOTNET_CLI_TELEMETRY_OPTOUT = '1'
$env:DOTNET_NOLOGO = '1'
$dotnet = Join-Path $env:LOCALAPPDATA 'Microsoft\dotnet10\dotnet.exe'
if (-not (Test-Path $dotnet)) { $dotnet = 'dotnet' }

function Assert-Exit([string] $step) {
    if ($LASTEXITCODE -ne 0) { throw "$step failed (exit $LASTEXITCODE)" }
}

# 1. ClaudeBar's Quotas module at the pinned commit
$vendor = Join-Path $root 'native\vendor\ClaudeBar'
if (-not (Test-Path (Join-Path $vendor '.git'))) {
    git clone --quiet --filter=blob:none --no-checkout https://github.com/tddworks/ClaudeBar.git $vendor; Assert-Exit 'clone ClaudeBar'
    git -C $vendor sparse-checkout set --cone Modules/Quotas; Assert-Exit 'sparse-checkout'
}
git -C $vendor checkout --quiet $claudeBarCommit
if ($LASTEXITCODE -ne 0) {
    git -C $vendor fetch --quiet --filter=blob:none origin $claudeBarCommit; Assert-Exit 'fetch pinned commit'
    git -C $vendor checkout --quiet $claudeBarCommit; Assert-Exit 'checkout pinned commit'
}

# 2. The Swift DLL. SwiftPM needs MSVC's `link` on PATH, so load the build tools' environment first.
$vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
$vcvars = & $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 `
    -find 'VC\Auxiliary\Build\vcvarsall.bat' | Select-Object -First 1
if (-not $vcvars) { throw 'vcvarsall.bat not found (MSVC build tools)' }
$vcArch = @{ x64 = 'x64'; arm64 = 'x64_arm64' }[$Arch]
cmd /c "`"$vcvars`" $vcArch >nul && set" | ForEach-Object {
    if ($_ -match '^([^=]+)=(.*)$') { Set-Item -Path "env:$($Matches[1])" -Value $Matches[2] }
}
if (-not (Get-Command link.exe -ErrorAction SilentlyContinue)) { throw "vcvarsall $vcArch did not put link.exe on PATH" }
$triple = @{ x64 = 'x86_64-unknown-windows-msvc'; arm64 = 'aarch64-unknown-windows-msvc' }[$Arch]
$native = Join-Path $root 'native'
$clock = [Diagnostics.Stopwatch]::StartNew()
swift build -c release --package-path $native --triple $triple; Assert-Exit 'swift build'
"swift build: {0:N0} s" -f $clock.Elapsed.TotalSeconds
$bin = (swift build -c release --package-path $native --triple $triple --show-bin-path | Select-Object -Last 1).Trim()

# 3. Stage the DLL and the Swift runtime DLLs it imports, transitively
$runtime = @{
    x64   = Join-Path $env:LOCALAPPDATA "Programs\Swift\Runtimes\$swiftVersion\usr\bin"
    arm64 = Join-Path $env:LOCALAPPDATA "Programs\Swift\Platforms\$swiftVersion\Windows.platform\Developer\SDKs\Windows.sdk\usr\bin\aarch64"
}[$Arch]
if (-not (Test-Path $runtime)) { throw "Swift runtime DLLs for $Arch not found at $runtime" }
$dumpbin = & $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 `
    -find 'VC\Tools\MSVC\**\bin\Hostx64\x64\dumpbin.exe' | Select-Object -First 1
if (-not $dumpbin) { throw 'dumpbin.exe not found (MSVC build tools)' }

$stage = Join-Path $root "native-out\win-$Arch"
Remove-Item $stage -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Path $stage | Out-Null
Copy-Item (Join-Path $bin 'ClaudeBarKitNative.dll') $stage
$queue = [System.Collections.Generic.Queue[string]]::new()
$queue.Enqueue((Join-Path $stage 'ClaudeBarKitNative.dll'))
while ($queue.Count -gt 0) {
    $dll = $queue.Dequeue()
    $imports = & $dumpbin /nologo /dependents $dll | ForEach-Object { $_.Trim() } | Where-Object { $_ -match '\.dll$' }
    foreach ($name in $imports) {
        $source = Join-Path $runtime $name
        $target = Join-Path $stage $name
        if ((Test-Path $source) -and -not (Test-Path $target)) {
            Copy-Item $source $target
            $queue.Enqueue($target)
        }
    }
}
$staged = Get-ChildItem $stage -Filter *.dll
"staged {0} DLLs, {1:N1} MB:" -f $staged.Count, (($staged | Measure-Object Length -Sum).Sum / 1MB)
$staged | Sort-Object Length -Descending | ForEach-Object { '  {0,-40} {1,8:N0} KB' -f $_.Name, ($_.Length / 1KB) }
if ($SkipApp) { return }

# 4. The C# WinUI 3 app, self-contained
$rid = "win-$Arch"
$platform = @{ x64 = 'x64'; arm64 = 'ARM64' }[$Arch]
$out = Join-Path $root ("out\$rid" + $(if ($Aot) { '-aot' } else { '' }) + $(if ($Msix) { '-msix' } else { '' }))
Remove-Item $out -Recurse -Force -ErrorAction SilentlyContinue
$publish = @('publish', (Join-Path $root 'app\ClaudeBarSpike.csproj'), '-c', 'Release', '-r', $rid, "-p:Platform=$platform", '-o', $out)
if ($Aot) { $publish += '-p:PublishAot=true' }
if ($Msix) { $publish += '-p:WindowsPackageType=MSIX' }
$clock.Restart()
& $dotnet @publish; Assert-Exit 'dotnet publish'
"dotnet publish: {0:N0} s" -f $clock.Elapsed.TotalSeconds
$files = Get-ChildItem $out -Recurse -File
"published to $out : {0} files, {1:N1} MB" -f $files.Count, (($files | Measure-Object Length -Sum).Sum / 1MB)
