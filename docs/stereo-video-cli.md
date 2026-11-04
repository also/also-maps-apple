# Stereo video capture

`also-maps-render video` records the shared Metal renderer without a window,
RealityKit, headset, or screen recording. It exports either Apple spatial
video (rectilinear MV-HEVC with spatial metadata) or a full-width side-by-side
HEVC movie. It can follow an app camera CSV track or make an eased A-to-B move.

This first version records the geographic camera's view. It does not capture
the visionOS interface, tracked head motion, adaptive map tilt/scale, or a
180°/360° panorama. Spatial video plays as a stereo window on Vision Pro;
Apple Immersive Video and projected immersive formats are separate formats.
The renderer and journey sampling can be reused for panoramic capture later.

## Build

From this worktree, generate the project and build the existing CLI target:

```sh
xcodegen generate
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild \
  -scheme 'Also Maps Render CLI' -configuration Release \
  -destination 'platform=macOS' -derivedDataPath build CODE_SIGNING_ALLOWED=NO build
```

Release expects `GOOGLE_MAPS_API_KEY` in the environment. Debug can also use
this worktree's gitignored `Config/Secrets.xcconfig`. Do not put a key in
command arguments or commit it. Key resolution and HTTP caching are the same
as the [offscreen benchmark](metal-render-cli.md). A new worktree does not
inherit the original checkout's gitignored secrets file.

## An A-to-B shot

```sh
env -u OS_ACTIVITY_DT_MODE build/Build/Products/Release/also-maps-render video \
  --google \
  --from '40.7549,-73.984,600,0,-45' \
  --to '40.7564,-73.984,600,0,-45' \
  --duration 8 --fps 30 --width 1920 --height 1080 \
  --radius 1800 --detail 16 \
  --world-scale 0.002 --convergence 1000 \
  --output build/manhattan-spatial
```

Poses are `latitude,longitude,height,heading,pitch`: geographic angles in
degrees, height in metres above the WGS84 ellipsoid, heading clockwise from
north, pitch negative down. Height is **not** clearance above roofs or terrain.
There is no collision avoidance or terrain following.

A-to-B uses smoothstep easing with shortest-path heading/longitude changes,
linear latitude/height/pitch interpolation, and no roll. This is intended for
local shots; it is not a great-circle flight planner. Both endpoints are
included in the sampled frames. `ceil(duration × fps)` frames are encoded at
exactly `index/fps`, so duration rounds up to the next whole frame. At least
two frames are required. Source motion reaches the end on the last frame,
less than one output frame before the movie's end.

`--width` and `--height` are **per eye**. A 1920 × 1080 spatial movie stores
two 1920 × 1080 views in one multiview track. SBS stores a 3840 × 1080 frame,
left eye first, with no spatial-video metadata. Choose SBS with `--format sbs`
when a stereo editor/player needs that layout; tell it the layout explicitly.
Unsupported codec/dimension combinations fail rather than silently producing
mono. There is no audio track.

Without `--google`, the command makes a small moving stereo synthetic scene
with no key or network. For example:

```sh
build/Build/Products/Release/also-maps-render video \
  --duration 1 --fps 12 --width 640 --height 360 \
  --output build/stereo-synthetic
```

## Follow an app recording

```sh
env -u OS_ACTIVITY_DT_MODE build/Build/Products/Release/also-maps-render video \
  --google --track '/absolute/path/Track 2026-11-03 12.00.00.csv' \
  --start 5 --duration 10 --fps 30 --format spatial \
  --world-scale 0.01 --convergence 1000 \
  --output build/track-spatial
```

`--start` is seconds from the first CSV sample. Omit `--duration` to use the
remaining track, up to the 600-second limit; longer tracks need an explicit
crop. This uses the app's `TrackPlayback` interpolation, preserving segment
jumps as hard cuts. Invalid rows, non-finite/out-of-range poses, duplicate or
backwards timestamps, decreasing segments, unknown headers, and intervals
outside the recording are rejected. `--track` cannot be mixed with endpoints.
The app records a navigation pose, not a headset's actual eye orientation.

