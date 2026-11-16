# Builds the Smash port from the user's own base-game and update RPX files.
# Output in Play: U Unlocked.exe, smash.exe (update), smash-compat.exe (x86-64-v2),
# smash-base.exe (base game), WUA extractor, logo and runtime dependencies.
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

$env:PATH = @((Join-Path $toolchain 'llvm-mingw\bin'), (Join-Path $toolchain 'Ninja'), (Join-Path $toolchain 'CMake\bin'), "$env:SystemRoot\System32") -join ';'

function Build-Game([string]$rpx, [string]$generated, [string]$dir, [string[]]$targets, [string[]]$options = @()) {
    & (Join-Path $build 'recomp\cafe-recomp.exe') $rpx $generated --any-rpx
    if ($LASTEXITCODE) { throw "cafe-recomp failed on $rpx" }
    $configureArgs = @(
        '-S', $engineRoot, '-B', $dir, '-G', 'Ninja',
        '-DCMAKE_BUILD_TYPE=Release',
        '-DCMAKE_C_COMPILER=x86_64-w64-mingw32-clang',
        '-DCMAKE_CXX_COMPILER=x86_64-w64-mingw32-clang++',
        '-DCMAKE_RC_COMPILER=x86_64-w64-mingw32-windres',
        '-DCMAKE_EXE_LINKER_FLAGS=-static',
        "-DSMASH_GENERATED_DIR=$generated"
    ) + $options
    & cmake @configureArgs
    if ($LASTEXITCODE) { throw "CMake configure failed for $dir" }
    & ninja -C $dir @targets
    if ($LASTEXITCODE) { throw "Build failed for $dir" }
}

Build-Game $Rpx (Join-Path $root 'generated\smash') $build @('smash', 'smash-launcher', 'wua_extract')
New-Item -ItemType Directory -Force $play | Out-Null
Copy-Item (Join-Path $build 'smash.exe'), (Join-Path $build 'U Unlocked.exe'), (Join-Path $build 'wua_extract.exe') $play
$titleLogo = Join-Path $engineRoot 'runtime\res\title-logo.png'
if (-not (Test-Path -LiteralPath $titleLogo -PathType Leaf)) {
    throw "The project-owned U Unlocked title logo is missing: $titleLogo"
}
Copy-Item -LiteralPath $titleLogo -Destination (Join-Path $play 'title-logo.png')

$compatBuild = Join-Path $engineRoot 'build-compat'
Build-Game $Rpx (Join-Path $root 'generated\smash') $compatBuild @('smash') @('-DSMASH_COMPAT=ON')
Copy-Item (Join-Path $compatBuild 'smash-compat.exe') $play

# The launcher supports base-game-only play; always provide its executable.
$baseBuild = Join-Path $engineRoot 'build-base'
Build-Game $BaseRpx (Join-Path $root 'generated\smash-base') $baseBuild @('smash')
Copy-Item (Join-Path $baseBuild 'smash.exe') (Join-Path $play 'smash-base.exe')

Copy-Item (Join-Path $prefix 'bin\*.dll') $play
New-Item -ItemType Directory -Force (Join-Path $play 'mods') | Out-Null
$updater = Join-Path (Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))) 'tools\windows\update-launcher.ps1'
if (-not (Test-Path -LiteralPath $updater -PathType Leaf)) {
    throw "The Windows launcher updater is missing: $updater"
}
Copy-Item -LiteralPath $updater -Destination $play

$requiredOutputs = @('U Unlocked.exe', 'smash.exe', 'smash-compat.exe', 'smash-base.exe', 'wua_extract.exe', 'title-logo.png')
$missing = @($requiredOutputs | Where-Object { -not (Test-Path -LiteralPath (Join-Path $play $_) -PathType Leaf) })
if ($missing.Count -gt 0) {
    throw "Build finished with missing outputs: $($missing -join ', ')"
}
