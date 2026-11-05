# Profiling

The tile pipeline is instrumented with signposts (`os_signpost`), so Instruments or `xctrace` can show where the time goes. Subsystem `dev.also.maps`; definitions in `Sources/Signposts.swift` (Swift) and `CNSignpostLog` in `Sources/Cesium/CNTileStreamer.mm` (the bridge). They cost almost nothing when nobody is recording.

## What's marked

| Category | Interval | Where | Covers |
|---|---|---|---|
| Tiles | `Fetch` | bridge | one HTTP request, from `dataTask` start to completion. End message: status, bytes. A cache hit is about 1 ms. |
| Tiles | `Flatten` | bridge | cesium-native's glTF to the flat `CNPrimitive` buffers (load thread) |
| Tiles | `TileUpload` | `TileUploader` | a tile from handler call to `completion()`: queue wait + build + assemble |
| Tiles | `QueueWait` | `TileUploader` | waiting for one of the limiter's slots (`uploadConcurrency`) |
| Tiles | `BuildMesh` | `TileUploader` | `MeshResource(from:)` for a tile's primitives |
| Tiles | `Assemble` | `TileUploader` | entity and materials, on the main actor, including textures |
| Tiles | `Texture` | `TileUploader` | one `TextureResource(image:)`; message is the size |
| Tiles | event `LoadComplete` | `TileStreaming` | progress reached 100% |
| Frame | `Update` | `TileStreaming.update` | the whole per-frame update on the main thread |
| Frame | `Select` | bridge | cesium-native's selection pass inside `Update` |
| Frame | `MetalEncode` | `MetalTileRenderer` | render-only culling and draw encoding for one view |
| Tiles | `MetalBuild` | `MetalTileRenderer` | one tile's Metal buffers and textures, off the main thread. Begin message: builds in flight. |
| Frame | `ImmersiveTick` | `MetalImmersiveRenderer` | visionOS Metal space: the model's tick, including streaming's `Update` |
| Frame | `ImmersiveWait` | `MetalImmersiveRenderer` | waiting for the compositor's optimal input time |
| Frame | `ImmersiveRender` | `MetalImmersiveRenderer` | querying the drawable, encoding both eyes and committing |
| Frame | event `MissedDeadline` | `MetalImmersiveRenderer` | a frame committed after the compositor's rendering deadline; message: by how much |
| Frame | event `FrameGap` | `MetalImmersiveRenderer` | more than 1.5 frames (at 90 Hz) between presentation times; message: the gap |

Add more with `Signposts.tiles.beginInterval("Name", id: signposter.makeSignpostID())` / `endInterval`, or `os_signpost_interval_begin` in the bridge. Names must be string literals.

## Recording headlessly

Use the unsandboxed Debug Mac app (see the README). Launch it under `xctrace` so the recording covers the whole load from the first request:

```
xctrace record --template 'Time Profiler' --instrument 'os_signpost' \
  --time-limit 15s --output run.trace \
  --env ALSOMAPS_LAT=37.7955 --env ALSOMAPS_LON=-122.3937 --env ALSOMAPS_RADIUS=800 \
  --launch -- /usr/bin/env -u OS_ACTIVITY_DT_MODE \
  "build/Build/Products/Debug/Also Maps.app/Contents/MacOS/Also Maps"
xctrace export --input run.trace \
  --xpath '/trace-toc/run[@number="1"]/data/table[@schema="OSSignpostIntervals"]' > intervals.xml
python3 Scripts/signpost_summary.py intervals.xml
```

