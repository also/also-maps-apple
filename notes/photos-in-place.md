# Photos in place: working notes

Spike notes for putting the user's own photos back where they were taken (Settings › General › Photos in place, or `ALSOMAPS_PHOTOS=1`). Branch `spike/photos-in-place`. **Observed** means seen running on a device, a simulator or in tests. **Inferred** means reasoned from documentation, memory of the APIs or the code, and not yet confirmed. Nothing here has been built or run yet, so every finding is Inferred. The log at the end is newest first.

## Goals

- **Photos where they were taken.** Each geotagged photo appears in the 3D world at its capture position, facing the way the camera faced.
- **Stand in a photo ("rephotography").** Going to a photo puts the eye where the photographer stood. The photo is framed at its true field of view over the 3D scene, so photo and world line up, with a slider to fade between them.
- **Line it up by hand.** EXIF has no pitch or roll, and compass headings are rough, so the user can nudge heading and pitch.
- **Private.** Photos never leave the device. Nothing is uploaded or saved; picked photos last for the session.
- **Off by default.** With the setting off, nothing about the app changes.
- **Platforms.** visionOS first, then the Mac, sharing the code. tvOS is left out. iOS compiles the shared code (ScreenMap uses it) but has no photo controls.

## Design

### Where the code is

| File | What | Platform-neutral? |
|---|---|---|
| `Sources/Photos/PhotoMetadata.swift` | Reads location, altitude, direction, lens, pixel size and orientation from an ImageIO properties dictionary, by key strings | Foundation only, tested |
| `Sources/Photos/PhotoGeometry.swift` | Displayed shape, field of view (35 mm equivalent, else sensor size, else assumed), heading and the magnetic flag | Foundation only, tested |
| `Sources/Photos/PhotoPose.swift` | Eye height rule, the camera pose, frame and screen sizes, the Mac's widened field of view, marker orientation | Navigation types and simd, tested |
| `Sources/Photos/PhotoImporter.swift` | PhotosPicker items → data → ImageIO; the PhotoKit fallback; Photos Near Here | ImageIO, PhotosUI, Photos |
| `Sources/Photos/PhotoSession.swift` | The session's photos in memory, ground samples, the active photo, opacity, nudges; `PhotoSessionHost` | SwiftUI/Observation |
| `Sources/Photos/PhotoOverlay.swift` | RealityKit markers (thumbnail on a post) and the immersive frame | RealityKit |
| `Sources/Photos/PhotoControls.swift` | Add Photos (picker), Photos menu, the fade and nudge panel | SwiftUI |
| `Tests/Photos/PhotoPoseTests.swift` | Tests for the first three files, in `Also Maps Core Tests` | |

`MapModel` (visionOS) and `ScreenMap` (Mac and iOS) each own a `PhotoSession` and implement `PhotoSessionHost` (stand in, leave, adjusted, search centre) over their own camera.

### Choosing photos

- **System picker first.** `PhotosPicker(…, preferredItemEncoding: .current, photoLibrary: .shared())` needs no library permission. `.current` asks for the original encoding (HEIC usually), which should carry the EXIF, rather than a transcoded JPEG. `photoLibrary: .shared()` gives each item an `itemIdentifier` (the asset's local identifier) without permission.
- **Whether the picker's data keeps the GPS block is unverified** (Inferred). My understanding is that the original-encoding data includes it unless the user turns location off when sharing. That isn't confirmed for visionOS 26 or macOS 26, so both paths are implemented:
  1. Read EXIF GPS from the picked data (`locationSource = .exif`).
  2. If there's none and the item has an identifier, ask for library access (`PHPhotoLibrary.requestAuthorization(for: .readWrite)`, using `NSPhotoLibraryUsageDescription`) and read `PHAsset.location` (`locationSource = .photoLibrary`). That gives latitude, longitude and altitude but no camera direction: `CLLocation.course` is the direction of travel, so it isn't used.
  The debug log line `picked photo: location in EXIF|missing, direction …, 35 mm …` shows which path ran.
- **What the fallback costs.** It needs the usage description (added to the visionOS, Mac and iOS Info.plists, via project.yml). The sandboxed Mac Release build also needs `com.apple.security.personal-information.photos-library`, now in `SourcesMac/AlsoMapsMac.entitlements`. The first photo without a location prompts for access. Limited access only resolves assets the user shared with the app.
- **Photos Near Here (stretch goal)**, in the Photos menu: asks for library access, walks every image asset's `location` (PhotoKit can't filter by location in the fetch), keeps those within 2 km of the camera (visionOS volume: the map's centre), nearest first, up to 40, and reads each original through `PHImageManager.requestImageDataAndOrientation`, so direction and lens come from EXIF. Network access is allowed so iCloud-only originals download. That's a download of the user's own photo; nothing is uploaded.

### From metadata to a pose

- **Location:** GPS latitude and longitude with their N/S and E/W refs.
- **Heading:** `GPSImgDirection` in degrees. `T` (true) is used directly. `M` (magnetic) is used as if true and flagged in the panel ("magnetic heading, uncorrected"). There's no magnetic model in the app, declination is under 15° in most populated places, and nudging fixes it. With no direction the photo faces north, also flagged. A missing reference is read as true (iPhones write `T`).
- **Field of view**, as displayed (upright):
  1. From `FocalLenIn35mmFilm`, by the diagonal: the image's diagonal sees what a 36 × 24 mm frame's would. This is CIPA DC-004's definition (Inferred that Apple's cameras follow it). A 4:3 iPhone photo at 26 mm comes out at about 67.3° × 53.1°.
  2. Else from `FocalLength` and the sensor size implied by `FocalPlaneXResolution` (and Y) and its unit. Sizes outside 1–80 mm are ignored as bogus.
  3. Else assumed: 26 mm equivalent, flagged ("lens unknown").
