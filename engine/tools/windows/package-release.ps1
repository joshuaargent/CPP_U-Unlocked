# Packages the redistributable U Unlocked launcher only.
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
$prefix = Join-Path $engineRoot 'build-deps\prefix'
if (-not (Test-Path -LiteralPath $launcher -PathType Leaf)) {
    throw "Launcher build not found: $launcher. Build U Unlocked first."
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

Copy-Item -LiteralPath $launcher -Destination $stage
$dllDirectory = Join-Path $prefix 'bin'
if (-not (Test-Path -LiteralPath $dllDirectory -PathType Container)) {
    throw "Launcher dependency directory is missing: $dllDirectory"
}
$dlls = @(Get-ChildItem -LiteralPath $dllDirectory -Filter '*.dll' -File)
if ($dlls.Count -eq 0) { throw 'No runtime DLLs were found beside the build dependencies.' }
foreach ($dll in $dlls) { Copy-Item -LiteralPath $dll.FullName -Destination $stage }

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
This package contains the U Unlocked launcher only.

The game runtime is built locally for each user from their own legally obtained game files.
No Nintendo game data, console keys, saves, generated recompiled code, or game executable is included.
Clone the U Unlocked source repository and follow the README build instructions to build your local runtime.
'@ | Set-Content -LiteralPath (Join-Path $stage 'RUNTIME-BUILD-REQUIRED.txt') -Encoding utf8

$tar = Join-Path $env:SystemRoot 'System32\tar.exe'
if (-not (Test-Path -LiteralPath $tar -PathType Leaf)) { throw "tar.exe was not found: $tar" }
& $tar -a -cf $zip -C $dist $name
if ($LASTEXITCODE -ne 0) { throw "Launcher archive creation failed with exit code $LASTEXITCODE." }
Remove-Item -LiteralPath $stage -Recurse -Force
Write-Host "Launcher package created: $zip" -ForegroundColor Green
