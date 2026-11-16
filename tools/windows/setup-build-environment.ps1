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
$toolchainRoot = Join-Path $repoRoot 'toolchain'
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

if ($UseSystemTools) {
    $cmake = Find-Executable 'cmake.exe'
    $ninja = Find-Executable 'ninja.exe'
    $python = Find-Executable 'python.exe'
    if (-not $cmake -or -not $ninja -or -not $python) {
        throw 'The CI runner must provide CMake, Ninja, and Python when -UseSystemTools is selected.'
    }
    $cmakeVersionLine = (& $cmake --version | Select-Object -First 1)
    $cmakeMatch = [regex]::Match($cmakeVersionLine, '(\d+\.\d+\.\d+)')
    if (-not $cmakeMatch.Success -or [version]$cmakeMatch.Groups[1].Value -lt [version]'3.20.0') {
        throw "CMake 3.20 or newer is required; found '$cmakeVersionLine'."
    }
    $ninjaVersion = (& $ninja --version | Out-String).Trim()
    if ([version]$ninjaVersion -lt [version]'1.10.0') {
        throw "Ninja 1.10 or newer is required; found '$ninjaVersion'."
    }
    $pythonVersion = (& $python --version 2>&1 | Out-String).Trim()
    $pythonMatch = [regex]::Match($pythonVersion, 'Python (\d+\.\d+)')
    if (-not $pythonMatch.Success -or [version]$pythonMatch.Groups[1].Value -lt [version]'3.9') {
        throw "Python 3.9 or newer is required; found '$pythonVersion'."
    }
} else {
    $cmake = Find-Executable 'cmake.exe'
    $cmakeVersionLine = if ($cmake) { (& $cmake --version | Select-Object -First 1) } else { '' }
    if ($cmakeVersionLine -notmatch '3\.31\.6') {
        Invoke-WingetInstall -Id 'Kitware.CMake' -Version '3.31.6'
        $cmake = Find-Executable 'cmake.exe' @("$env:ProgramFiles\CMake\bin\cmake.exe", "$env:LOCALAPPDATA\Programs\CMake\bin\cmake.exe")
    }
    if (-not $cmake) { throw 'CMake 3.31.6 was installed but cmake.exe could not be located.' }

    $ninja = Find-Executable 'ninja.exe' @("$env:LOCALAPPDATA\Microsoft\WinGet\Links\ninja.exe", "$env:LOCALAPPDATA\Programs\Ninja-build\Ninja\ninja.exe")
    $ninjaVersionLine = if ($ninja) { (& $ninja --version | Out-String).Trim() } else { '' }
    if ($ninjaVersionLine -ne '1.12.1') {
        Invoke-WingetInstall -Id 'Ninja-build.Ninja' -Version '1.12.1'
        $ninja = Find-Executable 'ninja.exe' @("$env:LOCALAPPDATA\Microsoft\WinGet\Links\ninja.exe", "$env:LOCALAPPDATA\Programs\Ninja-build\Ninja\ninja.exe")
    }
    if (-not $ninja) { throw 'Ninja 1.12.1 was installed but ninja.exe could not be located.' }

    $python = Find-Executable 'python.exe'
    $pythonVersion = if ($python) { (& $python --version 2>&1 | Out-String).Trim() } else { '' }
    if ($pythonVersion -notmatch '^Python 3\.12\.') {
        Invoke-WingetInstall -Id 'Python.Python.3.12' -Version '3.12.10'
        $python = Find-Executable 'python.exe' @("$env:LOCALAPPDATA\Programs\Python\Python312\python.exe", "$env:ProgramFiles\Python312\python.exe")
    }
    if (-not $python) { throw 'Python 3.12.10 was installed but python.exe could not be located.' }
    $pythonVersion = (& $python --version 2>&1 | Out-String).Trim()
    if ($pythonVersion -notmatch '^Python 3\.12\.') { throw "Expected Python 3.12; found '$pythonVersion'." }
}

$llvmVersion = '20260616'
$llvmArchiveName = "llvm-mingw-$llvmVersion-ucrt-x86_64.zip"
$llvmArchive = Join-Path $downloads $llvmArchiveName
$llvmSha256 = 'b9b68a4d276e16fa25802aaba458e4638f64b3884c290aaccdc2d87083b6ca35'
$llvmDestination = Join-Path $toolchainRoot 'llvm-mingw'
$compiler = Join-Path $llvmDestination 'bin\x86_64-w64-mingw32-clang++.exe'

if (-not (Test-Path -LiteralPath $compiler -PathType Leaf)) {
    $llvmUrl = "https://github.com/mstorsjo/llvm-mingw/releases/download/$llvmVersion/$llvmArchiveName"
    if (-not (Test-Path -LiteralPath $llvmArchive -PathType Leaf)) {
        Write-Host "Downloading $llvmArchiveName (approximately 180 MB)..." -ForegroundColor Cyan
        Invoke-WebRequest -Uri $llvmUrl -OutFile $llvmArchive
    }
    $actualHash = (Get-FileHash -LiteralPath $llvmArchive -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($actualHash -ne $llvmSha256) {
        Remove-Item -LiteralPath $llvmArchive -Force
        throw "llvm-mingw SHA-256 mismatch. Expected $llvmSha256; got $actualHash."
    }
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

$cmakeVersion = (& $cmake --version | Select-Object -First 1)
$ninjaVersion = (& $ninja --version | Out-String).Trim()
if (-not $UseSystemTools -and ($cmakeVersion -notmatch '3\.31\.6' -or $ninjaVersion -ne '1.12.1')) {
    throw "Unexpected build tool versions: $cmakeVersion; Ninja $ninjaVersion. Expected CMake 3.31.6 and Ninja 1.12.1."
}
Write-Host "Build tools ready: $cmakeVersion; Ninja $ninjaVersion; $pythonVersion; llvm-mingw $llvmVersion." -ForegroundColor Green
$memoryGb = [math]::Floor((Get-CimInstance -ClassName Win32_ComputerSystem).TotalPhysicalMemory / 1GB)
$buildJobs = if ($memoryGb -ge 32) { 4 } elseif ($memoryGb -ge 12) { 2 } else { 1 }
$env:U_UNLOCKED_BUILD_JOBS = [string]$buildJobs
Write-Host "Build parallelism: $buildJobs job(s) for $memoryGb GiB RAM." -ForegroundColor Green

$env:PATH = (@((Split-Path -Parent $python), (Split-Path -Parent $cmake), (Split-Path -Parent $ninja),
    (Join-Path $toolchainRoot 'llvm-mingw\bin'), "$env:SystemRoot\System32")) + @($env:PATH -split ';' | Where-Object { $_ })) -join ';'
& $python (Join-Path $repoRoot 'engine\tools\setup_deps.py') --help | Out-Null
if ($LASTEXITCODE -ne 0) { throw 'Python cannot execute the dependency bootstrap script.' }
