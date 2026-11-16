# Builds the native U Unlocked runtime and launcher from the in-repository engine source.
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
$enginePath = Join-Path $repoRoot 'engine'
$verifyScript = Join-Path $PSScriptRoot 'verify-checkout.ps1'
$iconScript = Join-Path $PSScriptRoot 'new-u-unlocked-icon.ps1'
$engineBuild = Join-Path $enginePath 'tools\windows\build-smash.ps1'

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

# The resource compiler requires the icon to exist before CMake configures the Windows target.
& $iconScript -SourceRoot $enginePath
if ($LASTEXITCODE -ne 0) {
    throw "Icon generation failed with exit code $LASTEXITCODE."
}

if (-not (Test-Path -LiteralPath $engineBuild -PathType Leaf)) {
    throw "The native build entry point is missing: $engineBuild"
}

Write-Host 'Building U Unlocked from its in-repository native source.' -ForegroundColor Cyan
if ($resolvedBaseRpx) {
    & $engineBuild -Rpx $resolvedRpx -BaseRpx $resolvedBaseRpx
} else {
    & $engineBuild -Rpx $resolvedRpx -BaseRpx ''
}
if ($LASTEXITCODE -ne 0) {
    throw "U Unlocked build failed with exit code $LASTEXITCODE."
}

$playDirectory = Join-Path $repoRoot 'Play'
$expected = @('U Unlocked.exe', 'smash.exe', 'wua_extract.exe', 'title-logo.png')
$missing = @($expected | Where-Object { -not (Test-Path -LiteralPath (Join-Path $playDirectory $_) -PathType Leaf) })
if ($missing.Count -gt 0) {
    $missing | ForEach-Object { Write-Host "Missing output: $_" -ForegroundColor Red }
    throw 'The build completed without producing all required U Unlocked outputs.'
}

Write-Host "U Unlocked build completed: $(Join-Path $playDirectory 'U Unlocked.exe')" -ForegroundColor Green
