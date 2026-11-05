# Two places at once: working notes

Spike branch `spike/two-places`. Show a second ("guest") place with the map,
beside it or over it, at the same scale. **Observed** means seen when
something was run. **Inferred** means reasoned from the code or the maths
and not confirmed. None of this branch has been built: it was written in a
Linux container with no Xcode, Apple SDKs or Swift toolchain.

## Goals

- Compare two places at the same scale in 3D: the Grand Canyon next to
  Boston, Central Park on top of Golden Gate Park.
- Real sizes and real heights, with no map projection in the way.
- Two ways to compare:
  - **Side by side**, at the guest's own heights, so differences in
    elevation show.
  - **Overlay**, centres together, the guest turned to a chosen heading and
    its ground on the host's, to compare sizes.
- Off by default; tvOS left out but still building.

## Design

### The idea

Tiles are placed relative to an anchor with no global origin, so a second
place shown somewhere else is a second streamer with its own anchor and a
different transform on its tiles root. Nothing in the bridge changes.

### Placement maths (pure Swift, tested)

- `Sources/Navigation/DisplacedStream.swift` is the general piece: a tile
  stream with its own anchor and area of interest, plus `shownFromReal`, a
  similarity from its real world (ECEF) to where it's shown in the host's
  world (ECEF).
  - `placement(in: georeference)` = georeference ∘ shownFromReal ∘
    ecefFromAnchor, composed in double like `Georeference.placement(of:)`,
    so the guest goes through the same host georeference as everything
    else. That's why it works in every host (volume, immersive, a window)
    without any per-host code.
  - `lodCamera(carrying:from:)`: the host's LOD camera, taken from the
    host's anchor frame into the guest's by the inverse placement. The guest
    refines as if seen where it's shown. With a scaled `shownFromReal` the
    carried camera's distance scales too, which is the right detail for a
    miniature.
- `Sources/Navigation/GuestPlacement.swift` builds the rigid
  `shownFromReal` for a guest. Out of the guest's level frame at its centre,
  turned about its up by `heading`, into the level frame at the shown
  centre, raised by `verticalShift`.
  - **Side by side:** shown centre is the host's centre moved along
    `bearing` (east by default) by host radius + guest radius + gap. The gap
    defaults to a tenth of the two radii, at least 100 m. Shift 0, so a
    point h m above the ellipsoid at the guest is shown h m above it beside
    the host.
  - **Overlay:** shown centre is the host's centre. Shift is host ground −
    guest ground, both sampled at runtime (`sampleGroundHeight` on each
    streamer, at a quarter of the guest's radius around each centre) and
    never saved. `isPlaced` is false until both are known, and the guest
    isn't drawn until then, rather than showing at its own heights and
    jumping.
- `Tests/Navigation/GuestPlacementTests.swift` covers: separation and
  bearing; own heights kept side by side; north kept unturned; overlay
  ground matched; heading turning the guest's north (0, 0.5, π/2, 3 rad);
  rigidity; the LOD camera carried back equalling the host's (position,
  direction, up, field of view); a camera over the shown centre landing over
  the guest's centre; a scaled placement pushing the camera 10× away; the
  tiles root origin landing where expected; inputs streaming around the
  guest's own centre.

### The host's centre is fixed

The guest is placed relative to the host's centre **when it was set**: the
view's centre then (visionOS: the georeference point and the shown radius;
screen: the ground at the middle of the window and the half-width shown
there). So it stays put in the host's world while you fly to it or around
it. Going to a place moves the host's centre to that place
(`GuestPlace.rehost`), so the guest comes along: show the Grand Canyon by
Boston, then go to New York, and it's by New York.

### Runtime: `GuestPlace`

