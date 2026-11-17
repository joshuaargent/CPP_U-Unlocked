$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$scriptPath = Join-Path $PSScriptRoot '..\..\tools\windows\runtime-activation.ps1'
. (Resolve-Path -LiteralPath $scriptPath).Path

$root = Join-Path ([System.IO.Path]::GetTempPath()) ("u-unlocked-runtime-test-" + [guid]::NewGuid().ToString('N'))
$required = @('smash.exe', 'smash-compat.exe', 'smash-base.exe', 'smash-base-compat.exe', 'wua_extract.exe', 'title-logo.png')

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

function New-TestRuntime {
    param([string]$Directory, [string]$Marker, [string[]]$Files = $required)
    New-Item -ItemType Directory -Force -Path $Directory | Out-Null
    foreach ($file in $Files) {
        $path = Join-Path $Directory $file
        $parent = Split-Path -Parent $path
        if ($parent -and -not (Test-Path -LiteralPath $parent)) {
            New-Item -ItemType Directory -Force -Path $parent | Out-Null
        }
        [System.IO.File]::WriteAllText($path, $Marker)
    }
}

try {
    New-Item -ItemType Directory -Force -Path $root | Out-Null

    # Crash after old runtime -> backup, before staging -> active runtime.
    $stage = Join-Path $root '.runtime-staging'
    $target = Join-Path $root 'runtime'
    $backup = Join-Path $root '.runtime-previous'
    New-TestRuntime -Directory $backup -Marker 'old'
    New-TestRuntime -Directory $stage -Marker 'partial'
    Recover-RuntimeActivation -Stage $stage -Target $target -Backup $backup -RequiredFiles $required
    Assert-True (Test-Path -LiteralPath $target) 'Recovery did not restore a missing active runtime.'
    Assert-True (-not (Test-Path -LiteralPath $backup)) 'Recovery left the backup directory behind.'
    Assert-True (-not (Test-Path -LiteralPath $stage)) 'Recovery did not discard the incomplete staging directory.'
    Assert-True ([System.IO.File]::ReadAllText((Join-Path $target 'smash.exe')) -eq 'old') 'Recovery did not restore the previous executable.'

    # Crash after new runtime activation, before deleting the old backup.
    $backup = Join-Path $root '.runtime-previous'
    New-TestRuntime -Directory $backup -Marker 'old'
    [System.IO.File]::WriteAllText((Join-Path $target 'smash.exe'), 'new')
    Recover-RuntimeActivation -Stage $stage -Target $target -Backup $backup -RequiredFiles $required
    Assert-True (-not (Test-Path -LiteralPath $backup)) 'A complete active runtime did not retire its stale backup.'
    Assert-True ([System.IO.File]::ReadAllText((Join-Path $target 'smash.exe')) -eq 'new') 'Recovery replaced a complete new runtime.'

    # An incomplete active runtime must be replaced by the complete backup.
    $backup = Join-Path $root '.runtime-previous'
    New-TestRuntime -Directory $backup -Marker 'old'
    Remove-Item -LiteralPath (Join-Path $target 'smash-base.exe') -Force
    Recover-RuntimeActivation -Stage $stage -Target $target -Backup $backup -RequiredFiles $required
    Assert-True ([System.IO.File]::ReadAllText((Join-Path $target 'smash.exe')) -eq 'old') 'An incomplete active runtime was not rolled back.'
    Assert-True (-not (Test-Path -LiteralPath ($target + '.incomplete'))) 'The incomplete runtime quarantine was not cleaned up.'

    # A failed stage validation must leave the currently active runtime untouched.
    $stage = Join-Path $root '.runtime-staging'
    New-TestRuntime -Directory $stage -Marker 'new' -Files ($required | Select-Object -First ($required.Count - 1))
    $before = [System.IO.File]::ReadAllText((Join-Path $target 'smash.exe'))
    $failed = $false
    try {
        Activate-StagedRuntime -Stage $stage -Target $target -Backup $backup -RequiredFiles $required
    } catch {
        $failed = $true
    }
    Assert-True $failed 'Activation accepted an incomplete staged runtime.'
    Assert-True ([System.IO.File]::ReadAllText((Join-Path $target 'smash.exe')) -eq $before) 'Failed stage validation changed the active runtime.'

    # A valid staged runtime replaces the old runtime and retires the backup.
    Remove-Item -LiteralPath $stage -Recurse -Force
    New-TestRuntime -Directory $stage -Marker 'new'
    Activate-StagedRuntime -Stage $stage -Target $target -Backup $backup -RequiredFiles $required
    Assert-True ([System.IO.File]::ReadAllText((Join-Path $target 'smash.exe')) -eq 'new') 'A valid staged runtime was not activated.'
    Assert-True (-not (Test-Path -LiteralPath $backup)) 'Successful activation did not remove its backup.'
    Assert-True (-not (Test-Path -LiteralPath $stage)) 'Successful activation left the staging directory behind.'

    Write-Host 'Runtime activation recovery tests passed.' -ForegroundColor Green
} finally {
    if (Test-Path -LiteralPath $root) {
        Remove-Item -LiteralPath $root -Recurse -Force
    }
}
