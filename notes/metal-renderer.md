# Metal renderer: working notes

Notes on the experimental Metal renderer (Settings › General › Draw with
Metal): how its performance work fits together, how to measure it, and a
running log of what was found, newest first. **Observed** means seen on a
device or in logs. **Inferred** means a hypothesis that fits the evidence but
wasn't confirmed.

## How it works

### Culling

The renderer culls against the actual render camera before binding buffers
and textures and encoding indexed draws. Whole tiles are tested first; tiles
with several primitives also get a per-primitive test. This targets detailed
geometry behind the viewer and outside the viewport. It doesn't detect
geometry hidden behind other buildings.

It's render-only. Tile selection, refinement, loading and the all-around
streaming area are unchanged, so turning around can immediately draw content
that's already loaded. Each eye is tested separately, from its current
compositor projection and predicted pose. Held tiles use their current
render transform, like live tiles.

Bounds are computed once from the uploaded positions, before the CPU buffers
are discarded. A box is rejected only if it's wholly outside a homogeneous
clip plane. Crossing the eye or near plane, or touching a frustum boundary,
keeps it drawable, and so do missing bounds. Reverse Z, asymmetric eye
projections and tile and root transforms all go through the same clip matrix
as the vertex shader. The core test target covers these cases without a key
or GPU.

### Foveation (visionOS)

The immersive space enables foveation when the compositor supports it with
dedicated eye textures, and binds each texture's rasterization-rate map to its
render pass. Unsupported configurations keep the unfoveated dedicated or
shared layout. Stereo still uses a separate draw loop per eye; vertex
amplification would be a later change.

### Tracks

`MetalTrackRenderer` (Sources/Metal/MetalTrack.swift) draws the same tube
TrackOverlay builds for RealityKit: TubeExtruder now returns the triangles on
the CPU, TrackOverlay keeps the last build with a generation count, and each
host's track renderer uploads new buffers when that changes. It draws after
the tiles with the same reverse-Z depth test, before the sky-depth pass, at
the overlay root's transform (on a screen, in the scene; immersive, under
`placementRoot` and `root`, `MapModel.trackInImmersiveSpace`). Lit in the
track's orange by a light from above, without RealityKit's PBR. No culling:
one draw.

## Measuring

Environment variables:

- `ALSOMAPS_METAL=1`: use Metal for this run.
- `ALSOMAPS_METAL_STATS=1`: log submission counts once a second on macOS,
  iOS and immersive visionOS.
- `ALSOMAPS_METAL_CULLING=0`: turn culling off, for a baseline. On by default.
- `ALSOMAPS_METAL_FOVEATION=0`: turn visionOS foveation off, for a baseline.
  On by default where the dedicated layout supports it.

The log reports submitted out of considered tiles, draws and triangles,
summed over the interval. "Considered" is what would be submitted with
culling off, so one run gives both numbers. Stereo counts each eye
separately. These are CPU submission counts, not presented frames a second;
the screen FPS overlay counts RealityKit updates, and the immersive log counts
frame-loop iterations.

`MetalEncode` signposts (subsystem `dev.also.maps`, category `Frame`) cover
culling and draw encoding for one view; record and summarize them as in
[docs/profiling.md](../docs/profiling.md). Use Metal System Trace or GPU timing
for GPU execution and missed deadlines: fewer submitted triangles alone don't
prove a frame-rate gain.

For a controlled comparison, use a fixed saved view (New York at street level,
say) with culling on and off, the same drawable resolution and detail
settings, and a deliberately warm cache for both runs
([docs/tile-caching.md](../docs/tile-caching.md)). Measure settled idle,
movement and streaming separately. Check a full turn, the view's edges, both
eyes and near-plane crossings for missing geometry. On Vision Pro, compare
foveation separately with culling held fixed, and check peripheral image
quality, both eyes and compositor depth. The simulator can't show foveation
quality.

## Log

### 2026-11-08: system environments don't show behind the Metal layer

- **Decided:** the Metal space no longer asks to coexist with the system
  environment, so the system puts the environment away when it opens.
- **Observed (Vision Pro):** without `.coexist`, the Digital Crown does
  nothing in the Metal space, in mixed or full, so the black sky can't
  happen. Every state looks right.

