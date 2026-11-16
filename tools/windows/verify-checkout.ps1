# Validates the U Unlocked source tree and local Windows toolchain.
[CmdletBinding()]
param(
    [switch]$SkipToolchainCheck
)

$ErrorActionPreference = 'Stop'
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$enginePath = Join-Path $repoRoot 'engine'

$requiredSource = @(
    (Join-Path $enginePath 'CMakeLists.txt'),
    (Join-Path $enginePath 'runtime\src\smash_main.cpp'),
    (Join-Path $enginePath 'runtime\src\host\window.cpp'),
    (Join-Path $enginePath 'runtime\src\host\controller_profiles.cpp'),
    (Join-Path $enginePath 'runtime\src\host\controller_profiles.h'),
    (Join-Path $enginePath 'launcher\smash\main.cpp'),
    (Join-Path $enginePath 'recomp\src\recompile_main.cpp'),
    (Join-Path $enginePath 'tools\setup_deps.py'),
    (Join-Path $enginePath 'tools\windows\build-smash.ps1'),
    (Join-Path $repoRoot 'tools\windows\build-from-library.ps1'),
    (Join-Path $enginePath 'tools\windows\package-release.ps1'),
    (Join-Path $repoRoot 'tools\windows\update-launcher.ps1'),
    (Join-Path $enginePath 'third_party\cemu_nex\LICENSE.txt'),
    (Join-Path $repoRoot 'LICENSES\RECOMPILATION-MIT-LICENSE.txt')
)
$missingSource = @($requiredSource | Where-Object { -not (Test-Path -LiteralPath $_ -PathType Leaf) })
if ($missingSource.Count -gt 0) {
    $missingSource | ForEach-Object { Write-Host "Missing source: $_" -ForegroundColor Red }
    throw 'The U Unlocked source tree is incomplete.'
}

# Launcher workers must be owned and joined; detached workers can outlive the
# Launcher object and write into freed state when the user closes the window.
$launcherMain = Get-Content -LiteralPath (Join-Path $enginePath 'launcher\smash\main.cpp') -Raw
if ($launcherMain -match '\.detach\s*\(') {
    throw 'Detached launcher threads are forbidden; own and join background workers.'
}
if ($launcherMain -notmatch '~Launcher\s*\(') {
    throw 'Launcher shutdown must join its owned background workers.'
}

# Keep the retired upstream project name out of all tracked source and documentation.
# Split the token so this guard does not match itself.
$legacyName = 'Smash' + '4PC'
$gitCommand = Get-Command git -ErrorAction SilentlyContinue
if ($gitCommand -and (Test-Path -LiteralPath (Join-Path $repoRoot '.git'))) {
    $trackedFiles = @(git -C $repoRoot ls-files)
    if ($LASTEXITCODE -ne 0) {
        throw 'Unable to enumerate tracked files for the legacy-reference check.'
    }
} else {
    # Release source bundles intentionally omit .git metadata. Scan the complete
    # source tree while excluding generated build outputs and downloaded toolchains.
    $excludedRoots = @('toolchain', 'generated', 'Play', 'dist', 'engine/build', 'engine/build-deps')
    $trackedFiles = @(Get-ChildItem -LiteralPath $repoRoot -File -Recurse -Force | Where-Object {
        $relative = [System.IO.Path]::GetRelativePath($repoRoot, $_.FullName).Replace('\', '/')
        $parts = $relative.Split('/')
        ($parts -notcontains '.git') -and
        -not ($excludedRoots | Where-Object { $relative.StartsWith($_ + '/', [System.StringComparison]::OrdinalIgnoreCase) })
    } | ForEach-Object { [System.IO.Path]::GetRelativePath($repoRoot, $_.FullName).Replace('\', '/') })
}
$legacyPaths = @($trackedFiles | Where-Object {
    $_.IndexOf($legacyName, [System.StringComparison]::OrdinalIgnoreCase) -ge 0
})
if ($legacyPaths.Count -gt 0) {
    $legacyPaths | ForEach-Object {
        Write-Host "Forbidden legacy branding in tracked path: $_" -ForegroundColor Red
    }
    throw 'The retired upstream project name must not appear in tracked file paths.'
}

$legacyMatches = @(
    foreach ($relativePath in $trackedFiles) {
        $fullPath = Join-Path $repoRoot ($relativePath -replace '/', [System.IO.Path]::DirectorySeparatorChar)
        if (Test-Path -LiteralPath $fullPath -PathType Leaf) {
            Select-String -LiteralPath $fullPath -Pattern $legacyName -SimpleMatch -ErrorAction SilentlyContinue
        }
    }
)
if ($legacyMatches.Count -gt 0) {
    $legacyMatches | ForEach-Object {
        Write-Host "Forbidden legacy reference: $($_.Path):$($_.LineNumber)" -ForegroundColor Red
    }
    throw 'The retired upstream project name must not appear in this repository.'
}

if (-not $SkipToolchainCheck) {
    $requiredToolchain = @(
        (Join-Path $repoRoot 'toolchain\llvm-mingw\bin\x86_64-w64-mingw32-clang++.exe'),
        (Join-Path $repoRoot 'toolchain\Ninja\ninja.exe'),
        (Join-Path $repoRoot 'toolchain\CMake\bin\cmake.exe')
    )
    $missingToolchain = @($requiredToolchain | Where-Object { -not (Test-Path -LiteralPath $_ -PathType Leaf) })
    if ($missingToolchain.Count -gt 0) {
        $missingToolchain | ForEach-Object { Write-Host "Missing tool: $_" -ForegroundColor Yellow }
        throw 'The Windows toolchain is incomplete. See the README build requirements.'
    }
}

Write-Host 'U Unlocked source tree verified.' -ForegroundColor Green
