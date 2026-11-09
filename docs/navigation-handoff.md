# Navigation: goals and decisions (hand-off note)

Written 2026-10-26 at the end of a long design and implementation session, to seed a fresh one. It separates what the project owner said or approved from what was only proposed. Check it for leftover assumptions before relying on it: it was written from inside the session it summarises.

## Purpose (owner)

A general-purpose app with Google Earth VR-like flying, from street level to the globe, and a flight-sim feel. Spatial visualisation and drawing come later. Today it's visionOS (a volume, and an immersive mode, formerly the "floor modes" 3×, 5× and 10×, in an immersive space), plus a static macOS view.

## Decided by the owner

**Motion and navigation**

- **Climb** changes height only; latitude and longitude stay fixed.
- **Turn** changes heading in place.
- **Move** travels along the globe, carrying the heading with it, so flying over a pole continues.
- **Speed** scales with height above the ground under you, not with a zoom radius, so it isn't faster over hills than in valleys.
- **Pinch and twist** happen around where you pinched. Drag moves with the hand.
- **Flying is one experience.** Climbing, turning and moving look and feel the same everywhere. Whether that's done by rescaling the world or by moving a scene is an implementation detail.

**Level and tilt**

- **In VR there is a level baseline: the floor.** "For the map to look level, it must be level with the floor." The map doesn't always need to look level, but when it does, it must actually be level.
- **Tilt isn't inherently tied to altitude.** It belongs to the camera or interaction mode.
  - **Drone mode (today's):** always a level base (tangent to the geoid). Far enough away you'd need to look straight down to see anything, so some tilt is helpful. The current tilt-versus-altitude curve is fairly arbitrary.
  - **Google Earth VR:** a button toggles tilt between two extremes ("ground" and "globe"), with overlapping altitude limits. You reach ground mode's maximum altitude, then toggle to globe mode to go higher.
- **Flat screens** (macOS): some "looks level" behaviour tied to positions may make sense there. It isn't the VR rule.
- **The camera is the eye, always.** In the immersive space the camera is never a point in space disconnected from the viewer's eye, at any altitude or tilt: tracks, speed, tile loading and saved views all mean "where you are". Tilt therefore turns the world about the eye. (An earlier tilt pivoted about the map's centre point and moved the camera off the eye above 50 km; recorded tracks exposed it.)

**Modes and streaming**

- **Multiple camera and interaction modes** should be possible.
- **Tiles live or held** is a user-facing choice. It's a real feature (Hold tiles), not a workaround.
  - **Live:** detail refines as you approach, and the streamed area follows.
  - **Held:** fly through the geometry already loaded, so the view is stable but nothing finer arrives.
- **Streaming should not simply "follow your head".** Following the head means tiles load, unload and shift as you move, which isn't always wanted. Both ways should be possible, with a switch.

**The "how does this work" mode (the grounding use case)**

- **What's shown:** the relevant points as models: a head with a headset, and rays or cones from it.
- **Where it sits:** normally at the real head's position. In this mode you can walk around the scene, or start a few metres away from the modelled user, watching it.
- **Streaming:** it follows the modelled user, whose position can be animated to show how streaming is connected.
- **Rendering:** ideally the same setup, with the modelled user's position decoupled from the real user's.
- **Watching from a few metres away** is a transform of everything (the whole scene), not a special kind of room placement.

**Documents and process**

- **Docs:** goals first, mechanisms after. Don't overspecify, and don't state consequences of an assumed mechanism as if they were requirements.
- **Old saved views:** no compatibility. Reject them clearly; new-format saving and restoring stays a feature.
- **Review before building:** review designs before big changes, and try things before commits are pushed.
- **Commits:** one per stage. Build each commit's exact staged contents for visionOS and macOS first.
- **Never commit:** secrets (`Config/Secrets.xcconfig`) or `Config/App.xcconfig`. Don't push without the owner's go-ahead.
- **After simulator testing:** quit the app; it can play a soundtrack.
- **Tests:** keep the macOS unit-test target for the navigation core (approved).

**Direction since the first hand-off draft (owner)**

