# MapVolume

A visionOS app that streams Google's Photorealistic 3D Tiles into a volumetric window, using [cesium-native](https://github.com/CesiumGS/cesium-native) for tile selection and loading and RealityKit for rendering.

## How it fits together

- `Sources/Cesium/CNTileStreamer.{h,mm}`: an Objective-C++ bridge that owns a cesium-native `Tileset`. It provides:
  - networking over `NSURLSession` (cesium-native is built without curl)
  - a GCD task processor
  - an `IPrepareRendererResources` that flattens each tile's glTF into float positions (small offsets from the tile's own centre), UVs, indices and RGBA. Every frame each drawn tile gets a transform, computed in double, that places it relative to the current focus. There's no global origin, so precision is the same anywhere on Earth
  - an excluder that limits streaming to the square region shown, measured in the focus's own frame. The focus is a latitude/longitude, moved along the globe
- `Sources/MapVolumeModel.swift`: runs one cesium-native update per RealityKit frame, turns new tiles into `ModelEntity`s with unlit textured materials, hides tiles that aren't selected, removes freed ones, and handles pan and zoom.
- The Shared Space provides no head pose, so a synthetic camera in front of the volume, 45° up, drives level of detail.

## Setup

1. **Build the xcframework.** Use the `visionos` branch of [also/cesium-native-xcframework](https://github.com/also/cesium-native-xcframework/tree/visionos), checked out next to this repo, then copy the result in:

   ```
   ../cesium-native-xcframework/build-xcframework.sh --slices "visionos visionos-simulator"
   cp -R ~/.cache/cesium-native-xcframework/out/CesiumNative.xcframework Vendor/
   ```

   The build needs cmake and ninja, plus Xcode with the visionOS SDK. If `xcode-select` points at the Command Line Tools, prefix the command with `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`.

2. **Add an API key.** Copy `Config/Secrets.example.xcconfig` to `Config/Secrets.xcconfig` and set `GOOGLE_MAPS_API_KEY`. The key needs the Map Tiles API enabled. Restrict it to iOS apps with bundle ID `com.ryanberdeen.MapVolume`; the app sends `X-Ios-Bundle-Identifier`. You can also set `GOOGLE_MAPS_API_KEY` in the scheme's environment.

3. **Generate the project and run it.**

   ```
   xcodegen generate
   open MapVolume.xcodeproj
   ```

   Run on the Apple Vision Pro simulator or a device running visionOS 26 or later.

To test without a key, tick the `MAPVOLUME_*` variables in the scheme. They stream a public Cesium sample tileset instead. `MAPVOLUME_LAT`, `MAPVOLUME_LON`, `MAPVOLUME_RADIUS` and `MAPVOLUME_HEADING` also work on their own, to start somewhere other than the Ferry Building.

## Controls

- **Pan:** look at the map, pinch and drag. Gestures are indirect only (look and pinch), so open hands over the map do nothing.
- **Zoom:** pinch with both hands and move them apart or together. The view's half-width ranges from 50 m to the Tuning window's zoom-out limit (20 km by default, up to 10,000 km).
- **Turn:** pinch with both hands and twist about the vertical. The map turns around the focus point and can turn while zooming.
- **Hardware keyboard:** WASD or the arrow keys move relative to where you're facing, Q and E turn, R and F (or `=` and `-`) zoom, and holding Shift goes three times faster. The ornament shows these hints while a keyboard is connected.
- **Game controller** (Xbox-style): the left stick moves. The right stick turns (left/right) and changes altitude (up climbs, which zooms out; down descends). Both sticks are analog with a dead zone. RT and LT also zoom in and out. Hold LB, or click the left stick, to go faster. D-pad left and right step through places, and Y faces north. The ornament shows these hints while a controller is connected. Keyboard and controller input combine, and the Tuning window's turn pivot applies to both.

`MAPVOLUME_HEADING`, in degrees clockwise from north, sets the starting direction.

## Places

The pin button next to the mode picker jumps to a saved place: its position, zoom and facing. The defaults are in `Sources/Places/Places.json` (San Francisco, Boston, New York and Chicago). Each entry has an `id`, `name`, `latitude`, `longitude`, `radius` (view half-width in metres) and an optional `heading` (degrees clockwise from north). `PlaceLibrary` is where user-added places, stored locally or in iCloud, would be merged in later. `MAPVOLUME_PLACE=<id>` starts at that place.

## Views

The picker under the volume switches between the volume and floor modes. A floor mode opens a mixed-immersion space and lays the map on the floor in front of you at 3×, 5× or 10× the volume's size. The volume stays open as the control panel, and an attribution panel sits at the map's near edge. If you close the volume while in a floor mode, that panel shows **Show Controls** to bring it back. Opening the app from the Home View always reopens the volume.

Every mode streams the same tiles at the same level of detail, so a floor mode is the volume's map enlarged, at lower effective resolution. To try other sizes or placements, add entries to `MapPresentation.all`. `MAPVOLUME_PRESENTATION=floor5x` (or another mode's `id`) starts in that mode.

Floor mode doesn't clip the map's edges the way the volume does, so whole tiles stick out past the region.

## Tuning

The slider button next to the mode picker opens a Tuning window with live stats and streaming settings. Changes apply immediately and are remembered between launches. **Reset to Defaults** returns to the hand-tuned baseline in `StreamingSettings.default`.

- **Region** (floor modes only): streams past the volume-sized square, up to 10× its half-width.
- **Detail / Outer detail**: cesium-native's screen-space error thresholds, for tiles inside and outside the LOD camera's view. Most of an expanded region is outside that view, so Outer detail controls how sharp the far map is and how many tiles it costs.
- **Upload budget, Simultaneous loads, Cache, Forbid holes**: trade-offs between fill speed, hitching and memory.
- **Turn and zoom around**: the map's centre, or **where you are**: the ground beneath the viewer stays fixed, so zooming is moving straight up or down and turning is turning on the spot. The viewer is where you stood when floor mode opened, or, for the volume, just in front of it. This applies to every input: sticks, triggers, keys, pinch and twist.
- **Zoom-out limit**: 20 km to 10,000 km, on a logarithmic slider. Below 50 km the ground is placed by sampling terrain. Above 50 km it's placed by the Earth's curve, so sea level at the view's edges meets the floor, with no sampling. At hemisphere scale, tiles on the far side of the Earth are skipped.

`MAPVOLUME_OPEN_TUNING=1` opens the window at launch.

## Known gaps

- Mesh and texture creation run on the main thread under a time budget per frame, which causes hitches while streaming (#1).
- Below 50 km, ground height is the lowest hit on a 3×3 grid of samples. In a region that's mostly hills with a little low ground, the hills can reach close to the top of the volume.
