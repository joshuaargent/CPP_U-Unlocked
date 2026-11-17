# Package game-data-free cafe_runtime object files from the exact release build.
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$EngineRoot,
    [Parameter(Mandatory = $true)][string]$OutputArchive
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem

$EngineRoot = [IO.Path]::GetFullPath($EngineRoot)
$repoRoot = Split-Path -Parent $EngineRoot
$objectsRoot = Join-Path $EngineRoot 'build\runtime\CMakeFiles\cafe_runtime.dir'
. (Join-Path $repoRoot 'tools\windows\toolchain-path.ps1')
$toolchainRoot = Get-UUnlockedToolchainRoot
$compiler = Join-Path $toolchainRoot 'llvm-mingw\bin\x86_64-w64-mingw32-clang++.exe'
if (-not (Test-Path -LiteralPath $objectsRoot -PathType Container)) {
    throw "The compiled generic runtime object directory is missing: $objectsRoot"
}
$objects = @(Get-ChildItem -LiteralPath $objectsRoot -Filter '*.obj' -File -Recurse | Sort-Object FullName)
$librarySources = [ordered]@{
    'libamd_addrlib.a' = Join-Path $EngineRoot 'build\libamd_addrlib.a'
    'libcemu_nex.a' = Join-Path $EngineRoot 'build\libcemu_nex.a'
    'libcafe_rpx.a' = Join-Path $EngineRoot 'build\recomp\libcafe_rpx.a'
    'libcafe_title.a' = Join-Path $EngineRoot 'build\runtime\libcafe_title.a'
    'libcafe_latte.a' = Join-Path $EngineRoot 'build\runtime\libcafe_latte.a'
    'libzarchive.a' = Join-Path $EngineRoot 'build\third_party\ZArchive\libzarchive.a'
}
foreach ($library in $librarySources.GetEnumerator()) {
    if (-not (Test-Path -LiteralPath $library.Value -PathType Leaf)) {
        throw "A required generic runtime static library is missing: $($library.Value)"
    }
}
if ($objects.Count -lt 40 -or $objects.Count -gt 200) {
    throw "The generic runtime object count is outside the expected range: $($objects.Count)"
}
$git = Get-Command git.exe -ErrorAction Stop
$revision = (& $git.Source -C $repoRoot rev-parse HEAD).Trim()
if ($LASTEXITCODE -ne 0 -or $revision -notmatch '^[0-9a-fA-F]{40}$') {
    throw 'Unable to resolve the exact source revision for the prebuilt runtime.'
}
if (-not (Test-Path -LiteralPath $compiler -PathType Leaf)) {
    throw 'The pinned compiler executable is missing while packaging the generic runtime.'
}

$outputArchive = [IO.Path]::GetFullPath($OutputArchive)
$outputDirectory = Split-Path -Parent $outputArchive
New-Item -ItemType Directory -Force -Path $outputDirectory | Out-Null
$stage = Join-Path $outputDirectory ('.prebuilt-runtime-' + [guid]::NewGuid().ToString('N'))
$archive = $null
$completed = $false
try {
    $stageObjects = Join-Path $stage 'objects'
    New-Item -ItemType Directory -Force -Path $stageObjects | Out-Null
    $stageLibraries = Join-Path $stage 'libraries'
    New-Item -ItemType Directory -Force -Path $stageObjects, $stageLibraries | Out-Null
    $records = @(
        foreach ($object in $objects) {
            $relative = $object.FullName.Substring($objectsRoot.Length + 1).Replace('\', '/')
            if ([string]::IsNullOrWhiteSpace($relative) -or $relative.Contains('..') -or
                [IO.Path]::IsPathRooted($relative)) {
                throw "Unsafe prebuilt runtime object path: $relative"
            }
            $destination = Join-Path $stageObjects ($relative.Replace('/', '\'))
            $destinationDirectory = Split-Path -Parent $destination
            New-Item -ItemType Directory -Force -Path $destinationDirectory | Out-Null
            Copy-Item -LiteralPath $object.FullName -Destination $destination
            [ordered]@{
                path = 'objects/' + $relative
                sha256 = (Get-FileHash -LiteralPath $destination -Algorithm SHA256).Hash.ToLowerInvariant()
                length = (Get-Item -LiteralPath $destination).Length
            }
        }
    )
    $libraryRecords = @(
        foreach ($library in $librarySources.GetEnumerator()) {
            $destination = Join-Path $stageLibraries $library.Key
            Copy-Item -LiteralPath $library.Value -Destination $destination
            [ordered]@{
                path = 'libraries/' + $library.Key
                sha256 = (Get-FileHash -LiteralPath $destination -Algorithm SHA256).Hash.ToLowerInvariant()
                length = (Get-Item -LiteralPath $destination).Length
            }
        }
    )
    $manifest = [ordered]@{
        schema_version = 1
        architecture = 'x86_64-windows'
        source_revision = $revision.ToLowerInvariant()
        compiler_sha256 = (Get-FileHash -LiteralPath $compiler -Algorithm SHA256).Hash.ToLowerInvariant()
        build_configuration = 'Release; generic x86-64 baseline; no game-derived sources'
        object_count = $records.Count
        objects = $records
        library_count = $libraryRecords.Count
        libraries = $libraryRecords
    }
    $manifest | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $stage 'runtime-manifest.json') -Encoding UTF8

    Remove-Item -LiteralPath $outputArchive -Force -ErrorAction SilentlyContinue
    $archive = [IO.Compression.ZipFile]::Open($outputArchive, [IO.Compression.ZipArchiveMode]::Create)
    $files = @(Get-ChildItem -LiteralPath $stage -File -Recurse | Sort-Object FullName)
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
        throw 'The prebuilt runtime archive was not created.'
    }
    $completed = $true
    Write-Host "Created generic runtime object archive with $($records.Count) objects: $outputArchive" -ForegroundColor Green
} finally {
    if ($archive) { $archive.Dispose() }
    if (Test-Path -LiteralPath $stage -PathType Container) {
        Remove-Item -LiteralPath $stage -Recurse -Force
    }
    if (-not $completed -and (Test-Path -LiteralPath $outputArchive -PathType Leaf)) {
        Remove-Item -LiteralPath $outputArchive -Force
    }
}