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
- [x] Add a bounded Windows WUA extraction utility using the pinned ZArchive reader, with strict path/filename validation, case-collision detection, reparse-point rejection, exclusive file creation, and depth/file-count/expanded-size limits; add a dedicated Windows compile check in CI. The POSIX extractor now has matching inventory limits.
- [x] Integrate WUA archive selection into the launcher Library workflow, with private staging, cleanup on failure, Smash title-folder validation, preservation of the original archive, and activation into the local game library.
- [ ] Run end-to-end tests against real WUA dumps and verify interrupted-import recovery on Windows.
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

- [x] Expose the existing resolution, fullscreen/windowed, and presentation-rate controls in the launcher.
- [x] Add Performance (720p render target), Balanced (1080p), Quality (1440p), and Automatic starting profiles, with manual resolution and presentation-rate overrides.
- [ ] Add a fuller graphics settings hierarchy with explicit VSync, frame pacing, and advanced options.
- [ ] Implement hardware-aware preset recommendations using detected GPU capabilities and measured performance.
- [ ] Add detailed GPU/Vulkan capability detection and diagnostics.
- [ ] Benchmark the HP EliteBook 640 G9 and tune defaults from measured results.
- [ ] Verify graphics options do not alter deterministic game simulation; presentation interpolation must remain a render-only operation and must not advance gameplay state.
- [x] Add opt-in measurements for previous-frame GPU retirement waits and presentation-image pool waits; see [GPU frame pacing and simulation decoupling](GPU_FRAME_PACING.md).
- [ ] Profile and remove unintended GPU-completion back-pressure from guest simulation without weakening guest-memory/resource lifetime guarantees.
- [ ] Design a bounded frames-in-flight queue so the guest can continue at the title's 59.94 Hz cadence when rendering is slower, with explicit input/audio/netplay timing and deterministic replay tests.
- [ ] Add stress tests that deliberately limit rendering below 60 FPS and verify guest simulation ticks, input sampling, audio timing, and frame queue bounds independently.

## Mod management

- [x] Implement folder-based mod installation and enable/disable toggles for detected content folders. Archive-based mod installation remains disabled until a bounded ZIP/7z/RAR extractor is integrated.
- [x] Disable unbounded system-tar archive extraction; mod installation now accepts folders only, rejects symlinks/reparse points and special files, caps traversal at 20,000 entries and 4 GiB, and stages copies before activation. Secure ZIP/7z/RAR support remains blocked on a bounded archive reader with traversal/link/overwrite protections.
- [ ] Implement a versioned mod manifest.
- [ ] Implement named enable/disable profiles, dependency checks, and conflict reporting.
- [ ] Implement transactional file changes, backups, and rollback.
- [ ] Package the project-owned mod only after its contents and redistribution rights are verified.

## Release engineering

- [ ] Add Windows build validation for the actual native targets.
- [x] Add a launcher-only Windows package with a file manifest and SHA-256 sidecar; game runtime binaries and user game data remain excluded.
- [ ] Add a versioned release workflow that uploads both the ZIP and checksum assets after review.
- [ ] Test clean installation, upgrade, rollback, and user-data preservation on a clean Windows machine.
