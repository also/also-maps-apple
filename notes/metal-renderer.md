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
compositor projection and predicted pose. Held (Fly) tiles use their current
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
culling and draw encoding for one view; record and summarise them as in
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

### 2026-11-04: zoom stepped near the ground (both spaces)

- **Observed (owner, Vision Pro, Metal space):** pinch-zooming close to the
  ground could get jumpy and steppy.
- **Observed (core test):** replaying a two-handed zoom from about 950 m
  toward the 55 m floor, 2% an update, about a point 40 m out on the gesture
  slab: the camera's position didn't move for runs of updates while its
  height did, then jumped 300–600 m, and the pinched point drifted over a
  metre off the hand. A point 8 m out stayed smooth.
- **Cause (observed in the solver's iterations):** the slab is flat and the
  Earth isn't, so a point 25 km out on it is about 48 m above the ground.
  That height stays fixed as you zoom in onto it, so its room-space offset
  along the map's up grows with the scale. The solve can't correct that part:
  moving the camera only shifts the map east and north, and its height comes
  from the scale. `AdaptiveModel.solve` picked the best iteration by the full
  3D error, so the unmoved first guess often won, until the scale error
  outgrew the offset and it jumped. Being low means looking at far points,
  so this showed near the ground.
- **Fix:** judge iterations by the error along the map (not along its up)
  together with the scale error. `zoomingInOnAFarPointFollowsEveryUpdate`
  fails without it and passes with it.
- **Inferred:** the RealityKit space uses the same solve, with a slab out to
  the same 50 m, so it should have stepped the same way and gets the same
  fix. Not compared on a device.
- **Not ruled out, if steps remain:** the 55 m floor is measured from
  `cameraGround`, which follows loading tiles all the time, including
  during a gesture (eased over about 0.3 s), so the floor can rise or fall
  under you. Spatial events may also arrive less often than frames; each
  one moves the view directly, with no smoothing.

### 2026-11-04: look-and-pinch from spatial events

The RealityKit space gets pan, zoom and twist from SwiftUI gestures targeted
at an invisible slab entity (`mapGestures`). A `CompositorLayer` has no
entities, so the Metal space now builds the same gestures from
`LayerRenderer.onSpatialEvent` (`MetalSpatialGestures`, with the pure logic in
`Sources/Navigation/PinchGestures.swift`) and feeds the same `MapModel`
calls (`drag`, `magnify`, `rotate` and their ends).

- **Observed (SDK, XROS 27.2):** `onSpatialEvent` hands the layer a
  `SpatialEventCollection` (SwiftUI's type). Each event has its own `id`,
  `kind` (`.indirectPinch`, `.directPinch`, …), `phase`, `chirality`,
  `selectionRay` and `inputDevicePose.pose3D`. Each pinching hand is a
  separate event, so two-handed zoom and twist can be built from two ids.
  `targetedEntity` and `location3D` are there too but have nothing to target
  in a compositor layer.
- **Alternatives, set aside:** ARKit hand tracking would mean recognising
  pinches ourselves, and has no gaze, so it couldn't tell what's looked at;
  it's the sibling custom-controls work's territory. A GPU depth pick isn't
  needed: the RealityKit space's slab is a plane too, so a CPU ray test
  matches it.
- **How it maps:**
  - a pinch counts only if its selection ray hits the gesture slab's top
    face (`MapModel.immersiveGestureHit`: the slab's own transform and
    collision box, so the same 50 m area as RealityKit's); one that misses is
    ignored until it ends;
  - after that the hand's position drives it and the ray isn't followed;
  - one hand: a drag from the hit point, carried 1:1 with the hand, once the
    hand has moved 1 cm (DragGesture's minimum distance);
  - two hands: magnify by the change in horizontal distance between the
    hands, twist by the turn of the line between them about +Y, both about
    the midpoint of the two hits; the drag ends while both are down, and the
    hand left after a two-handed gesture drags on from its point's current
    place, without a jump.
- **Inferred (not checked against every SDK):** an immersive space's
  content is either a `CompositorLayer` or SwiftUI/RealityKit content, not
  both, so there's no entity for SwiftUI's entity gestures to target. That
  rules out an invisible gesture slab in the Metal space.
- **Observed:** builds for visionOS (device and simulator), macOS, iOS and
  tvOS; `PinchGestureTests` cover the drag, zoom, twist sign and the
  two-to-one-hand hand-over. In the visionOS 27 simulator the Metal space
  still opens and renders with the handler installed.
- **Not tested:** any actual pinch. The simulator tooling here couldn't
  inject input into a visionOS 27 simulator, and nothing has run on a
  device. Needs checking on a Vision Pro:
  - that events arrive in the immersive space's origin frame (the
    simulator-only 1.6 m eye lift is applied to them, as to the renderer);
  - whether `selectionRay` is present on the first `.active` event of an
    indirect pinch;
  - whether 1:1 hand travel feels like the RealityKit space's drag
    (DragGesture's indirect `location3D` may scale with distance);
  - the twist direction and zoom feel against the RealityKit space;
  - that game controllers don't also arrive as pinches (the RealityKit
    space routes them away with `handlesGameControllerEvents`, which the
    XROS 27.2 SDK has only as a `View` modifier, not for compositor content);
    the handler takes `.indirectPinch` events only, which may be enough;
  - the `[AlsoMaps] Metal gestures:` Debug lines show each pinch's hit or
    miss.

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
  100 km), leaving colour alone. Clearing to that depth instead would have
  hidden tiles beyond it. Sky shows on the device since.
- **Inferred:** the stepped band was foveation's coarse blocks near the
  horizon mixing terrain depth into a few sky pixels. The Mac remote spike
  hit the same far-plane rule as a fully blank frame.

### 2026-11-03: the same, with an optimised build

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
  overhead: unoptimised cesium-native destructors, Swift at `-Onone` and Metal's
  debug layers. The main-thread design leaves about 7 ms a frame spare here.
  Judging the renderer's smoothness, or profiling it, needs an optimised build.

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
    optimised build would free each buffer in one call.
  - 15% is the selection pass itself (`updateViewGroup`, with
    `estimateGlobeRectangle` prominent).
  - Metal's debug and capture layers (`MTLDebugCommandBuffer`,
    `CaptureMTLRenderCommandEncoder`) take a noticeable share of encoding,
    and `MetalFrustum` about 9% (Swift at `-Onone`).
- **Inferred:** much of this is Debug-build overhead, so the next step is the
  same recording with an optimised build and Metal validation off. What
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
