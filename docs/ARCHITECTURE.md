# U Unlocked — Architecture and Engineering Plan

## Product direction

U Unlocked is a Windows-first, native PC platform for Super Smash Bros. for Wii U, built on the existing Smash4PC static-recompilation/runtime project. Its launcher and in-game settings should take product-design inspiration from Melee Unlocked: a polished dark interface, clear navigation, integrated settings, controller configuration, mod management, diagnostics, and practical low-spec controls.

This is an independent project. Melee Unlocked is a visual and feature reference, not a source-code dependency. Do not copy its GPL-licensed implementation into the MIT-licensed Smash4PC-derived codebase without an explicit licensing decision. Reimplement equivalent UX using the existing project's architecture and preserve all third-party notices.

## Technical foundation

- Primary language: C++.
- Build system: CMake and the existing Windows build scripts.
- Runtime: retain Smash4PC's static recompilation, Vulkan renderer, SDL3 input layer, and Wii U compatibility/runtime implementation.
- Launcher: retain the existing SDL3 launcher initially; do not replace the UI framework until profiling and a focused prototype prove a better option.
- Supporting tools: Python and PowerShell for build, packaging, asset processing, and validation; JSON for manifests and portable profiles.
- Target: Windows 10/11 x64, with performance tiers and runtime capability detection.

## UX principles

1. Match the quality bar of Melee Unlocked: deliberate spacing, typography, alignment, consistent component states, keyboard/controller navigation, DPI-aware layouts, useful empty/error states, and no placeholder artwork in releases.
2. Rebrand every user-facing surface as U Unlocked. Keep compatibility identifiers and internal paths stable when changing them would break existing installs, saves, mods, or online functionality.
3. Keep the launcher fast and lightweight. Avoid expensive blur, continuously animated backgrounds, large uncompressed images, unnecessary polling, and blocking work on the UI thread.
4. Use a shared design system: spacing scale, typography scale, colour tokens, focus/hover/pressed/disabled states, reusable controls, and responsive layout rules.
5. Accessibility and usability are requirements: keyboard navigation, readable contrast, scalable UI, clear focus indicators, and actionable error messages.

## Feature architecture

### Launcher
- Home / Play: game, update and DLC folder detection; validation; launch configuration; recent launch status.
- Controls: controller discovery, per-player device assignment, button remapping, stick/trigger calibration, dead zones, profiles, reset and live input tester.
- Graphics: window/fullscreen, resolution, frame pacing/cap, VSync and renderer options exposed only when supported.
- Mods: install, enable/disable, profiles, manifests, dependency and conflict reporting, safe rollback.
- Settings: paths, audio, language, diagnostics and update preferences.

### Input
- Build on SDL3's existing device abstraction.
- Keep physical-device discovery separate from logical Wii U controller mapping.
- Persist versioned profiles with stable device GUID/name hints and per-port assignments.
- Never silently change a user's mappings after an update.
- Provide defaults for Xbox, PlayStation, Nintendo and generic SDL controllers, while allowing complete remapping.
- Reuse Cemu-style interaction patterns (select device, select emulated controller, click an input, press a physical control, save profile), but do not assume Cemu configuration files are directly compatible. Import existing Cemu mappings only after their format and semantics are verified.

### Mods
- Preserve current Smash4PC content/graphic-pack support.
- Add a versioned manifest format, per-profile enabled state, file ownership/conflict detection, dependency checks and transactional install/uninstall.
- Do not overwrite user data silently. Back up affected files and provide rollback.
- Keep the U Unlocked game modpack independently versioned from the launcher/runtime.

## HP EliteBook 640 G9 performance target

The 640 G9 has multiple CPU, memory and graphics configurations. Do not hard-code assumptions based only on the model name. Detect CPU features, available memory, GPU vendor/device, Vulkan capabilities, display resolution and refresh rate at runtime.

Provide:
- An automatic recommended preset based on measured capabilities.
- A Low-spec preset that reduces render resolution/scale, expensive post-processing, texture filtering and other GPU costs without changing deterministic game simulation or gameplay timing.
- A Balanced preset suitable for integrated graphics.
- A Quality preset only when hardware headroom exists.
- A safe fallback for unsupported Vulkan features and clear diagnostics for driver problems.
- Shader/pipeline cache reuse, bounded background compilation, no unnecessary per-frame allocations, and profiling before speculative optimisation.
- Frame pacing that keeps the game simulation's required timing separate from display presentation. Never claim higher gameplay simulation rates unless the engine actually supports them.

Do not assume every 640 G9 has the same Iris Xe configuration. Benchmark on the actual machine before selecting defaults.

## Licensing and upstream reuse

- Smash4PC identifies its own code as MIT; preserve its LICENSE and attribution.
- Preserve licenses and notices for every dependency and imported upstream component.
- Melee Unlocked identifies its project as GPL-3.0-or-later (with older history under GPL-2.0-or-later). Its design can inform UX, but its code must not be copied into this codebase without resolving the resulting license obligations.
- Do not commit Nintendo game data, generated recompiled game code, console files, keys, user saves, or proprietary assets.
- Document source provenance for every imported code directory.

## Quality gates

Every implementation PR must:
1. Build the affected targets in Release and Debug where supported.
2. Run unit tests and relevant integration/launcher tests.
3. Run formatting/static analysis available in the repository.
4. Verify settings migration and backward compatibility.
5. Test keyboard-only navigation and controller navigation for UI changes.
6. Test on the HP EliteBook 640 G9 and record CPU/GPU, resolution, settings, average frame time, 1% lows, memory use and shader-cache state.
7. Include screenshots for UI changes at standard and high-DPI scaling.
8. Include a reviewed diff and a concise test report. Do not mark unbuilt code as verified.

## Delivery sequence

1. Import and audit the Smash4PC source into this repository while preserving provenance and license notices.
2. Establish a reproducible Windows build and CI baseline.
3. Profile the unmodified build on the target EliteBook.
4. Implement U Unlocked branding and a polished launcher design system.
5. Implement Cemu-style controller configuration and profile persistence.
6. Improve graphics/settings UX and add measured low-spec presets.
7. Expand the mod manager and introduce U Unlocked mod profiles.
8. Package the launcher, runtime, required redistributables and optional modpack without bundling copyrighted game data.
9. Run regression, security, performance and release audits.

This document is a plan, not a claim that these features have already been implemented.
