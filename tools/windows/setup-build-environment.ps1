# Install the pinned Windows cross-toolchain and deterministic build utilities.
# This does not install or modify any game files.
[CmdletBinding()]
param([switch]$UseSystemTools)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

if ($env:OS -ne 'Windows_NT') {
    throw 'The U Unlocked local game build is currently supported on Windows only.'
}

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
. (Join-Path $PSScriptRoot 'toolchain-path.ps1')
$toolchainRoot = Get-UUnlockedToolchainRoot
$downloads = Join-Path $toolchainRoot 'downloads'
New-Item -ItemType Directory -Force -Path $downloads | Out-Null

function Invoke-WingetInstall {
    param(
        [Parameter(Mandatory = $true)][string]$Id,
        [Parameter(Mandatory = $true)][string]$Version
    )
    $winget = Get-Command winget.exe -ErrorAction SilentlyContinue
    if (-not $winget) {
        throw "Windows Package Manager (winget) is required to install $Id. Install or update App Installer from Microsoft, then retry."
    }
    Write-Host "Installing $Id $Version..." -ForegroundColor Cyan
    & $winget.Source install --id $Id --exact --version $Version --silent --accept-package-agreements --accept-source-agreements --disable-interactivity
    if ($LASTEXITCODE -ne 0) {
        throw "winget failed to install $Id $Version (exit code $LASTEXITCODE)."
    }
}

function Find-Executable {
    param([string]$Name, [string[]]$Candidates = @())
    foreach ($candidate in $Candidates) {
        if (Test-Path -LiteralPath $candidate -PathType Leaf) { return $candidate }
    }
    $command = Get-Command $Name -ErrorAction SilentlyContinue
    if ($command) { return $command.Source }
    return $null
}

# Capture all native output before inspecting it. Piping a native executable
# directly to Select-Object -First 1 can close its output pipe early in Windows
# PowerShell 5.1 and produce a misleading non-zero LASTEXITCODE.
function Get-CheckedExecutableFirstLine {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [string[]]$Arguments = @(),
        [Parameter(Mandatory = $true)][string]$Label
    )
    $output = @(& $Path @Arguments 2>&1)
    $exitCode = $LASTEXITCODE
    if ($exitCode -ne 0) {
        $details = ($output | ForEach-Object { [string]$_ }) -join [Environment]::NewLine
        throw "$Label failed with exit code $exitCode. $details"
    }
    foreach ($line in $output) {
        if ($null -ne $line) { return [string]$line }
    }
    return ''
}

