# Camera-centric navigation core

Status: revision 7 (2026-11-09).

- **Implemented:** stages 1 and 2 are merged. Stage 2b (§13) is implemented as checkpoints on `claude/volume-explicit-tilt-bcfcc9`, not merged: both room hosts are placed by §5, and pitch no longer affects what they show or how they respond.
- **Changed here:** §5's tilt now pivots about the design eye point, as the immersive space's did, and each host sets its full tilt. Terms for the view centre, the content centre and pitch's uses are in §2. Zoom in room hosts (§11) heads for the view centre, below where the tilt starts.
- **Working log:** `notes/volume-placement.md`.

## 1. Goals

### What the app is for

- **Fly anywhere, from street level to the whole globe,** as in Google Earth VR, with a flight-sim feel.
- **Later:** spatial visualisation and drawing on top of the map.

### How navigation should feel

1. **Consistent motion.** Climbing, turning and moving behave the same in every host and with held or live tiles. Climbing changes altitude, turning changes heading, moving travels along the globe (including over the poles).
2. **Speed that matches what you see.** Movement scales with your height above the ground beneath you, not with a zoom radius. Hills and valleys feel the same.
3. **Direct manipulation.** What you grab stays under your hand while you drag, pinch and twist.
4. **Several camera and interaction modes over one core.**
   - **Today's mode is a drone.**
   - **A Google Earth VR-style mode with ground and globe tilt** can be added without rewriting navigation (§3.3).
   - **On the Mac, orbit/pan/zoom** can be added the same way.
   - **Later:** a fixed human-scale mode.

### What the display must respect

5. **In VR, the room's floor is the level baseline.**
   - When the map is meant to be level, it **is** level with the floor, by construction.
   - Tilting the map is a deliberate choice of the current mode. It never results from geometry happening not to match.
   - Nothing about the map's tilt changes because you switched host, jumped to a place or turned your head.
6. **On a flat screen** (the macOS window), the render camera is the camera. "Level" there is the camera's own pitch, and no room baseline exists.

### What streaming must do

7. **Streaming follows what you see.**
   - Detail refines as you approach. You can also **hold** the loaded tiles and fly through them (§9).
   - Display and streaming must not feed back into each other. Stage 2 learned this the hard way (§7).

### Engineering goals

8. **Platform-neutral core.** The navigation maths is Foundation and simd only, tested on macOS without a scene (`Also Maps Core Tests`).
9. **Total and stable.** Every input has a defined result, with no NaN transforms. Estimates that move the view change only when they're trustworthy, and they ease when they do.

### Non-goals

- Collision avoidance or terrain clearance guarantees.
- Exact equivalence with the old implementation.
- Restoring old saved views.

## 2. Terminology

