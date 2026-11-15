# Checking the visionOS app in the simulator (for agents)

Agents can build, install, launch and screenshot the app in the Apple Vision Pro simulator, but no tool tried so far can tap, click or gesture in it (#56). Don't retry the approaches under "What doesn't work". Set up what you need at launch, check it with screenshots, and ask the person to try anything that needs interaction.

## Build, launch, look

```
xcodebuild -scheme "Also Maps visionOS" -destination 'generic/platform=visionOS Simulator' -derivedDataPath build ARCHS=arm64 build
xcrun simctl install booted "build/Build/Products/Debug-xrsimulator/Also Maps.app"
SIMCTL_CHILD_ALSOMAPS_PRESENTATION=immersive xcrun simctl launch booted dev.also.maps
```

- **`ARCHS=arm64`** is needed because the generic destination also builds x86_64, which fails to link: the cesium-native package has only arm64 simulator slices.
- **Launch state:** `simctl launch` passes each `SIMCTL_CHILD_`-prefixed variable to the app without the prefix. Use the [launch variables](launch-variables.md) to reach the state you want to check.
- **Preferences:** `xcrun simctl spawn booted defaults write dev.also.maps <key> <value>` before launch, with a key from `ViewPreferences` in `Sources/StreamingSettings.swift`.
- **Screenshots:** the iOS Simulator tool's `screenshot` action captures the device.
- **Logs:** `xcrun simctl spawn booted log show --last 5m --predicate '…'`.

If something can only be reached by interacting, say so and ask the person to check it, rather than reporting it as verified.

## What doesn't work

Observed on Xcode 27.2 with the visionOS 27.0 simulator runtime, November 2026.

- **The iOS Simulator tool's `tap`, `swipe`, `touch_path` and `button`** fail with `dtuhidServiceNotVended(name: "com.apple.coredevice.feature.remote.hid.digitizer")`. Restarting the simulator and re-attaching don't help. The simulator's input daemon (`dtuhidd`) provides keyboard, pointer, Digital Crown and button input but no touch input, which those actions use.
- **Claude's computer use** can't reach the simulator window. There's no Simulator.app in Xcode 27: the window belongs to Device Hub (`com.apple.dt.Devices`, in `Xcode.app/Contents/Applications`). The background tools list no windows for it, even by a window ID the window server reports as on screen. Under full-screen control, screenshots work but every click in the window fails with "Could not verify which document this window is editing".
- **Codex's computer use** finds and captures the window by Device Hub's bundle ID, but runs into problems interacting with the app's controls.

If a new Xcode, simulator runtime or tool changes any of this, update this page and #56.
