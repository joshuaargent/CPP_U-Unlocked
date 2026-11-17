function Get-RuntimeMissingFiles {
    param(
        [Parameter(Mandatory = $true)][string]$Directory,
        [Parameter(Mandatory = $true)][string[]]$RequiredFiles
    )

    return @($RequiredFiles | Where-Object {
        -not (Test-Path -LiteralPath (Join-Path $Directory $_) -PathType Leaf)
    })
}

function Recover-RuntimeActivation {
    param(
        [Parameter(Mandatory = $true)][string]$Stage,
        [Parameter(Mandatory = $true)][string]$Target,
        [Parameter(Mandatory = $true)][string]$Backup,
        [Parameter(Mandatory = $true)][string[]]$RequiredFiles
    )

    # A staging directory is never authoritative: it has not been activated.
    if (Test-Path -LiteralPath $Stage) {
        Remove-Item -LiteralPath $Stage -Recurse -Force
    }

    if (-not (Test-Path -LiteralPath $Backup)) {
        return
    }

    if (-not (Test-Path -LiteralPath $Target)) {
        Move-Item -LiteralPath $Backup -Destination $Target
        Write-Host 'Recovered the previous runtime after an interrupted activation.' -ForegroundColor Yellow
        return
    }

    $missing = @(Get-RuntimeMissingFiles -Directory $Target -RequiredFiles $RequiredFiles)
    if ($missing.Count -eq 0) {
        # The new runtime was fully activated; only cleanup was interrupted.
        Remove-Item -LiteralPath $Backup -Recurse -Force
        return
    }

    $failedTarget = "$Target.incomplete"
    if (Test-Path -LiteralPath $failedTarget) {
        Remove-Item -LiteralPath $failedTarget -Recurse -Force
    }
    Move-Item -LiteralPath $Target -Destination $failedTarget
    try {
        Move-Item -LiteralPath $Backup -Destination $Target
    } catch {
        if (-not (Test-Path -LiteralPath $Target) -and
            (Test-Path -LiteralPath $failedTarget)) {
            Move-Item -LiteralPath $failedTarget -Destination $Target
        }
        throw
    }
    Remove-Item -LiteralPath $failedTarget -Recurse -Force
    Write-Host 'Restored the previous runtime because the interrupted replacement was incomplete.' -ForegroundColor Yellow
}

function Activate-StagedRuntime {
    param(
        [Parameter(Mandatory = $true)][string]$Stage,
        [Parameter(Mandatory = $true)][string]$Target,
        [Parameter(Mandatory = $true)][string]$Backup,
        [Parameter(Mandatory = $true)][string[]]$RequiredFiles
    )

    $missingStage = @(Get-RuntimeMissingFiles -Directory $Stage -RequiredFiles $RequiredFiles)
    if ($missingStage.Count -gt 0) {
        throw "Staged runtime is incomplete; missing: $($missingStage -join ', ')."
    }
    if (Test-Path -LiteralPath $Backup) {
        throw "Refusing to overwrite an existing recovery backup: $Backup"
    }

    if (Test-Path -LiteralPath $Target) {
        Move-Item -LiteralPath $Target -Destination $Backup
    }

    try {
        Move-Item -LiteralPath $Stage -Destination $Target
        $missingTarget = @(Get-RuntimeMissingFiles -Directory $Target -RequiredFiles $RequiredFiles)
        if ($missingTarget.Count -gt 0) {
            throw "Activated runtime is incomplete; missing: $($missingTarget -join ', ')."
        }
    } catch {
        if (Test-Path -LiteralPath $Target) {
            Remove-Item -LiteralPath $Target -Recurse -Force
        }
        if (Test-Path -LiteralPath $Backup) {
            Move-Item -LiteralPath $Backup -Destination $Target
        }
        throw
    }

    if (Test-Path -LiteralPath $Backup) {
        Remove-Item -LiteralPath $Backup -Recurse -Force
    }
}
