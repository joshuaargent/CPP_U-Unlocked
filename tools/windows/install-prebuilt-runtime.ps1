# Verify and install game-data-free precompiled runtime objects.
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$ArchivePath,
    [Parameter(Mandatory = $true)][string]$EngineRoot,
    [Parameter(Mandatory = $true)][string]$ExpectedSourceRevision
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
Add-Type -AssemblyName System.IO.Compression

if ($ExpectedSourceRevision -notmatch '^[0-9a-fA-F]{40}$') {
    throw 'The expected source revision is not a valid 40-character Git commit.'
}
if (-not (Test-Path -LiteralPath $ArchivePath -PathType Leaf)) {
    throw "The prebuilt runtime archive is missing: $ArchivePath"
}
$EngineRoot = [IO.Path]::GetFullPath($EngineRoot)
$ArchivePath = [IO.Path]::GetFullPath($ArchivePath)
$destination = Join-Path $EngineRoot 'build-prebuilt-runtime'
$stage = Join-Path $EngineRoot ('.build-prebuilt-runtime-staging-' + [guid]::NewGuid().ToString('N'))
$backup = Join-Path $EngineRoot ('.build-prebuilt-runtime-backup-' + [guid]::NewGuid().ToString('N'))
$archive = $null
$installed = $false

try {
    New-Item -ItemType Directory -Force -Path $stage | Out-Null
    $archive = [IO.Compression.ZipFile]::OpenRead($ArchivePath)
    $entries = [Collections.Generic.Dictionary[string,System.IO.Compression.ZipArchiveEntry]]::new([StringComparer]::OrdinalIgnoreCase)
    [int64]$totalBytes = 0
    if ($archive.Entries.Count -lt 2 -or $archive.Entries.Count -gt 205) {
        throw "The prebuilt runtime archive has an invalid entry count: $($archive.Entries.Count)"
    }
    foreach ($entry in $archive.Entries) {
        $name = $entry.FullName.Replace([char]92, [char]47)
        $parts = $name.Split([char]47)
        if ([string]::IsNullOrWhiteSpace($name) -or $name.StartsWith('/') -or $name.Contains(':') -or
            ($parts -contains '') -or ($parts -contains '.') -or ($parts -contains '..') -or
            $entry.Name.Length -eq 0) {
            throw "Unsafe path in prebuilt runtime archive: $name"
        }
        if ($entries.ContainsKey($name)) { throw "Duplicate path in prebuilt runtime archive: $name" }
        if ($name -ne 'runtime-manifest.json' -and -not $name.StartsWith('objects/')) {
            throw "Unexpected path in prebuilt runtime archive: $name"
        }
        $totalBytes += $entry.Length
        if ($totalBytes -gt 1GB) { throw 'The prebuilt runtime archive exceeds the 1 GiB extraction limit.' }
        $entries.Add($name, $entry)
    }
    if (-not $entries.ContainsKey('runtime-manifest.json')) {
        throw 'The prebuilt runtime manifest is missing.'
    }

    $reader = [IO.StreamReader]::new($entries['runtime-manifest.json'].Open())
    try { $manifest = $reader.ReadToEnd() | ConvertFrom-Json } finally { $reader.Dispose() }
    if ($manifest.schema_version -ne 1 -or $manifest.architecture -ne 'x86_64-windows' -or
        [string]$manifest.source_revision -ne $ExpectedSourceRevision.ToLowerInvariant() -or
        -not ($manifest.objects -is [array]) -or $manifest.objects.Count -lt 40 -or
        $manifest.objects.Count -gt 200 -or [int]$manifest.object_count -ne $manifest.objects.Count -or
        [string]$manifest.compiler_sha256 -notmatch '^[0-9a-fA-F]{64}$') {
        throw 'The prebuilt runtime manifest does not match this release source or architecture.'
    }
    if ($entries.Count -ne ($manifest.objects.Count + 1)) {
        throw 'The prebuilt runtime archive contains unlisted or missing files.'
    }

    $expected = [Collections.Generic.Dictionary[string,string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($record in $manifest.objects) {
        $relative = [string]$record.path
        $hash = [string]$record.sha256
        if (-not $relative.StartsWith('objects/') -or $relative.Contains('..') -or
            [IO.Path]::IsPathRooted($relative) -or $hash -notmatch '^[0-9a-fA-F]{64}$' -or
            [int64]$record.length -lt 1 -or $expected.ContainsKey($relative)) {
            throw 'The prebuilt runtime manifest contains an unsafe or duplicate object entry.'
        }
        if (-not $entries.ContainsKey($relative) -or $entries[$relative].Length -ne [int64]$record.length) {
            throw "A listed prebuilt runtime object is missing or has the wrong size: $relative"
        }
        $expected.Add($relative, $hash.ToLowerInvariant())
    }

    foreach ($entry in $archive.Entries) {
        $name = $entry.FullName.Replace([char]92, [char]47)
        if ($name -eq 'runtime-manifest.json') { continue }
        if (-not $expected.ContainsKey($name)) { throw "Unlisted prebuilt runtime object: $name" }
        $relative = $name.Substring('objects/'.Length).Replace('/', '\')
        $target = Join-Path $stage $relative
        $targetDirectory = Split-Path -Parent $target
        New-Item -ItemType Directory -Force -Path $targetDirectory | Out-Null
        $input = $entry.Open()
        $output = [IO.File]::Create($target)
        try { $input.CopyTo($output) } finally { $output.Dispose(); $input.Dispose() }
        $actual = (Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($actual -ne $expected[$name]) {
            throw "Prebuilt runtime object failed SHA-256 verification: $name"
        }
    }
    Copy-Item -LiteralPath (Join-Path $stage 'runtime-manifest.json') -Destination (Join-Path $stage 'runtime-manifest.json') -Force -ErrorAction SilentlyContinue
    $archive.Dispose()
    $archive = $null

    if (Test-Path -LiteralPath $destination) {
        Move-Item -LiteralPath $destination -Destination $backup
    }
    try {
        Move-Item -LiteralPath $stage -Destination $destination
        $installed = $true
    } catch {
        if (Test-Path -LiteralPath $backup) { Move-Item -LiteralPath $backup -Destination $destination }
        throw
    }
    if (Test-Path -LiteralPath $backup) { Remove-Item -LiteralPath $backup -Recurse -Force }
    Write-Host "Installed $($manifest.object_count) verified generic runtime objects for source $ExpectedSourceRevision." -ForegroundColor Green
} finally {
    if ($archive) { $archive.Dispose() }
    if (Test-Path -LiteralPath $stage) { Remove-Item -LiteralPath $stage -Recurse -Force }
    if (-not $installed -and (Test-Path -LiteralPath $backup) -and -not (Test-Path -LiteralPath $destination)) {
        Move-Item -LiteralPath $backup -Destination $destination
    } elseif (Test-Path -LiteralPath $backup) {
        Remove-Item -LiteralPath $backup -Recurse -Force
    }
}