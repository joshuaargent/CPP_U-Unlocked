# HP EliteBook 640 G9 — initial performance profile

## Confirmed by the user

- Laptop family: HP EliteBook 640 G9.
- Processor: Intel Core i5 model (exact SKU not yet confirmed).
- Graphics: Intel Iris Xe integrated graphics (user's current identification).
- Memory: 16 GB RAM.

These are provisional hardware details, not a verified hardware inventory. Do not infer an exact CPU SKU, GPU device ID, memory-channel configuration, display refresh rate or driver version.

## Engineering implications

- Treat the Iris Xe as an integrated GPU using shared system memory; do not expose a fictitious dedicated-VRAM budget.
- Preserve the upstream x86-64-v2 compatibility build. Detect AVX2/FMA support at runtime before choosing the faster x86-64-v3 executable.
- Require and report Vulkan 1.3 capability as the upstream project does. Show the adapter name and driver version in diagnostics.
- Keep shader compilation bounded and reuse the upstream cache. Avoid unnecessary texture duplication and large CPU-side staging buffers.
- Keep UI rendering inexpensive. Avoid large animated backgrounds, blur-heavy panels and continuous redraw when the window is idle.
- Provide a Low Spec preset that lowers rendering cost without altering deterministic simulation or input timing.
- Avoid parallel build settings that exhaust 16 GB RAM. The upstream build process lists approximately 16 GB as a requirement; a build may need memory headroom beyond the OS and background applications.

## Benchmark protocol

Record the following for every baseline and optimisation comparison:

| Measurement | Required record |
| --- | --- |
| CPU | Exact model and active power mode |
| GPU | Adapter name and driver version |
| Memory | Installed RAM and available RAM at launch |
| API | Vulkan version and supported device features |
| Display | Resolution, refresh rate, window/fullscreen |
| Game build | Upstream commit and generated build configuration |
| Settings | Render resolution, VSync, frame cap, preset |
| Runtime | Average frame time, 1% low frame time, CPU/GPU utilisation |
| Memory | Process working set and peak working set |
| Shader cache | Cold or warm; first-run compilation time |
| Test | Same game mode, stage, fighter count and test duration |

Use the same repeatable test scene and run each configuration more than once. Do not compare a cold shader-cache run with a warm-cache run. Do not claim a stable frame rate from a short menu-only test.

## Default policy

Until a benchmark is completed, retain upstream defaults and expose conservative options. Do not hard-code a 640 G9-specific resolution, frame cap or quality level based only on the model family.
