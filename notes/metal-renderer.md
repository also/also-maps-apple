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

### Who calls what, and on which thread

Read from the code, 2026-11-05 (**Observed**: code, nothing run).

**The frame today (visionOS Metal).** `MetalImmersiveRenderer.run` is on the
main actor. Each frame: `frame.startUpdate()`, then
`MapModel.metalImmersiveTick` → `tick` (input, `updateGround`, `applyView`,
which sets `streaming.inputs` and `tilesRoot.transform`) →
`TileStreaming.update` → `CNTileStreamer updateWithDeltaTime:`, all on the main
thread; then `await clock.sleep(until: optimalInputTime)`, then `render`, which
reads `streaming.drawnTiles` and `model.tilesInImmersiveSpace` and encodes both
eyes. On macOS and iOS `MetalMapView` draws from the same two properties, but
its `update` is driven by the RealityKit scene's update event
(`ScreenMap.tick`), so it's only the immersive space that this work touches.

**What the bridge's `update` does**, in order, all inline:

1. Writes the area-of-interest excluder (`radius`, `anchorUp`,
   `ecefToAnchorEnu`) from the anchor properties.
2. Turns the LOD camera (anchor frame, RealityKit axes) into an ECEF
   `ViewState`. A degenerate camera returns the last frame.
3. `updateViewGroup` (selection), then `loadTiles()`: starts loads and
   **unloads cached content** until under `maximumCachedBytes`. Unloading
   destroys the tile's glTF `Model`, including its decoded images, and calls
   `IPrepareRendererResources::free`, which releases the retained `CNTileMesh`
   and records its id.
4. `dispatchMainThreadTasks()`: runs cesium-native's "main thread"
   continuations: tiles becoming drawable (`prepareInMainThread`), and ground
   samples' completions. So those run on whichever thread calls `update`.
5. Places each drawn tile: a double-precision matrix from the tile's
   centre to the anchor frame **as set at this update**, so a tile's
   placement is only meaningful with that anchor.
6. Drains the freed-id list, snapshots credits, computes load progress, and
   keeps the result as `_lastFrame`.

**What it reads.** The plain `nonatomic` properties (anchor, radius, heading,
view camera, `reportsTileBounds`), the `Tileset`'s options (written by the
settings setters straight into `_tileset->getOptions()`), the Tileset itself
and `_lastFrame`.

**Thread-safety rules of the bridge** (nothing is documented; this is read off
the code):

- Not safe to use from two threads: every plain property, the option setters,
  `update`, `sampleGroundHeight`, and the release of the streamer (`dealloc`
  destroys the Tileset). There is no locking around the Tileset. Today they're
  all on the main thread, so nothing needed any.
- Safe from any thread: `fetchStats` and `takeKeyFailureStatus` (atomics),
  the tile load handler's getter and setter (mutex), the freed list (mutex),
  and a `CNTileMesh` once built (immutable fields; `primitives` and
  `renderObject` are atomic).
- The load handler and its completion run on background threads already, and
  the completion may be called from any thread.
- A `CNTileMesh` is retained by cesium-native, and again by anything holding
  `tilesToRender`. `free` drops cesium's reference only, so a published frame
  keeps its tiles (and their Metal buffers and textures) alive after
  cesium-native has unloaded them.

**How camera input arrives.** `TileStreaming.inputs` (a value:
`StreamingInputs`) is set by `MapModel.applyView` every tick unless tiles are
held, and its `didSet` copies it into the bridge's properties. Held ("Fly")
tiles freeze `inputs` (`heldInputs`), so `update` keeps selecting from the
held view while `tilesRoot` is recomputed every tick from the *current*
georeference and the held anchor.

**The placement pairing that makes a stale frame safe.** `tilesRoot.transform`
is `georeference.placement(of: streaming.inputs.anchor)`. A frame's tile
placements are relative to the anchor it was selected with. Drawing an older
frame with the current anchor's root would shift every tile by the anchor's
movement since (the anchor follows the camera). The fix is to pair a frame
with its own anchor and today's georeference: `tilesInImmersiveSpace(anchoredAt:)`.

## Measuring

Environment variables:

- `ALSOMAPS_METAL=1`: use Metal for this run.
- `ALSOMAPS_METAL_STATS=1`: log submission counts once a second on macOS,
  iOS and immersive visionOS.
- `ALSOMAPS_METAL_CULLING=0`: turn culling off, for a baseline. On by default.
- `ALSOMAPS_METAL_FOVEATION=0`: turn visionOS foveation off, for a baseline.
  On by default where the dedicated layout supports it.
- `ALSOMAPS_METAL_THREADED_SELECT=1`: experimental, visionOS immersive only.
  Run cesium-native's selection and unloading on a serial queue instead of in
  the frame (see "Selection off the main thread" below). Off by default.
- `ALSOMAPS_METAL_RELEASE_IMAGES=1`: experimental. Free each tile's decoded
  glTF images on the load thread right after its buffers are built, instead of
  when cesium-native unloads the tile. Metal only; independent of the above.

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

### 2026-11-05: selection off the main thread (prototype, not built or run)

Written without a build or a device, by reading the code. **Nothing here has
been compiled or run.** It is the first step of idea 4 in
[metal-feature-ideas.md](metal-feature-ideas.md), plus a flagged version of
its option 2. Both are off by default; with neither flag the frame loop does
what it did, one extra function call apart.

