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
- [x] Add a local developer build pipeline that recompiles user-supplied base/update RPX files into separate ignored output directories and builds update/base executables for x86-64-v3 and x86-64-v2 in one CMake configuration, sharing the native runtime and launcher; keep all game-derived code and data on the user's machine and out of CI/release assets.
- [x] Integrate the local pipeline into the launcher's first-run Build Runtime action; Play starts the same build automatically when the selected runtime is missing.
- [x] Embed a clean, game-data-free source build kit in the launcher package and bootstrap pinned llvm-mingw, CMake, Ninja, Python, and pinned third-party source archives without requiring Git or a developer checkout.
- [x] Validate separate base/update folders and RPX title IDs before building; capture timestamped build logs; limit build parallelism based on physical RAM; verify all four CPU/title executables; stage and atomically activate the runtime in a separate directory without replacing the running launcher.
- [ ] Add visible build progress, cancellation, and interrupted-build recovery. The current launcher reports the build state while the PowerShell build process displays detailed output.
- [ ] Verify the launcher starts the locally generated game runtime after a clean separate-folder setup and after a clean WUA import on Windows with real user-owned game files.
- [x] Add a game-update management page for selecting and removing the locally installed update dump.
- [x] Add a Diagnostics page for platform, CPU core count, system memory, CPU optimisation path, SDL renderer, game/update validation, active mods, shader-cache count, log path, and clipboard export.
- [x] Own and join the launcher's background workers for mod installation, Pretendo sign-in, room discovery, and application update checks; contain worker exceptions and clear the sign-in password buffer after use.
- [x] Make Netplay status explain the actual direct IP/VPN connection requirements instead of implying that an unconfigured room directory is active.
- [ ] Rework the launcher into a consistent Melee Unlocked-inspired product flow: Build, Play, Updates, Mods, and Online as primary destinations, with configuration and diagnostics grouped cleanly.
- [ ] Complete responsive layouts, high-DPI scaling, focus states, keyboard/controller navigation, and accessibility.
- [x] Check for application updates automatically in a background worker at launcher startup; retain stable/beta channels, GitHub release links, SHA-256 package verification, per-file manifest verification, staged replacement, backups, and automatic rollback if replacement or relaunch fails. Installing an update remains an explicit user action. This is separate from managing the game's update dump.
- [x] Add launcher release packaging with a versioned ZIP, per-file manifest, and SHA-256 sidecar asset.
- [x] Add a tag-triggered Windows release workflow that builds and links the launcher, builds the bounded WUA extractor, creates and verifies the package, and publishes the ZIP and checksum as GitHub release assets. The first tagged run remains outstanding.
- [ ] Run the release workflow against a version-matched prerelease tag, then verify the published assets through both stable/beta update discovery paths.
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
- [x] Enforce exact host-side UDP packet lengths, reject stale input sequence numbers, clamp controller axes, rate-limit total and per-source-IP incoming packets/handshakes with bounded token buckets, and limit each guest to one keyframe request per second.
- [x] Bound guest-side video reassembly to 8 MiB, validate fragment counts/indices/lengths and consistent frame metadata, and reject malformed stereo int16 audio packet framing before decode/playback.
- [ ] Add authenticated guest pairing, cryptographic replay protection, per-peer abuse controls, and host approval before enabling public internet connectivity.
- [ ] Add secure public-internet connectivity only after the authentication and transport security work is complete.
- [ ] Deliver both supported online paths: direct IPv4/hostname over LAN or user-managed VPN, and Nintendo Network/Pretendo through the integrated NEX services; expose their distinct setup, status, error and diagnostics flows in the launcher.
- [ ] Add an optional U Unlocked-owned room directory and NAT traversal service, with no third-party room-service dependency.

## Project branding