## Stereo depth

The cameras are parallel and rectified, with off-axis projections. Their
zero-disparity plane is `--convergence` geographic metres away. Nearer objects
appear in front of that plane and farther objects behind it. The command
does not turn the eyes inward, which would introduce vertical disparity.

- `--baseline` is physical eye spacing in millimetres (64 by default).
- `--world-scale` is physical metres per geographic metre: 1 is full-size;
  0.01 makes the world a 1:100 miniature. The Google default is 0.01; synthetic
  defaults to 1. A smaller scale produces stronger stereo depth at aerial heights.
- The geographic eye separation is `baseline / 1000 / worldScale`. For
  example, 64 mm and scale 0.002 give a 32 m geographic separation.
- `--convergence` defaults to 1000 geographic metres for Google, 6 for synthetic.
- `--fov` is the horizontal angle of **each eye**, 75° by default.

Spatial metadata records the physical baseline, horizontal FOV, rectilinear
projection, and zero additional disparity adjustment. The off-axis projection
already applies convergence; it isn't applied again by metadata. The capture
report records the effective scale and geographic baseline/convergence too.

These parameters are constant for a recording. They do not reproduce the
app's adaptive presentation scale. Review depth and camera speed on Vision
Pro before choosing a final promo shot; the tool verifies geometry and file
structure, not viewing comfort.

## Loading and output

Each pose updates the existing Cesium session, waits for 100% progress and an
unchanged selection for `--settle` seconds (default .1), then renders both eyes
from the same immutable tile snapshot. Both views therefore show the same
refinement state. The SSE threshold is applied equally inside and outside
the central view, including the shifted eyes. Loads use 16 concurrent slots
and a 512 MB tile-cache budget. The bounded radius can expose a terrain edge:
look farther down or increase the radius for a shot that includes the horizon.
There can still be LOD changes as a route advances.

Loading can take longer than real time. Waiting is absent from movie time;
the fixed frame schedule never drops a frame to keep up. The retained HTTP
cache is warm/mixed; it is not deleted. Fetch counters are recorded. Choose
warm/cold experiments explicitly per [tile-caching.md](tile-caching.md).

The command requires a **new output directory** and writes:

- `video.mov`: completed recording; a failed encoder/load removes the partial movie.
- `first-sbs.png`, `last-sbs.png`: full-width stereo previews.
- `capture.json`: options, effective camera geometry, fixed timestamps, poses,
  per-eye draw counters, credits, and final cache/network counters; no key or URLs.

Google/provider attribution is burned into the bottom of both eyes, also in
the PNG previews, and recorded per frame. If it cannot fit, export fails
rather than truncating it. These overlays cover a strip of the rendered view.

`video --help` lists the bounded option ranges. GPU/encoder failures, rejected
keys, load timeouts and invalid tracks exit nonzero. Existing outputs are not
overwritten. Inspect the printed error and select a new directory to retry.

## Verify an export

The repository includes an AVFoundation checker; no ffmpeg install is needed:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun swiftc \
  -parse-as-library Scripts/verify-stereo-video.swift -o build/verify-stereo-video
build/verify-stereo-video build/manhattan-spatial
```

It decodes every frame, checks resolution, frame count, timestamps and movie
duration, and for spatial output requires two correctly tagged eye buffers,
distinct eye images, and the expected spatial metadata. It writes decoded
first/last frames for visual inspection, including the encoded attribution.
A headset playback/comfort check remains separate.

## Format references

Apple's [spatial-video conversion sample](https://developer.apple.com/documentation/avfoundation/converting-side-by-side-3d-video-to-multiview-hevc-and-spatial-video)
provides the MV-HEVC layer/eye IDs, tagged-buffer writing, and metadata units.
[Build compelling spatial photo and video experiences](https://developer.apple.com/videos/play/wwdc2024/10166/)
explains rectification and spatial presentation.
