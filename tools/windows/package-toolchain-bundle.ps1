# Package the exact Windows compiler and portable build tools used by CI.
# Upstream distribution trees are copied intact so their licence files remain included.
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$OutputArchive
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem

. (Join-Path $PSScriptRoot 'toolchain-path.ps1')
$toolchainRoot = Get-UUnlockedToolchainRoot
$llvmRoot = Join-Path $toolchainRoot 'llvm-mingw'
$compiler = Join-Path $llvmRoot 'bin\x86_64-w64-mingw32-clang++.exe'
if (-not (Test-Path -LiteralPath $compiler -PathType Leaf)) {
    throw "The pinned llvm-mingw compiler is missing: $compiler"
}

function Resolve-CommandPath {
    param([Parameter(Mandatory = $true)][string]$Name)
    $command = Get-Command $Name -ErrorAction Stop
    if ([string]::IsNullOrWhiteSpace($command.Source) -or
        -not (Test-Path -LiteralPath $command.Source -PathType Leaf)) {
        throw "Unable to resolve an installed executable for $Name."
    }
    return [IO.Path]::GetFullPath($command.Source)
}

$cmakeExe = Resolve-CommandPath 'cmake.exe'
$ninjaExe = Join-Path $toolchainRoot 'ninja\\ninja.exe'
if (-not (Test-Path -LiteralPath $ninjaExe -PathType Leaf)) {
    throw "The pinned standalone Ninja executable is missing: $ninjaExe"
}
$pythonExe = Resolve-CommandPath 'python.exe'
$cmakeRoot = Split-Path -Parent (Split-Path -Parent $cmakeExe)
$pythonRoot = Split-Path -Parent $pythonExe
$cmakeRelative = [IO.Path]::GetRelativePath($cmakeRoot, $cmakeExe)
$pythonRelative = [IO.Path]::GetRelativePath($pythonRoot, $pythonExe)
if ($cmakeRelative -match '^\.\.' -or $pythonRelative -match '^\.\.') {
    throw 'CMake or Python resolved outside its expected portable distribution root.'
}

