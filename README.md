# U Unlocked

U Unlocked is a Windows-first PC platform for Super Smash Bros. for Wii U, built on the Smash4PC static-recompilation/runtime project.

The product direction takes UX inspiration from Melee Unlocked: a polished dark interface, integrated settings, controller configuration, mod management, diagnostics and practical performance presets. U Unlocked is an independent project; Melee Unlocked is a design reference, not a code dependency.

## Current status

The repository is at its foundation stage. The implementation source from Smash4PC has not yet been imported, and no game/runtime or launcher changes are claimed as complete.

See [Architecture and Engineering Plan](docs/ARCHITECTURE.md) for the technical direction, licensing rules, HP EliteBook 640 G9 performance target, feature architecture and verification requirements.

## Planned technical foundation

- C++ and CMake
- Existing Smash4PC static recompilation/runtime and Vulkan renderer
- SDL3 input and controller support
- Windows 10/11 x64
- Python and PowerShell for build and packaging automation

## Legal and data requirements

U Unlocked does not distribute Nintendo game data, keys, console files, user saves or generated recompiled game code. Users must supply their own legally obtained game files. Preserve upstream and third-party licenses and notices.

Smash4PC identifies its own code as MIT. Melee Unlocked is GPL-3.0-or-later; its visual design and feature set may inform independent implementation, but its code must not be copied into this repository without an explicit licensing decision.
