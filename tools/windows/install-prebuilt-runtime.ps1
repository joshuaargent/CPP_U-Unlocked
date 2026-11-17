# Verify and install the game-data-free runtime, support libraries, and host objects.
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$ArchivePath,
    [Parameter(Mandatory = $true)][string]$EngineRoot,
    [Parameter(Mandatory = $true)][string]$ExpectedSourceRevision
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
Add-Type -AssemblyName System.IO.Compression

function Get-RuntimeIdentityHash {
    param([Parameter(Mandatory = $true)]$Manifest)
    $identity = [ordered]@{
        compiler_sha256 = [string]$Manifest.compiler_sha256
        objects = @($Manifest.objects | ForEach-Object { "$($_.path):$($_.sha256):$($_.length)" })
        libraries = @($Manifest.libraries | ForEach-Object { "$($_.path):$($_.sha256):$($_.length)" })
        host_variants = @($Manifest.host_variants | ForEach-Object {
            $variantName = [string]$_.variant
            @($_.objects | ForEach-Object { "$variantName/$($_.path):$($_.sha256):$($_.length)" })
        })
    }
    $json = $identity | ConvertTo-Json -Depth 8 -Compress
    $bytes = [Text.Encoding]::UTF8.GetBytes($json)
    $sha = [Security.Cryptography.SHA256]::Create()
    try { return [BitConverter]::ToString($sha.ComputeHash($bytes)).Replace('-', '').ToLowerInvariant() }
    finally { $sha.Dispose() }
}

if ($ExpectedSourceRevision -notmatch '^[0-9a-fA-F]{40}$') {
    throw 'The expected source revision is not a valid 40-character Git commit.'
}
if (-not (Test-Path -LiteralPath $ArchivePath -PathType Leaf)) {
    throw "The prebuilt runtime archive is missing: $ArchivePath"
}

