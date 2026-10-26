# Camera-centric navigation core

Status: design for review, revision 5 (2026-10-26). Nothing here is implemented yet.

Navigation today is **focus-centric**. `MapVolumeModel` stores a focus, a radius, a heading and an anchored ground height. Everything else is patched on top: the viewer pivot and its 50–500 km fade, the facing tilt, heading transport, and Fly's scene similarity. This document replaces that with:

- shared **navigation state**, with movement heading separate from viewing orientation;
- interchangeable **control styles** and **presentation styles**;
- separate **georeference**, **viewer pose** and **area of interest** inputs, each pure or a provider;
- a **room placement** that the user and the system own, kept apart from navigation.

It sits on the `TileStreaming` seam from #12.

## 1. Principles

1. **One navigation core, multiple styles.** Geographic position, movement heading and viewing orientation have explicit meanings independent of input bindings and presentation style. Today's controls are one style; drone flight, POI assistance and Mac pan/orbit/zoom can be other styles. Changing style should preserve the displayed view at the transition, then initialize any style-specific state such as an orbit pivot.
2. **Three separate inputs, not one ray.** The streaming code needs three things, and each comes from its own source:
   - the **georeference**, from navigation state and the presentation style;
   - the **LOD viewpoint**, from the viewer pose provider;
   - the **area of interest**, from a policy.
   
   Each strategy (AOI at the viewer, AOI ahead of the viewer, ground from the georeference) is a configuration of these, not a redesign.
3. **Room placement isn't navigation.** visionOS recentring and the user moving the map in the room change only the room placement. Navigation changes geographic state and control-style state. Neither touches the other.
4. **Tiles are live or held.** That's the one user-facing streaming choice (§10). It decides whether the streaming inputs follow the camera. The georeference and room placement are always ours.
5. **Everything is total.** Inputs are validated at the boundary; supported finite inputs have defined results, and invalid inputs produce explicit failure or retain the last valid state. There are no NaN transforms. Surface queries return hit-or-miss (§5).
6. **The core is platform-neutral.** It uses Foundation and simd only, so it can be tested without a scene: by the macOS unit-test target if §16's proposal is approved, otherwise by DEBUG self-tests.

## 2. Terminology

