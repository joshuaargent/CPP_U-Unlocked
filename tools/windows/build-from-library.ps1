# Build U Unlocked directly from the separately selected base-game and update folders.
# Generated game-specific code and executables remain local to this PC.
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$GameDirectory,

    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$UpdateDirectory,

    [string]$LogDirectory,

    [string]$LauncherDirectory
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

Add-Type -AssemblyName System.IO.Compression.FileSystem

function Get-ZipEntrySha256 {
    param(
        [Parameter(Mandatory = $true)][string]$ArchivePath,
        [Parameter(Mandatory = $true)][string]$EntryName
    )
    $archive = [IO.Compression.ZipFile]::OpenRead($ArchivePath)
    try {
        $entry = $archive.GetEntry($EntryName)
        if (-not $entry) { throw "Archive is missing its integrity manifest: $EntryName" }
        $stream = $entry.Open()
        $sha = [Security.Cryptography.SHA256]::Create()
        try {
            return [BitConverter]::ToString($sha.ComputeHash($stream)).Replace('-', '').ToLowerInvariant()
        } finally {
            $sha.Dispose()
            $stream.Dispose()
        }
    } finally {
        $archive.Dispose()
    }
}

function Resolve-TitleFolder {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$ExpectedTitleId,
        [Parameter(Mandatory = $true)][string]$Label
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
        throw "$Label folder does not exist: $Path"
    }

    $resolved = (Resolve-Path -LiteralPath $Path).Path
    $metadataPath = Join-Path $resolved 'code\app.xml'
    $rpxPath = Join-Path $resolved 'code\cross_f.rpx'

    if (-not (Test-Path -LiteralPath $metadataPath -PathType Leaf)) {
        throw "$Label folder is missing code\app.xml. Select the extracted title folder, not its parent or the code folder."
    }
    if (-not (Test-Path -LiteralPath $rpxPath -PathType Leaf)) {
        throw "$Label folder is missing code\cross_f.rpx. This build currently requires the cross_f.rpx input from the title."
    }

    try {
        [xml]$metadata = Get-Content -LiteralPath $metadataPath -Raw
    } catch {
        throw "$Label code\app.xml is not valid XML: $($_.Exception.Message)"
    }
    $titleNode = $metadata.SelectSingleNode('//title_id')
    if (-not $titleNode -or $titleNode.InnerText.Trim().ToUpperInvariant() -ne $ExpectedTitleId) {
        $actual = if ($titleNode) { $titleNode.InnerText.Trim() } else { 'not present' }
        throw "$Label title ID mismatch. Expected $ExpectedTitleId; found $actual."
    }

    $rpx = Get-Item -LiteralPath $rpxPath
    if ($rpx.Length -lt 1MB) {
        throw "$Label RPX is unexpectedly small ($($rpx.Length) bytes). Check that the title dump is complete."
    }

    return [pscustomobject]@{
        Folder = $resolved
        Rpx = $rpx.FullName
        Size = $rpx.Length
    }
}

function Find-BuildTool {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [string[]]$Candidates = @()
    )
    foreach ($candidate in $Candidates) {
        if (Test-Path -LiteralPath $candidate -PathType Leaf) { return $candidate }
    }
    $command = Get-Command $Name -ErrorAction SilentlyContinue
    if ($command) { return $command.Source }
    return $null
}

$script:AssetVerificationCache = $null
$script:AssetVerificationCachePath = $null
$script:AssetVerificationCacheRoot = $null

