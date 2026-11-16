# Builds the pinned Smash4PC baseline from the U Unlocked checkout.
# This is not yet a branded U Unlocked release: the upstream launcher is still used.
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$Rpx,

    [Parameter(Mandatory = $false)]
    [ValidateNotNullOrEmpty()]
    [string]$BaseRpx
)

$ErrorActionPreference = 'Stop'
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$verifyScript = Join-Path $PSScriptRoot 'verify-checkout.ps1'
$upstreamBuild = Join-Path $repoRoot 'upstream\tools\windows\build-smash.ps1'

& $verifyScript
if ($LASTEXITCODE -ne 0) {
    throw 'Checkout validation failed.'
}

if (-not (Test-Path -LiteralPath $Rpx -PathType Leaf)) {
    throw "Update RPX not found: $Rpx"
}
if ($BaseRpx -and -not (Test-Path -LiteralPath $BaseRpx -PathType Leaf)) {
    throw "Base-game RPX not found: $BaseRpx"
}
if (-not (Test-Path -LiteralPath $upstreamBuild -PathType Leaf)) {
    throw "The pinned Smash4PC build script is missing: $upstreamBuild"
}

Write-Host 'Building the pinned Smash4PC baseline. The resulting launcher is not yet U Unlocked-branded.' -ForegroundColor Cyan
if ($BaseRpx) {
    & $upstreamBuild -Rpx $Rpx -BaseRpx $BaseRpx
} else {
    & $upstreamBuild -Rpx $Rpx
}
if ($LASTEXITCODE -ne 0) {
    throw "Smash4PC build failed with exit code $LASTEXITCODE."
}

$launcher = Join-Path $repoRoot 'Play\Smash 4 PC.exe'
if (-not (Test-Path -LiteralPath $launcher -PathType Leaf)) {
    throw "Build script returned without producing the expected launcher: $launcher"
}

Write-Host "Baseline build completed: $launcher" -ForegroundColor Green
Write-Host 'Do not distribute this build as a U Unlocked release. Rebranding and project-owned launcher features are still in development.' -ForegroundColor Yellow
