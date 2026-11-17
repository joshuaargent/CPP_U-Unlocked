# Builds both Smash Wii U title variants and both CPU tiers from the user's own RPX files.
# The native Vulkan runtime and launcher are compiled once and shared by all four game executables.
param(
    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$Rpx,
    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$BaseRpx
)
$ErrorActionPreference = 'Stop'

foreach ($entry in @(@{ Name = 'Update'; Path = $Rpx }, @{ Name = 'Base game'; Path = $BaseRpx })) {
    if (-not (Test-Path -LiteralPath $entry.Path -PathType Leaf)) {
        throw "$($entry.Name) RPX file does not exist: $($entry.Path)"
    }
}
$Rpx = (Resolve-Path -LiteralPath $Rpx).Path
$BaseRpx = (Resolve-Path -LiteralPath $BaseRpx).Path

$root = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))
. (Join-Path $root 'tools\windows\toolchain-path.ps1')
$toolchain = Get-UUnlockedToolchainRoot
$engineRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$build = Join-Path $engineRoot 'build'
$prefix = Join-Path $engineRoot 'build-deps\prefix'
$play = Join-Path $root 'Play'
$cacheBase = if ($env:LOCALAPPDATA) { Join-Path $env:LOCALAPPDATA 'U Unlocked\BuildCache' } else { Join-Path $env:TEMP 'U Unlocked\BuildCache' }
$updateGenerated = Join-Path $cacheBase 'generated\smash'
$baseGenerated = Join-Path $cacheBase 'generated\smash-base'
$buildJobs = if ($env:U_UNLOCKED_BUILD_JOBS -match '^[0-9]+$') { [int]$env:U_UNLOCKED_BUILD_JOBS } else { 2 }
function Get-Sha256([string]$Path) { return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant() }

function Test-GeneratedCodeCache {
    param([string]$RpxPath, [string]$OutputDirectory, [string]$RecompilerPath)
    $manifestPath = Join-Path $OutputDirectory '.u-unlocked-cache.json'
    if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) { return $false }
    try {
        $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
        if ($manifest.schema_version -ne 1 -or $manifest.rpx_sha256 -ne (Get-Sha256 $RpxPath) -or
            $manifest.recompiler_sha256 -ne (Get-Sha256 $RecompilerPath) -or $manifest.arguments -ne '--any-rpx' -or
            -not ($manifest.files -is [array]) -or $manifest.files.Count -eq 0) { return $false }
        $expected = [Collections.Generic.Dictionary[string,string]]::new([StringComparer]::OrdinalIgnoreCase)
        foreach ($file in $manifest.files) {
            $relative = [string]$file.path
            $hash = [string]$file.sha256
            if ([string]::IsNullOrWhiteSpace($relative) -or $relative.Contains('..') -or [IO.Path]::IsPathRooted($relative) -or
                $hash.Length -ne 64 -or $hash -notmatch '^[0-9a-fA-F]{64}' -or $expected.ContainsKey($relative)) { return $false }
            $expected.Add($relative, $hash.ToLowerInvariant())
        }
        $actualFiles = @(Get-ChildItem -LiteralPath $OutputDirectory -File -Recurse | Where-Object { $_.FullName -ne $manifestPath })
        if ($actualFiles.Count -ne $expected.Count) { return $false }
        foreach ($file in $actualFiles) {
            $relative = $file.FullName.Substring($OutputDirectory.Length + 1).Replace('\', '/')
            if (-not $expected.ContainsKey($relative) -or (Get-Sha256 $file.FullName) -ne $expected[$relative]) { return $false }
        }
        return $true
    } catch { return $false }
}

