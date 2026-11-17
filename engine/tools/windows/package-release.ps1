# Packages the launcher, bounded WUA utility, portable toolchain, and generic precompiled runtime.
# Game-specific generated code and executables are built locally from each user's own game files.
# User saves, console files, keys, mods, caches, and settings are never packaged.
[CmdletBinding()]
param(
    [string]$Version
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))
$engineRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$launcher = Join-Path $engineRoot 'build\U Unlocked.exe'
$wuaExtractor = Join-Path $engineRoot 'build\wua_extract.exe'
$titleLogo = Join-Path $engineRoot 'runtime\res\title-logo.png'
$prefix = Join-Path $engineRoot 'build-deps\prefix'
$updater = Join-Path $repoRoot 'tools\windows\update-launcher.ps1'
if (-not (Test-Path -LiteralPath $launcher -PathType Leaf)) {
    throw "Launcher build not found: $launcher. Build U Unlocked first."
}
if (-not (Test-Path -LiteralPath $updater -PathType Leaf)) {
    throw "The Windows launcher updater is missing: $updater"
}
if (-not (Test-Path -LiteralPath $wuaExtractor -PathType Leaf)) {
    throw "The bounded WUA extractor is missing: $wuaExtractor"
}
if (-not (Test-Path -LiteralPath $titleLogo -PathType Leaf)) {
    throw "The original U Unlocked title logo is missing: $titleLogo"
}

if ([string]::IsNullOrWhiteSpace($Version)) {
    $main = Get-Content -LiteralPath (Join-Path $engineRoot 'launcher\smash\main.cpp') -Raw
    $match = [regex]::Match($main, 'kVersion\s*=\s*"([^"]+)"')
    if (-not $match.Success) { throw 'Unable to read the launcher version.' }
    $Version = $match.Groups[1].Value
}

$name = "U-Unlocked-v$Version-Windows-Launcher"
$dist = Join-Path $repoRoot 'dist'
$stage = Join-Path $dist $name
$zip = Join-Path $dist "$name.zip"
New-Item -ItemType Directory -Force -Path $dist | Out-Null
Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item -LiteralPath $zip -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force -Path $stage | Out-Null
New-Item -ItemType Directory -Force -Path (Join-Path $stage 'licenses') | Out-Null

# Ship the complete, game-data-free source build kit with the launcher. The kit
# bootstraps its pinned compiler/build tools and compiles game-specific code only
# from the user's local RPX files. Git archive includes tracked source only.
$buildKit = Join-Path $stage 'build-kit'
$buildKitArchive = Join-Path $dist "$name-build-kit-source.zip"
Remove-Item -LiteralPath $buildKitArchive -Force -ErrorAction SilentlyContinue
& git -C $repoRoot archive --format=zip --output=$buildKitArchive HEAD
if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $buildKitArchive -PathType Leaf)) {
    throw 'Unable to create the clean source build kit from the release commit.'
}
Expand-Archive -LiteralPath $buildKitArchive -DestinationPath $buildKit -Force

# The release workflow has already fetched every locked source revision. Package
# those exact, marker-verified trees so first-run builds do not depend on GitHub
# archive downloads or the user's network connection.
# Package the compiled dependency prefix using the same tested packager as CI.
$prebuiltArchive = Join-Path $dist "$name-prebuilt-dependencies.zip"
Remove-Item -LiteralPath $prebuiltArchive -Force -ErrorAction SilentlyContinue
& (Join-Path $engineRoot 'tools\windows\package-prebuilt-dependencies.ps1') -EngineRoot $engineRoot -OutputArchive $prebuiltArchive
if (-not (Test-Path -LiteralPath $prebuiltArchive -PathType Leaf)) {
    throw 'Precompiled dependency archive was not created.'
}
Copy-Item -LiteralPath $prebuiltArchive -Destination (Join-Path $buildKit 'prebuilt-dependencies.zip')
Remove-Item -LiteralPath $prebuiltArchive -Force

# Include the generic PowerPC recompiler built from this exact source revision.
# It contains no game-derived code; the user's RPX files are still processed locally.
$recompiler = Join-Path $engineRoot 'build\recomp\cafe-recomp.exe'
if (-not (Test-Path -LiteralPath $recompiler -PathType Leaf)) {
    throw "The prebuilt local recompiler is missing: $recompiler"
}
Copy-Item -LiteralPath $recompiler -Destination (Join-Path $buildKit 'cafe-recomp.exe')

