# MapVolume

A visionOS app that streams Google's Photorealistic 3D Tiles into a volumetric window, using [cesium-native](https://github.com/CesiumGS/cesium-native) for tile selection and loading and RealityKit for rendering.

## How it fits together

- `Sources/Cesium/CNTileStreamer.{h,mm}`: an Objective-C++ bridge that owns a cesium-native `Tileset`. It provides:
  - networking over `NSURLSession` (cesium-native is built without curl)
  - a GCD task processor
  - an `IPrepareRendererResources` that flattens each tile's glTF into float positions (small offsets from the tile's own centre), UVs, indices and RGBA. Every frame each drawn tile gets a transform, computed in double, that places it relative to the current anchor. There's no global origin, so precision is the same anywhere on Earth
  - an excluder that limits streaming to the area of interest, a square around the anchor measured in the anchor's own frame
  - a level-of-detail camera given as position, direction and up in the anchor's frame
- `Sources/TileUploader.swift`: builds each loaded tile's RealityKit meshes and textures asynchronously, a few at a time, before cesium-native counts the tile as loaded. Meshes are built off the main thread.
- `Sources/TileStreaming.swift`: runs one cesium-native update per RealityKit frame from its streaming inputs (anchor, area of interest, LOD camera), adds ready tile entities, hides tiles that aren't selected and removes freed ones.
- `Sources/Navigation/`: the platform-neutral navigation core, being introduced in stages (see [docs/camera-core.md](docs/camera-core.md)): WGS84 geodesy and surface queries, camera pose and navigation state, the georeference (world → map frame), streaming inputs, and prototype control styles. `MapVolumeCoreTests` tests it on macOS without a scene or network: `xcodebuild -scheme MapVolumeCoreTests -destination 'platform=macOS' test`.
- `Sources/MapVolumeModel.swift`: navigation and presentation. It stores the camera (`NavigationState`), steers it with the core's model-flight style and anchored gestures, and shows it in each host. The volume uses the adaptive model: the world is scaled so the camera sits at the design eye point and what it looks at sits low in the volume. The immersive space uses the eye-level model (`Sources/Navigation/EyeLevelModel.swift`): the camera is at your eye and the map is level on the origin plane, whatever the camera's pitch, with the scale making the camera's height above the ground your eye's height above the floor. Far up, the map tilts with altitude to face you as a globe. Tiles are placed relative to whichever anchor is streaming, so held tiles stay put while you fly.
- The Shared Space provides no head pose, so a synthetic camera in front of the volume, 45° up, drives level of detail.

## Setup

1. **Add an API key.** Copy `Config/Secrets.example.xcconfig` to `Config/Secrets.xcconfig` and set `GOOGLE_MAPS_API_KEY`. The key needs the Map Tiles API enabled. Restrict it to iOS apps with bundle ID `com.ryanberdeen.MapVolume`; the app sends `X-Ios-Bundle-Identifier`. You can also set `GOOGLE_MAPS_API_KEY` in the scheme's environment.

2. **Generate the project and run it.**

   ```
   xcodegen generate
   open MapVolume.xcodeproj
   ```

   Run on the Apple Vision Pro simulator or a device running visionOS 26 or later.

**Optional Cesium ion token:** to use the Cesium ion tile sources, add `CESIUM_ION_TOKEN` to `Config/Secrets.xcconfig`. Create the token with only the `assets:read` scope, restricted to the assets the app uses (1, Cesium World Terrain, and 96188, Cesium OSM Buildings).

