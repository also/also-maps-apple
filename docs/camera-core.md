# Camera-centric navigation core

Status: design for review, revision 6 (2026-10-26).

- **Implemented:** stages 1 and 2 (§13) are committed, with the room-host rule from revision 5, which tilted the map whenever the camera's pitch didn't match the host's eye line.
- **Changed here:** this revision replaces that rule (§5). The goals now come first (§1), and tilt is an explicit choice of the interaction mode (§3.3), never a side effect.

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

8. **Platform-neutral core.** The navigation maths is Foundation and simd only, tested on macOS without a scene (`AlsoMapsCoreTests`).
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
| **Design eye point** (E) | The assumed viewer position in a room host: in front of the volume, or where you stood when the immersive space opened. It isn't the tracked head. |
| **Head pose** | The real head (ARKit's `DeviceAnchor`), in immersive spaces only. Used for level of detail later (#4), never for placement. |
| **Reference space** | The host's origin: the volume's centre, or the immersive space's origin (the floor where the user stood when it opened). |
| **Base plane** | The horizontal plane the map's ground is placed on: low in the volume, or the immersive space's origin plane (y = 0). |
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
  - **The curve:** today's curve (0 below 50 km, rising to full tilt by 500 km on a smoothstep in log altitude) is fairly arbitrary. It's a tunable setting, not a principle.
- **Ground/globe toggle (Google Earth VR-style, future).**
  - **Two states:** ground (τ = 0) and globe (τ at full tilt). A button toggles between them, easing the tilt over a short transition.
  - **Altitude limits:** each state has its own range, and the ranges overlap. Ground mode has a maximum altitude, and globe mode a minimum one. To climb higher than ground mode allows, you toggle to globe first.
- **Fixed level (simplest).** τ = 0 always. Useful for checking the baseline, and for a fixed human-scale presentation style.

Whatever the mode, τ is part of the presentation, so switching host, jumping to a place or turning your head never changes it.

### 3.4 Pitch

- **Flat screen:** the camera's pitch is the render camera's pitch.
- **VR room host:** your head does the looking. The stored pitch doesn't affect placement. It only aims the LOD viewpoint until head tracking (#4) replaces it, and it's kept so that switching to a flat-screen or drone-gimbal view has a direction to use.

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

Replaces revision 5's ray-and-placement-point construction.

**Inputs:**

- camera X with heading ψ;
- the host's design eye point E and base plane height y_g;
- the camera's height above ground, `agl` (from the settled ground estimate);
- the view tilt τ;
- the tilt pivot C, a point on the host's ground: its content centre.

**Untilted (τ = 0):**

1. **Scale:** s = (E.y − y_g) / agl.
2. **Rotation:** yaw only. The level frame at the ground beneath the camera maps to the room with up → up and the camera's heading → −z (away from the viewer).
3. **Translation:** the camera lands on E. The ground beneath it then lands at (E.x, y_g, E.z), on the host's ground level.

**Tilted (τ > 0):** apply a rotation by τ about the room's horizontal right axis through C, after the untilted placement. The mode may also raise C toward the viewer as τ grows, as today's facing tilt does, so a fully tilted globe sits in front of you rather than below the floor. With τ = 0 none of this applies.

**Shown region:** half-width ρ = contentHalfWidth / s, used by the gesture slab, AOI and ground sampling.

**Properties this guarantees:**

- At τ = 0 the map is exactly level, in every host, at any altitude.
- Switching hosts changes s (each host's eye is at a different height) and where content sits, but never the tilt.
- No surface intersection is needed to place the world, so there's no horizon miss case for placement. The surface query remains for gestures, pointers and pivots (§6).

## 6. Surfaces and the horizon

`Geodesy.intersect` returns hit, miss or invalid ray, against a scaled ellipsoid at a given height. Hits are refined with a bounded iteration, and every result is finite.

- **Callers decide what a miss means.** A pointer or pivot keeps its last value, uses a declared fallback, or declines.
- **The horizon pitch limit (`AdaptiveModel.pitchLimit`)** is only for modes that need a view ray to meet the ground: a flat-screen orbit pivot, say. It's no longer part of room placement.

## 7. Ground estimates

There are two estimates, with different jobs and different trust requirements.

| | **Placement ground** | **Camera ground** |
|---|---|---|
| Used for | Scale and where the map sits (§5) | Speed, minimum and maximum altitude |
| Source | The 3×3 `sampleHeightMostDetailed` across the shown region once motion settles (lowest hit); the curvature envelope far out | Rendered-tile height ranges, only from tiles no wider than max(2·agl, 500 m) |
| Updates | On settle and after gestures, eased. The first sample after a place jump moves the camera with the ground instead | Every frame, eased |
| While held or during a gesture | Frozen | Continues |
| Can move the view? | Yes, so it must be stable | Never |

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
| `.blended` | Viewer near the ground, view centre higher up | Covers both | Immersive modes |

- **Outside the frustum:** cesium-native already uses a coarser screen-space error (Outer Detail) outside the frustum, and the AOI only bounds what's eligible.
- **LOD viewpoint:** the design eye point through the georeference, looking at the content centre, until head tracking (#4).

## 9. Live and held tiles

A user-facing choice (the airplane button, or X on a controller). Flying is identical either way.

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
- **Dolly (`=` and `−`):** along the view.
- **Faster:** ×3 with Shift or LB.
- **Y** faces north, and **X** toggles held tiles.

All rates are starting values for tuning.

**Tilt assist.** The current curve (§3.3), as a mode setting, can be switched off.

**Gestures.** Drag, pinch and twist compose into one anchored manipulation: the grabbed world point stays under the hand.

- With a level world, pinch scales about the grab point (an altitude change plus a horizontal shift) and twist turns about it. Drag moves horizontally.
- The solve is local, with a bounded correction for curvature. It's tested to under 1 mm.

**Places.** A place (centre, radius, heading) maps to a camera whose shown region is that radius in the current host, centred on the place, untilted.

## 12. Persistence

View state version 2 stores:

- the camera, movement heading and heading link;
- the interaction mode and presentation style;
- the ground estimates;
- the host and room placement;
- the tile mode, with the held streaming inputs if held.

This revision adds the view tilt τ and the tilt mode's state. Old focus-centric states are rejected with a clear message.

## 13. Implementation status and next steps

- **Stage 1 (done, `d715d51`):** the core types, the bridge LOD camera and AOI heading, the tiles root through the georeference, and the core test target.
- **Stage 2 (done, `5bc6e91`, fixes `ff2eb9e` and `1cb1bf4`):**
  - **In:** the camera as the stored state, model-flight controls, anchored gestures, speed from agl, held tiles, view state v2, and per-host place framing.
  - **Still on revision 5's rule:** placement from a view ray, with tilt derived from pitch.
- **Stage 2b (next, this revision):** replace room placement with §5.
  - **Placement:** yaw-only plus an explicit τ.
  - **Drone tilt:** τ from the drone mode's tilt assist, replacing the pitch-follows-altitude assist.
  - **Pitch:** removed from placement.
  - **Gestures and places:** the gesture solve and place framing redone for the level world.
  - **Tests:** τ = 0 is exactly level in every host and stays level across host switches and place jumps.
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
2. **Tilt pivot and raised centre:** today's facing tilt pivots on the content centre and raises it toward eye level. Is that the right behaviour for the globe state?
3. **Ground changes while live:** today the camera stays put and the map eases. Would moving the camera with the ground feel better at all altitudes, not just after place jumps?
4. **Defaults for AOI and detail:** immersive modes now stream more tiles. Are `.blended` and today's detail settings right?
5. **Held-tile limits** (1.5× travel, 3× climb), and whether "Fly" is the right name for holding.
