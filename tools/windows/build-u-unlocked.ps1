# Builds U Unlocked from an isolated copy of the pinned Smash4PC source.
# The upstream submodule remains untouched. This milestone applies branding only;
# the redesigned launcher, custom controller mapping and expanded settings are still in development.
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
$upstreamPath = Join-Path $repoRoot 'upstream'
$buildSource = Join-Path $repoRoot 'upstream-build'
$verifyScript = Join-Path $PSScriptRoot 'verify-checkout.ps1'
$brandingScript = Join-Path $PSScriptRoot 'apply-u-unlocked-branding.ps1'

& $verifyScript

if (-not (Test-Path -LiteralPath $Rpx -PathType Leaf)) {
    throw "Update RPX not found: $Rpx"
}
$resolvedRpx = (Resolve-Path -LiteralPath $Rpx).Path
$resolvedBaseRpx = $null
if ($BaseRpx) {
    if (-not (Test-Path -LiteralPath $BaseRpx -PathType Leaf)) {
        throw "Base-game RPX not found: $BaseRpx"
    }
    $resolvedBaseRpx = (Resolve-Path -LiteralPath $BaseRpx).Path
}

# Keep the submodule clean: build from a disposable mirror and retain only its build caches.
New-Item -ItemType Directory -Force -Path $buildSource | Out-Null
$robocopy = Join-Path $env:SystemRoot 'System32\robocopy.exe'
if (-not (Test-Path -LiteralPath $robocopy -PathType Leaf)) {
    throw "Robocopy was not found: $robocopy"
}

& $robocopy $upstreamPath $buildSource /MIR /R:2 /W:2 /XD '.git' 'build' 'build-deps' /XF '.git' /NFL /NDL /NJH /NJS /NP
$copyExitCode = $LASTEXITCODE
if ($copyExitCode -ge 8) {
    throw "Unable to prepare the isolated source copy. Robocopy returned $copyExitCode."
}
$global:LASTEXITCODE = 0

& $brandingScript -SourceRoot $buildSource

$upstreamBuild = Join-Path $buildSource 'tools\windows\build-smash.ps1'
if (-not (Test-Path -LiteralPath $upstreamBuild -PathType Leaf)) {
    throw "The pinned upstream build script is missing: $upstreamBuild"
}

Write-Host 'Building the game runtime and U Unlocked-branded launcher from the isolated source copy.' -ForegroundColor Cyan
$global:LASTEXITCODE = 0
if ($resolvedBaseRpx) {
    & $upstreamBuild -Rpx $resolvedRpx -BaseRpx $resolvedBaseRpx
} else {
    & $upstreamBuild -Rpx $resolvedRpx
}
if ($LASTEXITCODE -ne 0) {
    throw "The upstream build failed with exit code $LASTEXITCODE."
}

$playDirectory = Join-Path $repoRoot 'Play'
$launcher = Join-Path $playDirectory 'U Unlocked.exe'
$game = Join-Path $playDirectory 'smash.exe'
if (-not (Test-Path -LiteralPath $launcher -PathType Leaf)) {
    throw "The build completed without producing the expected launcher: $launcher"
}
if (-not (Test-Path -LiteralPath $game -PathType Leaf)) {
    throw "The build completed without producing the expected game runtime: $game"
}

foreach ($staleAsset in @('title-logo.png', 'launcher-background.jpg')) {
    $assetPath = Join-Path $playDirectory $staleAsset
    if (Test-Path -LiteralPath $assetPath -PathType Leaf) {
        Remove-Item -LiteralPath $assetPath -Force
    }
}

Write-Host "U Unlocked branding build completed: $launcher" -ForegroundColor Green
Write-Host 'The launcher still uses the upstream menu layout. Do not describe this build as feature-complete or publish it as a finished release.' -ForegroundColor Yellow
