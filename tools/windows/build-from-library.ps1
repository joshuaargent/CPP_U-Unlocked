# Build U Unlocked directly from the separately selected base-game and update folders.
# Generated game-specific code and executables remain local to this PC.
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$GameDirectory,

    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$UpdateDirectory,

    [string]$LogDirectory,

    [string]$LauncherDirectory
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

    try {
        [xml]$metadata = Get-Content -LiteralPath $metadataPath -Raw
    } catch {
        throw "$Label code\app.xml is not valid XML: $($_.Exception.Message)"
    }
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

function Find-BuildTool {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [string[]]$Candidates = @()
    )
    foreach ($candidate in $Candidates) {
        if (Test-Path -LiteralPath $candidate -PathType Leaf) { return $candidate }
    }
    $command = Get-Command $Name -ErrorAction SilentlyContinue
    if ($command) { return $command.Source }
    return $null
}

function Copy-PreservedDirectory {
    param(
        [Parameter(Mandatory = $true)][string]$Source,
        [Parameter(Mandatory = $true)][string]$Destination
    )
    if (-not (Test-Path -LiteralPath $Source -PathType Container)) { return }
    New-Item -ItemType Directory -Force -Path $Destination | Out-Null
    foreach ($item in Get-ChildItem -LiteralPath $Source -Force) {
        if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) { continue }
        $target = Join-Path $Destination $item.Name
        if ($item.PSIsContainer) {
            Copy-PreservedDirectory -Source $item.FullName -Destination $target
        } else {
            Copy-Item -LiteralPath $item.FullName -Destination $target -Force
        }
    }
}

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$buildEntry = Join-Path $repoRoot 'tools\windows\build-u-unlocked.ps1'
$environmentSetup = Join-Path $PSScriptRoot 'setup-build-environment.ps1'
$verifyScript = Join-Path $PSScriptRoot 'verify-checkout.ps1'

