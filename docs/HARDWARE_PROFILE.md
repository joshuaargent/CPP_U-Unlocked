# HP EliteBook 640 G9 hardware profile

## Initial target

The initial development target is provisionally:

- Intel Core i5 processor.
- Intel Iris Xe integrated graphics.
- 16 GB system memory.
- Windows 10 or Windows 11.

The exact processor SKU, memory configuration, graphics driver, display resolution, and Vulkan device capabilities have not yet been confirmed. Treat this as a provisional target, not a verified benchmark result.

## Detection requirements

At startup and in Diagnostics, report:

- CPU model, logical processor count, supported instruction sets, and available memory.
- GPU vendor, device name, dedicated/shared memory where available, and driver version.
- Vulkan API version, supported extensions, and selected physical device.
- Display resolution, refresh rate, and scaling factor.

## Performance policy

- Keep gameplay simulation and deterministic timing independent from graphics presets.
- Preserve a compatible x86-64-v2 executable where the fast x86-64-v3 build is unsupported.
- Select the fast build only after checking AVX2/FMA support.
- Bound shader compilation work and reuse shader caches.
- Avoid unnecessary per-frame allocations, CPU/GPU synchronisation, and duplicate texture staging.
- Provide a one-click Low Spec preset, then Balanced and Quality presets.
- Do not hard-code a 640 G9-specific resolution, frame cap, or quality level based only on the model family.

## Benchmark record

No target-device benchmark has been completed yet. Record the following before changing defaults:

| Metric | Result |
| --- | --- |
| Exact CPU | Pending |
| RAM configuration | Pending |
| GPU and driver | Pending |
| Vulkan version | Pending |
| Display resolution / refresh | Pending |
| Graphics preset | Pending |
| Average frame time | Pending |
| 1% low frame time | Pending |
| Peak memory use | Pending |
| Shader compilation behaviour | Pending |

## Build memory

A full native build may use substantial memory. With 16 GB RAM, close memory-heavy applications before compiling, keep parallel build jobs conservative, and retain sufficient disk space for dependencies, generated code, and multiple build configurations.
