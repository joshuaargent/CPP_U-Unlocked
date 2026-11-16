# Build U Unlocked directly from the separately selected base-game and update folders.
# Game-specific output is generated locally and is never copied into the source repository or release assets.
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$GameDirectory,

    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$UpdateDirectory,

    [string]$LogDirectory
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Resolve-TitleFolder {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$ExpectedTitleId,
        [Parameter(Mandatory = $true)][string]$Label
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
        throw "$Label folder does not exist: $Path"
    }

    $resolved = (Resolve-Path -LiteralPath $Path).Path
    $metadataPath = Join-Path $resolved 'code\app.xml'
    $rpxPath = Join-Path $resolved 'code\cross_f.rpx'

    if (-not (Test-Path -LiteralPath $metadataPath -PathType Leaf)) {
        throw "$Label folder is missing code\app.xml. Select the extracted title folder, not its parent or the code folder."
    }
    if (-not (Test-Path -LiteralPath $rpxPath -PathType Leaf)) {
        throw "$Label folder is missing code\cross_f.rpx. This build currently requires the title's cross_f.rpx input."
    }

    [xml]$metadata = Get-Content -LiteralPath $metadataPath -Raw
    $titleNode = $metadata.SelectSingleNode('//title_id')
    if (-not $titleNode -or $titleNode.InnerText.Trim().ToUpperInvariant() -ne $ExpectedTitleId) {
        $actual = if ($titleNode) { $titleNode.InnerText.Trim() } else { 'not present' }
        throw "$Label title ID mismatch. Expected $ExpectedTitleId; found $actual."
    }

    $rpx = Get-Item -LiteralPath $rpxPath
    if ($rpx.Length -lt 1MB) {
        throw "$Label RPX is unexpectedly small ($($rpx.Length) bytes). Check that the title dump is complete."
    }

    return [pscustomobject]@{
        Folder = $resolved
        Rpx = $rpx.FullName
        Size = $rpx.Length
    }
}

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$buildEntry = Join-Path $repoRoot 'tools\windows\build-u-unlocked.ps1'
if (-not (Test-Path -LiteralPath $buildEntry -PathType Leaf)) {
    throw "The source build entry point is missing: $buildEntry. This build kit must be run from a complete U Unlocked source checkout."
}

$environmentSetup = Join-Path $PSScriptRoot 'setup-build-environment.ps1'
if (-not (Test-Path -LiteralPath $environmentSetup -PathType Leaf)) {
    throw "The build environment bootstrap is missing: $environmentSetup"
}
Write-Host 'Preparing the pinned Windows build environment...' -ForegroundColor Cyan
& $environmentSetup
if ($LASTEXITCODE -ne 0) { throw 'Windows build environment setup failed.' }

$game = Resolve-TitleFolder -Path $GameDirectory -ExpectedTitleId '0005000010144F00' -Label 'Base game'
$update = Resolve-TitleFolder -Path $UpdateDirectory -ExpectedTitleId '0005000E10144F00' -Label 'Game update'

if ([string]::IsNullOrWhiteSpace($LogDirectory)) {
    $local = if ($env:LOCALAPPDATA) { $env:LOCALAPPDATA } else { $env:TEMP }
    $LogDirectory = Join-Path $local 'U Unlocked\BuildLogs'
}
New-Item -ItemType Directory -Force -Path $LogDirectory | Out-Null
$logPath = Join-Path $LogDirectory ("build-{0:yyyyMMdd-HHmmss}.log" -f (Get-Date))
$transcriptStarted = $false

try {
    Start-Transcript -LiteralPath $logPath -Force | Out-Null
    $transcriptStarted = $true

    Write-Host 'U Unlocked local runtime build' -ForegroundColor Cyan
    Write-Host "Base game: $($game.Folder)"
    Write-Host "Update:    $($update.Folder)"
    Write-Host "Base RPX:  $($game.Size) bytes"
    Write-Host "Update RPX:$($update.Size) bytes"
    Write-Host 'Game files remain in their selected locations. Generated code and executables stay on this PC.'

    & (Join-Path $repoRoot 'tools\windows\verify-checkout.ps1')
    & $buildEntry -Rpx $update.Rpx -BaseRpx $game.Rpx
    $playDirectory = Join-Path $repoRoot 'Play'
    $required = @(
        'U Unlocked.exe',
        'smash.exe',
        'smash-compat.exe',
        'smash-base.exe',
        'smash-base-compat.exe',
        'wua_extract.exe',
        'title-logo.png'
    )
    $missing = @($required | Where-Object {
        -not (Test-Path -LiteralPath (Join-Path $playDirectory $_) -PathType Leaf)
    })
    if ($missing.Count -gt 0) {
        throw "Build returned without all required files. Missing: $($missing -join ', ')."
    }

    Write-Host "Build verified. Launcher: $(Join-Path $playDirectory 'U Unlocked.exe')" -ForegroundColor Green
    Write-Host "Build log: $logPath"
} catch {
    Write-Host "BUILD FAILED: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host "Build log: $logPath"
    throw
} finally {
    if ($transcriptStarted) {
        Stop-Transcript | Out-Null
    }
}