$dependencyBundle = Join-Path $dist "$name-dependency-bundle.zip"
Remove-Item -LiteralPath $dependencyBundle -Force -ErrorAction SilentlyContinue
$python = Get-Command python.exe -ErrorAction SilentlyContinue
if (-not $python) { throw 'Python is required to package the verified dependency bundle.' }
& $python.Source (Join-Path $engineRoot 'tools\setup_deps.py') --bundle-output $dependencyBundle
if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $dependencyBundle -PathType Leaf)) {
    throw 'Creating the verified dependency bundle failed.'
}

# Install every dependency from the archive into a clean source tree with all
# network traffic deliberately blocked. Missing bundle content must fail here.
$dependencyVerificationRoot = Join-Path $dist ('.dependency-bundle-verification-' + [guid]::NewGuid().ToString('N'))
$dependencyVerificationEngine = Join-Path $dependencyVerificationRoot 'engine'
New-Item -ItemType Directory -Force -Path (Join-Path $dependencyVerificationEngine 'tools') | Out-Null
Copy-Item -LiteralPath (Join-Path $engineRoot 'tools\setup_deps.py') -Destination (Join-Path $dependencyVerificationEngine 'tools\setup_deps.py')
Copy-Item -LiteralPath (Join-Path $engineRoot 'dependencies.lock.json') -Destination (Join-Path $dependencyVerificationEngine 'dependencies.lock.json')
$previousHttpProxy = $env:HTTP_PROXY
$previousHttpsProxy = $env:HTTPS_PROXY
$previousHttpProxyLower = $env:http_proxy
$previousHttpsProxyLower = $env:https_proxy
try {
    $env:HTTP_PROXY = 'http://127.0.0.1:9'
    $env:HTTPS_PROXY = 'http://127.0.0.1:9'
    $env:http_proxy = 'http://127.0.0.1:9'
    $env:https_proxy = 'http://127.0.0.1:9'
    & $python.Source (Join-Path $dependencyVerificationEngine 'tools\setup_deps.py') --bundle-archive $dependencyBundle
    if ($LASTEXITCODE -ne 0) { throw 'The dependency source bundle failed its clean, network-blocked installation test.' }
    $dependencyLockData = Get-Content -LiteralPath (Join-Path $dependencyVerificationEngine 'dependencies.lock.json') -Raw | ConvertFrom-Json
    foreach ($dependency in $dependencyLockData.PSObject.Properties) {
        $installedDependency = Join-Path $dependencyVerificationEngine (Join-Path 'third_party' $dependency.Name)
        $markerPath = Join-Path $installedDependency '.u-unlocked-revision'
        if (-not (Test-Path -LiteralPath $markerPath -PathType Leaf) -or
            (Get-Content -LiteralPath $markerPath -Raw).Trim() -ne [string]$dependency.Value.revision) {
            throw "The dependency bundle did not install the locked $($dependency.Name) revision."
        }
    }
} finally {
    foreach ($proxy in @(
        @{ Name = 'HTTP_PROXY'; Value = $previousHttpProxy },
        @{ Name = 'HTTPS_PROXY'; Value = $previousHttpsProxy },
        @{ Name = 'http_proxy'; Value = $previousHttpProxyLower },
        @{ Name = 'https_proxy'; Value = $previousHttpsProxyLower }
    )) {
        if ([string]::IsNullOrWhiteSpace([string]$proxy.Value)) {
            Remove-Item "Env:\$($proxy.Name)" -ErrorAction SilentlyContinue
        } else {
            Set-Item "Env:\$($proxy.Name)" -Value $proxy.Value
        }
    }
    if (Test-Path -LiteralPath $dependencyVerificationRoot) {
        Remove-Item -LiteralPath $dependencyVerificationRoot -Recurse -Force
    }
}
Copy-Item -LiteralPath $dependencyBundle -Destination (Join-Path $buildKit 'dependency-bundle.zip')
Remove-Item -LiteralPath $dependencyBundle -Force

