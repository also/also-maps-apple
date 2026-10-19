# MapVolume

A visionOS app that streams Google's Photorealistic 3D Tiles into a volumetric window, using [cesium-native](https://github.com/CesiumGS/cesium-native) for tile selection and loading and RealityKit for rendering.

## How it fits together

- `Sources/Cesium/CNTileStreamer.{h,mm}`: an Objective-C++ bridge that owns a cesium-native `Tileset`. It provides:
  - networking over `NSURLSession` (cesium-native is built without curl)
  - a GCD task processor
  - an `IPrepareRendererResources` that flattens each tile's glTF into float positions, UVs, indices and RGBA in a fixed local east-north-up frame
  - an excluder that limits streaming to the square region shown in the volume
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

   Run on the Apple Vision Pro simulator or a device.

To test without a key, tick the `MAPVOLUME_*` variables in the scheme. They stream a public Cesium sample tileset instead.

## Controls

- **Pan:** drag in the volume.
- **Zoom:** pinch. The radius ranges from 50 m to 20 km.

## Known gaps

- Mesh and texture creation run on the main thread under a time budget per frame, which causes hitches while streaming.
- Ground height comes from a single sample at the focus point, which can land on a rooftop.
- The attribution uses a text "Google" label where Google's logo asset should be.
