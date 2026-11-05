# The visionOS simulator, for agents

Agents can build, install, launch and screenshot the app in the Apple Vision Pro simulator. **They can't interact with it**: no tool tried so far gets a tap, click or gesture to the app's controls. Don't spend time retrying. Set up the state you need at launch, check it with screenshots, and ask the person to try the interactions by hand.

## What works

- **Building:** `xcodebuild -scheme 'Also Maps visionOS' -destination 'generic/platform=visionOS Simulator' -derivedDataPath build ARCHS=arm64 build`. Without `ARCHS=arm64`, the generic destination also builds x86_64 and fails to link, because `CesiumNative.a` has only arm64 simulator slices.
- **Installing and launching:** `xcrun simctl install <udid> "build/Build/Products/Debug-xrsimulator/Also Maps.app"`, then `xcrun simctl launch <udid> dev.also.maps`. Prefix the launch with `SIMCTL_CHILD_<NAME>=<value>` to set the app's environment, for example `SIMCTL_CHILD_ALSOMAPS_DEBUG_PANEL=1`.
- **Settings:** `xcrun simctl spawn <udid> defaults write dev.also.maps <key> <value>` sets a stored preference before launch, for example `ShowsDebugControls -bool YES`.
- **Screenshots:** the iOS Simulator tool's `screenshot` action captures the device.
- **Logs:** `xcrun simctl spawn <udid> log show --last 5m --predicate '…'`.

### Launch variables that set state

Everything you'd otherwise tap is set with a launch variable instead. These are read in `VolumeView`'s `.task` and elsewhere; grep `ALSOMAPS_` for the full list.

| Variable | Effect |
|---|---|
| `ALSOMAPS_PRESENTATION=immersive` (or `volume`) | Starts in that mode |
| `ALSOMAPS_STATE=<JSON>` | Restores a view state from Copy View State |
| `ALSOMAPS_LAT`, `ALSOMAPS_LON`, `ALSOMAPS_RADIUS`, `ALSOMAPS_HEADING` | Starting position |
| `ALSOMAPS_OPEN_SETTINGS=1` | Opens the Settings window |
| `ALSOMAPS_DEBUG_PANEL=1` | Opens the debug panel |
| `ALSOMAPS_MARKERS=1`, `ALSOMAPS_TILE_BOUNDS=1` | Debug overlays |
| `ALSOMAPS_SHOW_TRACK=1`, `ALSOMAPS_PLAY_TRACK=1` | Draws or plays the latest track |
| `ALSOMAPS_FULL_IMMERSION=1`, `ALSOMAPS_HUMAN_SCALE=1` | Immersion options |
| `ALSOMAPS_METAL=1` | Draws with the Metal renderer |

When a change adds something that can only be reached by interaction, add a launch variable for it too, so it can be checked by screenshot.

## What doesn't work

Observed on Xcode 27.2 with the visionOS 27.0 simulator runtime, November 2026.

- **The iOS Simulator tool's `tap`, `swipe`, `touch_path` and `button` actions** fail with `dtuhidServiceNotVended(name: "com.apple.coredevice.feature.remote.hid.digitizer")`. Restarting the simulator and re-attaching doesn't help. The simulator's input daemon (`dtuhidd`) creates keyboard, pointer, Digital Crown (`dial`), button and `avpCustom` services but no digitizer, and those actions need one. Every agent session that has tried this hit the same error.
- **Simulator.app doesn't exist in Xcode 27.** The simulator window belongs to **Device Hub** (`/Applications/Xcode.app/Contents/Applications/DeviceHub.app`, bundle ID `com.apple.dt.Devices`).
- **Claude's computer use:** with Device Hub granted, the background tools list no windows for it, and refuse a `window_id` that the window server reports as on screen. With full-screen control, screenshots work but every click in the window fails with "Could not verify which document this window is editing".
- **Codex's computer use** got the window by its bundle ID, with a screenshot and Device Hub's accessibility tree (the app's own controls aren't in that tree), but also ran into problems interacting with the app's controls.

Tracked in also/also-maps-apple#56. If a new Xcode, simulator runtime or tool changes any of this, update this page and the issue.
