$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$installer = Join-Path $repoRoot 'tools\windows\install-prebuilt-dependencies.ps1'
$temporary = Join-Path ([IO.Path]::GetTempPath()) ('u-unlocked-prebuilt-test-' + [guid]::NewGuid().ToString('N'))
$engineRoot = Join-Path $temporary 'engine'
$sourceRoot = Join-Path $temporary 'source'
New-Item -ItemType Directory -Force -Path $engineRoot, $sourceRoot | Out-Null

function Get-TestHash([string]$Path) {
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function New-TestArchive {
    param(
        [string]$Path,
        [string]$Root,
        [string]$LockHash,
        [switch]$Tamper,
        [switch]$Traversal
    )
    $files = @(
        Get-ChildItem -LiteralPath $Root -File -Recurse | ForEach-Object {
            [ordered]@{
                path = 'prefix/' + $_.FullName.Substring($Root.Length + 1).Replace('\', '/')
                sha256 = Get-TestHash $_.FullName
            }
        }
    )
    $manifest = [ordered]@{
        schema_version = 1
        architecture = 'x86_64-windows'
        dependency_lock_sha256 = $LockHash
        files = $files
    }

    $zip = [IO.Compression.ZipFile]::Open($Path, [IO.Compression.ZipArchiveMode]::Create)
    try {
        # Directory entries are intentionally present; the installer must ignore
        # them while validating the exact file inventory.
        foreach ($directory in @('prefix/', 'prefix/lib/', 'prefix/include/', 'prefix/include/vulkan/')) {
            [void]$zip.CreateEntry($directory)
        }
        foreach ($file in Get-ChildItem -LiteralPath $Root -File -Recurse) {
            $relative = $file.FullName.Substring($Root.Length + 1).Replace('\', '/')
            $entry = $zip.CreateEntry('prefix/' + $relative, [IO.Compression.CompressionLevel]::Optimal)
            $input = [IO.File]::OpenRead($file.FullName)
            $output = $entry.Open()
            try {
                if ($Tamper -and $relative -eq 'lib/libvulkan-1.a') {
                    $bytes = [Text.Encoding]::UTF8.GetBytes('tampered library')
                    $output.Write($bytes, 0, $bytes.Length)
                } else {
                    $input.CopyTo($output)
                }
            } finally {
                $output.Dispose()
                $input.Dispose()
            }
        }
        if ($Traversal) {
            $entry = $zip.CreateEntry('prefix/../escape.txt')
            $output = $entry.Open()
            try {
                $bytes = [Text.Encoding]::UTF8.GetBytes('escape')
                $output.Write($bytes, 0, $bytes.Length)
            } finally { $output.Dispose() }
        }
        $manifestEntry = $zip.CreateEntry('prebuilt-manifest.json')
        $stream = $manifestEntry.Open()
        try {
            $json = $manifest | ConvertTo-Json -Depth 6 -Compress
            $bytes = [Text.Encoding]::UTF8.GetBytes($json)
            $stream.Write($bytes, 0, $bytes.Length)
        } finally { $stream.Dispose() }
    } finally {
        $zip.Dispose()
    }
}

try {
    $lockPath = Join-Path $engineRoot 'dependencies.lock.json'
    Set-Content -LiteralPath $lockPath -Value '{"SDL":{"revision":"0123456789abcdef0123456789abcdef01234567"}}' -Encoding UTF8
    $lockHash = Get-TestHash $lockPath

    $libDirectory = Join-Path $sourceRoot 'lib'
    $headerDirectory = Join-Path $sourceRoot 'include\vulkan'
    New-Item -ItemType Directory -Force -Path $libDirectory, $headerDirectory | Out-Null
    Set-Content -LiteralPath (Join-Path $libDirectory 'libvulkan-1.a') -Value 'valid import library' -Encoding ASCII
    Set-Content -LiteralPath (Join-Path $headerDirectory 'vulkan.h') -Value '#pragma once' -Encoding ASCII

    $validArchive = Join-Path $temporary 'valid.zip'
    New-TestArchive -Path $validArchive -Root $sourceRoot -LockHash $lockHash
    & $installer -ArchivePath $validArchive -EngineRoot $engineRoot
    foreach ($required in @('lib\libvulkan-1.a', 'include\vulkan\vulkan.h')) {
        if (-not (Test-Path -LiteralPath (Join-Path $engineRoot ('build-deps\prefix\' + $required)) -PathType Leaf)) {
            throw "Verified dependency installation is missing $required."
        }
    }

    $installedLibrary = Join-Path $engineRoot 'build-deps\prefix\lib\libvulkan-1.a'
    $installedHash = Get-TestHash $installedLibrary
    $tamperedArchive = Join-Path $temporary 'tampered.zip'
    New-TestArchive -Path $tamperedArchive -Root $sourceRoot -LockHash $lockHash -Tamper
    $rejected = $false
    try { & $installer -ArchivePath $tamperedArchive -EngineRoot $engineRoot } catch { $rejected = $true }
    if (-not $rejected) { throw 'The installer accepted a file that failed its SHA-256 check.' }
    if ((Get-TestHash $installedLibrary) -ne $installedHash) {
        throw 'A rejected dependency archive modified the previously installed prefix.'
    }

    Set-Content -LiteralPath $lockPath -Value '{"SDL":{"revision":"fedcba9876543210fedcba9876543210fedcba98"}}' -Encoding UTF8
    $mismatchRejected = $false
    try { & $installer -ArchivePath $validArchive -EngineRoot $engineRoot } catch { $mismatchRejected = $true }
    if (-not $mismatchRejected) { throw 'The installer accepted a dependency lock mismatch.' }
    if ((Get-TestHash $installedLibrary) -ne $installedHash) {
        throw 'A lock mismatch modified the previously installed prefix.'
    }

    $traversalArchive = Join-Path $temporary 'traversal.zip'
    New-TestArchive -Path $traversalArchive -Root $sourceRoot -LockHash $lockHash -Traversal
    $traversalRejected = $false
    try { & $installer -ArchivePath $traversalArchive -EngineRoot $engineRoot } catch { $traversalRejected = $true }
    if (-not $traversalRejected) { throw 'The installer accepted a path-traversal archive entry.' }
    if (Test-Path -LiteralPath (Join-Path $temporary 'escape.txt')) {
        throw 'A path-traversal archive wrote outside the dependency prefix.'
    }

    Write-Host 'Prebuilt dependency installer integrity, lock, and rollback tests passed.' -ForegroundColor Green
} finally {
    if (Test-Path -LiteralPath $temporary -PathType Container) {
        Remove-Item -LiteralPath $temporary -Recurse -Force
    }
}
