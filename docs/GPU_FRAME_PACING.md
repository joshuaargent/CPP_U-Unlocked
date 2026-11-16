# GPU frame pacing and simulation decoupling

## Status

The guest display clock and Vulkan presentation thread are separate from the command processor, but guest simulation is **not yet independent of GPU completion**. Do not describe the runtime as maintaining 59.94 simulation updates per second under a GPU bottleneck until the stress tests in this document pass.

The current implementation deliberately retains synchronization. The first change in this workstream adds opt-in measurements; it does not change frame timing or resource ownership.

Enable the measurements with:

```powershell
$env:TTT2_TRACE_PACING = "1"
'.\Play\U Unlocked.exe'
```

The command processor reports the average and maximum time spent waiting for the previous frame's GPU retirement over each 60-frame window. The renderer's command-processor path reports waits for a free presentation image and when it reuses an older queued image. These are separate sources of back-pressure and must be measured independently.

## Current synchronization points

### Guest frame completion

`engine/runtime/src/gpu/command_processor.cpp`, in the `pm4::kHleSwapBuffers` handler:

1. The Vulkan backend flushes the current frame and returns a timeline-semaphore value.
2. The command processor waits for the preceding frame's timeline value.
3. Only then does it call `frame_ready()`.
4. Guest display/vblank accounting can consequently advance only after this GPU dependency has completed.

This is intentionally limited to one frame of GPU work in flight. Removing the wait without changing the memory model is unsafe.

### Guest memory is directly visible to Vulkan

`engine/runtime/src/gpu/vulkan/context.cpp` imports committed MEM1/MEM2 host allocations with `VK_EXT_external_memory_host`. `GuestMemory::device_address()` exposes device addresses into those live guest allocations.

`engine/runtime/src/gpu/vulkan/draw.cpp` uses those addresses in `buffer_descriptor()` for shader constant buffers, shader buffer resources, and vertex attributes. Index data and per-draw constants are copied into the upload ring in their respective paths, but that does not snapshot every buffer a shader or vertex fetch can read.

The renderer header explicitly documents that the current command processor / renderer contract is synchronous because guest memory read in place must not change while Vulkan is using it. The guest CPU can reuse or modify those allocations as soon as it advances. A frame queue alone does not make those reads safe.

### Presentation image pressure

`engine/runtime/src/gpu/vulkan/present.cpp` has a pool of 12 presentation images. `take_present_image()` normally waits for an image to become free. When the display is stalled, it may reuse the oldest queued image after a 20 ms wait, but it can still block if no queued image can be superseded.

The presentation queue and image pool are independent of the command processor's GPU timeline. Increasing the number of command frames in flight without accounting for this pool can merely move the stall.

### Other renderer and command-queue waits

- `Renderer::cmd()` rotates through 64 Vulkan command-buffer slots and waits for a slot's previous timeline value before reusing it.
- `Renderer::upload()` waits for upload-ring chunks when they are still referenced by submitted work.
- Explicit GX2 synchronization, resource resizing/destruction, stream changes, and diagnostic captures can call `submit(true)` and wait for all prior renderer submissions.
- The Vulkan renderer already reports waits per frame for command slots, upload chunks, explicit sync, and other waits in its periodic GPU statistics. `TTT2_TRACE_PACING=1` also enables swap-to-vblank timing and the new frame/presentation-pool measurements.
- The command processor's guest submission queue (`g_queue`) and GPU retirement queue (`g_retire_queue`) are deques without explicit capacity limits. A decoupled producer must not turn these into unbounded memory growth.
- Each command-processor queue item currently stores a guest command-buffer address and word count, not an owned copy. Any producer/consumer separation must establish command-buffer and indirect-buffer lifetime before allowing the guest CPU to reuse that memory.

### GPU-visible side effects

GPU writebacks, end-of-pipe writes, timestamps, stream-out, and guest waits have observable ordering. The retirement thread processes backend completion values in order and makes those results visible to guest memory. Any decoupling must preserve these semantics; a completed simulation tick must not imply that an unfinished GPU writeback is already visible to the guest.

## Required design

The target is a deterministic guest simulation clock at the title's 59.94 Hz cadence, independently scheduled from image production and host presentation. The renderer may produce fewer than 59.94 new images per second when the hardware cannot keep up; presentation may repeat the latest completed image. Do not run gameplay, physics, collision, input sampling, or netplay simulation faster to compensate for a slow renderer.