- **What it does (visionOS Metal immersive only), with
  `ALSOMAPS_METAL_THREADED_SELECT=1`:**
  - `TileStreaming` starts a `TileSelectionWorker` for the streamer. Each tick
    the main thread submits a `Job` (a copy of `inputs`, `settings` and the
    time step) and returns. The worker's serial queue applies the job to the
    bridge, runs `update`, and publishes an immutable `Snapshot` (tiles,
    placements, the anchor they're relative to, credits, load progress).
  - One update runs and at most one job waits; a newer job replaces the waiting
    one and their time steps add, so the queue can't back up. If an update takes
    longer than a frame, the worker simply runs back to back.
  - The main thread adopts a new snapshot once per tick (credits, progress,
    `renderedTiles` for `CameraGround`, stats). The frame loop reads the newest
    published snapshot at render time through `drawnForRender()`, not what the
    tick adopted, so a job that finishes during the optimal-input wait is
    drawn that frame.
  - Everything that touches the Tileset moves to the queue: the bridge's
    properties and option setters (applied from the job, so each update uses
    one consistent copy), `sampleGroundHeight` (its completion hops back to the
    main queue, where `MapModel` asserts it is), and the streamer's release
    after a restart. `drawnTiles` stays empty in this mode. The tile bounds
    overlay is off (it's RealityKit's).
  - Restart (key, tile source, handler change) cancels the worker: the running
    update finishes and publishes nothing, then the old streamer goes.
- **Held (Fly) tiles:** nothing special is needed beyond the pairing above.
  Held `inputs` are just the same job each tick, so loads continue as they do
  now. The frame loop draws the held snapshot with today's georeference and the
  held anchor, which is the same composition `applyView` does. Releasing the
  hold changes the anchor; the first new snapshot arrives a few frames later and
  the old one keeps drawing correctly until then.
- **`ALSOMAPS_METAL_RELEASE_IMAGES=1` (option 2):** `prepareInLoadThread` empties
  every glTF image's `pixelData` right after `buildTileMesh` has copied the RGBA
  into the `CNPrimitive`s, on the load thread. Unloading then has no big
  buffers to free inside `loadTiles`. It's independent of the threading flag, so
  it can be measured alone in the Debug build, where the destructors were 31%
  of the main thread. The `discardCPUData` call in `MetalTileRenderer.handler`
  is the Swift half and already ran after upload.

**Risks, in the order I'd check them:**

1. **cesium-native's thread rules are Inferred, not read.** The assumption is
   that the Tileset has no thread affinity, only a need for one caller at a
   time, and that "main thread" in `AsyncSystem` just means "whoever calls
   `dispatchMainThreadTasks`". A serial `DispatchQueue` guarantees one caller
   at a time but may use a different thread for each block. If cesium-native
   asserts a thread, uses thread-local state, or the Tileset is created and
   destroyed on a thread it cares about, a dedicated `Thread` would be the fix.
   The streamer is also created on the main thread and torn down on whichever
   thread lets go last; `dealloc` then drains `dispatchMainThreadTasks` on the
   main queue while `~Tileset` runs elsewhere, which hasn't been thought
   through.
2. **Camera lag.** Selection runs on the camera of the tick that submitted the
   job, and is drawn one or more frames later (the length of an update; optimised
   ~3 ms mean, Debug up to 200 ms). Placement stays right (the anchor pairing);
   what lags is detail: a fast zoom or turn can show last frame's LOD for a few
   frames. Bounded and unmeasured.
3. **Stale-snapshot popping.** Each snapshot is a complete, self-consistent
   cesium selection, so mixing can't open holes. But a tile becomes visible
   only when a job that selected it finishes, so refinement can pop in later than
   today, and a view that moved can briefly show tiles selected for the old
   view. Two drawables in one frame (capturing) each call `drawnForRender()`
   and could use different snapshots.
4. **Ordering between the camera and the first snapshot.** Until the worker's
   first job finishes nothing is drawn (as at launch). After a restart the same.
5. **Stale `renderedHeightRanges`.** `CameraGround` reads the tiles adopted on
   the last tick, now up to one update behind its own camera.
6. **Image release and cache accounting (unverified).** If cesium-native sizes a
   tile from its model both when loaded and when unloaded, emptying the images
   in between would make the unload subtract less than the load added, so the
   total drifts upward and the cache evicts too eagerly. If it records the size
   once, there's no issue. Check `maximumCachedBytes` behaviour over a long
   run before trusting it. Separately, a texture shared between tiles by
   external URI would be emptied for the next tile; Google's embedded textures
   aren't shared.
7. **Memory.** Snapshots keep tiles alive after cesium-native frees them, so
   GPU memory can briefly exceed the cache budget by about a frame or two of
   tiles.
8. **A busy core.** With updates longer than a frame the worker never idles.
   `qos: .userInteractive` was chosen so it isn't starved by the load threads.
9. **Not done:** `MetalMapView` (macOS and iOS) isn't converted; its root comes
   from `tilesRoot.transform` and would need the same pairing. No unit test:
   `TileStreaming` isn't in the Core Tests target.

**To measure** (optimised build, per [docs/profiling.md](../docs/profiling.md),
and a fixed view with a deliberately warm cache per
[docs/tile-caching.md](../docs/tile-caching.md)): the main-thread `Update` and
`ImmersiveTick` signposts should fall to near zero; the new `SelectionJob`
interval is the worker's time and the bridge's own `Select` now runs on its
queue. Compare `MissedDeadline` and `FrameGap` counts with and without the
flag, for settled idle, movement and streaming separately. Then the same in the
Debug build, where unloading was the biggest cost, with and without
`ALSOMAPS_METAL_RELEASE_IMAGES=1`.

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