With the Metal space in mixed immersion and `.immersiveEnvironmentBehavior(.coexist)`,
turning the Digital Crown to bring in a system environment. The tests
below drew patterns in place of the map through a temporary debug switch,
since removed (commit f832a68 in PR #38, if it's needed again):

- **Observed (Vision Pro):** the SwiftUI controls take on the environment's
  lighting, but where the map is transparent you keep seeing the room
  partway up, and once the environment is all the way on the sky turns
  black. Without Metal (RealityKit), the environment shows behind the map.
- **Observed (Vision Pro):** the same with the layer drawing nothing, only
  a transparent clear: room, then black.
  So it isn't the tiles, the sky's depth, or the far-plane rule. Lifting
  the transparent sky off the far plane (running the sky depth pass in
  mixed too) didn't change it either.
- **Observed (Vision Pro):** opaque magenta 1 m away stays
  magenta at every Crown position; the environment never draws in front
  of it.
- **Inferred:** the system doesn't composite its environment behind a
  CompositorLayer. What's behind the layer is passthrough, or nothing once
  the environment replaces passthrough. CompositorServices has no API
  touching system environments (none in the visionOS 27.2 SDK headers or
  Swift interface), and Apple documents `.coexist` only as a preference.
- **Observed (simulator):** opaque colour at the far plane (depth 0) was
  shown, not dropped, unlike the device in full immersion (the 2026-11-04
  entry below). The simulator's compositor may differ here.
- Never submitting a drawable isn't a usable test: the app was shut down
  within seconds in the simulator.

### 2026-11-04: tracks drawn with Metal on macOS

- **Observed:** Mac app, Debug, `ALSOMAPS_METAL=1 ALSOMAPS_METAL_STATS=1`,
  `ALSOMAPS_TRACK` set to a synthetic loop over downtown San Francisco 40 to
  110 m above the ground. The tube drew in orange and passed behind nearer
  towers (depth-tested against tiles); it rebuilt at a new radius on zooming
  in, as with RealityKit.
- Not run: iOS, visionOS (simulator or device). Those build only.

### 2026-11-04: immersion styles (mixed works, progressive needs layered)

- **Observed (simulator):** the Metal space now opens mixed or full,
  following Settings › Immersion › Full immersion (`model.fullImmersion`),
  as the RealityKit space does. It first also asked to coexist with the
  system environment; that didn't work and was dropped (2026-11-08).
  In mixed, the simulator's room shows wherever there's no map; in full,
  the sky as before. Both on the visionOS 27 Vision Pro simulator with
  `ALSOMAPS_METAL=1 ALSOMAPS_PRESENTATION=immersive` (plus
  `ALSOMAPS_FULL_IMMERSION=1` for full). Not yet checked on a device, nor
  switching the toggle while the space is open.
- What mixed needed, per WWDC24 "Render Metal with passthrough in
  visionOS" (10092): clear colour to all zeros (premultiplied alpha; full
  clears opaque), depth still cleared to 0, and real depth for every drawn
  pixel. Nothing in `LayerRenderer.Configuration` changes. The sky's
  depth-only pass is skipped in mixed: sky pixels stay at the far plane,
  which the compositor drops, so passthrough shows there. The style is read
  each frame, so the toggle should apply live.
- **Inferred:** tile fragments write their texture's alpha unblended. Google's
  photorealistic textures are opaque, so this should be fine; content with
  alpha below 1 would show as unpremultiplied, translucent colour in mixed.
  Worth a look on the device.
