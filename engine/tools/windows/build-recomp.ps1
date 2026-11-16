# Build cafe-recomp, cafe-census, and the function finder self-test.
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))
$toolchain = Join-Path $root 'toolchain'
$engineRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$prefix = Join-Path $engineRoot 'build-deps\prefix'
$python = (Get-Command python).Source
$buildJobs = if ($env:U_UNLOCKED_BUILD_JOBS -match '^[0-9]+$') { [int]$env:U_UNLOCKED_BUILD_JOBS } else { 2 }
$env:PATH = (@((Join-Path $toolchain 'llvm-mingw\bin'), (Join-Path $prefix 'bin'), "$env:SystemRoot\System32") + @($env:PATH -split ';' | Where-Object { $_ })) -join ';'

& $python (Join-Path $engineRoot 'tools\setup_deps.py')
if ($LASTEXITCODE -ne 0) { throw 'setup_deps.py failed.' }

$buildDirectory = Join-Path $engineRoot 'build'
& cmake -S $engineRoot -B $buildDirectory -G Ninja -DCMAKE_BUILD_TYPE=Release -DCMAKE_C_COMPILER=x86_64-w64-mingw32-clang -DCMAKE_CXX_COMPILER=x86_64-w64-mingw32-clang++ -DCMAKE_RC_COMPILER=x86_64-w64-mingw32-windres -DCMAKE_EXE_LINKER_FLAGS=-static
if ($LASTEXITCODE -ne 0) { throw 'CMake configure failed.' }

& ninja -j $buildJobs -C $buildDirectory cafe-recomp cafe-census function_finder_test
if ($LASTEXITCODE -ne 0) { throw 'Recompiler build failed.' }

& (Join-Path $buildDirectory 'recomp\function_finder_test.exe')
if ($LASTEXITCODE -ne 0) { throw 'function_finder_test failed.' }

Write-Host 'Recompiler and function finder self-test passed.' -ForegroundColor Green