function Initialize-AssetVerificationCache {
    param([Parameter(Mandatory = $true)][string]$BuildKitDirectory)
    $resolvedRoot = [IO.Path]::GetFullPath($BuildKitDirectory)
    if ($null -ne $script:AssetVerificationCache) {
        if ($script:AssetVerificationCacheRoot -ne $resolvedRoot) {
            throw 'A single build invocation cannot verify assets from multiple build-kit roots.'
        }
        return
    }

    $localRoot = if ($env:LOCALAPPDATA) { $env:LOCALAPPDATA } else { $env:TEMP }
    $identityBytes = [Text.Encoding]::UTF8.GetBytes($resolvedRoot.ToUpperInvariant())
    $identitySha = [Security.Cryptography.SHA256]::Create()
    try {
        $identity = [BitConverter]::ToString($identitySha.ComputeHash($identityBytes)).Replace('-', '').ToLowerInvariant().Substring(0, 20)
    } finally {
        $identitySha.Dispose()
    }
    $cacheRoot = Join-Path $localRoot 'U Unlocked\BuildCache\AssetVerification'
    New-Item -ItemType Directory -Force -Path $cacheRoot | Out-Null
    $script:AssetVerificationCacheRoot = $resolvedRoot
    $script:AssetVerificationCachePath = Join-Path $cacheRoot "$identity.json"
    $script:AssetVerificationCache = @{}

    if (Test-Path -LiteralPath $script:AssetVerificationCachePath -PathType Leaf) {
        try {
            $state = Get-Content -LiteralPath $script:AssetVerificationCachePath -Raw | ConvertFrom-Json
            if ($state.schema_version -eq 1 -and $state.root_path -eq $resolvedRoot -and $state.files) {
                foreach ($property in $state.files.PSObject.Properties) {
                    $script:AssetVerificationCache[$property.Name] = [string]$property.Value
                }
            }
        } catch {
            $script:AssetVerificationCache = @{}
        }
    }
}

function Assert-ReleaseAssetHash {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$ExpectedHash,
        [Parameter(Mandatory = $true)][string]$BuildKitDirectory,
        [Parameter(Mandatory = $true)][string]$CacheKey
    )
    $file = Get-Item -LiteralPath $Path
    $useCache = $file.Length -ge 10MB
    $signature = "$($ExpectedHash.ToUpperInvariant())|$($file.Length)|$($file.LastWriteTimeUtc.Ticks)"
    if ($useCache) {
        Initialize-AssetVerificationCache -BuildKitDirectory $BuildKitDirectory
        if ($script:AssetVerificationCache.ContainsKey($CacheKey) -and
            $script:AssetVerificationCache[$CacheKey] -eq $signature) {
            return
        }
    }

    $actualHash = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
    if ($actualHash -ne $ExpectedHash.ToUpperInvariant()) {
        throw "Release asset failed SHA-256 verification: $Path"
    }
    if ($useCache) {
        $script:AssetVerificationCache[$CacheKey] = $signature
        try {
            $state = [ordered]@{
                schema_version = 1
                root_path = $script:AssetVerificationCacheRoot
                files = $script:AssetVerificationCache
            }
            $temporary = "$($script:AssetVerificationCachePath).tmp"
            $state | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $temporary -Encoding UTF8
            Move-Item -LiteralPath $temporary -Destination $script:AssetVerificationCachePath -Force
        } catch {
            Remove-Item -LiteralPath "$($script:AssetVerificationCachePath).tmp" -Force -ErrorAction SilentlyContinue
            Write-Verbose "Could not persist release asset verification cache: $($_.Exception.Message)"
        }
    }
}

function Assert-BuildKitFile {
    param(
        [Parameter(Mandatory = $true)][string]$BuildKitDirectory,
        [Parameter(Mandatory = $true)][string]$FileName
    )
    $manifestPath = Join-Path $BuildKitDirectory 'build-kit-manifest.json'
    $filePath = Join-Path $BuildKitDirectory $FileName
    if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf) -or
        -not (Test-Path -LiteralPath $filePath -PathType Leaf)) {
        throw "The build-kit manifest or required asset is missing: $FileName"
    }
    $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
    if ($manifest.schema_version -ne 1 -or -not ($manifest.files -is [array])) {
        throw 'The embedded build-kit manifest is invalid.'
    }
    $records = @($manifest.files | Where-Object { [string]$_.name -ceq $FileName })
    if ($records.Count -ne 1) { throw "The build-kit manifest does not uniquely list $FileName." }
    $expected = [string]$records[0].sha256
    if ($expected.Length -ne 64 -or $expected -match '[^0-9a-fA-F]') {
        throw "The build-kit manifest has an invalid SHA-256 for $FileName."
    }
    Assert-ReleaseAssetHash -Path $filePath -ExpectedHash $expected -BuildKitDirectory $BuildKitDirectory -CacheKey "build-kit:$FileName"
}

