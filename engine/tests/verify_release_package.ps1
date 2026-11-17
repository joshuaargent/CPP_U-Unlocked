# Verify the complete Windows launcher package and the player-side prebuilt asset install.
[CmdletBinding()]
param(
    [string]$RepositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem

$mainPath = Join-Path $RepositoryRoot 'engine\launcher\smash\main.cpp'
$main = Get-Content -LiteralPath $mainPath -Raw
$versionMatch = [regex]::Match($main, 'kVersion\s*=\s*"([^"]+)"')
if (-not $versionMatch.Success) { throw 'Unable to resolve the launcher version.' }
$version = $versionMatch.Groups[1].Value
$packagePath = Join-Path $RepositoryRoot "dist\U-Unlocked-v$version-Windows-Launcher.zip"
$checksumPath = "$packagePath.sha256"
if (-not (Test-Path -LiteralPath $packagePath -PathType Leaf) -or
    -not (Test-Path -LiteralPath $checksumPath -PathType Leaf)) {
    throw 'The complete release ZIP or checksum sidecar is missing.'
}
$expectedPackageHash = ((Get-Content -LiteralPath $checksumPath -Raw).Trim() -split '\s+')[0]
$actualPackageHash = (Get-FileHash -LiteralPath $packagePath -Algorithm SHA256).Hash.ToLowerInvariant()
if ($expectedPackageHash -ne $actualPackageHash) { throw 'The release package checksum does not match.' }

$temporary = Join-Path ([IO.Path]::GetTempPath()) ('u-unlocked-release-package-test-' + [guid]::NewGuid().ToString('N'))
$buildKitPath = Join-Path $temporary 'build-kit.zip'
$buildKitDirectory = Join-Path $temporary 'build-kit'
$testEngine = Join-Path $temporary 'engine'
$archive = $null
$buildKitArchive = $null

try {
    New-Item -ItemType Directory -Force -Path $temporary | Out-Null
    $archive = [IO.Compression.ZipFile]::OpenRead($packagePath)
    if ($archive.Entries.Count -gt 20000) { throw 'Release package contains too many entries.' }
    $entries = [Collections.Generic.Dictionary[string,System.IO.Compression.ZipArchiveEntry]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($entry in $archive.Entries) {
        $name = $entry.FullName.Replace([char]92, [char]47)
        $parts = $name.Split([char]47)
        if ([string]::IsNullOrWhiteSpace($name) -or $name.StartsWith('/') -or $name.Contains(':') -or
            ($parts -contains '..') -or ($parts -contains '.')) {
            throw "Unsafe path in release package: $name"
        }
        if ($entries.ContainsKey($name)) { throw "Duplicate path in release package: $name" }
        $entries.Add($name, $entry)
    }

    foreach ($required in @('package-manifest.json', 'U Unlocked.exe', 'wua_extract.exe',
        'title-logo.png', 'update-launcher.ps1', 'build-kit.zip', 'RUNTIME-BUILD-REQUIRED.txt')) {
        if (-not $entries.ContainsKey($required)) { throw "Release package is missing $required." }
    }

    $manifestStream = $entries['package-manifest.json'].Open()
    try {
        $reader = [IO.StreamReader]::new($manifestStream)
        try { $manifest = $reader.ReadToEnd() | ConvertFrom-Json } finally { $reader.Dispose() }
    } finally { $manifestStream.Dispose() }
    if ($manifest.schema_version -ne 1 -or [string]$manifest.version -ne $version -or
        -not ($manifest.files -is [array])) {
        throw 'Release package manifest schema, version, or file list is invalid.'
    }

    $listedFiles = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($file in $manifest.files) {
        $name = [string]$file.name
        $hash = [string]$file.sha256
        if ([string]::IsNullOrWhiteSpace($name) -or $name.Contains('/') -or $name.Contains('\') -or
            $hash.Length -ne 64 -or $hash -match '[^0-9a-fA-F]' -or -not $listedFiles.Add($name) -or
            -not $entries.ContainsKey($name)) {
            throw "Release manifest contains an invalid or missing asset: $name"
        }
        $stream = $entries[$name].Open()
        $sha = [Security.Cryptography.SHA256]::Create()
        try { $actualHash = [BitConverter]::ToString($sha.ComputeHash($stream)).Replace('-', '').ToLowerInvariant() }
        finally { $sha.Dispose(); $stream.Dispose() }
        if ($actualHash -ne $hash.ToLowerInvariant()) { throw "Release manifest SHA-256 mismatch: $name" }
    }
    if (-not $listedFiles.Contains('build-kit.zip')) { throw 'The release manifest does not authenticate build-kit.zip.' }

    $rootRuntimeDirectory = Join-Path $temporary 'root-runtime'
    New-Item -ItemType Directory -Force -Path $rootRuntimeDirectory | Out-Null
    foreach ($file in $manifest.files) {
        $name = [string]$file.name
        if ($name -eq 'wua_extract.exe' -or [IO.Path]::GetExtension($name) -ieq '.dll') {
            $entry = $entries[$name]
            $destination = Join-Path $rootRuntimeDirectory $name
            $input = $entry.Open()
            $output = [IO.File]::Open($destination, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
            try { $input.CopyTo($output); $output.Flush($true) } finally { $output.Dispose(); $input.Dispose() }
        }
    }

    $input = $entries['build-kit.zip'].Open()
    $output = [IO.File]::Open($buildKitPath, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
    try { $input.CopyTo($output); $output.Flush($true) } finally { $output.Dispose(); $input.Dispose() }
    $archive.Dispose()
    $archive = $null

    # Starting the packaged WUA extractor with no arguments should reach its
    # usage path. Missing dependent DLLs fail before the process can start.
    $wuaExecutable = Join-Path $rootRuntimeDirectory 'wua_extract.exe'
    $wuaProcess = Start-Process -FilePath $wuaExecutable -WorkingDirectory $rootRuntimeDirectory -PassThru -Wait -NoNewWindow
    if (-not $wuaProcess -or $wuaProcess.Id -le 0) { throw 'The packaged WUA extractor could not be started with its release DLL set.' }

    $buildKitArchive = [IO.Compression.ZipFile]::OpenRead($buildKitPath)
    if ($buildKitArchive.Entries.Count -gt 20000) { throw 'Embedded build kit contains too many entries.' }
    $buildKitEntries = [Collections.Generic.Dictionary[string,System.IO.Compression.ZipArchiveEntry]]::new([StringComparer]::OrdinalIgnoreCase)
    [int64]$expanded = 0
    foreach ($entry in $buildKitArchive.Entries) {
        $name = $entry.FullName.Replace([char]92, [char]47)
        $parts = $name.Split([char]47)
        if ([string]::IsNullOrWhiteSpace($name) -or $name.StartsWith('/') -or $name.Contains(':') -or
            ($parts -contains '..') -or ($parts -contains '.')) {
            throw "Unsafe path in embedded build kit: $name"
        }
        if ($buildKitEntries.ContainsKey($name)) { throw "Duplicate path in embedded build kit: $name" }
        $buildKitEntries.Add($name, $entry)
        $expanded += [int64]$entry.Length
        if ($expanded -gt 2GB) { throw 'Embedded build kit expands beyond the 2 GiB test limit.' }
    }

    foreach ($required in @('build-kit-manifest.json', 'prebuilt-dependencies.zip', 'cafe-recomp.exe',
        'dependency-bundle.zip', 'tools/windows/build-from-library.ps1', 'tools/windows/toolchain-path.ps1',
        'tools/windows/install-prebuilt-dependencies.ps1', 'engine/dependencies.lock.json',
        'engine/tools/windows/build-deps.ps1')) {
        if (-not $buildKitEntries.ContainsKey($required)) { throw "Embedded build kit is missing $required." }
    }

    $innerManifestStream = $buildKitEntries['build-kit-manifest.json'].Open()
    try {
        $reader = [IO.StreamReader]::new($innerManifestStream)
        try { $innerManifest = $reader.ReadToEnd() | ConvertFrom-Json } finally { $reader.Dispose() }
    } finally { $innerManifestStream.Dispose() }
    if ($innerManifest.schema_version -ne 1 -or [string]$innerManifest.version -ne $version -or
        -not ($innerManifest.files -is [array])) {
        throw 'Embedded build-kit manifest schema, version, or file list is invalid.'
    }

    $innerListedFiles = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($asset in $innerManifest.files) {
        $name = [string]$asset.name
        $hash = [string]$asset.sha256
        if ($hash.Length -ne 64 -or $hash -match '[^0-9a-fA-F]' -or
            -not $innerListedFiles.Add($name)) {
            throw "Embedded build-kit manifest contains an invalid or duplicate asset: $name"
        }
        if ($name -eq 'U Unlocked.exe' -or $name -eq 'wua_extract.exe') { continue }
        if (-not $buildKitEntries.ContainsKey($name)) {
            throw "Embedded build-kit archive is missing authenticated asset: $name"
        }
        $stream = $buildKitEntries[$name].Open()
        $sha = [Security.Cryptography.SHA256]::Create()
        try { $actualHash = [BitConverter]::ToString($sha.ComputeHash($stream)).Replace('-', '').ToLowerInvariant() }
        finally { $sha.Dispose(); $stream.Dispose() }
        if ($actualHash -ne $hash.ToLowerInvariant()) { throw "Embedded build-kit asset SHA-256 mismatch: $name" }
    }
    foreach ($requiredAsset in @('prebuilt-dependencies.zip', 'cafe-recomp.exe', 'dependency-bundle.zip',
        'U Unlocked.exe', 'wua_extract.exe')) {
        if (-not $innerListedFiles.Contains($requiredAsset)) {
            throw "Embedded build-kit manifest does not authenticate $requiredAsset."
        }
    }

    $buildKitArchive.Dispose()
    $buildKitArchive = $null

    # The first-install launcher uses the expanded build-kit folder, while the
    # updater extracts build-kit.zip. Verify both layouts contain identical assets.
    $directArchive = [IO.Compression.ZipFile]::OpenRead($packagePath)
    try {
        foreach ($required in @('build-kit/build-kit-manifest.json', 'build-kit/prebuilt-dependencies.zip',
            'build-kit/cafe-recomp.exe', 'build-kit/dependency-bundle.zip',
            'build-kit/tools/windows/build-from-library.ps1')) {
            if (-not $directArchive.GetEntry($required)) { throw "Expanded release build kit is missing $required." }
        }
        foreach ($asset in $innerManifest.files) {
            $name = [string]$asset.name
            $entryName = if ($name -eq 'U Unlocked.exe' -or $name -eq 'wua_extract.exe') { $name } else { "build-kit/$name" }
            $entry = $directArchive.GetEntry($entryName)
            if (-not $entry) { throw "Expanded release package is missing authenticated asset $entryName." }
            $stream = $entry.Open()
            $sha = [Security.Cryptography.SHA256]::Create()
            try { $hash = [BitConverter]::ToString($sha.ComputeHash($stream)).Replace('-', '').ToLowerInvariant() }
            finally { $sha.Dispose(); $stream.Dispose() }
            if ($hash -ne ([string]$asset.sha256).ToLowerInvariant()) {
                throw "Release asset does not match the build-kit manifest: $name"
            }
        }
    } finally { $directArchive.Dispose() }

    [IO.Compression.ZipFile]::ExtractToDirectory($buildKitPath, $buildKitDirectory)

    New-Item -ItemType Directory -Force -Path (Join-Path $testEngine 'tools\windows') | Out-Null
    New-Item -ItemType Directory -Force -Path (Join-Path $testEngine 'engine\tools\windows') | Out-Null
    Copy-Item -LiteralPath (Join-Path $buildKitDirectory 'engine\dependencies.lock.json') -Destination (Join-Path $testEngine 'engine\dependencies.lock.json')
    Copy-Item -LiteralPath (Join-Path $buildKitDirectory 'engine\tools\windows\build-deps.ps1') -Destination (Join-Path $testEngine 'engine\tools\windows\build-deps.ps1')
    $installer = Join-Path $buildKitDirectory 'tools\windows\install-prebuilt-dependencies.ps1'
    $prebuiltArchive = Join-Path $buildKitDirectory 'prebuilt-dependencies.zip'
    & $installer -ArchivePath $prebuiltArchive -EngineRoot (Join-Path $testEngine 'engine')
    $installedPrefix = Join-Path $testEngine 'engine\build-deps\prefix'
    foreach ($required in @(
        'lib\libvulkan-1.a', 'include\vulkan\vulkan.h',
        'include\SDL3\SDL.h', 'bin\SDL3.dll',
        'include\shaderc\shaderc.h', 'bin\libshaderc_shared.dll',
        'bin\libSPIRV-Tools-shared.dll', 'include\zlib.h', 'include\zstd.h'
    )) {
        if (-not (Test-Path -LiteralPath (Join-Path $installedPrefix $required) -PathType Leaf)) {
            throw "The packaged prebuilt dependency archive did not install $required."
        }
    }
    foreach ($pattern in @('*shaderc_shared*', '*SDL3*', '*zstd*')) {
        if (-not (Get-ChildItem -LiteralPath (Join-Path $installedPrefix 'lib') -File | Where-Object { $_.Name -like $pattern })) {
            throw "The packaged prebuilt dependency archive is missing link library $pattern."
        }
    }
    if (-not (Test-Path -LiteralPath (Join-Path $installedPrefix 'lib\libz.a') -PathType Leaf) -and
        -not (Test-Path -LiteralPath (Join-Path $installedPrefix 'lib\libz.dll.a') -PathType Leaf)) {
        throw 'The packaged prebuilt dependency archive is missing the zlib link library.'
    }

    Write-Host "Complete release package, embedded build kit, and player dependency installation verified: $packagePath" -ForegroundColor Green
} finally {
    if ($archive) { $archive.Dispose() }
    if ($buildKitArchive) { $buildKitArchive.Dispose() }
    if (Test-Path -LiteralPath $temporary -PathType Container) {
        Remove-Item -LiteralPath $temporary -Recurse -Force
    }
}
