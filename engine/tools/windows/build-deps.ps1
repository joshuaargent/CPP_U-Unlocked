# Build pinned runtime dependencies for the Windows Vulkan release.
# All dependency source is downloaded from immutable commit archives by setup_deps.py.
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))
. (Join-Path $root 'tools\windows\toolchain-path.ps1')
$toolchain = Get-UUnlockedToolchainRoot
$engineRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$third = Join-Path $engineRoot 'third_party'
$work = Join-Path $engineRoot 'build-deps'
$prefix = Join-Path $work 'prefix'
$python = (Get-Command python).Source
$buildJobs = if ($env:U_UNLOCKED_BUILD_JOBS -match '^[0-9]+$') { [int]$env:U_UNLOCKED_BUILD_JOBS } else { 2 }

$env:PATH = (@(
    (Join-Path $toolchain 'llvm-mingw\bin'),
    (Split-Path -Parent $python),
    "$env:SystemRoot\System32"
) + @($env:PATH -split ';' | Where-Object { $_ })) -join ';'

& $python (Join-Path $engineRoot 'tools\setup_deps.py')
if ($LASTEXITCODE -ne 0) { throw 'setup_deps.py failed.' }

New-Item -ItemType Directory -Force -Path $work, $prefix | Out-Null

function Build-Dep {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$Source,
        [string[]]$Options = @()
    )

    Write-Host "== Building $Name" -ForegroundColor Cyan
    $buildDirectory = Join-Path $work $Name
    if (Test-Path -LiteralPath $buildDirectory) {
        Remove-Item -LiteralPath $buildDirectory -Recurse -Force
    }

    & cmake -S $Source -B $buildDirectory -G Ninja -DCMAKE_BUILD_TYPE=Release "-DCMAKE_INSTALL_PREFIX=$prefix" "-DCMAKE_PREFIX_PATH=$prefix" -DCMAKE_C_COMPILER=x86_64-w64-mingw32-clang -DCMAKE_CXX_COMPILER=x86_64-w64-mingw32-clang++ @Options
    if ($LASTEXITCODE -ne 0) { throw "$Name CMake configuration failed." }

    & cmake --build $buildDirectory --target install --parallel $buildJobs
    if ($LASTEXITCODE -ne 0) { throw "$Name build/install failed." }

    Remove-Item -LiteralPath $buildDirectory -Recurse -Force
}

Build-Dep -Name 'zlib' -Source (Join-Path $third 'zlib') -Options @('-DZLIB_BUILD_EXAMPLES=OFF')
Build-Dep -Name 'zstd' -Source (Join-Path $third 'zstd\build\cmake') -Options @('-DZSTD_BUILD_PROGRAMS=OFF', '-DZSTD_BUILD_TESTS=OFF', '-DZSTD_BUILD_SHARED=OFF')
Build-Dep -Name 'SDL' -Source (Join-Path $third 'SDL') -Options @('-DSDL_TESTS=OFF', '-DSDL_EXAMPLES=OFF')
Build-Dep -Name 'Vulkan-Headers' -Source (Join-Path $third 'Vulkan-Headers')
Build-Dep -Name 'shaderc' -Source (Join-Path $third 'shaderc') -Options @(
    '-DSHADERC_SKIP_TESTS=ON',
    '-DSHADERC_SKIP_EXAMPLES=ON',
    '-DSHADERC_SKIP_EXECUTABLES=ON',
    '-DSHADERC_SKIP_COPYRIGHT_CHECK=ON',
    '-DSHADERC_ENABLE_WERROR_COMPILE=OFF',
    "-DSHADERC_GLSLANG_DIR=$third\glslang",
    "-DSHADERC_SPIRV_HEADERS_DIR=$third\spirv-headers",
    "-DSHADERC_SPIRV_TOOLS_DIR=$third\spirv-tools",
    '-DSPIRV_SKIP_TESTS=ON',
    '-DSPIRV_SKIP_EXECUTABLES=ON',
    '-DSPIRV_WERROR=OFF',
    '-DENABLE_GLSLANG_BINARIES=OFF'
)

# Generate the loader import library from the same pinned Vulkan registry as the headers.
# This makes cross-compilation independent of whether the build machine has a GPU driver.
Write-Host '== Generating Vulkan loader import library' -ForegroundColor Cyan
$registryPath = Join-Path $third 'Vulkan-Headers\registry\vk.xml'
if (-not (Test-Path -LiteralPath $registryPath -PathType Leaf)) {
    throw "The pinned Vulkan command registry is missing: $registryPath"
}
[xml]$registry = Get-Content -LiteralPath $registryPath -Raw
$exports = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
foreach ($command in $registry.SelectNodes('/registry/commands/command')) {
    $nameNode = $command.SelectSingleNode('proto/name')
    $name = if ($nameNode) { $nameNode.InnerText } else { $command.GetAttribute('name') }
    if ($name -match '^vk[A-Z]') { [void]$exports.Add($name) }
}
if ($exports.Count -eq 0) { throw 'No Vulkan commands were found in the pinned vk.xml registry.' }

New-Item -ItemType Directory -Force -Path (Join-Path $prefix 'lib') | Out-Null
$definitionFile = Join-Path $work 'vulkan-1.def'
Set-Content -LiteralPath $definitionFile -Encoding ascii -Value (@('LIBRARY vulkan-1.dll', 'EXPORTS') + @($exports | Sort-Object))
& llvm-dlltool -m i386:x86-64 -d $definitionFile -l (Join-Path $prefix 'lib\libvulkan-1.a')
if ($LASTEXITCODE -ne 0) { throw 'llvm-dlltool failed to create libvulkan-1.a.' }

Write-Host 'Pinned runtime dependencies and Vulkan import library are ready.' -ForegroundColor Green
