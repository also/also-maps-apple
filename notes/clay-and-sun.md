# Clay model and sun study: working notes

A spike on the experimental Metal renderer (Settings › General › Draw with
Metal). Branch `spike/clay-and-sun`. Newest entries first in the log at the
end. **Observed** means seen running, on a device, in logs or in a test run.
**Inferred** means reasoned from the code but not confirmed. Nothing here has
been built yet: the spike was written in a Linux container with no Xcode, so
nothing in it is Observed on Apple hardware.

## Goals

1. **Clay model mode.** Draw the city's real photogrammetry without its
   photographs, as a matte warm-grey model lit by a directional light, like
   an architect's study model.
2. **Sun and shadow study.** Pick a date and time; the light comes from the
   true sun for the place, buildings cast shadows, and the sun's path for
   that day is drawn across the sky. The question it answers: "when does the
   sun reach my balcony in December?"

Both are only possible because the Metal renderer draws tiles with its own
shaders. The RealityKit renderer doesn't get them.

## Design

### Where it lives

- `Sources/Metal/SolarPosition.swift` (pure): NOAA's solar position
  equations. Azimuth, elevation (geometric, plus NOAA's refraction for an
  "apparent" elevation), declination, equation of time, and the day's path
  in a given time zone. The ENU direction is written out from the hour angle
  and declination rather than NOAA's `acos` azimuth, so there's no branch at
  noon and nothing ill-conditioned at the zenith.
- `Sources/Metal/SunShadowFit.swift` (pure): the sun's orthographic view in
  the anchor frame.
- `Sources/Metal/SunClock.swift` (pure): the chosen instant as a day and time
  of day in the place's zone; time-lapse looping; a longitude-only zone.
- `Sources/Metal/SunStudy.swift` (main actor, `@Observable`, singleton): the
  switches, the clock, the zone lookup, and each frame's
  `MetalTileRenderer.Lighting`. With every switch off it returns nil and the
  renderer takes exactly its old path (same pipeline, same fragment function).
- `Sources/Metal/MetalTiles.swift`: a second fragment function
  (`studyFragment`), a depth-only shadow pipeline (`shadowVertex`), the
  sun-path dots (`sunPathVertex`/`sunPathFragment`), `prepare` (shadow pass)
  and `encodeSunPath`.
- Hosts: `MetalMapView` (macOS, iOS) and `MetalImmersiveRenderer`
  (visionOS) ask `SunStudy.shared.lighting(...)` each frame.
- `Sources/Settings/SettingsView.swift`: a **Clay and Sun** category.

The pure files are in the `Also Maps Core Tests` target (project.yml), with
tests in `Tests/Metal/SolarPositionTests.swift`, `SunShadowFitTests.swift`
and `SunClockTests.swift`. tvOS doesn't compile `Sources/Metal` or
`Sources/Settings`, so it's untouched.

### Everything in the anchor frame

All lighting is done in the streaming anchor's frame (x east, y up, z south,
metres), which is where the bridge places every tile (`drawnTiles`'
placements). The sun's direction is computed at the anchor's coordinate and
mapped to those axes (`SolarPosition.anchorFrame`). The vertex shader passes
each vertex's anchor-frame position (`anchorFromLocal` = placement, a new
field in `TileUniforms`) and, for ion content with normals, its anchor-frame
normal. This means:

- The map's own transform (root: scale, yaw, the globe tilt) never touches
  lighting, so the sun stays fixed to the world when you turn the map.
- Held (Fly) tiles keep their placements relative to the held anchor, and
  streaming keeps its held inputs, so `streaming.inputs.anchor` is the right
  frame for them too.
- The viewer's position, needed to orient flat normals, is moved into the
  anchor frame with `root.inverse` per view.
- The hemisphere ambient uses anchor-frame up. **Inferred:** at globe scale,
  far from the anchor, "up" is wrong (the Earth curves away). Shadows are
  limited to a disc near the anchor, so only the ambient tint is affected,
  and only far out.

### Clay

- Photogrammetry tiles have no normals (the bridge sends normals only for
  untextured content). A flat normal per pixel comes from
  `cross(dfdx(p), dfdy(p))` on the anchor-frame position, then flipped to
  face the viewer, which sidesteps both the derivative's handedness and the
  skins' unknown winding. ion content keeps its own (smooth or flat) normals.
  Computing flat normals at upload would mean unwelding Google's indexed
  meshes (3× the vertices); derivatives cost nothing in memory.
