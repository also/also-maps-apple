# Offscreen Metal CLI

For stereo movies along a camera journey, see [Stereo video capture](stereo-video-cli.md).
The benchmark below continues to use a frozen scene for its A/B comparison.

`also-maps-render` is a macOS command-line tool that uses the app's actual
Metal renderer, shader, sampler mapping, culling, and Cesium tile bridge.
It draws into colour/depth textures, waits for GPU completion, and reads back
the pixels. It creates no window and uses no RealityKit, MTKView, compositor,
screen recording, Accessibility, or Computer Use connection.

## Build and run

Generate the project first, as for the app:

```
xcodegen generate
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild \
  -scheme 'Also Maps Render CLI' -configuration Debug \
  -destination 'platform=macOS' -derivedDataPath build CODE_SIGNING_ALLOWED=NO build
```

The default mode is a deterministic synthetic scene, with no network or key:

```
env -u OS_ACTIVITY_DT_MODE build/Build/Products/Debug/also-maps-render \
  --output build/headless-synthetic
```

It includes visible geometry, a tile fully behind the eye, a tile wholly
offscreen, and a multipart tile with a hidden primitive. The regression
requires five unculled draws to become two, with exactly identical pixels.

For a bounded Midtown Manhattan scene:

```
env -u OS_ACTIVITY_DT_MODE build/Build/Products/Debug/also-maps-render \
  --google --altitude 600 --radius 1500 --frames 30 \
  --output build/headless-nyc
```

Use `--help` for camera, resolution, detail, and timeout options. The camera
uses the navigation core's screen projection and placement. `--altitude` is
height above the WGS84 ellipsoid; the CLI does not perform terrain-following
or the interactive app's asynchronous ground-height adjustment. Streaming
uses the explicit radius, 16 concurrent loads, and a 512 MB tile cache budget.
The rendered area can have a visible edge because the streaming radius is bounded.

Google mode uses `GOOGLE_MAPS_API_KEY` from the environment, then the Debug
binary's embedded `Config/Secrets.xcconfig` key. The CLI embeds the app's
`dev.also.maps` bundle ID to preserve the request header/key restriction and
HTTP-cache namespace. Release embeds no key; provide it through the
environment. The report includes no key or request URLs.

## What is measured

The tool first waits for the tiles to reach 100% load and an unchanged
selection for half a second, subject to `--timeout`. It then takes strong
references to one immutable snapshot of GPU resources and transforms.
No tile selection or loading is part of the measured render loop. Both
modes use this exact snapshot, avoiding cache, refinement, or camera changes
between comparisons.

After warmup, samples alternate on/off order. `report.json` contains:

- Actual submitted and considered tiles, draws, and triangles for each mode.
- CPU time inside the shared renderer's encode call, excluding GPU waits.
- GPU execution time from completed command buffers, reported as unavailable
  if the system doesn't supply timestamps.
- Raw samples and median/p95 values, in milliseconds.
- The camera/options, device, fetch counters, attributions, and differing pixels.

`culling-off.png` and `culling-on.png` have provider attribution in a footer
for Google captures. Pixel comparison uses the raw render targets before
adding the footer. A changed image, failed GPU command, empty render,
incomplete load, or synthetic regression exits nonzero.

Use **Release** for performance conclusions; debug Swift code can make the
CPU cost of the culling test look substantially larger. This is a serial,
offscreen GPU workload, not presented FPS or an end-to-end app frame time.
Other GPU clients, power state, scene density, and resolution still affect it.
It does not test display pacing, window composition, input latency, stereo,
foveation, or visionOS compositor behavior.

The HTTP cache is retained; it is not cleared by the CLI. A cold/mixed cache
only affects the preceding load stage, with counters recorded in the report.
For a load-time experiment, explicitly choose warm or cold runs per
[tile-caching.md](tile-caching.md). For Instruments signposts, follow
[profiling.md](profiling.md), launch through `env -u OS_ACTIVITY_DT_MODE`,
and export/summarize with `Scripts/signpost_summary.py`.

## Locked-screen validation

On 2026-11-03, an Apple M2 successfully executed offscreen clears/readback,
the real shader's synthetic regression, and a Google Midtown Manhattan
render while the Mac was locked and screen sharing was disconnected.
The synthetic images were identical with draws reduced from five to two.
The Manhattan snapshot also produced identical images, with 331 considered
tiles, 482 draws reduced to 241, and 1,151,930 triangles reduced to 538,552.

A Release run at 1280 × 720 with 60 measured frames per mode gave these
results on that same 331-tile snapshot:

| Per-frame measurement | Culling off | Culling on |
|---|---:|---:|
| CPU encode median | 0.170 ms | 0.091 ms |
| CPU encode p95 | 0.186 ms | 0.100 ms |
| GPU execution median | 1.448 ms | 0.842 ms |
| GPU execution p95 | 1.683 ms | 0.972 ms |
| Differing pixels | — | 0 |

The load used a warm cache: 693 hits, one revalidation, and no full downloads.
These are one run's offscreen results, not an interactive FPS claim or a
device-independent performance guarantee. The report retains the raw samples.

This establishes that the CLI can perform real rendering in that host's
locked state. It does not guarantee GPU availability in every macOS session
or power state; the CLI reports a GPU failure instead of depending on an
automatic desktop unlock.
