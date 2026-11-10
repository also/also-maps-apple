# Fundamentals

The ideas behind how Also Maps places the world, for readers new to 3D and VR. [camera-core.md](camera-core.md) has the rules; this is the background.

## Heights

Three heights come up again and again:

- **Height above the ellipsoid** (`height` in the code): how far a point is above a smooth mathematical Earth, WGS84.
- **Terrain height:** how far the ground is above that ellipsoid at some point. It has to be estimated from the loaded tiles (or another source). Sea level (the geoid) sits up to about 100 m off the ellipsoid, which rarely matters here.
- **Altitude above ground level (AGL):** a height minus the terrain height beneath it. It's only as good as the terrain estimate.

## Where the ground comes in

Some features plainly need the ground, and some plainly don't. The interesting ones are in between.

**Needs the ground:**

- **Minimum altitude:** keeping a point above the terrain.
- **Speed**, when it's defined relative to the ground, so it's the same over hills and valleys.
- **Placing terrain in the volume:** to put the ground somewhere in the box, you need to know where it is.

**Doesn't need the ground:**

- **Immersive at human scale:** the world is presented at 1:1, without trying to line the ground up with the room’s floor. No terrain estimate is needed for that placement.
- **Far out:** terrain is at most about 9 km high, so at 1,000 km up the ellipsoid is close enough.

**In between: scale and placement.**

## Scale

Scale on its own doesn't need the ground. It can be:

- fixed, like human scale (1:1);
- set by the user, with a slider;
- a function of height above the ellipsoid.

In a single perspective image, rescaling the world about the viewing position leaves the image unchanged: objects change size and distance by the same factor. In VR two things let you perceive the difference:

- **Stereo:** your eyes are about 63 mm apart.
- **Parallax:** your head moves through real metres.

In VR, a small tower nearby can occupy the same amount of your view as a full-size tower far away. But the different views from your two eyes, and how the tower shifts as you move your head, let you perceive it as a nearby model. Stereo and parallax show the scale when things are close enough in the room: a few tens of metres for stereo, which works from your eyes' 63 mm, and further the more your head moves for parallax. The whole Earth can appear as a ball a metre away at model scale, and a small head movement reveals its depth. At 1:1 it's thousands of kilometres away: moving your head barely changes the view, which tells you it's distant, but gives little sense of just how far away it is.

**Placement is where the ground comes in.** To line the ground up with the room's floor or the volume's base plane, you need a terrain estimate.

### Human scale or model scale

Human scale preserves real-world distances, but far away it makes stereo and head-motion parallax negligible, so the world can read as a backdrop. In mixed immersion that sits next to a real room with full depth; in full immersion there's nothing near to move relative to. Model scale brings the world back into reach, so you can lean around it. A near frame of reference, such as a cockpit, vehicle or platform, is another way to keep depth cues while the world is far away.

### A scale change needs a fixed point

Changing the scale shrinks or grows everything about some point, and that point decides what you see:

- **About the point between your eyes:** everything gets nearer and smaller by the same factor, so the picture from that point doesn't change. Each eye sits slightly to one side, so its view changes a little, and so does the view when you move your head. Those changes are stereo and parallax, and they show things as smaller and closer.
- **About the Earth's centre:** the surface drops away below you, and what's on it shrinks and recedes until it disappears.
- **About a point on the map:** that point stays put and you seem to fly away from it.

### Easily confused with scale

These three change how size and depth look, but they come from the flat picture itself: where the viewpoint is and how wide its field of view is. Scaling about the point between your eyes changes neither, and in a headset the field of view is fixed by the optics.

- **Perspective distortion:** near things look stretched, as in a wide-angle selfie. It comes from being close, plus stretching toward the edges of a wide view.
- **Lens compression:** through a telephoto lens, depth looks squashed. It's really the distance; the long lens only crops a far-away view.
- **Dolly zoom** (the *Vertigo* effect): moving the camera while changing the field of view keeps the subject the same size while the background swells or shrinks. It needs a changing field of view.
