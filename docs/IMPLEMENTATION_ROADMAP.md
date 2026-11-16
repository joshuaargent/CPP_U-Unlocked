# U Unlocked implementation roadmap

This roadmap separates verified foundation work from planned product features. A milestone is complete only when its acceptance checks pass.

## Milestone 0 — Source foundation

- [x] Establish U Unlocked product direction and technical architecture.
- [x] Match the repository README structure to the CathoScroll project README.
- [ ] Pin Smash4PC as a Git submodule and verify clean recursive checkout.
- [ ] Verify the upstream license and preserve its third-party notices.
- [ ] Run the upstream Windows build on a supported machine with user-supplied game files.
- [ ] Record the exact compiler/toolchain, build output and baseline performance.

## Milestone 1 — Source and build audit

- [ ] Inventory every upstream directory, target, dependency and license.
- [ ] Map launcher screens, input event handling, display settings, config persistence and runtime launch contract.
- [ ] Audit file/path handling, archive extraction, process launching and update/package scripts.
- [ ] Identify stable extension points so U Unlocked changes do not become fragile source substitutions.
- [ ] Add a reproducible project-owned build entry point and Windows CI validation.

## Milestone 2 — U Unlocked identity and launcher

- [ ] Replace user-visible Smash4PC branding, window titles, executable names, icons and package metadata.
- [ ] Build a consistent dark UI design system inspired by the quality and interaction patterns of Melee Unlocked.
- [ ] Implement responsive navigation, focus states, keyboard/controller navigation and high-DPI scaling.
- [ ] Preserve the upstream runtime launch contract, settings compatibility and user data.
- [ ] Add first-run game/update/DLC validation and useful diagnostics.

## Milestone 3 — Controller configuration

- [ ] Discover SDL3 devices and show connection/disconnection state.
- [ ] Assign physical devices to logical Wii U controller ports.
- [ ] Implement press-to-bind button and axis mapping.
- [ ] Add stick calibration, dead zones, trigger thresholds and live input visualisation.
- [ ] Save, load, rename, duplicate, reset and export versioned profiles.
- [ ] Add Cemu profile import only after schema and semantics are verified; preview every imported mapping.

## Milestone 4 — Graphics and performance

- [ ] Expose only graphics settings supported by the current runtime and Vulkan device.
- [ ] Implement Low Spec, Balanced and Quality profiles.
- [ ] Keep display interpolation/presentation separate from game simulation timing.
- [ ] Add hardware and Vulkan diagnostics.
- [ ] Profile CPU/GPU frame time, allocations, shader compilation and memory on the target EliteBook.
- [ ] Set defaults only from repeatable measurements.

## Milestone 5 — Mod management

- [ ] Preserve existing content mods and Cemu graphic packs.
- [ ] Add mod manifests and metadata validation.
- [ ] Add enable/disable profiles and explicit load ordering where supported.
- [ ] Detect conflicting files and dependencies before applying changes.
- [ ] Make install/uninstall transactional with backups and rollback.
- [ ] Package the U Unlocked modpack only where redistribution rights are clear.

## Milestone 6 — Release quality

- [ ] Add PR build validation and static checks.
- [ ] Add tag-only release workflow after the packaging pipeline is reproducible.
- [ ] Verify expected artifacts and provenance before publishing.
- [ ] Test clean install, upgrade, user-data preservation and rollback.
- [ ] Complete security, performance, compatibility and legal-data audits.

## Definition of done

A feature is not complete because its UI exists. It must work end to end, persist correctly, handle failure safely, preserve existing user data, pass relevant tests and be documented. Performance claims require measurements from the stated hardware and settings.