- Shading: `clay × (hemisphere ambient + sun colour × max(n·L, 0) × strength
  × shadow)`. The hemisphere mixes a ground colour and a sky colour by
  `n.y`. Colours change with the sun's elevation: direct light fades in as
  the disc clears the horizon (−1° to 3°, apparent), the sky's light through
  civil twilight (−6° to 6°), and the sun warms below 25°. The window's or
  compositor's clear colour darkens with it. All tuned by guess, not by eye.
- No ambient occlusion yet. Screen-space AO needs a separate depth and
  normal pre-pass per eye; the next cheap step would be a horizon-based AO
  pass over the depth buffer the main pass already writes, or a sky-
  visibility term from a few extra shadow maps from around the sky (which
  would double as soft skylight shadows). Not attempted.

### Shadows

- One orthographic depth map from the sun per frame, `depth32Float`,
  2048² by default (`ALSOMAPS_SHADOW_RESOLUTION`, 256–8192). On visionOS it
  is rendered once per drawable, before both eyes' passes, in the same command
  buffer, and both eyes sample it.
- Fit (`SunShadowFit`): a square in the sun's view covering a disc around the
  anchor of radius `min(streamingRadius × √2, 1500 m)`
  (`ALSOMAPS_SHADOW_RADIUS` changes the cap). Depth spans every drawn tile's
  bounds (their corners through each tile's placement), so casters outside
  the square still cast into it. The centre snaps to whole texels, so panning
  doesn't make shadow edges shimmer. At the default 1500 m that's 1.5 m a
  texel: fine for buildings, too coarse for balconies. For the balcony
  question, zoom in (a smaller area of interest means a smaller disc) or
  raise the resolution.
- The shadow pass draws every drawn tile the sun's view can see, culled with
  the same `MetalFrustum` test as the main pass (the ortho clip volume is
  0…w in z too), and clears to 1 with `less`: regular Z, unlike the main
  pass's reverse Z.
- Sampling: 3 × 3 PCF of hardware-filtered comparisons. To avoid acne, the
  receiver point is moved 1.5 texels along its normal and one toward the sun
  before projecting, so the bias is in metres and follows the texel size.
  Outside the map is lit. No shadows once the sun is down.
- Over textures (**Shadows over photos**): the photographs already carry
  Google's capture-time daylight and shadows, so shadows only darken
  (to 55 %), faces turned from the sun count as shadowed, and the whole
  scene dims at night. This is the option the brief asked for so the owner
  can judge whether it looks acceptable; expect double shadows.

### Sun path

- Drawn with the Metal renderer (not RealityKit, which the Metal hosts don't
  use): one instanced quad per dot, a constant fraction of the view's height
  across, round by `discard`, depth-tested against the city and writing
  depth (so the compositor reprojects them where they are).
- Dots sit on a dome over the anchor, radius `0.8 × streamingRadius`
  (50 m–5 km): a sun-path diagram over the model rather than dots at
  infinity, so it reads from above in the window as well as from inside it.
  Every 10 minutes while the sun is up (apparent elevation > −0.5°), bigger
  on the hour, the current sun biggest and pale; a grey horizon ring every 5°
  with north in red.

### Time and time zone

- Times are **the place's**, not the device's: "8 am on 21 December in
  Lisbon" whatever zone the device is in, which is what the balcony question
  needs. The zone comes from a reverse geocode (`CLGeocoder`, placemark
  `timeZone`), looked up again after moving 25 km. Until it answers, or if it
  fails (offline), the longitude's hour stands in (`SunClock.
  approximateTimeZone`, no daylight saving), and the label says "from
  longitude".
- Until the time is changed, a zone change keeps the instant (now). Once the
  date or time is changed, a zone change keeps the wall-clock time chosen
  instead: set 08:00 in December, fly to Tokyo, and it's 08:00 in Tokyo.
- The instant isn't saved; each launch starts at now, or at
  `ALSOMAPS_SUN_TIME`.
- **Play the day** loops the chosen local day at 2,400×, a day in 36 s.

### Switches

All off by default. Settings › Clay and Sun has **Clay model**, **Sun
shadows**, **Shadows over photos** (shown when shadows are on) and **Sun
path**, disabled with a note when Draw with Metal is off. Environment
variables turn them on for a run, like `ALSOMAPS_METAL`:

| Variable | Effect |
| --- | --- |
| `ALSOMAPS_CLAY=1` | Clay model |
| `ALSOMAPS_SHADOWS=1` | Sun shadows |
| `ALSOMAPS_SHADOWS_TEXTURED=1` | Shadows over photos (with shadows on) |
| `ALSOMAPS_SUN_PATH=1` | Sun path |
| `ALSOMAPS_SUN_TIME=2024-12-21T09:00:00+00:00` | Starting instant (ISO 8601) |
| `ALSOMAPS_SHADOW_RADIUS=600` | Cap on the shadow disc's radius, metres |
| `ALSOMAPS_SHADOW_RESOLUTION=4096` | Shadow map size |

### Google Maps Platform terms

- Nothing is stored or exported: the shadow map, flat normals and lighting
  are computed on the GPU each frame from tiles already loaded, and dropped.
  No surface heights leave the renderer.
- Nothing from another provider is drawn over Google's tiles. The reverse
  geocode only reads a time zone name; nothing from it is drawn.
- The Google logo and attributions are SwiftUI overlays outside the
  renderer, so clay mode leaves them as they are. **Open question** below on
  whether clay is acceptable at all.

## Unverified

Places marked `UNVERIFIED:` in code, and other things a build or a device
has to confirm:

1. **Comparison order** (`MetalTiles.swift`, `sunVisibility`): the shader
   assumes `sample_compare` with `compare_func::less_equal` passes where the
   reference depth is ≤ the stored depth. If shadows come out inverted (lit
   where they should be dark, and vice versa), switch to `greater_equal`.
2. **CLGeocoder** (`SunStudy.swift`): deprecated in the 26 SDKs in favour of
   MapKit's reverse geocoding request, I believe, but still available. Expect a
   deprecation warning. If it fails, the longitude zone stays.
3. **DatePicker and time zones** (`SettingsView.swift`): assumes
   `.environment(\.timeZone, …)` makes DatePicker show and set the day in the
   place's zone. If not, the day can be off by one near midnight.
4. **The whole shader**: compiled from source at launch, so a typo shows up
   only when the app starts. A failure prints `[AlsoMaps] Metal pipeline
   failed:` with the compiler's message, and nothing is drawn.
5. **Flat-normal flip**: the facing-the-viewer flip should make both the
   derivative's handedness and the winding irrelevant, but on foveated
   (rasterization-rate-mapped) eye textures the derivatives are in physical
   pixels. They should still give the right plane; not checked.
6. **Uniform layouts**: `Uniforms`/`TileUniforms` (3 × float4x4, float4,
   uint), `LightUniforms` (float4x4, 7 × float4, uint), `SunPathUniforms`
   (float4x4, float) and `SunPathDot` (2 × float4) were laid out to match by
   hand, with no float3 members.
7. **Swift**: none of this has been type-checked; `swift` isn't installed in
   the container and the toolchain download was blocked. The solar equations
   and the test expectations were checked with a Python transcription
   (below).
8. **Cost**: the shadow pass redraws every drawn tile the sun can see, once a
   frame. The renderer had about 7 ms a frame spare on Vision Pro in an
   optimised build (notes/metal-renderer.md); the shadow pass might use a
   good share of it. The `MetalShadow` signpost (category `Frame`) times its
   encoding; the GPU time needs Metal System Trace.

## Test plan

Build as in the README's Setup (`xcodegen generate` first). Use an optimised
build on Vision Pro (the `Also Maps visionOS (Optimised)` scheme): Debug
misses frames on its own.

### Core tests (Mac)

1. Run the `Also Maps Core Tests` scheme. The new suites are
   `SolarPositionTests`, `SunShadowFitTests` and `SunClockTests`. All should
   pass. If `matchesTheNRELSolarPositionAlgorithmExample` fails by a few
   hundredths, the tolerance may simply be tight; the Python twin is 0.003°
   off.

### Mac (quickest)

1. Run the Mac app with `ALSOMAPS_METAL=1 ALSOMAPS_CLAY=1` (README, "Running
   and inspecting the Mac app"), at a dense city: New York at street level,
   or a saved place. Expect: the city in matte warm grey, faceted, lit from
   one side, sky blue behind. Check the console for `Metal pipeline failed`.
2. Turn the map: the lit side should stay fixed to the world (lit faces keep
   facing the same compass direction).
3. Add `ALSOMAPS_SHADOWS=1 ALSOMAPS_SUN_TIME=2024-12-21T15:00:00-05:00` in
   New York (mid-afternoon, sun low in the south-west, about 13° up): long
   shadows toward the north-east. If the city is dark everywhere and lit only
   where it should be shadowed, see Unverified 1.
4. Open Settings › Clay and Sun. Drag the time slider through the day:
   shadows swing from west to east, the light warms near sunrise and sunset,
   and the city and sky go dark at night. Try **Play the day**.
5. Turn on **Sun path**: an arc of orange dots over the city, bigger on the
   hour, the sun's dot pale and large, a grey horizon ring with a red dot at
   north. Low in the south in December, high in June. Sanity check: in
   New York on 21 June the noon dot should be about 73° up, due south.
6. Turn clay off, keep shadows and turn on **Shadows over photos**: judge
   whether it's useful or just double shadows.
7. Look for shadow acne (stripes on lit roofs), peter-panning (shadows
   detached from their buildings), and shimmer while panning. Try
   `ALSOMAPS_SHADOW_RESOLUTION=4096` and `ALSOMAPS_SHADOW_RADIUS=500`.
8. Check the time zone: the footer should name the place's zone once the
   lookup answers (e.g. "EST"), and "UTC−5, from longitude" before it or
   offline. Fly to Tokyo with a time set: it should stay that wall-clock time.
9. Everything off: the map should look exactly as on `main`.

### Vision Pro

1. Settings › General › Draw with Metal on, Settings › Clay and Sun: Clay
   model, Sun shadows and Sun path on. Open Immersive.
2. Expect the clay city around you, with shadows identical in both eyes
   (one map per frame) and the sun-path dome overhead. Close one eye then
   the other: no shadow disagreement between eyes.
3. Keep Settings open beside you and drag the time slider: shadows move live.
4. Toggle Fly (held tiles), move and turn: shadows stay attached to the
   buildings.
5. Record a profile with the `MetalShadow` signpost (docs/profiling.md, with
   `env -u OS_ACTIVITY_DT_MODE`), once with shadows off and once on, from the
   same saved view with a warm cache (docs/tile-caching.md), and compare
   `ImmersiveRender`, `MissedDeadline` and GPU time.

### iPhone

Same as the Mac, from Settings.

## Open questions for the owner

1. **The tabletop volume.** On visionOS, Metal draws only the immersive
   space; the volume is RealityKit. The "physical model on a table" look
   needs either the Metal path in the volume (a CompositorLayer can't be in a
   volume; it would mean a `LowLevelTexture` or `LowLevelMesh` bridge into
   RealityKit) or a RealityKit clay material: a plain `PhysicallyBasedMaterial`
   with no texture is easy, but flat normals and sun shadows there would need
   unwelded meshes and RealityKit's directional light shadows. Worth a
   separate spike?
2. **Clay and Google's terms.** Clay draws Google's geometry without its
   imagery. That's an effect computed while rendering, and attribution stays,
   but whether Google would see an untextured rendering as acceptable use of
   Photorealistic 3D Tiles is worth checking against the Map Tiles API
   policies before shipping.
3. **Time zone source.** Is Apple's reverse geocoder acceptable here (it
   sends the coordinate to Apple), or would you rather use the longitude's
   hour, or the device's zone?
4. **Should the clay and sun switches turn Draw with Metal on** instead of
   being disabled without it? I chose disabled, so turning them on never
   restarts streaming by surprise.
5. **Sun path placement.** A dome over the area of interest (a sun-path
   diagram) or directions at infinity around the viewer (a true sky)? I
   chose the dome so it reads from above in the window; in Immersive at
   street level a sky arc might read better.
6. **Save the chosen date and time** between launches, or always start at now?

## Log

### 2026-11-05: spike written, unbuilt

- **Observed (Python):** a Python transcription of `SolarPosition`'s
  equations gives, for NREL SPA's worked example (17 October 2003,
  12:30:30 UTC−7, 39.742476° N 105.1786° W): apparent zenith 50.1086°
  (SPA 50.11162°), azimuth 194.3426° (SPA 194.34024°), declination −9.3158°
  (SPA −9.31434°), equation of time 14.647 min (SPA 14.641503). At the 2024
  solstices (USNO instants) declination ±23.4386°. London's noon elevation on
  21 June 2024 is 61.937°, against 90 − 51.5 + δ = 61.937°, at azimuth
  180.03°. Tromsø on 21 December 2024 peaks at −2.98° apparent. These are the
  numbers the Swift tests expect, within their tolerances.
- **Inferred:** `swift` isn't available in the container and
  download.swift.org was blocked by the proxy, so nothing was type-checked.
  The shadow fit's and clock's tests were worked through by hand only.
- **Inferred:** the derivative flat normal makes Google's meshes look
  faceted at every triangle, which suits the study-model look. Smoother clay
  would need normals generated at upload (cesium-native can generate smooth
  normals for content that lacks them, as the ion terrain path does, but for
  Google's textured tiles the bridge skips normals entirely).
