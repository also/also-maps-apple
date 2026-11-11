# Volume placement

Status: **merged** in [also/also-maps-apple#66](https://github.com/also/also-maps-apple/pull/66). This note keeps the log of what was tried and found. Section numbers such as §5 refer to `docs/camera-core.md`, which has since been removed and is in the git history.

## Log (newest first)

**2026-11-11: one line of sight for the view center** ([also/also-maps-apple#67](https://github.com/also/also-maps-apple/issues/67))

- **Owner decision:** keep the view center, defined by what's in front of the viewer: C₀ with no tilt, the ground below the navigation position at full tilt. Supersedes the 2026-11-09 "eliminate it".
- **Inferred:** with the line-of-sight rule only C₁'s direction from E mattered, and that direction is the one `fullTilt` already points the nadir along, so C₁ duplicated `fullTilt` (the immersive space's sat 3° off it).
- **Changed:** `RoomGeometry` drops C₁ (`placementDown`) and `viewCentreFollowsTilt`. Both hosts' view center is the ground along `sightLine(tiltWeight:)`: straight ahead, dipping as E→C₀ does while level, turning evenly with the tilt to 90° less `fullTilt`. The volume computes `fullTilt` from the box's center as before. Volume behavior is unchanged at the ends and within 0.4° in between.
- **Inferred (flat-ground estimate, h = camera height):** the immersive view center sits 3.5h ahead level, 1.5h at weight 0.25, 0.75h at 0.5, 0.33h at 0.75, and on the navigation position at full tilt. The line meets the globe inside the horizon at every altitude.
- **Observed (probe):** untilted, the immersive view center moves out along the line past the old point (ground beneath C₀) by the Earth's curve: 1.3 m at 600 m up, 88 m at 5 km, 1.5 km at 20 km, 9.6 km at the 49.5 km zoom stop. Zoom holds the view center, so this no longer shows as drift.
- **Not decided:** which of the issue's uses should keep following it. The gesture slab moves with it until [also/also-maps-apple#61](https://github.com/also/also-maps-apple/issues/61).

**2026-11-11: zoom holds the view center**

- **Observed (core simulation):** with the immersive view center moved onto the line of sight toward C₀, zooming out to the 49.5 km stop and back drifted 105 m (was 50 m). Zoom flew straight at the view center, and the camera's local level turns with the Earth's curve as it moves, so the view center slid up to 10 km at the top and didn't fully come back.
- **Owner decision:** zoom holds the view center instead, before changing its definition.
- **Changed:** zoom changes height above the dolly surface and solves for the standpoint that keeps the view center where it was (`EyeLevelModel.pose(_:at:holdingViewCentre:)`, sharing `framePlace`'s solver), keeping pitch and the heading relative to the view center. The pose is a function of the view center and the height, so a round trip returns to the same view. `NavigationOperations.approach` is gone.
- **Observed (core tests):** the round trip now returns within 1 cm and the same heading in both hosts. The solver holds the view center to about 1 µm per step. The 50 km zoom limit is unchanged.

**2026-11-09: the immersive space's view center**

- **Observed (git history):** the immersive space's view center (the ground beneath C₀ as placed level) was the tilt's pivot in `2cdf8b1`. When `2fb7061` moved the pivot to the design eye point, the view center stayed and wasn't re-derived. **Inferred:** it no longer means anything; far out it's past the horizon. It still sets the gesture slab, the LOD camera's direction, place framing, the hold-tiles travel limit and the ground sample's center, on `main` too. **Owner decision:** eliminate it rather than move it ([also/also-maps-apple#67](https://github.com/also/also-maps-apple/issues/67)).

**2026-11-09: zoom**

- **Observed (owner, headset; reproduced in a core simulation):** with zoom capped, holding zoom out at the stop turned the view 180°. **Cause, observed in the simulation:** at the stop each step moves the camera by a rounding error, and `GeoMath.bearingChange` carried the heading across that move using bearings computed from rounding noise. **Fix:** `bearingChange` treats moves under 1 mm as no change. That hides the symptom; the method is still ill-conditioned for short moves ([also/also-maps-apple#65](https://github.com/also/also-maps-apple/issues/65)).
- **Observed (owner, headset):** zoom out from San Francisco's 600 m view could leave you stuck above the cap, unable to zoom back in. **Inferred:** the stop could land on 50.000 km or a rounding error over it. **Changed:** zoom out stops 1% short (49.5 km).
- **Owner decision:** zoom works only below where the tilt starts (50 km above the ellipsoid). Above it (reachable by climbing), zoom does nothing either way. Zooming in from above moved you toward a point you weren't looking at, and making that sensible would need another algorithm. This limit is a workaround, not a property of the world.
- **Observed (core simulation):** zooming out to the 50 km cap and back down to the starting height leaves the view center 11 m (volume) and 50 m (Immersive) from where it started, for a 600 m view. Uncapped, it was 1–2.4 km.
- **Tried in the core and backed out (not agreed):** zooming by changing height while the view center stays fixed. It returns exactly in the volume (0.2 µm) but failed in Immersive by 12,700 km, because Immersive's view center runs past the horizon far out. Anchoring Immersive's zoom on the volume's line-of-sight center would fix that. Both were started without the owner's agreement while implementing an agreed change, and backed out; neither was tried on the headset.
- **Observed (owner, headset):** in the volume, zooming out (toward the view center, uncapped) from San Francisco to 397 km left San Francisco at the top edge of the box, partly cut off. **Inferred:** zoom backs away from the current view center, which slides toward the ground below the camera as the map tilts, and the tilt carries ground ahead up the box.
- **Observed (owner, headset), on `main` and on `9dcad75`:** in Immersive, zooming out from San Francisco moved back and up, then "just moved away"; zooming in didn't return, and later zooms went straight up. **Observed (core simulation):** zoom went along the stored pitch; the pitch steepened as the camera moved around the Earth; at the 11,000 km ceiling the height clamp pushed the camera off its line, sliding it 1,600 km sideways; zooming in then landed 6,700 km from San Francisco at a pitch of −76°. The old horizon pitch clamp wasn't the cause.
- **Changed:** zoom in both room hosts heads for the view center, leaves pitch alone, and stops on its line at a height limit (`NavigationOperations.approach`).

**2026-11-09: placement** (see "Built for trying" below)

## Goal

The volume's map tilt becomes a pure function of the camera's position and heading (plus the placement ground for scale). Pitch no longer moves the volume's placement. The volume and the immersive space share one placement function.

## What's there today

- **Volume (`AdaptiveModel.framing`):** G, where the camera's view ray meets the ray surface, goes on C(θ), which slides from C₀ (level) to C₁ (straight down) with pitch. The camera sits on E. Tilt is therefore whatever the stored pitch is, and the pitch assist (`pitchTarget`/`easedPitch`, eased at 6/s, plus `settlesPitch` after a host switch) drives that pitch from altitude. Pitch that lags its target is tilt that lags.
- **Immersive (`EyeLevelModel.framing`):** camera on E, yaw-only level rotation, s = eye height / agl, then tilt about E by `tiltWeight(altitude) · 90°`. Pitch isn't used.

One observation that makes the move cheap: **at its level pitch, today's volume placement is already §5's τ = 0 placement.** The camera maps to E, the view ray at θ₀ maps onto E→C₀ (also θ₀ down), so the rotation is yaw-only and s = |C₀ − E| / range = (E.y − y_g) / agl. The change only removes the cases where pitch differs from θ₀.

## Proposal

### 1. One placement function for both room hosts

Generalise `EyeLevelModel.framing` and use it for the volume too:

1. **Scale:** s = (E.y − y_g) / agl, agl over the placement ground (§7 below). Unchanged from §5.
2. **Level rotation:** yaw only; the level frame at the camera maps up → up, heading → −z.
3. **Translation:** the camera lands on E. The ground beneath it lands at N₀ = (E.x, y_g, E.z).
4. **Tilt:** rotate by τ about the room's right axis **through E** (as immersive does today, so the camera stays on E), with τ = w · τ_max.

This differs from §5's text, which pivots about C and lets the camera leave E. Immersive already moved its pivot to E (`2fb7061`) after recorded tracks showed the camera leaving E, so I'd update §5 to match rather than give the volume a different pivot.

**What plays C₀/C₁'s role in the box:**

- **C₀** keeps its meaning: the box's ground center (0, −0.25, 0), where the view center sits when level. Nothing is placed *on* it; it's ~0.85 m ahead of N₀ and 0.55 m below E, so level, the box shows ground 0.35–1.35 eye heights ahead of the camera's nadir. That's what today's volume shows at its level pitch.
- **C₁** becomes *where the nadir points at full tilt*, and that sets the host's full tilt: τ_max = 90° − depression(E→C₁).
  - **Volume:** C₁ = (0, 0, 0), the box center: τ_max = 70.6°. At full tilt the globe's nadir faces you along your line of sight to the box center.
  - **Immersive:** τ_max stays 90° (the ground below comes up to straight ahead, as now). I'd store τ_max per host explicitly (`RoomGeometry.fullTilt`) rather than derive immersive's from its C₁ (0, 1.3, −5.6), which would give 87° and drift with the measured eye.
- A 90° tilt about E doesn't work in the box: the nadir lands on the box's top edge and half the globe is above it. Hence the per-host τ_max.

**The weight w** is the mode's choice (§3.3). Drone mode keeps today's curve, `EyeLevelModel.tiltWeight` (0 below 50 km, 1 by 500 km, smoothstep in log altitude), now for both hosts. Hosts map w = 1 to their own τ_max, so at w = 0 every host is exactly level, and a host switch keeps w. (Above 50 km the absolute angle differs between hosts, 70.6° vs 90° at full tilt; flagging that against §1's "nothing about the map's tilt changes because you switched host".)

**View center (G), for the gesture slab, AOI, ground sampling and held limits:** the ground beneath the world point that lands on C(w) = C₀ + w·(C₁ − C₀). Level, that's today's immersive rule (ground beneath C₀). Tilted, it moves toward the nadir, so at full tilt it's the nadir rather than a point that can be past the horizon. Found by mapping C(w) back through the placement and dropping it to the ground: no surface intersection, always finite, so `nadirFraming` and the "keep the last framing on a miss" path go away. This slightly changes immersive above 50 km: its slab and view center follow C(w) up instead of staying at the ground beneath level C₀.

**Feel change in the volume, high up:** today's volume at full assist scales by |C₁ − E| / range (0.9 m per range); the new one by 0.55 m per agl, so above 500 km the globe is about 0.6× today's size at the same altitude. At 11,000 km (the ceiling) it's 0.64 m across, centered near the box center, just clipped top and bottom. If you'd rather keep today's size, s can grow from |N₀ − E| to |C₁ − E| with w; I'd start with §5's fixed rule.

### 2. What replaces the pitch assist

Nothing on pitch. Tilt is computed every frame from w(altitude), so there's no stored, eased value to lag, and `settlesPitch`, `easedPitch`, `pitchTarget`, the steer-time pitch clamp and the pitch closure in the gesture solve all go. `pitchFollowsAltitude` becomes `tiltFollowsAltitude` (off = fixed level, §3.3's simplest mode).

**Pitch itself** is no longer touched per frame in room hosts. Places set it (looking at the center, as `EyeLevelModel.framePlace` does), and it's recorded in tracks and kept for flat-screen hosts (§3.4).

**Zoom (dolly: = and − on the keyboard, RT and LT on a controller)** goes along the camera's view ray today, so with pitch frozen it would head off in whatever direction the last place left. In room hosts I'd aim it at the view center G instead (`ModelFlightStyle` takes a dolly target point rather than a ray surface height). This changes immersive slightly too: it dollies toward the view center rather than along the stored pitch.

### 3. Gestures

`MapModel.solveManipulation` uses the existing generic `AdaptiveModel.solve(_:frame:)` with the shared framing for both hosts (immersive already does). Changes:

- **Remove the pitch handling** from the solve: no `AnchorTarget.pitch` closure, no horizon limit. The pose's pitch is carried through unchanged.
- **Scale surface** is the placement ground in both hosts. Scale ∝ 1 / (height above it) holds exactly under the new rule.
- **Tilt changing mid-pinch** (pinching between 50 and 500 km) is just part of the framing the solve iterates on. I'll add a test that it still converges to under 1 mm there.
- **Remove** the `rayHeight`/`envelopeHeight` overload of `solve`.

### 4. Place framing

`MapModel.framing(_:in:groundHeight:)` uses the generalised `EyeLevelModel.framePlace` for both hosts: the radius sets the scale and so the height. The tilt weight then follows from that height, and the camera is nudged until the place's center is the view center G. Every place in `Places.json` (radii 500 m to 8 km) is below 50 km, so they all frame level, but a big radius would frame correctly tilted. `AdaptiveModel.framePlace` goes.

### 5. LOD camera and area of interest (`MapModel.streamingInputs(for:)`)

- **LOD camera:** `lodCamera(framing:eye:anchor:)` unchanged: at E through the georeference, looking at the placed view center. Since the camera is now on E in both hosts, that's the navigation camera's position in both, looking at the view center (the direction §8 asks for until head tracking).
- **AOI:** policies unchanged: `.georeference` (center G, ρ) for the volume, `.horizon` for immersive. The volume/immersive split in the altitude passed to the policy goes: the viewer is the camera in both, and its altitude is over the placement ground.
- **Anchor height:** the placement ground.

### 6. Ground estimates and what "altitude" means

There are two different altitudes:

- **Tilt altitude: the camera's height above the ellipsoid.** That makes τ a function of position alone, with no estimate in it. The curve only moves between 50 and 500 km, where terrain (−0.5 to 9 km) shifts the weight negligibly. It also stops a bad ground estimate from tilting the map. Immersive changes from ground-relative to ellipsoid-relative, which makes no visible difference.
- **Scale altitude (agl): over the placement ground**, as §5 says. That stays an estimate (§7), but becomes a **single** estimate:
  - `rayHeight` and `envelopeHeight` merge into one placement ground. The ray surface existed for the view-ray intersection, which placement no longer does.
  - The volume's far-out **curvature envelope** (aim at ray − curvatureDrop(shown) above 50 km) goes. It kept the edges of a straight-down view above the base plane. Under the new rule, level content spans at most 2.45 agl from the nadir, and at 50 km the Earth's curve drops it about 1.3 cm in the box, inside the 5 cm between the base plane and the floor. Above that the tilt lifts the far side. I'll add a test that the shown square's ground stays above the box floor from 55 m to 11,000 km.
  - The ground sample (3×3 lowest, on settle, shown < 50 km) and "first sample after a place jump moves the camera" are unchanged, centered on G.

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
- places frame their center on C₀ at their radius;
- the shown square stays above the volume's floor at all altitudes.

## Overlap with PR #59

[also/also-maps-apple#59](https://github.com/also/also-maps-apple/pull/59) (`camera-diagrams`, unmerged) moves the pitch assist into `AdaptiveModel.assistedPitch`/`easedPitch` and the room streaming inputs into `StreamingInputs.room(...)`. This work deletes the assist and simplifies the streaming inputs, so the two conflict in `MapModel.swift` and `AdaptiveModel.swift`. Whichever lands second resolves it: if #59 lands first, its `assistedPitch`/`easedPitch` are deleted and `StreamingInputs.room` loses its `eyeLevel`/`cameraGround` parameters. Its camera diagram may also draw the view ray as what places the volume, which would then be out of date.

**Observed** (resolved on `camera-diagrams`, merging main in): `assistedPitch`/`easedPitch` are gone, `StreamingInputs.room` takes only the placement ground, and the camera diagram draws both room hosts with `EyeLevelModel.framing`.

## Questions for the owner

1. **Tilt pivot:** about E in both hosts (camera always on E, per-host τ_max), or §5's pivot about a raised C (one τ for all hosts, camera leaves E in the volume)? I recommend E.
2. **Tilt altitude from the ellipsoid** rather than over the ground estimate. OK?
3. **Volume scale far out:** §5's fixed eye height / agl (globe about 0.6× today's size), or grow toward |C₁ − E| with tilt to keep today's size?
4. **Zoom (dolly) toward the view center** in room hosts, rather than along the frozen pitch?
5. **Rename** to one `RoomModel` type now, or keep the names for this stage and leave renames for stage 3?

## Built for trying (2026-11-09)

The owner asked to try it before deciding. What was built, with the open questions taken at the recommended answer unless noted.

**Decisions taken for the trial**

- **Pivot:** tilt about the design eye point in both hosts (question 1). Full tilt is 70.6° in the volume (`RoomGeometry.fullTilt`, from `RoomGeometry.tiltFacing(C₁, from: E)`) and 90° in Immersive.
- **Tilt altitude:** the camera's height above the ellipsoid (question 2), in both hosts: `EyeLevelModel.tiltWeight(for:)`.
- **Scale:** §5's fixed eye height / agl (question 3).
- **Zoom:** in `9dcad75`, the volume's zoom headed for the view center and Immersive's still went along the stored pitch. I narrowed that myself, without asking, and it left pitch in use in Immersive. Superseded by `c63a61e` (see the log).
- **Names:** no renames (question 5). `AdaptiveModel` keeps `Framing`, `minimumRange`, `pitchLimit`, `lodCamera`, `AnchorTarget` and the generic `solve`. The view-ray framing, the nadir fallback, `placementPoint`, `pitchTarget`, `framePlace` and the ray/envelope `solve` overload are gone. So are `RoomGeometry.levelPitch` and, in `MapModel`, the pitch easing, `settlesPitch`, the steering pitch clamp and the horizon clamp on restore.
- **Immersive's C₀ uses are unchanged** (agreed in discussion). The shared placement needs only the design eye point. The view center that rises from C₀ to C₁ is the volume's alone (`RoomGeometry.viewCentreFollowsTilt`; superseded 2026-11-11, see the log). Immersive keeps the ground beneath level C₀ for its slab, ground sample and place framing. Replacing those is a follow-up ([also/also-maps-apple#67](https://github.com/also/also-maps-apple/issues/67)), and the gesture slab is [also/also-maps-apple#61](https://github.com/also/also-maps-apple/issues/61).
- **Ground:** one placement ground (`MapModel.placementGround`), the 3×3 sample, no curvature envelope. Saved states write it to both `ray` and `envelope`; restoring reads `ray`. `pitchFollowsAltitude` is now `tiltFollowsAltitude`.
- **Places** frame with the tilt their height gives, with the center as the view center. Every place in the library is below 50 km, so they all frame level.

**Found by the tests** (`Tests/Navigation/VolumePlacementTests.swift`, `Stage2Tests.swift`)

- **Observed: pinching between 50 and 500 km can't keep the grabbed point under the hand.** A pinch changes height, which changes the tilt, and tilting about the design eye point swings the ground plane through the box. A ×1.6 pinch from 120 km turns it about 19°, and the best the solve can do leaves the grab 8–12 cm from the hand (the scale is exact). The old volume, measured the same way on `b7bf38d`, left it 0.5–4.6 cm off, because its tilt pivoted near the content, where you grab. Immersive already behaves like the new volume. This is the main cost of pivoting about the design eye point: worth feeling on the headset. If it's bad, options are pivoting about C (§5's original, camera off E) or letting the pinch give up exact scale to hold the point.
- **Observed: high up, the box's floor cuts the tilted globe.** Above about 450 km some of the visible globe falls below the floor (lowest visible ground at −0.43 to −1.7 m against a floor at −0.3 m). The old volume did the same, measured the same way: −0.27 m at 72 km, down to −3.4 m at 760 km. Below 50 km, with no curvature envelope, all visible ground stays above the floor.
- **Observed:** below 50 km the view center is within 1 cm of C₀; the line of sight meets the curved ground just past it. At 600 m the placement matches the original (legacy) placement to within 1 mm.

**Not checked:** anything on the headset or in the simulator. Builds: visionOS, macOS and tvOS succeed; the core tests pass (176).