# Bundle the exact compiler, CMake, Ninja, and Python used by this release build.
# The player no longer needs WinGet or a separate 180 MB compiler download.
$toolchainBundle = Join-Path $dist "$name-toolchain-bundle.zip"
Remove-Item -LiteralPath $toolchainBundle -Force -ErrorAction SilentlyContinue
& (Join-Path $repoRoot 'tools\windows\package-toolchain-bundle.ps1') -OutputArchive $toolchainBundle
if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $toolchainBundle -PathType Leaf)) {
    throw 'Creating the self-contained Windows toolchain bundle failed.'
}
Copy-Item -LiteralPath $toolchainBundle -Destination (Join-Path $buildKit 'toolchain-bundle.zip')

# Test the actual player bootstrap against a clean toolchain root. This must
# install without WinGet, external downloads, or preinstalled developer tools.
$previousToolchainRoot = $env:U_UNLOCKED_TOOLCHAIN_ROOT
$previousToolchainBundle = $env:U_UNLOCKED_TOOLCHAIN_BUNDLE
$toolchainVerificationRoot = Join-Path $dist ('.toolchain-install-verification-' + [guid]::NewGuid().ToString('N'))
try {
    $env:U_UNLOCKED_TOOLCHAIN_ROOT = $toolchainVerificationRoot
    $env:U_UNLOCKED_TOOLCHAIN_BUNDLE = $toolchainBundle
    & (Join-Path $repoRoot 'tools\windows\setup-build-environment.ps1')
    if ($LASTEXITCODE -ne 0) { throw 'The bundled toolchain failed its clean-root player bootstrap test.' }
    foreach ($required in @(
        (Join-Path $toolchainVerificationRoot 'cmake\bin\cmake.exe'),
        (Join-Path $toolchainVerificationRoot 'ninja\ninja.exe'),
        (Join-Path $toolchainVerificationRoot 'python\python.exe'),
        (Join-Path $toolchainVerificationRoot 'llvm-mingw\bin\x86_64-w64-mingw32-clang++.exe')
    )) {
        if (-not (Test-Path -LiteralPath $required -PathType Leaf)) {
            throw "The clean-root toolchain bootstrap did not install: $required"
        }
    }
} finally {
    if ([string]::IsNullOrWhiteSpace($previousToolchainRoot)) {
        Remove-Item Env:\U_UNLOCKED_TOOLCHAIN_ROOT -ErrorAction SilentlyContinue
    } else {
        $env:U_UNLOCKED_TOOLCHAIN_ROOT = $previousToolchainRoot
    }
    if ([string]::IsNullOrWhiteSpace($previousToolchainBundle)) {
        Remove-Item Env:\U_UNLOCKED_TOOLCHAIN_BUNDLE -ErrorAction SilentlyContinue
    } else {
        $env:U_UNLOCKED_TOOLCHAIN_BUNDLE = $previousToolchainBundle
    }
    if (Test-Path -LiteralPath $toolchainVerificationRoot) {
        Remove-Item -LiteralPath $toolchainVerificationRoot -Recurse -Force
    }
}
Remove-Item -LiteralPath $toolchainBundle -Force

# Ship the generic native runtime objects built by CI. These contain no game data;
# the player only compiles the locally generated RPX code and links the targets.
$git = Get-Command git.exe -ErrorAction Stop
$sourceRevision = (& $git.Source -C $repoRoot rev-parse HEAD).Trim()
if ($LASTEXITCODE -ne 0 -or $sourceRevision -notmatch '^[0-9a-fA-F]{40}$') {
    throw 'Unable to record the source revision for the release build kit.'
}
$sourceRevision | Set-Content -LiteralPath (Join-Path $buildKit 'source-revision.txt') -Encoding ASCII

$prebuiltRuntime = Join-Path $dist "$name-prebuilt-runtime.zip"
Remove-Item -LiteralPath $prebuiltRuntime -Force -ErrorAction SilentlyContinue
& (Join-Path $engineRoot 'tools\windows\package-prebuilt-runtime.ps1') -EngineRoot $engineRoot -OutputArchive $prebuiltRuntime
if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $prebuiltRuntime -PathType Leaf)) {
    throw 'Creating the precompiled generic runtime bundle failed.'
}

