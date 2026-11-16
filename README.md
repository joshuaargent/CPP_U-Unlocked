<div align="center">

# U Unlocked

### Super Smash Bros. for Wii U, rebuilt for PC.

A native Windows experience for Super Smash Bros. for Wii U, built on the Smash4PC static-recompilation project and developed around a cleaner launcher, complete controller configuration, practical graphics settings, and a proper mod-management experience.

[![GitHub](https://img.shields.io/badge/GitHub-joshuaargent-181717?style=for-the-badge&logo=github&logoColor=white)](https://github.com/joshuaargent)
[![Platform](https://img.shields.io/badge/Platform-Windows%2010%20%2F%2011-0078D4?style=for-the-badge&logo=windows&logoColor=white)](https://www.microsoft.com/windows)
[![Language](https://img.shields.io/badge/Language-C%2B%2B-00599C?style=for-the-badge&logo=cplusplus&logoColor=white)](https://isocpp.org/)

<br />

![C++](https://img.shields.io/badge/C%2B%2B-20-00599C?logo=cplusplus&logoColor=white)
![CMake](https://img.shields.io/badge/CMake-3.20%2B-064F8C?logo=cmake&logoColor=white)
![SDL3](https://img.shields.io/badge/SDL-3-1E6B54?logo=sdl&logoColor=white)
![Vulkan](https://img.shields.io/badge/Graphics-Vulkan%201.3-AC162C?logo=vulkan&logoColor=white)

</div>

---

## About this project

U Unlocked is a Windows-first PC project for Super Smash Bros. for Wii U. It uses the existing Smash4PC static recompilation and Wii U runtime as its technical foundation rather than starting another game port from scratch.

The aim is to keep the underlying game compatibility and performance work that already exists, then build a more complete PC experience around it. The launcher, settings and mod workflow take design inspiration from Melee Unlocked: clear navigation, a consistent dark interface, useful configuration screens and controls that feel like part of one finished application.

U Unlocked is an independent project. Melee Unlocked is a design reference only; its GPL-licensed source is not copied into this repository.

## What you'll find here

- **Native PC runtime** - the Smash4PC static-recompilation runtime, Vulkan renderer and SDL3 platform layer, retained as a pinned upstream dependency.
- **Game installation** - support for the game, update and optional DLC folders dumped from a user's own Wii U.
- **Controller configuration** - planned per-player device assignment, press-to-bind remapping, calibration, dead zones, controller layouts and portable profiles.
- **Graphics settings** - planned resolution, display mode, VSync, frame pacing and hardware-aware quality presets.
- **Mod management** - existing Smash4PC content mods and Cemu graphic-pack support, with a broader U Unlocked profile and conflict-management experience planned.
- **Performance profiles** - a Low Spec mode and measured Balanced and Quality presets, with the Intel Iris Xe integrated-graphics configuration included in the initial optimisation target.
- **Diagnostics** - planned hardware detection, Vulkan capability reporting, shader-cache information and actionable troubleshooting.
- **Preserved game behaviour** - performance settings must not change deterministic game simulation or silently alter gameplay timing.

Features described as planned are not represented as already implemented. See the [implementation roadmap](docs/IMPLEMENTATION_ROADMAP.md) and [architecture](docs/ARCHITECTURE.md) for the delivery sequence and engineering requirements.

## Why U Unlocked?

The goal is not simply to make the game launch on a PC. The goal is to make the whole experience feel intentional.

That means controller setup should be straightforward before the first match, settings should explain what they do, mods should be manageable without manually moving files around, and the application should select sensible defaults for the hardware actually detected. Existing saves, game files, mod formats and online compatibility should be preserved wherever possible.

## Current status

The repository is being established around a pinned copy of Smash4PC. The upstream runtime and launcher are the starting point; the U Unlocked launcher redesign, controller-profile system, expanded mod manager and hardware-tuned presets are being implemented in stages.

The initial target machine is an HP EliteBook 640 G9 provisionally identified as an Intel Core i5 model with Intel Iris Xe graphics and 16 GB RAM. The exact CPU model and Vulkan driver capabilities still need to be confirmed on the target machine. Defaults will be based on runtime detection rather than the laptop model name.

No Nintendo game data, keys, console files, user saves or generated recompiled game code are included in this repository.

## Built with

| Area | Technology |
| --- | --- |
| Language | C++ |
| Build system | CMake and Ninja |
| Platform | Windows 10/11 x64 |
| Windowing and input | SDL3 |
| Graphics | Vulkan |
| Game foundation | Smash4PC static recompilation and Wii U runtime |
| Build automation | PowerShell and Python |
| Configuration | Versioned JSON / INI, according to the owning subsystem |
| Source control | Git and GitHub pull requests |

## Install and run

U Unlocked does not currently publish a finished installer. The first development builds are produced from source.

### Requirements

- 64-bit Windows 10 or Windows 11.
- Python 3 and Git.
- Approximately 16 GB RAM for the upstream build process; more memory and free disk space are beneficial.
- A Vulkan 1.3-capable graphics driver.
- The Smash4PC Windows toolchain: llvm-mingw, Ninja and CMake.
- Your own legally obtained Super Smash Bros. for Wii U game dump.

### Get the source

Clone the repository and initialise its pinned Smash4PC submodule:

```powershell
git clone --recurse-submodules https://github.com/joshuaargent/CPP_U-Unlocked.git
cd CPP_U-Unlocked
```

If the repository was cloned without submodules:

```powershell
git submodule update --init --recursive
```

Place the `toolchain\` directory beside the `upstream\` directory:

```text
CPP_U-Unlocked\
  toolchain\
    llvm-mingw\
    Ninja\
    CMake\
  upstream\                 # pinned Smash4PC source
  docs\
  tools\
```

### Game files

The upstream runtime expects the user's own extracted Wii U game folders:

| Folder | Title ID | Required |
| --- | --- | --- |
| Game | `0005000010144F00` | Yes |
| Update | `0005000E10144F00` | Recommended |
| DLC | `0005000C10144F00` | Optional |

The folders should be dumped from the user's own console using an appropriate dumping tool. Keep game data, console files and keys out of Git, issue attachments and release packages.

### Build the upstream baseline

The current baseline build script is maintained by Smash4PC:

```powershell
.\upstream\tools\windows\build-smash.ps1 -Rpx '<update>\code\cross_f.rpx' -BaseRpx '<game>\code\cross_f.rpx'
```

The script builds the translated game programs and launcher into the repository's sibling `Play\` directory. The upstream build currently retains its own executable branding; a successful baseline build is not yet a completed U Unlocked release.

The upstream release packager can be run with:

```powershell
.\upstream\tools\windows\package-release.ps1
```

Do not upload or distribute the generated game code or executables built from it. They contain code translated from the user's game files.

## Development and pull requests

Changes are developed on focused feature branches and submitted as pull requests against `main`.

- Keep changes scoped to one coherent feature or fix.
- Preserve existing upstream behaviour unless a change is deliberate, documented and tested.
- Run the relevant build and tests before requesting review.
- Address automated review findings and CI failures before merging.
- Use **Squash and merge** after review and validation.
- Keep release publication separate from ordinary commits. Releases should be created from reviewed, merged version tags.

Build validation and release workflows will be added as the project gains its own reproducible build entry point. A workflow must not claim to validate the application until it actually builds the relevant targets.

## Licensing and third-party code

U Unlocked retains the upstream Smash4PC source as a pinned Git submodule. Its source identifies the project as MIT-licensed; its license and all third-party notices remain with that source.

Melee Unlocked is used as a product-design reference, not a source dependency. Its GPL-licensed implementation is not copied here.

Super Smash Bros. for Wii U and all associated game assets remain the property of their respective rights holders. This project is not affiliated with or endorsed by Nintendo, Bandai Namco or Sora Ltd. Users must provide their own game files. Do not commit game dumps, keys, console files, saves, proprietary assets or generated recompiled game code.

---

<div align="center">

**U Unlocked** · Built for the game. Designed for PC.

</div>
