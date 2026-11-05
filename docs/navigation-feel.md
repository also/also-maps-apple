# How navigation should feel

Written 2026-11-05; rewritten the same day so every claim says where it comes from. Companion to [camera-core.md](camera-core.md) (mechanism) and [navigation-handoff.md](navigation-handoff.md) (earlier owner decisions).

## How to read this

Every statement carries one tag saying what kind of claim it is.

| Tag | Meaning | Can we change it? |
|---|---|---|
| **[Owner]** | The project owner said or decided it. Quoted or closely paraphrased. | Only the owner |
| **[Proposal]** | A design opinion from the agent writing this. Not decided. | Yes |
| **[Nature]** | Geometry, physics or human perception. | No |
| **[Hardware]** | Apple Vision Pro or visionOS. | No, short of a new platform |
| **[Data]** | Google Photorealistic 3D Tiles. | No, short of another data source |
| **[API]** | cesium-native or RealityKit, as we use them. | Sometimes: work around it, patch it or upgrade |
| **[Code]** | What the app does today, with a file reference. | Yes |
| **[Painted in]** | A constraint that exists only because of an earlier choice in this app. It feels like a limit but isn't one. | Yes, at a cost |
| **[Inferred]** | Reasoned from tagged facts; not tested. | — |

Facts (Nature, Hardware, Data, API, Code) also say how well they're established:

- **checked:** confirmed against the source named, as of this writing.
- **observed:** seen running the app (from the hand-off note or notes).
- **unchecked:** from general knowledge; not confirmed for this doc. Treat as plausible, not established.

## 1. Terms

[Proposal] "Altitude" on its own is ambiguous and isn't used here. Instead:

- **Height:** the eye above the WGS84 ellipsoid. The data's own datum; within tens of metres of sea level ([Nature], unchecked).
- **Height above ground:** the eye above the surface directly below it. Only meaningful where that surface is known. The code calls this `altitude` and the older docs `agl`.
- **Clearance:** distance from the eye to the nearest surface in any direction.
- **Scale:** room metres per world metre. 1 is life-size.
- **Eye height:** the real eye above the real floor.

## 2. Who it's for

- [Owner] The user so far has mostly been the owner, who wants to play around and look at things; it's cool if it feels like flying.
- [Owner] Earlier decisions: a flight-sim feel, like Google Earth VR, from street level to the globe; spatial visualisation and drawing later.
- [Proposal] So delight comes before precision, and exploring before arriving. Precise uses (drawing, measuring) can come as their own mode later rather than shaping today's feel.

## 3. Experience goals

From the owner's decisions:

- [Owner] Climbing changes height only; turning changes heading in place; moving travels along the globe.
- [Owner] Speed scales with height above the ground under you, not with a zoom radius.
- [Owner] What you pinch, twist or drag stays with your hand.
- [Owner] In VR the floor defines level: when the map should look level, it is level with the floor. Tilt belongs to the mode, not to altitude or pitch.
- [Owner] The camera is the eye in the immersive space, at any altitude or tilt.
- [Owner] Tile loading should suit a viewpoint, not a view direction.
- [Owner] Whether the floor is also a height datum (ground on the floor) is open.

Proposed in addition:

- [Proposal] **The world never moves by itself.** It doesn't tilt, rescale or slide unless you did something, or a deliberate, gentle transition runs (a toggle, a place jump). An estimate settling, a tile loading or a head turn must not visibly move it. Most of the reported bugs break this (§9).
- [Proposal] **Surfaces are solid by default.** You can skim them; you don't end up inside them.

## 4. The two modes

- [Owner] The volume and the immersive space are the app's two modes. The volume is the default. The immersive space is much more immersive, probably more useful, and fun.
- [Owner] The volume is neither a way to fly nor mainly a control panel. The same controls work there, but moving a clipped volume doesn't feel like flying.
- [Hardware] A volume's content is clipped to its bounds. Checked in third-party write-ups and Apple forum threads ([forum](https://developer.apple.com/forums/thread/760018)), not in Apple's reference docs. One write-up gives a 2 m maximum size, unchecked.
- [Hardware] The tracked head (`DeviceAnchor`) is available only in immersive spaces, not to a volume in the Shared Space. Observed (hand-off note).
- [Inferred] Being outside a clipped box, viewing it from in front, is a likely reason the volume doesn't feel like flying. Whether a larger volume or a different placement would change that is untested.
- [Proposal] Design flying for the immersive space. Give the volume the basics anyway, as the default: level when it should be, and the world never moving by itself.