**cesium-native** comes prebuilt as a Swift package ([also/cesium-native-xcframework](https://github.com/also/cesium-native-xcframework)); Xcode downloads it on first build. To work on it locally, build it there (see its README), symlink the result next to its `Package.swift`, and change `CesiumNative` under `packages:` in `project.yml` to `path: ../cesium-native-xcframework`.

**Optional soundtrack:** put an MP3 at `Local/soundtrack.mp3`. `Local/` is gitignored, for assets that can't be published. If the file is there, the build bundles it and the app loops it quietly while active, with a mute button in the ornament. Without it, the app simply has no soundtrack.

To test without a key, tick the `MAPVOLUME_*` variables in the scheme. They stream a public Cesium sample tileset instead. `MAPVOLUME_LAT`, `MAPVOLUME_LON`, `MAPVOLUME_RADIUS` and `MAPVOLUME_HEADING` also work on their own, to start somewhere other than the Ferry Building.

## Controls

- **Pan:** look at the map, pinch and drag. Gestures are indirect only (look and pinch), so open hands over the map do nothing.
- **Zoom:** pinch with both hands and move them apart or together. The view's half-width ranges from 50 m to the Tuning window's zoom-out limit (20 km by default, up to 10,000 km).
- **Turn:** pinch with both hands and twist about the vertical. The map turns around the focus point and can turn while zooming.
- **Hardware keyboard:** WASD or the arrow keys move relative to where you're facing, Q and E turn, R and F descend and climb (which is zoom), `=` and `-` zoom, and holding Shift goes three times faster. The ornament shows these hints while a keyboard is connected.
- **Game controller** (Xbox-style): the left stick moves. The right stick turns (left/right) and changes altitude (up climbs, which zooms out; down descends). Both sticks are analog with a dead zone. RT and LT also zoom in and out. Hold LB, or click the left stick, to go faster. D-pad left and right step through places, Y faces north, and X toggles Fly. The ornament shows these hints while a controller is connected. Keyboard and controller input combine, and the Tuning window's turn pivot applies to both.

`MAPVOLUME_HEADING`, in degrees clockwise from north, sets the starting direction.

## Fly

The airplane button, or X on a controller, toggles **Fly**. Streaming freezes, so the loaded tiles stay as they are. Every control then does exactly what it does outside Fly: the same moves, turns and zoom, at the same rates and around the same pivot (the "Turn and zoom around" setting), applied to the frozen scene instead of the live map. The surface stays on the base plane. Turning Fly off resumes streaming from where you are, without anything visibly moving.

Detail doesn't improve as you zoom in, because nothing new loads while frozen. Changing view mode or going to a place leaves Fly.

## Places

The pin button next to the mode picker jumps to a saved place: its position, zoom and facing. The defaults are in `Sources/Places/Places.json` (San Francisco, Boston, New York and Chicago). Each entry has an `id`, `name`, `latitude`, `longitude`, `radius` (view half-width in metres) and an optional `heading` (degrees clockwise from north). `PlaceLibrary` is where user-added places, stored locally or in iCloud, would be merged in later. `MAPVOLUME_PLACE=<id>` starts at that place.

## Views

The picker under the volume switches between the volume and **Immersive**. Immersive opens an immersive space and lays the map level on its origin plane, the floor where you stood when it opened, all around you, with the camera at your eye. The map's centre point, 5.6 m ahead, is where places are framed and where the map pivots as it tilts into a globe far up. The space is mixed (passthrough) unless **Full immersion** is on in Tuning. The volume stays open as the control panel, and an attribution panel sits at the map's near edge. If a system environment (Mount Hood, the Moon and so on) is active, mixed Immersive keeps it, with the map on its ground. If you close the volume while in Immersive, that panel shows **Show Controls** to bring it back. Opening the app from the Home View always reopens the volume.

`MAPVOLUME_PRESENTATION=immersive` (or `volume`) starts in that mode. Saved view states from the earlier 3×, 5× and 10× modes restore into Immersive.

Immersive doesn't clip the map's edges the way the volume does, so whole tiles stick out past the region (#5).

## Tuning

The slider button next to the mode picker opens a Tuning window with live stats and streaming settings. **Tiles** picks the source: Google Photorealistic, or Cesium OSM Buildings or Cesium World Terrain via Cesium ion. The ion sources are untextured, so they're drawn lit. Buildings use their own normals, or flat normals computed per triangle. Terrain uses smooth normals generated by cesium-native, in a flat earth tone until imagery overlays arrive (#8). Switching restarts streaming at the same view. Credits that carry a logo, such as Cesium ion's, show it in the attribution panel. Changes apply immediately and are remembered between launches. **Reset to Defaults** returns to the hand-tuned baseline in `StreamingSettings.default`.

- **Limit reach** (Immersive only): by default Immersive streams everything you could see, all around you out to the horizon (plus ~200 km for mountains beyond it), measured from where your eye is in the world, so a tilted globe shows its whole visible face. Turn this on to stream only **Reach** around you instead: 5× to 100× your height above the ground (the same multiple of your eye height above the floor).
- **Detail / Outer detail**: cesium-native's screen-space error thresholds, for tiles inside and outside the LOD camera's view. Most of an expanded region is outside that view, so Outer detail controls how sharp the far map is and how many tiles it costs.
- **Parallel uploads, Simultaneous loads, Cache, Forbid holes**: trade-offs between fill speed, memory and gaps while refining. Forbid holes is on by default: a tile counts as loaded only once it's drawable, so parents stay until all their children can replace them.
- **Turn and zoom around**: the map's centre, or **where you are**: the ground beneath the viewer stays fixed, so zooming is moving straight up or down and turning is turning on the spot. The viewer is where you stood when the immersive mode opened, or, for the volume, just in front of it. This applies to every input: sticks, triggers, keys, pinch and twist. The pivot is full strength up to a 50 km half-width and fades to the map's centre by 500 km, where there's no meaningful "beneath you" on the curved map. Over the same range the map tilts to face you, like a globe in Google Earth VR. Its centre rises toward eye level and turns so your line of sight meets it head-on, and level-of-detail selection looks down to match. Fully tilted, the bigger immersive modes extend below the floor, so Immersive 3× works best for this.
- **Zoom-out limit**: 20 km to 10,000 km, on a logarithmic slider. Below 50 km the ground is placed by sampling terrain. Above 50 km it's placed by the Earth's curve, so sea level at the view's edges meets the base plane, with no sampling. At hemisphere scale, tiles on the far side of the Earth are skipped.

`MAPVOLUME_OPEN_TUNING=1` opens the window at launch.

**Debugging** (in Tuning):
- **Show pivot and centre markers** draws a red post where turns and zooms pivot, and a blue post at the map's centre.
- **Copy View State** copies the whole view as JSON (position, zoom, heading, presentation, Fly pose and settings) and prints it to the console.
- **Restore from Clipboard** brings a copied state back.

At launch, `MAPVOLUME_STATE=<that JSON>` restores a state and `MAPVOLUME_MARKERS=1` shows the markers.

## Running and inspecting the Mac app (for tools and agents)

The macOS target's **Debug** build is unsandboxed (`SourcesMac/MapVolumeMac.Debug.entitlements`: network client only), so you can launch the binary directly, pass `MAPVOLUME_*` variables, capture its stdout, and read its on-disk state. **Release** keeps the sandbox (`SourcesMac/MapVolumeMac.entitlements`). The sandboxed build keeps its files in `~/Library/Containers/com.ryanberdeen.MapVolume/`, which the shell can't list ("Operation not permitted").

```
xcodebuild -scheme MapVolumeMac -configuration Debug -destination 'platform=macOS' -derivedDataPath build build
MAPVOLUME_LAT=37.7955 MAPVOLUME_LON=-122.3937 MAPVOLUME_RADIUS=800 \
  build/Build/Products/Debug/MapVolume.app/Contents/MacOS/MapVolume > run.log 2>&1 &
```

It needs a logged-in macOS session, since it opens a window. Kill it by PID when done. The API key comes from `Config/Secrets.xcconfig` via Info.plist, or from `GOOGLE_MAPS_API_KEY` in the environment.

Where things land when unsandboxed:
- **HTTP cache**: `~/Library/Caches/com.ryanberdeen.MapVolume/tiles/`. Delete it for a cold run. See [docs/tile-caching.md](docs/tile-caching.md).
- **Defaults**: `~/Library/Preferences/com.ryanberdeen.MapVolume.plist`.

Timing the tile pipeline with signposts and `xctrace` is in [docs/profiling.md](docs/profiling.md). Tile caching, the request counters in the Tuning stats, and how to measure them are in [docs/tile-caching.md](docs/tile-caching.md).

## Known gaps

- The main thread still spends 2–3 ms per frame on tile selection and on re-placing every tile, even when the view isn't moving (#2).
- Below 50 km, ground height is the lowest hit on a 3×3 grid of samples. In a region that's mostly hills with a little low ground, the hills can reach close to the top of the volume.

## tvOS static-map prototype

This worktree adds the `MapVolumeTV` target (tvOS 26+) with a full-screen,
fixed-camera Ferry Building scene. It shares `SourcesMac/MapWindowView.swift`
and the existing tile streaming pipeline. Set `MAPVOLUME_VIEW=bay` to try the
wider Mac view; the existing detail, radius and concurrency overrides work too.
The LOD camera tracks the actual view aspect ratio.

The project currently uses the sibling `../cesium-native-xcframework` package,
with its local XCFramework containing `tvos` and `tvos-simulator` slices. Build
those in the framework repo before generating this project:

```
./build-xcframework.sh --slices "tvos tvos-simulator"
```

Keep `Config/Secrets.xcconfig` configured as above, then run `xcodegen generate`
and select the `MapVolumeTV` scheme and an Apple TV simulator or device in Xcode.
This prototype has no navigation or TV app icon/top-shelf artwork yet.
The local framework must include the corresponding slices to build the other
platform targets in this worktree.

Verified in the Apple TV 4K (3rd generation) simulator with tvOS 27.0:
Debug build succeeded, and the default scene reached 343 rendered tiles,
100% load and 60 fps (first tile 0.7 s, initial load 5.5 s). These are simulator
observations, not measurements on Apple TV hardware.