- `Sources/GuestPlace.swift`: owns a second `TileStreaming` (label "guest
  <id>" in the debug log) around the guest's centre, from the same tile
  source and key. Its tiles root goes in the host's map frame next to the
  host's.
  - `apply(georeference:hostInputs:held:)` sets its inputs and root
    transform. The host calls it where it places its own tiles.
  - `update(deltaTime:host:held:)` runs its cesium-native update after the
    host's and asks for any missing overlay ground samples.
- Hosts: `MapModel` (visionOS) and `ScreenMap` (Mac, iPhone) each hold an
  optional `guest`, conform to `GuestHost`, and forward settings and the
  Metal tile handler to it.
- UI: `Sources/GuestMenu.swift`, one menu for all three apps, next to
  Places: pick a guest, Side by Side or Overlay, Turn 45°, Hide. Shown only
  while the switch is on.
- Attribution: both streamers' credits are merged, each once, in the
  visionOS attribution panel and the screen attribution bar. The Google
  logo stays as it was (same source).

### Switch

- Settings › General › **Two places (experimental)**
  (`ViewPreferences.guestPlacesKey`), off by default. It only shows the
  Guest menu; turning it off hides any guest. Not reset by Reset to
  Defaults, like Draw with Metal.
- `ALSOMAPS_GUEST_PLACE=<place id>` shows that guest at launch (and the menu
  with it). `ALSOMAPS_GUEST_MODE=side|overlay` (side by default),
  `ALSOMAPS_GUEST_HEADING=<degrees>` and `ALSOMAPS_GUEST_RADIUS=<metres>`
  (the place's own radius by default).

### Drawing an overlay so the guest reads clearly

Side by side needs nothing special: both renderers draw the guest opaque.

**Chosen for Metal: a see-through guest with a depth pre-pass.** After the
host, the guest's tiles are drawn depth-only, then again in colour at 60%
alpha with depth compare greater-or-equal (reverse Z) and no depth write
(`MetalTileRenderer.encode(…, opacity:)`). Each pixel then shows:

- where the guest is nearest: its nearest surface, once, blended over the
  host behind it (no sorting, no guest-over-guest layering);
- where the host is nearer (a host building through the guest's ground):
  the host, opaque.

Positions are `[[invariant]]` with `preserveInvariance` so the two passes
meet exactly.

**RealityKit (volume, RealityKit immersive, RealityKit windows):**
`OpacityComponent(opacity: 0.6)` on the guest's tiles root. Simple, but
RealityKit sorts translucent meshes itself, and large photogrammetry tiles
may hide parts of the guest behind other parts of it, or flicker as the
sort changes (UNVERIFIED).

**Alternatives not built:**

- *Clip the host inside the guest's footprint* (Metal: discard host
  fragments whose position, in the host's level frame, is within the
  guest's turned square; pass that square as a uniform). Very clear, but you
  no longer see the host there, so it's a swap more than a comparison of
  sizes. Probably the better choice for side by side when the host streams
  to the horizon (see below).
- *Guest opaque, host see-through*: same pre-pass trick the other way.
  Reads as "the guest is real, the host is a ghost".
- *Tint or outline the guest* (multiply by a colour, or draw its footprint
  as a line): could combine with any of these to tell which is which.
- *Stipple / screen-door transparency* in RealityKit
  (`ShaderGraphMaterial` with a dithered discard): sort-free, available to
  RealityKit, but needs a material per tile.

### Fly (held tiles)

Fly holds the guest's tiles with the host's: its inputs stay as they were,
its tiles keep following the map (same georeference), no overlay samples
are asked for. Showing, replacing or hiding a guest leaves Fly, as going to
a place does, since a new guest would have nothing to hold. Changing mode
or turning the guest while in Fly is allowed; the guest moves, but its
detail is whatever was held.

### Costs

- A second root tileset request, so for Google a second map session per
  guest shown (and per streaming restart: key change, tile source change,
  Metal on or off).
- Roughly double the tiles, requests and memory while a guest is shown. The
  guest gets the same settings as the host, so its own 512 MB cache budget
  on top of the host's, its own 64 simultaneous loads and its own upload
  concurrency.
- A second cesium-native update on the main thread each frame. Selection is
  the bulk of the tick on Vision Pro (about 3 ms in an optimised build,
  notes/metal-renderer.md), so a guest could roughly double that.
- The guest's area of interest is a fixed square (its radius), not the
  horizon, so it's bounded: the Grand Canyon's 8 km radius is a 16 km
  square.

### Reconciling with `spike/world-in-miniature`

That spike also needs a second streamer. The shared part here is
`DisplacedStream`: any second stream is an anchor, an area of interest and
a `shownFromReal` similarity, scaled for a miniature and rigid for a guest,
with the LOD camera carried by its inverse. `GuestPlace` is the guest's
policy on top of that (modes, ground samples, host centre). A reconciled
version would probably be a `SecondaryStream` owning a `TileStreaming` and a
`DisplacedStream` source, with `GuestPlace` and the miniature each
supplying one, and the hosts holding a list of them rather than one
optional `guest`. Issue #9's sketch (several streamers, credits merged,
per-streamer tile IDs) fits the same shape: tile IDs are already per
streamer because each `TileStreaming` keeps its own entity map.

## Unverified

Nothing here has been compiled. In particular:

- **Everything compiles**, on visionOS, macOS, iOS and tvOS. tvOS doesn't
  include any new file; the only tvOS-visible change is `AttributionBar`'s
  optional `guest` parameter and `ViewPreferences.offersGuestPlaces`.
- **The Swift tests pass.** The frame conventions behind them (heading
  sign, the shift, the LOD round trip) were checked numerically in Python
  (see Log), not in Swift.
- **RealityKit translucency** of a whole tileset with `OpacityComponent`
  (marked UNVERIFIED in `GuestPlace.applyMode`).
- **Metal:** a depth-only pipeline with no fragment function; that
  invariance holds across the two passes with foveation's rasterization-rate
  maps (both marked UNVERIFIED in `MetalTiles.swift`).
- **`Picker` inside a `Menu` inside the visionOS bottom ornament** renders
  as an inline choice.
- **Ground sampling on the guest's streamer** finds the guest's ground soon
  after it starts. It's asked as soon as the streamer exists, before any
  tile has loaded; the bridge's sample loads what it needs (Inferred from
  the header). After six misses it falls back to sea level.
- **Two `CNTileStreamer`s at once.** The bridge has no per-process state
  besides signpost logs and a one-time registration (`dispatch_once`), and
  each streamer has its own asset accessor, credit system and caches
  (Inferred from reading `CNTileStreamer.mm`). Both share `URLCache`, which
  is what you'd want.

## Test plan

Every step needs a Google key (README, "Setup") and `xcodegen generate`
first. Watch the console for `[AlsoMaps] guest <id>: render …` once a
second, and for `guest <id>: host ground …` / `guest ground …` in an
overlay.

### 0. Tests

```
xcodebuild -scheme 'Also Maps Core Tests' -destination 'platform=macOS' test
```

`GuestPlacementTests.swift` should pass. A failure in
`turnsTheGuestsNorthToTheHeading` means the heading's sign is the wrong
way round.

### 1. Mac, side by side (try this first)

```
xcodebuild -scheme "Also Maps macOS" -configuration Debug -destination 'platform=macOS' -derivedDataPath build build
ALSOMAPS_GUEST_PLACE=grand-canyon ALSOMAPS_GUEST_MODE=side \
  "build/Build/Products/Debug/Also Maps.app/Contents/MacOS/Also Maps" > run.log 2>&1 &
```

The Mac starts at San Francisco with the canyon beside it (ALSOMAPS_PLACE
only works on visionOS and iPhone). Pick Boston from Places, which brings
the guest with it. Then:

- Turn to face east (right-drag) and zoom out (scroll) until about 20 km
  across.
- Expect: Boston, then about 10 km east of its centre, over the harbour or
  the sea, the canyon, floating at its real height: the rim about 2,100 m
  up, the river about 700 m up. North on both points the same way.
- Stats on (Settings › General › Show stats): a "Guest Grand Canyon" line
  with its own tiles and requests; the request counts roughly double.
- Attribution: Google's logo and credits from both places (Arizona's data
  providers appear alongside Boston's).
- Fly toward the canyon: it should sharpen as you get close to it where
  it's shown, as Boston does.

### 2. Mac, overlay

```
ALSOMAPS_GUEST_PLACE=new-york ALSOMAPS_GUEST_MODE=overlay ALSOMAPS_GUEST_RADIUS=2000 \
  "build/Build/Products/Debug/Also Maps.app/Contents/MacOS/Also Maps" > run.log 2>&1 &
```

The Mac starts at San Francisco, so the guest is over the Ferry Building.

- Expect: nothing of the guest until both ground lines are logged, then
  Midtown Manhattan over the Ferry Building, its ground level with San
  Francisco's, 60% opaque under RealityKit.
- Guest › Turn 45° turns it about the centre; Side by Side moves it east.
- Settings › General › Draw with Metal on: streaming restarts, the guest
  comes back see-through with only its nearest surface blended. San
  Francisco's taller buildings should show solid through Manhattan's
  streets. Look for: shimmer where the two passes disagree, black or
  missing guest tiles (depth-only pipeline), the guest drawn opaque.
- Compare the two renderers' overlays by eye; that's the decision of which
  overlay method to keep.

### 3. Mac, UI and switch

- Without the variables: Settings › General › Two places (experimental) on.
  A Guest menu appears left of Places. Pick a place, switch mode, turn,
  hide. Turning the setting off hides the guest and the menu.

### 4. Vision Pro (Optimised scheme), volume

Scheme environment: `ALSOMAPS_PLACE=boston`, `ALSOMAPS_GUEST_PLACE=grand-canyon`.

- Zoom out (two-hand pinch) until the volume shows about 20 km: the canyon
  beside Boston, at its height. The volume clips both, as it does the map.
- Guest menu in the ornament (next to Places): Overlay. Boston's ground and
  the canyon's rim should meet; the canyon cuts below Boston's ground, seen
  through it at 60%.
- Fly on: both hold; move about; Fly off: both resume.

### 5. Vision Pro, immersive (RealityKit and Metal)

- Immersive, then the same as 4, with Draw with Metal off and then on (the
  Metal space opens on the next Immersive).
- Check the Metal overlay with foveation on and off
  (`ALSOMAPS_METAL_FOVEATION=0`) for shimmer.
- Watch the frame rate with stats on and a guest shown against none: two
  updates on the main thread. A signpost recording (docs/profiling.md) with
  and without a guest would put a number on it.

## Open questions for the owner

1. **Overlay method:** see-through guest (built, Metal), clip the host in
   the guest's footprint, or see-through host? And should RealityKit get
   the same (a custom material), or is Metal enough for the overlay?
2. **Side by side when the host streams to the horizon** (immersive and the
   screen apps): the host's own tiles are also where the guest is shown,
   so a guest below the host's ground (say Death Valley beside Boston)
   cuts into it, and one above it floats over the host's tiles. Clip the
   host in the guest's footprint there too?
3. **Camera on showing a guest:** today nothing moves. Should showing one
   side by side frame both places?
4. **Fly:** holding the guest with the host, and leaving Fly when the guest
   changes. Is that right?
5. **Cache budget:** the guest gets its own full budget (512 MB). Split one
   budget between the two instead?
6. **Saved views:** the guest isn't in Copy View State. Should it be (its
   place, mode and heading, not its heights)?