# Exercise the same hash-checked installer used by players before shipping the archive.
$runtimeVerificationRoot = Join-Path $dist ('.runtime-package-verification-' + [guid]::NewGuid().ToString('N'))
$runtimeVerificationEngine = Join-Path $repoRoot ('.runtime-package-verification-engine-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $runtimeVerificationEngine | Out-Null
try {
    & (Join-Path $repoRoot 'tools\windows\install-prebuilt-runtime.ps1') -ArchivePath $prebuiltRuntime -EngineRoot $runtimeVerificationEngine -ExpectedSourceRevision $sourceRevision
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath (Join-Path $runtimeVerificationEngine 'build-prebuilt-runtime\runtime-manifest.json') -PathType Leaf)) {
        throw 'The prebuilt runtime archive failed its clean-directory installation test.'
    }

    # Configure and link all four CPU/game combinations against the imported
    # runtime objects and static libraries, proving players do not rebuild them.
    $previousRuntimeDirectory = $env:U_UNLOCKED_PREBUILT_RUNTIME_DIR
    $env:U_UNLOCKED_PREBUILT_RUNTIME_DIR = Join-Path $runtimeVerificationEngine 'build-prebuilt-runtime'
    . (Join-Path $repoRoot 'tools\windows\toolchain-path.ps1')
    $toolchainRoot = Get-UUnlockedToolchainRoot
    $compilerBin = Join-Path $toolchainRoot 'llvm-mingw\bin'
    $env:PATH = "$compilerBin;$env:PATH"
    try {
        $runtimeVerificationBuild = Join-Path $runtimeVerificationRoot 'cmake-build'
        $updateFixture = (Resolve-Path (Join-Path $engineRoot 'tests\cmake_game_targets\fixtures\update')).Path
        $baseFixture = (Resolve-Path (Join-Path $engineRoot 'tests\cmake_game_targets\fixtures\base')).Path
        & cmake -S $engineRoot -B $runtimeVerificationBuild -G Ninja -DCMAKE_BUILD_TYPE=Release -DCMAKE_C_COMPILER=x86_64-w64-mingw32-clang -DCMAKE_CXX_COMPILER=x86_64-w64-mingw32-clang++ -DCMAKE_RC_COMPILER=x86_64-w64-mingw32-windres -DCMAKE_EXE_LINKER_FLAGS=-static "-DSMASH_GENERATED_DIR=$updateFixture" "-DSMASH_BASE_GENERATED_DIR=$baseFixture"
        if ($LASTEXITCODE -ne 0) { throw 'CMake could not configure the installed prebuilt runtime and library targets.' }
        & ninja -j 2 -C $runtimeVerificationBuild smash_update_v3 smash_update_v2 smash_base_v3 smash_base_v2
        if ($LASTEXITCODE -ne 0) { throw 'The four game targets failed to link against the prebuilt runtime bundle.' }
    } finally {
        if ([string]::IsNullOrWhiteSpace($previousRuntimeDirectory)) {
            Remove-Item Env:\U_UNLOCKED_PREBUILT_RUNTIME_DIR -ErrorAction SilentlyContinue
        } else {
            $env:U_UNLOCKED_PREBUILT_RUNTIME_DIR = $previousRuntimeDirectory
        }
    }
} finally {
    if (Test-Path -LiteralPath $runtimeVerificationRoot) {
        Remove-Item -LiteralPath $runtimeVerificationRoot -Recurse -Force
    }
    if (Test-Path -LiteralPath $runtimeVerificationEngine) {
        Remove-Item -LiteralPath $runtimeVerificationEngine -Recurse -Force
    }
}
Copy-Item -LiteralPath $prebuiltRuntime -Destination (Join-Path $buildKit 'prebuilt-runtime.zip')
Remove-Item -LiteralPath $prebuiltRuntime -Force

foreach ($requiredBuildFile in @('tools\windows\build-from-library.ps1', 'tools\windows\setup-build-environment.ps1', 'tools\windows\toolchain-path.ps1', 'tools\windows\install-prebuilt-dependencies.ps1', 'engine\tools\windows\package-prebuilt-dependencies.ps1', 'engine\tools\setup_deps.py', 'engine\dependencies.lock.json', 'tools\windows\package-toolchain-bundle.ps1', 'engine\tools\windows\package-prebuilt-runtime.ps1', 'tools\windows\install-prebuilt-runtime.ps1', 'LICENSES\NINJA-APACHE-2.0.txt')) {
    if (-not (Test-Path -LiteralPath (Join-Path $buildKit $requiredBuildFile) -PathType Leaf)) {
        throw "The embedded build kit is incomplete: $requiredBuildFile"
    }
}

