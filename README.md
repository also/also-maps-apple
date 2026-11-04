# Also Maps

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
- `Sources/Navigation/`: the platform-neutral navigation core, being introduced in stages (see [docs/camera-core.md](docs/camera-core.md)): WGS84 geodesy and surface queries, camera pose and navigation state, the georeference (world → map frame), streaming inputs, and prototype control styles. `Also Maps Core Tests` tests it on macOS without a scene or network (see [Tests](#tests)).
- `Sources/MapModel.swift`: navigation and presentation. It stores the camera (`NavigationState`), steers it with the core's model-flight style and anchored gestures, and shows it in each host. The volume uses the adaptive model: the world is scaled so the camera sits at the design eye point and what it looks at sits low in the volume. The immersive space uses the eye-level model (`Sources/Navigation/EyeLevelModel.swift`): the camera is at your eye and the map is level on the origin plane, whatever the camera's pitch, with the scale making the camera's height above the ground your eye's height above the floor. Far up, the map tilts with altitude about your eye, so the ground below comes up in front of you as a globe; the camera stays at your eye at every altitude. Tiles are placed relative to whichever anchor is streaming, so held tiles stay put while you fly.
- The Shared Space provides no head pose, so a synthetic camera in front of the volume, 45° up, drives level of detail.

## Setup

1. **Add an API key.** Copy `Config/Secrets.example.xcconfig` to `Config/Secrets.xcconfig` and set `GOOGLE_MAPS_API_KEY`. This is for Debug builds; see [Keys](#keys). The key needs the Map Tiles API enabled. Restrict it to iOS apps with bundle ID `dev.also.maps`; the app sends `X-Ios-Bundle-Identifier`. You can also set `GOOGLE_MAPS_API_KEY` in the scheme's environment.

2. **Generate the project and run it.**

   ```
   xcodegen generate
   open AlsoMaps.xcodeproj
   ```

   Run on the Apple Vision Pro simulator or a device running visionOS 26 or later.

**Optional Cesium ion token:** to use the Cesium ion tile sources, add `CESIUM_ION_TOKEN` to `Config/Secrets.xcconfig`. Create the token with only the `assets:read` scope, restricted to the assets the app uses (1, Cesium World Terrain, and 96188, Cesium OSM Buildings).

**cesium-native** comes prebuilt as a Swift package ([also/cesium-native-xcframework](https://github.com/also/cesium-native-xcframework)); Xcode downloads it on first build. To work on it locally, build it there (see its README), symlink the result next to its `Package.swift`, and change `CesiumNative` under `packages:` in `project.yml` to `path: ../cesium-native-xcframework`.

**Optional soundtrack:** put an MP3 at `Local/soundtrack.mp3`. `Local/` is gitignored, for assets that can't be published. If the file is there, the build bundles it and the app loops it quietly while active, with a mute button in the ornament. Without it, the app simply has no soundtrack.

To test without a key, tick the `ALSOMAPS_*` variables in the scheme. They stream a public Cesium sample tileset instead. `ALSOMAPS_LAT`, `ALSOMAPS_LON`, `ALSOMAPS_RADIUS` and `ALSOMAPS_HEADING` also work on their own, to start somewhere other than the Ferry Building.

## Tests

`Also Maps Core Tests` tests the navigation core on macOS, without a scene or network:

```
xcodebuild -scheme 'Also Maps Core Tests' -destination 'platform=macOS' test
```

## Offscreen Metal CLI

`Also Maps Render CLI` renders and compares culling on/off without a window,
RealityKit, or Computer Use. It can run a network-free synthetic regression or
load Google tiles with the configured key. It writes PNGs and a JSON timing
report. See [the CLI guide](docs/metal-render-cli.md) for build/run commands,
locked-screen validation, and measurement limits.

`also-maps-render video` also records stereo video along an A-to-B move or an
app camera CSV track. It exports Apple spatial MV-HEVC or side-by-side HEVC,
with adjustable stereo depth and fixed frame timing. See the
[stereo video guide](docs/stereo-video-cli.md).

## Controls

- **Pan:** look at the map, pinch and drag. Gestures are indirect only (look and pinch), so open hands over the map do nothing.
- **Zoom:** pinch with both hands and move them apart or together. The view's half-width ranges from 50 m to 10,000 km, about a hemisphere. Below 50 km the ground is placed by sampling terrain. Above 50 km it's placed by the Earth's curve, so sea level at the view's edges meets the base plane, with no sampling. At hemisphere scale, tiles on the far side of the Earth are skipped.
- **Turn:** pinch with both hands and twist about the vertical. The map turns around the focus point and can turn while zooming.
- **Hardware keyboard:** WASD or the arrow keys move relative to where you're facing, Q and E turn, R and F descend and climb (which is zoom), `=` and `-` zoom, and holding Shift goes three times faster. The ornament shows these hints while a keyboard is connected.
- **Game controller** (Xbox-style): the left stick moves. The right stick turns (left/right) and changes altitude (up climbs, which zooms out; down descends). Both sticks are analog with a dead zone. RT and LT also zoom in and out. Hold LB, or click the left stick, to go faster. D-pad left and right step through places, Y faces north, and X toggles Fly. The ornament shows these hints while a controller is connected. Keyboard and controller input combine, and the turn pivot in Settings applies to both.

On a Mac, the map also takes the usual mouse and trackpad controls:

- **Pan:** click and drag, and let go while moving to flick the map on. Two-finger scrolling on a trackpad or Magic Mouse pans too.
- **Zoom:** pinch, turn a mouse wheel, or hold Option and scroll, all about the pointer. Double-click zooms in, Option-double-click zooms out, and a two-finger double tap on a trackpad zooms in.
- **Turn and tilt:** right-drag, or hold Option or Control and drag: sideways turns, up and down tilts. A two-finger twist on a trackpad turns, and Shift-scroll tilts.

`ALSOMAPS_HEADING`, in degrees clockwise from north, sets the starting direction.

## Fly

The airplane button, or X on a controller, toggles **Fly**. Streaming freezes, so the loaded tiles stay as they are. Every control then does exactly what it does outside Fly: the same moves, turns and zoom, at the same rates and around the same pivot (the "Turn and zoom around" setting), applied to the frozen scene instead of the live map. The surface stays on the base plane. Turning Fly off resumes streaming from where you are, without anything visibly moving.

Detail doesn't improve as you zoom in, because nothing new loads while frozen. Changing view mode or going to a place leaves Fly.

## Places

The pin button next to the mode picker jumps to a saved place: its position, zoom and facing. The defaults are in `Sources/Places/Places.json` (San Francisco, Boston, New York, Chicago, Grand Canyon and Puente Nuevo in Ronda). Each entry has an `id`, `name`, `latitude`, `longitude`, `radius` (view half-width in metres) and an optional `heading` (degrees clockwise from north). `PlaceLibrary` is where user-added places, stored locally or in iCloud, would be merged in later. `ALSOMAPS_PLACE=<id>` starts at that place.

The remote config can replace these defaults; see below.

## Remote config

Every platform reads `https://maps.also.dev/config/v1.json`, a static file published from also-maps-site, on launch, on returning to the foreground and every 15 minutes while active (every minute while blocked). `Sources/Config/` holds the file's model and rules (`AppConfig`), its fetching and saved copy (`AppConfigStore`) and how the app applies it (`AppGate`).

```json
{
  "notices": [
    {
      "id": "update-required-1.2",
      "severity": "blocking",
      "title": "Update required",
      "body": "This version of Also Maps no longer works.",
      "link": { "title": "Update", "url": "https://apps.apple.com/app/id0000000000" },
      "platforms": ["visionos", "ios", "macos", "tvos"],
      "minVersion": "1.0",
      "maxVersion": "1.1.9",
      "keySource": "app",
      "expires": "2027-01-01T00:00:00Z"
    }
  ],
  "places": []
}
```

All the top-level keys are optional. A notice needs `id`, `severity`, `title` and `body`; everything else narrows who sees it. Versions compare against `CFBundleShortVersionString`, inclusive at both ends, so a fix that a notice shouldn't reach needs a new version number. `expires` takes ISO 8601 without fractional seconds.

- **`info`** shows as an alert, once. Give a new message a new `id`.
- **`blocking`** replaces the app, stopping streaming, until it no longer applies. With no version range it's the kill switch; with `maxVersion` it's a minimum version. Don't let one match a build in App Review, or the reviewer sees a blocked app.
- **`places`** has the format of `Places.json`, and replaces the bundled list when it has at least one usable entry.
- **`keySource`** on a notice limits it to people on the app's key (`"app"`) or their own (`"own"`). Having your own Google key counts as `"own"`, since that's the quota the notice protects. A blocking `"app"` notice offers **Use Your Own Key**, so it can stop the shared key without stopping everyone.
- **`"appKeys": false`** at the top level turns off the app's key. People on it see how to add their own.

The app fails open: launch never waits for the file, it starts from the last good copy (or the bundled places), and an outage or a bad file leaves that in place. Unusable notices and places are skipped, while older builds ignore unknown fields. Don't add a new way to narrow a notice's audience to a live notice: older builds would ignore it and show the notice more widely. Change the format incompatibly only at a new URL (`v2.json`). The file is public, so it must never hold secrets. The block is enforced by the app, so it doesn't reach older builds or protect the API keys; those need quotas on the services themselves.

`ALSOMAPS_CONFIG_URL=<url>` reads another file instead, without touching the saved copy, and accepts `file://` URLs.

## Keys

Release builds contain no keys, except on tvOS. Where there's no key yet, the first launch asks how to load the map: with the app's shared key, which may be throttled, or with your own. Change it later in Keys (in Settings on every platform but tvOS). `Sources/Credentials/` holds this.

- **The app's key** comes from the credentials API in also-maps-site, which needs App Attest, so `AppKeyClient` proves the app is genuine, saves what it gets in the Keychain and refreshes it daily. Where `isSupported` is false, the app offers only your own key: macOS 26, and simulators. The Mac needs macOS 27 or later, where the API also requires Apple's key policy (full security mode and System Integrity Protection). Refreshes run only while a window is active. Device builds need the App Attest capability on the App ID.
- **Your own key** is saved in the Keychain, and follows you between devices through iCloud Keychain. Saving one makes one request to check it, which for Google counts as a map session.
- **Which wins**: a scheme's `GOOGLE_MAPS_API_KEY` or `CESIUM_ION_TOKEN`, then your own, then the app's, then one built in from `Config/Secrets.xcconfig` (Debug builds, and tvOS). `ALSOMAPS_CREDENTIALS_URL=<url>` points at another deployment of the API.
- **Rotation**: streaming restarts whenever the key changes. When a service rejects the app's key, the app fetches a new one straight away, so an old key can be deleted at any time. See also-maps-site/docs/credentials-api.md.

## Views

The picker under the volume switches between the volume and **Immersive**. Immersive opens an immersive space and lays the map level on its origin plane, the floor where you stood when it opened, all around you, with the camera at your eye. The map's centre point, 5.6 m ahead, is where places are framed. Far up, the map tilts about your eye into a globe in front of you. The space is mixed (passthrough) unless **Full immersion** is on in Settings. The volume stays open as the control panel, and an attribution panel sits at the map's near edge. If a system environment (Mount Hood, the Moon and so on) is active, mixed Immersive keeps it, with the map on its ground. If you close the volume while in Immersive, that panel shows **Show Controls** to bring it back. Opening the app from the Home View always reopens the volume.

`ALSOMAPS_PRESENTATION=immersive` (or `volume`) starts in that mode. Saved view states from the earlier 3×, 5× and 10× modes restore into Immersive.

Immersive doesn't clip the map's edges the way the volume does, so whole tiles stick out past the region (#5).

## Settings

Settings is a window on visionOS and a sheet on iPhone and iPad, each opened with the gear button (on visionOS, next to the mode picker). On the Mac it's the standard Settings window (⌘,). Categories are in a sidebar. Changes apply immediately and are remembered between launches. visionOS has every category; the others have General, Keys and Advanced.

**General**
- **Tiles** picks the source: Google Photorealistic, or Cesium OSM Buildings or Cesium World Terrain via Cesium ion. The ion sources are untextured, so they're drawn lit. Buildings use their own normals, or flat normals computed per triangle. Terrain uses smooth normals generated by cesium-native, in a flat earth tone until imagery overlays arrive (#8). Switching restarts streaming at the same view. Credits that carry a logo, such as Cesium ion's, show it in the attribution panel.
- **Show stats** adds tiles drawn, entities, load progress and request counts to the panel over the map: the ornament on visionOS, the top-left overlay on iPhone and the Mac (which adds fps and the camera's position). Keyboard and controller hints show there whether or not stats are on.
- **Turn and zoom around** (visionOS): the map's centre, or **where you are**: the ground beneath the viewer stays fixed, so zooming is moving straight up or down and turning is turning on the spot. The viewer is where you stood when the immersive mode opened, or, for the volume, just in front of it. This applies to every input: sticks, triggers, keys, pinch and twist. The pivot is full strength up to a 50 km half-width and fades to the map's centre by 500 km, where there's no meaningful "beneath you" on the curved map. Over the same range the map tilts to face you, like a globe in Google Earth VR. Its centre rises toward eye level and turns so your line of sight meets it head-on, and level-of-detail selection looks down to match. Fully tilted, the bigger immersive modes extend below the floor, so Immersive 3× works best for this.

**Immersion** (visionOS): **Full immersion**, **Human scale (test)**, and
- **Limit reach** (Immersive only): by default Immersive streams everything you could see, all around you out to the horizon (plus ~200 km for mountains beyond it), measured from where your eye is in the world, so a tilted globe shows its whole visible face. Turn this on to stream only **Reach** around you instead: 5× to 100× your height above the ground (the same multiple of your eye height above the floor).

**Detail** (visionOS): cesium-native's screen-space error thresholds, for tiles inside and outside the LOD camera's view. Most of an expanded region is outside that view, so Outer detail controls how sharp the far map is and how many tiles it costs. On iPhone and the Mac, detail is set from the window's pixels instead.

**Keys**: see [Keys](#keys).

**Advanced**
- **Parallel uploads, Simultaneous loads, Cache, Forbid holes**: trade-offs between fill speed, memory and gaps while refining. Forbid holes is on by default: a tile counts as loaded only once it's drawable, so parents stay until all their children can replace them.
- **Reset to Defaults** returns everything but Show stats and keys to the hand-tuned baseline in `StreamingSettings.default`.

`ALSOMAPS_OPEN_SETTINGS=1` opens the window at launch on visionOS.

**Debugging** (Advanced, visionOS):
- **Show pivot and centre markers** draws a red post where turns and zooms pivot, and a blue post at the map's centre.
- **Copy View State** copies the whole view as JSON (position, zoom, heading, presentation, Fly pose and settings) and prints it to the console.
- **Restore from Clipboard** brings a copied state back.

At launch, `ALSOMAPS_STATE=<that JSON>` restores a state and `ALSOMAPS_MARKERS=1` shows the markers.

## Running and inspecting the Mac app (for tools and agents)

The macOS target's **Debug** build is unsandboxed (`SourcesMac/AlsoMapsMac.Debug.entitlements`: network client only), so you can launch the binary directly, pass `ALSOMAPS_*` variables, capture its stdout, and read its on-disk state. **Release** keeps the sandbox (`SourcesMac/AlsoMapsMac.entitlements`). The sandboxed build keeps its files in `~/Library/Containers/dev.also.maps/`, which the shell can't list ("Operation not permitted").

```
xcodebuild -scheme "Also Maps macOS" -configuration Debug -destination 'platform=macOS' -derivedDataPath build build
ALSOMAPS_LAT=37.7955 ALSOMAPS_LON=-122.3937 ALSOMAPS_RADIUS=800 \
  "build/Build/Products/Debug/Also Maps.app/Contents/MacOS/Also Maps" > run.log 2>&1 &
```

It needs a logged-in macOS session, since it opens a window. Kill it by PID when done. The API key comes from `Config/Secrets.xcconfig` via Info.plist, or from `GOOGLE_MAPS_API_KEY` in the environment.

Where things land when unsandboxed:
- **HTTP cache**: `~/Library/Caches/dev.also.maps/tiles/`. Delete it for a cold run. See [docs/tile-caching.md](docs/tile-caching.md).
- **Defaults**: `~/Library/Preferences/dev.also.maps.plist`.

Timing the tile pipeline with signposts and `xctrace` is in [docs/profiling.md](docs/profiling.md). Tile caching, the request counters in the Tuning stats, and how to measure them are in [docs/tile-caching.md](docs/tile-caching.md).

## Known gaps

The experimental Metal renderer's render-only culling, submission counters,
and A/B profiling switches are described in [Metal rendering performance](docs/metal-renderer-performance.md).

- The main thread still spends 2–3 ms per frame on tile selection and on re-placing every tile, even when the view isn't moving (#2).
- Below 50 km, ground height is the lowest hit on a 3×3 grid of samples. In a region that's mostly hills with a little low ground, the hills can reach close to the top of the volume.

## tvOS static-map prototype

The `Also Maps tvOS` target (tvOS 26+) displays a full-screen,
static scene selected from the bundled places. The location button in the
upper-right opens a remote-focusable Places list; selecting an entry replaces
the scene and streams that location using its saved radius and heading. The
camera looks down at 45 degrees, with distance proportional to the radius,
and samples ground height to frame elevated locations.

It shares `Sources/Static/StaticMapView.swift` and the existing tile streaming
pipeline. Set `ALSOMAPS_PLACE=<id>` to select the starting place, or
`ALSOMAPS_VIEW=bay` to try the wider Mac view. Detail and concurrency
overrides apply to both; saved places use their own radius, while
`ALSOMAPS_RADIUS` overrides the area for an explicit camera preset.
The LOD camera tracks the actual view aspect ratio.

The project uses the released `CesiumNative` package version `0.64.0-2`,
which contains arm64 macOS and device/simulator slices for iOS, visionOS and
tvOS. No sibling framework checkout is required.

Keep `Config/Secrets.xcconfig` configured as above, then run `xcodegen generate`
and select the `Also Maps tvOS` scheme and an Apple TV simulator or device in Xcode.
This prototype has no free camera navigation or TV app icon/top-shelf artwork yet.

Verified with Debug builds for macOS and the Apple TV 4K (3rd generation)
simulator on tvOS 27.0. The saved San Francisco scene rendered 160 tiles at
100% load and 60 fps. These are simulator observations, not measurements on
Apple TV hardware. Remote-driven picker selection still needs manual verification.

## iPhone static-map prototype

The `Also Maps iOS` target (iOS 26+, iPhone) uses the shared static-map scene
and the released CesiumNative package. Open Places in the navigation bar to
choose any bundled location; each uses its saved radius and heading, with
sampled ground height. Portrait and landscape use the actual scene aspect
ratio. Credits wrap within the safe area, and the phone hides diagnostic stats.

Run `xcodegen generate`, select `Also Maps iOS`, and run on an iPhone or iOS
simulator. API keys and `ALSOMAPS_PLACE` / `ALSOMAPS_VIEW` overrides work as
above. This prototype has no free camera navigation or app icon yet.

Verified: Debug build and launch on the iPhone 18 Pro simulator (iOS 27.0),
with textured San Francisco tiles, the Places control and wrapped attribution
visible in portrait. Touch-driven place selection, rotation and physical-device
performance still need manual verification.
