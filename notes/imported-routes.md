# Imported routes: working notes

Notes on the imported-routes spike (branch `spike/imported-routes`): what it's for, how it's built, what hasn't been checked, how to try it, and a running log of findings, newest first. **Observed** means seen when something actually ran. **Inferred** means reasoned from the code or the docs but not run. Nothing in the app has run yet: the branch was written in a Linux container with no Swift toolchain, Xcode or device, so every in-app behaviour below is Inferred. The only Observed findings come from Python checks of the data and the maths.

## Goals

- **Bring your own movement into the 3D world.** Open a GPX file (a run, ride, hike or flight) and see it as a tube over the photorealistic terrain.
- **Colour it by what happened:** speed, elevation, heart rate or cadence, with a legend.
- **Put it at the right height:** either on the ground (GPS heights are too noisy for that) or as recorded (for flights).
- **Replay it:** play the route in time at 10× to 120×, with the camera behind and above the moving point, turning with the direction of travel smoothly enough not to wobble.
- **Respect the constraints:**
  - off by default;
  - tvOS left out but still compiling;
  - in the immersive space the camera is always the eye (docs/navigation-handoff.md);
  - Google's terms: no stored surface heights, no other provider's content over the tiles, attribution stays visible.

## Design

### The pipeline

```
file ─RouteImport─▶ RouteDocument ─▶ ImportedRoute ─heights(mode:surface:)─▶ ECEF positions
                    (as read)        (densified, distance,                       │
                                      speed, replay clock)          RouteGeometry (coloured runs)
                                                                                  │
                                                         RouteOverlay (a TubeExtruder mesh per colour)

replay: ImportedRoute.playback (TrackPlayback) ─▶ moving point ─▶ ChaseCamera ─▶ the host's navigation camera
```

Everything up to `RouteGeometry`, plus `ChaseCamera` and `Geoid`, is plain Swift in `Sources/Routes/`, in the `Also Maps Core Tests` target with tests in `Tests/Routes/`. The RealityKit and SwiftUI parts are `Sources/RouteOverlay.swift`, `Sources/RouteSession.swift` (per map, like `TrackSession`) and `Sources/RouteControls.swift` (the menu and legend). They're in the visionOS, macOS and iOS targets, not tvOS.

### Reused, and new

- **Reused unchanged:**
  - `TubeExtruder`: one instance per colour.
  - `TrackPath.dropTolerances`: simplification, per coloured run.
  - `TrackPlayback`: the moving point's interpolation and segment jumps, fed route points as `CameraTrack.Sample`s.
  - `Geodesy`, `GeoMath`, `CameraPose`, `NavigationContext.clampHeight`.
  - Each host's `go(to:)`: framing.
  - The track-playback pattern in `MapModel` and `ScreenMap`: a played camera that blocks input and is stopped by places, restores and presentation switches.
- **New:**
  - the parser;
  - the geoid;
  - draping;
  - colouring;
  - the chase camera;
  - one bridge call: `sampleSurfaceHeights(latitudes:longitudes:completion:)`, which wraps cesium-native's `sampleHeightMostDetailed` for a list of points.

### Parsing (`RouteDocument.swift`)

- **GPX 1.0 and 1.1, with `XMLParser`:**
  - Each `trkseg` and each `rte` becomes a line, with a gap drawn before the next. Waypoints are ignored.
  - Per point: `lat`, `lon`, `ele`, `time` (with or without fractional seconds, `Z` or an offset), plus heart rate and cadence.
  - Heart rate and cadence come from the Garmin TrackPointExtension (`hr`, `cad`) or the bare `heartrate` and `cadence` some apps write.
- **Matched by local name:** elements are matched by their name without the prefix, so `gpxtpx:` and `ns3:` both work. Namespace processing stays off, because with it on an undeclared prefix is a fatal error.
- **Points skipped:** points with no usable position (out of range, or not numbers) are skipped.
- **GeoJSON (the stretch goal, done):**
  - LineString and MultiLineString, from a bare geometry, a Feature, a FeatureCollection or a GeometryCollection.
  - togeojson's per-coordinate times and heart rates, in both of its conventions (`coordinateProperties.times`/`.heart` and `coordTimes`).
  - GeoJSON heights are taken as **ellipsoidal**, per RFC 7946, though some tools write sea level there (see open questions).