## 5. Scale

### What scale is

- [Owner] We present the tiles as if they're on the ground at a scale, so we need to know where the tiles are relative to that ground.
- [Nature] Checked by geometry: scaling the world by *s* about your eye gives the same image as scaling your eye separation and eye height by 1/*s*. In stereo, scale changes how big the world seems to you.
- [Nature] Checked by geometry: with one eye and no head tracking (the Mac, iPhone and iPad), scaling the world about the camera leaves the image unchanged. On flat screens, scale is invisible except through speed and clipping planes.
- [Nature] Partly checked: stereo depth works best near the viewer. Cutting and Vishton (1995) divide space into personal (about arm's reach), action (about 1.5 to 30 m) and vista (beyond); disparity matters most in the nearer zones ([Naceri et al. 2015](https://www.frontiersin.org/journals/human-neuroscience/articles/10.3389/fnhum.2015.00511/full), citing them). Exact cutoffs unchecked.
- [Inferred] So in the room, a small-scale world (terrain metres away) shows its shape in stereo. A life-size world seen from hundreds of metres up is beyond stereo range and looks flat.
- [Hardware] Unconfirmed, one third-party source ([etcentric](https://www.etcentric.org/?p=190053)): Vision Pro's displays have a fixed focal distance of about 1.8 m. [Nature] Unchecked: the further content is from the focal distance, especially nearer, the stronger the mismatch between where the eyes point and where they focus, and the greater the discomfort.
- [Inferred] At today's 55 m minimum and 1.6 m eye height, scale is about 1:34, so a facade 10 m away is about 30 cm from the eyes in the room: far nearer than 1.8 m.

### Ways to think about it

- [Proposal] **Giant:** you're in the world, standing on its ground; climbing makes you bigger. Moving yourself is the natural control, and tilting the world feels like the ground tipping under you.
- [Owner] **Diorama:** another way to think about it. The world is an object you look at from outside.
- [Inferred] On the headset the two can produce the same image; the difference is the story and the controls. Diorama suits moving, tilting and resizing the model. The ground/globe toggle can be seen as switching from giant to diorama.

### Two separate questions

1. [Proposal] **Which scale policy is on:** for example always life-size, always some fixed giant or tiny scale, or a rule. The person picks with a toggle or setting.
2. [Proposal] **Under a rule, what changes the scale moment to moment:** your explicit action (a pinch), your own motion (climbing grows you), or your surroundings (for example clearance).

- [Owner] It's a choice: you could always be human scale (there's a toggle), always giant, or always tiny.
- [Code] Checked: the immersive space's rule is scale = eye height ÷ height above a ground estimate (`Sources/Navigation/EyeLevelModel.swift:41`), with eye height 1.6 m unless measured when the space opens (`Sources/MapPresentation.swift:44`, `Sources/MapModel.swift:753`). "Human scale (test)" in Settings switches to a fixed 1:1.
- [Code] Arithmetic on those values: under that rule, life-size happens exactly when height above ground equals eye height. That's a property of this rule, not of scale.

### What the owner's examples rule out

- [Owner] **The wedge:** at human scale at the base of a wedge, slope to your right and the body of the shape behind you, out of view. Move right and up along the slope: height above ground stays constant, so the scale stays human. Make the same move with no wedge: the same view ahead, but the scale changes.
- [Owner] **The rooftop:** descend onto a tall building. Ideally we know it isn't the ground, so you're not at human scale, yet you're standing among human-scale features. If we do treat the roof as ground, then fly off its edge: should the scale change?
- [Owner] Height above ground is hard to know when the ground isn't what you see.
- [Proposal] Principles drawn from these:
  1. Scale must not depend on geometry you can't see from where you are. "From where you are" means the viewpoint in any direction, not where you're looking, so that a head turn never changes it.
  2. The same motion through the same visible surroundings gives the same change in scale.
- [Inferred] Scale from height above ground fails both. With the wedge, scale depends on hidden geometry. At the roof edge, height above ground jumps by the building's height in one step, so the scale would jump by the same factor.

### Candidate rules

- [Proposal] **Scale changes only when you act on it** (climbing, a pinch, a toggle).
  - Passes both principles.
  - Needs no ground estimate to place the world.
  - The floor stops meaning "the ground": fly level toward a plateau and the land comes up toward you.
- [Proposal] **Scale follows clearance:** smaller near surfaces, bigger in the open.
  - Passes both principles if measured in all directions.
  - Gives the automatic in-and-out of human scale. [Owner] The owner finds that interesting.
  - [Inferred] Risks: the world resizes as you pass things, and approach looks faster than it is.
  - Needs a clearance measurement (§7).
- [Proposal] **Fixed, by toggle:** life-size or any other scale.
- [Proposal] Default to the first, try the second as an experiment, and keep the toggle.

### The scale toggle

- [Owner] A scale switch that also moves you (for example "land here at life-size") is a bizarre use of it in an app built around navigating by altitude change. Getting somewhere is flying.
- [Proposal] So the toggle changes scale only, about your eye: pressed at 500 m, you're life-size 500 m up.
- [Proposal] Switching back to a rule eases over about a second, about the eye, rather than snapping.

## 6. Speed

- [Owner] Speed scales with height above the ground under you.
- [Nature] Checked by geometry: ground directly below sweeps past at speed ÷ height, in radians per second. Speed proportional to height keeps that constant.
- [Code] Checked: moving covers 0.75 × height above ground per second (`Sources/Navigation/ControlStyles.swift`, `moveRate`). That's about 43° per second of sweep directly below.
- [Code] Arithmetic: under the immersive scale rule, room speed is 0.75 × eye height per second, about 1.2 m/s at a 1.6 m eye, at every height.
- [Nature] By geometry: a surface at distance *d* sweeps past at speed ÷ *d*. When something beside or ahead of you is nearer than the ground below, it sweeps faster. Example from today's numbers: 55 m up at about 41 m/s, a facade 10 m to the side sweeps at about 4 rad/s.
- [Inferred] Speed from height above ground goes wrong:
  - beside tall buildings;
  - heading toward slopes;
  - over edges, where height above ground jumps and speed with it.
- [Proposal] Base speed on clearance instead. Slow down quickly as things get near, and speed up slowly as they fall away.

## 7. Hitting surfaces

### What would feel natural

- [Nature] Unchecked: unexpected acceleration, rotation and motion you didn't cause are leading causes of VR discomfort. Smooth constant motion is usually tolerated.
- [Proposal] No dead stops. Slow as you near a surface, then slide along it, keeping any motion parallel to it. Flying into a slope carries you up it; descending onto a roof brings you gently to rest on it.
- [Inferred] Speed proportional to clearance gives most of this for free. Heading straight at a surface, speed falls with distance, so you approach ever more slowly. It still needs a minimum clearance to cover boost and long frames.
- [Proposal] Passing through surfaces could be an explicit exploring mode with a clear cue. Not the default.

### What we can build

- [Data] Unchecked against Google's docs: the tiles are a single textured mesh over everything, with no layer for ground, buildings, trees or water in what we load. A ray from above meets roofs, treetops and bridge decks first.
- [Data] Coverage varies by place; Google points to the Map Tiles API coverage page ([overview](https://developers.google.com/maps/documentation/tile/3d-tiles-overview)). Unchecked which places have full 3D.
- [API] Checked against cesium-native v0.64.0 (`Tileset.h`, `TilesetHeightQuery.cpp`): `sampleHeightMostDetailed` takes longitude and latitude only (a vertical ray). It walks down to the most detailed tiles along that ray, requesting any that aren't loaded, and resolves only once they have loaded. It can't answer "what's ahead of me", and it can wait on the network.
- [Code] Checked: the app uses it to sample a 3×3 grid across the shown area and keeps the lowest hit (`Sources/Cesium/CNTileStreamer.mm` near line 1375; `Sources/MapModel.swift:700`).
- [API] Checked: cesium-native has `GltfUtilities::intersectRayGltfModel`, which intersects any ray with one glTF model. A loaded tile's content keeps its glTF model (`TileContent::getModel`). There's no tileset-wide "ray against loaded tiles" call in the public headers.
- [Inferred] So collision against what's already loaded is buildable without the network: cast rays (down, and along the direction of motion) against the tiles being drawn. It is app-side work, not a cesium-native feature.
- [API] Unchecked in detail: cesium-native refines a tile until its screen-space error (geometric error over distance, in pixels) meets a threshold, so loaded geometry's error is roughly proportional to its distance from the viewpoint it was chosen for.
- [Painted in] Checked (`Sources/MapModel.swift:826`, `AdaptiveModel.lodCamera`): detail is chosen for a virtual camera at the design eye (assumed, or measured once when the immersive space opens), looking at the map's centre point, not for the tracked head. Geometry right beside you may be coarser than that implies.
- [Code] While tiles are held, nothing refines.
- [Proposal] Where nothing near you is loaded (after a jump or fast travel), treat the surface as unknown: don't descend below the last known surface, but allow moving sideways. When finer detail arrives above the eye, ease out of it.

## 8. What "the ground" is used for

- [Proposal] Four jobs that each want something different:
  1. **What sits on the floor** (if anything does). Wants stability, since changes resize or move the world.
  2. **Speed.** Wants local and quick.
  3. **What stops you.** Wants exact and conservative.
  4. **Tilt,** if it depends on height. Wants stability.
- [Observed] Hand-off note: a coarse tile's lowest vertex can be kilometres below the real ground; −10,500 m was seen near San Francisco. Cause not established.
- [Code] Checked: the per-tile height range the app uses is the lowest and highest *vertex* of each tile (`Sources/Cesium/CNTileStreamer.mm` around lines 559–599), not a surface below a point.
- [Code] Checked: placement uses the 3×3 sample (job 1). Speed and the minimum height use a per-frame estimate from loaded tiles (jobs 2 and 3; `Sources/Navigation/CameraGround.swift`). Immersive tilt uses the placement estimate (job 4; `Sources/MapModel.swift:137`).
- [Painted in] The ground on the floor came from the volume, where content must sit in the box. [Owner] Putting the ground on the floor isn't a goal in itself.
- [Painted in] Because scale is tied to height above ground (§5), the world's size depends on job 1's estimate, which the data can't give reliably. The candidate rule "scale changes only when you act" removes job 1 entirely.

## 9. The reported bugs

- [Owner] Frequent bugs: tilt; ground estimation; the viewpoint passing through the ground despite a ground estimate; the volume showing tilted ground below the tilt threshold.

**Tilt.**

- [Code] Checked: the immersive tilt is a function of height above the placement ground estimate (`Sources/MapModel.swift:137`, `Sources/Navigation/EyeLevelModel.swift:21–26`).
- [Inferred] When that estimate changes, the tilt changes, even though you did nothing. (Only above 50 km, where the curve starts.)

**Passing through the ground.**

- [Code] Checked: what stops you is the camera-ground estimate plus 55 m (`Sources/Navigation/NavigationOperations.swift:13–15`, `Sources/MapModel.swift:93`). That estimate (`Sources/Navigation/CameraGround.swift`):
  - looks only below the camera, within max(20 m, 5% of height above ground);
  - takes the lowest vertex of any tile that reaches within that radius, wherever in the tile that vertex is (`Sources/Navigation/AreaOfInterest.swift:125–141`). On a slope it can be well below the surface under you;
  - uses only tiles no wider than max(2 × height above ground, 500 m), and keeps its old value when none qualify;
  - eases toward new values;
  - is reset to 0 m on a place jump (`Sources/MapModel.swift:359`).
- [Inferred] So you can fly sideways into a slope or a building; an old value survives fast travel; and the drawn mesh can be above the value used to stop you.

**The volume tilted at low altitude.**

- [Code] Checked: the volume still uses the adaptive model, where the map's orientation comes from the camera's view direction (`Sources/Navigation/AdaptiveModel.swift:71`). The map is level only while the pitch equals the angle from the assumed eye to the map's centre point.
- [Code] Checked: the pitch is steered toward that angle only while climbing or zooming (`Sources/MapModel.swift:566`) and after a mode switch (`Sources/MapModel.swift:55`, 496–501). Moving clamps it to a horizon limit (`Sources/MapModel.swift:569`, 577).
- [Inferred] Anything else that leaves the pitch off that angle leaves the volume tilted at any height: a gesture whose solve stops short, a restored view or played-back track. The 50 km threshold applies only to the immersive tilt.
- [Painted in] This is the "tilt derived from pitch" rule the owner rejected, still live in the volume.

**The common thread.**

- [Inferred] Each of these involves the view changing because an estimate changed (tilt, scale, the volume's orientation), or because the estimate for one job was used for another.

## 10. Open questions for the owner

1. Scale policy: default to "changes only when you act", try clearance as an experiment, keep the toggle (§5)?
2. Does the floor stay a height datum at all (§8)?
3. Speed from clearance rather than height above ground (§6)?
4. Surfaces: soft and sliding by default, with passing through as an explicit mode (§7)?
5. Drone tilt: keep the altitude curve, or move to the ground/globe toggle (diorama for the globe)?
