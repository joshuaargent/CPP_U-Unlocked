<div align="center">

# U Unlocked

### Super Smash Bros. for Wii U, rebuilt for PC.

A native Windows experience for Super Smash Bros. for Wii U, with a polished launcher, controller remapping, practical graphics settings, and a mod-management workflow.

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

U Unlocked is a Windows-first PC project for Super Smash Bros. for Wii U. It brings the native game runtime, launcher, controller setup, graphics configuration, and mod workflow together as one coherent application.

The goal is to make the complete experience feel intentional: configure controllers before the first match, choose sensible graphics settings for the hardware in use, manage mods without manually moving files, and get clear diagnostics when something goes wrong.

The launcher takes design inspiration from Melee Unlocked. That inspiration is limited to product design and interaction patterns; its source code is not included in this repository.

## What you'll find here

- **Native PC runtime** - C++20, Vulkan rendering, SDL3 input, and a native Windows game runtime.
- **Game installation** - validation of the game, update, and optional DLC folders supplied by the user.
- **WUA installation** - the Windows launcher can import a `.wua` archive through the bundled bounded extractor. It extracts into a private staging directory, rejects unsafe paths/reparse points and resource-limit violations, validates the Smash base-game title ID, then activates the imported library without modifying or deleting the original archive. Real-archive end-to-end testing remains outstanding.
- **Launcher** - a controller- and mouse-friendly home dashboard with Play, Build, game-update management, Online, Netplay, Controls, Graphics, Mods, and Diagnostics pages. Build manages the user-supplied game/update/DLC folders; Diagnostics reports runtime and system information and can copy a support report.
- **Controller configuration** - the Controls page supports per-device button/axis remapping, per-player slot assignment, per-axis dead zones and stick inversion, trigger thresholds, a live input monitor, JSON profile saving, and automatic discovery of standard Cemu profile folders.
- **Cemu profile import** - imports Cemu Wii U GamePad and Pro Controller XML profiles using explicit SDLController mapping translation. Unsupported input APIs and settings are reported; imported mappings remain unsaved until reviewed and saved by the user.
- **Graphics settings** - Performance (720p render target), Balanced (1080p), Quality (1440p), and Automatic starting profiles are available, with manual render-resolution, display-mode, and presentation-rate controls. These are starting points, not hardware benchmarks; detailed GPU/Vulkan detection and measured hardware-aware recommendations remain planned.
- **Netplay** - host game streaming and direct IP/VPN joining; room discovery remains disabled until a U Unlocked-owned compatible service is deployed. The current UDP protocol has no app-level authentication or encryption, so use trusted LAN/private-VPN peers only; public port forwarding is not safe yet.
- **Mod management** - folder-based installation and enable/disable support. Archive installation is temporarily disabled until a bounded extractor can safely reject traversal, links, duplicate paths, oversized archives, and overwrite attempts. Profiles, dependency checks, conflict reporting, and transactional rollback remain planned.
- **Performance profiles** - the launcher provides Performance, Balanced, Quality, and Automatic profiles. Performance uses a 1280x720 render target, Balanced 1920x1080, and Quality 2560x1440. The Iris Xe target still needs on-device benchmarking before any preset can be called optimal.
- **Application updates** - the Windows launcher checks GitHub releases on demand, supports stable/beta channels, verifies SHA-256 package and per-file hashes, stages updates, backs up replaced launcher files, and rolls back if replacement or relaunch fails. Game files, mods, saves, console files, and settings are not replaced. User-selectable rollback and end-to-end release testing remain outstanding.
- **Diagnostics** - the launcher reports platform, logical CPU cores, system memory, CPU optimisation path, SDL launcher renderer, game/update validation, active mods, shader-cache count, and log location. Vulkan capability reporting and deeper automated troubleshooting remain planned.
- **Preserved game behaviour** - presentation interpolation creates additional visual frames from recorded render state; it must not advance gameplay simulation, physics, collision checks, or input timing. A 120 Hz display can therefore receive smoother presentation while the game simulation retains its original cadence. Interpolation remains optional and may add visual latency.

Features described as planned are not represented as already implemented. See the [implementation roadmap](docs/IMPLEMENTATION_ROADMAP.md) and [architecture](docs/ARCHITECTURE.md) for the delivery sequence and engineering requirements.

## Why U Unlocked?

The objective is not simply to make the game launch on a PC.

Controller setup should be straightforward, settings should explain what they change, mods should be easy to manage, and performance defaults should be based on the hardware actually detected. Existing saves, game files, mod formats, and online compatibility should be preserved wherever possible.

## Current status

