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
- [ ] Add Windows WUA archive selection and safe extraction into the Build workflow, with strict path, link, file-count, and expanded-size validation. Preserve the original archive and stage extraction before activating the resulting folder.
- [x] Add a game-update management page for selecting and removing the locally installed update dump.
- [x] Add a Diagnostics page for platform, CPU core count, system memory, CPU optimisation path, SDL renderer, game/update validation, active mods, shader-cache count, log path, and clipboard export.
- [x] Own and join the launcher's background workers for mod installation, Pretendo sign-in, room discovery, and application update checks; contain worker exceptions and clear the sign-in password buffer after use.
- [x] Make Netplay status explain the actual direct IP/VPN connection requirements instead of implying that an unconfigured room directory is active.
- [ ] Rework the launcher into a consistent Melee Unlocked-inspired product flow: Build, Play, Updates, Mods, and Online as primary destinations, with configuration and diagnostics grouped cleanly.
- [ ] Complete responsive layouts, high-DPI scaling, focus states, keyboard/controller navigation, and accessibility.
- [x] Add an on-demand Windows application update check with stable/beta channels, GitHub release links, SHA-256 package verification, per-file manifest verification, staged replacement, backups, and automatic rollback if replacement or relaunch fails. This is separate from managing the game's update dump.
- [x] Add launcher release packaging with a versioned ZIP, per-file manifest, and SHA-256 sidecar asset.
- [ ] Add a user-facing version history and rollback selector for previously installed U Unlocked releases.
- [ ] Exercise clean install, stable/beta upgrade, interrupted update, rollback, and user-data preservation on Windows.
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

## Netplay

- [x] Remove the inherited third-party room-discovery endpoint and disable room discovery by default.
- [x] Add direct IPv4/hostname joining and persist the host address in launcher settings.
- [x] Correct launcher guidance to explain the direct host connection and current security boundary.
- [ ] Add authenticated guest pairing and explicit host approval.
- [ ] Add encryption and message integrity protection for video, audio, and controller datagrams.
- [ ] Add replay protection, strict packet validation, connection limits, and rate limiting.
- [ ] Add secure public-internet connectivity only after the authentication and transport security work is complete.
- [ ] Add an optional U Unlocked-owned room directory and NAT traversal service, with no third-party room-service dependency.

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
- [x] Add a launcher-only Windows package with a file manifest and SHA-256 sidecar; game runtime binaries and user game data remain excluded.
- [ ] Add a versioned release workflow that uploads both the ZIP and checksum assets after review.
- [ ] Test clean installation, upgrade, rollback, and user-data preservation on a clean Windows machine.
