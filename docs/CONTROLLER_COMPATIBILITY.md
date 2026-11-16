# Controller configuration and Cemu profile compatibility

## Current runtime input layer

The Windows runtime uses SDL3 for physical gamepad discovery and events. The current implementation maps physical controls into Wii U GamePad and Pro Controller state, but does not yet expose a complete physical remapping interface.

The integration points are the existing pad-state mapping and update functions in `engine/runtime/src/host/window.cpp`. Preserve controller slot assignment, remote-pad routing, virtual-pad test hooks, and the distinction between Wii U GamePad and Pro Controller state.

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

## Import compatibility rules

Cemu numeric mapping/button values are Cemu-internal identifiers, not SDL3 button or axis enums. Its `uuid` is tied to the selected input API and must not be assumed to equal an SDL GUID. Copying those values directly into a U Unlocked profile would be incorrect.

The importer must:

1. Parse XML with a real XML parser and reject malformed or oversized files.
2. Validate the root, emulated controller type, and required fields.
3. Identify each controller API. Support only APIs with an explicit, tested translation path; show a clear unsupported-API warning for the rest.
4. Translate known mapping IDs through a versioned mapping table. Never cast numeric values directly to SDL enums.
5. Match a physical device using available vendor/product/name/serial/GUID hints. If the identifier cannot be matched reliably, ask the user to select the device.
6. Preserve supported dead-zone, range, trigger, and axis-inversion settings. Warn about unsupported motion/rumble/custom settings rather than silently dropping them.
7. Preview every translated mapping and show unmapped/ambiguous inputs before saving.
8. Save as a new U Unlocked profile. Never overwrite the source XML or an existing U Unlocked profile during import.

The first import target should be SDL-based profiles. Other APIs should be supported only after their identifiers and semantics are independently mapped and tested.

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