**The `env -u OS_ACTIVITY_DT_MODE` is required.** `xctrace --launch` starts the process with `OS_ACTIVITY_DT_MODE=0` (plus `OS_ACTIVITY_TOOLS_PRIVACY=1`, `OS_ACTIVITY_TOOLS_OVERSIZE=1`, `OSLogRateLimit=64`). The presence of `OS_ACTIVITY_DT_MODE` (Xcode's "route logging to the debugger" switch) appears to suppress unified-log output; empirically the app's signposts never reach the log (neither `xctrace` nor `log stream` sees them), while other processes' and the system frameworks' signposts still appear. Passing `--env OS_ACTIVITY_DT_MODE=NO` doesn't help (an empty value is rejected); the variable has to be absent, hence `env -u`, which then `exec`s the app so `xctrace` still follows the same pid. With this, the first `Fetch` starts about 1 s into the trace and `LoadComplete` shows up at about 5 s.

Alternatively, start the app yourself and `--attach $pid` (no `env -u` needed), but intervals that began before the attach aren't captured. Open `run.trace` in Instruments for the timeline and the Time Profiler call tree. `Scripts/signpost_summary.py` prints count, total, mean, p50, p95 and max per interval.

For a quick look without a trace:

```
/usr/bin/log stream --signpost --predicate 'subsystem == "dev.also.maps"'
```

(In zsh, call `/usr/bin/log`: plain `log` is a shell builtin.)

## Reading the numbers

Ferry Building, 800 m, Mac Debug build. Intervals are per-event, in ms; they overlap across threads, so totals don't add up to elapsed time.

Cold (tile cache cleared):

| Interval | Count | Mean | p95 |
|---|---|---|---|
| `Fetch` | 375 | 190 | 390 |
| `TileUpload` | 317 | 45 | 97 |
| `QueueWait` | 317 | 14 | 66 |
| `Assemble` | 317 | 18 | 34 |
| `BuildMesh` | 317 | 6.4 | 17 |
| `Flatten` | 317 | 1.2 | 3.5 |
| `Update` / `Select` | 1799 | 1.1 / 0.7 | 1.4 / 1.1 |

Warm (tiles cached):

| Interval | Count | Mean | p95 |
|---|---|---|---|
| `Fetch` | 91 | 1.0 | 2.0 |
| `TileUpload` | 80 | 92 | 125 |
| `QueueWait` | 80 | 70 | 95 |
| `Assemble` | 93 | 11 | 18 |
| `BuildMesh` | 91 | 7.0 | 13 |
| `Flatten` | 80 | 1.2 | 3.5 |

Cold, the network dominates (`Fetch` about 190 ms each, 12 connections per host). Warm, the fetch is gone and tiles wait on the uploader: most of a tile's `TileUpload` is `QueueWait` for one of the 4 slots, and the work in a slot is about 20 to 25 ms. These are single recordings with the first second or so cut off, so treat them as indicative. A frame's `Update` stays near 1 ms either way.

## Upload concurrency

Warm cache, default view (the bay), 607 tile uploads, Mac Debug build. Time is from the first fetch to the last upload finishing; `QueueWait` is the mean time a tile waited for an upload slot. Record with `ALSOMAPS_UPLOADS` and `ALSOMAPS_LOADS` (see `recording headlessly`).

| Parallel uploads | Simultaneous loads | Load | Mean `QueueWait` |
|---|---|---|---|
| 4 | 20 | 4.08 s | 80 ms |
| 8 | 20 | 2.41 s | 24 ms |
| 12 | 20 | 1.98 s | 5 ms |
| 24 | 20 | 1.90 s | 0 ms |
| 64 | 20 | 1.95 s | 0 ms |
| 24 | 64 | 1.45 s | - |

With 4 slots the uploader was the limit (slots about 98% busy). From 12 slots up, tiles no longer wait for one, and the last fetch finishes within 0.1 s of the last upload: the limit is how fast tiles are discovered, which more simultaneous loads speeds up. Per-tile `Assemble` (main actor) only rose from 15 ms to about 20 ms, so the main actor was not the limit up to 64 slots. The defaults are now 12 uploads and 64 loads.

Not measured: a cold load (network-bound, so loads may matter more and uploads less), main-thread frame time while uploads run (20 ms per `Assemble` may hitch), and visionOS.
