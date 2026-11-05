# World in miniature: working notes

A spike (branch `spike/world-in-miniature`): while the immersive space is
open, the volume shows a small copy of the world around you, and you can go
somewhere by pointing at it. Goals and design first, then what's unverified,
how to test it, open questions, and a running log, newest first. **Observed**
means seen running; **Inferred** means reasoned from the code or docs but not
run. Nothing in this spike has been built or run yet, so nothing below is
Observed except what was read in the code.

## Goals

- **Getting somewhere far, from inside the map.** In the immersive view
  you're in the map at your own eye, so going tens of kilometres means a long
  flight or a trip through Places. A world in miniature (the VR navigation
  technique: a hand-held or tabletop copy of the world you're in) lets you
  see where you are in the wider area and point to go there.
- **Use the volume.** In Immersive it's only a control panel. Make it the
  miniature: the area around you, a few to tens of kilometres across.
- **Show what's happening:** where you are (the eye), which way you're
  heading and looking, and what the immersive map is streaming.
- **Follow you** as you fly.
- **Go by pointing:** pinch-tap a spot to jump there, keeping your heading and
  height above the ground, through the navigation core's existing operations
  and with a new track segment (docs/navigation-handoff.md: the camera is
  always the eye; jumps start a new segment).
- **Stretch:** drag the miniature to slide along; pinch it with both hands to
  zoom the miniature, not the map.
- **Constraints:** off by default; visionOS only (tvOS, iOS and the Mac don't
  get it but keep building); Google's terms (nothing stored or exported, no
  other providers' content over Google's, logo and attributions visible).

## Design

### Where the miniature's tiles come from: a second streamer

A RealityKit entity can only be in one scene, so the immersive map's tile
entities can't also be in the volume. The choices considered:

| | Second streamer (built) | Clone the immersive map's tile entities |
|---|---|---|
| Detail | Chosen for a 1 m table: even, coarse | Wrong for a table: very fine around you, coarse or missing tens of km away |
| Coverage | The table, whatever the immersive map streams | Only what the immersive map streams; with Limit reach, maybe less than the table |
| Metal renderer | Works (the miniature is always RealityKit) | Nothing to clone: Metal tiles aren't entities |
| Google map sessions | One more per start | None |
| Memory and requests | Its own tiles (bounded by its cache budget) | Shared meshes and textures, but every near tile drawn twice |

The clone would be cheaper in sessions and requests, but it shows the wrong
thing and doesn't work with Metal, so the spike streams the miniature's own
tileset.

**What it took** (Inferred from the code): very little.
`TileStreaming` was already a self-contained streamer: its own inputs,
settings, `tilesRoot`, uploader, key handling, credits and stats. A second
instance needed:

- **A shared HTTP cache** (`CNTileStreamer.mm`, `CNSharedTileCache`). Each
  streamer's `URLSessionAssetAccessor` made its own `CNTileCache` over the
  same directory. It's now one instance per process. This also covers today's
  restarts, where the old streamer drains while the new one starts.
- **A name** (`TileStreaming.name`), for the debug log and the stats line.
- **Attribution from several streamers** (`AttributionView(sources:)`):
  credits merged, Google's logo if any of them is Google's.

Everything about the miniature itself is in `WorldMiniature` (RealityKit) and
`MiniatureLayout` (the navigation core), not in the streaming layer.

**Reconciling with `spike/two-places`:** that spike also needs a second
`TileStreaming`. The pieces above are the general part: any number of
`TileStreaming`s, each with a name, sharing the cache, with merged
attribution. Neither spike adds anything miniature-specific to
`TileStreaming` or the bridge. What a merge would still need is a shared idea
of the second streamer's settings: here `WorldMiniature.streamingSettings`
derives them from the main tile source (detail 24, outer 64, 4 uploads, 16
loads, 128 MB).

**What it costs** (Inferred; measure it, see the test plan):

- **Google map sessions.** Each streamer start is a root tileset request,
  which Google counts as a map session. The miniature's streamer starts every
  time it's shown (opening Immersive with it on, turning it on, the volume
  coming back) and restarts with a new tile source or key. Hiding it drops the
  streamer, which frees its memory but costs a session the next time. Keeping
  it alive across Immersive sessions would trade memory for sessions (open
  question 5).