function Invoke-CachedRecompile {
    param([string]$Label, [string]$RpxPath, [string]$OutputDirectory, [string]$RecompilerPath)
    if (Test-GeneratedCodeCache -RpxPath $RpxPath -OutputDirectory $OutputDirectory -RecompilerPath $RecompilerPath) {
        Write-Host "$Label RPX and generated code are unchanged; reusing the verified local recompile cache." -ForegroundColor Green
        return
    }
    if (Test-Path -LiteralPath $OutputDirectory -PathType Container) { Remove-Item -LiteralPath $OutputDirectory -Recurse -Force }
    New-Item -ItemType Directory -Force -Path $OutputDirectory | Out-Null
    Write-Host "Recompiling the user's $Label RPX locally..." -ForegroundColor Cyan
    & $RecompilerPath $RpxPath $OutputDirectory --any-rpx
    if ($LASTEXITCODE) { throw "cafe-recomp failed on the $Label RPX." }
    $generatedFiles = @(Get-ChildItem -LiteralPath $OutputDirectory -File -Recurse)
    if ($generatedFiles.Count -eq 0) { throw "cafe-recomp produced no files for the $Label RPX." }
    $manifest = [ordered]@{
        schema_version = 1
        rpx_sha256 = Get-Sha256 $RpxPath
        recompiler_sha256 = Get-Sha256 $RecompilerPath
        arguments = '--any-rpx'
        files = @(
            foreach ($file in $generatedFiles) {
                [ordered]@{ path = $file.FullName.Substring($OutputDirectory.Length + 1).Replace('\', '/'); sha256 = Get-Sha256 $file.FullName }
            }
        )
    }
    $manifest | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $OutputDirectory '.u-unlocked-cache.json') -Encoding UTF8
    if (-not (Test-GeneratedCodeCache -RpxPath $RpxPath -OutputDirectory $OutputDirectory -RecompilerPath $RecompilerPath)) {
        throw "Generated $Label RPX cache failed its post-build integrity check."
    }
}
$stbHeader = Join-Path $engineRoot 'third_party\stb\stb_truetype.h'
if (-not (Test-Path -LiteralPath $stbHeader -PathType Leaf)) {
    $python = (Get-Command python).Source
    & $python (Join-Path $engineRoot 'tools\setup_deps.py') stb
    if ($LASTEXITCODE) { throw 'Fetching the pinned stb headers failed.' }
}
if (-not (Test-Path (Join-Path $prefix 'lib\libvulkan-1.a'))) {
    & (Join-Path $PSScriptRoot 'build-deps.ps1')
    if ($LASTEXITCODE) { throw 'Building pinned runtime dependencies failed.' }
}
$recompiler = Join-Path $build 'recomp\cafe-recomp.exe'
if (-not (Test-Path -LiteralPath $recompiler -PathType Leaf)) {
    & (Join-Path $PSScriptRoot 'build-recomp.ps1')
    if ($LASTEXITCODE) { throw 'Building the recompilation tools failed.' }
}
if (-not (Test-Path -LiteralPath $recompiler -PathType Leaf)) { throw "The cafe-recomp executable is missing: $recompiler" }

$env:PATH = (@((Join-Path $toolchain 'llvm-mingw\bin'), (Join-Path $prefix 'bin'), "$env:SystemRoot\System32") + @($env:PATH -split ';' | Where-Object { $_ })) -join ';'
$prebuiltRuntimeDirectory = Join-Path $engineRoot 'build-prebuilt-runtime'
if (Test-Path -LiteralPath (Join-Path $prebuiltRuntimeDirectory 'runtime-manifest.json') -PathType Leaf) {
    $env:U_UNLOCKED_PREBUILT_RUNTIME_DIR = $prebuiltRuntimeDirectory
    Write-Host 'Using the release-matched precompiled generic runtime; only local game code and final links remain.' -ForegroundColor Green
} else {
    Remove-Item Env:\U_UNLOCKED_PREBUILT_RUNTIME_DIR -ErrorAction SilentlyContinue
}
Invoke-CachedRecompile -Label 'update' -RpxPath $Rpx -OutputDirectory $updateGenerated -RecompilerPath $recompiler
Invoke-CachedRecompile -Label 'base-game' -RpxPath $BaseRpx -OutputDirectory $baseGenerated -RecompilerPath $recompiler

$configureArgs = @(
    '-S', $engineRoot, '-B', $build, '-G', 'Ninja',
    '-DCMAKE_BUILD_TYPE=Release',
    '-DCMAKE_C_COMPILER=x86_64-w64-mingw32-clang',
    '-DCMAKE_CXX_COMPILER=x86_64-w64-mingw32-clang++',
    '-DCMAKE_RC_COMPILER=x86_64-w64-mingw32-windres',
    '-DCMAKE_EXE_LINKER_FLAGS=-static',
    "-DSMASH_GENERATED_DIR=$updateGenerated",
    "-DSMASH_BASE_GENERATED_DIR=$baseGenerated"
)
& cmake @configureArgs
if ($LASTEXITCODE) { throw 'CMake configuration of the complete U Unlocked runtime failed.' }

$prebuiltLauncher = $env:U_UNLOCKED_PREBUILT_LAUNCHER
$prebuiltWuaExtractor = $env:U_UNLOCKED_PREBUILT_WUA_EXTRACTOR
if (-not [string]::IsNullOrWhiteSpace($prebuiltLauncher) -and
    -not (Test-Path -LiteralPath $prebuiltLauncher -PathType Leaf)) {
    throw "The verified release launcher is missing: $prebuiltLauncher"
}
if (-not [string]::IsNullOrWhiteSpace($prebuiltWuaExtractor) -and
    -not (Test-Path -LiteralPath $prebuiltWuaExtractor -PathType Leaf)) {
    throw "The verified release WUA extractor is missing: $prebuiltWuaExtractor"
}

$targets = @(
    'smash_update_v3',
    'smash_update_v2',
    'smash_base_v3',
    'smash_base_v2'
)
if ([string]::IsNullOrWhiteSpace($prebuiltLauncher)) { $targets += 'smash-launcher' }
if ([string]::IsNullOrWhiteSpace($prebuiltWuaExtractor)) { $targets += 'wua_extract' }

if (-not [string]::IsNullOrWhiteSpace($prebuiltLauncher) -and
    -not [string]::IsNullOrWhiteSpace($prebuiltWuaExtractor)) {
    Write-Host 'Building the Vulkan runtime and four game executables; reusing the verified release launcher and WUA extractor.' -ForegroundColor Cyan
} else {
    Write-Host 'Building the Vulkan runtime, launcher, WUA extractor, and all four game executables...' -ForegroundColor Cyan
}
& ninja -j $buildJobs -C $build @targets
if ($LASTEXITCODE) { throw 'The complete U Unlocked build failed.' }

New-Item -ItemType Directory -Force $play | Out-Null
$launcherSource = if ([string]::IsNullOrWhiteSpace($prebuiltLauncher)) {
    Join-Path $build 'U Unlocked.exe'
} else {
    $prebuiltLauncher
}
$wuaExtractorSource = if ([string]::IsNullOrWhiteSpace($prebuiltWuaExtractor)) {
    Join-Path $build 'wua_extract.exe'
} else {
    $prebuiltWuaExtractor
}
$outputs = @(
    @{ Source = (Join-Path $build 'smash.exe'); Destination = 'smash.exe' },
    @{ Source = (Join-Path $build 'smash-compat.exe'); Destination = 'smash-compat.exe' },
    @{ Source = (Join-Path $build 'smash-base.exe'); Destination = 'smash-base.exe' },
    @{ Source = (Join-Path $build 'smash-base-compat.exe'); Destination = 'smash-base-compat.exe' },
    @{ Source = $launcherSource; Destination = 'U Unlocked.exe' },
    @{ Source = $wuaExtractorSource; Destination = 'wua_extract.exe' }
)
foreach ($output in $outputs) {
    if (-not (Test-Path -LiteralPath $output.Source -PathType Leaf)) {
        throw "The build did not produce required output: $($output.Source)"
    }
    Copy-Item -LiteralPath $output.Source -Destination (Join-Path $play $output.Destination) -Force
}

$titleLogo = Join-Path $engineRoot 'runtime\res\title-logo.png'
if (-not (Test-Path -LiteralPath $titleLogo -PathType Leaf)) {
    throw "The project-owned U Unlocked title logo is missing: $titleLogo"
}
Copy-Item -LiteralPath $titleLogo -Destination (Join-Path $play 'title-logo.png') -Force

$dllDirectory = Join-Path $prefix 'bin'
$dlls = @(Get-ChildItem -LiteralPath $dllDirectory -Filter '*.dll' -File)
if ($dlls.Count -eq 0) {
    throw "No runtime dependency DLLs were found in $dllDirectory"
}
foreach ($dll in $dlls) {
    Copy-Item -LiteralPath $dll.FullName -Destination $play -Force
}

# SDL3 and other shared dependencies are built with llvm-mingw and can depend on
# compiler runtime DLLs. Keep these beside the game executables in the runtime folder.
$compilerDllDirectory = Join-Path $toolchain 'llvm-mingw\bin'
$compilerDlls = @(Get-ChildItem -LiteralPath $compilerDllDirectory -Filter '*.dll' -File)
foreach ($dll in $compilerDlls) {
    Copy-Item -LiteralPath $dll.FullName -Destination $play -Force
}

New-Item -ItemType Directory -Force (Join-Path $play 'mods') | Out-Null
$updater = Join-Path $root 'tools\windows\update-launcher.ps1'
if (-not (Test-Path -LiteralPath $updater -PathType Leaf)) {
    throw "The Windows launcher updater is missing: $updater"
}
Copy-Item -LiteralPath $updater -Destination $play -Force

$requiredOutputs = @(
    'U Unlocked.exe', 'smash.exe', 'smash-compat.exe',
    'smash-base.exe', 'smash-base-compat.exe',
    'wua_extract.exe', 'title-logo.png', 'update-launcher.ps1'
)
$missing = @($requiredOutputs | Where-Object { -not (Test-Path -LiteralPath (Join-Path $play $_) -PathType Leaf) })
if ($missing.Count -gt 0) {
    throw "Build finished with missing outputs: $($missing -join ', ')"
}
Write-Host 'U Unlocked and all four local game executables were built successfully.' -ForegroundColor Green
