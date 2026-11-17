# Installs the release's precompiled Windows dependency prefix after verifying its
# dependency lock, exact file inventory, and every file's SHA-256 digest.
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$ArchivePath,
    [Parameter(Mandatory = $true)][string]$EngineRoot
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem

$EngineRoot = [IO.Path]::GetFullPath($EngineRoot)
$ArchivePath = [IO.Path]::GetFullPath($ArchivePath)
$lockPath = Join-Path $EngineRoot 'dependencies.lock.json'
if (-not (Test-Path -LiteralPath $ArchivePath -PathType Leaf)) { throw "Prebuilt dependency archive is missing: $ArchivePath" }
if (-not (Test-Path -LiteralPath $lockPath -PathType Leaf)) { throw "Dependency lock file is missing: $lockPath" }

$lockHash = (Get-FileHash -LiteralPath $lockPath -Algorithm SHA256).Hash.ToLowerInvariant()
$recipePath = Join-Path $EngineRoot 'tools\windows\build-deps.ps1'
if (-not (Test-Path -LiteralPath $recipePath -PathType Leaf)) { throw "Dependency build recipe is missing: $recipePath" }
$recipeHash = (Get-FileHash -LiteralPath $recipePath -Algorithm SHA256).Hash.ToLowerInvariant()
$destination = Join-Path $EngineRoot 'build-deps\prefix'
$parent = Split-Path -Parent $destination
New-Item -ItemType Directory -Force -Path $parent | Out-Null
$stage = Join-Path $parent ('.prefix-staging-' + [guid]::NewGuid().ToString('N'))
$backup = Join-Path $parent ('.prefix-previous-' + [guid]::NewGuid().ToString('N'))
$archive = $null