- **Memory.** cesium-native keeps up to 128 MB of loaded tiles for it (the
  main map's default is 512 MB), plus their RealityKit meshes and textures.
  How many tiles a 10 km table settles at, at SSE 24, is unmeasured; a guess
  is a few hundred.
- **Requests.** Its own requests, all through the shared cache. Google's tile
  URLs carry a per-session token, so the two streamers' requests never hit
  each other's cache entries even for the same tile. Each session allows 12
  connections per host, so it's up to 24 with both.
- **Main-thread time.** A second `update` per frame: selection, re-placing its
  tiles and showing or hiding entities. The main map's costs 2–3 ms (#2); the
  miniature's should be less, with fewer tiles. Each frame now has two
  `Update` and two `Select` signposts.
- **Keys.** Each streamer handles keys itself, so a rejected app key could
  trigger two refreshes (`refreshAppKeys(force:)`) at once.

### The table (`MiniatureLayout`, `Sources/Navigation/Miniature.swift`)

- **Scale:** fixed by its size: `halfWidth` world metres (1–30 km, so 2–60 km
  across; default 10 km across) over the volume's half-width (0.5 m). At the
  default, 1 cm on the table is 100 m.
- **Placement:** level, centred on the ground beneath the eye, which sits at
  y = −0.2 m (0.1 m above the volume's floor, so somewhat lower ground still
  shows). The ground height is the one the immersive map is placed by (the
  settled 3×3 sample), so the miniature never reads its own tiles to place
  itself (the "nothing from the tile selection moves the view" rule doesn't
  strictly apply, since the miniature's LOD camera doesn't depend on its
  placement, but there was no reason to test it).
- **Orientation:** heading-up by default: your heading points into the volume,
  so what's ahead of you in Immersive is ahead on the table, and the table
  turns as you turn. North-up is the other choice.
- **Edges:** the volume clips whatever reaches past it.
- **Its streaming:** anchored on the ground beneath the eye, every frame. The
  square is 1.25 × the table, turned with it. The LOD camera looks straight
  down from far enough that the square's corners are in view, so everything
  is selected at the inside detail. On the bridge's 2048-pixel view, that puts
  the table about as many pixels across as the real table covers on the
  display (1 m seen from about a metre), so its detail number is roughly
  comparable with the main map's.

### What's drawn on it (`WorldMiniature`)

- **You:** a white ball at the eye, on a white post from the ground beneath
  it. The eye is drawn at most at the volume's ceiling (0.27 m), which at the
  default size is anything above about 4.7 km above the ground; then the post
  is thicker.
- **Heading:** an orange bar from the eye, along the camera's heading (which
  way you move).
- **Looking:** a translucent teal cone from the eye along the head's view
  direction, carried through the room placement and the immersive map's
  georeference (so a tilted globe tilts it too). The RealityKit immersive
  space follows the head with its own `HeadTracker` while the miniature is
  on. The Metal one passes on the device anchor it already has. With neither,
  the cone lies level along the heading.
- **What's streaming:** the main streamer's square, in yellow, as the
  bridge's excluder sees it (as in the tile bounds overlay). By default
  Immersive streams to the horizon (hundreds of kilometres), so the square is
  far off the table and clipped away. It shows with Limit reach, and while
  Fly holds tiles, where it marks the held area as you fly toward its edge.

### Going somewhere

- **Pinch-tap** (`SpatialTapGesture` on a slab over the table) →
  `MapModel.jump(to:)`. It works like going to a place: held tiles are
  released, playback stops, and the track starts a new segment
  (`markJump`). The move is `NavigationOperations.move` straight to the
  point (`MiniatureLayout.jump`), so latitude and longitude change, height
  above the ellipsoid stays, and both headings are carried along the great
  circle, a fraction of a degree over tens of kilometres. Height above the
  ground is kept by moving the camera with the ground. It's first estimated
  from the miniature's own tiles (the lowest vertex of the most detailed
  tile over the point, used only while rendering). Then the ground sample
  there corrects it, through the existing `placeAwaitsGround` path that place
  jumps use.
- **Drag** (stretch): the world you grab stays under your hand, as when
  dragging the main map. Since the table follows you, you slide the other way
  by the drag ÷ the scale (`MiniatureLayout.slid`, also
  `NavigationOperations.move`). It's continuous travel, not a jump, so no new
  track segment. It's limited like any travel while tiles are held.
- **Two-handed pinch** (stretch) zooms the table (its `halfWidth`) about your
  marker, never the immersive map. The ornament also gets zoom buttons while
  the miniature shows.

The slab sits at the table's ground level, and tiles have no collision, so
gaze goes through the terrain to the slab. Pointing at a mountainside lands
beyond the point you see, along your gaze, by the terrain's height on the
table (about a centimetre per 100 m at the default size).

### Switches

