# Gesture grab point

Working notes for [also/also-maps-apple#61](https://github.com/also/also-maps-apple/issues/61): find the grab point by intersecting the gaze ray with the real surface, not from where gaze hits the flat gesture slab. Newest first.

## 2026-11-11

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