- [x] Generate an original U Unlocked Windows application icon.
- [x] Generate an original transparent U Unlocked wordmark during the Windows build; use it in the launcher header and overlay it onto the game's title-logo regions.
- [x] Include the logo in launcher release packages, per-file SHA-256 manifests, automatic updates, and rollback so branding remains consistent across upgrades.
- [x] Keep the retired upstream project name out of tracked file paths and file contents through the checkout verification script.

## Graphics and performance

- [x] Expose the existing resolution, fullscreen/windowed, and presentation-rate controls in the launcher.
- [x] Add Performance (720p render target), Balanced (1080p), Quality (1440p), and Automatic starting profiles, with manual resolution and presentation-rate overrides.
- [ ] Add a fuller graphics settings hierarchy with explicit VSync, frame pacing, and advanced options.
- [ ] Implement hardware-aware preset recommendations using detected GPU capabilities and measured performance.
- [ ] Surface Vulkan capability and driver details in the launcher's Diagnostics page; runtime startup logging is implemented, but launcher-side reporting remains outstanding.
- [ ] Benchmark the Intel Iris Xe target and a discrete GPU, and tune defaults from measured results.
- [ ] Validate both the AVX2/FMA x86-64-v3 build and the x86-64-v2 compatibility build on real hardware; select the correct executable automatically and verify equivalent gameplay behaviour.
- [ ] Verify graphics options do not alter deterministic game simulation; presentation interpolation must remain a render-only operation and must not advance gameplay state.
- [x] Add opt-in measurements for previous-frame GPU retirement waits and presentation-image pool waits; see [GPU frame pacing and simulation decoupling](GPU_FRAME_PACING.md).
- [x] Replace the GPU command-submission and timeline-retirement deques with fixed 256-entry circular buffers and producer back-pressure; preserve all submissions and guest-visible writebacks. This bounds backlog memory but does not yet decouple simulation from GPU completion.
- [x] Bound asynchronous shader compilation to at most four workers and 64 queued jobs, with failed jobs transitioned out of the pending state.
- [x] Report the selected Vulkan device, driver, API version, vendor/device IDs, memory heaps, and enabled optional capabilities in the runtime log.
- [x] Filter Vulkan adapters by the renderer's required Vulkan 1.3 features and a combined graphics/compute queue before preferring a discrete GPU, allowing fallback to a compatible integrated GPU.
- [ ] Capture and compare repeatable GPU/CPU frame-time baselines on the Intel Iris Xe target and a discrete GPU.
- [x] Bound startup Vulkan pipeline prewarming to at most four workers, seed worker-local caches from the persisted driver cache, merge them after compilation, and serialize shared runtime-cache access.
- [ ] Pass the new Windows CI job that compiles the complete Vulkan runtime with pinned Vulkan headers, shaderc, SDL3, and runtime dependencies; the job has been added but has not yet completed successfully.
- [ ] Audit and implement the Smash Wii U GX2 paths exercised by the game, including unsupported geometry-shader/tessellation/stream-out draws, blend/ROP3 modes, and any unsupported target or texture formats found in real-game logs.
- [ ] Verify boot, title screen, character select, full match, pause, results, and repeated scene transitions with Vulkan validation enabled; fix every reproducible rendering or synchronization error.
- [ ] Validate the Vulkan backend against identical deterministic Smash Wii U scenes on the target integrated GPU and at least one discrete GPU. Alternative graphics backends are deferred until after the first complete playable release.
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

- [ ] Pass Windows CI for the complete Vulkan runtime build; a dedicated compile job has been added and is awaiting its first successful run.
- [x] Add Windows CI that compiles and links the redistributable launcher target and compiles the bounded WUA extractor.
- [x] Add a Windows launcher package with a file manifest and SHA-256 sidecar; embed the game-data-free local build kit while excluding game runtime binaries, generated game code, and user game data.
- [x] Add a tag-triggered versioned release workflow that verifies the launcher version, package root layout, and per-file manifest hashes before publishing the ZIP and checksum assets.
- [ ] Test clean installation, upgrade, rollback, and user-data preservation on a clean Windows machine.