- **Settings › Immersion › World in miniature**, off by default, with "On the
  table" (heading or north ahead) and Size (km across). It isn't saved between
  launches, like Human scale.
- `ALSOMAPS_MINIATURE=1` turns it on for a run (listed, unticked, in the
  visionOS scheme next to `ALSOMAPS_PRESENTATION=immersive`).
  `ALSOMAPS_MINIATURE_KM=<n>` makes the table n km across,
  `ALSOMAPS_MINIATURE_NORTH_UP=1` keeps north up, and
  `ALSOMAPS_MINIATURE_DETAIL=<SSE>` sets its detail (default 24).
- It shows only while the setting is on, the map is Immersive and the volume
  is open. It's checked every frame, so toggling any of them takes effect at
  once.

### Terms

- **Nothing stored or exported.** The miniature's tiles go through the same
  cache as the main map's, within the cache headers. The ground guess from its
  tiles is used for one jump and not kept.
- **Only Google's tiles** (or the chosen source) are on the table. The
  markers are the app's own.
- **Logo and attributions:** while it shows, the volume's ornament shows the
  miniature's attribution (Google's logo and its credits) above the table.
  With the Metal immersive space, which has no panel of its own, these are
  merged with the immersive map's.

## Unverified

Marked `UNVERIFIED:` in the code where it's one line:

- **`UnlitMaterial.blending = .transparent(opacity: .init(floatLiteral:))`**
  for the cone (`WorldMiniature.init`). If it doesn't compile, drop the
  opacity; the cone is then opaque.
- **Two `ARKitSession`s with world tracking at once** (`ImmersiveMapView`).
  The eye measurement's session overlaps the head follower's for up to 3 s
  when Immersive opens with the miniature on. If ARKit refuses, the cone
  falls back to the heading; the fix is one tracker for both.

Not marked, but not checked against the SDK or a device:

- `SpatialTapGesture().targetedToEntity(_:)` and its value's `location3D`
  with `convert(_:from:to: .scene)`, used beside the volume's other gestures.
  A tap might also fire at the end of a short drag.
- The volume keeps drawing and taking gestures while an immersive space is
  open, including the Metal one's full immersion.
- Entities in the volume's scene can be updated from the immersive scene's
  frame event (or the Metal frame loop) on the main actor. Today's code only
  updates the scene that sends the event.
- The volume's RealityView content origin is the scene origin (the volume's
  centre). The map's gestures already assume this.
- The volume clips the table's tiles at its bounds (the README says it clips
  the map's).
- `AttributionView.body` uses statements and an explicit `return` (no view
  builder). A nested string literal inside a `Text` interpolation.

Swift isn't installed in the Linux container this was written in, and the
`simd` module the core uses doesn't exist on Linux anyway, so not even the
pure code was type-checked. The tests' expected values were worked by hand.

## Test plan

**Mac, first:**

1. `xcodegen generate`.
2. Build each target, to catch compile errors: `Also Maps visionOS`, `Also
   Maps macOS`, `Also Maps iOS`, `Also Maps tvOS`. Only the bridge change, the
   core file and `TileStreaming.name` reach the last three.
3. Run the core tests: `xcodebuild -scheme 'Also Maps Core Tests'
   -destination 'platform=macOS' test`. `MiniatureLayoutTests` and
   `MiniatureNavigationTests` are new. The tolerance most likely to be
   wrong is the drag test's 2 mm (spherical steering on an ellipsoid).
4. Regression check of the shared cache: run the Mac app warm and cold, as in
   docs/tile-caching.md. The counts should match that doc's table.

**visionOS simulator** (no head pose, so the cone stays level along the
heading):

1. Scheme environment: tick `ALSOMAPS_MINIATURE=1` and
   `ALSOMAPS_PRESENTATION=immersive`, and add `ALSOMAPS_PLACE=san-francisco` (or a place
   from Places.json) and `ALSOMAPS_MINIATURE_KM=10`. Start with a warm cache
   or a cold one on purpose (docs/tile-caching.md); the miniature's requests
   add to the totals.
2. **Expect:** the volume has its baseplate and shows a 10 km square of San
   Francisco, level, a little above its floor, with a white post and ball at
   the centre, an orange bar pointing into the volume and a teal cone along
   it. Above the table, the Google logo and credits. The log has
   `[AlsoMaps] miniature: render N tiles …` once a second beside the main
   line.
3. **Show stats** (Settings › General): the ornament lists the miniature's
   tiles and requests.
4. **Follow:** fly forward with the keyboard (W). The table slides toward you
   under the fixed marker. Turn (Q/E): heading-up, the table turns and the bar
   stays pointing in. Switch to North ahead: the bar turns instead.