$outputArchive = [IO.Path]::GetFullPath($OutputArchive)
$outputDirectory = Split-Path -Parent $outputArchive
New-Item -ItemType Directory -Force -Path $outputDirectory | Out-Null
$stage = Join-Path $outputDirectory ('.toolchain-bundle-' + [guid]::NewGuid().ToString('N'))
$archive = $null
$completed = $false
try {
    $cmakeDestination = Join-Path $stage 'cmake'
    $pythonDestination = Join-Path $stage 'python'
    $llvmDestination = Join-Path $stage 'llvm-mingw'
    $ninjaDestination = Join-Path $stage 'ninja'
    New-Item -ItemType Directory -Force -Path $stage, $ninjaDestination | Out-Null

    Copy-Item -LiteralPath $llvmRoot -Destination $llvmDestination -Recurse -Force
    Copy-Item -LiteralPath $cmakeRoot -Destination $cmakeDestination -Recurse -Force
    Copy-Item -LiteralPath $pythonRoot -Destination $pythonDestination -Recurse -Force
    Copy-Item -LiteralPath $ninjaExe -Destination (Join-Path $ninjaDestination 'ninja.exe') -Force
    $repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    $ninjaLicense = Join-Path $repoRoot 'LICENSES\NINJA-APACHE-2.0.txt'
    if (-not (Test-Path -LiteralPath $ninjaLicense -PathType Leaf)) { throw 'The Ninja Apache 2.0 licence notice is missing.' }
    Copy-Item -LiteralPath $ninjaLicense -Destination (Join-Path $ninjaDestination 'LICENSE-APACHE-2.0.txt') -Force

    $stagedCmake = Join-Path $cmakeDestination $cmakeRelative
    $stagedPython = Join-Path $pythonDestination $pythonRelative
    $stagedNinja = Join-Path $ninjaDestination 'ninja.exe'
    $stagedCompiler = Join-Path $llvmDestination 'bin\x86_64-w64-mingw32-clang++.exe'
    foreach ($required in @($stagedCmake, $stagedPython, $stagedNinja, $stagedCompiler)) {
        if (-not (Test-Path -LiteralPath $required -PathType Leaf)) {
            throw "The staged toolchain is missing a required executable: $required"
        }
    }

    $cmakeVersion = (& $stagedCmake --version | Select-Object -First 1).Trim()
    if ($LASTEXITCODE -ne 0) { throw 'The staged CMake executable failed to run.' }
    $cmakeMatch = [regex]::Match($cmakeVersion, '([0-9]+\.[0-9]+\.[0-9]+)')
    $ninjaVersion = (& $stagedNinja --version | Out-String).Trim()
    if ($LASTEXITCODE -ne 0) { throw 'The staged Ninja executable failed to run.' }
    $pythonVersion = (& $stagedPython --version 2>&1 | Out-String).Trim()
    if ($LASTEXITCODE -ne 0) { throw 'The staged Python executable failed to run.' }
    if (-not $cmakeMatch.Success -or [version]$cmakeMatch.Groups[1].Value -lt [version]'3.20.0' -or
        $ninjaVersion -notmatch '^[0-9]+\.[0-9]+\.[0-9]+$' -or
        [version]$ninjaVersion -lt [version]'1.12.1' -or
        $pythonVersion -notmatch '^Python 3\.12\.') {
        throw "The staged build tools failed version validation: $cmakeVersion; Ninja $ninjaVersion; $pythonVersion."
    }

    $stagedFiles = @(Get-ChildItem -LiteralPath $stage -Force -File -Recurse | Sort-Object FullName)
    if ($stagedFiles.Count -lt 4 -or $stagedFiles.Count -gt 100000) {
        throw "The staged toolchain has an invalid file count: $($stagedFiles.Count)"
    }
    $fileRecords = @(
        foreach ($file in $stagedFiles) {
            $relative = $file.FullName.Substring($stage.Length + 1).Replace('\', '/')
            [ordered]@{
                path = $relative
                sha256 = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
                length = $file.Length
            }
        }
    )
    $manifest = [ordered]@{
        schema_version = 1
        architecture = 'x86_64-windows'
        llvm_mingw_version = '20260616'
        cmake_version = $cmakeMatch.Groups[1].Value
        ninja_version = $ninjaVersion
        python_version = $pythonVersion
        file_count = $fileRecords.Count
        files = $fileRecords
        executables = @(
            [ordered]@{ path = 'cmake/' + $cmakeRelative.Replace('\', '/'); sha256 = (Get-FileHash -LiteralPath $stagedCmake -Algorithm SHA256).Hash.ToLowerInvariant() },
            [ordered]@{ path = 'ninja/ninja.exe'; sha256 = (Get-FileHash -LiteralPath $stagedNinja -Algorithm SHA256).Hash.ToLowerInvariant() },
            [ordered]@{ path = 'python/' + $pythonRelative.Replace('\', '/'); sha256 = (Get-FileHash -LiteralPath $stagedPython -Algorithm SHA256).Hash.ToLowerInvariant() },
            [ordered]@{ path = 'llvm-mingw/bin/x86_64-w64-mingw32-clang++.exe'; sha256 = (Get-FileHash -LiteralPath $stagedCompiler -Algorithm SHA256).Hash.ToLowerInvariant() }
        )
    }
    $manifest | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $stage 'toolchain-manifest.json') -Encoding UTF8

    Remove-Item -LiteralPath $outputArchive -Force -ErrorAction SilentlyContinue
    $archive = [IO.Compression.ZipFile]::Open($outputArchive, [IO.Compression.ZipArchiveMode]::Create)
    $files = @(Get-ChildItem -LiteralPath $stage -Force -File -Recurse | Sort-Object FullName)
    if ($files.Count -lt 4 -or $files.Count -gt 100000) {
        throw "The staged toolchain has an invalid file count: $($files.Count)"
    }
    foreach ($file in $files) {
        $relative = $file.FullName.Substring($stage.Length + 1).Replace('\', '/')
        $entry = $archive.CreateEntry($relative, [IO.Compression.CompressionLevel]::Optimal)
        $input = [IO.File]::OpenRead($file.FullName)
        $output = $entry.Open()
        try { $input.CopyTo($output) } finally { $output.Dispose(); $input.Dispose() }
    }
    $archive.Dispose()
    $archive = $null
    if (-not (Test-Path -LiteralPath $outputArchive -PathType Leaf) -or
        (Get-Item -LiteralPath $outputArchive).Length -eq 0) {
        throw 'The toolchain bundle archive was not created.'
    }
    $completed = $true
    Write-Host "Created self-contained Windows toolchain bundle: $outputArchive" -ForegroundColor Green
} finally {
    if ($archive) { $archive.Dispose() }
    if (Test-Path -LiteralPath $stage -PathType Container) {
        Remove-Item -LiteralPath $stage -Recurse -Force
    }
    if (-not $completed -and (Test-Path -LiteralPath $outputArchive -PathType Leaf)) {
        Remove-Item -LiteralPath $outputArchive -Force
    }
}