- **Orientation:** EXIF 5–8 turn the stored pixels a quarter turn, so width and height swap, and with them the horizontal and vertical angles. ImageIO's thumbnail options apply the orientation, so the stored image is upright.
- **Pitch and roll:** level, plus the user's pitch nudge (clamped to ±0.5 rad). No roll.
- **Eye height:** the ground beneath the photo + 1.6 m. The ground is sampled from the tiles at runtime (lowest of a 3 × 3 grid within 2.4 m, `PhotoPose.groundSampleRadius` = 3) and kept only in memory, per Google's terms. The recorded GPS altitude is used instead only if it's more than 120 m above that ground. GPS altitude is above sea level, not the ellipsoid, so the geoid alone can put it ~100 m off. Only a photo clearly taken from high up (a tower, a drone, a plane) clears that. Before the ground sample arrives, the recorded altitude stands in. With neither, the camera stands on the ellipsoid until the sample arrives and lifts it.

### On the map

- **Markers:** each photo is a thumbnail on a white post, at its ground (or its recorded altitude until the ground arrives), turned to its heading. The thumbnail faces back toward the photographer, so standing behind it and looking the same way reads it as the viewfinder did. A dark back shows from the other side. All unlit.
- **Size:** like the other overlays.
  - **visionOS:** a constant size in the room, 5 cm wide in the volume and 50 cm in the immersive space (×magnification, like the debug markers).
  - **Mac:** in proportion to distance, 0.05 × distance (about 3°).
- **While standing in a photo,** its own marker is hidden.

### Going to a photo