5. **Climb** (F): the ball rises, and above ~4.7 km sits at the ceiling on a
   thicker post.
6. **Streaming outline:** Settings › Immersion › Limit reach, Reach 5×. A
   yellow square appears around the marker and shrinks and grows as you
   descend and climb. Turn on Fly and fly toward its edge: the square stays
   while the marker moves within it.
7. **Jump:** pinch-tap a point a few kilometres away. The log says
   `miniature: jumped to …`, then a `ground sample` line. The immersive map is
   now there, facing the same way, at about the same height above the ground.
   Its ground may shift once when the sample lands. Try a hill or a valley a
   few hundred metres above or below where you were.
8. **Track:** record a track, jump twice, stop, and Show Track. Each jump
   should start a new segment, with no line across.
9. **Drag** the table: the point you grabbed stays under your hand, and you
   travel the other way. **Two-handed pinch:** the table zooms about the
   marker (2–60 km), and the immersive map doesn't change. Try the ornament's
   zoom buttons.
10. **Off:** turn the setting off. The table and its attribution go and the
    baseplate hides. Exit Immersive with it on: the volume shows the normal
    map, with no miniature log line.

**Vision Pro** (Optimised scheme):

1. Repeat 2, 4, 6, 7 and 9 standing. Check that the cone follows your head as
   you look around and down, and that a tap lands where you're looking,
   including on a hillside (see "Going somewhere").
2. **Metal:** with Draw with Metal on, check the table works the same, the
   cone follows the head, and the ornament shows one merged attribution.
3. **Cost:** with Show stats, settle at a place with the miniature on and off.
   Record the tile counts, memory (Xcode's memory gauge) and Update signposts
   (two per frame with it on; docs/profiling.md). Note them in the log below.
4. **Sessions:** count root tileset requests in the log or Instruments over
   one Immersive visit with the miniature toggled once: expect one for the
   main map and one per time the miniature showed.

## Open questions

1. **Orientation:** heading-up (built as the default) or north-up? The
   proper WIM is aligned with the room: north on the table is north around
   you, wherever the volume is. That needs the volume's pose in the immersive
   space; SwiftUI's `.immersiveSpace` coordinate space might give it
   (unverified), so it wasn't built.
2. **Drag:** the drag moves the world under your hand (you go the other way),
   matching the map's direct manipulation. Did "slide yourself along" mean
   dragging your marker instead (you go the way you drag)?
3. **Tap accuracy on terrain:** the tap hits a flat slab, so hillsides land
   long. Worth collision on the miniature's tiles, or a ray through the
   miniature's tiles (cesium-native can intersect rays with loaded tiles)?
4. **Ground pop after a jump:** the camera moves with the ground twice (the
   miniature's guess, then the sample). Acceptable, or wait for the sample
   before jumping, behind a short fade?
5. **Sessions vs memory:** keep the miniature's streamer between Immersive
   visits, or for the app's life, to save Google map sessions?
6. **What to show for streaming:** the yellow square is off the table unless
   reach is limited. Would the immersive map's drawn tile footprints, or its
   LOD view, say more?
7. **Persist the setting**, unlike Human scale?
8. **Vertical exaggeration** for flat areas at large sizes (a non-uniform
   scale on the miniature's tiles root)?
9. **Before Immersive:** should the volume offer the miniature's
   "point to go" too?

## Log

### 2026-11-05: the spike, written but not built

- **Observed (code):** `TileStreaming` needed no structural change to run
  twice. The only shared state below it was the HTTP cache, one per
  `URLSessionAssetAccessor` over the same directory. Today's restarts
  already overlapped two of them while the old streamer drained.
- **Observed (code):** the volume's own gestures target the main map's slab,
  which moves to the immersive scene while Immersive is open. So the
  miniature's gestures in the volume don't compete with them for an entity.
- **Observed (code):** `go(to:)`'s `placeAwaitsGround` path moves the camera
  with the ground by `ground − rayHeight`. Leaving `rayHeight` at the old
  ground (rather than resetting it to 0, as place jumps do) keeps height
  above the ground across a jump with no new mechanism.
- **Inferred:** with the default (horizon) streaming, the main streamer's
  square is hundreds of kilometres wide, so it never shows on a 2–60 km table.
- Commits, in order: shared tile cache; streamer names; `MiniatureLayout` and
  tests; `WorldMiniature`; `MapModel` wiring; the volume; head following;
  Settings and scheme variables; these notes; a fix so a cancelled pinch on
  the table can't block dragging.