function Assert-RootPackageFile {
    param(
        [Parameter(Mandatory = $true)][string]$PackageDirectory,
        [Parameter(Mandatory = $true)][string]$BuildKitDirectory,
        [Parameter(Mandatory = $true)][string]$FileName
    )
    $manifestPath = Join-Path $BuildKitDirectory 'build-kit-manifest.json'
    $filePath = Join-Path $PackageDirectory $FileName
    if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf) -or
        -not (Test-Path -LiteralPath $filePath -PathType Leaf)) {
        throw "The build-kit manifest or required root asset is missing: $FileName"
    }
    $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
    if ($manifest.schema_version -ne 1 -or -not ($manifest.files -is [array])) {
        throw 'The build-kit manifest is invalid.'
    }
    $records = @($manifest.files | Where-Object { [string]$_.name -ceq $FileName })
    if ($records.Count -ne 1) { throw "The build-kit manifest does not uniquely list $FileName." }
    $expected = [string]$records[0].sha256
    if ($expected.Length -ne 64 -or $expected -match '[^0-9a-fA-F]') {
        throw "The build-kit manifest has an invalid SHA-256 for $FileName."
    }
    Assert-ReleaseAssetHash -Path $filePath -ExpectedHash $expected -BuildKitDirectory $BuildKitDirectory -CacheKey "package-root:$FileName"
}

function Copy-PreservedDirectory {
    param(
        [Parameter(Mandatory = $true)][string]$Source,
        [Parameter(Mandatory = $true)][string]$Destination
    )
    if (-not (Test-Path -LiteralPath $Source -PathType Container)) { return }
    New-Item -ItemType Directory -Force -Path $Destination | Out-Null
    foreach ($item in Get-ChildItem -LiteralPath $Source -Force) {
        if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) { continue }
        $target = Join-Path $Destination $item.Name
        if ($item.PSIsContainer) {
            Copy-PreservedDirectory -Source $item.FullName -Destination $target
        } else {
            Copy-Item -LiteralPath $item.FullName -Destination $target -Force
        }
    }
}

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$buildEntry = Join-Path $repoRoot 'tools\windows\build-u-unlocked.ps1'
$environmentSetup = Join-Path $PSScriptRoot 'setup-build-environment.ps1'
$verifyScript = Join-Path $PSScriptRoot 'verify-checkout.ps1'
$activationScript = Join-Path $PSScriptRoot 'runtime-activation.ps1'
. (Join-Path $PSScriptRoot 'toolchain-path.ps1')
$prebuiltDependencyInstaller = Join-Path $PSScriptRoot 'install-prebuilt-dependencies.ps1'
$prebuiltRuntimeInstaller = Join-Path $PSScriptRoot 'install-prebuilt-runtime.ps1'

foreach ($required in @($buildEntry, $environmentSetup, $verifyScript, $activationScript, $prebuiltDependencyInstaller, $prebuiltRuntimeInstaller)) {
    if (-not (Test-Path -LiteralPath $required -PathType Leaf)) {
        throw "A required local build script is missing: $required"
    }
}

. $activationScript

if ([string]::IsNullOrWhiteSpace($LogDirectory)) {
    $local = if ($env:LOCALAPPDATA) { $env:LOCALAPPDATA } else { $env:TEMP }
    $LogDirectory = Join-Path $local 'U Unlocked\BuildLogs'
}
New-Item -ItemType Directory -Force -Path $LogDirectory | Out-Null
$logPath = Join-Path $LogDirectory ("build-{0:yyyyMMdd-HHmmss}.log" -f (Get-Date))
$transcriptStarted = $false

