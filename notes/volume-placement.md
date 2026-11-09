# Volume placement on §5 (stage 2b): design for review

Status: **implemented as checkpoints, not merged.** Proposal written 2026-11-05 from `main` at `081538b`. Built on `claude/volume-explicit-tilt-bcfcc9` from `b7bf38d`: `9dcad75` (placement) and `c63a61e` (zoom), so the owner can try it on the headset. The settled parts are in `docs/camera-core.md` (revision 7); this note keeps the log of what was tried and found.

## Log (newest first)

**2026-11-09: zoom**

- **Observed (owner, headset; reproduced in a core simulation):** with zoom capped, holding zoom out at the stop turned the view 180°. **Cause, observed in the simulation:** at the stop each step moves the camera by a rounding error, and `GeoMath.bearingChange` carried the heading across that move using bearings computed from rounding noise. **Fix:** `bearingChange` treats moves under 1 mm as no change. That hides the symptom; the method is still ill-conditioned for short moves ([also/also-maps-apple#65](https://github.com/also/also-maps-apple/issues/65)).
- **Observed (owner, headset):** zoom out from San Francisco's 600 m view could leave you stuck above the cap, unable to zoom back in. **Inferred:** the stop could land on 50.000 km or a rounding error over it. **Changed:** zoom out stops 1% short (49.5 km).
- **Owner decision:** zoom works only below where the tilt starts (50 km above the ellipsoid). Above it (reachable by climbing), zoom does nothing either way. Zooming in from above moved you toward a point you weren't looking at, and making that sensible would need another algorithm. This limit is a workaround, not a property of the world.
- **Observed (core simulation):** zooming out to the 50 km cap and back down to the starting height leaves the view centre 11 m (volume) and 50 m (Immersive) from where it started, for a 600 m view. Uncapped, it was 1–2.4 km.
- **Tried in the core and backed out (not agreed):** zooming by changing height while the view centre stays fixed. It returns exactly in the volume (0.2 µm) but failed in Immersive by 12,700 km, because Immersive's view centre runs past the horizon far out. Anchoring Immersive's zoom on the volume's line-of-sight centre would fix that. Both were started without the owner's agreement while implementing an agreed change, and backed out; neither was tried on the headset.
- **Observed (owner, headset):** in the volume, zooming out (toward the view centre, uncapped) from San Francisco to 397 km left San Francisco at the top edge of the box, partly cut off. **Inferred:** zoom backs away from the current view centre, which slides toward the ground below the camera as the map tilts, and the tilt carries ground ahead up the box.
- **Observed (owner, headset), on `main` and on `9dcad75`:** in Immersive, zooming out from San Francisco moved back and up, then "just moved away"; zooming in didn't return, and later zooms went straight up. **Observed (core simulation):** zoom went along the stored pitch; the pitch steepened as the camera moved around the Earth; at the 11,000 km ceiling the height clamp pushed the camera off its line, sliding it 1,600 km sideways; zooming in then landed 6,700 km from San Francisco at a pitch of −76°. The old horizon pitch clamp wasn't the cause.
- **Changed:** zoom in both room hosts heads for the view centre, leaves pitch alone, and stops on its line at a height limit (`NavigationOperations.approach`).

**2026-11-09: placement** (see "Built for trying" below)

## Goal

The volume's map tilt becomes a pure function of the camera's position and heading (plus the placement ground for scale). Pitch no longer moves the volume's placement. The volume and the immersive space share one placement function.

## What's there today

- **Volume (`AdaptiveModel.framing`):** G, where the camera's view ray meets the ray surface, goes on C(θ), which slides from C₀ (level) to C₁ (straight down) with pitch. The camera sits on E. Tilt is therefore whatever the stored pitch is, and the pitch assist (`pitchTarget`/`easedPitch`, eased at 6/s, plus `settlesPitch` after a host switch) drives that pitch from altitude. Pitch that lags its target is tilt that lags.
- **Immersive (`EyeLevelModel.framing`):** camera on E, yaw-only level rotation, s = eye height / agl, then tilt about the eye by `tiltWeight(altitude) · 90°`. Pitch isn't used.

One observation that makes the move cheap: **at its level pitch, today's volume placement is already §5's τ = 0 placement.** The camera maps to E, the view ray at θ₀ maps onto E→C₀ (also θ₀ down), so the rotation is yaw-only and s = |C₀ − E| / range = (E.y − y_g) / agl. The change only removes the cases where pitch differs from θ₀.

## Proposal

### 1. One placement function for both room hosts

Generalise `EyeLevelModel.framing` and use it for the volume too:

1. **Scale:** s = (E.y − y_g) / agl, agl over the placement ground (§7 below). Unchanged from §5.
2. **Level rotation:** yaw only; the level frame at the camera maps up → up, heading → −z.
3. **Translation:** the camera lands on E. The ground beneath it lands at N₀ = (E.x, y_g, E.z).
4. **Tilt:** rotate by τ about the room's right axis **through E** (as immersive does today, and as the owner's "the camera is always the eye" requires), with τ = w · τ_max.

This differs from §5's text, which pivots about C and lets the camera leave E. Immersive already chose the eye pivot (`2cdf8b1`) after recorded tracks showed the camera leaving the eye, so I'd update §5 to match rather than give the volume a different pivot.

**What plays C₀/C₁'s role in the box:**

- **C₀** keeps its meaning: the box's ground centre (0, −0.25, 0), where the view centre sits when level. Nothing is placed *on* it; it's ~0.85 m ahead of N₀ and 0.55 m below E, so level, the box shows ground 0.35–1.35 eye heights ahead of the camera's nadir. That's what today's volume shows at its level pitch.
- **C₁** becomes *where the nadir points at full tilt*, and that sets the host's full tilt: τ_max = 90° − depression(E→C₁).
  - **Volume:** C₁ = (0, 0, 0), the box centre: τ_max = 70.6°. At full tilt the globe's nadir faces you along your line of sight to the box centre.
  - **Immersive:** τ_max stays 90° (the ground below comes up to straight ahead, as now). I'd store τ_max per host explicitly (`RoomGeometry.fullTilt`) rather than derive immersive's from its C₁ (0, 1.3, −5.6), which would give 87° and drift with the measured eye.
- A 90° tilt about the eye doesn't work in the box: the nadir lands on the box's top edge and half the globe is above it. Hence the per-host τ_max.

**The weight w** is the mode's choice (§3.3). Drone mode keeps today's curve, `EyeLevelModel.tiltWeight` (0 below 50 km, 1 by 500 km, smoothstep in log altitude), now for both hosts. Hosts map w = 1 to their own τ_max, so at w = 0 every host is exactly level, and a host switch keeps w. (Above 50 km the absolute angle differs between hosts, 70.6° vs 90° at full tilt; flagging that against §1's "nothing about the map's tilt changes because you switched host".)

**View centre (G), for the gesture slab, AOI, ground sampling and held limits:** the ground beneath the world point that lands on C(w) = C₀ + w·(C₁ − C₀). Level, that's today's immersive rule (ground beneath C₀). Tilted, it moves toward the nadir, so at full tilt it's the nadir rather than a point that can be past the horizon. Found by mapping C(w) back through the placement and dropping it to the ground: no surface intersection, always finite, so `nadirFraming` and the "keep the last framing on a miss" path go away. This slightly changes immersive above 50 km: its slab and view centre follow C(w) up instead of staying at the ground beneath level C₀.

**Feel change in the volume, high up:** today's volume at full assist scales by |C₁ − E| / range (0.9 m per range); the new one by 0.55 m per agl, so above 500 km the globe is about 0.6× today's size at the same altitude. At 11,000 km (the ceiling) it's 0.64 m across, centred near the box centre, just clipped top and bottom. If you'd rather keep today's size, s can grow from |N₀ − E| to |C₁ − E| with w; I'd start with §5's fixed rule.

### 2. What replaces the pitch assist

Nothing on pitch. Tilt is computed every frame from w(altitude), so there's no stored, eased value to lag, and `settlesPitch`, `easedPitch`, `pitchTarget`, the steer-time pitch clamp and the pitch closure in the gesture solve all go. `pitchFollowsAltitude` becomes `tiltFollowsAltitude` (off = fixed level, §3.3's simplest mode).

**Pitch itself** is no longer touched per frame in room hosts. Places set it (looking at the centre, as `EyeLevelModel.framePlace` does), and it's recorded in tracks and kept for flat-screen hosts (§3.4).

**Zoom (dolly: = and − on the keyboard, RT and LT on a controller)** goes along the camera's view ray today, so with pitch frozen it would head off in whatever direction the last place left. In room hosts I'd aim it at the view centre G instead (`ModelFlightStyle` takes a dolly target point rather than a ray surface height). This changes immersive slightly too: it dollies toward the view centre rather than along the stored pitch.

### 3. Gestures

`MapModel.solveManipulation` uses the existing generic `AdaptiveModel.solve(_:frame:)` with the shared framing for both hosts (immersive already does). Changes:

- **Remove the pitch handling** from the solve: no `AnchorTarget.pitch` closure, no horizon limit. The pose's pitch is carried through unchanged.
- **Scale surface** is the placement ground in both hosts. Scale ∝ 1 / (height above it) holds exactly under the new rule.
- **Tilt changing mid-pinch** (pinching between 50 and 500 km) is just part of the framing the solve iterates on. I'll add a test that it still converges to under 1 mm there.
- **Remove** the `rayHeight`/`envelopeHeight` overload of `solve`.

### 4. Place framing

`MapModel.framing(_:in:groundHeight:)` uses the generalised `EyeLevelModel.framePlace` for both hosts: the radius sets the scale and so the height. The tilt weight then follows from that height, and the camera is nudged until the place's centre is the view centre G. Every place in `Places.json` (radii 500 m to 8 km) is below 50 km, so they all frame level, but a big radius would frame correctly tilted. `AdaptiveModel.framePlace` goes.

### 5. LOD camera and area of interest (`MapModel.streamingInputs(for:)`)

- **LOD camera:** `lodCamera(framing:eye:anchor:)` unchanged: at E through the georeference, looking at the placed view centre. Since the camera is now on E in both hosts, that's the navigation camera's position in both, looking at the view centre (the direction §8 asks for until head tracking).
- **AOI:** policies unchanged: `.georeference` (centre G, ρ) for the volume, `.horizon` for immersive. The volume/immersive split in the altitude passed to the policy goes: the viewer is the camera in both, and its altitude is over the placement ground.
- **Anchor height:** the placement ground.

### 6. Ground estimates and what "altitude" means

There are two different altitudes:

- **Tilt altitude: the camera's height above the ellipsoid.** That makes τ a function of position alone, with no estimate in it. The curve only moves between 50 and 500 km, where terrain (−0.5 to 9 km) shifts the weight negligibly. It also stops a bad ground estimate from tilting the map. Immersive changes from ground-relative to ellipsoid-relative, which makes no visible difference.
- **Scale altitude (agl): over the placement ground**, as §5 says. That stays an estimate (§7), but becomes a **single** estimate:
  - `rayHeight` and `envelopeHeight` merge into one placement ground. The ray surface existed for the view-ray intersection, which placement no longer does.
  - The volume's far-out **curvature envelope** (aim at ray − curvatureDrop(shown) above 50 km) goes. It kept the edges of a straight-down view above the base plane. Under the new rule, level content spans at most 2.45 agl from the nadir, and at 50 km the Earth's curve drops it about 1.3 cm in the box, inside the 5 cm between the base plane and the floor. Above that the tilt lifts the far side. I'll add a test that the shown square's ground stays above the box floor from 55 m to 11,000 km.
  - The ground sample (3×3 lowest, on settle, shown < 50 km) and "first sample after a place jump moves the camera" are unchanged, centred on G.

**Issue #60** ([also/also-maps-apple#60](https://github.com/also/also-maps-apple/issues/60)): this covers its cause. The −20.8 km estimate was the volume's curvature envelope carried into Immersive, and the volume no longer produces one. With a correct estimate, Immersive's shown half-width falls below 50 km as you descend (at about 16 km above the ground), so the settle sample runs again. One leftover: a view state saved before this change can still carry the bad envelope. On restore I'd read the placement ground from `groundEstimate.ray` (always a sample) and ignore `envelope`, which fixes the issue's repro too. Keeping the `GroundEstimate` fields as they are (writing the one value to both) keeps view state v2 readable without a version bump.

### 7. What's left of `AdaptiveModel`

Removed: `framing` (view-ray), `nadirFraming`, `placementPoint(pitch:)`, `pitchTarget`, `framePlace`, the ray/envelope `solve` overload, and `RoomGeometry.levelPitch` (only the assist used it).

Kept (they're presentation-neutral): `Framing`, `minimumRange`, `lodCamera`, `AnchorTarget` and the generic `solve`. I'd move them next to the placement and rename the pair to one type, e.g. `RoomModel` (placement, place framing, LOD camera, solve), leaving no `AdaptiveModel`. If you'd rather keep renames out of this stage, I'll leave the names and just delete. Either way, `pitchLimit` (§6: only for a future flat-screen orbit pivot) loses its last caller. I'd delete it in stage 3 with `LegacyMapping`, or now if you prefer.

Tests: `MappingTests`' framing/nadir tests and `Stage2Tests`' assist and pitch tests go. In `Tests/Navigation`:

- τ = 0 is exactly level (up → up to 1e-12) in both hosts, at several altitudes and latitudes, with any pitch;
- pitch doesn't change placement (same framing for pitches −89°…+30°);
- the tilt weight depends only on the camera's height above the ellipsoid, so it's unchanged across a ground estimate change, a host switch and a place jump, and level after a place jump;
- the camera is on E in both hosts at every tilt;
- full tilt points the nadir at C₁ in the volume and straight ahead in immersive;
- anchored gestures converge to under 1 mm, including mid-tilt;
- places frame their centre on C₀ at their radius;
- the shown square stays above the volume's floor at all altitudes.

## Overlap with PR #59

[also/also-maps-apple#59](https://github.com/also/also-maps-apple/pull/59) (`camera-diagrams`, unmerged) moves the pitch assist into `AdaptiveModel.assistedPitch`/`easedPitch` and the room streaming inputs into `StreamingInputs.room(...)`. This work deletes the assist and simplifies the streaming inputs, so the two conflict in `MapModel.swift` and `AdaptiveModel.swift`. Whichever lands second resolves it: if #59 lands first, its `assistedPitch`/`easedPitch` are deleted and `StreamingInputs.room` loses its `eyeLevel`/`cameraGround` parameters. Its camera diagram may also draw the view ray as what places the volume, which would then be out of date.

## Questions for the owner

1. **Tilt pivot:** about the eye in both hosts (camera always on E, per-host τ_max), or §5's pivot about a raised C (one τ for all hosts, camera leaves E in the volume)? I recommend the eye.
2. **Tilt altitude from the ellipsoid** rather than over the ground estimate. OK?
3. **Volume scale far out:** §5's fixed eye height / agl (globe about 0.6× today's size), or grow toward |C₁ − E| with tilt to keep today's size?
4. **Zoom (dolly) toward the view centre** in room hosts, rather than along the frozen pitch?
5. **Rename** to one `RoomModel` type now, or keep the names for this stage and leave renames for stage 3?

## Built for trying (2026-11-09)

The owner asked to try it before deciding. What was built, with the open questions taken at the recommended answer unless noted.

**Decisions taken for the trial**

- **Pivot:** tilt about the eye in both hosts (question 1). Full tilt is 70.6° in the volume (`RoomGeometry.fullTilt`, from `RoomGeometry.tiltFacing(C₁, from: E)`) and 90° in Immersive.
- **Tilt altitude:** the camera's height above the ellipsoid (question 2), in both hosts: `EyeLevelModel.tiltWeight(for:)`.
- **Scale:** §5's fixed eye height / agl (question 3).
- **Zoom:** in `9dcad75`, the volume's zoom headed for the view centre and Immersive's still went along the stored pitch. I narrowed that myself, without asking, and it left pitch in use in Immersive. Superseded by `c63a61e` (see the log).
- **Names:** no renames (question 5). `AdaptiveModel` keeps `Framing`, `minimumRange`, `pitchLimit`, `lodCamera`, `AnchorTarget` and the generic `solve`. The view-ray framing, the nadir fallback, `placementPoint`, `pitchTarget`, `framePlace` and the ray/envelope `solve` overload are gone. So are `RoomGeometry.levelPitch` and, in `MapModel`, the pitch easing, `settlesPitch`, the steering pitch clamp and the horizon clamp on restore.
- **Immersive's C₀ uses are unchanged** (agreed in discussion). The shared placement needs only the eye. The view centre that rises from C₀ to C₁ is the volume's alone (`RoomGeometry.viewCentreFollowsTilt`). Immersive keeps the ground beneath level C₀ for its slab, ground sample and place framing. Moving those to the eye is a follow-up, and the gesture slab is [also/also-maps-apple#61](https://github.com/also/also-maps-apple/issues/61).
- **Ground:** one placement ground (`MapModel.placementGround`), the 3×3 sample, no curvature envelope. Saved states write it to both `ray` and `envelope`; restoring reads `ray`. `pitchFollowsAltitude` is now `tiltFollowsAltitude`.
- **Places** frame with the tilt their height gives, with the centre as the view centre. Every place in the library is below 50 km, so they all frame level.

**Found by the tests** (`Tests/Navigation/VolumePlacementTests.swift`, `Stage2Tests.swift`)

- **Observed: pinching between 50 and 500 km can't keep the grabbed point under the hand.** A pinch changes height, which changes the tilt, and tilting about the eye swings the ground plane through the box. A ×1.6 pinch from 120 km turns it about 19°, and the best the solve can do leaves the grab 8–12 cm from the hand (the scale is exact). The old volume, measured the same way on `b7bf38d`, left it 0.5–4.6 cm off, because its tilt pivoted near the content, where you grab. Immersive already behaves like the new volume. This is the main cost of the eye pivot: worth feeling on the headset. If it's bad, options are pivoting about C (§5's original, camera off the eye) or letting the pinch give up exact scale to hold the point.
- **Observed: high up, the box's floor cuts the tilted globe.** Above about 450 km some of the visible globe falls below the floor (lowest visible ground at −0.43 to −1.7 m against a floor at −0.3 m). The old volume did the same, measured the same way: −0.27 m at 72 km, down to −3.4 m at 760 km. Below 50 km, with no curvature envelope, all visible ground stays above the floor.
- **Observed:** below 50 km the view centre is within 1 cm of C₀; the line of sight meets the curved ground just past it. At 600 m the placement matches the original (legacy) placement to within 1 mm.

**Not checked:** anything on the headset or in the simulator. Builds: visionOS, macOS and tvOS succeed; the core tests pass (176).