- **Progressive (Digital Crown) isn't done.** visionOS 26 adds it for
  CompositorServices ("Controlling Metal rendering immersion level"; WWDC25
  "What's new in Metal rendering for immersive apps", 294), but only with
  the **layered** layout. The space declares `.progressive` (with `.full`),
  the configuration sets `drawableRenderContextStencilFormat` (checked
  against `drawableRenderContextSupportedStencilFormats`), and each frame
  calls `drawable.addRenderContext(commandBuffer:)`, then
  `drawMaskOnStencilAttachment(commandEncoder:value:)` before drawing, a
  stencil test against that value, and `renderContext.endEncoding` in place
  of `endEncoding`; the system draws the portal's faded edge. The SDK
  headers (`drawable_render_context.h`) say the encoder must have
  `renderTargetArrayLength` equal to the drawable's view count and that
  dedicated and shared layouts aren't supported, except on one-view
  platforms such as the simulator. So this renderer, which draws each eye
  in its own pass into dedicated textures, would need both eyes in one
  layered pass: vertex amplification (or instancing) writing
  `[[render_target_array_index]]`, per-eye view-projections in the
  uniforms, and culling against both eyes. That's a change to
  `MetalTiles.swift`'s shaders and `encode`, so it's left as its own piece
  of work. It would also bring the vertex amplification the foveation note
  above mentions.
- **Not done: an edge fade.** In mixed the map ends in a hard cut against
  passthrough at the streaming reach, as the RealityKit space's does. A
  fade would be a premultiplied alpha ramp by horizontal distance from the
  viewer in the tile fragment shader, with blending on; a shader change,
  so left for whoever owns the shaders. Progressive's portal edge is
  faded by the system and wouldn't need it.

### 2026-11-04: eye height is measured twice

- **Observed (code):** both immersive spaces place the map around an eye
  height measured once on entry, but in two copies.
  - `ImmersiveMapView` uses `HeadTracker.headPosition()`, which waits up to 3 s
    for a pose marked `isTracked`.
  - `MetalImmersiveRenderer` takes the first device anchor its frame loop
    gets, without that check, and repeats the 0.5–2.5 m bounds check.
  - The Metal copy was a convenience (the frame loop already had a pose); the
    missing `isTracked` check was an oversight.
- **Inferred:** a pose from before tracking settles could put the map's
  ground a little higher or lower than RealityKit would, which can read as a
  change in scale. On one Vision Pro session the owner thought the Metal
  scale felt different; not confirmed or measured. The `eye measured at …`
  Debug line would show it.
- **Follow-up:** share one measurement between the spaces (a `MapModel`
  method that runs `HeadTracker`, checks the bounds and sets `measuredEye`).
  Further out, the head pose is something both renderers could have
  continuously rather than once, which would also change what "placed
  around the eye" means; not decided.

### 2026-11-04: two compositor rules, from device bugs