# Bind the player assets to the exact build-kit archive. The outer release
# manifest authenticates build-kit.zip; this inner manifest lets the player
# re-check each prebuilt asset immediately before using it.
$buildKitAssets = @(
    @{ name = 'prebuilt-dependencies.zip'; path = (Join-Path $buildKit 'prebuilt-dependencies.zip') },
    @{ name = 'cafe-recomp.exe'; path = (Join-Path $buildKit 'cafe-recomp.exe') },
    @{ name = 'dependency-bundle.zip'; path = (Join-Path $buildKit 'dependency-bundle.zip') },
    @{ name = 'toolchain-bundle.zip'; path = (Join-Path $buildKit 'toolchain-bundle.zip') },
    @{ name = 'prebuilt-runtime.zip'; path = (Join-Path $buildKit 'prebuilt-runtime.zip') },
    @{ name = 'source-revision.txt'; path = (Join-Path $buildKit 'source-revision.txt') },
    @{ name = 'U Unlocked.exe'; path = $launcher },
    @{ name = 'wua_extract.exe'; path = $wuaExtractor }
)
$buildKitManifest = [ordered]@{
    schema_version = 1
    version = $Version
    files = @(
        foreach ($asset in $buildKitAssets) {
            if (-not (Test-Path -LiteralPath $asset.path -PathType Leaf)) {
                throw "A required release build-kit asset is missing: $($asset.name)"
            }
            [ordered]@{
                name = $asset.name
                sha256 = (Get-FileHash -LiteralPath $asset.path -Algorithm SHA256).Hash.ToLowerInvariant()
            }
        }
    )
}
$buildKitManifest | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $buildKit 'build-kit-manifest.json') -Encoding UTF8

Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem
Remove-Item -LiteralPath $buildKitArchive -Force -ErrorAction SilentlyContinue
[IO.Compression.ZipFile]::CreateFromDirectory($buildKit, $buildKitArchive, [IO.Compression.CompressionLevel]::Optimal, $false)
if (-not (Test-Path -LiteralPath $buildKitArchive -PathType Leaf)) {
    throw 'The complete source and prebuilt build-kit archive was not created.'
}
Copy-Item -LiteralPath $buildKitArchive -Destination (Join-Path $stage 'build-kit.zip')
Remove-Item -LiteralPath $buildKitArchive -Force

Copy-Item -LiteralPath $launcher -Destination $stage
Copy-Item -LiteralPath $updater -Destination $stage
Copy-Item -LiteralPath $wuaExtractor -Destination $stage
Copy-Item -LiteralPath $titleLogo -Destination $stage
$dllDirectory = Join-Path $prefix 'bin'
if (-not (Test-Path -LiteralPath $dllDirectory -PathType Container)) {
    throw "Launcher dependency directory is missing: $dllDirectory"
}
$dlls = @(Get-ChildItem -LiteralPath $dllDirectory -Filter '*.dll' -File)
if ($dlls.Count -eq 0) { throw 'No runtime DLLs were found beside the build dependencies.' }
foreach ($dll in $dlls) { Copy-Item -LiteralPath $dll.FullName -Destination $stage }

# The updater only replaces these explicitly listed launcher files. It never
# infers install targets from arbitrary archive paths.
$packageFiles = @(
    Get-ChildItem -LiteralPath $stage -File |
        Where-Object { $_.Name -eq 'U Unlocked.exe' -or $_.Name -eq 'update-launcher.ps1' -or $_.Name -eq 'wua_extract.exe' -or $_.Name -eq 'title-logo.png' -or $_.Name -eq 'build-kit.zip' -or $_.Extension -eq '.dll' } |
        Sort-Object Name
)
if (-not ($packageFiles | Where-Object { $_.Name -eq 'U Unlocked.exe' })) {
    throw 'The launcher executable is missing from the package.'
}
if (-not ($packageFiles | Where-Object { $_.Name -eq 'wua_extract.exe' })) {
    throw 'The bounded WUA extractor is missing from the package.'
}
if (-not ($packageFiles | Where-Object { $_.Name -eq 'title-logo.png' })) {
    throw 'The original U Unlocked title logo is missing from the package.'
}
$manifest = [ordered]@{
    schema_version = 1
    version = $Version
    files = @(
        foreach ($file in $packageFiles) {
            [ordered]@{
                name = $file.Name
                sha256 = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
            }
        }
    )
}
$manifest | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $stage 'package-manifest.json') -Encoding UTF8