- **Full immersion first:** focus on an immersive mode without passthrough. It's easier to reason about, and the room competes less.
- **Scale is an area to explore:** for example Google Earth VR's fixed human-scale mode, and moving in and out of human scale automatically, which the owner finds an interesting effect.
- **The floor defines level; its role as a height datum is open.** Putting the ground on the origin plane (the floor) isn't a goal in itself. It was inherited from the volume, where content must sit in the box.
- **Tile loading should suit a viewpoint, not a view direction.** The eye is at a point and may look anywhere in a comfortable range, so load the detail any of those views would need, nearest first. Detail closest to you, where you can easily look while seated, matters most.
- **Distances and ranges aren't derived from the room's size.** The map doesn't read as bounded by the room (it seems to extend past the walls), so don't propose cutoffs from room dimensions without a reason.

## Rejected

- **"The eye is the camera":** placing the world so the navigation camera sits at an assumed viewer position. It welded three separate things together:
  - the navigation camera;
  - where and how big the world appears in the room;
  - the viewpoint tiles are selected for.
  
  This produced a tilt that came from pitch, tilt changes on mode switches, and claims like "moving the viewer changes the world or detail". None of those are inherent.
- **Tilt derived from camera pitch or from host geometry.**

## Proposed, not decided

- **Keeping the three things separate:**
  - placement is a function of the navigation camera and the mode (scale, yaw, an explicit tilt), with nothing about any viewer;
  - the streaming viewpoint is an independent switch: a fixed design viewpoint, the tracked head (#4), or a modelled viewer;
  - live/held is a second, independent switch.
- **Room hosts:** scale so the ground beneath the camera sits on the base plane (low in the volume, the origin plane in an immersive space). Untested against the owner's intent.
- **Layering:** room placement (how the user arranges the map in their room) and an observer offset (explain mode) as separate parent transforms over the whole scene.
- **Tilt pivot and raised centre** for a "globe" state.
- **Streaming defaults:** areas of interest per host (volume around the view centre, immersive blended toward the viewer) and level of detail from a fixed design viewpoint.

## Engineering findings (observed, factual)

- **Tile heights are unreliable while loading.** The lowest vertex of a coarse rendered tile can be kilometres below the real ground; −10,500 m was seen near San Francisco.
- **Never let tile selection move the view.** Placing the map from rendered-tile heights each frame created a feedback loop: new height → rescaled map → moved level-of-detail camera → different tiles → new height. The view bounced. Rule: nothing derived from the current tile selection may continuously move the view.
- **A newly opened RealityKit scene's first frames can have a near-zero time step.** Easing loops must test whether they've reached their target, not whether the last step was small.
- **cesium-native can select tiles for several viewpoints at once.** `updateViewGroup` takes a list of views, which is relevant to the explain mode.
- **visionOS SDK limits.**
  - `onWorldRecenter` (XROS 27.0) exists only for Compositor Services content, not RealityView immersive spaces.
  - The tracked head (`DeviceAnchor`) is only available in immersive spaces.
- **Restoring a view state at launch** used to be overwritten when streaming started. Fixed in stage 2.

**Tile loading (cesium-native v0.64.0, as built)**

- **Tiles are chosen for one virtual camera (the LOD camera).** In immersive modes it sits at the assumed eye (1.6 m above the immersive origin), points at the map's centre point (about 16° down, 5.6 m ahead), and has a 60° view. It doesn't follow the head.
- **Frustum culling is now off** (`23e2502`). It was on, so tiles outside that view were dropped, and the floor from the viewer's feet to about 1.5 m ahead had no tiles. This was a stage 2 regression: the area streamed around the viewer was loaded and then culled. The old 45° camera saw the whole map.
- **Detail:** a tile is refined until its screen-space error (roughly geometric error ÷ distance, in pixels) meets **Detail** (16) inside the view or **Outer detail** (64) outside it. Outer detail had no effect while culling was on. Both fall with distance; setting them equal removes the direction penalty, not the distance falloff.
- **Load order is fixed** (`computeTilePriority`): `(1 − cos angle) × distance` from each view's position and direction, best across views, smallest first, within the urgent, normal and preload groups. So tiles near the view's direction load first, even far away, and the floor under the viewer loads last. It isn't configurable without a patch (the xcframework is built locally from a tag, so a patch is possible).
- **A straight-down view gives distance order:** for ground tiles the score becomes distance minus the camera's height. It needs Outer detail ≈ Detail, because a 60° downward view leaves most tiles "outside".
- **Adding views takes the best score:** a wide forward view alongside a down view brings distant on-axis tiles to the front again, so the two together don't give distance order.
- **v0.65.0** (Oct 2026) adds a `ViewStateMeasureDelegate`: an app-defined error measure per tile, which can express detail by distance from a point with no frustum. Load priority is unchanged in v0.65.0. It has breaking `ViewState` changes.
- **Fog culling with the default table never culls anything here.** The cutoff is about 27 ÷ density, which is 135 km or more at every height in the table, far beyond the area of interest. Fog-hidden tiles get Outer detail even with fog culling off, so that never triggers either.
- **The area of interest (yellow in the overlay) is the hard limit** on what loads. The bridge's excluder skips tiles whose bounding sphere is entirely outside an east/north-aligned square around the streaming anchor, enlarged to contain the square turned to the heading. With culling off, it's the only limit on what loads behind the viewer.
- **Ground estimates move the LOD camera:** the virtual camera sits (ray height − envelope height) below the navigation camera in the world. A new 3×3 sample moves it, which refines or coarsens some tiles. It can jump by hundreds of metres where the sample grid gains or loses a valley (for example around Ronda, where high relief also puts the viewer's head inside the terrain).
- **Judgement:** cesium-native's selection and ordering are built around one view direction per camera, which is a poor fit for VR. Streaming, decoding, caching and hole-free loading are fine.

**Debugging tools**

- **Tile bounds overlay** (`5137146`, `4eef2d4`, `6eb1796`; Tuning "Show tile bounds", or `ALSOMAPS_TILE_BOUNDS=1`):
  - each drawn tile's box: cyan inside the LOD camera's view, orange outside;
  - yellow: the area-of-interest square;
  - pink: the LOD camera's view, drawn from the camera itself and tapering there;
  - white: its view direction.
- **Proposed, not built:** use the measured head position on entering the immersive space for the LOD camera only, not for placement; a Tuning toggle for frustum culling; weighted view groups.

## Code state (`main`, not pushed)

**Commits**

- `d715d51` Stage 1:
  - `Sources/Navigation/`: geodesy and a hit-or-miss surface query, camera pose and navigation state with movement heading, georeference and room placement types, streaming inputs, area-of-interest policies, navigation operations and two prototype control styles;
  - the bridge takes a level-of-detail camera as vectors and an area-of-interest heading;
  - tiles are placed relative to whichever anchor is streaming;
  - the `Also Maps Core Tests` target.
- `5bc6e91`, `ff2eb9e`, `1cb1bf4` Stage 2 and fixes:
  - the camera is the stored state;
  - model-flight controls;
  - anchored gestures;
  - speed from height above ground;
  - held tiles;
  - view state v2;
  - per-tile height ranges in the bridge.
  
  **Placement uses the rejected "eye is the camera" rule.**
- `23e2502` Frustum culling off.
- `5137146`, `4eef2d4`, `6eb1796` Tile bounds debug overlay.
- `2cdf8b1` **Immersive placement replaced** (`EyeLevelModel`): the camera at the eye, the map level whatever the pitch, scale from height above the ground, tilt following altitude directly about the map's centre point (5.6 m ahead). The volume still uses the adaptive model.
- Then: one Immersive mode (10×'s geometry) instead of 3×/5×/10×, which differed only in where the centre point sat and the shown square's size; and an area of interest that covers everything visible: all around the ground beneath the eye's position in the world, out to the horizon plus a 3 km terrain allowance (the old "blended" policy faded out above 1 km and dropped to the shown square above 50 km). **Limit reach** in Tuning caps it at a multiple of height above the ground; Region is gone.

**Likely keepable:** stage 1's pieces, the bridge changes, held tiles, view state v2's shape, the navigation operations (climb, turn, move with heading transport), the ground lesson, and the tests that don't assume the rejected rule.

**Suspect:**

- **The room placement rule:** `AdaptiveModel.framing` and its pitch policy, the horizon pitch limit as a placement constraint, the anchored-gesture solve built on it, and place framing.
- **`docs/camera-core.md`** throughout: written under the rejected rule.

Untracked: `docs/camera-core-review.md` (an external review of revision 2) and this file.

## Suggested instructions for the next session

- **Goals first:** start from the owner's decisions above; restate goals in plain terms before any mechanism.
- **Assumptions:** list them explicitly. Mark anything not decided by the owner as a proposal.
- **No unapproved requirements:** don't derive consequences from an assumed mechanism and present them as requirements.
- **Terminology:** keep it minimal and stable, and define a term before using it.
- **Small steps:** work in small, reviewable steps, and turn each agreed principle into a test, for example "untilted map is exactly level with the floor in every host, across host switches and place jumps".
- **Stage 2's placement:** decide with the owner whether to revert it or rework it.