- **Format choice:** by file extension, or by whether the data starts with `{`.

### Deriving the route (`ImportedRoute.swift`)

- **Densified:** points are added so no step is longer than 30 m, so a sparse route still follows the ground between fixes when draped. Sparse means a planned route, or a watch that records every 5–30 s. It stops at 50,000 points, beyond which steps get longer.
- **Distance:** distance along the route, with the gaps between segments not counted.
- **Speed:** distance over a 10 s window centred on each point, and at least the neighbours either side. GPS fixes jitter by metres, so a 1 s speed is noise. Speed is only computed when every point has a time and the times are in order; otherwise there are no times at all.
- **The replay clock:**
  - It follows the recorded times.
  - A gap over 10 s covering less than 0.5 m/s is a pause (a café, a light, auto-pause), and the replay skips it in 1 s.
  - Each segment change holds for 1 s, then jumps.
  - With no times, the clock is the distance at 10 m/s.
- **Typical speed:** distance ÷ moving time. It sets the chase distance and the heading lookahead.

### Heights

- **On the ground** (the default) drapes the route on the map's surface, sampled at run time, plus 1 m.
  - **Samples:** up to 400 points along the route (`drapeIndices`: every 40 m, or more widely to stay within budget, plus each segment's ends), asked for in batches of 64 so the tube settles onto the ground as they land.
  - **Between samples:** heights are interpolated by distance, and held past the first and last.
  - **Lift:** the overlay also lifts a draped tube by its own radius, so it sits on the surface instead of half in it. The radius changes with scale, which is why the lift is applied when the mesh is rebuilt, not baked into the points.
  - **Before the samples arrive:** points use the recorded height, or sea level.
  - **Retries:** a batch that hasn't come back in 45 s is sent again. A tile source switch replaces the streamer, which may drop it.
- **As recorded** uses the file's heights. GPX `ele` is above mean sea level, so the geoid height is added (`Geoid`). Points with no height are draped, then fall back to sea level.
- **The geoid** (`Geoid.swift`, `GeoidGrid.swift`) is EGM96 sampled every 2° (91 × 180 values, stored as base64 Int16 decimetres: 48 KB of source, no bundle resource), interpolated bilinearly.
  - **Accuracy against GeographicLib's 15′ grid:** RMS 0.96 m, 99% of points within 3.9 m, worst 17 m (near trenches and steep mountain fronts). See the log.
  - **Source and licence:** generated by `Scripts/make_geoid_grid.py` from GeographicLib's `egm96-15.pgm`. EGM96 is the US National Geospatial-Intelligence Agency's model, a US government work in the public domain. The grid isn't Google content.
  - A 1° grid (130 KB) would give RMS 0.45 m, 99% within 1.8 m. That isn't worth it while GPS heights wander by 10 m or more.
- **Google's terms:** the sampled surface heights live only in `RouteSession`'s memory and are dropped when the route closes. Nothing derived from tiles is written to disk or exported. The route itself is the user's own data.

### Colouring (`RouteColouring.swift`, `RouteOverlay.swift`)

- **Choice:** the tube is split into a few meshes binned by value, each with its own material, not a per-vertex colour attribute.
  - **Why:** RealityKit's built-in materials (`PhysicallyBasedMaterial`, `UnlitMaterial`) don't read a vertex colour from a `LowLevelMesh`. Using one would need a ShaderGraph material authored in Reality Composer Pro.
  - **Bonus:** binning gives discrete colours a legend can explain, and `TubeExtruder` stays as it is.
  - **Cost:** at most ten tube entities and draw calls.
- **Bins:** 8, spaced evenly between the 5th and 95th percentiles, so a GPS spike or a dropped strap doesn't squash everything into one colour. Values beyond either end take that end's colour. Each kind of value has a minimum span (2 km/h, 10 m, 10 bpm, 10/min), so a flat ride isn't a rainbow.
- **Colours:**
  - the ramp runs blue → teal → green → yellow → orange → red;
  - grey is for no data;
  - orange (as camera tracks use) is for "Single colour".
- **Runs:** each step between two points takes the bin of its ends' mean, consecutive steps in one bin form a run, and runs share their end points, so there are no gaps.
  - **Simplification:** each run is simplified separately, so colour boundaries never get simplified away. Simplifying first and colouring after would merge changes along a straight road.
  - **Runs never cross segments.**
- **Legend:** `RouteLegend` shows:
  - the name and length;
  - the colour ramp with its end values;
  - replay time and speed-up;
  - draping progress, or why a file didn't open.
- **Where the legend sits:**
  - visionOS: the attribution panel (the volume's ornament, and the immersive space's attachment), above the Google logo and credits, never replacing them;
  - Mac: under the menus at the top right;
  - iPhone: under the track status.

### Opening and framing

- **Route menu:** next to Places (the volume's toolbar, the Mac's top-right overlay, the iPhone's bar), shown only while the switch is on. It has:
  - Open Route…;
  - Colour by (only colourings the route has values for);
  - Height;
  - Replay or Stop Replay;
  - Replay speed;
  - Show Whole Route;
  - Close Route.
- **File importer:** a separate `routeImporter` modifier on the host view, since toolbar items can be rebuilt and lose their state. It handles security-scoped URLs. The Mac Release build gets `com.apple.security.files.user-selected.read-only`; Debug is unsandboxed already.
- **Framing:** opening frames the camera through the host's own `go(to:)`, with a `Place` from the route:
  - centred on the mean of its points;
  - its radius 1.15 × the farthest point, at least 150 m;
  - facing from the start toward the middle.

  So place framing, the ground lift and the jump mark for track recording all behave as for any place.

### Replay and the chase camera (`ChaseCamera.swift`)

- **The moving point** is `TrackPlayback.pose(at:)` on the replay clock. It's at the same heights as the tube: on the ground plus 1 m, without the radius lift, which is display only.
- **The travel heading** is the bearing from 1 lookahead behind the point to 1 lookahead ahead of it along the route. The lookahead is 5 s of typical speed, 15 m to 1 km. That irons out GPS wander and short corners before any smoothing.
- **Camera position:**
  - **Distance:** a chase distance behind the point (20 s of typical speed, 60 m to 3 km).
  - **Height:** 0.4 × that above it (about 22° down), looking at the point.
  - **On visionOS:** room hosts keep the camera at least 55 m above the ground, so the chase is at least 60 m up there, and further back to keep the angle.
- **Smoothing:** the heading eases toward the travel heading with a 1 s half-life (wall-clock time, whatever the speed-up), and the point's height with 0.5 s.
- **Ground clamp:** the host clamps the camera above the ground under it, which can be higher than the route (when a route climbs out of a valley, the camera behind it is in the hillside).
- **The camera is the eye.** The chase produces a `CameraPose` and nothing else. Each host sets it as the navigation camera exactly as track playback does:
  - on a screen it's the window's camera;
  - in the volume, the adaptive model places it at the design eye;
  - in the immersive space, `EyeLevelModel` puts it at the viewer's eye.

  The camera is never a point detached from the viewer. In a headset the head does the looking (pitch is ignored), and the world turns about the eye as the route turns. `ALSOMAPS_CHASE_TURNS=0` keeps the heading fixed instead.
- **While a replay runs:**
  - gestures, the keyboard, the controller and touch are ignored;
  - going to a place, restoring a view, switching presentation or playing a track stops it, and so does reaching the end;
  - the ground is re-sampled every 2 s of wall-clock time, as for track playback.

### The switch

- **Setting:** `ViewPreferences.importsRoutes`, under Settings › General › Imported routes (experimental), saved as `ImportsRoutes` in UserDefaults. It's off by default and kept out of `StreamingSettings`, so Reset leaves it alone, like Draw with Metal.
- **For a run:** `ALSOMAPS_ROUTES=1`, or `ALSOMAPS_ROUTE=<file>`.
- **While it's off:** nothing is drawn or requested, and the menus don't appear. The `RouteSession` objects exist, but idle.

### Launch variables

| Variable | Effect |
|---|---|
| `ALSOMAPS_ROUTES=1` | Shows the Route menu for this run. |
| `ALSOMAPS_ROUTE=<path>` | Opens that GPX or GeoJSON file at launch and frames it (also turns the feature on). A relative path is in the app's Documents folder. |
| `ALSOMAPS_ROUTE_COLOUR=speed\|elevation\|heartRate\|cadence\|plain` | The colouring. |
| `ALSOMAPS_ROUTE_HEIGHT=ground\|recorded` | The height mode. |
| `ALSOMAPS_ROUTE_REPLAY=<speed-up>` | Starts the replay at that speed-up (e.g. 30). |
| `ALSOMAPS_ROUTE_DRAPE_SAMPLES=<n>` | Samples the surface at up to n points (default 400). |
| `ALSOMAPS_CHASE_DISTANCE=<metres>` | Chases that far back, 0.4× that above. |
| `ALSOMAPS_CHASE_TURNS=0` | Keeps the chase heading fixed. |

## Unverified

Everything here was written without compiling. The riskiest assumptions, each also marked `UNVERIFIED:` in the code where it applies:

1. **That it builds** for visionOS, macOS, iOS and tvOS, and that the new core tests pass. No Swift compiler could be downloaded here (swift.org and the Docker registries were blocked).
2. **XMLParser and undeclared prefixes:** whether it accepts a prefix like `ns3:` that's never declared, with namespace processing off. The fixtures declare theirs. If it fails, a real Garmin file would fail to open with an "unreadable" error.
3. **Bridge cost:** what `sampleHeightMostDetailed` costs for a batch of 64 points on a cold cache (time, tiles, bytes), and whether a tileset destroyed mid-sample ever completes its future. The 45 s re-send is there in case it doesn't.
4. **Importer content types:** whether `UTType(filenameExtension: "gpx", conformingTo: .xml)` lets the importer pick `.gpx` files on each platform. `.xml` and `.json` are listed as fallbacks.
5. **A file importer from a visionOS volume:** whether `.fileImporter` presents from a volumetric window, attached as it is to the view behind its bottom-ornament toolbar.
6. **The menu's pickers:** how `Picker`s inside a `Menu` render in the visionOS ornament and on the Mac's button-style menu.
7. **Parameterised tests:** that Swift Testing destructures the tuple arguments in `GeoidTests.matchesEGM96` into three parameters.
8. **Draping looks:** whether draping reads well on Google's surface. It's the highest hit, so a route under trees runs along the canopy, one through a tunnel goes over the hill, and one on a bridge deck is fine.
9. **Comfort in a headset:** the chase turning the world in the immersive space. The heading turns at most about 27°/s for the demo ride at 30× (see the log). That may be too much in a headset.
10. **Performance:**
    - ten `LowLevelMesh` tube entities, rebuilt at each radius step;
    - a full rebuild (heights, runs, Douglas–Peucker) per drape batch, about seven times per route.

    Both are Inferred to be fine at these sizes: thousands of points.

## Test plan

The first time, run `xcodegen generate` (the project is generated). Each run below says whether the tile cache should be cold or warm (docs/tile-caching.md). Draping loads detailed tiles along the whole route, so a cold run costs real requests. The demos are in San Francisco, next to the default view, so a warm cache from normal use covers most of them.

### 1. Core tests (Mac)

```
xcodebuild -scheme 'Also Maps Core Tests' -destination 'platform=macOS' test
```

The new suites are GPXParserTests, GeoJSONRouteTests, GeoidTests, ImportedRouteTests, RouteColourScaleTests, RouteGeometryTests and ChaseCameraTests. They should all pass. If `readsOtherPrefixesBareExtensionsAndRoutes` fails, look at how prefixes are matched first.

### 2. The Mac app, Debug (warm cache)

Build as in the README's "Running and inspecting the Mac app", then:

1. **Default unchanged.** Launch with no variables. There's no Route menu next to Places, and nothing new in the log.
2. **Open the ride.** Launch with:
   ```
   ALSOMAPS_ROUTE="$PWD/Tests/Routes/Fixtures/demo-embarcadero-ride.gpx" \
     "build/Build/Products/Debug/Also Maps.app/Contents/MacOS/Also Maps" > run.log 2>&1 &
   ```
   Expect:
   - **Log:** `route demo-embarcadero-ride.gpx: 1053 points in 1 segments, 6738 m, 1052 s`. Those numbers are from the Python port (log); the Swift should agree to within a metre or a point.
   - **Log, while draping:** about seven `route surface: 64 of 64 samples, …% done` lines.
   - **Framing:** the camera framed on the waterfront from the Ferry Building to Crissy Field, looking roughly west-north-west from the Ferry Building end.
   - **The tube:** coloured by speed and sitting on the road. Blue to green along the slow stretch at Pier 39 and Fisherman's Wharf, orange and red on the open stretches.
   - **Legend** (top right): "Embarcadero ride (demo) · 6.7 km", then "Speed 11 km/h ▭▭▭ 31 km/h". "Placing on the ground… n%" counts up and disappears.
3. **Colour by Heart rate, Cadence, Elevation.** Each should recolour at once, and the legend should change units. Elevation is nearly flat, so it spans the 10 m minimum.
4. **Height › As recorded.** The tube moves to the file's noisy heights plus the geoid (about −33 m here). Expect it to dip into the road and float above it by a few metres. Switch back to On the ground: it settles onto the surface again with no new samples (they're kept for the session).
5. **Replay at 30×.**
   - **Duration:** about 35 s. The three-minute stop near Pier 39 passes in a blink.
   - **Ball and camera:** a white ball runs along the route, with the camera about 130 m behind and 50 m above.
   - **Smoothness:** the heading should turn smoothly through corners, with no wobble from the GPS noise.
   - **Input:** keyboard and mouse do nothing meanwhile.
   - **Legend:** shows "Replay m:ss / 17:32 · 30×".
   - **At the end:** it stops on its own.
   - **Stopping early:** start it again and pick a place from Places. The replay should stop.
6. **The hike.** Launch with `ALSOMAPS_ROUTE=…/demo-twin-peaks-hike.gpx ALSOMAPS_ROUTE_REPLAY=30`. It's 1.5 km up Twin Peaks, with a fix every 5 s that the app fills in.
   - **On the ground:** the tube should follow the hillside, with bumps over trees and roofs.
   - **As recorded:** the tube should wander in and out of the hill by metres. That's the point of the ground mode.
   - **The chase:** it should stay above the hill behind the hiker (the ground clamp).
7. **A real file.** Turn the switch on in Settings › General, then use Route › Open Route… with a GPX from a Garmin, Strava or Apple Health export. Check that:
   - heart rate shows (Garmin's `ns3:` prefix);
   - pauses are skipped;
   - a long ride's legend and chase distance look sensible.
8. **The Release build (sandboxed).** Open Route… should still open a picked file.
9. **Draw with Metal.** The route isn't drawn (as with tracks), but Replay still drives the camera.
10. **Cold cache.** Delete `~/Library/Caches/dev.also.maps/tiles/`, open the ride, and note from Show stats how many tiles draping downloads and how long it takes. This sizes the default of 400 samples.

### 3. Vision Pro (Optimised scheme)

1. **Get the demo onto the device.**
   - **Files:** use the Files app (On My Apple Vision Pro › Also Maps): AirDrop or copy `demo-embarcadero-ride.gpx` there. Then set `ALSOMAPS_ROUTE=demo-embarcadero-ride.gpx` in the scheme's environment (a relative path is read from Documents).
   - **Settings:** or turn on Settings › General › Imported routes and use the toolbar's Route menu.
2. **Volume.**
   - **Toolbar:** the Route menu is after Places.
   - **The route:** the tube is drawn in the volume.
   - **Legend:** in the attribution ornament above the map, with the Google logo and credits still showing.
   - **Open Route…:** presents a file picker. If it doesn't, that's unverified item 5.
3. **Replay in the volume.** The camera chases from at least 60 m up. Pinch and drag should do nothing while it runs.
4. **Immersive.** Launch with `ALSOMAPS_PRESENTATION=immersive ALSOMAPS_FULL_IMMERSION=1 ALSOMAPS_ROUTE=demo-embarcadero-ride.gpx ALSOMAPS_ROUTE_REPLAY=10`.
   - **The eye:** you're the chase camera: the ball runs ahead of you on the floor, and you can look anywhere.
   - **The world:** it turns about you as the route turns.
   - **Comfort:** judge it. Then try `ALSOMAPS_CHASE_TURNS=0` (fixed heading) for comparison.
   - **Legend:** sits in the attribution panel at the map's near edge.
5. **Human scale** (Settings › Immersion), then replay: the chase at 1:1, 60 m back.

### 4. iPhone (if it comes free)

- **Menu and importer:** with the switch on, the Route menu is in the bar and Open Route… uses the document picker.
- **During a replay:** the drone sticks hide, and the legend sits under the track status.

## Open questions for the owner

1. **Comfort in the immersive space:** should the chase turn the world with the route? Alternatives:
   - a fixed heading (built: `ALSOMAPS_CHASE_TURNS=0`);
   - turning only at big changes of direction;
   - a first-person "rider's eye" view.
2. **Draping cost:** is up to 400 most-detailed samples (a few hundred tile loads along a route) acceptable against quota? Draping coarsely first and refining near the camera would cut it.
3. **What draping sits on:** the samples hit the highest surface, so roofs and tree canopy count.
   - Would you rather drape on the lowest of a few nearby samples?
   - Or on a terrain-only source (Cesium World Terrain)? That would be heights from another provider, not their content drawn over Google's tiles, but check it reads that way.
4. **GeoJSON heights:** RFC 7946 says the third coordinate is above the ellipsoid, but many tools write sea level there. Follow the RFC (as built), or treat GeoJSON like GPX?
5. **Should routes be remembered?** The file is the user's own and could be copied into Documents and reopened at launch. The sampled heights couldn't be kept.
6. **Units and readouts:**
   - km/h for everything, or pace (min/km) for runs, or imperial?
   - A readout of the moving point's speed or heart rate during replay?
7. **Relation to camera tracks:** keep two systems, or let a camera track open as a route (a CSV reader would be small)?
8. **Metal:** should the Metal renderer draw routes and tracks? It draws neither today.
9. **Several routes at once:** for example, comparing two rides of the same loop.

## Log

### 2026-11-05: spike written (Linux, no toolchain)

- **Observed (Python):** the 2° EGM96 grid, interpolated bilinearly, against GeographicLib's 15′ grid at every 15′ point:

  | Grid step | Values | RMS | 99% within | Worst |
  |---|---|---|---|---|
  | 5° | 2,664 | 1.90 m | 7.5 m | 23.1 m |
  | 2° (used) | 16,380 | 0.96 m | 3.9 m | 17.1 m |
  | 1° | 65,160 | 0.45 m | 1.8 m | 13.7 m |
  | 0.5° | 259,920 | 0.13 m | 0.5 m | 3.9 m |

  Spot values on the 2° grid against the 15′ grid:
  - 0°, 0°: 17.20 m against 17.16 m;
  - the Ferry Building: −33.3 m against −32.2 m;
  - Everest: −31.6 m against −28.9 m;
  - the Indian Ocean low: −104.1 m against −107.0 m.
- **Observed (Python):** `Geoid.swift`'s decoding and interpolation, transcribed line for line, reproduce those values, wrap at the antimeridian (3 mm apart either side) and give one value at each pole.
- **Observed (Python port of `ImportedRoute` and the chase heading, on the demo files):**

  | | Embarcadero ride | Twin Peaks hike |
  |---|---|---|
  | Points | 1,053 | 345 |
  | Length | 6,738 m | 1,494 m |
  | Replay | 1,052 s, from 1,231 s real (the 180 s stop became 1 s) | 1,720 s |
  | Typical speed | 6.4 m/s | 0.87 m/s |
  | Speed scale | 11–31 km/h | 1.9–5.0 km/h |
  | Chase | 128 m back | 60 m back |
  | Lookahead | 32 m | 15 m |
  | Heading turn at 30×, raw → smoothed | 256°/s → 27°/s | 137°/s → 16°/s |

  The hike's fixes are every 5 s, about 4 m apart, so it needed no densifying.
- **Inferred:** at 27°/s, the ride's sharpest smoothed turn may be uncomfortable in the immersive space at 30×. A longer heading half-life, or a fixed heading, may be needed there.
- **Inferred:** a run's default chase (60 m back, 24 m up) would be clamped to the volume's 55 m minimum altitude and look past the runner. The chase now keeps at least 60 m up in room hosts, moving further back to keep its angle.
- **Observed:** swift.org, Docker Hub (rate-limited) and ECR Public (blocked) were all unreachable from the container, so no Swift was compiled or run.