Copy-Item -LiteralPath (Join-Path $repoRoot 'README.md') -Destination $stage
Copy-Item -LiteralPath (Join-Path $repoRoot 'docs\THIRD_PARTY_NOTICES.md') -Destination $stage
Copy-Item -LiteralPath (Join-Path $repoRoot 'LICENSES\RECOMPILATION-MIT-LICENSE.txt') -Destination (Join-Path $stage 'licenses')

$thirdParty = Join-Path $engineRoot 'third_party'
$licenseMap = @{
    'SDL3.txt' = 'SDL\LICENSE.txt'
    'Vulkan-Headers.txt' = 'Vulkan-Headers\LICENSE.md'
    'shaderc.txt' = 'shaderc\LICENSE'
    'glslang.txt' = 'glslang\LICENSE.txt'
    'SPIRV-Tools.txt' = 'spirv-tools\LICENSE'
    'SPIRV-Headers.txt' = 'spirv-headers\LICENSE'
    'zlib.txt' = 'zlib\LICENSE'
    'zstd.txt' = 'zstd\LICENSE'
    'ZArchive.txt' = 'ZArchive\LICENSE'
    'addrlib.txt' = 'addrlib\LICENSE'
    'Cemu-NEX-MPL-2.0.txt' = 'cemu_nex\LICENSE.txt'
}
foreach ($entry in $licenseMap.GetEnumerator()) {
    $source = Join-Path $thirdParty $entry.Value
    if (-not (Test-Path -LiteralPath $source -PathType Leaf)) {
        throw "A required third-party licence is missing: $source"
    }
    Copy-Item -LiteralPath $source -Destination (Join-Path $stage "licenses\$($entry.Key)")
}
Copy-Item -Recurse -LiteralPath (Join-Path $thirdParty 'cemu_nex') -Destination (Join-Path $stage 'licenses\cemu_nex-source')
@'
stb_image and stb_truetype (Sean Barrett): public domain or MIT, at your choice; see the headers in the source repository.
'@ | Set-Content -LiteralPath (Join-Path $stage 'licenses\stb.txt') -Encoding utf8

@'
This package contains the U Unlocked launcher, its bounded WUA extraction utility, and the complete source build kit.

Select your base-game and update folders in the launcher, then choose BUILD RUNTIME (or select PLAY when no runtime has been built). The launcher runs the included build kit, which installs the precompiled third-party libraries, generic recompiler, and pinned Windows compiler/build tools supplied with this release. It reuses the precompiled native runtime and compiles only game-specific code from your own legally obtained game files, then links the four local game executables.

No Nintendo game data, console keys, saves, generated recompiled code, or game executable is included. Generated game code and executables remain on this PC.
'@ | Set-Content -LiteralPath (Join-Path $stage 'RUNTIME-BUILD-REQUIRED.txt') -Encoding utf8

$tar = Join-Path $env:SystemRoot 'System32\tar.exe'
if (-not (Test-Path -LiteralPath $tar -PathType Leaf)) { throw "tar.exe was not found: $tar" }
# The updater expects package-manifest.json and each binary at the ZIP root.
# Archiving the containing directory would add a top-level folder and make a
# correctly signed release impossible to install.
$archiveEntries = @(Get-ChildItem -LiteralPath $stage -Force | ForEach-Object { $_.Name })
if ($archiveEntries.Count -eq 0) { throw 'The launcher package staging directory is empty.' }
& $tar -a -cf $zip -C $stage @archiveEntries
if ($LASTEXITCODE -ne 0) { throw "Launcher archive creation failed with exit code $LASTEXITCODE." }
$archiveHash = (Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash.ToLowerInvariant()
"$archiveHash  $([System.IO.Path]::GetFileName($zip))" |
    Set-Content -LiteralPath "$zip.sha256" -Encoding ASCII
Remove-Item -LiteralPath $stage -Recurse -Force
Write-Host "Launcher package created: $zip" -ForegroundColor Green
Write-Host "SHA-256 checksum created: $zip.sha256" -ForegroundColor Green