try {
    $archive = [IO.Compression.ZipFile]::OpenRead($ArchivePath)
    if ($archive.Entries.Count -lt 2 -or $archive.Entries.Count -gt 50000) {
        throw 'Prebuilt dependency archive has an invalid entry count.'
    }

    $entries = [Collections.Generic.Dictionary[string,System.IO.Compression.ZipArchiveEntry]]::new([StringComparer]::OrdinalIgnoreCase)
    [int64]$expanded = 0
    foreach ($entry in $archive.Entries) {
        $name = $entry.FullName.Replace([char]92, [char]47)
        $parts = $name.Split([char]47)
        if ([string]::IsNullOrWhiteSpace($name) -or $name.StartsWith('/') -or $name.Contains(':') -or
            ($parts -contains '..') -or ($parts -contains '.') -or $name.Contains('//')) {
            throw "Unsafe prebuilt dependency archive path: $name"
        }
        $kind = ($entry.ExternalAttributes -shr 16) -band 0xF000
        if ($kind -eq 0xA000) { throw "Symbolic links are not allowed in the prebuilt dependency archive: $name" }
        if ($name -eq 'prebuilt-manifest.json') {
            if ($entries.ContainsKey($name)) { throw 'Duplicate prebuilt dependency manifest.' }
            $entries.Add($name, $entry)
            $expanded += [int64]$entry.Length
            if ($expanded -gt 2GB) { throw 'Prebuilt dependency archive expands beyond the 2 GiB safety limit.' }
            continue
        }
        if (-not $name.StartsWith('prefix/', [StringComparison]::Ordinal)) {
            throw "Unexpected prebuilt dependency archive path: $name"
        }
        if ($entries.ContainsKey($name)) { throw "Duplicate prebuilt dependency archive path: $name" }
        if ($entry.Name -eq '') { continue }
        $entries.Add($name, $entry)
        $expanded += [int64]$entry.Length
        if ($expanded -gt 2GB) { throw 'Prebuilt dependency archive expands beyond the 2 GiB safety limit.' }
    }

    if (-not $entries.ContainsKey('prebuilt-manifest.json')) {
        throw 'Prebuilt dependency archive is missing prebuilt-manifest.json.'
    }
    $manifestStream = $entries['prebuilt-manifest.json'].Open()
    try {
        $reader = [IO.StreamReader]::new($manifestStream)
        try { $manifest = $reader.ReadToEnd() | ConvertFrom-Json } finally { $reader.Dispose() }
    } finally { $manifestStream.Dispose() }

    if ($manifest.schema_version -ne 1 -or $manifest.architecture -ne 'x86_64-windows' -or
        $manifest.toolchain_version -ne '20260616' -or $manifest.dependency_lock_sha256 -ne $lockHash -or
        $manifest.build_recipe_sha256 -ne $recipeHash -or -not ($manifest.files -is [array])) {
        throw 'Prebuilt dependency manifest does not match this build kit or target architecture.'
    }

    $expected = [Collections.Generic.Dictionary[string,string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($file in $manifest.files) {
        $name = [string]$file.path
        $hash = [string]$file.sha256
        if (-not $name.StartsWith('prefix/', [StringComparison]::Ordinal) -or
            $name.Contains('..') -or $name.Contains(':') -or $name.Contains('//') -or ($hash.Length -ne 64 -or $hash -notmatch '^[0-9a-fA-F]{64}') -or
            $expected.ContainsKey($name)) {
            throw "Invalid or duplicate file in prebuilt dependency manifest: $name"
        }
        $expected.Add($name, $hash.ToLowerInvariant())
    }

    $actualNames = @($entries.Keys | Where-Object { $_ -ne 'prebuilt-manifest.json' })
    if ($actualNames.Count -ne $expected.Count) {
        throw 'Prebuilt dependency archive file inventory does not match its manifest.'
    }
    foreach ($name in $actualNames) {
        if (-not $expected.ContainsKey($name)) { throw "Unlisted file in prebuilt dependency archive: $name" }
        $entryStream = $entries[$name].Open()
        $sha = [Security.Cryptography.SHA256]::Create()
        try { $actualHash = [BitConverter]::ToString($sha.ComputeHash($entryStream)).Replace('-', '').ToLowerInvariant() }
        finally { $sha.Dispose(); $entryStream.Dispose() }
        if ($actualHash -ne $expected[$name]) { throw "Prebuilt dependency SHA-256 mismatch: $name" }
    }

    # Rebuilds can happen when only the user's game RPX changes. Avoid extracting
    # and rewriting the large dependency prefix when every installed file is
    # already byte-for-byte identical to the verified release archive.
    if (Test-Path -LiteralPath $destination -PathType Container) {
        $existingFiles = @(Get-ChildItem -LiteralPath $destination -File -Recurse)
        if ($existingFiles.Count -eq $expected.Count) {
            $existingMatches = $true
            foreach ($file in $existingFiles) {
                $relative = $file.FullName.Substring($destination.Length + 1).Replace('\', '/')
                if (-not $expected.ContainsKey("prefix/$relative") -or
                    (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash.ToLowerInvariant() -ne $expected["prefix/$relative"]) {
                    $existingMatches = $false
                    break
                }
            }
            if ($existingMatches) {
                Write-Host "Verified precompiled Windows dependencies are already current: $destination" -ForegroundColor Green
                return
            }
        }
    }

    New-Item -ItemType Directory -Force -Path $stage | Out-Null
    foreach ($name in $actualNames) {
        $relative = $name.Substring('prefix/'.Length)
        $target = Join-Path $stage ($relative.Replace('/', [IO.Path]::DirectorySeparatorChar))
        $resolvedTarget = [IO.Path]::GetFullPath($target)
        if (-not $resolvedTarget.StartsWith(($stage.TrimEnd('\') + '\'), [StringComparison]::OrdinalIgnoreCase)) {
            throw "Prebuilt dependency path escapes the staging directory: $name"
        }
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $target) | Out-Null
        $input = $entries[$name].Open()
        $output = [IO.File]::Open($target, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
        try { $input.CopyTo($output); $output.Flush($true) } finally { $output.Dispose(); $input.Dispose() }
    }

    foreach ($required in @('lib\libvulkan-1.a', 'include\vulkan\vulkan.h')) {
        if (-not (Test-Path -LiteralPath (Join-Path $stage $required) -PathType Leaf)) {
            throw "Prebuilt dependency prefix is incomplete; missing $required."
        }
    }

    $archive.Dispose()
    $archive = $null
    if (Test-Path -LiteralPath $destination -PathType Container) { Move-Item -LiteralPath $destination -Destination $backup }
    try {
        Move-Item -LiteralPath $stage -Destination $destination
    } catch {
        if (Test-Path -LiteralPath $backup -PathType Container) { Move-Item -LiteralPath $backup -Destination $destination }
        throw
    }
    if (Test-Path -LiteralPath $backup -PathType Container) { Remove-Item -LiteralPath $backup -Recurse -Force }
    Write-Host "Verified precompiled Windows dependencies installed: $destination" -ForegroundColor Green
} finally {
    if ($archive) { $archive.Dispose() }
    if (Test-Path -LiteralPath $stage -PathType Container) { Remove-Item -LiteralPath $stage -Recurse -Force }
    if (Test-Path -LiteralPath $backup -PathType Container) {
        if (-not (Test-Path -LiteralPath $destination -PathType Container)) { Move-Item -LiteralPath $backup -Destination $destination }
        else { Remove-Item -LiteralPath $backup -Recurse -Force }
    }
}
