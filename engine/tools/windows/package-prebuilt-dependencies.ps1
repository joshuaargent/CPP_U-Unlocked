# Create a relocatable, integrity-manifested archive of the compiled Windows dependency prefix.
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
$OutputArchive = [IO.Path]::GetFullPath($OutputArchive)
$prefix = Join-Path $EngineRoot 'build-deps\prefix'
$lockPath = Join-Path $EngineRoot 'dependencies.lock.json'
$recipePath = Join-Path $EngineRoot 'tools\windows\build-deps.ps1'
foreach ($required in @(
    (Join-Path $prefix 'lib\libvulkan-1.a'),
    (Join-Path $prefix 'include\vulkan\vulkan.h'),
    (Join-Path $prefix 'bin\SDL3.dll'),
    $lockPath,
    $recipePath
)) {
    if (-not (Test-Path -LiteralPath $required -PathType Leaf)) {
        throw "A required prebuilt dependency input is missing: $required"
    }
}

$outputDirectory = Split-Path -Parent $OutputArchive
New-Item -ItemType Directory -Force -Path $outputDirectory | Out-Null
$stage = Join-Path $outputDirectory ('.prebuilt-dependencies-' + [guid]::NewGuid().ToString('N'))
$archive = $null

try {
    $stagePrefix = Join-Path $stage 'prefix'
    New-Item -ItemType Directory -Force -Path $stagePrefix | Out-Null

    $allItems = @(Get-ChildItem -LiteralPath $prefix -Force -Recurse)
    foreach ($item in $allItems) {
        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "Refusing to package a reparse point in the dependency prefix: $($item.FullName)"
        }
    }

    $sourceFiles = @(Get-ChildItem -LiteralPath $prefix -File -Recurse -Force | Sort-Object FullName)
    if ($sourceFiles.Count -lt 3 -or $sourceFiles.Count -gt 50000) {
        throw "Precompiled dependency prefix has an invalid file count: $($sourceFiles.Count)"
    }

    [int64]$totalBytes = 0
    $fileEntries = @(
        foreach ($file in $sourceFiles) {
            $relative = $file.FullName.Substring($prefix.Length + 1).Replace('\', '/')
            $parts = $relative.Split([char]47)
            if ([string]::IsNullOrWhiteSpace($relative) -or $relative.Contains(':') -or
                ($parts -contains '') -or ($parts -contains '.') -or ($parts -contains '..')) {
                throw "Unsafe path in precompiled dependency prefix: $relative"
            }
            $totalBytes += $file.Length
            if ($totalBytes -gt 2GB) { throw 'Precompiled dependency prefix exceeds the 2 GiB package limit.' }
            [ordered]@{
                path = 'prefix/' + $relative
                sha256 = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
            }
        }
    )

    $manifest = [ordered]@{
        schema_version = 1
        architecture = 'x86_64-windows'
        toolchain_version = '20260616'
        dependency_lock_sha256 = (Get-FileHash -LiteralPath $lockPath -Algorithm SHA256).Hash.ToLowerInvariant()
        build_recipe_sha256 = (Get-FileHash -LiteralPath $recipePath -Algorithm SHA256).Hash.ToLowerInvariant()
        files = $fileEntries
    }
    $manifestPath = Join-Path $stage 'prebuilt-manifest.json'
    $manifest | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $manifestPath -Encoding UTF8

    Remove-Item -LiteralPath $OutputArchive -Force -ErrorAction SilentlyContinue
    $archive = [IO.Compression.ZipFile]::Open($OutputArchive, [IO.Compression.ZipArchiveMode]::Create)
    foreach ($file in $sourceFiles) {
        $relative = $file.FullName.Substring($prefix.Length + 1).Replace('\', '/')
        $entry = $archive.CreateEntry('prefix/' + $relative, [IO.Compression.CompressionLevel]::Optimal)
        $input = [IO.File]::OpenRead($file.FullName)
        $output = $entry.Open()
        try { $input.CopyTo($output) } finally { $output.Dispose(); $input.Dispose() }
    }
    $manifestEntry = $archive.CreateEntry('prebuilt-manifest.json', [IO.Compression.CompressionLevel]::Optimal)
    $manifestInput = [IO.File]::OpenRead($manifestPath)
    $manifestOutput = $manifestEntry.Open()
    try { $manifestInput.CopyTo($manifestOutput) } finally { $manifestOutput.Dispose(); $manifestInput.Dispose() }
    $archive.Dispose()
    $archive = $null

    if (-not (Test-Path -LiteralPath $OutputArchive -PathType Leaf) -or (Get-Item -LiteralPath $OutputArchive).Length -eq 0) {
        throw 'Precompiled dependency archive was not created.'
    }
    Write-Host "Created relocatable precompiled dependency archive: $OutputArchive" -ForegroundColor Green
} finally {
    if ($archive) { $archive.Dispose() }
    if (Test-Path -LiteralPath $stage -PathType Container) {
        Remove-Item -LiteralPath $stage -Recurse -Force
    }
}