- **Observed:** exiting Immersive aborted with "BUG IN CLIENT:
  cp_frame_end_submission() failed because the frame is not valid". The
  frame loop's wait for the optimal input time is an `await`, so the space
  could close mid-frame, and a frame with no drawable still had its
  submission ended. Fixed by re-checking the layer is running after the wait,
  and dropping a frame without a drawable instead of ending its submission
  (as Apple's samples do). No crash since on the device.
- **Observed:** in full immersion the sky was black except a stepped band
  along the horizon. The pass clears depth to 0, the far plane in reverse Z,
  and the compositor drops pixels at the far plane as clipped; only the
  terrain, with real depth, showed. Fixed by a depth-only full-screen pass
  after the tiles that raises any pixel still at 0 to `skyDepth` (about
  100 km), leaving color alone. Clearing to that depth instead would have
  hidden tiles beyond it. Sky shows on the device since.
- **Inferred:** the stepped band was foveation's coarse blocks near the
  horizon mixing terrain depth into a few sky pixels. The Mac remote spike
  hit the same far-plane rule as a fully blank frame.

### 2026-11-03: the same, with an optimized build

The Debug configuration rebuilt with `GCC_OPTIMIZATION_LEVEL=s
SWIFT_OPTIMIZATION_LEVEL=-O SWIFT_COMPILATION_MODE=wholemodule
ENABLE_DEBUG_DYLIB=NO` (keeping Debug's key), installed with `devicectl`,
launched from the Home screen. Recorded the same way for 120 s; the Metal
space ran for the last 44 s, streaming the whole time (7,439 fetches, 5,900
tile builds).

- **Observed:** 3,966 frames at 90.0 a second, no `MissedDeadline` and no
  `FrameGap` events. `ImmersiveTick` mean 3.2 ms, max 5.6 ms (`Select` 3.0,
  max 5.4); `ImmersiveRender` mean 0.5 ms for both eyes, max 1.0 ms;
  `MetalEncode` 0.2 ms a view; `MetalBuild` 1.3 ms a tile.
- **Observed:** by eye in the headset, smooth while streaming near dense
  terrain, where the Debug build stuttered.
- **Inferred:** the stutters in the Debug recording below were Debug-build
  overhead: unoptimized cesium-native destructors, Swift at `-Onone` and Metal's
  debug layers. The main-thread design leaves about 7 ms a frame spare here.
  Judging the renderer's smoothness, or profiling it, needs an optimized build.

### 2026-11-03: stutters while streaming on a Vision Pro (Debug build)

Recorded with `xctrace record --device … --template 'Time Profiler'
--instrument os_signpost --all-processes` (`--attach` can't find the app on
visionOS), the app launched from the Home screen, flying near dense terrain
while it streamed. The Metal space ran for the last 23.5 s of 90.

- **Observed:** 1,202 frames, about 51 a second. 497 `MissedDeadline` events
  (41% of frames; median 6 ms late, p95 53 ms) and 498 `FrameGap` events
  (median 22 ms, p95 67 ms between presentations).
- **Observed:** missed deadlines follow the main-thread tick. Ticks under 4 ms
  missed 2.6% of the time, 4–8 ms 30%, 8–11 ms 72%, over 11 ms 93–100%.
  `ImmersiveTick` is almost all streaming's `Update`, which is almost all the
  bridge's `Select` (mean 10 ms, p95 39 ms, max 203 ms). `ImmersiveRender`
  is steady at about 7 ms for both eyes (max 11 ms). In 785 of 1,201 frames,
  tick plus render alone exceeded 11.1 ms, since both run in turn on the main
  thread. `MetalBuild` is about 2 ms a tile, off the main thread.
- **Observed:** main-thread samples during the Metal space: 59% in the
  model's tick (55% in `CNTileStreamer update`), 39% in rendering.
  - 31% is cesium-native unloading cached tile content inside `loadTiles`
    (`unloadCachedBytes` → `~ModelSpec` → each glTF image's
    `std::vector<std::byte>` destroyed byte by byte). These destructors are
    inline, so they're compiled into `Also Maps.debug.dylib` at `-O0`; an
    optimized build would free each buffer in one call.
  - 15% is the selection pass itself (`updateViewGroup`, with
    `estimateGlobeRectangle` prominent).
  - Metal's debug and capture layers (`MTLDebugCommandBuffer`,
    `CaptureMTLRenderCommandEncoder`) take a noticeable share of encoding,
    and `MetalFrustum` about 9% (Swift at `-Onone`).
- **Inferred:** much of this is Debug-build overhead, so the next step is the
  same recording with an optimized build and Metal validation off. What
  would remain regardless: selection and unloading run on the main thread
  inside the frame, in series with rendering, and cesium-native keeps each
  tile's decoded images after we've uploaded them, so unloading them is main-
  thread work that the upload could have done earlier off it.

### 2026-11-03: culling and foveation on a Vision Pro

- **Observed:** with #33 (culling and foveation) against #32 (neither), the
  frame rate didn't look noticeably different, but the image looked much
  better: #32 looked aliased and #33 didn't. Nothing else looked wrong.
  Judged by eye; no counters or traces.
- **Inferred:** the image difference is foveation, not culling, which only
  skips off-screen geometry. Neither branch multisamples. Unfoveated eye
  textures have one uniform pixel density, while the foveated ones render
  where you look at a higher density. Untested: running #33 with
  `ALSOMAPS_METAL_FOVEATION=0` should look like #32 if so.

### 2026-11-03: culling on macOS

- **Observed:** default view (San Francisco), Metal with
  `ALSOMAPS_METAL_STATS=1`, one second's totals over 59 frames: tiles
  16,166 of 28,143 submitted, draws 18,703 of 31,152, triangles 12,248,872 of
  19,213,704. About 43% fewer tiles and 36% fewer triangles. One view, one
  sample, submission counts only.
- **Observed:** with a Google Maps key and Metal on, New York rendered in the
  Mac window and the submission counters were active.
