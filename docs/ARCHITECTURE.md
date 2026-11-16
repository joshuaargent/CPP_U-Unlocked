# U Unlocked — Architecture and Engineering Plan

## Product direction

U Unlocked is a Windows-first native PC platform for Super Smash Bros. for Wii U. The project reuses the existing Smash4PC static-recompilation and Wii U runtime rather than attempting a second implementation of the game engine.

The Windows application should take product-design inspiration from Melee Unlocked: a polished dark interface, clear navigation, integrated settings, controller configuration, mod management, diagnostics and practical performance presets. Melee Unlocked is a design reference only. Its GPL-licensed source is not a code dependency.

## Source foundation and provenance

The Smash4PC repository is included as the `upstream` Git submodule:

- Repository: https://github.com/josiahg2502-glitch/Smash4PC
- Pinned upstream commit: `f145e7fc14d0be2caf712cc4080f9deb3e7ab6aa`
- Upstream release represented by that commit: `v0.1.2`
- Upstream project license: MIT; third-party dependencies retain their own licenses.

The pin makes builds reproducible and avoids silently taking upstream changes. Update it only in a reviewed PR after inspecting the upstream diff, licenses, build scripts and compatibility implications.

Do not make untracked edits inside the submodule as the permanent home for U Unlocked changes. Keep new implementation in this repository. Where upstream source must be changed, maintain a reviewed patch or a deliberate upstream fork/commit and make its application deterministic. Never commit generated game code or user game files.

## Technical foundation

- Primary language: C++20.
- Build system: CMake and Ninja, using the upstream Windows build scripts initially.
- Runtime: retain Smash4PC static recompilation, Vulkan renderer, SDL3 input layer and Wii U compatibility/runtime.
- Launcher: retain SDL3 initially; do not replace the rendering/UI framework until profiling and a focused prototype justify it.
- Supporting tools: Python and PowerShell for build, packaging, asset processing and validation; versioned JSON for new portable profiles.
- Platform: Windows 10/11 x64.

## UX principles

1. Match the quality bar of Melee Unlocked: deliberate spacing, typography, alignment, consistent component states, keyboard/controller navigation, DPI-aware layouts, useful empty/error states and no placeholder artwork in releases.
2. Rebrand every user-facing surface as U Unlocked. Keep compatibility identifiers and internal paths stable when changing them could break installs, saves, mods or online functionality.
3. Keep the launcher responsive and lightweight. Avoid expensive blur, continuously animated backgrounds, large uncompressed images, unnecessary polling and blocking work on the UI thread.
4. Use shared design tokens for spacing, typography, colour, focus/hover/pressed/disabled states and reusable controls.
5. Provide keyboard navigation, readable contrast, scalable UI, clear focus indicators and actionable error messages.

## Feature architecture

### Launcher and first-run setup

- Home / Play: game, update and DLC folder detection; validation; launch configuration; recent launch status.
- First-run flow: explain required game folders, validate title IDs and versions, and keep all user data outside the repository.
- Controls: controller discovery, per-player device assignment, button remapping, stick/trigger calibration, dead zones, profiles, reset and live input tester.
- Graphics: window/fullscreen, resolution, frame pacing/cap, VSync and renderer options exposed only when supported.
- Mods: install, enable/disable, profiles, manifests, dependency/conflict reporting and safe rollback.
- Settings: paths, audio, language, diagnostics and update preferences.

### Input and Cemu profile compatibility

Build on SDL3's existing device abstraction. Keep physical-device discovery separate from logical Wii U controller mapping.

Persist versioned profiles with stable device GUID/name hints and per-port assignments. Never silently change a user's mappings after an update. Provide defaults for Xbox, PlayStation, Nintendo and generic SDL controllers, while allowing complete remapping.

The intended interaction is Cemu-like: select a physical device, select the emulated Wii U controller, activate a control, press the physical input, test it, and save the profile. Cemu profile import is not assumed to work. Inspect the real Cemu profile schema and mapping semantics first, then implement a validated importer with a preview and no destructive overwrite.

### Mod management

Preserve existing Smash4PC content/graphic-pack support. Add a versioned manifest, per-profile enabled state, file ownership/conflict detection, dependency checks and transactional install/uninstall. Do not overwrite user data silently. Back up affected files and provide rollback.

Keep the U Unlocked game modpack independently versioned from the launcher/runtime. Mods remain user-supplied unless redistribution permissions are explicit.

## Initial hardware target: HP EliteBook 640 G9

The initial target is provisionally an Intel Core i5 model with Intel Iris Xe graphics and 16 GB RAM. The exact CPU model, memory configuration, display and driver version have not yet been confirmed. Do not hard-code assumptions from the laptop model name.

At runtime, detect CPU instruction-set support, available memory, GPU vendor/device, Vulkan API and feature support, display resolution and refresh rate. Iris Xe uses system memory; avoid assumptions about dedicated VRAM.

Provide:
- An automatic recommended preset based on detected capabilities.
- Low Spec, Balanced and Quality profiles.
- A Low Spec profile that reduces render resolution/scale, expensive post-processing, texture filtering and other GPU costs without changing deterministic game simulation or gameplay timing.
- A safe fallback for unsupported Vulkan features and clear diagnostics for driver problems.
- Shader/pipeline cache reuse, bounded background compilation, no unnecessary per-frame allocations and profiling before speculative optimisation.
- Frame pacing that keeps game simulation timing separate from display presentation.

The upstream build already has an x86-64-v2 compatibility executable for CPUs without AVX2/FMA. Preserve that fallback and verify CPU dispatch rather than assuming every i5 model supports the faster binary.

Do not set final graphics defaults until a benchmark has been run on the actual laptop. Record CPU/GPU, driver, display mode, resolution, preset, average frame time, 1% lows, memory use and shader-cache state.

## Licensing and data boundaries

- Preserve the upstream Smash4PC MIT license and every third-party license/notice.
- Melee Unlocked is GPL-3.0-or-later; its code must not be copied into this project without an explicit licensing decision.
- Do not commit Nintendo game data, generated recompiled game code, console files, keys, user saves or proprietary assets.
- Keep build output, local toolchains, caches and user data out of Git.

## Quality gates

Every implementation PR must:
1. Build affected targets in Release and Debug where supported.
2. Run unit tests and relevant integration/launcher tests.
3. Run formatting/static analysis available in the repository.
4. Verify settings migration and backward compatibility.
5. Test keyboard-only navigation and controller navigation for UI changes.
6. Test on the HP EliteBook and record the benchmark data listed above.
7. Include screenshots for UI changes at standard and high-DPI scaling.
8. Include a reviewed diff and concise test report. Do not mark unbuilt code as verified.

## Delivery sequence

1. Pin and document the Smash4PC source; establish a reproducible local checkout and baseline build.
2. Audit the full source tree, licenses, launcher, input handling, settings and packaging scripts.
3. Establish project-owned build orchestration and CI that validates actual Windows targets.
4. Replace upstream branding and implement the U Unlocked launcher design system.
5. Implement Cemu-style controller configuration, profile persistence, testing and validated import.
6. Improve graphics/settings UX and add measured Low Spec, Balanced and Quality presets.
7. Expand the mod manager with profiles, manifests, conflict checks and rollback.
8. Package the launcher, runtime and required redistributables without bundling copyrighted game data.
9. Run regression, security, performance and release audits.

This document records the architecture and delivery requirements. It is not a claim that the planned features have already shipped.
