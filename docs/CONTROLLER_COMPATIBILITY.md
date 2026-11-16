# Controller configuration and Cemu profile compatibility

## Current runtime input layer

The Windows runtime uses SDL3 for physical gamepad discovery and events. The launcher exposes per-device physical button/axis remapping, per-player assignment, per-axis dead zones, stick inversion, trigger thresholds, and a live input monitor. The runtime translates these profiles into Wii U GamePad and Pro Controller state.

The runtime integration points are the controller profile module and pad-state routing in `engine/runtime/src/host/window.cpp`. Preserve remote-pad routing, virtual-pad test hooks, and the distinction between Wii U GamePad and Pro Controller state.

## Cemu profile format

Cemu stores named controller profiles as XML files in its `controllerProfiles/` configuration directory. Its profile loader/saver uses an `emulated_controller` root element with:

- `type`: emulated Wii U controller type.
- `profile`: optional saved profile name.
- One or more `controller` elements, each with `api`, `uuid`, and `display_name`.
- Optional per-controller `axis`, `rotation`, and `trigger` settings containing `deadzone` and `range`.
- Optional `rumble` and `motion` settings.
- `mappings/entry` elements containing numeric `mapping` and `button` values.

References:
- Cemu controller profile loader/saver: https://github.com/cemu-project/Cemu/blob/main/src/input/InputManager.cpp
- Cemu controller setup guide: https://cemu.cfw.guide/controller-configuration.html

## Implemented import scope

The importer is deliberately limited to Cemu profiles containing an `SDLController` entry and an emulated type of `Wii U GamePad` or `Wii U Pro Controller`.

- The XML parser is TinyXML-2. Files are limited to 1 MiB and malformed XML, missing required elements, unsupported controller types, and profiles without an SDLController entry are rejected.
- Cemu logical mapping IDs are translated using separate GamePad and Pro Controller tables. Physical SDL button and axis identifiers are translated through explicit lookup tables; numeric IDs are never cast directly to SDL enums.
- The importer prefers a controller UUID matching the currently selected device. A mismatch is reported for review; it does not silently claim the devices are identical.
- Stick and trigger dead zones are imported. The Cemu stick dead zone is applied to both axes of the relevant stick as an approximation of Cemu's radial processing.
- Cemu range, rumble, motion, non-SDL APIs, unsupported controls, and conflicting mappings are not silently discarded: the import report records warnings and skipped mappings.
- Imported settings are loaded into the Controls page in memory only. The source XML and saved U Unlocked profile are not changed until the user explicitly selects Save Profile.

The importer does not yet import XInput, DirectInput, DSU, motion, rumble, or Cemu range/gain settings. It does not claim byte-for-byte equivalence with Cemu's radial dead-zone algorithm.

## U Unlocked profile model

The project-owned profile format should be versioned and independent of Cemu's XML format. It should represent:

- Profile schema version and user-facing name.
- Emulated device type: Wii U GamePad or Wii U Pro Controller.
- Physical device identity hints: SDL GUID, vendor/product IDs, device name, and optional serial.
- Button-to-logical-input bindings.
- Axis bindings, inversion, dead zone, saturation/range, and trigger threshold.
- Per-player assignment and profile selection.

Use a bounded parser, validate every enum/range, write settings atomically, keep a backup of the last valid profile, and fall back to defaults with a visible diagnostic when a profile is invalid.

## Cemu-like configuration UX

1. Select the physical controller and emulated Wii U controller type.
2. Select an action (A, B, X, Y, D-pad, shoulders, triggers, sticks, Plus, Minus, Home).
3. Press the physical button or move the desired axis to bind it.
4. Calibrate sticks and triggers; adjust dead zones and inversion.
5. Test the live mapping in a visual input monitor.
6. Save, rename, duplicate, reset, export, or import a profile.
7. Assign a different profile to each player slot.

The interface must support keyboard-only operation and gamepad navigation. Binding mode needs a timeout, cancel action, reserved-input handling, and a clear indication of which physical device is being listened to.