A safe implementation needs all of the following:

1. **Explicit submission ownership.** Every command buffer, indirect buffer, draw argument, resource descriptor, and guest-memory range referenced by pending GPU work must have a defined lifetime. No queued submission may retain an unowned pointer into mutable guest memory.
2. **GPU-read snapshots.** Snapshot the vertex attributes, shader buffer resources, uniform/constant ranges, and any other guest memory read asynchronously. Use a bounded, aligned staging/upload allocator and deduplicate copies only when a tracked write-generation proves the source has not changed. Do not assume the interpolation-only constant snapshot path covers normal rendering.
3. **Ordered GPU side effects.** Keep stream-out, render-target writeback, EOP writes, timestamp retirement, cache invalidation, and guest-visible fences in command order. Guest reads that depend on GPU writes must still wait for the relevant retirement value.
4. **A bounded workload policy.** Bound queued simulation/render submissions and presentation images. When the renderer falls behind, stale visual work may only be skipped after proving that doing so cannot omit guest-visible GPU side effects. Never allow an unbounded queue or silently discard synchronization operations.
5. **Resource retirement.** Defer destruction and reuse of buffers, images, descriptors, upload-ring chunks, and staging allocations until the timeline value that last references them has completed. Avoid global device-idle waits in normal frame operation.
6. **Independent presentation.** The presentation thread should consume completed images without blocking the simulation clock. If no new image is ready, repeat the last valid image. Reuse or drop only images that are no longer being read by the presentation engine.
7. **Input, audio, and Netplay contracts.** Define exactly which simulation tick samples each input, how audio is clocked when rendering falls behind, and how deterministic Netplay advances. Rendering stalls must not change input order or simulation tick count.

A bounded frames-in-flight count by itself is not the solution. If every simulation tick continues to enqueue a full render workload and the GPU is slower, a bounded queue eventually blocks the producer. The implementation must define which render-only work can be coalesced or skipped while preserving the guest-visible effects above, or provide another proven way to separate simulation progress from render production.

## Implementation sequence

- [x] Add opt-in timing for the command processor's previous-frame GPU retirement wait.
- [x] Add opt-in timing for presentation-image pool waits and queued-image reuse.
- [ ] Capture baseline measurements on the target Intel Iris Xe laptop and on a faster discrete GPU.
- [ ] Inventory every direct guest-memory GPU read and write, including vertex attributes, constant buffers, shader storage/buffer resources, index data, stream-out, and writeback targets.
- [ ] Introduce submission-owned snapshots and write-generation tracking; add tests for guest writes after submission and before GPU completion.
- [ ] Introduce timeline-based deferred resource retirement for every object that can outlive command recording.
- [ ] Specify and implement a bounded render-work policy that preserves non-rendering GPU side effects.
- [ ] Decouple guest frame/vblank readiness from GPU image readiness without changing the guest's 59.94 Hz simulation contract.
- [ ] Make presentation-image acquisition non-blocking for the simulation producer; repeat the latest completed image when the pool is exhausted.
- [ ] Add deterministic tests for timestamp/EOP ordering, stream-out, guest-visible writeback, resource reuse, and queue saturation.
- [ ] Stress at simulated 30 FPS and 45 FPS render throughput while asserting approximately 59.94 guest simulation ticks per second, bounded memory/queues, stable input sampling, audio timing, and deterministic Netplay state.
- [ ] Run long-duration gameplay and scene-transition tests before enabling more than one frame in flight by default.

## Acceptance criteria

The work is complete only when:

- Guest simulation timing remains at the title's expected 59.94 Hz cadence during sustained 30 FPS and 45 FPS rendering tests, within a documented scheduler tolerance.
- Rendering presents the newest completed frame and repeats it when no newer frame is ready; it never displays a partially rendered image.
- Queue and staging memory remain bounded during prolonged GPU overload.
- GPU writes, timestamps, EOP events, stream-out, cache coherency, and guest fences remain ordered and correct.
- Input, audio, and Netplay remain deterministic and are not advanced by presentation interpolation.
- The same tests pass with the null backend and the Vulkan backend, with backend-specific expectations documented.