function Install-BundledToolchain {
    param([Parameter(Mandatory = $true)][string]$ArchivePath)

    if (-not (Test-Path -LiteralPath $ArchivePath -PathType Leaf)) {
        throw "The release toolchain bundle is missing: $ArchivePath"
    }
    $installedManifestPath = Join-Path $toolchainRoot 'toolchain-manifest.json'
    $requiredDirectories = @('llvm-mingw', 'cmake', 'ninja', 'python')

    function Test-InstalledBundle {
        param([string]$ManifestPath)
        if (-not (Test-Path -LiteralPath $ManifestPath -PathType Leaf)) { return $false }
        try {
            $manifest = Get-Content -LiteralPath $ManifestPath -Raw | ConvertFrom-Json
            if ($manifest.schema_version -ne 1 -or $manifest.architecture -ne 'x86_64-windows' -or
                -not ($manifest.executables -is [array]) -or $manifest.executables.Count -ne 4 -or
                -not ($manifest.files -is [array]) -or $manifest.files.Count -lt 4 -or
                $manifest.files.Count -gt 100000 -or [int]$manifest.file_count -ne $manifest.files.Count) { return $false }
            foreach ($entry in $manifest.executables) {
                $relative = [string]$entry.path
                $hash = [string]$entry.sha256
                if ([string]::IsNullOrWhiteSpace($relative) -or [IO.Path]::IsPathRooted($relative) -or
                    $relative.Contains('..') -or $hash -notmatch '^[0-9a-fA-F]{64}$') { return $false }
                $file = Join-Path $toolchainRoot ($relative.Replace('/', '\'))
                if (-not (Test-Path -LiteralPath $file -PathType Leaf) -or
                    (Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash -ne $hash.ToUpperInvariant()) { return $false }
            }
            return $true
        } catch { return $false }
    }

    if (-not (Test-InstalledBundle -ManifestPath $installedManifestPath)) {
        $staging = Join-Path $toolchainRoot ('.bundle-staging-' + [guid]::NewGuid().ToString('N'))
        $backup = Join-Path $toolchainRoot ('.bundle-backup-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Force -Path $staging, $backup | Out-Null
        $installedDirectories = [Collections.Generic.List[string]]::new()
        $backedUpDirectories = [Collections.Generic.List[string]]::new()
        try {
            Expand-Archive -LiteralPath $ArchivePath -DestinationPath $staging -Force
            $manifestPath = Join-Path $staging 'toolchain-manifest.json'
            if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
                throw 'The bundled toolchain manifest is missing.'
            }
            $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
            if ($manifest.schema_version -ne 1 -or $manifest.architecture -ne 'x86_64-windows' -or
                -not ($manifest.executables -is [array]) -or $manifest.executables.Count -ne 4 -or
            -not ($manifest.files -is [array]) -or $manifest.files.Count -lt 4 -or
            $manifest.files.Count -gt 100000 -or [int]$manifest.file_count -ne $manifest.files.Count) {
                throw 'The bundled toolchain manifest has an unsupported schema or architecture.'
            }
            foreach ($directory in $requiredDirectories) {
                if (-not (Test-Path -LiteralPath (Join-Path $staging $directory) -PathType Container)) {
                    throw "The bundled toolchain is missing its $directory directory."
                }
            }
            foreach ($entry in $manifest.executables) {
                $relative = [string]$entry.path
                $hash = [string]$entry.sha256
                if ([string]::IsNullOrWhiteSpace($relative) -or [IO.Path]::IsPathRooted($relative) -or
                    $relative.Contains('..') -or $hash -notmatch '^[0-9a-fA-F]{64}$') {
                    throw 'The bundled toolchain manifest contains an unsafe path or invalid hash.'
                }
                $file = Join-Path $staging ($relative.Replace('/', '\'))
                if (-not (Test-Path -LiteralPath $file -PathType Leaf) -or
                    (Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash -ne $hash.ToUpperInvariant()) {
                    throw "The bundled toolchain executable failed integrity verification: $relative"
                }
            }
            foreach ($directory in $requiredDirectories) {
                $destination = Join-Path $toolchainRoot $directory
                if (Test-Path -LiteralPath $destination) {
                    Move-Item -LiteralPath $destination -Destination (Join-Path $backup $directory)
                    $backedUpDirectories.Add($directory)
                }
                Move-Item -LiteralPath (Join-Path $staging $directory) -Destination $destination
                $installedDirectories.Add($directory)
            }
            Copy-Item -LiteralPath $manifestPath -Destination $installedManifestPath -Force
            if (-not (Test-InstalledBundle -ManifestPath $installedManifestPath)) {
                throw 'The installed toolchain did not pass its post-install integrity check.'
            }
        } catch {
            foreach ($directory in @($installedDirectories.ToArray())) {
                $destination = Join-Path $toolchainRoot $directory
                if (Test-Path -LiteralPath $destination) {
                    Remove-Item -LiteralPath $destination -Recurse -Force
                }
            }
            foreach ($directory in @($backedUpDirectories.ToArray())) {
                $destination = Join-Path $toolchainRoot $directory
                $old = Join-Path $backup $directory
                if (Test-Path -LiteralPath $old) {
                    if (Test-Path -LiteralPath $destination) {
                        Remove-Item -LiteralPath $destination -Recurse -Force
                    }
                    Move-Item -LiteralPath $old -Destination $destination
                }
            }
            throw
        } finally {
            if (Test-Path -LiteralPath $staging) { Remove-Item -LiteralPath $staging -Recurse -Force }
            if (Test-Path -LiteralPath $backup) { Remove-Item -LiteralPath $backup -Recurse -Force }
        }
    }

    $manifest = Get-Content -LiteralPath $installedManifestPath -Raw | ConvertFrom-Json
    $cmakePath = [string]($manifest.executables | Where-Object { $_.path -like 'cmake/*' } | Select-Object -First 1).path
    $ninjaPath = [string]($manifest.executables | Where-Object { $_.path -like 'ninja/*' } | Select-Object -First 1).path
    $pythonPath = [string]($manifest.executables | Where-Object { $_.path -like 'python/*' } | Select-Object -First 1).path
    $compilerPath = [string]($manifest.executables | Where-Object { $_.path -like 'llvm-mingw/bin/*clang++.exe' } | Select-Object -First 1).path
    return [pscustomobject]@{
        CMake = Join-Path $toolchainRoot $cmakePath.Replace('/', '\')
        Ninja = Join-Path $toolchainRoot $ninjaPath.Replace('/', '\')
        Python = Join-Path $toolchainRoot $pythonPath.Replace('/', '\')
        Compiler = Join-Path $toolchainRoot $compilerPath.Replace('/', '\')
    }
}

$bundledToolchain = $null
if (-not $UseSystemTools -and -not [string]::IsNullOrWhiteSpace($env:U_UNLOCKED_TOOLCHAIN_BUNDLE)) {
    $bundledToolchain = Install-BundledToolchain -ArchivePath $env:U_UNLOCKED_TOOLCHAIN_BUNDLE
}

if ($UseSystemTools) {
    $cmake = Find-Executable 'cmake.exe'
    $ninja = Find-Executable 'ninja.exe'
    $python = Find-Executable 'python.exe'
    if (-not $cmake -or -not $ninja -or -not $python) {
        throw 'The CI runner must provide CMake, Ninja, and Python when -UseSystemTools is selected.'
    }

    $cmakeVersionLine = Get-CheckedExecutableFirstLine -Path $cmake -Arguments @('--version') -Label 'CMake'
    $cmakeMatch = [regex]::Match($cmakeVersionLine, '([0-9]+\.[0-9]+\.[0-9]+)')
    if (-not $cmakeMatch.Success -or [version]$cmakeMatch.Groups[1].Value -lt [version]'3.20.0') {
        throw "CMake 3.20 or newer is required; found '$cmakeVersionLine'."
    }
    $ninjaVersionLine = (& $ninja --version | Out-String).Trim()
    if ($ninjaVersionLine -notmatch '^[0-9]+\.[0-9]+\.[0-9]+$' -or [version]$ninjaVersionLine -lt [version]'1.12.1') {
        throw "Ninja 1.12.1 or newer is required; found '$ninjaVersionLine'."
    }
    $pythonVersion = (& $python --version 2>&1 | Out-String).Trim()
    $pythonMatch = [regex]::Match($pythonVersion, 'Python ([0-9]+\.[0-9]+)')
    if (-not $pythonMatch.Success -or [version]$pythonMatch.Groups[1].Value -lt [version]'3.9') {
        throw "Python 3.9 or newer is required; found '$pythonVersion'."
    }
} elseif ($bundledToolchain) {
    $cmake = $bundledToolchain.CMake
    $ninja = $bundledToolchain.Ninja
    $python = $bundledToolchain.Python
    $cmakeVersionLine = Get-CheckedExecutableFirstLine -Path $cmake -Arguments @('--version') -Label 'CMake'
    if ($LASTEXITCODE -ne 0) { throw 'The bundled CMake executable failed to run.' }
    $cmakeMatch = [regex]::Match($cmakeVersionLine, '([0-9]+\.[0-9]+\.[0-9]+)')
    if (-not $cmakeMatch.Success -or [version]$cmakeMatch.Groups[1].Value -lt [version]'3.20.0') {
        throw "The bundled CMake version is unsupported: $cmakeVersionLine"
    }
    $ninjaVersionLine = (& $ninja --version | Out-String).Trim()
    if ($LASTEXITCODE -ne 0 -or $ninjaVersionLine -notmatch '^[0-9]+\.[0-9]+\.[0-9]+$' -or
        [version]$ninjaVersionLine -lt [version]'1.12.1') {
        throw "The bundled Ninja version is unsupported: $ninjaVersionLine"
    }
    $pythonVersion = (& $python --version 2>&1 | Out-String).Trim()
    if ($LASTEXITCODE -ne 0 -or $pythonVersion -notmatch '^Python 3\.12\.') {
        throw "The bundled Python version is unsupported: $pythonVersion"
    }

} else {
    # Match the CI contract: any installed CMake >= 3.20 is supported. Do not
    # force an exact-version WinGet upgrade when a compatible CMake is already present.
    $cmakeCandidates = @(
        "$env:ProgramFiles\CMake\bin\cmake.exe",
        "$env:LOCALAPPDATA\Programs\CMake\bin\cmake.exe"
    )
    $cmake = Find-Executable 'cmake.exe' $cmakeCandidates
    $cmakeVersionLine = if ($cmake) { Get-CheckedExecutableFirstLine -Path $cmake -Arguments @('--version') -Label 'CMake' } else { '' }
    $cmakeMatch = [regex]::Match($cmakeVersionLine, '([0-9]+\.[0-9]+\.[0-9]+)')
    $cmakeVersionNumber = if ($cmakeMatch.Success) { [version]$cmakeMatch.Groups[1].Value } else { [version]'0.0.0' }
    if (-not $cmake -or $cmakeVersionNumber -lt [version]'3.20.0') {
        Invoke-WingetInstall -Id 'Kitware.CMake' -Version '3.31.6'
        $cmake = Find-Executable 'cmake.exe' $cmakeCandidates
        $cmakeVersionLine = if ($cmake) { Get-CheckedExecutableFirstLine -Path $cmake -Arguments @('--version') -Label 'CMake' } else { '' }
        $cmakeMatch = [regex]::Match($cmakeVersionLine, '([0-9]+\.[0-9]+\.[0-9]+)')
        $cmakeVersionNumber = if ($cmakeMatch.Success) { [version]$cmakeMatch.Groups[1].Value } else { [version]'0.0.0' }
    }
    if (-not $cmake -or $cmakeVersionNumber -lt [version]'3.20.0') {
        throw "CMake 3.20 or newer is required; found '$cmakeVersionLine'."
    }

    $ninja = Find-Executable 'ninja.exe' @("$env:LOCALAPPDATA\Microsoft\WinGet\Links\ninja.exe", "$env:LOCALAPPDATA\Programs\Ninja-build\Ninja\ninja.exe")
    $ninjaVersionLine = if ($ninja) { (& $ninja --version | Out-String).Trim() } else { '' }
    if ($ninjaVersionLine -notmatch '^[0-9]+\.[0-9]+\.[0-9]+$' -or [version]$ninjaVersionLine -lt [version]'1.12.1') {
        Invoke-WingetInstall -Id 'Ninja-build.Ninja' -Version '1.12.1'
        $ninja = Find-Executable 'ninja.exe' @("$env:LOCALAPPDATA\Microsoft\WinGet\Links\ninja.exe", "$env:LOCALAPPDATA\Programs\Ninja-build\Ninja\ninja.exe")
        $ninjaVersionLine = if ($ninja) { (& $ninja --version | Out-String).Trim() } else { '' }
    }
    if (-not $ninja -or $ninjaVersionLine -notmatch '^[0-9]+\.[0-9]+\.[0-9]+$' -or [version]$ninjaVersionLine -lt [version]'1.12.1') {
        throw "Ninja 1.12.1 or newer could not be installed; found '$ninjaVersionLine'."
    }

    # Ignore WindowsApps execution-alias stubs: they resolve through Get-Command
    # but are not an installed interpreter and terminate under ErrorActionPreference=Stop.
    function Get-UsablePython312 {
        $candidates = @(
            "$env:LOCALAPPDATA\Programs\Python\Python312\python.exe",
            "$env:ProgramFiles\Python312\python.exe",
            "$env:LOCALAPPDATA\Programs\Python\Python312-32\python.exe",
            'C:\Python312\python.exe'
        )
        foreach ($candidate in $candidates) {
            if (-not (Test-Path -LiteralPath $candidate -PathType Leaf)) { continue }
            try {
                $output = @(& $candidate --version 2>&1)
                if ($LASTEXITCODE -eq 0) {
                    $versionText = ($output | Out-String).Trim()
                    if ($versionText -match '^Python 3\.12\.') {
                        return [pscustomobject]@{ Path = $candidate; Version = $versionText }
                    }
                }
            } catch {
                # Continue searching; a stale/broken executable must not block installation.
            }
        }

        $command = Get-Command python.exe -ErrorAction SilentlyContinue
        if ($command -and $command.Source -and
            $command.Source -notmatch '[\\/]Microsoft[\\/]WindowsApps[\\/]') {
            try {
                $output = @(& $command.Source --version 2>&1)
                if ($LASTEXITCODE -eq 0) {
                    $versionText = ($output | Out-String).Trim()
                    if ($versionText -match '^Python 3\.12\.') {
                        return [pscustomobject]@{ Path = $command.Source; Version = $versionText }
                    }
                }
            } catch {
                # Treat launch failures exactly like a missing interpreter.
            }
        }
        return $null
    }

    $pythonInstall = Get-UsablePython312
    if (-not $pythonInstall) {
        Invoke-WingetInstall -Id 'Python.Python.3.12' -Version '3.12.10'
        $pythonInstall = Get-UsablePython312
    }
    if (-not $pythonInstall) {
        throw 'Python 3.12 could not be installed or executed. The WindowsApps Microsoft Store alias is not a valid Python interpreter.'
    }
    $python = $pythonInstall.Path
    $pythonVersion = $pythonInstall.Version
}

# llvm-mingw 20260616 is pinned by release tag and the SHA-256 published for this exact asset.
$llvmVersion = '20260616'
$llvmArchiveName = "llvm-mingw-$llvmVersion-ucrt-x86_64.zip"
$llvmArchive = Join-Path $downloads $llvmArchiveName
$llvmSha256 = 'b9b68a4d276e16fa25802aaba458e4638f64b3884c290aaccdc2d87083b6ca35'
$llvmDestination = Join-Path $toolchainRoot 'llvm-mingw'
$compiler = Join-Path $llvmDestination 'bin\x86_64-w64-mingw32-clang++.exe'

if (-not (Test-Path -LiteralPath $compiler -PathType Leaf)) {
    $llvmUrl = "https://github.com/mstorsjo/llvm-mingw/releases/download/$llvmVersion/$llvmArchiveName"
    $archiveVerified = $false
    if (Test-Path -LiteralPath $llvmArchive -PathType Leaf) {
        $existingHash = (Get-FileHash -LiteralPath $llvmArchive -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($existingHash -eq $llvmSha256) {
            $archiveVerified = $true
        } else {
            Remove-Item -LiteralPath $llvmArchive -Force
        }
    }

    if (-not $archiveVerified) {
        $attempts = 5
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        for ($attempt = 1; $attempt -le $attempts; $attempt++) {
            Remove-Item -LiteralPath $llvmArchive -Force -ErrorAction SilentlyContinue
            try {
                Write-Host "Downloading $llvmArchiveName (approximately 180 MB), attempt $attempt of $attempts..." -ForegroundColor Cyan
                Invoke-WebRequest -UseBasicParsing -Uri $llvmUrl -OutFile $llvmArchive -TimeoutSec 900
                if (-not (Test-Path -LiteralPath $llvmArchive -PathType Leaf)) {
                    throw 'The compiler download did not create an archive.'
                }
                $actualHash = (Get-FileHash -LiteralPath $llvmArchive -Algorithm SHA256).Hash.ToLowerInvariant()
                if ($actualHash -ne $llvmSha256) {
                    throw "llvm-mingw SHA-256 mismatch. Expected $llvmSha256; got $actualHash."
                }
                $archiveVerified = $true
                break
            } catch {
                $downloadError = $_
                Remove-Item -LiteralPath $llvmArchive -Force -ErrorAction SilentlyContinue
                $statusCode = 0
                try { $statusCode = [int]$downloadError.Exception.Response.StatusCode } catch {}
                if ($statusCode -ge 400 -and $statusCode -lt 500 -and $statusCode -notin @(408, 425, 429)) {
                    throw "The pinned compiler download was rejected with HTTP $statusCode. $($downloadError.Exception.Message)"
                }
                if ($attempt -eq $attempts) {
                    throw "Unable to download and verify the pinned compiler after $attempts attempts. $($downloadError.Exception.Message)"
                }
                $delay = [Math]::Min(20, 2 * $attempt)
                Write-Warning "Compiler download failed: $($downloadError.Exception.Message). Retrying in $delay seconds."
                Start-Sleep -Seconds $delay
            }
        }
    }
    if (-not $archiveVerified) { throw 'The pinned compiler archive could not be verified.' }

    $staging = Join-Path $toolchainRoot '.llvm-mingw-staging'
    if (Test-Path -LiteralPath $staging) { Remove-Item -LiteralPath $staging -Recurse -Force }
    New-Item -ItemType Directory -Force -Path $staging | Out-Null
    try {
        Expand-Archive -LiteralPath $llvmArchive -DestinationPath $staging -Force
        $candidate = Get-ChildItem -LiteralPath $staging -Directory -Recurse | Where-Object {
            Test-Path -LiteralPath (Join-Path $_.FullName 'bin\x86_64-w64-mingw32-clang++.exe')
        } | Select-Object -First 1
        if (-not $candidate) { throw 'The verified llvm-mingw archive did not contain the expected x86_64 compiler.' }
        if (Test-Path -LiteralPath $llvmDestination) { Remove-Item -LiteralPath $llvmDestination -Recurse -Force }
        Move-Item -LiteralPath $candidate.FullName -Destination $llvmDestination
    } finally {
        if (Test-Path -LiteralPath $staging) { Remove-Item -LiteralPath $staging -Recurse -Force }
    }
}
if (-not (Test-Path -LiteralPath $compiler -PathType Leaf)) { throw 'The llvm-mingw compiler is still missing after installation.' }

# Do not package a WinGet AppsFolder execution alias. Download Ninja's official
# standalone archive, verify its pinned SHA-256, and install the real binary.
# Player releases already contain this binary inside the verified toolchain bundle.
if (-not $bundledToolchain) {
    $ninjaArchiveName = 'ninja-win-1.12.1.zip'
    $ninjaArchive = Join-Path $downloads $ninjaArchiveName
    $ninjaArchiveSha256 = 'f550fec705b6d6ff58f2db3c374c2277a37691678d6aba463adcbb129108467a'
    $ninjaUrl = 'https://github.com/ninja-build/ninja/releases/download/v1.12.1/ninja-win.zip'
    $ninjaArchiveVerified = $false

    if (Test-Path -LiteralPath $ninjaArchive -PathType Leaf) {
        $existingNinjaHash = (Get-FileHash -LiteralPath $ninjaArchive -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($existingNinjaHash -eq $ninjaArchiveSha256) {
            $ninjaArchiveVerified = $true
        } else {
            Remove-Item -LiteralPath $ninjaArchive -Force
        }
    }

    if (-not $ninjaArchiveVerified) {
        $ninjaAttempts = 5
        for ($attempt = 1; $attempt -le $ninjaAttempts; $attempt++) {
            Remove-Item -LiteralPath $ninjaArchive -Force -ErrorAction SilentlyContinue
            try {
                Write-Host "Downloading pinned standalone Ninja 1.12.1, attempt $attempt of $ninjaAttempts..." -ForegroundColor Cyan
                Invoke-WebRequest -UseBasicParsing -Uri $ninjaUrl -OutFile $ninjaArchive -TimeoutSec 180
                if (-not (Test-Path -LiteralPath $ninjaArchive -PathType Leaf)) {
                    throw 'The Ninja download did not create an archive.'
                }
                $actualNinjaHash = (Get-FileHash -LiteralPath $ninjaArchive -Algorithm SHA256).Hash.ToLowerInvariant()
                if ($actualNinjaHash -ne $ninjaArchiveSha256) {
                    throw "Ninja archive SHA-256 mismatch. Expected $ninjaArchiveSha256; got $actualNinjaHash."
                }
                $ninjaArchiveVerified = $true
                break
            } catch {
                $downloadError = $_
                Remove-Item -LiteralPath $ninjaArchive -Force -ErrorAction SilentlyContinue
                if ($attempt -eq $ninjaAttempts) {
                    throw "Unable to download and verify standalone Ninja after $ninjaAttempts attempts. $($downloadError.Exception.Message)"
                }
                $delay = [Math]::Min(20, 2 * $attempt)
                Write-Warning "Ninja download failed: $($downloadError.Exception.Message). Retrying in $delay seconds."
                Start-Sleep -Seconds $delay
            }
        }
    }
    if (-not $ninjaArchiveVerified) { throw 'The pinned standalone Ninja archive could not be verified.' }

    $ninjaStage = Join-Path $toolchainRoot ('.ninja-staging-' + [guid]::NewGuid().ToString('N'))
    $ninjaDestination = Join-Path $toolchainRoot 'ninja'
    New-Item -ItemType Directory -Force -Path $ninjaStage | Out-Null
    try {
        Expand-Archive -LiteralPath $ninjaArchive -DestinationPath $ninjaStage -Force
        $stagedNinja = Join-Path $ninjaStage 'ninja.exe'
        if (-not (Test-Path -LiteralPath $stagedNinja -PathType Leaf)) {
            throw 'The official Ninja archive does not contain ninja.exe at its root.'
        }
        New-Item -ItemType Directory -Force -Path $ninjaDestination | Out-Null
        Copy-Item -LiteralPath $stagedNinja -Destination (Join-Path $ninjaDestination 'ninja.exe') -Force
    } finally {
        if (Test-Path -LiteralPath $ninjaStage -PathType Container) {
            Remove-Item -LiteralPath $ninjaStage -Recurse -Force
        }
    }
    $ninja = Join-Path $ninjaDestination 'ninja.exe'
    $ninjaVersionLine = (& $ninja --version | Out-String).Trim()
    if ($LASTEXITCODE -ne 0 -or $ninjaVersionLine -ne '1.12.1') {
        throw "The verified standalone Ninja binary failed its version check: '$ninjaVersionLine'."
    }
}

$cmakeVersion = Get-CheckedExecutableFirstLine -Path $cmake -Arguments @('--version') -Label 'CMake'
$ninjaVersion = (& $ninja --version | Out-String).Trim()
Write-Host "Build tools ready: $cmakeVersion; Ninja $ninjaVersion; $pythonVersion; llvm-mingw $llvmVersion." -ForegroundColor Green

try {
    $memoryGb = [math]::Floor((Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop).TotalPhysicalMemory / 1GB)
} catch {
    $memoryGb = 8
}
$buildJobs = if ($memoryGb -ge 32) { 4 } elseif ($memoryGb -ge 12) { 2 } else { 1 }
$env:U_UNLOCKED_BUILD_JOBS = [string]$buildJobs
Write-Host "Build parallelism: $buildJobs job(s) for $memoryGb GiB RAM." -ForegroundColor Green

$env:PATH = (@((Split-Path -Parent $python), (Split-Path -Parent $cmake), (Split-Path -Parent $ninja),
    (Join-Path $toolchainRoot 'llvm-mingw\bin'), "$env:SystemRoot\System32") + @($env:PATH -split ';' | Where-Object { $_ })) -join ';'
& $python (Join-Path $repoRoot 'engine\tools\setup_deps.py') --help | Out-Null
if ($LASTEXITCODE -ne 0) { throw 'Python cannot execute the dependency bootstrap script.' }
