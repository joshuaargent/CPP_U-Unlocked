# Implementation roadmap

## Foundation

- [x] Establish the U Unlocked product direction, architecture, and project README.
- [x] Bring the native runtime and recompilation source into the repository.
- [x] Preserve required MIT and third-party licence notices.
- [x] Replace application-facing identity and launcher artwork references.
- [x] Establish a Windows source-validation workflow.
- [ ] Run a complete Windows build on the target laptop with user-supplied game files.
- [ ] Verify the packaged output contains no game dump, keys, saves, or generated game code.

## Launcher

- [x] Replace the single-column startup menu with a feature-rich home dashboard and featured game launch panel.
- [x] Add direct home-screen navigation to Play, Build, game-update management, Online, Netplay, Controls, Graphics, Mods, and Diagnostics.
- [x] Add a Build/library workflow for selecting and validating the user's game, update, and DLC folders.
- [x] Add a game-update management page for selecting and removing the locally installed update dump.
- [x] Add a Diagnostics page for platform, CPU core count, system memory, CPU optimisation path, SDL renderer, game/update validation, active mods, shader-cache count, log path, and clipboard export.
- [x] Make Netplay status explain the actual direct IP/VPN connection requirements instead of implying that an unconfigured room directory is active.
- [ ] Rework the launcher into a consistent Melee Unlocked-inspired product flow: Build, Play, Updates, Mods, and Online as primary destinations, with configuration and diagnostics grouped cleanly.
- [ ] Complete responsive layouts, high-DPI scaling, focus states, keyboard/controller navigation, and accessibility.
- [ ] Add an application updater with stable/beta channels, signed or hash-verified packages, staged installation, rollback, and user-data preservation. This is separate from managing the game's update dump.
- [ ] Add version selection and rollback for previous U Unlocked application releases.
- [ ] Add an in-game settings overlay with keyboard and controller access.
- [ ] Add consistent error, confirmation, progress, and recovery dialogs.

## Controller configuration

- [x] Implement versioned per-device profile storage and atomic JSON writes.
- [x] Discover connected controllers and select a physical device to configure.
- [x] Implement press-to-bind buttons and axes, including Escape cancellation and a 10-second timeout.
- [x] Implement configurable stick dead zones and trigger thresholds.
- [x] Implement explicit player-slot assignment (automatic, Wii U GamePad, and Pro Controller slots).
- [x] Implement per-axis dead zones and stick-axis inversion.
- [x] Add a live controller input monitor for all mapped buttons, sticks, and triggers.
- [ ] Implement full stick/trigger calibration and saturation.
- [x] Import Cemu Wii U GamePad and Pro Controller XML profiles for the SDLController API with explicit button/axis mapping translation and a review-before-save workflow.
- [x] Discover standard Cemu profile directories automatically and allow a custom configuration directory through CEMU_CONFIG_DIR.
- [x] Add automated tests for axis normalization, dead zones, inversion, profile persistence, and invalid-save protection.
- [ ] Add tests for reconnects, ambiguous device identities, and multi-controller setups.

## Graphics and performance

- [x] Expose the existing resolution, fullscreen/windowed, and frame-pacing controls in the launcher.
- [ ] Add a clear graphics settings hierarchy with render scale, VSync, frame pacing, and advanced options.
- [ ] Implement hardware-aware Low Spec, Balanced, and Quality presets.
- [ ] Add detailed GPU/Vulkan capability detection and diagnostics.
- [ ] Benchmark the HP EliteBook 640 G9 and tune defaults from measured results.
- [ ] Verify graphics options do not alter deterministic game simulation.

## Mod management

- [x] Implement basic archive/folder installation and enable/disable toggles for detected content folders.
- [ ] Audit archive extraction against path traversal, symlink, decompression-bomb, and overwrite risks before broadening supported formats.
- [ ] Implement a versioned mod manifest.
- [ ] Implement named enable/disable profiles, dependency checks, and conflict reporting.
- [ ] Implement transactional file changes, backups, and rollback.
- [ ] Package the project-owned mod only after its contents and redistribution rights are verified.

## Release engineering

- [ ] Add Windows build validation for the actual native targets.
- [ ] Add reproducible packaging and output verification.
- [ ] Add versioned release workflow after the package format is stable.
- [ ] Test clean installation, upgrade, rollback, and user-data preservation.
