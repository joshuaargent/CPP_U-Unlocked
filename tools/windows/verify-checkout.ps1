# Validates the U Unlocked source tree and local Windows toolchain.
[CmdletBinding()]
param(
    [switch]$SkipToolchainCheck
)

$ErrorActionPreference = 'Stop'
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$enginePath = Join-Path $repoRoot 'engine'

$requiredSource = @(
    (Join-Path $enginePath 'CMakeLists.txt'),
    (Join-Path $enginePath 'runtime\src\smash_main.cpp'),
    (Join-Path $enginePath 'runtime\src\host\window.cpp'),
    (Join-Path $enginePath 'recomp\src\recompile_main.cpp'),
    (Join-Path $enginePath 'tools\windows\build-smash.ps1'),
    (Join-Path $enginePath 'third_party\cemu_nex\LICENSE.txt'),
    (Join-Path $repoRoot 'LICENSES\RECOMPILATION-MIT-LICENSE.txt')
)
$missingSource = @($requiredSource | Where-Object { -not (Test-Path -LiteralPath $_ -PathType Leaf) })
if ($missingSource.Count -gt 0) {
    $missingSource | ForEach-Object { Write-Host "Missing source: $_" -ForegroundColor Red }
    throw 'The U Unlocked source tree is incomplete.'
}

if (-not $SkipToolchainCheck) {
    $requiredToolchain = @(
        (Join-Path $repoRoot 'toolchain\llvm-mingw\bin\x86_64-w64-mingw32-clang++.exe'),
        (Join-Path $repoRoot 'toolchain\Ninja\ninja.exe'),
        (Join-Path $repoRoot 'toolchain\CMake\bin\cmake.exe')
    )
    $missingToolchain = @($requiredToolchain | Where-Object { -not (Test-Path -LiteralPath $_ -PathType Leaf) })
    if ($missingToolchain.Count -gt 0) {
        $missingToolchain | ForEach-Object { Write-Host "Missing tool: $_" -ForegroundColor Yellow }
        throw 'The Windows toolchain is incomplete. See the README build requirements.'
    }
}

Write-Host 'U Unlocked source tree verified.' -ForegroundColor Green