| Term | Meaning here |
|---|---|
| **Camera pose** | A geographic viewpoint: position and viewing orientation. It does not by itself define movement heading or physical world scale. |
| **Movement heading** | The direction used by forward/right movement controls, independently of where the head or virtual camera is aimed. |
| **Control style** | How input changes navigation state: flight, orbit/pan/zoom, or a coordinated POI flight, for example. |
| **Presentation style** | How the geographic world is mapped into physical viewing space, including scale and placement: adaptive model, fixed human scale or inspectable model (§4). |
| **Host** | The physical container and its fixed geometry: the volume, a floor N× immersive layout, or the macOS window (`HostGeometry`; today's `MapPresentation`, renamed `MapHost`). Independent of presentation style. |
| **Heading link** | Whether movement heading follows view heading (`linked`) or is independent. Set by the control style (§11). |
| **Design eye point** (E) | The assumed viewer position in the map frame: in front of the volume, or where you stood when the immersive space opened. It is *not* the real head. |
| **Viewer pose / head pose** | The real head. On visionOS that's ARKit's `DeviceAnchor` via `WorldTrackingProvider.queryDeviceAnchor(atTimestamp:)`, available only while an immersive space is open. |
| **Origin / reference space** | The space a host's content is attached to: the immersive space's origin on the floor, or the volume's centre. |
| **Room placement** | A user- and system-adjustable rigid transform from the map frame to the reference space (§9). |
| **Map frame** | Where the host geometry (E, C, the gesture slab) is defined. It equals the reference space while the room placement is identity, as it is today. |
| **Georeference** | Which world point sits where in the map frame, with what scale and rotation (Cesium's `CesiumGeoreference`). Rebasing the coordinate origin is *origin shifting*; changing display scale or orientation is a separate presentation-style decision. |
| **Georeference point** (G) | The world point the georeference is built around. In the adaptive model presentation style, it is where the virtual viewing direction meets the reference surface; it is optional for other styles. It is **not** where the user looks: at street level in floor mode it's a few metres ahead on the floor and may be hidden behind buildings. |
| **Placement point** (C) | The map-frame point where the georeference puts the (ground-adjusted) georeference point. G and C are different kinds of quantity: with ground lift, the transform maps the lowered point Ĝ to C; G itself is above it. |
| **Area of interest** (AOI) | The geographic square eligible for streaming. Its centre is the streaming anchor. |
| **LOD viewpoint / culling camera** | The view frustum cesium-native uses for screen-space error and frustum culling. |

## 3. Spaces, frames and types

### Spaces and frames

```
reference space ──room placement⁻¹──▶ map frame ──georeference⁻¹──▶ world (ECEF)
(origin, head pose)    (§9)        (E, C, slab)       (§4)          (pose, tiles)
```

| Frame | Axes | Use |
|---|---|---|
| ECEF | WGS84 Earth-fixed, metres, double | All geo maths in the core |
| ENU(p) | east, north, up at point p | Pose angles, local offsets |
| Anchor frame A | RealityKit axes at the streaming anchor: x = east, y = up, z = south | The bridge places every tile here (unchanged) |
| Map frame | y up, −z away from the design eye point | Host geometry, gestures |
| Reference space | The host's origin | Head pose, recentring |

RealityKit hierarchy: host anchor (reference space) → `placementRoot` (room placement) → `root` (map frame: gesture slab, markers) → `tilesRoot` (the georeference composed with the anchor frame).

### Core types

These live in `Sources/Navigation/`, which both targets compile.

```swift
/// A geographic viewpoint; movement heading and controller state are separate.
struct CameraPose: Codable, Equatable {
    var latitude: Double      // degrees
    var longitude: Double     // degrees
    var height: Double        // metres above the WGS84 ellipsoid
    var heading: Double       // radians clockwise from local north at the camera
    var pitch: Double         // radians: 0 level, −π/2 straight down, + up
}

/// Shared geographic state. Concrete style-specific state is owned separately.
struct NavigationState: Codable, Equatable {
    var camera: CameraPose
    var movementHeading: Double // radians clockwise from local north
    var headingLink: HeadingLink // set by the control style on activation
}

/// Whether movement heading follows view heading. Model flight uses `.linked`:
/// every change to camera.heading is applied to movementHeading too, and they
/// start equal. A drone style uses `.independent`.
enum HeadingLink: String, Codable { case linked, independent }

/// WGS84 helpers (geodetic ↔ ECEF, ENU bases) and the surface query (§5).
enum Geodesy {
    static func intersect(ray: Ray, surfaceHeight: Double) -> SurfaceHit
}
enum SurfaceHit { case hit(point: SIMD3<Double>, t: Double)
                  case miss }

/// Host geometry in the map frame. Fixed per host (volume, floor N×, window).
enum HostGeometry: Equatable {
    case room(designEye: SIMD3<Double>,        // E
              placementLevel: SIMD3<Double>,   // C₀: where G goes when the map is level
              placementDown: SIMD3<Double>,    // C₁: where G goes looking straight down
              contentHalfWidth: Double)        // map-frame metres: shown region, gesture slab
    case window(fovY: Double, aspect: Double)  // macOS: the render camera is the camera
}

/// World → map frame. Always ours, in either tile mode.
struct Georeference: Equatable {
    var scale: Double                 // map-frame metres per world metre
    var rotation: simd_quatd          // ECEF → map frame
    var translation: SIMD3<Double>    // map = translation + scale · rotation · ecef
    func map(_ ecef: SIMD3<Double>) -> SIMD3<Double>
    func ecef(map: SIMD3<Double>) -> SIMD3<Double>
}

/// Map frame → reference space. Rigid: translation and yaw.
struct RoomPlacement: Codable, Equatable { var translation: SIMD3<Double>; var yaw: Double }

/// Where the viewer's head is, in the reference space.
protocol ViewerPoseProvider { func viewerPose() -> RigidTransform }
// Fixed design viewpoint (synthetic, not a real head) · tracked head (DeviceAnchor, #4)

/// What streams. See §7.
enum AOIPolicy: Codable, Equatable {
    case georeference(regionMultiplier: Double)   // today's behaviour
    case viewer(reachPerAGL: Double)              // all around the viewer's nadir
    case forward(reachPerAGL: Double, lead: Double) // biased along the view direction
    case blended(…)                               // viewer near the ground → georeference high up
}

/// What cesium-native is told. Follows the camera while live, frozen while held.
struct StreamingInputs: Equatable {
    var anchor: StreamingAnchor   // AOI centre: geo point + height, frame A's origin
    var lod: LODCamera   // LOD viewpoint
    var regionHeading: Double          // rotation of the AOI square
    var streamingRadius: Double        // AOI half-width, world metres
}

/// StreamingAnchor and LODCamera are core-owned value types; TileStreaming adapts them.

/// A ground estimate over a footprint (§8).
struct GroundEstimator { var footprint, statistic, update … }
```

**Tiles-root transform.** The tiles root is always set to `georeference ∘ ecefFromAnchor(streaming.anchor)`, composed in double, then converted to a Float `Transform`. It uses whatever anchor the streamer is actually on: the current AOI centre when live, the frozen one when held. Because tiles are placed relative to an anchor that's either live or held, the anchor can sit anywhere (here, the AOI centre) without affecting where G lands.

### Changes to `TileStreaming` and the bridge

- **LOD camera.** `LODView` (an orbit around the anchor) becomes `LODCamera { position, direction, up (frame A), fovY, aspect }`. The bridge gets `viewPosition`, `viewDirection`, `viewUp`, `viewFieldOfView` and `viewAspect`. These replace `viewerDistance`, `viewHeading` and `viewElevation`.
- **AOI square.** It's still centred on the anchor, now rotated by a new `regionHeading` property. `focusRadius` is only used by today's sampler; it becomes a footprint parameter of that call (§8).
- **Holding.** `TileStreaming.isHeld` (§10).
- **Per-tile height ranges.** `CNTileMesh` gains `minimumHeight` and `maximumHeight`: ellipsoid heights of its vertices, computed in the load handler while positions are still on the CPU. A synchronous `heightRanges(inFootprint:)` returns the ranges of the most detailed *rendered* tiles covering a footprint, with no network (§8).

## 4. Georeference

The georeference is the world-to-map transform produced by the presentation style. Navigation and control styles do not depend on the particular construction below. Physical head movement must not cause a model to follow the head; an inhabited-world presentation style instead applies tracking as a local viewing offset at the geographic viewpoint.

### Presentation styles and perceived scale

- **Adaptive model** (the proposed room-host style below): altitude/range changes world scale so a useful region fits in the room. The initial goal is roughly equivalent UX to the existing table/floor map, not exact transform equivalence.
- **Fixed human scale** (future): one physical metre corresponds to one geographic metre, including eye separation and head translation. Ascending changes position, not world scale. A full-size Earth far away is geometrically representable, but room-scale translation produces negligible parallax at planetary distances.
- **Inspectable model** (future): explicit model size and placement allow walking around a globe. This intentionally feels like a nearby object rather than occupying a distant position in space.

Apparent size alone does not determine perceived scale. A small nearby globe and a full-size distant Earth can match from one central viewpoint while differing in stereo disparity and motion parallax. Changing scale can be visible with the head still, or during straight ascent/descent: nearby features shift differently between the eyes and vergence changes. Scale policy and its transitions are user-visible behavior, not an invisible LOD optimization. Apply world scale consistently to stereo and tracking; changing virtual eye separation alone is not the whole policy.

Google Earth VR documents “Fixed human scale” as staying human-sized at all altitudes, and its developers describe ordinary navigation as “scale-and-fly.” These establish the UX distinction, not its exact stereo implementation. See [official release notes](https://steamcommunity.com/app/348250/announcements/) and [The Making of Google Earth VR](https://history.siggraph.org/wp-content/uploads/2022/09/2017-Talks-Kaeser_The-Making-of-Google-Earth-VR.pdf).

The adaptive model is an initial implementation candidate. Evaluate whether coupling viewing pitch to model size and placement gives the intended experience before treating its equations as the core abstraction.

### 4.1 Room hosts (volume and floor hosts)

This section specifies the adaptive model presentation style. Before ground lift, a successful ray construction places the navigation viewpoint at the design eye point. Ground lift changes that relationship as described below. Other presentation styles need not use a forward-surface intersection.

Notation: X is the camera position (ECEF). ψ is the heading, θ the pitch. In ENU at the camera:

- f = (sinψ cosθ, cosψ cosθ, sinθ)
- r̂ = (cosψ, −sinψ, 0)
- û = r̂ × f

1. **Pitch limit.** θ is clamped to the horizon limit (§5.3), so a hit is the normal case.
2. **Georeference point.** G comes from `Geodesy.intersect(ray: X + t·f, surfaceHeight: h_ray)`. h_ray is the terrain height at G from the georeference ground estimate (§8), bounded to [−500 m, 9,000 m]. On a miss, retain the last valid model framing, or initialize framing about the camera nadir if none exists (§5.2). Do not continue the hit equations with an off-ray surface point. The range is r = max(|G − X|, 1 m).
3. **Placement point.** C(θ) = mix(C₀, C₁, w), where w = (θ₀ − θ) / (θ₀ + π/2), clamped to 0…1. θ₀ is the pitch from E to C₀.
   - C₁ is today's raised target: the volume's middle (y = 0), or eye height − 0.3 m on the floor. The globe then sits in front of you when you look straight down.
   - This blend is driven by the camera's pitch, which is state.
4. **Map-frame view ray.** u = normalize(C − E), with basis r̂ₘ = normalize(u × ŷ), ûₘ = r̂ₘ × u.
5. **Scale.** s = |C − E| / r.
6. **Rotation.** q maps the camera basis (r̂, û, −f) to (r̂ₘ, ûₘ, −u). Let θ_room = asin(u·ŷ), the pitch of u = C − E in the map frame. q guarantees exactly two things: the camera's forward f lands on u, and its right r̂ stays horizontal (no roll). The camera's local up at X therefore lands tilted from the map's ŷ by θ_room − θ, about r̂ₘ. Ground at the camera's nadir is level in the map frame only when θ = θ_room. Ground at G is tilted by a further γ ≈ r·cosθ/R, the central angle between X's and G's local up: about 0.1° at 10 km of range and 0.9° at 100 km. This tilt is the facing tilt, now derived from pitch.
7. **Ground lift.** Let Ĝ be G lowered along G's up by Δ = h_ray − h_env ≥ 0. h_env is the georeference ground estimate's envelope, measured along G's up, so it includes the Earth's curvature (§8). The translation puts **world point Ĝ at map-frame point C**: the lowest ground of the footprint is on the table or floor.
   - The camera then maps to E + λ, where λ = s·Δ·q(up_G). That's a few centimetres up close; far out it's today's curvature lift.
   - With Δ = 0, the camera maps exactly to E.

**Relationship to today.** The existing app scales and turns an anchor-relative map, lifts its lowest sampled ground above the floor, and tips distant views toward the viewer. Preserve those broad interaction goals. Exact old/new transforms, arbitrary Fly-state conversion and legacy saved-view restoration are not requirements.

The curvature drop moves out of the ray surface and into the adaptive model's ground lift. A deeply negative curvature envelope is useful for floor placement, but is not a meaningful surface for determining the viewing horizon.

### 4.2 Window host (macOS)

The RealityKit camera is the camera, and the georeference is camera-relative:

- s = 1;
- the camera entity sits at the origin with identity orientation;
- map = q_c⁻¹·(ecef − X), where q_c is (r̂, û, −f).

There's no ground lift and no placement point. Pitch is free up to +80°, and the horizon limit doesn't apply, because nothing here depends on a hit. Surface queries (cursor, AOI) use the same hit-or-miss function (§5).

## 5. Surface intersection and the horizon

### 5.1 Intersection

`Geodesy.intersect(ray:surfaceHeight: h)` intersects the ray with the **scaled ellipsoid** with semi-axes (a+h, a+h, b+h). That's a closed-form quadric: scale the axes to a unit sphere and solve a quadratic.

- **Inside the surface** (camera below it, possible with off-area held ground): take the positive root, so there's always an answer.
- **Hit:** refine toward constant geodetic height along the ray as the numerical contract below specifies.

**Numerical contract.** The quadric is an initial approximation to constant geodetic height. Refine a hit only while the height derivative is well-conditioned, using a bounded iteration count and explicit residual tolerance. A single Newton step is not assumed to achieve millimetre accuracy at grazing angles. Reject non-finite or zero-direction rays; test tangent and below-surface cases. The returned hit must remain on the forward ray with t ≥ 0.

### 5.2 Miss handling belongs to the consumer

A miss is a normal result: a viewpoint can look level or into the sky. It does not invalidate navigation.

- **Adaptive model framing:** preserve the last valid framing while the optional framing assist adjusts view pitch. On initial entry without a valid framing, construct finite nadir-based framing with a positive minimum range. Preserve position and movement heading. This fallback may temporarily depart from the requested view orientation; it must not claim that an off-ray surface point satisfies the hit construction.
- **Fixed-scale/window views:** continue rendering the requested view without an intersection.
- **Pointer/POI operations:** keep an existing pivot, use a declared plane/globe fallback, or decline the operation. A projected surface fallback is distinct from both a ray hit and the closest point on the ray.

Test continuity of each presentation style's transition; continuity of a fallback surface point alone does not establish continuity of the rendered transform.

### 5.3 Pitch limit (adaptive model framing only)

θ ≤ θ_lim = −(δ + m), where:

- δ = arccos(clamp((R_N + h_ray) / (R_N + h_cam), 0, 1)) is the horizon dip from the camera's height down to the **ray surface**. R_N is the prime-vertical radius at the camera; the margin covers its error.
- If the camera is at or below the ray surface, use δ = 0. Validate heights and positive radii before evaluating the formula.
- m is a margin, 8° by default (Tuning, 5–10°).

| Camera above the ray surface | δ | θ_lim (m = 8°) |
|---|---|---|
| 1 km | 1.0° | −9.0° |
| 24 km | 5.0° | −13.0° |
| 98 km | 10.0° | −18.0° |
| 410 km | 20.0° | −28.0° |
| 2,600 km | 45.0° | −53.0° |

**Where it applies:** the adaptive model style limits its framing pitch when entering the style and after movement, climb, manipulation or restored-state validation. It may ease the viewing adjustment, with §5.2 supplying valid framing during the transition. This is a presentation-style constraint, not a universal constraint on vehicle heading, head orientation or navigation. Other styles can look toward or above the horizon.

**Range bound.** With the limit, the range is at most about (h_cam − h_ray)/sin(m) ≈ 7.2× the height above the ray surface. The scale is therefore bounded and changes smoothly with pitch; there's no near-grazing blow-up.

**Pitch policy.** The pitch policy (§12.3) always stays inside the limit. At 50 km its target is −27° to −33°, while the limit is −15.1°. At 200 km it's ≤ −40°, while the limit is −22.2°.

### 5.4 Tests (stage 2)

- At the dip ± 1e-6 rad, at 24 km/−5°, at 410 km/−20° and at 2,600 km/−45°: the result is a hit or a miss, never NaN. The adaptive framing transition remains finite and continuous; other styles preserve the requested viewing direction on a miss.
- With the camera below the surface: the positive root.
- The cursor ray (window) at the horizon and pointing at the sky: an explicit miss handled by the requesting operation.

## 6. Viewer pose and LOD viewpoint

- `ViewerPoseProvider` gives the head pose in the reference space:
  - **`.designEyePoint` (default today):** the fixed E, looking at C. Convert it to reference space through room placement; it is a synthetic viewpoint, not a tracked head.
  - **`.tracked` (#4):** the `DeviceAnchor`, in immersive spaces only. The volume keeps the design eye point.
- **LOD viewpoint** = the viewer pose → map frame (room placement⁻¹) → world (georeference⁻¹), with a 60° fov.
  - With the design eye point, this coincides with camera X only when ground lift is zero. With lift, derive LOD from the displayed design viewpoint rather than assuming coincidence.
  - With tracking, the LOD follows your real head while the georeference, and so the world, stays put.
- **Window host:** the viewer pose is the camera; there's no provider.

## 7. Area of interest

The AOI policy decides the streaming anchor (the AOI centre), `regionHeading` and `streamingRadius`. Inside the AOI, cesium-native already blends in-view and out-of-view detail: `maximumScreenSpaceError` for the frustum, `culledScreenSpaceError` (Outer Detail) outside it. The AOI only bounds what's eligible.

| Policy | Centre | Half-width | Notes |
|---|---|---|---|
| `.georeference(regionMultiplier)` | G | ρ · multiplier, where ρ = contentHalfWidth / s | Today. The volume uses it, since the volume clips to the shown region anyway. |
| `.viewer(reachPerAGL)` | Ground under the viewer's nadir | clamp(k·agl, 1 km, horizon) | Provides coverage around the viewer when turning; loading can still leave gaps. |
| `.forward(reachPerAGL, lead)` | Viewer nadir + lead·reach along the view heading | reach | Frustum with margin; fewer tiles behind you. |
| `.blended` | mix(viewer nadir, G, w(agl)) | Enough to cover both the viewer disc and ρ around G | The floor-mode default. w = smoothstep over log(agl) from 1 km to 50 km. |

- Each host picks a default (volume `.georeference`, floor `.blended`, window `.viewer`), and Tuning can override it.
- The listed strategies are just these values:
  - "AOI at the viewer" is `.viewer`;
  - "AOI kept ahead including the look direction" is `.forward`;
  - "based on the origin or georeference" is `.georeference`.
- The anchor is the AOI centre, at the georeference ground estimate's height, so streamed tiles are near frame A's origin for precision.

## 8. Ground estimation

`GroundEstimator` is one type used twice, with its own parameters for each use. Neither use is the AOI (usually larger) or the viewer pose.

| | **Georeference ground** | **Camera ground** |
|---|---|---|
| Used for | h_ray (terrain at G) and h_env (envelope); the ground lift (§4.1) | Height above ground (agl): speed, altitude limits, aglMin, terrain following |
| Footprint | h_ray: only G's column. h_env: disc around G, radius 0.8·ρ, scaling with the shown region (today's 3×3 reach) | Disc around the camera's nadir, radius max(20 m, 0.05·agl) |
| Statistic | h_ray: a representative height at G from tiles covering G, optionally refined by a central sample. h_env: the footprint statistic, either minimum (default), low percentile (p10), or later a morphological opening (erode, then dilate) to ignore isolated pits; constrained h_env ≤ h_ray | Minimum |
| Measured along | h_env: G's up, so the curvature drop is included: a sample at distance d counts as height − d²/(2R) | Ellipsoid normal at the nadir |
| Sources | (1) Rendered-tile height ranges over the footprint, synchronous, no network. (2) Optional refinement when motion settles: today's 3×3 `sampleHeightMostDetailed` (may load tiles) | Rendered-tile height ranges only |
| Update | 4 Hz while moving and once on settle. Hysteresis: ignore changes < max(0.5 m, 0.002·ρ). Eased with 95% in 0.5 s (today's `easeFocusHeight`) | Every frame, eased over about 0.3 s |
| While held | Frozen: no samples, no easing, no re-anchoring | Continues on the frozen tile set |
| Nothing covers it | Hold the last value; the ellipsoid if none | Hold the last value |

**Per-tile height ranges.** Use the most detailed rendered tiles covering the footprint. Their minimum is a low-height approximation over the tile, not necessarily the street or surface directly under the camera. The sampled refinement keeps today's "lowest of 3×3" behaviour, which stops terrain sinking through the volume floor.

**Source and timing.** Before any tiles load, use height 0 above the WGS84 ellipsoid. Thereafter hold the last valid estimate when coverage is missing. Use the previous update's h_ray to find G, then query geometry for the next update; there is no recursive terrain solve within the mapping. Define h_ray separately from the footprint minimum: initially use a representative height from tiles covering G, optionally refined by a central height sample. Compute h_env from the footprint's low-height envelope in G's local up frame and constrain h_env ≤ h_ray. At planetary ranges use the existing analytic curvature envelope rather than an unbounded local d²/(2R) approximation.

**Scope.** These estimates support presentation-style placement, speed and altitude limits. aglMin is relative to estimated ground; collision detection, mesh-clearance guarantees and per-frame raycasting against loaded triangles are not requirements. Keep the existing low-sample floor-placement behavior as the UX reference.

**Camera fixed.** When the georeference ground changes, the **camera stays put**. Only G, the scale and the lift ease (open question 1).

**Terrain following** (setting, default off): after a move, height = camera ground + the agl held at the start of the move.

**Limits:** `altitudeLimit` (§13). aglMin is 55 m for room hosts (today's 50 m radius) and 1.5 m for the window. While held, §10.4 also applies.

## 9. Room placement

**Map frame → reference space, a rigid transform (translation + yaw).** It's distinct from the georeference, and only the user and the system change it.

**visionOS recentring.**

- Recentring (holding the Digital Crown) moves the immersive space's origin to the user. Everything hangs under that origin, so the map comes with you, and the design eye point stays right relative to you. That honours recentring without any code.
- The volume is repositioned by the system.
- `onWorldRecenter` exists in this SDK (XROS 27.0, `WorldRecenterPhase` began/ended), but only on `CompositorContent`, the Compositor Services layers. A RealityView immersive space can't attach it.
- If we need a notification later (say, to reset the room placement), the tracked viewer provider can detect the origin jump from the `DeviceAnchor`. Nothing in this design requires one.

**App control** (stage 3, optional):

- a grab handle at the map's near edge: drag translates and twist rotates the room placement;
- **Place here:** puts the map frame so the design eye point is at your current head pose, using the tracked provider, or so the map is in front of you otherwise;
- **Reset placement:** identity.

**Composition.**

- Input: gesture locations (reference space) → map frame (placement⁻¹) → world (georeference⁻¹).
- The viewer pose passes through the same chain (§6).
- Recentring, placement and head tracking all compose without touching the camera pose, and navigation never edits the placement.

## 10. Tiles: live and held

This is a user-facing option, today's Fly toggle (airplane button, X on a controller). Flying is identical either way.

| | Live | Held |
|---|---|---|
| Camera pose, georeference, room placement | Ours, every frame | Ours, every frame — identical |
| Streaming inputs (AOI, anchor, LOD viewpoint) | Recomputed from the camera and viewer pose | Frozen at the moment of holding |
| Detail | Refines as you approach | Frozen view request; zooming in does not request closer detail |
| Coverage | The AOI follows the policy | The loaded area stays put; you can fly past its edge |
| Georeference ground | Sampled and eased | Frozen |
| Camera ground (speed) | From rendered tiles | From the frozen rendered tiles |

### 10.1 Responsibilities in each mode

- **Live.** Each change recomputes `StreamingInputs` and pushes them in the same tick as the tiles root, before `streaming.update`, so placements and the root never disagree for a frame.
- **Held.** Only the georeference and room placement change. The tiles root keeps using the frozen anchor, so the loaded tiles stay correct wherever the camera goes. They're placed in full 3D from ECEF.

### 10.2 Explicit hold in cesium-native

- `TileStreaming.isHeld = true` snapshots the inputs and ignores new ones. The model owns the authoritative held snapshot for persistence (§14); TileStreaming consumes that snapshot rather than independently capturing another one.
- `update(deltaTime:)` keeps calling `streamer.update` with the frozen view every frame, as Fly does today. Main-thread tasks keep being dispatched, and in-flight loads may finish and refine the rendered selection. This preserves existing Fly behavior; it does not pin an exact tile set or promise unchanged cache contents.
- No georeference ground samples are requested.

### 10.3 What the user sees while held

- **Zooming in or descending** magnifies the loaded geometry, which can get blurry; approaching it does not request finer detail, although outstanding loads may finish. aglMin still applies. The status line says "Tiles held · view requests frozen".
- **Zooming out, climbing or travelling** reveals the edge of the held AOI square, and empty background beyond it.

### 10.4 Limits while held

These are soft clamps on the operation's result:

- **Travel:** G (room hosts) or the nadir (window) stays within 1.5 × the held half-width of the frozen anchor.
- **Climb:** ρ ≤ 3 × the held half-width.
- **Descend:** aglMin over the camera ground.
- The pitch limit (§5.3) uses the frozen h_ray.

### 10.5 Precision

- Tile placements are Float offsets from the frozen anchor, computed in double by the bridge. Tiles intersecting the held AOI may extend beyond its edges, as they do today. Preserve tile-local mesh vertices and double-precision per-frame anchor-relative placement; do not assume clipping bounds every vertex to the AOI.
- The camera's maths is double throughout.
- The travel limit keeps the camera near the tiles.

### 10.6 Holding and releasing

- **Hold:** freeze the inputs. Nothing moves, since the root is the same function of the same anchor.
- **Release:** in one tick, push inputs from the current camera and viewer pose, and switch the root to the new anchor. It's seamless because the camera never jumped. Detail and coverage then stream in, and a georeference ground refresh is requested.
- **Actions that release first:** going to a place, changing the tile source, or restoring a live state.
- **Actions that keep the hold:** switching host or presentation style, and moving the room placement.

## 11. Operations

These are pure operations with explicit navigation state and context (ground estimates, limits and held coverage). A control style composes them; presentation-style pitch constraints are not applied globally. In drone controls, movement heading is independent of viewing direction. Earth supplies local up/down: climb changes ellipsoid height and horizontal travel follows the globe. This does not require a motor or falling-body simulation.

The initial model controls may link movement heading and view heading for familiar behavior. That linkage is explicit: `NavigationState.headingLink`, set by the control style when it activates, not a permanent identity in CameraPose. Model flight sets `.linked`. Core state should include a movement heading and a view orientation relative to a local navigation frame; tracked head offsets compose with that orientation. Orbit controls additionally own a pivot. CameraPose describes the base view; tracked head offsets are applied separately. If future styles need roll or another orientation representation, extend this value without changing streaming or input contracts. Validate the type boundary with the two-style prototype in §15.

"View heading" is `camera.heading`. Under `.linked`, every change to the view heading below is also applied to `movementHeading`; under `.independent` it isn't.

| Operation | Effect |
|---|---|
| `climb(by Δh)` | `height += Δh`, clamped to [camera ground + aglMin, camera ground + altitudeLimit] and, while held, §10.4. Latitude, longitude and both headings are untouched. Viewing/framing assists may subsequently adjust view pitch without changing movement heading. |
| `turn(by Δψ)` | View heading += Δψ, mod 2π, in place; movement heading too while linked. |
| `faceNorth` | View heading = 0; movement heading = 0 too while linked. Under `.independent`, a style may bind a separate "movement north". |
| `pitch(by Δθ)` | Changes view pitch within the selected style's range; the adaptive model applies its own framing limit. |
| `move(forward:right:)` | `destination(from: camera, bearing: movementHeading + atan2(right, forward), distance: √(f² + r²))`. Both headings are transported by `GeoMath.bearingChange`, so flying over a pole continues. |
| `dolly(by k)` | Moves X along f by a fraction k of the range r (zoom along the view). |
| `orbit(by Δψ)` | Rotates X about the vertical through G and adds Δψ to the view heading, so the camera keeps facing the pivot; movement heading too while linked. Unbound by default. |

### 11.1 Anchored manipulation

**Goal.** Keep the grab point W₀ (a world point) under map-frame point P while the view scales by k, turns by Δψ and translates with the hand.

- **Window/fixed scale.** Keep the world transform rigid. Pinch drives dolly toward a pivot, with a screen-space anchor constraint; rotate drives orbit or view rotation as selected by the control style. A scaled similarity cannot be extracted into a rigid camera with equivalent parallax for arbitrary 3D geometry.
- **Room hosts.** The scale is derived, so solve for the pose whose *derived* georeference satisfies the target:
  1. ψ' = ψ₀ − Δψ (view heading; movement heading too while linked). θ' comes from the pitch policy when `pitchFollowsAltitude` is on. When it's off, θ' is the current pitch. Either way, θ' is clamped to θ_lim at the new height. s' = k·s₀.
  2. r' = |C(θ') − E| / s'.
  3. The offset d = P − C(θ'), less the lift, maps to the world tangent offset w = q'⁻¹(d)/s' at W₀. So G' = `GeoMath.offset(W₀, east: −w.e, north: −w.n)`, on the ray surface.
  4. X' = G' − r'·f(ψ'_G', θ'). Convert to geodetic, and transport the heading back to the camera's nadir. ψ' and θ' are targets in ENU at the camera, but f is built in ENU at G'. The two frames differ by the central angle γ ≈ r'·cosθ'/R, so the resulting camera's pitch is off by up to γ: 0.1° at 10 km of range and 0.9° at 100 km.
  5. Iterate to an explicit error tolerance with a bounded iteration count. Each pass corrects both residuals: the anchor error e = P − T'(W₀), by nudging G' by −q'⁻¹(e)/s'; and the orientation error, measured as the heading and pitch of f at X', by adjusting the angles used at G' in step 4. An unconstrained successful solve asserts |e| < 1 mm. If limits prevent convergence, return a constrained result or retain the last valid pose; do not promise exact anchoring after a conflicting clamp.
- P is always a hit on the gesture slab, which lies on the content surface, so the ground isn't asked to leave the table.
- Gesture locations arrive in the reference space and pass through the room placement⁻¹ first.

## 12. Input mapping

### 12.1 Gestures (visionOS)

There's one `Manipulation` per gesture session, holding W₀, P_start, k, Δψ and the hand translation, with one solve per update.

| Gesture | Grab point | Contribution |
|---|---|---|
| Drag | Drag start on the slab | Translation = hand movement, projected onto the content surface |
| Pinch (`MagnifyGesture`) | Its `startLocation3D` (to verify) | k = magnification |
| Twist (`RotateGesture3D`, y-axis) | Its `startLocation3D` (already used) | Δψ = yaw (view heading; movement heading too while linked) |

Pinch and twist happen **around where you pinched**.

### 12.2 Keyboard and controller (both platforms)

These are the initial model-flight bindings, with `headingLink = .linked`. They operate at the navigation viewpoint, which can differ from the displayed design eye after lift. Alternative control styles can use other bindings and pivots.

| Input | Operation | Rate |
|---|---|---|
| WASD / arrows, left stick | `move` (along movement heading) | 0.75 · agl_eff m/s |
| Q E, right stick x | `turn` (view heading; linked, so movement heading too) | 60°/s |
| R F, right stick y | `climb` | dh/dt = ±1.0 · agl_eff |
| = −, RT LT | `dolly` | dr/dt = ∓1.0 · r |
| Shift, LB | ×3 | — |
| Y | `faceNorth` (both headings, since linked) | — |
| X | toggle live / held tiles | — |

agl_eff = max(agl, 10 m). All three rates are starting values for tuning, matched to today's:

- **Move:** ρ ≈ 0.91·agl, so today's 0.8 ρ/s ≈ 0.73 agl/s.
- **Climb and dolly:** today R/F and =/− both scale the radius by e^{±1} per second (`zoomRate`). At fixed pitch, agl and range are both proportional to the radius, so 1.0·agl and 1.0·r reproduce that.

### 12.3 Pitch policy

`pitchFollowsAltitude` is an optional viewing/framing assist for the adaptive model, initially on. It is not intrinsic to geographic movement or to all room presentations.

- After each climb, dolly or pinch, and on a host switch, pitch eases toward θ_target(agl), anchored at C.
- θ_target is the host's θ₀ up to 50 km agl. Above that, it goes to −90° on a smoothstep in log(agl) by 500 km.
- The result is always clamped to θ_lim.
- A manual pitch input switches the policy off until the next place jump (keys: open question 4).

### 12.4 Pointer (macOS, later step)

- **Scroll:** dolly toward a cursor hit or the existing orbit pivot; on a miss use the controller's declared fallback (§5.2).
- **Drag:** keep W₀ under the cursor ray. Use a plane at W₀'s height up close, and a globe drag (rotation about the Earth's centre) on the sphere through W₀ when the plane is ill-conditioned or the ray misses.
- **Trackpad pinch and rotate:** §11.1's window case.

### 12.5 Alternative styles and switching

A future drone style separates movement heading from head/view direction. Plain climb remains straight up. Optional viewing tilt can keep Earth ahead during ascent; a POI “dronie” instead coordinates backward/upward travel and viewing to keep a place framed. These are assists, not changes to the meaning of climb.

A Mac style can use familiar globe drag, orbit, pan and cursor zoom. Switching control styles preserves the displayed viewpoint initially and initializes extra state (such as a pivot) without a jump. Switching presentation styles may intentionally change framing and perceived scale; define an eased transition and preserve geographic navigation position unless explicitly requested otherwise. Switching to an inspectable globe need not maintain the illusion of occupying a distant point in space.

Alternative styles are extension requirements, not a requirement to implement every style in this migration. Prototype two materially different styles early to verify the boundaries.

## 13. Settings and Tuning

- **`keyboardTurnPivot` is removed;** the decoder ignores it.
- **`zoomOutLimitKilometres` becomes `altitudeLimitKilometres`:** ×1.1, so 20 km becomes 22 km; log slider 20–10,000 km.
- **New settings:**
  - `pitchMarginDegrees` (8);
  - `aoiPolicy` (per-host default; override);
  - georeference ground statistic (minimum / p10);
  - `terrainFollowing` (off);
  - `pitchFollowsAltitude` (on).
- **Debug markers:**
  - red at the camera's nadir;
  - blue at G;
  - green at the AOI centre, with its square outlined;
  - yellow for the held AOI while held.
- **Room placement controls** (§9).
- **README and Tuning text** are rewritten in stage 3.

## 14. Persistence

`MapViewState` gets a `version`:

```json
{
  "version": 2,
  "camera": { "latitude": 37.78, "longitude": -122.40, "height": 812.0,
              "headingDegrees": 0, "pitchDegrees": -32.9 },
  "movementHeadingDegrees": 0,
  "controlStyle": "modelFlight",
  "presentationStyle": "adaptiveModel",
  "groundEstimate": { "ray": 4.5, "envelope": 1.0 },
  "host": "floor5x",
  "roomPlacement": { "translation": [0, 0, 0], "yawDegrees": 0 },
  "tiles": "held",
  "heldStreaming": { "anchor": { … }, "lod": { … }, "regionHeading": 0, "streamingRadius": 600 },
  "settings": { … }
}
```

- **Restoring** validates navigation, style-specific state and estimates, then initializes the selected host and presentation style safely. Save the host, the control-style and presentation-style identifiers, movement heading and viewing orientation as these types are finalized. New-format saved views remain supported.
- **A held state restores** by streaming with `heldStreaming` and holding at once, to recreate the held view request. Loaded content may differ; this is not an exact tile-set snapshot.
- **Legacy saved views are unsupported.** Reject old focus/radius/Fly state with a clear message. No v1 converter or retained legacy mapping is required. Saving and restoring the new state remains a feature.
- **Places** (centre, radius, heading) map to a pose framing the place in the *volume's* geometry: pitch = θ_target(agl), clamped; s = 0.5/radius; r = |E − C|/s; camera = centre − r·f. The `MAPVOLUME_LAT/LON/RADIUS/HEADING` overrides go through the same framing.

## 15. Migration stages

One commit per stage. Each commit's staged contents get built for both targets first.

### Stage 1: establish the seam and validate style boundaries

- **New code.** Add `Sources/Navigation/`: `CameraPose`, `NavigationState` (with `HeadingLink`), `Geodesy` (with hit-or-miss), `HostGeometry`, `Georeference`, `RoomPlacement` (identity) and `StreamingInputs`. Add it to both targets.
- **Bridge.** `LODCamera` and `regionHeading` in the bridge. Today's orbit is converted to the identical camera vectors (visionOS model and macOS `StaticMap`).
- **Model wiring.** `applyFocus` and `applyFly` become one path:
  - it builds the georeference from the legacy state (h_ray = h_env = `focusHeight`, the legacy mapping extracted as a function);
  - the streaming inputs use the legacy AOI (`.georeference`) and the legacy LOD orbit, skipped while Fly holds them, as today;
  - it sets `tilesRoot = georeference ∘ ecefFromAnchor`;
  - it adds `placementRoot` as identity.
  
  `flyRoot` folds into the composition.
- **Verification:** compare representative locations and scales (volume, floor5x, city, regional and globe views, live and Fly) for roughly equivalent movement, turning, zooming and floor placement. Do not require exact legacy transforms or captured-state conversion.
- **Two-style prototype (pure core, tests only):** implement model flight and a minimal orbit/pan/zoom style as pure functions over `NavigationState` in `Sources/Navigation/`, with no UI, app wiring or Mac input. Exercise both with scripted inputs, through the §16 target if approved or DEBUG self-tests otherwise, against the shared navigation, presentation-style and streaming-input contracts. Check:
  - independent movement and view headings under `.independent`;
  - linked headings under `.linked`;
  - continuity of the initial view when switching between the two styles.
  
  App use of these styles comes in stage 2 (visionOS) and stage 4 (macOS).

### Stage 2: navigation state and policies become authoritative

- **Model.** `MapVolumeModel` stores NavigationState, selected styles and their state, ground estimates, tile mode and the authoritative held snapshot.
- **Wired in:** the operations with the pitch limit, `Manipulation`, the pitch policy, both `GroundEstimator`s (bridge height ranges; ray and envelope split), the AOI policy with per-host defaults, the viewer pose provider (`.designEyePoint`), held limits and the new rates.
- **Fly** becomes held tiles. New-format saved views, without legacy conversion; places framed (§14).
- **Expected changes:**
  - explicit altitude;
  - anchored pinch and twist;
  - speed from agl;
  - pitch instead of tilt;
  - no fade;
  - the LOD viewpoint is the design eye point through the georeference (closer and lower than today's 1.2 m at 45°);
  - floor modes stream around the viewer at low altitude;
  - the curvature drop moves into the lift.
- **Expectation checks** (unit tests if §16 is approved, otherwise DEBUG self-tests):
  - climb keeps latitude and longitude (1e-9°) and changes agl by exp(rate·t), leaving movement heading unchanged; adaptive framing may separately steepen view pitch at its limit;
  - pinch k at P keeps W₀ within 1 mm of P; so does pinch + twist + drag together; so does each after a non-identity room placement;
  - moving forward from 89.9°N at heading 0 for 50 km ends near 89.65°N, longitude +180°, heading ≈ π, and continues away from the pole;
  - turn keeps the camera's position;
  - §5.4's horizon and grazing tests;
  - one input sequence gives the same pose live and held (within held limits);
  - hold and release leave every tile's map-frame transform unchanged (1e-4 relative);
  - held travel stops at 1.5×;
  - changing the room placement leaves the camera pose unchanged, and changing the camera leaves the placement unchanged;
  - new-format save/restore round trips preserve navigation and style state; legacy states are rejected clearly;
  - control-style switches preserve the initial displayed viewpoint; movement heading can remain fixed while viewing changes;
  - scale transitions are numerically continuous: along scripted straight ascent and descent, host switches and presentation-style switches, the georeference's scale, rotation and translation change by no more than a bounded step per frame, with no discontinuity.
- **In the simulator:** replay new-format states, scripted input (a temporary DEBUG driver), and screenshots, live and held, in the volume and floor modes.

### Stage 3: remove the old machinery and add room placement controls

- **Removed:** `farTilt`, `tiltedGroundPosition`, `tiltAngle`, `viewerPivotWeight`, `viewerGroundOffset`, `zoom(to:)`, `turn(to:)`, the Fly similarity (`flyScale`, `flyYaw`, `flyTranslation`, `flyRoot`, `flyAboutPivot`, `fly(with:)`, `resumeStreamingAfterFlying`), `radius`/`focus` state, `updateCurvatureAnchor`, `keyboardTurnPivot`.
- **Removed as well:** old saved-view decoding and any temporary legacy mapping used during stage 1. No permanent conversion layer.
- **Added:** the room placement grab handle, "Place here" and "Reset placement" (§9).
- **Updated:** `TuningView` (§13), the README (controls, live and held tiles, AOI, Tuning, view state), and `MapPresentation` renamed `MapHost`.

### Stage 4: macOS on the core

- `StaticMap` becomes `MapWindowModel`, with a `CameraPose` and `.window(fovY:aspect:)`. The camera entity and tiles root come from the georeference, and the LOD viewpoint is the real camera.
- AOI is `.viewer`.
- The start pose roughly frames today's location: the Ferry Building, heading 270°, 35° down, 2.5 km range.
- No Mac input yet.

Later, outside this work: the `.tracked` viewer pose provider (#4), and Mac pointer input (§12.4).

### Headset UX evaluation (not an automated check)

On a Vision Pro, after stage 2, judge what numbers and screenshots can't:

- perceived scale in stereo while still and during straight ascent and descent;
- whether pitch-coupled framing feels right (§4);
- scale transitions between hosts.

Tracked head translation joins this evaluation when #4 lands; it's out of scope here.

## 16. Testing infrastructure (proposal)

Add a `MapVolumeCoreTests` macOS unit-test target that compiles only `Sources/Navigation/`, with no cesium-native and no network. The stage 2 expectation checks and §5.4 become permanent tests (`xcodebuild test`). Simulator replays still cover streaming and visuals. The alternative is temporary DEBUG self-tests, removed before each commit.

## 17. Open questions for review

1. **Georeference ground changes while live:** keep the camera fixed, so G, the scale and the lift ease (recommended). The alternative is to shift the camera by Δ to keep today's lift feel, which makes a ground estimate change the altitude.
2. **Host switches keep the camera.** Floor 5× then shows about 1.45× the volume's region, and its θ₀ is −27°, not −33° (the pitch policy re-targets, anchored at C). Recommendation: accept, rather than adding a per-host scale bias.
3. **LOD viewpoint and AOI defaults** change tile counts in stage 2, so `detail` and `outerDetail` may need re-tuning. Are `.blended` for floor modes and `.georeference` for the volume the right defaults?
4. **Manual pitch input:** proposal T/G and D-pad up/down.
5. **Turn pivot:** drop it (proposed), or keep "orbit G" on a modifier?
6. **The unit-test target** (§16): add it, or keep temporary self-tests?
7. **Held tiles in the UI:** keep the airplane button and the "Fly" name, or rename it ("Hold tiles", pin or lock)? And are 1.5× travel and 3× climb the right starting held limits?
8. **Pitch margin:** is 8° (range ≤ about 7× height near the limit) right, or should it be tighter?
9. **Room placement in persistence:** save it per host across launches, or only in view states (proposed)?

## 18. Review basis and acceptance

This revision is grounded in README.md, MapVolumeModel.swift, TileStreaming.swift, MapPresentation.swift and CNTileStreamer.mm. Existing behavior is the UX reference: a scaled map on a floor/table, lowest-of-nine terrain placement, curvature lift at large radius, and Fly retaining streaming inputs while the update loop continues. No collision-avoidance requirement is introduced.

The migration aims for roughly equivalent UX, not mathematical identity with the old implementation. The architectural acceptance question is whether a different control or presentation style can be added without rewriting geographic navigation or streaming. Keep new saved views and settings; drop legacy saved-view compatibility. Final selection of default adaptive model versus inhabited-world presentation style and exact scale-transition tuning remains a UX decision, not a settled requirement to make the world life-sized.
