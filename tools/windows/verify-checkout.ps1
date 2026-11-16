# Validates the U Unlocked checkout and its pinned upstream source.
[CmdletBinding()]
param(
    [switch]$SkipToolchainCheck
)

$ErrorActionPreference = 'Stop'
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$upstreamPath = Join-Path $repoRoot 'upstream'
$expectedCommit = 'f145e7fc14d0be2caf712cc4080f9deb3e7ab6aa'

if (-not (Test-Path (Join-Path $upstreamPath '.git'))) {
    throw "The Smash4PC submodule is missing. Run: git submodule update --init --recursive"
}

$actualCommit = (& git -C $upstreamPath rev-parse HEAD).Trim()
if ($LASTEXITCODE -ne 0) {
    throw 'Unable to read the Smash4PC submodule commit. Check that Git is installed and the submodule is initialised.'
}
if ($actualCommit -ne $expectedCommit) {
    throw "Unexpected Smash4PC revision. Expected $expectedCommit but found $actualCommit. Review upstream updates before building."
}

$dirty = @(& git -C $upstreamPath status --porcelain --untracked-files=no)
if ($LASTEXITCODE -ne 0) {
    throw 'Unable to inspect the Smash4PC submodule working tree.'
}
if ($dirty.Count -gt 0) {
    throw "The Smash4PC submodule has local modifications. Keep project changes outside the submodule or record an intentional upstream patch."
}

if (-not $SkipToolchainCheck) {
    $required = @(
        (Join-Path $repoRoot 'toolchain\llvm-mingw\bin\x86_64-w64-mingw32-clang++.exe'),
        (Join-Path $repoRoot 'toolchain\Ninja\ninja.exe'),
        (Join-Path $repoRoot 'toolchain\CMake\bin\cmake.exe')
    )
    $missing = @($required | Where-Object { -not (Test-Path $_) })
    if ($missing.Count -gt 0) {
        $missing | ForEach-Object { Write-Host "Missing: $_" -ForegroundColor Yellow }
        throw 'The upstream Windows toolchain is incomplete. See the README build requirements.'
    }
}

Write-Host "U Unlocked checkout verified. Smash4PC is pinned at $actualCommit." -ForegroundColor Green