The native runtime and Windows build foundation are now part of this repository. The launcher includes Play, Build, game-update management, Online, Netplay, Controls, Graphics, Mods, and Diagnostics workflows. Controls supports physical button and axis capture, player-slot assignment, per-axis calibration, a live input monitor, per-device JSON profile persistence, automatic Cemu profile-folder discovery, and a Cemu XML importer for SDLController profiles. The launcher also provides direct IP/VPN Netplay joining without requiring a room directory. The Library screen now imports WUA archives through a bundled bounded extractor, stages and validates the extracted base game, and preserves the source archive. The Windows launcher package includes the extractor. Windows launcher update checks and a checksum-verified staged update helper are implemented; the release package must include both the ZIP and its SHA-256 sidecar. End-to-end update testing, user-selectable rollback, secure ZIP/7z/RAR mod installation, real-WUA end-to-end testing, richer mod management, detailed GPU/Vulkan reporting, full runtime linking, and on-device performance testing remain outstanding. Graphics profiles are implemented as explicit starting configurations, not automatic hardware tuning.

The initial target machine is an HP EliteBook 640 G9 provisionally identified as an Intel Core i5 model with Intel Iris Xe graphics and 16 GB RAM. The exact CPU model and Vulkan driver capabilities still need to be confirmed on the target machine. Defaults will be based on runtime detection and measured performance rather than the laptop model name.

No Nintendo game data, keys, console files, user saves, or generated recompiled game code are included in this repository.

## Built with

| Area | Technology |
| --- | --- |
| Language | C++20 |
| Build system | CMake and Ninja |
| Platform | Windows 10/11 x64 |
| Windowing and input | SDL3 |
| Graphics | Vulkan 1.3 |
| Configuration | Versioned JSON and INI |
| Build automation | PowerShell and Python |
| Source control | Git and GitHub pull requests |

## Run locally

### Requirements

- 64-bit Windows 10 or Windows 11.
- Git and Python 3.
- Approximately 16 GB RAM for a full native build; more memory and free disk space provide additional headroom.
- A Vulkan 1.3-capable graphics driver.
- The Windows toolchain: llvm-mingw, Ninja, and CMake.
- Your own legally obtained Super Smash Bros. for Wii U game dump.

### Get the source

Clone the repository normally. The native runtime is included directly in the `engine\` directory.

```powershell
git clone https://github.com/joshuaargent/CPP_U-Unlocked.git
cd CPP_U-Unlocked
```

Place the `toolchain\` directory beside `engine\`:

```text
CPP_U-Unlocked\
  toolchain\
    llvm-mingw\
    Ninja\
    CMake\
  engine\
    CMakeLists.txt
    runtime\
    recomp\
    third_party\
  docs\
  tools\
```

### Game files

The runtime expects the user's own extracted Wii U game folders:

| Folder | Title ID | Required |
| --- | --- | --- |
| Game | `0005000010144F00` | Yes |
| Update | `0005000E10144F00` | Recommended |
| DLC | `0005000C10144F00` | Optional |

Keep game data, console files, keys, and saves out of Git, issue attachments, and release packages.

### Build U Unlocked

Run the project build wrapper from the repository root:

```powershell
.\tools\windows\build-u-unlocked.ps1 -Rpx '<update>\code\cross_f.rpx' -BaseRpx '<game>\code\cross_f.rpx'
```

The build uses the source in `engine\`, the local toolchain in `toolchain\`, and writes build output to ignored working directories. The launcher and game runtime are written to `Play\`; the launcher is named `U Unlocked.exe`.

A first build requires the user's game/update RPX files and the toolchain described above. Do not distribute generated game code or executables built from it. They contain code translated from the user's game files.

### Package the launcher for a release

After building the launcher, run the package script from the repository root with the release version:

```powershell
.\engine\tools\windows\package-release.ps1 -Version 0.2.0
```

It creates a Windows launcher package ZIP containing U Unlocked, the bounded WUA extractor, the updater, runtime DLLs, and required licence notices, plus a matching SHA-256 sidecar. Attach both files to the GitHub release tagged v0.2.0. The update checker expects the asset name U-Unlocked-v0.2.0-Windows-Launcher.zip and its .sha256 sidecar. The package does not include the game runtime; each user builds that locally from their own game files.

## Development and pull requests

Changes are developed on focused feature branches and submitted as pull requests against `main`.

- Keep changes scoped to one coherent feature or fix.
- Preserve game compatibility and user data unless a change is deliberate, documented, and tested.
- Run the relevant build and tests before requesting review.
- Address automated review findings and CI failures before merging.
- Use **Squash and merge** after review and validation.
- Keep release publication separate from ordinary commits. Releases should be created from reviewed, merged version tags.

## Licensing and third-party code

The repository includes MIT-licensed runtime and recompilation components. The required copyright and permission notice is retained in `LICENSES/RECOMPILATION-MIT-LICENSE.txt`. Third-party components retain their own licence files and notices; see [third-party notices](docs/THIRD_PARTY_NOTICES.md).

Melee Unlocked is used as a product-design reference only. Its GPL-licensed implementation is not copied into this repository.

Super Smash Bros. for Wii U and all associated game assets remain the property of their respective rights holders. This project is not affiliated with or endorsed by Nintendo, Bandai Namco, or Sora Ltd. Users must provide their own game files. Do not commit game dumps, keys, console files, saves, proprietary assets, or generated recompiled game code.

---

<div align="center">

**U Unlocked** · Built for the game. Designed for PC.

</div>