7. **Heading control:** Turn 45° only. A twist gesture on the guest, or a
   slider?
8. **Guest radius:** the place's own view half-width. Grand Canyon at 8 km
   is a lot of tiles; New York's 1.2 km is less than Manhattan. Per-place
   comparison radii, or chosen in the menu?

## Log

### 2026-11-05: placement conventions checked numerically

- **Observed:** a Python (numpy) mirror of `GuestPlacement.shownFromReal`
  and `DisplacedStream.ownFromHost`, with WGS84 frames as in `Geodesy`,
  gave:
  - Grand Canyon side by side with Boston (radii 8,000 and 900 m): the
    guest's centre at 2,100 m maps to the computed shown centre, 2,100 m up,
    9.8 km east of Boston's.
  - A point 100 m north of the canyon's centre is shown 99.8 m north of the
    shown centre (and 0.0008 m below: the Earth's curve).
  - Overlay with heading 90°: the same point is shown 99.8 m **east** of
    Boston's centre, so a positive heading turns the guest clockwise, as
    intended. Guest ground at 2,100 m maps to the host's ground at 10 m.
  - The carried LOD camera, taken back through the placement, matches the
    host's to 2 × 10⁻⁹ m.
- **Observed:** `swift` isn't installed in this container, so none of the
  Swift was type-checked or run here.
- **Inferred:** the 0.2% short in "100 m north" is `GeoMath.offset`'s
  spherical Earth against the WGS84 frames; the tests allow 0.5 m.
