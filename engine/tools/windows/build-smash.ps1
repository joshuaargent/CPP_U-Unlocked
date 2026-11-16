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
$toolchain = Join-Path $root 'toolchain'
$engineRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$build = Join-Path $engineRoot 'build'
$prefix = Join-Path $engineRoot 'build-deps\prefix'
$play = Join-Path $root 'Play'
$updateGenerated = Join-Path $root 'generated\smash'
$baseGenerated = Join-Path $root 'generated\smash-base'

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
& (Join-Path $PSScriptRoot 'build-recomp.ps1')
if ($LASTEXITCODE) { throw 'Building the recompilation tools failed.' }

$env:PATH = @((Join-Path $toolchain 'llvm-mingw\bin'), "$env:SystemRoot\System32") + @($env:PATH -split ';' | Where-Object { $_ }) -join ';'
$recompiler = Join-Path $build 'recomp\cafe-recomp.exe'
if (-not (Test-Path -LiteralPath $recompiler -PathType Leaf)) {
    throw "The cafe-recomp executable was not built: $recompiler"
}

Write-Host 'Recompiling the user's update RPX locally...' -ForegroundColor Cyan
& $recompiler $Rpx $updateGenerated --any-rpx
if ($LASTEXITCODE) { throw 'cafe-recomp failed on the update RPX.' }

Write-Host 'Recompiling the user's base-game RPX locally...' -ForegroundColor Cyan
& $recompiler $BaseRpx $baseGenerated --any-rpx
if ($LASTEXITCODE) { throw 'cafe-recomp failed on the base-game RPX.' }

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

$targets = @(
    'smash_update_v3',
    'smash_update_v2',
    'smash_base_v3',
    'smash_base_v2',
    'smash-launcher',
    'wua_extract'
)
Write-Host 'Building the Vulkan runtime, launcher, and all four game executables...' -ForegroundColor Cyan
& ninja -C $build @targets
if ($LASTEXITCODE) { throw 'The complete U Unlocked build failed.' }

New-Item -ItemType Directory -Force $play | Out-Null
$outputs = @(
    @{ Source = (Join-Path $build 'smash.exe'); Destination = 'smash.exe' },
    @{ Source = (Join-Path $build 'smash-compat.exe'); Destination = 'smash-compat.exe' },
    @{ Source = (Join-Path $build 'smash-base.exe'); Destination = 'smash-base.exe' },
    @{ Source = (Join-Path $build 'smash-base-compat.exe'); Destination = 'smash-base-compat.exe' },
    @{ Source = (Join-Path $build 'U Unlocked.exe'); Destination = 'U Unlocked.exe' },
    @{ Source = (Join-Path $build 'wua_extract.exe'); Destination = 'wua_extract.exe' }
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