foreach ($required in @($buildEntry, $environmentSetup, $verifyScript)) {
    if (-not (Test-Path -LiteralPath $required -PathType Leaf)) {
        throw "A required local build script is missing: $required"
    }
}

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

    Write-Host 'U Unlocked local Vulkan runtime build' -ForegroundColor Cyan
    Write-Host 'Validating the selected game folders...'
    $game = Resolve-TitleFolder -Path $GameDirectory -ExpectedTitleId '0005000010144F00' -Label 'Base game'
    $update = Resolve-TitleFolder -Path $UpdateDirectory -ExpectedTitleId '0005000E10144F00' -Label 'Game update'

    Write-Host "Base game: $($game.Folder)"
    Write-Host "Update:    $($update.Folder)"
    Write-Host "Base RPX:  $($game.Size) bytes"
    Write-Host "Update RPX: $($update.Size) bytes"
    Write-Host 'Installing build prerequisites and preparing pinned dependencies. The first build can take a while.'
    Write-Host 'Game files remain in their selected locations. Generated code and executables stay on this PC.'

    & $environmentSetup
    if ($LASTEXITCODE -ne 0) { throw "Windows build environment setup failed with exit code $LASTEXITCODE." }

    # Child PowerShell processes cannot modify this process's PATH. Resolve the
    # just-installed tools again here before verify-checkout and the build scripts.
    $toolchainRoot = Join-Path $repoRoot 'toolchain'
    $cmake = Find-BuildTool 'cmake.exe' @("$env:ProgramFiles\CMake\bin\cmake.exe", "$env:LOCALAPPDATA\Programs\CMake\bin\cmake.exe")
    $ninja = Find-BuildTool 'ninja.exe' @("$env:LOCALAPPDATA\Microsoft\WinGet\Links\ninja.exe", "$env:LOCALAPPDATA\Programs\Ninja-build\Ninja\ninja.exe")
    $python = Find-BuildTool 'python.exe' @("$env:LOCALAPPDATA\Programs\Python\Python312\python.exe", "$env:ProgramFiles\Python312\python.exe")
    $compilerBin = Join-Path $toolchainRoot 'llvm-mingw\bin'
    if (-not $cmake -or -not $ninja -or -not $python -or -not (Test-Path -LiteralPath (Join-Path $compilerBin 'x86_64-w64-mingw32-clang++.exe') -PathType Leaf)) {
        throw 'The pinned CMake, Ninja, Python, or llvm-mingw compiler could not be located after bootstrap.'
    }
    $env:PATH = (@((Split-Path -Parent $python), (Split-Path -Parent $cmake), (Split-Path -Parent $ninja), $compilerBin, "$env:SystemRoot\System32") + @($env:PATH -split ';' | Where-Object { $_ })) -join ';'
    try {
        $memoryGb = [math]::Floor((Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop).TotalPhysicalMemory / 1GB)
    } catch {
        $memoryGb = 8
    }
    $env:U_UNLOCKED_BUILD_JOBS = if ($memoryGb -ge 32) { '4' } elseif ($memoryGb -ge 12) { '2' } else { '1' }

    & $verifyScript
    if ($LASTEXITCODE -ne 0) { throw "Source/toolchain verification failed with exit code $LASTEXITCODE." }

    & $buildEntry -Rpx $update.Rpx -BaseRpx $game.Rpx
    if ($LASTEXITCODE -ne 0) { throw "The native Vulkan build failed with exit code $LASTEXITCODE." }

    $playDirectory = Join-Path $repoRoot 'Play'
    $requiredOutputs = @(
        'U Unlocked.exe',
        'smash.exe',
        'smash-compat.exe',
        'smash-base.exe',
        'smash-base-compat.exe',
        'wua_extract.exe',
        'title-logo.png'
    )
    $missing = @($requiredOutputs | Where-Object {
        -not (Test-Path -LiteralPath (Join-Path $playDirectory $_) -PathType Leaf)
    })
    if ($missing.Count -gt 0) {
        throw "Build returned without all required files. Missing: $($missing -join ', ')."
    }

    if (-not [string]::IsNullOrWhiteSpace($LauncherDirectory)) {
        $launcherRoot = [System.IO.Path]::GetFullPath($LauncherDirectory)
        if (-not (Test-Path -LiteralPath $launcherRoot -PathType Container)) {
            throw "Launcher directory does not exist: $launcherRoot"
        }
        $runtimeStage = Join-Path $launcherRoot '.runtime-staging'
        $runtimeTarget = Join-Path $launcherRoot 'runtime'
        $runtimeBackup = Join-Path $launcherRoot '.runtime-previous'
        foreach ($temporaryPath in @($runtimeStage, $runtimeBackup)) {
            if (Test-Path -LiteralPath $temporaryPath) { Remove-Item -LiteralPath $temporaryPath -Recurse -Force }
        }
        New-Item -ItemType Directory -Force -Path $runtimeStage | Out-Null
        foreach ($file in Get-ChildItem -LiteralPath $playDirectory -File) {
            if ($file.Name -eq 'U Unlocked.exe') { continue }
            Copy-Item -LiteralPath $file.FullName -Destination $runtimeStage -Force
        }

        # Rebuilding the runtime must never discard saves, online credentials,
        # user fonts, logs, or display settings from the previous installation.
        foreach ($name in @('save', 'online', 'fonts', 'logs', 'cache')) {
            $stagedData = Join-Path $runtimeStage $name
            Copy-PreservedDirectory -Source (Join-Path $runtimeTarget $name) -Destination $stagedData
            if (-not (Test-Path -LiteralPath $stagedData -PathType Container)) {
                Copy-PreservedDirectory -Source (Join-Path $launcherRoot $name) -Destination $stagedData
            }
        }
        $previousDisplay = Join-Path $runtimeTarget 'display.ini'
        if (Test-Path -LiteralPath $previousDisplay -PathType Leaf) {
            Copy-Item -LiteralPath $previousDisplay -Destination $runtimeStage -Force
        } else {
            $launcherDisplay = Join-Path $launcherRoot 'display.ini'
            if (Test-Path -LiteralPath $launcherDisplay -PathType Leaf) {
                Copy-Item -LiteralPath $launcherDisplay -Destination $runtimeStage -Force
            }
        }

        if (Test-Path -LiteralPath $runtimeTarget) {
            Move-Item -LiteralPath $runtimeTarget -Destination $runtimeBackup
        }
        try {
            Move-Item -LiteralPath $runtimeStage -Destination $runtimeTarget
        } catch {
            if (Test-Path -LiteralPath $runtimeBackup) {
                Move-Item -LiteralPath $runtimeBackup -Destination $runtimeTarget
            }
            throw
        }
        if (Test-Path -LiteralPath $runtimeBackup) { Remove-Item -LiteralPath $runtimeBackup -Recurse -Force }
        Write-Host "Local game runtime activated: $runtimeTarget" -ForegroundColor Green
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
