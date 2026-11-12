# Gesture grab point

Working notes for [also/also-maps-apple#61](https://github.com/also/also-maps-apple/issues/61): find the grab point by intersecting the gaze ray with the real surface, not from where gaze hits the flat gesture slab. Newest first.

## 2026-11-12

### When the line of sight misses, the grab rides the horizon

- **Observed (owner, headset, immersive):** zooming in, the grabbed point could disappear beyond the horizon. In the log, a point grabbed about 30 cm above the eye from 434 km moved from 1.1 m away to about 10 m away and up as the zoom reached ×4 (about 110 km).
- **Observed (core test, logged geometry):** the point stayed exactly on the line of sight up to about ×3.8. Below that height the tilt has eased and lowered the globe, so a line of sight aimed above the eye passes over it. The fallback then took the globe's point nearest the line, and for a line that passes just over the globe that point is past the horizon, facing away from the eye.
- **Change:** when the line misses, `AdaptiveModel.sighted` takes the point on the horizon seen from the eye nearest the line (where a tangent from the eye touches, in the plane of the eye, the center and the line). That's the same point where the line just grazes, so there's no jump. The grab then follows the horizon as it sinks with the tilt instead of going behind it. `PinchManipulationTests.zoomInPastTheLineOfSightKeepsTheGrabOnTheHorizon` replays the logged zoom. It fails with the old fallback. Not yet tried on the headset.
- **Inferred:** no point on the globe can stay where you pinched once the line misses, so for these grabs the horizon is the closest the zoom can hold.

## 2026-11-11

### Zoom holds the grabbed point on the line of sight

- **Observed (PR review probe):** zooming out from a 20 km view with the grab at or near the view center spun the globe 1.09–1.62 rad in a single 1% height step near 9,900 km, and an unchanged pinch there kept turning it (up to 0.74 rad). Other starting heights, and grabs 15 cm off center, stayed under 0.05 rad a step.
- **Cause:** the zoom kept the grabbed point's direction from the globe's center. From a flat view that's straight up. As the globe shrinks its center rises, and near 9,900 km it passes the height of where you pinched, so the held direction flips to straight down, under the globe. The shortest turn from the start direction to an opposite one has no defined axis.
- **Change:** the grabbed point stays on the line of sight from the design eye through where the pinch began, where it first meets the globe, or at the globe's edge nearest that line once the globe has shrunk out of it (`AdaptiveModel.sighted`). Both directions then face the eye, so the shortest turn is safe. On a nearly flat map it's the same as before. The review probe is now `PinchManipulationTests.zoomOutToAGlobeTurnsSmoothly`: under 0.1 rad a step everywhere, and no turn for an unchanged pinch. Not yet tried on the headset.

### Open: how far a drag or zoom moves depends on where it started

- **Observed (owner, headset):** in one gesture, dragging something far away toward you and then back moves it much further than grabbing something close and pushing it away by the same hand movement. Zooming about a point far away can also feel odd.
- **Inferred, not checked:** visionOS seems to scale an indirect drag's reported location by the distance to what was grabbed, the way it moves distant windows further, and keeps that scale for the whole gesture. A drag that starts far keeps its large scale even once the point is close. The DEBUG `[AlsoMaps] pinch` step lines show the reported hand movement ("hand … m"); comparing that with the real movement for near and far grabs would confirm it.
- **Inferred:** zoom holds the grabbed point fixed and scales everything about it. About a distant point, the ground near you rushes toward or away from it, and on the far side of the tilt range the view swings. That may be the expected cost of zooming about where you pinched.
- **Options if it matters:** scale the drag by the grabbed point's current distance rather than its starting one, or ease the zoom's pivot toward the view center for distant grabs. No change for now.

### Pinches as a rotation of the globe (replaces the iterative solve)

- **Observed (owner, headset):** zoom jumped in large steps around where the map starts to tilt. Fully zoomed out, dragging stopped following the hand, then flickered between two positions every frame once the hand had moved about a globe's diameter.
- **Observed (simulation, volume geometry):** zooming out at 3.5% a frame, `AdaptiveModel.solve` stepped the scale by up to 41% a frame between about 60 and 500 km, and the grabbed point moved up to 25 cm. Dragging at 10,000 km, the globe followed the hand to about a third of its radius, then stalled and jumped 4–20° at a time.
- **Cause:** the solve held the grabbed point at the hand's position offset (start + translation, 1:1 in room meters) as well as the scale. In the tilt range no camera does both, because the tilt turns the ground about the eye as the height changes. Zoomed out, a target on a flat plane leaves the globe. Its position step also assumed the map slides sideways when the camera moves, which only holds near the camera's nadir. With no exact answer, it kept whichever of 8 tries scored best, and that changed from frame to frame.
- **Change:** `AdaptiveModel.pose(for:height:from:frame:)`. The height comes straight from the pinched scale. At a given height the world shown is a globe with a fixed center and size in the room, so the pinch is a rotation of it: the grabbed point keeps its direction from the center as seen at the start (zoom about it), the hand's movement rolls it along the surface by the same distance (drag), and the twist turns about its up. The camera is whichever pose gives that orientation. There's always an answer, found directly.
- **Observed (core tests):** the scale is exact every frame. Zooming from 20 km past 1,000 km the grabbed point moves at most 1.5 cm a frame. It moves up to about 38 cm in all, toward the shrinking globe's center and with the tilt, which is as close as a point on that globe can be. Dragging three globe diameters at 10,000 km moves the point the same 7 mm every frame, around the back and over again, within 1.3% of a perfect sphere's roll (the Earth's flattening).
- **Observed (owner, headset):** zoom is smooth. Zooms that start on one side of the tilt range and end on the other can still feel unnatural, possibly inherent in the auto-tilt. The zoomed-out drag still flickered.
- **Observed (simulation):** `MapModel.drag` projected the hand's movement onto the ground's plane at the grabbed point, using its up as currently shown. On a globe that feeds the drag back into itself: rolled toward the edge, the point's up turns sideways and removes most of the movement, the globe rolls back, and the full movement returns. With a hand held still half a meter to the side, the pose alternated between two positions every frame.
- **Change:** the drag passes the raw movement; the pose already takes the part along the surface where the drag began. A core test checks that a still hand holds a globe still. Not yet tried on the headset.

### Drag across the globe's far side

- **Observed (owner, headset):** with the flicker fixed, the zoomed-out drag glitched differently once the grabbed point reached the far side of the globe.
- **Observed (simulation):** rolling steadily, the globe turned 0.059 rad a frame until the point neared 180° from where it started, then 0.48 and 0.96 rad in single frames. The pose composed the shortest turn from the start direction to the rolled one, whose axis is undefined at 180°. The grabbed point's position stayed smooth, which is why the earlier test missed it: the jump was a spin about the point.
- **Change:** the roll is a turn about a fixed axis (`AdaptiveModel.roll`). The globe now turns 0.059 rad every frame to 270° and beyond, and the drag test checks the turn per frame. DEBUG builds log each pinch begin, restart, step, end and gesture-target rebuild; filter the console for `[AlsoMaps] pinch`. Not yet tried on the headset.

### Volume grabs off by about half the volume's depth

- **Observed (owner, headset):** in the volume, grabbing the near side of the map put the grab outside the volume, roughly half the volume's depth off around San Francisco. Immersive looked right, apart from hills.
- **Observed (earlier volume log):** gaze hits converted to `.scene` ran from z ≈ 0 to 0.96 in a volume 1 m deep, so `.scene` there isn't the space the map's root sits in. The gestures converted to `.scene` and then treated that as the map frame (through `roomPlacement`, which is identity). In Immersive the two spaces happen to coincide.
- **Inferred:** this offset predates the ground-shaped target. Drags were unaffected because they only use differences, but the grab point (and with it zoom and twist pivots) was shifted in the volume all along. It only became visible with the grab markers.
- **Change:** the gestures now convert straight into `root` (the map frame), so nothing depends on how a host's scene space is set up. Not yet checked on the headset.

### Ground-shaped gesture target (`GestureSurface`)

The volume gives no gaze ray, so the grab point can't come from intersecting one. The collision shape is now the ground itself: a convex hull of points on the ellipsoid at the placement ground (8 rings × 24 bearings plus the center, and one point just below the rim so a nearly flat cap has volume). Gaze hits its curved top; a ray past its rim misses it. The hit is snapped along the vertical onto the ground, because the hull lies slightly inside the curved surface between its points. Both hosts use it, so `selectionRay` isn't needed.

- **Volume:** centerd on the view center G, reaching twice the shown radius, at most a hemisphere.
- **Immersive:** centerd beneath the camera, reaching its horizon (or twice the shown radius, whichever is larger), at most a hemisphere.
- Built in the center's anchor frame in units of its own radius, so it keeps Float precision at any size. It's placed each frame at the current ground height and rebuilt only when the view drifts more than a tenth of its radius, zooms past what it covers or to well under it, or the ground moves more than a thousandth of its radius.
- **Inferred:** errors are largest at grazing angles toward the horizon, where the hull's flat facets sit below the curved ground (up to R·Δ²/8 between rings Δ radians apart) and that height error stretches along the ray. In Immersive the selection ray could refine that if it matters.
- **Observed (owner, headset):** with the map-frame fix below, volume grabs land where you look. Immersive looks right on flat ground; on hills the grab lands behind the slope, since the target sits at the estimated ground height.
- The selection-ray probe was removed before merging.

### Second headset run: the volume

About 90 pinches, all `host=volume`, `kind=indirectPinch`. The map started near the ground and ended as a small globe.

- **Observed:** `selectionRay` was nil on every pinch in the volume. With no ray and no device pose (no `DeviceAnchor` outside an immersive space), the volume can't build a gaze ray at all.
- **Inferred:** the system gives the ray only in an immersive space, probably to keep gaze private in the Shared Space.
- **Observed:** the logged "duplicates" are separate events. Some pairs share a timestamp and have consecutive ids (24/25, 48/49, 80/81), which looks like two hands pinching at once (two-handed zoom). Others are a new id 33–67 ms after the first, at nearly the same hit (0/4, 16/20, 36/32). Why the system starts a second event so soon is unknown.
- **Observed (owner):** pinching while looking just above the terrain at the back of the box did nothing, as expected: the slab ends at the streamed square.
- **Observed (owner):** looking at a small globe at the end, pan and zoom did nothing, and a couple of pinches gave a slight rotation. The slab hits then sat at scene z ≈ 0.78–0.96, y ≈ 0.06–0.3: the tilt had stood the slab up near the front of the volume, not on the globe.
- **Inferred:** a grab point on that upright slab is off the globe. The manipulation solver likely finds no camera that keeps it under the hand and drops the update, but the solver wasn't logged.

### First headset run: Immersive only (RealityKit)

About 60 pinches, all `host=immersive`. Places ranged from near the ground to hundreds of km up, looking down, level and toward the horizon. Nothing from the volume yet.

- **Observed:** `selectionRay` was filled in on every `indirectPinch`. Converted with `value.convert(_:from: .local, to: .scene)`, the slab hit lies on it (0.000–0.010 m off), so the ray and hit share one space and the conversion is right.
- **Observed:** the ray's origin is 2.5–5 cm from the `DeviceAnchor` position, usually about 2.5 cm below it (the eyes versus the device's origin). The head→hit fallback ray is 0.03–0.1° off for hits tens of meters away and 1–1.7° off for hits about 1 m away. Where the two rays meet the ground differs by about 1–8% of the distance (e.g. 52.3 km vs 48.2 km, 1114 m vs 1085 m).
- **Observed:** near the ground, looking down, level hits land at scene y ≈ 0.12 m, not on the floor plane. That is 63 m to 7 km above the placement ground depending on scale. The ray then meets the ground 400 m to 16 km past the slab grab. Looking toward the horizon, the gap reaches 30–52 km, and two pinches grabbed the slab where the ray misses the ground altogether.
- **Inferred:** most of that near-ground offset is the slab's thickness, `0.02 × magnification`: in Immersive (magnification 10) the slab is 0.2 m thick, so gaze hits its top face 0.1 m above the ground. Curvature adds to it further out.
- **Observed:** zoomed far out (scale ≲ 3e-6 scene/m), hits land at a constant scene z ≈ −0.99 m with y anywhere from −1.0 to 3.5 m: the tilt has stood the slab up as a wall about 1 m in front of the viewer. These grabs are 25–960 km from where the ray meets the globe. This confirms the issue's inference about Immersive above 50 km.
- **Observed:** most pinches were logged twice with the same ray, and sometimes the head position differed between the two. The once-per-pinch check isn't holding. The run didn't log event ids, so the cause is still unknown.
- **Not yet tried:** the volume; the Metal immersive renderer (its gestures don't go through `mapGestures`); whether RealityKit reports gaze hits from inside an enclosing collision shape.

### Spike: `SelectionRayProbe` (DEBUG builds)

A `SpatialEventGesture` on the gesture target, alongside drag, magnify and rotate (`VolumeView.mapGestures`), logs one `[AlsoMaps] selection-ray` block per pinch:

- `kind`: whether the pinch arrives as `indirectPinch`.
- `slab hit (scene)`: today's grab point.
- `selectionRay nil` or the ray, local and in scene space.
- `slab hit … off the ray`: about 0 if this is the ray that picked the target and the conversion to scene space is right.
- The ground report: the placement ground, the georeference scale, how high above that ground the slab grab is, and how far from it the ray meets the ground (or `misses`). This is how far the grab moves under #61.
- Immersive only: the head position (`DeviceAnchor`, from its own ARKit session, started on the first pinch, so the first pinch logs `head not tracked yet`), its distance from the ray origin, the angle between the head→hit ray and the selection ray, and the ground report for that fallback ray.

To read it on the headset: run the Debug build from Xcode and filter the console for `selection-ray`. Worth trying: volume level and tilted far out, Immersive near the ground and above 50 km, looking toward the horizon, and pinches just past the map's edge.

- **Observed:** builds for the visionOS simulator, and the app runs there with the probe in place. The simulator tool can't inject visionOS input (`dtuhidServiceNotVended`), so no pinch was logged. Nothing has been measured yet.

### Why the target is a flat slab

- **Observed (git history):** `08dca87` made the slab. The target before it was a map-sized box standing on the floor that accepted direct input. The commit also made three other changes, and those three fixed the false and runaway pinches:
  - indirect input only: hands resting inside the box had counted as touching it, so an open hand dragged the map;
  - the default `DragGesture` minimum distance instead of 0;
  - a new start location, or a magnify pause of more than 0.3 s, starts a new gesture, because visionOS can cancel one without calling `onEnded`.
- **Inferred:** the slab itself fixed two other things. Gaze aimed past or over the map no longer hit the invisible box, and the hit (which is the grab point) landed on the ground instead of on the box's faces in mid-air. #61 takes the second job away from the shape. The first is still a product question in the volume: a ray over the map can meet the ellipsoid beyond the volume's visible edge.
