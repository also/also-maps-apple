# iPhone controller

The iPhone/iPad app can control the visionOS map using Network.framework,
Bonjour discovery, and TLS over TCP. Both apps must stay active with Wi-Fi
enabled. `includePeerToPeer` enables Apple peer-to-peer Wi-Fi, so a shared
router is optional. There is no cloud service or Bluetooth transport.

## Use

1. Run `xcodegen generate` and build/install `AlsoMaps` on Vision Pro and
   `AlsoMapsPhone` on iPhone. Configure signing and API keys in
   `Config/Secrets.xcconfig` as for the main app; a fresh worktree needs its
   own local configuration.
2. In the Vision Pro map's bottom controls, open **iPhone Controller** and
   enable **Allow iPhone Controller**. Allow local-network access if prompted.
3. On iPhone, tap the game-controller button in the map toolbar. Select the
   headset name and enter the 12-digit code displayed on Vision Pro.
4. Use the left stick to move and the right stick to turn and climb. The
   centre slider zooms. Buttons change places, face north, toggle Fly, or
   enable faster motion. The controls support portrait and landscape.

Only one phone connects at a time. Xbox/keyboard input still works and merges
with remote movement. Closing the phone controller screen or backgrounding
either app disconnects and clears input. After the headset app becomes
inactive, re-enable pairing there. Turning pairing off and on creates a new
code. Codes are kept in memory and aren't advertised or saved.

## Transport and input

`Sources/Remote` contains the shared protocol and session. The phone sends
full input snapshots at up to approximately 60 Hz. Only one snapshot awaits
an acknowledgement at a time, limiting the queue when the network slows.
TCP disables Nagle's algorithm. Actions have separate reliable messages so
two brief taps aren't coalesced into one held-button state. The headset drains
them once per rendering frame through the existing `MapModel.perform` path.

The receiver clears continuous input after 250 ms without a snapshot and
rejects a delayed snapshot that arrives after that deadline. The phone drops
a connection after 500 ms without an acknowledgement; the host disconnects
a silent peer after one second. Pairing/handshakes time out after ten seconds.
Frames have bounded lengths, a protocol version, and validated finite axes.

TLS 1.2 with `TLS_PSK_WITH_AES_128_GCM_SHA256` authenticates using an HKDF-derived
key from the displayed code. Pair only with people who can see that code;
this manual code protocol isn't a persistent identity or PAKE system. Local
network and Bonjour declarations are in the two apps' generated Info.plists.
No multicast entitlement is needed for ordinary Bonjour browsing/advertising.

## Validation

```sh
xcodebuild -scheme AlsoMapsRemoteTests -destination 'platform=macOS' test
xcodebuild -scheme AlsoMapsCoreTests -destination 'platform=macOS' test
```

The remote suite exercises bounded framing, input validation, real Bonjour/TLS
pairing, repeated one-shot actions, disconnect/reconnect, wrong-code rejection,
and stale-input expiry (including rejection of delayed motion). It opens local
network listeners; allow local-network access if your environment requests it.
The navigation suite remains independent of networking.

For simulator builds with the released Cesium archive, use `ARCHS=arm64`.
Physical iPhone/Vision Pro testing found latency acceptable, but the connection
randomly disconnected several times. The disconnect cause is still unknown and
needs investigation before this is ready to merge. Check the strict snapshot
and acknowledgement deadlines, app scene-phase changes, and network errors;
these are investigation leads, not confirmed causes. Peer-to-peer behavior
without a router and physical-device lifecycle behavior need further testing.
