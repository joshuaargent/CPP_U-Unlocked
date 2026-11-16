# U Unlocked architecture

## Product direction

U Unlocked is a Windows-first native PC platform for Super Smash Bros. for Wii U. The repository owns the application, launcher, build orchestration, runtime integration, settings, profiles, and mod-management experience.

The existing native game runtime and static recompilation implementation are contained in `engine/`. Keep the game runtime and the PC application as distinct layers so launcher features can evolve without destabilising deterministic game behaviour.

## Technology

- C++20 for the native runtime, launcher, and platform integration.
- CMake and Ninja for reproducible builds.
- SDL3 for windowing, physical input discovery, and controller events.
- Vulkan 1.3 for graphics.
- PowerShell and Python for Windows build orchestration and asset tooling.
- Versioned JSON for project-owned profiles and manifests; preserve existing INI settings where compatibility requires them.

## Repository layout

- `engine/` - native runtime, recompilation tools, platform code, and required third-party components.
- `tools/windows/` - project-owned Windows build, verification, and packaging scripts.
- `docs/` - architecture, hardware, controller compatibility, and release documentation.
- `LICENSES/` - required notices for incorporated source components.
- `Play/`, `build/`, `generated/`, and `dist/` - ignored local build output only.

## Application areas

### Home and Play

- Present a dashboard with a featured launch action, game/update/DLC validation, and direct cards for Online, Netplay, Controls, Graphics, Mods, and Quit.
- Keep dashboard hit regions shared between mouse and pointer navigation; keyboard and gamepad selection must remain available.

- Detect game, update, and optional DLC folders.
- Validate required files before launch and explain missing or incompatible files.
- Show the selected game build, active mod profile, and controller assignments.
- Launch with a clear progress state and useful failure diagnostics.

### Controls

- Discover physical devices through SDL3.
- Assign devices to player slots and select the emulated Wii U controller type.
- Bind buttons and axes by selecting an action and pressing or moving the physical input.
- Calibrate sticks and triggers; support inversion, dead zones, saturation, and trigger thresholds.
- Save versioned per-player profiles with stable device hints.
- Provide a live input tester and keyboard/controller navigation.
- Import external controller profiles only through a validated parser and explicit mapping translation.

### Graphics and performance

- Expose window mode, resolution, VSync, frame pacing, scaling, and renderer capability details.
- Provide Low Spec, Balanced, and Quality presets.
- Detect CPU instruction-set support, memory, GPU vendor/device, Vulkan capabilities, display resolution, and refresh rate.
- Keep the game simulation deterministic. Graphics presets must not alter gameplay timing, physics, or simulation steps.
- Bound background shader compilation and avoid per-frame allocations.

### Mods

- Install supported archives and folders without overwriting unrelated user files.
- Track manifests, version, author, dependencies, conflicts, and file ownership.
- Provide named mod profiles and reversible enable/disable operations.
- Back up affected files and support rollback.
- Keep user-created mod data separate from application binaries and game dumps.

### Netplay

- Host streaming is opt-in from the launcher and uses Windows Media Foundation H.264 encoding.
- Guests can join directly with a host IPv4 address / hostname and UDP port; LAN and private VPN addresses are supported.
- Internet direct joins require a reachable UDP port (normally port forwarding) unless a private VPN provides connectivity.
- Room discovery is disabled by default. It may be enabled only with an explicitly deployed compatible service configured through `U_UNLOCKED_ROOM_SERVER`; never contact an inherited third-party endpoint or transmit room metadata to an unrelated service.

### Settings and diagnostics

- Store settings in a versioned user configuration directory.
- Migrate old settings safely and retain a backup before migration.
- Report detected hardware, renderer, driver, game paths, active profile, and recent logs.
- Provide copyable diagnostic reports with personal paths and identifiers redacted by default.

## Controller data model

A controller profile contains:

- Schema version and profile name.
- Emulated device type: Wii U GamePad or Wii U Pro Controller.
- Physical device hints: SDL GUID, vendor/product IDs, display name, and optional serial.
- Button-to-logical-action bindings.
- Axis bindings, inversion, dead zone, saturation, and trigger threshold.
- Player assignment and optional per-game overrides.

The runtime mapping layer translates physical SDL events into the existing logical Wii U input state. Keep physical-device discovery, profile storage, mapping evaluation, and game input state separate.

Profile writes must be atomic. Validate all enum values and numeric ranges, retain a last-known-good backup, and fall back to safe defaults with a visible diagnostic if a profile is malformed.

## Cemu profile import

Cemu profiles use XML and API-specific identifiers. Cemu numeric mapping values are not SDL enum values. The importer must parse XML safely, translate only mapping identifiers with tested mappings, request device selection when identity matching is ambiguous, preview every binding, and save a new U Unlocked profile without modifying the source file.

See [controller compatibility](CONTROLLER_COMPATIBILITY.md) for the XML structure and import rules.

## Graphics backend and resolution policy

The game runtime currently uses its Vulkan 1.3 backend. The launcher uses SDL3's renderer abstraction and lets SDL select an available native renderer. These are separate rendering paths: changing the launcher's SDL renderer does not change the game's Vulkan backend.

Do not add a second game renderer merely to increase a backend count. A Direct3D or OpenGL implementation is only worthwhile after it can implement the full GX2/Latte rendering contract and pass the same correctness tests. A partial backend risks rendering differences and maintenance overhead without a demonstrated performance gain. Keep Vulkan as the game backend until profiling on representative Intel, AMD, and NVIDIA hardware identifies a concrete compatibility or performance reason to add another.

The existing display configuration supports automatic scaling and 720p, 1080p, 1440p, 4K, and 5K render scales, plus fullscreen/windowed presentation and configurable frame pacing. Preserve these options and validate them against each display's available modes and the GPU's memory budget before adding more presets.

## Hardware target

The first target is an HP EliteBook 640 G9 provisionally configured with an Intel Core i5, Intel Iris Xe graphics, and 16 GB RAM. The exact CPU SKU and graphics driver must be confirmed on-device.

Detect hardware at runtime rather than relying on a model name. Benchmark actual performance before selecting defaults. Keep an x86-64-v2 compatibility build available where required, and choose the faster instruction-set variant only after checking CPU support.

## Licensing and data boundaries

Retain all required third-party copyright notices and licence files in `LICENSES/` or beside the corresponding component. Do not copy code from GPL-licensed design references.

Never commit Nintendo game dumps, console keys, user saves, proprietary game assets, or generated game code. Build output and user data remain ignored and local.

## Quality gates

Before merging a feature:

1. Build Debug and Release configurations on Windows.
2. Run unit tests and static analysis for changed native code.
3. Test settings migration and backward compatibility.
4. Test keyboard-only and controller-only navigation.
5. Test controller binding, cancellation, timeout, reconnect, and multi-player assignment.
6. Test mod install, conflict reporting, rollback, and interrupted operations.
7. Record performance on the target laptop, including average frame time, 1% lows, memory use, and shader-cache behaviour.
8. Inspect standard and high-DPI layouts.
9. Record exactly which tests ran and which require hardware or user game data.