try {
    Start-Transcript -LiteralPath $logPath -Force | Out-Null
    $transcriptStarted = $true

    Write-Host 'U Unlocked local Vulkan runtime build' -ForegroundColor Cyan
    Write-Host 'Validating the selected game folders...'
    $game = Resolve-TitleFolder -Path $GameDirectory -ExpectedTitleId '0005000010144F00' -Label 'Base game'
    $update = Resolve-TitleFolder -Path $UpdateDirectory -ExpectedTitleId '0005000E10144F00' -Label 'Game update'

    Write-Host "Base game: $($game.Folder)"
    Write-Host "Update:    $($update.Folder)"
    Write-Host "Base RPX:  $($game.Size) bytes"
    Write-Host "Update RPX: $($update.Size) bytes"

    $releaseAssetRoot = $null
    Remove-Item Env:\U_UNLOCKED_PREBUILT_RUNTIME_DIR -ErrorAction SilentlyContinue
    Remove-Item Env:\U_UNLOCKED_PREBUILT_LAUNCHER -ErrorAction SilentlyContinue
    Remove-Item Env:\U_UNLOCKED_PREBUILT_WUA_EXTRACTOR -ErrorAction SilentlyContinue
    if (-not [string]::IsNullOrWhiteSpace($LauncherDirectory)) {
        $packageRoot = [System.IO.Path]::GetFullPath($LauncherDirectory)
        $buildKitRoot = Join-Path $packageRoot 'build-kit'
        if (Test-Path -LiteralPath (Join-Path $buildKitRoot 'build-kit-manifest.json') -PathType Leaf) {
            foreach ($asset in @('prebuilt-dependencies.zip', 'cafe-recomp.exe', 'dependency-bundle.zip', 'toolchain-bundle.zip', 'prebuilt-runtime.zip', 'source-revision.txt')) {
                Assert-BuildKitFile -BuildKitDirectory $buildKitRoot -FileName $asset
            }
            $releaseAssetRoot = $buildKitRoot
            foreach ($asset in @('U Unlocked.exe', 'wua_extract.exe')) {
                Assert-RootPackageFile -PackageDirectory $packageRoot -BuildKitDirectory $buildKitRoot -FileName $asset
            }
            $env:U_UNLOCKED_PREBUILT_LAUNCHER = Join-Path $packageRoot 'U Unlocked.exe'
            $env:U_UNLOCKED_PREBUILT_WUA_EXTRACTOR = Join-Path $packageRoot 'wua_extract.exe'
        }
    }
    Write-Host 'Installing build prerequisites and preparing pinned dependencies. The first build can take a while.'
    Write-Host 'Game files remain in their selected locations. Generated code and executables stay on this PC.'

    if ($releaseAssetRoot) {
        $toolchainBundlePath = Join-Path $releaseAssetRoot 'toolchain-bundle.zip'
        $env:U_UNLOCKED_TOOLCHAIN_BUNDLE = $toolchainBundlePath
        $bundlePath = Join-Path $releaseAssetRoot 'dependency-bundle.zip'
        $env:U_UNLOCKED_DEPENDENCY_BUNDLE = $bundlePath
        Write-Host "Using the bundled pinned dependency sources: $bundlePath" -ForegroundColor Green
    } else {
        Remove-Item Env:\U_UNLOCKED_TOOLCHAIN_BUNDLE -ErrorAction SilentlyContinue
        Remove-Item Env:\U_UNLOCKED_DEPENDENCY_BUNDLE -ErrorAction SilentlyContinue
    }

    & $environmentSetup
    if ($LASTEXITCODE -ne 0) { throw "Windows build environment setup failed with exit code $LASTEXITCODE." }

    # Child PowerShell processes cannot modify this process's PATH. Resolve the
    # just-installed tools again here before verify-checkout and the build scripts.
    $toolchainRoot = Get-UUnlockedToolchainRoot
    $cmake = Find-BuildTool 'cmake.exe' @((Join-Path $toolchainRoot 'cmake\bin\cmake.exe'), "$env:ProgramFiles\CMake\bin\cmake.exe", "$env:LOCALAPPDATA\Programs\CMake\bin\cmake.exe")
    $ninja = Find-BuildTool 'ninja.exe' @((Join-Path $toolchainRoot 'ninja\ninja.exe'), "$env:LOCALAPPDATA\Microsoft\WinGet\Links\ninja.exe", "$env:LOCALAPPDATA\Programs\Ninja-build\Ninja\ninja.exe")
    $python = Find-BuildTool 'python.exe' @((Join-Path $toolchainRoot 'python\python.exe'), "$env:LOCALAPPDATA\Programs\Python\Python312\python.exe", "$env:ProgramFiles\Python312\python.exe")
    $compilerBin = Join-Path $toolchainRoot 'llvm-mingw\bin'
    if (-not $cmake -or -not $ninja -or -not $python -or -not (Test-Path -LiteralPath (Join-Path $compilerBin 'x86_64-w64-mingw32-clang++.exe') -PathType Leaf)) {
        throw 'The pinned CMake, Ninja, Python, or llvm-mingw compiler could not be located after bootstrap.'
    }
    $env:PATH = (@((Split-Path -Parent $python), (Split-Path -Parent $cmake), (Split-Path -Parent $ninja), $compilerBin, "$env:SystemRoot\System32") + @($env:PATH -split ';' | Where-Object { $_ })) -join ';'
    Write-Host 'Installing and verifying all pinned source dependencies from the bundled archive...' -ForegroundColor Cyan
    & $python (Join-Path $repoRoot 'engine\tools\setup_deps.py')
    if ($LASTEXITCODE -ne 0) { throw 'Pinned source dependency installation failed; the release bundle may be incomplete.' }
    try {
        $memoryGb = [math]::Floor((Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop).TotalPhysicalMemory / 1GB)
    } catch {
        $memoryGb = 8
    }
    $env:U_UNLOCKED_BUILD_JOBS = if ($memoryGb -ge 32) { '4' } elseif ($memoryGb -ge 12) { '2' } else { '1' }

    if ($releaseAssetRoot) {
        $prebuiltArchive = Join-Path $releaseAssetRoot 'prebuilt-dependencies.zip'
        & $prebuiltDependencyInstaller -ArchivePath $prebuiltArchive -EngineRoot (Join-Path $repoRoot 'engine')
        if ($LASTEXITCODE -ne 0) { throw 'Precompiled dependency verification or installation failed.' }

        $runtimeArchive = Join-Path $releaseAssetRoot 'prebuilt-runtime.zip'
        $sourceRevision = (Get-Content -LiteralPath (Join-Path $releaseAssetRoot 'source-revision.txt') -Raw).Trim()
        & $prebuiltRuntimeInstaller -ArchivePath $runtimeArchive -EngineRoot (Join-Path $repoRoot 'engine') -ExpectedSourceRevision $sourceRevision
        if ($LASTEXITCODE -ne 0) { throw 'Precompiled generic runtime verification or installation failed.' }
        $env:U_UNLOCKED_PREBUILT_RUNTIME_DIR = Join-Path (Join-Path $repoRoot 'engine') 'build-prebuilt-runtime'
    }

    # Keep Ninja's object files outside the replaceable release folder. The key
    # follows the launcher installation path, so updating the release in place
    # reuses unchanged generated game objects instead of compiling everything again.
    $cacheIdentityPath = if ([string]::IsNullOrWhiteSpace($LauncherDirectory)) {
        $repoRoot
    } else {
        [IO.Path]::GetFullPath($LauncherDirectory)
    }
    $identityBytes = [Text.Encoding]::UTF8.GetBytes($cacheIdentityPath.ToUpperInvariant())
    $identitySha = [Security.Cryptography.SHA256]::Create()
    try {
        $cacheIdentity = [BitConverter]::ToString($identitySha.ComputeHash($identityBytes)).Replace('-', '').ToLowerInvariant().Substring(0, 20)
    } finally {
        $identitySha.Dispose()
    }
    $localCacheRoot = if ($env:LOCALAPPDATA) { $env:LOCALAPPDATA } else { $env:TEMP }
    $cacheDirectory = Join-Path $localCacheRoot (Join-Path 'U Unlocked\BuildCache' $cacheIdentity)
    $engineBuildDirectory = Join-Path $cacheDirectory 'engine-build'
    New-Item -ItemType Directory -Force -Path $cacheDirectory | Out-Null
    $legacyGeneratedCache = Join-Path $localCacheRoot 'U Unlocked\BuildCache\generated'
    $newGeneratedCache = Join-Path $cacheDirectory 'generated'
    if (-not (Test-Path -LiteralPath $newGeneratedCache -PathType Container) -and
        (Test-Path -LiteralPath $legacyGeneratedCache -PathType Container)) {
        Copy-Item -LiteralPath $legacyGeneratedCache -Destination $newGeneratedCache -Recurse -Force
        Write-Host 'Migrated the existing verified generated-code cache into this installation’s persistent cache.' -ForegroundColor Green
    }

    $toolchainManifestPath = Join-Path $toolchainRoot 'toolchain-manifest.json'
    $compilerPath = Join-Path $toolchainRoot 'llvm-mingw\bin\x86_64-w64-mingw32-clang++.exe'
    if (Test-Path -LiteralPath $toolchainManifestPath -PathType Leaf) {
        $toolchainManifest = Get-Content -LiteralPath $toolchainManifestPath -Raw | ConvertFrom-Json
        if ($toolchainManifest.files -is [array] -and [int]$toolchainManifest.file_count -eq $toolchainManifest.files.Count) {
            $toolchainFileIdentity = @($toolchainManifest.files | ForEach-Object { '{0}:{1}:{2}' -f $_.path, $_.sha256, $_.length })
            $toolchainIdentityJson = [ordered]@{
                llvm_mingw_version = $toolchainManifest.llvm_mingw_version
                cmake_version = $toolchainManifest.cmake_version
                ninja_version = $toolchainManifest.ninja_version
                python_version = $toolchainManifest.python_version
                files = $toolchainFileIdentity
            } | ConvertTo-Json -Depth 8 -Compress
            $toolchainIdentityBytes = [Text.Encoding]::UTF8.GetBytes($toolchainIdentityJson)
            $toolchainIdentitySha = [Security.Cryptography.SHA256]::Create()
            try { $toolchainFingerprint = [BitConverter]::ToString($toolchainIdentitySha.ComputeHash($toolchainIdentityBytes)).Replace('-', '').ToLowerInvariant() }
            finally { $toolchainIdentitySha.Dispose() }
        } else {
            $toolchainFingerprint = (Get-FileHash -LiteralPath $toolchainManifestPath -Algorithm SHA256).Hash.ToLowerInvariant()
        }
    } elseif (Test-Path -LiteralPath $compilerPath -PathType Leaf) {
        $toolchainFingerprint = (Get-FileHash -LiteralPath $compilerPath -Algorithm SHA256).Hash.ToLowerInvariant()
    } else {
        throw 'Cannot fingerprint the pinned Windows compiler for the persistent build cache.'
    }
    $dependencyLock = Join-Path $repoRoot 'engine\dependencies.lock.json'
    $dependencyRecipe = Join-Path $repoRoot 'engine\tools\windows\build-deps.ps1'
    if ($releaseAssetRoot) {
        $dependencySourceManifestHash = Get-ZipEntrySha256 -ArchivePath (Join-Path $releaseAssetRoot 'dependency-bundle.zip') -EntryName 'bundle/dependency-manifest.json'
        $dependencyPrefixManifestHash = Get-ZipEntrySha256 -ArchivePath (Join-Path $releaseAssetRoot 'prebuilt-dependencies.zip') -EntryName 'prebuilt-manifest.json'
        $dependencyBytes = [Text.Encoding]::UTF8.GetBytes($dependencySourceManifestHash + [Environment]::NewLine + $dependencyPrefixManifestHash)
    } else {
        $dependencyBytes = [Text.Encoding]::UTF8.GetBytes(
            (Get-FileHash -LiteralPath $dependencyLock -Algorithm SHA256).Hash.ToLowerInvariant() +
            (Get-FileHash -LiteralPath $dependencyRecipe -Algorithm SHA256).Hash.ToLowerInvariant()
        )
    }
    $dependencySha = [Security.Cryptography.SHA256]::Create()
    try { $dependencyFingerprint = [BitConverter]::ToString($dependencySha.ComputeHash($dependencyBytes)).Replace('-', '').ToLowerInvariant() }
    finally { $dependencySha.Dispose() }
    $runtimeManifestPath = Join-Path $repoRoot 'engine\build-prebuilt-runtime\runtime-manifest.json'
    if ($releaseAssetRoot -and (Test-Path -LiteralPath $runtimeManifestPath -PathType Leaf)) {
        $runtimeManifest = Get-Content -LiteralPath $runtimeManifestPath -Raw | ConvertFrom-Json
        $runtimeFingerprintData = [ordered]@{
            compiler_sha256 = $runtimeManifest.compiler_sha256
            objects = @($runtimeManifest.objects | ForEach-Object { '{0}:{1}' -f $_.path, $_.sha256 })
            libraries = @($runtimeManifest.libraries | ForEach-Object { '{0}:{1}' -f $_.path, $_.sha256 })
            host_variants = @($runtimeManifest.host_variants | ForEach-Object {
                $variant = $_.variant
                @($_.objects | ForEach-Object { '{0}/{1}:{2}' -f $variant, $_.path, $_.sha256 })
            })
        }
        $runtimeFingerprintJson = $runtimeFingerprintData | ConvertTo-Json -Depth 8 -Compress
        $runtimeBytes = [Text.Encoding]::UTF8.GetBytes($runtimeFingerprintJson)
        $runtimeSha = [Security.Cryptography.SHA256]::Create()
        try { $runtimeFingerprint = [BitConverter]::ToString($runtimeSha.ComputeHash($runtimeBytes)).Replace('-', '').ToLowerInvariant() }
        finally { $runtimeSha.Dispose() }
    } else {
        $runtimeFingerprint = 'source-built-runtime'
    }
    $cmakeVersion = (& $cmake --version | Select-Object -First 1).Trim()
    $ninjaVersion = (& $ninja --version | Out-String).Trim()
    $sourceRevision = if ($releaseAssetRoot) { (Get-Content -LiteralPath (Join-Path $releaseAssetRoot 'source-revision.txt') -Raw).Trim() } else { 'working-tree' }
    $cacheFingerprintData = [ordered]@{
        schema_version = 1
        engine_source_root = [IO.Path]::GetFullPath((Join-Path $repoRoot 'engine'))
        compiler_sha256 = (Get-FileHash -LiteralPath $compilerPath -Algorithm SHA256).Hash.ToLowerInvariant()
        toolchain_manifest_sha256 = $toolchainFingerprint
        dependency_fingerprint = $dependencyFingerprint
        runtime_fingerprint = $runtimeFingerprint
        cmake_version = $cmakeVersion
        ninja_version = $ninjaVersion
        configuration = 'Release'
        linker_flags = '-static'
        generated_architectures = @('x86-64-v3', 'x86-64-v2')
    }
    $cacheFingerprintJson = $cacheFingerprintData | ConvertTo-Json -Depth 8 -Compress
    $cacheFingerprintBytes = [Text.Encoding]::UTF8.GetBytes($cacheFingerprintJson)
    $cacheFingerprintSha = [Security.Cryptography.SHA256]::Create()
    try {
        $cacheFingerprint = [BitConverter]::ToString($cacheFingerprintSha.ComputeHash($cacheFingerprintBytes)).Replace('-', '').ToLowerInvariant()
    } finally {
        $cacheFingerprintSha.Dispose()
    }
    $cacheStatePath = Join-Path $cacheDirectory 'build-cache-fingerprint.json'
    $cacheReusable = $false
    if ((Test-Path -LiteralPath $cacheStatePath -PathType Leaf) -and
        (Test-Path -LiteralPath $engineBuildDirectory -PathType Container)) {
        try {
            $previousCacheState = Get-Content -LiteralPath $cacheStatePath -Raw | ConvertFrom-Json
            $cacheReusable = $previousCacheState.schema_version -eq 1 -and
                $previousCacheState.fingerprint_sha256 -eq $cacheFingerprint -and
                $previousCacheState.engine_source_root -eq $cacheFingerprintData.engine_source_root
        } catch {
            $cacheReusable = $false
        }
    }
    if (-not $cacheReusable -and (Test-Path -LiteralPath $engineBuildDirectory -PathType Container)) {
        Write-Host 'Build toolchain/dependency fingerprint changed; safely rebuilding the local CMake object cache.' -ForegroundColor Yellow
        Remove-Item -LiteralPath $engineBuildDirectory -Recurse -Force
    } elseif ($cacheReusable) {
        Write-Host 'Reusing the persistent local CMake/Ninja object cache; changed source files will rebuild incrementally.' -ForegroundColor Green
    }
    New-Item -ItemType Directory -Force -Path $engineBuildDirectory | Out-Null
    $cacheState = [ordered]@{
        schema_version = 1
        fingerprint_sha256 = $cacheFingerprint
        engine_source_root = $cacheFingerprintData.engine_source_root
        source_revision = $sourceRevision
        updated_utc = [DateTime]::UtcNow.ToString('o')
    }
    $cacheStateTemp = "$cacheStatePath.tmp"
    $cacheState | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $cacheStateTemp -Encoding UTF8
    Move-Item -LiteralPath $cacheStateTemp -Destination $cacheStatePath -Force
    $env:U_UNLOCKED_ENGINE_BUILD_DIR = $engineBuildDirectory
    $env:U_UNLOCKED_BUILD_CACHE_ROOT = $cacheDirectory
    Write-Host "Persistent build cache: $engineBuildDirectory"

    if ($releaseAssetRoot) {
        $prebuiltRecompiler = Join-Path $releaseAssetRoot 'cafe-recomp.exe'
        $recompilerDirectory = Join-Path $engineBuildDirectory 'recomp'
        New-Item -ItemType Directory -Force -Path $recompilerDirectory | Out-Null
        Copy-Item -LiteralPath $prebuiltRecompiler -Destination (Join-Path $recompilerDirectory 'cafe-recomp.exe') -Force
        Write-Host 'Installed verified precompiled dependencies, runtime libraries, host objects, and the release-matched recompiler.' -ForegroundColor Green
    }


    & $verifyScript
    if ($LASTEXITCODE -ne 0) { throw "Source/toolchain verification failed with exit code $LASTEXITCODE." }

    & $buildEntry -Rpx $update.Rpx -BaseRpx $game.Rpx
    if ($LASTEXITCODE -ne 0) { throw "The native Vulkan build failed with exit code $LASTEXITCODE." }

    $playDirectory = Join-Path $repoRoot 'Play'
    $requiredOutputs = @(
        "U Unlocked.exe",
        "smash.exe",
        "smash-compat.exe",
        "smash-base.exe",
        "smash-base-compat.exe",
        "wua_extract.exe",
        "title-logo.png"
    )
    $missing = @($requiredOutputs | Where-Object {
        -not (Test-Path -LiteralPath (Join-Path $playDirectory $_) -PathType Leaf)
    })
    if ($missing.Count -gt 0) {
        $missingText = $missing -join ", "
        throw "Build returned without all required files. Missing: $missingText."
    }

    if (-not [string]::IsNullOrWhiteSpace($LauncherDirectory)) {
        $launcherRoot = [System.IO.Path]::GetFullPath($LauncherDirectory)
        if (-not (Test-Path -LiteralPath $launcherRoot -PathType Container)) {
            throw "Launcher directory does not exist: $launcherRoot"
        }

        $runtimeStage = Join-Path $launcherRoot ".runtime-staging"
        $runtimeTarget = Join-Path $launcherRoot "runtime"
        $runtimeBackup = Join-Path $launcherRoot ".runtime-previous"
        $runtimeRequired = @(
            "smash.exe", "smash-compat.exe", "smash-base.exe",
            "smash-base-compat.exe", "wua_extract.exe", "title-logo.png"
        )

        # Recover the previous runtime before preparing a replacement. This
        # preserves the only working copy if an earlier activation was interrupted.
        Recover-RuntimeActivation -Stage $runtimeStage -Target $runtimeTarget -Backup $runtimeBackup -RequiredFiles $runtimeRequired

        New-Item -ItemType Directory -Force -Path $runtimeStage | Out-Null
        foreach ($file in Get-ChildItem -LiteralPath $playDirectory -File) {
            if ($file.Name -eq "U Unlocked.exe") { continue }
            Copy-Item -LiteralPath $file.FullName -Destination $runtimeStage -Force
        }

        # Rebuilding the runtime must never discard saves, online credentials,
        # user fonts, logs, or display settings from the previous installation.
        foreach ($name in @("save", "online", "fonts", "logs", "cache")) {
            $stagedData = Join-Path $runtimeStage $name
            Copy-PreservedDirectory -Source (Join-Path $runtimeTarget $name) -Destination $stagedData
            if (-not (Test-Path -LiteralPath $stagedData -PathType Container)) {
                Copy-PreservedDirectory -Source (Join-Path $launcherRoot $name) -Destination $stagedData
            }
        }
        $previousDisplay = Join-Path $runtimeTarget "display.ini"
        if (Test-Path -LiteralPath $previousDisplay -PathType Leaf) {
            Copy-Item -LiteralPath $previousDisplay -Destination $runtimeStage -Force
        } else {
            $launcherDisplay = Join-Path $launcherRoot "display.ini"
            if (Test-Path -LiteralPath $launcherDisplay -PathType Leaf) {
                Copy-Item -LiteralPath $launcherDisplay -Destination $runtimeStage -Force
            }
        }

        Activate-StagedRuntime -Stage $runtimeStage -Target $runtimeTarget -Backup $runtimeBackup -RequiredFiles $runtimeRequired
        Write-Host "Local game runtime activated: $runtimeTarget" -ForegroundColor Green
    }

    $launcherOutput = Join-Path $playDirectory "U Unlocked.exe"
    Write-Host "Build verified. Launcher: $launcherOutput" -ForegroundColor Green
    Write-Host "Build log: $logPath"
} catch {
    Write-Host "BUILD FAILED: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host "Build log: $logPath"
    throw
} finally {
    if ($transcriptStarted) {
        Stop-Transcript | Out-Null
    }
}
