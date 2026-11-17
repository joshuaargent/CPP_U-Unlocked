# Packages the redistributable launcher and bounded WUA utility; no game runtime or user data.
# Game runtime binaries and generated code are deliberately excluded: each user builds those locally
# from their own game files. User saves, console files, keys, mods, caches, and settings are never packaged.
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
Remove-Item -LiteralPath $toolchainBundle -Force

# Ship the generic native runtime objects built by CI. These contain no game data;
# the player only compiles the locally generated RPX code and links the targets.
$prebuiltRuntime = Join-Path $dist "$name-prebuilt-runtime.zip"
Remove-Item -LiteralPath $prebuiltRuntime -Force -ErrorAction SilentlyContinue
& (Join-Path $engineRoot 'tools\windows\package-prebuilt-runtime.ps1') -EngineRoot $engineRoot -OutputArchive $prebuiltRuntime
if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $prebuiltRuntime -PathType Leaf)) {
    throw 'Creating the precompiled generic runtime bundle failed.'
}
Copy-Item -LiteralPath $prebuiltRuntime -Destination (Join-Path $buildKit 'prebuilt-runtime.zip')
Remove-Item -LiteralPath $prebuiltRuntime -Force

$git = Get-Command git.exe -ErrorAction Stop
$sourceRevision = (& $git.Source -C $repoRoot rev-parse HEAD).Trim()
if ($LASTEXITCODE -ne 0 -or $sourceRevision -notmatch '^[0-9a-fA-F]{40}$') {
    throw 'Unable to record the source revision for the release build kit.'
}
$sourceRevision | Set-Content -LiteralPath (Join-Path $buildKit 'source-revision.txt') -Encoding ASCII

foreach ($requiredBuildFile in @('tools\windows\build-from-library.ps1', 'tools\windows\setup-build-environment.ps1', 'tools\windows\toolchain-path.ps1', 'tools\windows\install-prebuilt-dependencies.ps1', 'engine\tools\windows\package-prebuilt-dependencies.ps1', 'engine\tools\setup_deps.py', 'engine\dependencies.lock.json', 'tools\windows\package-toolchain-bundle.ps1', 'engine\tools\windows\package-prebuilt-runtime.ps1', 'tools\windows\install-prebuilt-runtime.ps1')) {
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

Select your base-game and update folders in the launcher, then choose BUILD RUNTIME (or select PLAY when no runtime has been built). The launcher runs the included build kit, which installs the precompiled third-party libraries, generic recompiler, and pinned Windows compiler/build tools supplied with this release. It compiles the native runtime and game-specific code that must be built from your own legally obtained game files.

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