| Term | Meaning here |
|---|---|
| **Camera pose** | The geographic viewpoint: latitude, longitude, height above the WGS84 ellipsoid, heading and pitch. |
| **Navigation state** | The camera pose plus the movement heading and whether it's linked to the view heading. |
| **Interaction mode** | How input changes navigation, and which view tilt policy applies: drone, ground/globe toggle, orbit/pan/zoom. (Called a *control style* in code.) |
| **Presentation style** | How the world is mapped into the room or window, including scale: adaptive scale (today), fixed human scale, inspectable model. |
| **Host** | The physical container and its fixed geometry: the volume, an immersive N× layout on the immersive space's origin plane, or the macOS window. |
| **Level frame** | East, north and up at a point, with up along the ellipsoid normal. The geoid's vertical differs by under 0.02°, which is negligible here. |
| **View tilt** (τ) | How far the world is deliberately tipped toward the viewer in a room host: 0 is level with the floor, 90° faces you. It's chosen by the interaction mode. |
| **Design eye point** (E) | The assumed viewer position in a room host: a fixed point in front of the volume, or the headset's position measured once when the immersive space opens (an assumed point if that fails). It never follows the tracked head. Say "the design eye point", not "your eye". |
| **Pitch** | The camera pose's up/down angle. Its uses differ and should be named: the *pitch assist* (removed: it eased pitch with altitude); places *set* it; gestures and moves *carry it through*; flat screens *render* with it; tracks and saved views *record* it. Room hosts don't read it. |
| **Head pose** | The real head (ARKit's `DeviceAnchor`), in immersive spaces only. Used for level of detail later (#4), never for placement. |
| **Reference space** | The host's origin: the volume's centre, or the immersive space's origin (the floor where the user stood when it opened). |
| **Base plane** | The horizontal plane the map's ground is placed on: low in the volume, or the immersive space's origin plane (y = 0). |
| **Content centre** (C₀, C₁) | C₀: the middle of the shown region on the base plane (the box floor's centre in the volume, 5.6 m ahead in the immersive space). C₁: a raised point the volume's view centre rises toward as the map tilts (the box's centre). |
| **View centre** (G) | The ground point treated as the middle of what's shown: what the gesture slab, the ground sample, the volume's area of interest and zoom use. `georeferencePoint` in code. In the volume, the ground along the line of sight from E to the content centre, which moves from C₀ toward C₁ as the map tilts. In the immersive space, the ground beneath C₀ as placed level, carried by the tilt. |
| **Full tilt** | The tilt a host applies at full tilt weight: 90° in the immersive space; 70.6° in the volume, which points the ground below the camera at C₁. |
| **Placement ground** | The estimated ground height that sets the scale (§7). |
| **Room placement** | A rigid transform (translation and yaw) from the map frame to the reference space. Only the user and the system change it (§10). |
| **Georeference** | Which world point sits where in the map frame, with what scale and rotation (Cesium's term). |
| **Area of interest** (AOI) | The geographic square eligible for streaming. Its centre is the streaming anchor. |
| **LOD viewpoint** | The frustum cesium-native selects detail for. |

## 3. Concepts

### 3.1 The camera is the state

Navigation stores one camera pose. A focus, radius, scale and view centre may be useful to a presentation style, but they're derived from the camera, never stored separately.

### 3.2 The level baseline

In a room host the map frame's up is the room's up.

- **Untilted (τ = 0):** the world's local up at the ground beneath the camera is the room's up. The map is level with the floor, exactly, at any altitude.
- **Curvature:** far out you see the Earth's curve as a dome falling away from beneath you, as you would from a real aircraft.

### 3.3 View tilt belongs to the interaction mode

Tilt is a separate, explicit value τ, owned by the interaction mode, not derived from pitch, host geometry or altitude. Different modes choose it differently:

- **Drone (today).**
  - **Behaviour:** the base is always level. That could stay true at every altitude, but far enough away you'd need to look straight down to see anything, so the mode adds an optional tilt assist that tips the world toward you as you climb.
  - **The curve:** today's curve (0 below 50 km, rising to full weight by 500 km on a smoothstep in log altitude) is fairly arbitrary. It's a tunable setting, not a principle.
  - **Measured from the ellipsoid:** the weight follows the camera's height above the ellipsoid, so the tilt depends only on where the camera is, never on a ground estimate. Terrain shifts a 50–500 km curve negligibly.
  - **Per host:** the mode chooses a weight from 0 to 1; each host turns full weight into its own full tilt (§2).
- **Ground/globe toggle (Google Earth VR-style, future).**
  - **Two states:** ground (τ = 0) and globe (τ at full tilt). A button toggles between them, easing the tilt over a short transition.
  - **Altitude limits:** each state has its own range, and the ranges overlap. Ground mode has a maximum altitude, and globe mode a minimum one. To climb higher than ground mode allows, you toggle to globe first.
- **Fixed level (simplest).** τ = 0 always. Useful for checking the baseline, and for a fixed human-scale presentation style.

Whatever the mode, the tilt weight is part of the presentation, so switching host, jumping to a place or turning your head never changes it. **Not yet met above 50 km:** the hosts' full tilts differ (§2), so the same weight is a different angle in each host.

### 3.4 Pitch

- **Flat screen:** the camera's pitch is the render camera's pitch.
- **VR room host:** the viewer's head does the looking. Nothing a room host shows or does reads the stored pitch: not placement, tilt, zoom or gestures. Places still set it, gestures and moves carry it through, and tracks and saved views record it, so switching to a flat-screen view has a direction to use. Head tracking (#4) may later supply a real one.

### 3.5 Scale (adaptive scale presentation style)

The room host scales the world so the ground beneath the camera sits on the host's base plane: low in the volume, the origin plane in an immersive space.

- **Climbing** therefore reads as the ground dropping away beneath you.
- **Speed** is relative to height above ground, so movement covers the same apparent distance at any altitude.
- **Ground height:** this needs the ground under the camera. Placement uses only a settled, trustworthy estimate (§7).

### 3.6 Separate inputs

Streaming needs three things, each from its own source:

- **The georeference,** from the camera and the presentation style.
- **The LOD viewpoint,** from the viewer (design eye point today, tracked head later).
- **The area of interest,** from a policy.

Each of "stream around the viewer", "stream ahead" and "stream around what's shown" is a configuration of these, not a redesign (§8).

## 4. Spaces and types (summary)

```
reference space ──room placement⁻¹──▶ map frame ──georeference⁻¹──▶ world (ECEF)
```

- **ECEF:** all geo maths in double.
- **Anchor frame A** (x east, y up, z south at the streaming anchor): where the bridge places tiles.
- **Map frame:** where host geometry and gestures live.
- **Reference space:** the host's origin.

The tiles root is always `georeference ∘ ecefFromAnchor(streaming anchor)`, composed in double. It follows whichever anchor the streamer is on, live or held.

The core types live in `Sources/Navigation/`: `CameraPose`, `NavigationState` (movement heading and heading link), `Geodesy` (with a hit-or-miss surface query), `HostGeometry`, `Georeference`, `RoomPlacement`, `StreamingInputs`, `AOIPolicy`, ground estimates, operations and the control styles. Field-level detail is in the code; this document keeps to the rules.

## 5. Room host placement (adaptive scale)

Both room hosts use this (`EyeLevelModel.framing`). It replaces revision 5's ray-and-placement-point construction.

**Inputs:**

- camera X with heading ψ;
- the host's design eye point E, base plane height y_g and full tilt;
- the camera's height above ground, `agl` (from the placement ground);
- the tilt weight w, chosen by the interaction mode (§3.3).

**Untilted (w = 0):**

1. **Scale:** s = (E.y − y_g) / agl.
2. **Rotation:** yaw only. The level frame at the ground beneath the camera maps to the room with up → up and the camera's heading → −z (away from the viewer).
3. **Translation:** the camera lands on E. The ground beneath it then lands at (E.x, y_g, E.z), on the base plane.

**Tilted (w > 0):** rotate by w × the host's full tilt about the room's horizontal right axis **through E**, after the untilted placement. The camera stays on E at every tilt, and the ground below comes up toward straight ahead. (Revision 6 pivoted about the content centre, which moves the camera off E; the immersive space dropped that after recorded tracks showed it, and the volume now does the same.)

**Shown region:** half-width ρ = contentHalfWidth / s, used by the gesture slab, AOI and ground sampling.

**Properties this guarantees:**

- At w = 0 the map is exactly level, in every host, at any altitude.
- Switching hosts changes s (each host's eye is at a different height) and where content sits, but never the tilt weight.
- Pitch has no effect.
- No surface intersection is needed to place the world, so there's no horizon miss case for placement.

**Known costs:**

- **Pinching between 50 and 500 km:** a pinch changes height, which changes the tilt, which swings the ground about E. The grabbed point can't stay exactly under the hand: about 8–12 cm in the volume for ×1.6 at 120 km. Revision 5's volume, which pivoted near the content, was off by 0.5–4.6 cm.
- **The volume:** E is in front of the box, so the ground beneath the camera is outside what's shown, and climb, turn and speed pivot on it. Far out, the box's floor cuts the tilted globe (as revision 5's did).

## 6. Surfaces and the horizon

`Geodesy.intersect` returns hit, miss or invalid ray, against a scaled ellipsoid at a given height. Hits are refined with a bounded iteration, and every result is finite.

- **Callers decide what a miss means.** A pointer or pivot keeps its last value, uses a declared fallback, or declines.
- **The horizon pitch limit (`AdaptiveModel.pitchLimit`)** is only for modes that need a view ray to meet the ground: a flat-screen orbit pivot, say. Nothing calls it now.

## 7. Ground estimates

There are two estimates, with different jobs and different trust requirements.

| | **Placement ground** | **Camera ground** |
|---|---|---|
| Used for | Scale and where the map sits (§5) | Speed, minimum and maximum altitude |
| Source | The 3×3 `sampleHeightMostDetailed` across the shown region, around the view centre, once motion settles (lowest hit). Skipped when the shown half-width is 50 km or more | Rendered-tile height ranges, only from tiles no wider than max(2·agl, 500 m) |
| Updates | On settle and after gestures, eased. The first sample after a place jump moves the camera with the ground instead | Every frame, eased |
| While held or during a gesture | Frozen | Continues |
| Can move the view? | Yes, so it must be stable | Never |

**One placement ground.** There used to be two (the surface the view ray met, and a lower envelope that far out followed the Earth's curve). Placement no longer uses a view ray, and the curvature envelope is gone. It once carried a −20.8 km estimate from the volume into the immersive space ([also/also-maps-apple#60](https://github.com/also/also-maps-apple/issues/60)).

**Open:** far out the sample doesn't run, so an estimate taken elsewhere can persist and still sets the scale. One idea: use the estimate near the ground and blend toward the ellipsoid as altitude grows.

**Lesson from stage 2.** Reading the placement ground from rendered tiles continuously made the view bounce:

- coarse tiles' lowest vertices can be kilometres below the real ground;
- each new value rescaled the map, which moved the LOD camera, which changed the tiles, which changed the value again.

**Rule:** nothing derived from the current tile selection may move the view continuously.

## 8. Area of interest and level of detail

| Policy | Centre | Half-width | Default for |
|---|---|---|---|
| `.georeference` | The view centre | ρ × region multiplier | The volume, which clips to the shown region anyway |
| `.viewer` | Ground beneath the viewer | 3 × agl, from 1 km to the horizon | The Mac window |
| `.forward` | Ahead of the viewer | Reach with a lead | — |
| `.blended` | Viewer near the ground, view centre higher up | Covers both | — |
| `.horizon` | Ground beneath the viewer | Out to the horizon plus a terrain allowance, optionally capped per altitude | The immersive space |

- **Outside the frustum:** cesium-native already uses a coarser screen-space error (Outer Detail) outside the frustum, and the AOI only bounds what's eligible.
- **LOD viewpoint:** the design eye point through the georeference, which in room hosts is the camera's position, looking at the view centre, until head tracking (#4).

## 9. Live and held tiles

A user-facing choice (Hold tiles in the debug panel, or X on a controller). Flying is identical either way.

- **Live:** the streaming inputs (anchor, AOI, LOD viewpoint) follow the camera each frame. They're applied in the same tick as the tiles root.
- **Held:**
  - the inputs are frozen and cesium-native keeps updating with them, so loaded detail stays and nothing new is requested;
  - zooming in magnifies what's loaded, and travelling reveals the edge of the held area;
  - limits stop travel at 1.5×, and climbing or zooming out at 3×, the held area;
  - the placement ground is frozen.
- **Releasing:** streams from the current camera in one tick. Nothing jumps.
- **Releases first:** going to a place, changing tile source or restoring a live state. Switching host keeps the hold.

## 10. Room placement

Map frame → reference space, rigid. It's independent of navigation: navigation never changes it, and it never changes the camera.

- **visionOS recentring:** this moves the immersive space's origin, and the map comes with it, so it needs no code. `onWorldRecenter` exists only for Compositor Services layers, not RealityView spaces.
- **Later controls:** a grab handle, "Place here" and "Reset".

## 11. Interaction (drone mode, today)

**Heading link.** Movement heading and view heading are linked in this mode: turning changes both.

**Keyboard and controller:**

- **Move:** 0.75 × agl per second along the movement heading.
- **Turn:** 60°/s.
- **Climb:** height changes by e^±1 per second of agl.
- **Zoom (`=` and `−`, RT and LT):** on flat screens, along the view. In room hosts, toward the view centre, leaving pitch alone; at a height limit it stops on its line rather than being pushed off it. In room hosts zoom only works below where the tilt starts: zooming out stops 1% short of 50 km above the ellipsoid, and above that (reachable by climbing) zoom does nothing. **This limit is a workaround, not a property of the world:** there's no model yet of zooming that works with the tilt assist, because the view centre zoom heads for moves as the map tilts. The limit also keeps a zoom out and back in close to where it started (within tens of metres on a 600 m view).
- **Faster:** ×3 with Shift or LB.
- **Y** faces north, and **X** toggles held tiles.

All rates are starting values for tuning.

**Tilt assist.** The current curve (§3.3), as a mode setting, can be switched off.

**Gestures.** Drag, pinch and twist compose into one anchored manipulation: the grabbed world point stays under the hand.

- With a level world, pinch scales about the grab point (an altitude change plus a horizontal shift) and twist turns about it. Drag moves horizontally.
- The solve is local, with a bounded correction for curvature. It's tested to under 1 mm.

**Places.** A place (centre, radius, heading) maps to a camera whose shown region is that radius in the current host, with the place as the view centre, tilted as its height gives. Every place in the library is below 50 km, so they frame level. A place sets the camera's pitch to look at its centre.

## 12. Persistence

View state version 2 stores:

- the camera, movement heading and heading link;
- the interaction mode and presentation style;
- the ground estimates;
- the host and room placement;
- the tile mode, with the held streaming inputs if held.

The tilt isn't stored: it follows from the camera. The one placement ground is written to both of the ground estimate's fields (`ray` and `envelope`), and restoring reads `ray`, since older states can hold a curvature envelope in `envelope`. Old focus-centric states are rejected with a clear message.

## 13. Implementation status and next steps

- **Stage 1 (done, `d715d51`):** the core types, the bridge LOD camera and AOI heading, the tiles root through the georeference, and the core test target.
- **Stage 2 (done, `5bc6e91`, fixes `ff2eb9e` and `1cb1bf4`):**
  - **In:** the camera as the stored state, model-flight controls, anchored gestures, speed from agl, held tiles, view state v2, and per-host place framing.
  - **Still on revision 5's rule:** placement from a view ray, with tilt derived from pitch.
- **Stage 2b (checkpoints `9dcad75`, `c63a61e` on `claude/volume-explicit-tilt-bcfcc9`, not merged):**
  - **Placement:** both room hosts by §5, sharing `EyeLevelModel.framing`; the volume's view-ray placement, nadir fallback and pitch assist are gone.
  - **Tilt:** the drone tilt assist's weight from the camera's height above the ellipsoid, in both hosts.
  - **Pitch:** not read by room hosts.
  - **Ground:** one placement ground; no curvature envelope.
  - **Zoom:** toward the view centre, below 50 km (§11).
  - **Places:** framed with the place as the view centre.
  - **Tests:** level at w = 0 in every host and across host switches and place jumps; pitch has no effect; tilt ignores the ground estimate; zoom's limits.
  - **Overlap:** conflicts with PR #59 (`camera-diagrams`) in `MapModel.swift` and `AdaptiveModel.swift`.
- **Next for room hosts:**
  - the immersive space's remaining uses of C₀ (gesture slab, ground sample, hold-tiles travel limit) on the design eye point instead; its view centre runs past the horizon far out;
  - gestures from the gaze ray rather than a flat slab ([also/also-maps-apple#61](https://github.com/also/also-maps-apple/issues/61));
  - a representation of direction better than heading, at least in operations ([also/also-maps-apple#65](https://github.com/also/also-maps-apple/issues/65));
  - later, separate control styles for the volume and the immersive space.
- **Stage 3:** remove the leftover old code (`LegacyMapping`, the turn-pivot setting) and update Tuning and the README.
- **Stage 4:** the macOS window on the core: the real camera, pitch as the render camera's, the `.viewer` AOI.
- **Later:**
  - the ground/globe toggle mode;
  - head-tracked LOD (#4);
  - Mac pointer input;
  - a fixed human-scale presentation style.

**Headset evaluation (not automated).** On the headset, judge the feel of:

- the tilt assist curve against a ground/globe toggle;
- perceived scale while climbing;
- host switches.

## 14. Open questions

1. **Drone tilt:** keep the assist curve as the default, or start the drone at fixed level and add the ground/globe toggle sooner?
2. **Tilt pivot:** about the design eye point keeps the camera on E, but a pinch while the tilt changes can't hold the grabbed point (§5). Acceptable, or does the pinch need to trade exact scale for holding the point?
3. **Zoom with tilt:** what should zoom do once the map tilts? Today it's limited to the untilted range.
4. **The volume's controls:** climb, turn and speed pivot on a point outside the box. Camera over the box centre, or volume-specific control styles?
5. **Ground far out:** blend the placement ground toward the ellipsoid with altitude?
6. **Ground changes while live:** today the camera stays put and the map eases. Would moving the camera with the ground feel better at all altitudes, not just after place jumps?
7. **Defaults for AOI and detail:** are `.horizon` and today's detail settings right for the immersive space?
8. **Held-tile limits** (1.5× travel, 3× climb).
