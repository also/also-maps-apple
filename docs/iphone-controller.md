# iPhone controller

The iPhone or iPad app can fly the map on Vision Pro or a Mac, as a joystick. It's one client of remote control: the protocol, pairing and liveness are in [remote-control.md](remote-control.md), and the CLI and MCP server use the same connection. Network.framework, Bonjour and TLS over TCP. `includePeerToPeer` enables Apple peer-to-peer Wi-Fi, so a shared router is optional. There's no cloud service or Bluetooth.

## Use

1. Run `xcodegen generate` and build and install `Also Maps` on Vision Pro (or run it on the Mac) and on iPhone. Signing and API keys are as for the main app, in `Config/Secrets.xcconfig`. A fresh worktree needs its own.
2. On Vision Pro, open **Remote Control** (the iPhone-and-waves button in the volume's toolbar). On the Mac, it's the antenna button beside Places. Turn on **Allow Remote Control**, and allow local network access if asked.
3. On iPhone, tap the game-controller button in the map toolbar. Pick the device, enter the 6-digit code it shows, and connect. A code that worked is remembered for that device.
4. The left stick moves. The right stick turns and climbs. The centre slider zooms. The buttons step through places, face north, toggle Fly (Vision Pro), or move faster. Portrait and landscape both work.

The code stays the same, across launches too, until **New Code** is pressed, which disconnects everyone. Up to four clients can connect at once, for example the phone and an agent. Their sticks are added together, as are a keyboard's and a game controller's.

## Input

The phone sends a full stick snapshot about 60 times a second while a stick is off centre, and one more when the sticks return to centre. Only one snapshot waits for an acknowledgement at a time, so a slow network doesn't build a backlog. A late acknowledgement only delays the next snapshot. Button presses are separate messages, so two quick taps are two presses. The host takes them once per frame through the map's `perform`.

The host zeroes a phone's sticks 250 ms after its last snapshot, but keeps the connection. Only about 6 s with nothing received (each end pings once a second), a network or TLS error, or a malformed frame ends a connection. After a connection that had worked drops, the phone retries with backoff until you press Disconnect or Done.

**Lifecycle.** Going to the background disconnects the phone, since connections don't survive it. On Vision Pro, going to the background pauses hosting, and coming back resumes it with the same code. Becoming inactive (Control Center, a notification) leaves the connection up. The phone lets go of its sticks when it becomes inactive.

## Changes from the first version (PR 20)

The first version disconnected when no snapshot came for 1 s, or no acknowledgement for 500 ms, and the headset stopped hosting whenever the app wasn't active. Physical-device testing saw random disconnects with that version. Their cause wasn't diagnosed. Strict deadlines and scene-phase changes were the leads. Version 2 changes both. Whether that fixes the disconnects is untested: see `notes/remote-control.md`.

## Validation

```sh
xcodebuild -scheme AlsoMapsRemoteTests -destination 'platform=macOS' test
```

The suite covers framing and validation, pairing over loopback TLS, wrong codes, an idle connection outliving several silence limits, stale input zeroing without a disconnect, a silent peer being dropped, two controllers at once, requests answered in order, events going only to clients that asked, and reconnecting over Bonjour after the host restarts. It opens local network listeners, so allow local network access if asked.
