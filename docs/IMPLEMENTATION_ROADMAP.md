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

- [ ] Replace the starter launcher layout with the U Unlocked design system.
- [ ] Implement responsive navigation, DPI scaling, focus states, and controller navigation.
- [ ] Add Home, Controls, Mods, Graphics, Settings, Library, Updates, and Diagnostics sections.
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
- [ ] Implement Cemu XML import with explicit mapping translation and preview.
- [x] Add automated tests for axis normalization, dead zones, inversion, profile persistence, and invalid-save protection.
- [ ] Add tests for reconnects, ambiguous device identities, and multi-controller setups.

## Graphics and performance

- [ ] Implement display mode, resolution, VSync, frame pacing, and scaling controls.
- [ ] Implement Low Spec, Balanced, and Quality presets.
- [ ] Add CPU/GPU/Vulkan capability detection and diagnostics.
- [ ] Benchmark the HP EliteBook 640 G9 and tune defaults from measured results.
- [ ] Verify graphics options do not alter deterministic game simulation.

## Mod management

- [ ] Implement a versioned mod manifest.
- [ ] Implement archive/folder installation with path traversal protection.
- [ ] Implement enable/disable profiles, dependency checks, and conflict reporting.
- [ ] Implement transactional file changes, backups, and rollback.
- [ ] Package the project-owned mod only after its contents and redistribution rights are verified.

## Release engineering

- [ ] Add Windows build validation for the actual native targets.
- [ ] Add reproducible packaging and output verification.
- [ ] Add versioned release workflow after the package format is stable.
- [ ] Test clean installation, upgrade, rollback, and user-data preservation.
