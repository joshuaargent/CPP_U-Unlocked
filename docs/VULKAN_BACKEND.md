# Vulkan backend strategy and performance

## Current decision

The game renderer remains a native Vulkan backend with a Vulkan 1.3 minimum. This is deliberate: Vulkan 1.3 provides the core dynamic-rendering and synchronization2 interfaces used by the renderer while preserving a wider driver baseline than requiring Vulkan 1.4. A driver that exposes Vulkan 1.4 can still run this Vulkan 1.3 application.

The renderer already uses several performance-oriented mechanisms:

- External host-memory import for guest MEM1/MEM2, plus buffer device addresses, to avoid copying every guest buffer before drawing. This is fast but creates the guest-memory lifetime hazard documented in [GPU frame pacing](GPU_FRAME_PACING.md).
- Timeline semaphores for submission retirement and command-slot/upload-ring reuse.
- Synchronization2 and dynamic rendering.
- A 256 MiB upload ring and a rotating command-buffer slot pool.
- Shader translation and compilation on worker threads, on-disk SPIR-V caching, shader/pipeline reuse, and a Vulkan pipeline cache.
- GPU timestamp queries and wait-category statistics.
- Optional custom border colour, present-wait support, and device-fault reporting when the driver exposes those capabilities.
- A separate presentation thread and presentation-image pool.

These mechanisms make this a serious low-level renderer, but they do not prove it is optimal. The biggest known performance limitation is still CPU/GPU coupling: the command processor waits for prior GPU work at frame completion, and some paths wait for presentation images or renderer resources. Optimising those waits safely is more valuable than changing the API version.

## Vulkan 1.4

The current Khronos specification is Vulkan 1.4.368 (6 November 2026). Vulkan 1.4 promotes and standardises additional features, including dynamic-rendering local read, maintenance improvements, push descriptors, and host image copy. It does not automatically make an existing Vulkan 1.3 renderer faster. Most of those features do not remove our current guest-memory ownership and frame-retirement constraints.

Do not raise the minimum to Vulkan 1.4 just to use a newer version number. Keep 1.3 as the compatibility baseline and query optional 1.4 capabilities individually. Adopt a feature only when a concrete renderer path can use it, correctness tests pass, and measurements show an improvement on both integrated and discrete GPUs.

Official references:
- [Vulkan 1.4 specification](https://registry.khronos.org/vulkan/specs/latest/html/vkspec.html)
- [Vulkan 1.4 core revision notes](https://github.khronos.org/Vulkan-Site/spec/latest/appendices/versions.html)
- [Vulkan versions and porting guide](https://github.khronos.org/Vulkan-Site/guide/latest/versions.html)

## Backend scope

Vulkan is the only graphics backend in the first playable release. Do not spend release-critical development time on D3D11, D3D12, OpenGL, SDL_GPU, backend selection, or cross-backend abstractions. Revisit alternatives only after the Wii U game boots reliably, the required GX2 feature set is implemented, and a complete release has passed real-game testing. The Vulkan renderer should remain focused on the Wii U Latte/GX2 workload rather than carrying speculative portability layers.

## Immediate optimisation priorities

1. Preserve the Vulkan 1.3 baseline and report the selected GPU, driver, API version, vendor/device IDs, memory heaps, and enabled optional capabilities at runtime.
2. Bound shader compilation concurrency and queued work so first-run shader discovery cannot oversubscribe a low-memory laptop.
3. Profile CPU submission time, shader compilation, pipeline creation, upload-ring waits, command-slot waits, GPU execution time, and presentation waits separately.
4. Replace unsafe frame-completion coupling only after submission-owned snapshots, write-generation tracking, deferred resource retirement, and bounded render-work scheduling exist.
5. Tune render scale and presets from GPU timestamps and repeatable benchmark scenes, not device-name guesses.
6. Keep Vulkan 1.3 as the minimum. Evaluate optional Vulkan features individually and adopt them only when Smash Wii U correctness tests pass and repeatable measurements show a benefit.

## Hardware policy

The initial reference machine is an Intel Iris Xe integrated GPU with 16 GB system memory. The Vulkan backend must therefore avoid unbounded shader jobs, large transient allocations, unnecessary device-idle waits, and high-resolution defaults that have not been measured. The 256 MiB upload ring and presentation pool should be profiled under sustained gameplay and memory pressure. Integrated GPUs share system memory; a reported device-local heap size is a driver capability report, not a guarantee that all of it is available to this process.

Vulkan remains the sole production backend for the first playable release. Validate it on the target integrated GPU and at least one discrete GPU using identical Smash Wii U scenes, with correctness and frame-time results recorded.