- **visionOS:**
  - The Photos menu opens Immersive first if needed.
  - Then `standInPhoto` makes a camera jump to the photo's pose: the eye at the photo's position and eye height, heading the photo's, level unless nudged. It releases held tiles, stops playback, ends any gesture, resets the ground estimates to the photo's ground and marks a jump, so the track starts a new segment.
  - While standing in a photo, the eye-level model uses a fixed scale of 1 (human scale), as the Human scale test toggle does, and the minimum altitude is 1 m. The camera is the eye (docs/navigation-handoff.md), so this is literally standing where the photographer stood.
  - The frame is 1.5 m straight ahead of the eye along the camera's forward (pitch included), facing the eye, sized to subtend the photo's field of view exactly (`PhotoPose.frameSize`). Its opacity comes from the slider, through an `OpacityComponent`. 1.5 m keeps the bottom of a portrait photo in front of the ground (the bottom ray meets the ground about 2.4 m ahead for a 1.6 m eye). The controls attachment hangs under the frame.
  - **Nudges:**
    - **Heading** turns the camera, so the world turns about you and the frame stays straight ahead (room −z).
    - **Pitch** raises the frame, because the eye-level placement ignores pitch.
    - Either way, the angle between photo and world changes as it should.
  - In the volume (if Immersive couldn't open), going to a photo frames its spot like a place (150 m, facing its heading) without a frame.
- **Mac:**
  - The camera jumps to the pose.
  - The window camera's vertical field of view widens so the whole photo fits with a 10% margin (`PhotoPose.windowFieldOfView`, never narrower than the usual 45°). The LOD camera and the Metal renderer's projection use it too.
  - `ScreenMapView` draws the photo over the view, centred, at `PhotoPose.screenSize`. The fade and nudge panel sits above the attribution. Nudges turn the camera, and the photo stays centred.
- **Leaving:**
  - **What leaves:** Leave in the panel, or any flying input, grab or pointer gesture, going to a place, track playback, restoring a view state or switching host. The frame only lines up from the photo's pose, so moving at all leaves it.
  - **What happens:** the camera rises to the host's usual minimum height above the ground (55 m in the volume and Immersive, 2 m on the Mac). That's a jump, marked as one in the track.

### Privacy and terms

- **Photos stay in memory** (`PlacedPhoto`: a 2048 px image and a 256 px thumbnail) and go when the app quits. Nothing is uploaded, written to disk or put in view states.
- **Persisting later** would mean storing `PhotosPickerItem.itemIdentifier`s and resolving them through PhotoKit at launch. That needs library access every time, and the picker-only path loses its no-permission advantage. Ground heights would still be resampled each session, never stored.
- **Google's terms:**
  - Ground heights are tile-derived, so they're kept only in memory.
  - The photos are the user's own content drawn over Google's tiles, not another provider's map content.
  - The attribution panels are unchanged and stay visible. The Mac's photo panel sits above the attribution bar.
- **Track files:** these already record the camera, whose height follows the ground. Standing in a photo writes nothing new to them beyond that.

## Unverified (marked `UNVERIFIED:` in the code where it's an API)

- **Whether `PhotosPickerItem.loadTransferable(type: Data.self)`, with `.current` encoding, keeps the GPS EXIF** on visionOS 26 and macOS 26. This is the main question; see the test plan.
- **The async `TextureResource(image:withName:options:)` initialiser** (PhotoOverlay), and `.init(semantic: .color)`.
- **What `sampleHeightMostDetailed` does far from the streamed area.** I don't know whether it respects the area-of-interest excluder there (Inferred risk). If it does, photos far from the current view get no ground until you're near them. They're retried every 2 s (after a failure, every 10 s), and standing in one samples again once you're there.
- **SwiftUI and RealityKit details I'm fairly but not fully sure of:**
  - `PhotosPicker`'s `photoLibrary:` initialiser on visionOS.
  - `PHImageManager.requestImageDataAndOrientation` on visionOS.
  - Reparenting an attachment entity under a scene entity (`attachControls`).
  - `OpacityComponent` on an unlit textured plane.
  - `PerspectiveCameraComponent.fieldOfViewInDegrees` being vertical. The code already assumes it, and Metal's projection treats `fieldOfView` that way.
- **Whether the 35 mm equivalent is by the diagonal for Apple's and others' cameras.** Some makers compute it by width, which would make the frame slightly wrong for non-3:2 photos.
- **Swift strictness:** Sendable and isolation diagnostics in the closures (`sampleGround`, the picker's `Task`s). Written for Swift 5 language mode as the targets use.
- **No toolchain here.** `swift` isn't installed in this container, and download.swift.org is blocked by the network policy. So nothing was type-checked or run, not even the Foundation-only files, and the tests are unrun.

## Test plan

### Before anything

1. `xcodegen generate` (a new folder, `Sources/Photos`, and `Tests/Photos`).
2. Build `Also Maps visionOS`, `Also Maps macOS`, `Also Maps iOS` and `Also Maps tvOS`. tvOS doesn't include Photos and should be unaffected.
3. Run the `Also Maps Core Tests` scheme. `PhotoMetadataTests`, `PhotoGeometryTests` and `PhotoPoseTests` should pass. If any fails, the maths is wrong before anything visual is.

### Test photos

Take two or three photos on an iPhone with Location Services on for the Camera, in a place with good 3D coverage (a street with distinctive buildings, a landmark from a known spot):

- one landscape and one portrait;
- ideally one photo of something 50–200 m away, which shows heading error best.

Let them sync to iCloud Photos so they're on the Mac and Vision Pro. A screenshot or a downloaded image makes a good "no location" case.

### Mac (quickest)

1. Run the Debug build with `ALSOMAPS_PHOTOS=1` (or turn on Settings › General › Photos in place) and keep stdout:
   `ALSOMAPS_PHOTOS=1 "build/Build/Products/Debug/Also Maps.app/Contents/MacOS/Also Maps" > run.log 2>&1 &`
2. **Off by default:** without the variable and the setting, there should be no Photos buttons, no markers, and nothing different.
3. Click **Add Photos** (top right, next to Places) and pick the test photos.
   - Look for `[AlsoMaps] picked photo: location in EXIF, direction …` in the log. **This answers the main question.**
   - If it says `missing`, a library-access prompt should appear. Allow it, and the photo should still be placed (`location from your library` in the panel later).
   - The screenshot should be skipped with "Skipped 1 without a location" in the Photos menu.
4. Fly to the area (Places, or `ALSOMAPS_LAT/LON/RADIUS`).
   - Each photo should appear as a thumbnail on a post at its spot, facing back toward where it was taken from, a few pixels tall at any distance.
   - The log should print `photo …: ground N m, eye M m from ground`.
5. Choose the photo in the **Photos** menu.
   - The view should jump to street level, looking the photo's way.
   - The window's view widens a little.
   - The photo should sit centred at 70% opacity, with the panel above the attribution.
   - Drag the slider. At 1, only the photo; at 0, only the world.
   - With the slider at about 0.5, the buildings' edges should roughly line up.
6. **Nudge:**
   - Aim Left/Right turns the view under the photo half a degree per press, and Aim Up/Down tilts it.
   - Line up a building edge and note the adjustment in the panel. A few degrees of heading is expected (compass error); much more suggests a sign or reference error.
7. **Portrait photo:**
   - It should be taller than wide.
   - The window should widen more, and the whole photo should be visible.
8. Press an arrow key or drag the map. The photo should go and the camera rise to 2 m above the ground. Leave Photo should do the same.
9. Turn on Draw with Metal and repeat step 5. The photo overlay should still line up (markers aren't drawn with Metal).
10. Quit and relaunch. The photos should be gone.

### Vision Pro

1. Run `Also Maps visionOS` with `ALSOMAPS_PHOTOS=1` ticked in the scheme (add it next to the other `ALSOMAPS_*` variables), or turn on the setting.
2. In the volume, use **Add Photos** (photo-plus icon in the bottom toolbar) and pick the photos. Check the same log line as on the Mac for whether the GPS came through on visionOS.
3. Go to the area. Markers should show as small thumbnails on posts in the volume.
4. Choose a photo in the **Photos** menu.
   - Immersive should open (RealityKit, with Draw with Metal off).
   - You should be at street level, at human scale.
   - The photo should be framed about 1.5 m ahead, with its panel below it.
   - Look around: the world is all around you, and the frame stays where it is in the room, straight ahead of where you were facing when it opened.
   - Close one eye and compare the frame's edges with the scene. At 0.5 opacity, features should line up after nudging.
5. **Nudges:**
   - Heading turns the world about you.
   - Pitch moves the frame up and down.
   - Reset puts both back.
6. Pinch the map or use a controller stick. The frame should go, and the camera should rise to 55 m.
7. Choose another photo from the volume's menu while already in Immersive. It should jump straight there.
8. Switch the picker back to Volume. The photo should be left, with markers still visible in the volume.
9. With Full immersion on and off, the frame should read the same.
10. **Photos Near Here:** in the volume, frame a place where you've taken photos, then choose Photos Near Here. Expect a library-access prompt the first time, then markers for photos within 2 km.

### What to watch for

- **Heading error:** compass headings from phones are often 5–15° out, worse near metal or in cars. Expect to nudge.
- **Eye height:** the eye should be at standing height. If you're inside a building, or high above the street, the ground sample probably hit a roof (the 3 × 3 grid's lowest point is within 2.4 m), or the 120 m rule picked the recorded altitude.
- **Position:** the photo's GPS can be 5–20 m off in cities, so the parallax won't match exactly. Nudging can't fix that. A position nudge may be needed (open question).
- **Load:** the area's tiles stream as usual, starting from the jump. The ground sample may take a moment, and the camera is lifted once it arrives.

## Open questions for the owner

1. **Leaving on any movement.** Should standing in a photo end on any movement, as built, or should you be able to look around with the photo held in place (in the world, not the head) and fly away from it? The latter is nicer for comparing from a step back, but the frame then needs a world-locked placement.
2. **The jump to 55 m on leaving.** Would you rather stay at human scale until you climb, as the Human scale toggle does?
3. **A position nudge** (forward/back, left/right a few metres) for GPS error, alongside heading and pitch?
4. **Persistence.** Keep the session-only model, or store asset identifiers and require library access?
5. **Magnetic headings.** Add a declination model (WMM coefficients are small and public), or keep flagging them?
6. **The volume.** Opening Immersive to stand in a photo, as built, versus framing the spot in the volume like a place. Is that the right default?
7. **Metal.** Should the Metal immersive renderer draw the frame and markers? Today it shows neither, and has no controls attachment, so you can only leave by moving.
8. **iOS.** The shared ScreenMap code already does the work; the controls could be added to PhoneMapView cheaply.

## Log (newest first)

### 2026-11-05: spike written, not built

- **Inferred:** the whole feature, as above. No Xcode, no Swift toolchain (download.swift.org blocked), no device.
- **Inferred:** the frame lines up regardless of map scale. Angles from the eye don't depend on a uniform scale about the eye. Human scale is used anyway, so stereo depth and parallax as you move your head also match the photographer's.
- **Inferred:** 1.5 m keeps the frame clear of the ground. The eye is 1.6 m up, and a portrait photo's bottom edge is about 33.5° down, which meets the ground about 2.4 m ahead.