$EngineRoot = [IO.Path]::GetFullPath($EngineRoot)
$ArchivePath = [IO.Path]::GetFullPath($ArchivePath)
New-Item -ItemType Directory -Force -Path $EngineRoot | Out-Null
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
    if ($archive.Entries.Count -lt 2 -or $archive.Entries.Count -gt 220) {
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
        if ($entries.ContainsKey($name)) {
            throw "Duplicate path in prebuilt runtime archive: $name"
        }
        if ($name -ne 'runtime-manifest.json' -and
            -not $name.StartsWith('objects/') -and
            -not $name.StartsWith('libraries/') -and
            -not $name.StartsWith('host/')) {
            throw "Unexpected path in prebuilt runtime archive: $name"
        }
        $totalBytes += $entry.Length
        if ($totalBytes -gt 1GB) {
            throw 'The prebuilt runtime archive exceeds the 1 GiB extraction limit.'
        }
        $entries.Add($name, $entry)
    }

    if (-not $entries.ContainsKey('runtime-manifest.json')) {
        throw 'The prebuilt runtime manifest is missing.'
    }
    $manifestStream = $entries['runtime-manifest.json'].Open()
    try {
        $reader = [IO.StreamReader]::new($manifestStream)
        try {
            $manifestText = $reader.ReadToEnd()
            $manifest = $manifestText | ConvertFrom-Json
        } finally {
            $reader.Dispose()
        }
    } finally {
        $manifestStream.Dispose()
    }

    if ($manifest.schema_version -ne 1 -or
        $manifest.architecture -ne 'x86_64-windows' -or
        [string]$manifest.source_revision -ne $ExpectedSourceRevision.ToLowerInvariant() -or
        -not ($manifest.objects -is [array]) -or
        $manifest.objects.Count -lt 40 -or $manifest.objects.Count -gt 200 -or
        [int]$manifest.object_count -ne $manifest.objects.Count -or
        -not ($manifest.libraries -is [array]) -or $manifest.libraries.Count -ne 6 -or
        [int]$manifest.library_count -ne $manifest.libraries.Count -or
        -not ($manifest.host_variants -is [array]) -or $manifest.host_variants.Count -ne 2 -or
        ([string]$manifest.compiler_sha256) -notmatch '^[0-9a-fA-F]{64}$') {
        throw 'The prebuilt runtime manifest does not match this release source or architecture.'
    }

    $earlyHostVariantNames = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($variant in $manifest.host_variants) {
        $variantName = [string]$variant.variant
        if ($variantName -notin @('v2', 'v3') -or
            -not $earlyHostVariantNames.Add($variantName) -or
            -not ($variant.objects -is [array]) -or $variant.objects.Count -ne 3) {
            throw 'The prebuilt runtime manifest has invalid host object variants.'
        }
    }
    if ($earlyHostVariantNames.Count -ne 2) {
        throw 'The prebuilt runtime manifest does not contain both host object variants.'
    }
    $runtimeIdentityHash = Get-RuntimeIdentityHash -Manifest $manifest
    $archiveExpectedCount = $manifest.objects.Count + $manifest.libraries.Count + 6 + 1
    if ($archive.Entries.Count -ne $archiveExpectedCount) {
        throw 'Prebuilt runtime archive entry count does not match its manifest.'
    }
    foreach ($record in @($manifest.objects) + @($manifest.libraries)) {
        $relative = [string]$record.path
        if (-not $entries.ContainsKey($relative) -or $entries[$relative].Length -ne [int64]$record.length) {
            throw "Prebuilt runtime archive is missing a listed file or has the wrong size: $relative"
        }
    }
    foreach ($variant in $manifest.host_variants) {
        foreach ($record in $variant.objects) {
            $relative = [string]$record.path
            if (-not $entries.ContainsKey($relative) -or $entries[$relative].Length -ne [int64]$record.length) {
                throw "Prebuilt runtime archive is missing a listed host object or has the wrong size: $relative"
            }
        }
    }

    $repoRoot = Split-Path -Parent $EngineRoot
    . (Join-Path $repoRoot 'tools\windows\toolchain-path.ps1')
    $toolchainRoot = Get-UUnlockedToolchainRoot
    $compiler = Join-Path $toolchainRoot 'llvm-mingw\bin\x86_64-w64-mingw32-clang++.exe'
    if (-not (Test-Path -LiteralPath $compiler -PathType Leaf) -or
        (Get-FileHash -LiteralPath $compiler -Algorithm SHA256).Hash.ToLowerInvariant() -ne
        ([string]$manifest.compiler_sha256).ToLowerInvariant()) {
        throw 'The prebuilt runtime was compiled with a different or missing pinned compiler.'
    }

    $identityMarkerPath = Join-Path $destination '.u-unlocked-runtime-identity.sha256'
    $installedManifestPath = Join-Path $destination 'runtime-manifest.json'
    if ((Test-Path -LiteralPath $identityMarkerPath -PathType Leaf) -and
        (Get-Content -LiteralPath $identityMarkerPath -Raw).Trim() -eq $runtimeIdentityHash -and
        (Test-Path -LiteralPath $installedManifestPath -PathType Leaf)) {
        $installedIdentityMatches = $false
        try {
            $installedManifest = Get-Content -LiteralPath $installedManifestPath -Raw | ConvertFrom-Json
            $installedIdentityMatches = (Get-RuntimeIdentityHash -Manifest $installedManifest) -eq $runtimeIdentityHash
        } catch {
            $installedIdentityMatches = $false
        }
        if ($installedIdentityMatches) {
            $installedRecords = @($manifest.objects) + @($manifest.libraries) + @(
                $manifest.host_variants | ForEach-Object { $_.objects }
            )
            $expectedInstalledCount = $installedRecords.Count + 2
            $installedFiles = @(Get-ChildItem -LiteralPath $destination -File -Recurse -Force)
            $allInstalledFilesMatch = $installedFiles.Count -eq $expectedInstalledCount
            if ($allInstalledFilesMatch) {
                foreach ($record in $installedRecords) {
                    $relative = [string]$record.path
                    $expectedHash = [string]$record.sha256
                    $expectedLength = [int64]$record.length
                    if ([string]::IsNullOrWhiteSpace($relative) -or
                        [IO.Path]::IsPathRooted($relative) -or $relative.Contains('..') -or
                        $expectedHash -notmatch '^[0-9a-fA-F]{64}$' -or $expectedLength -lt 1) {
                        $allInstalledFilesMatch = $false
                        break
                    }
                    $installedPath = Join-Path $destination $relative.Replace('/', '\')
                    if (-not (Test-Path -LiteralPath $installedPath -PathType Leaf)) {
                        $allInstalledFilesMatch = $false
                        break
                    }
                    $installedFile = Get-Item -LiteralPath $installedPath
                    if ($installedFile.Length -ne $expectedLength -or
                        (Get-FileHash -LiteralPath $installedPath -Algorithm SHA256).Hash.ToLowerInvariant() -ne $expectedHash.ToLowerInvariant()) {
                        $allInstalledFilesMatch = $false
                        break
                    }
                }
            }
            if ($allInstalledFilesMatch) {
                [IO.File]::WriteAllText($installedManifestPath, $manifestText, [Text.UTF8Encoding]::new($false))
                Set-Content -LiteralPath $identityMarkerPath -Value $runtimeIdentityHash -Encoding ASCII
                Write-Host 'The verified generic runtime is already installed and every file matches its manifest; skipping extraction.' -ForegroundColor Green
                return
            }
        }
    }

    $expected = [Collections.Generic.Dictionary[string,string]]::new([StringComparer]::OrdinalIgnoreCase)
    $expectedLengths = [Collections.Generic.Dictionary[string,int64]]::new([StringComparer]::OrdinalIgnoreCase)

    foreach ($record in $manifest.objects) {
        $relative = [string]$record.path
        $hash = [string]$record.sha256
        $length = [int64]$record.length
        if (-not $relative.StartsWith('objects/') -or $relative.Contains('..') -or
            [IO.Path]::IsPathRooted($relative) -or $hash -notmatch '^[0-9a-fA-F]{64}$' -or
            $length -lt 1 -or $expected.ContainsKey($relative)) {
            throw 'The prebuilt runtime manifest contains an unsafe or duplicate object entry.'
        }
        $expected.Add($relative, $hash.ToLowerInvariant())
        $expectedLengths.Add($relative, $length)
    }

    $requiredLibraries = @(
        'libraries/libamd_addrlib.a',
        'libraries/libcemu_nex.a',
        'libraries/libcafe_rpx.a',
        'libraries/libcafe_title.a',
        'libraries/libcafe_latte.a',
        'libraries/libzarchive.a'
    )
    foreach ($record in $manifest.libraries) {
        $relative = [string]$record.path
        $hash = [string]$record.sha256
        $length = [int64]$record.length
        if (-not $relative.StartsWith('libraries/') -or $relative.Contains('..') -or
            [IO.Path]::IsPathRooted($relative) -or $hash -notmatch '^[0-9a-fA-F]{64}$' -or
            $length -lt 1 -or $expected.ContainsKey($relative)) {
            throw 'The prebuilt runtime manifest contains an unsafe or duplicate library entry.'
        }
        $expected.Add($relative, $hash.ToLowerInvariant())
        $expectedLengths.Add($relative, $length)
    }
    foreach ($requiredLibrary in $requiredLibraries) {
        if (-not $expected.ContainsKey($requiredLibrary)) {
            throw "The prebuilt runtime is missing a required static library: $requiredLibrary"
        }
    }

    $hostVariantNames = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($variant in $manifest.host_variants) {
        $variantName = [string]$variant.variant
        if ($variantName -notin @('v2', 'v3') -or
            -not $hostVariantNames.Add($variantName) -or
            -not ($variant.objects -is [array]) -or $variant.objects.Count -ne 3) {
            throw 'The prebuilt runtime manifest has invalid host object variants.'
        }
        foreach ($record in $variant.objects) {
            $relative = [string]$record.path
            $hash = [string]$record.sha256
            $length = [int64]$record.length
            if (-not $relative.StartsWith("host/$variantName/") -or $relative.Contains('..') -or
                [IO.Path]::IsPathRooted($relative) -or $hash -notmatch '^[0-9a-fA-F]{64}$' -or
                $length -lt 1 -or $expected.ContainsKey($relative)) {
                throw 'The prebuilt runtime manifest contains an unsafe or duplicate host object.'
            }
            $expected.Add($relative, $hash.ToLowerInvariant())
            $expectedLengths.Add($relative, $length)
        }
    }
    if ($hostVariantNames.Count -ne 2 -or
        $expected.Count -ne ($manifest.objects.Count + $manifest.libraries.Count + 6)) {
        throw 'The prebuilt runtime manifest does not contain both complete host object variants.'
    }
    if ($entries.Count -ne ($expected.Count + 1)) {
        throw 'The prebuilt runtime archive contains unlisted or missing files.'
    }

    foreach ($relative in $expected.Keys) {
        if (-not $entries.ContainsKey($relative) -or
            $entries[$relative].Length -ne $expectedLengths[$relative]) {
            throw "A listed prebuilt runtime file is missing or has the wrong size: $relative"
        }
    }

    foreach ($entry in $archive.Entries) {
        $name = $entry.FullName.Replace([char]92, [char]47)
        if ($name -eq 'runtime-manifest.json') { continue }
        if (-not $expected.ContainsKey($name)) {
            throw "Unlisted prebuilt runtime file: $name"
        }
        $relative = $name.Replace('/', '\')
        $target = [IO.Path]::GetFullPath((Join-Path $stage $relative))
        $stagePrefix = $stage.TrimEnd([char]92) + [IO.Path]::DirectorySeparatorChar
        if (-not $target.StartsWith($stagePrefix, [StringComparison]::OrdinalIgnoreCase)) {
            throw "Prebuilt runtime path escaped its staging directory: $name"
        }
        $targetDirectory = Split-Path -Parent $target
        New-Item -ItemType Directory -Force -Path $targetDirectory | Out-Null
        $input = $entry.Open()
        $output = [IO.File]::Create($target)
        try {
            $input.CopyTo($output)
        } finally {
            $output.Dispose()
            $input.Dispose()
        }
        $actual = (Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($actual -ne $expected[$name]) {
            throw "Prebuilt runtime file failed SHA-256 verification: $name"
        }
    }

    $manifestInput = $entries['runtime-manifest.json'].Open()
    $manifestOutput = [IO.File]::Create((Join-Path $stage 'runtime-manifest.json'))
    try {
        $manifestInput.CopyTo($manifestOutput)
    } finally {
        $manifestOutput.Dispose()
        $manifestInput.Dispose()
    }
    Set-Content -LiteralPath (Join-Path $stage '.u-unlocked-runtime-identity.sha256') -Value $runtimeIdentityHash -Encoding ASCII
    $archive.Dispose()
    $archive = $null

    if (Test-Path -LiteralPath $destination) {
        Move-Item -LiteralPath $destination -Destination $backup
    }
    try {
        Move-Item -LiteralPath $stage -Destination $destination
        $installed = $true
    } catch {
        if (Test-Path -LiteralPath $backup) {
            Move-Item -LiteralPath $backup -Destination $destination
        }
        throw
    }
    if (Test-Path -LiteralPath $backup) {
        Remove-Item -LiteralPath $backup -Recurse -Force
    }
    Write-Host "Installed $($manifest.object_count) runtime objects, $($manifest.library_count) libraries, and both host variants for source $ExpectedSourceRevision." -ForegroundColor Green
} finally {
    if ($archive) { $archive.Dispose() }
    if (Test-Path -LiteralPath $stage) {
        Remove-Item -LiteralPath $stage -Recurse -Force
    }
    if (-not $installed -and (Test-Path -LiteralPath $backup) -and -not (Test-Path -LiteralPath $destination)) {
        Move-Item -LiteralPath $backup -Destination $destination
    } elseif (Test-Path -LiteralPath $backup) {
        Remove-Item -LiteralPath $backup -Recurse -Force
    }
}