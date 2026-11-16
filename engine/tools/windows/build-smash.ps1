# Builds the Smash port: dependencies (once), cafe-recomp, the translated cross_f.rpx files, the game programs and
# the launcher. Output in Play\: "U Unlocked.exe" (the launcher), smash.exe (built from the update's v304 code),
# smash-base.exe (from the game's own v1.0 code, to play without the update), smash-compat.exe (the update's for
# processors without AVX2), the launcher dependencies and required licence notices.
param([string]$Rpx = 'N:\ROMS\Wii U\Super Smash Bros for Wii U [Update] [0005000e10144f00]\code\cross_f.rpx',
      [string]$BaseRpx = 'N:\ROMS\Wii U\Super Smash Bros for Wii U [Game] [0005000010144f00]\code\cross_f.rpx')
$ErrorActionPreference = 'Stop'
# Run from the repository's tools\windows: the repository's parent holds toolchain\ (llvm-mingw, Ninja, CMake)
# and receives generated\, Play\ and dist\.
$root = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))
$toolchain = Join-Path $root 'toolchain'
$engineRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$build = Join-Path $engineRoot 'build'
$prefix = Join-Path $engineRoot 'build-deps\prefix'
$play = Join-Path $root 'Play'

# stb is header-only and is not installed into the dependency prefix. Ensure its
# pinned checkout exists even when the compiled dependency prefix is already cached.
$stbHeader = Join-Path $engineRoot 'third_party\stb\stb_truetype.h'
if (-not (Test-Path -LiteralPath $stbHeader -PathType Leaf)) {
    $python = (Get-Command python).Source
    & $python (Join-Path $engineRoot 'tools\setup_deps.py') stb
    if ($LASTEXITCODE) { throw 'Fetching the pinned stb headers failed.' }
}

if (-not (Test-Path (Join-Path $prefix 'lib\libvulkan-1.a'))) {
    & (Join-Path $PSScriptRoot 'build-deps.ps1')
}
& (Join-Path $PSScriptRoot 'build-recomp.ps1') # also configures $build
$env:PATH = @((Join-Path $toolchain 'llvm-mingw\bin'), (Join-Path $toolchain 'Ninja'), (Join-Path $toolchain 'CMake\bin'),
    "$env:SystemRoot\System32") -join ';'

# One program per code version: the update's in build\, the game's own in build-base\.
function Build-Game([string]$rpx, [string]$generated, [string]$dir, [string[]]$targets, [string[]]$options = @()) {
    & (Join-Path $build 'recomp\cafe-recomp.exe') $rpx $generated --any-rpx
    if ($LASTEXITCODE) { throw "cafe-recomp failed on $rpx" }
    cmake -S $engineRoot -B $dir -G Ninja -DCMAKE_BUILD_TYPE=Release -DCMAKE_C_COMPILER=x86_64-w64-mingw32-clang `
        -DCMAKE_CXX_COMPILER=x86_64-w64-mingw32-clang++ -DCMAKE_RC_COMPILER=x86_64-w64-mingw32-windres `
        -DCMAKE_EXE_LINKER_FLAGS=-static "-DSMASH_GENERATED_DIR=$generated" @options
    if ($LASTEXITCODE) { throw 'cmake configure failed' }
    ninja -C $dir @targets
    if ($LASTEXITCODE) { throw 'build failed' }
}
Build-Game $Rpx (Join-Path $root 'generated\smash') $build @('smash', 'smash-launcher', 'wua_extract')
New-Item -ItemType Directory -Force $play | Out-Null
Copy-Item (Join-Path $build 'smash.exe'), (Join-Path $build 'U Unlocked.exe') $play
# The same code for processors without AVX2/FMA (x86-64-v2); the launcher picks it on those.
$compatBuild = Join-Path $engineRoot 'build-compat'
Build-Game $Rpx (Join-Path $root 'generated\smash') $compatBuild @('smash') @('-DSMASH_COMPAT=ON')
Copy-Item (Join-Path $compatBuild 'smash-compat.exe') $play
if (Test-Path $BaseRpx) {
    $baseBuild = Join-Path $engineRoot 'build-base'
    Build-Game $BaseRpx (Join-Path $root 'generated\smash-base') $baseBuild @('smash')
    Copy-Item (Join-Path $baseBuild 'smash.exe') (Join-Path $play 'smash-base.exe')
}
Copy-Item (Join-Path $prefix 'bin\*.dll') $play
# U Unlocked supplies its own launcher identity; no game title artwork is copied.
# U Unlocked uses its own launcher background.
New-Item -ItemType Directory -Force (Join-Path $play 'mods') | Out-Null
$updater = Join-Path (Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))) 'tools\windows\update-launcher.ps1'
if (-not (Test-Path -LiteralPath $updater -PathType Leaf)) {
    throw "The Windows launcher updater is missing: $updater"
}
Copy-Item -LiteralPath $updater -Destination $play
