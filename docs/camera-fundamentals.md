# Camera fundamentals

The ideas behind how Also Maps places the camera and the world, for readers new to 3D and VR. [camera-core.md](camera-core.md) has the rules; this is the background.

## Heights

Three heights come up again and again:

- **Height above the ellipsoid** (`height` in the code): how far the camera is above a smooth mathematical Earth, WGS84. It needs nothing but the camera's position.
- **Terrain height:** how far the ground is above that ellipsoid at some point. It has to be estimated from the loaded tiles. Sea level (the geoid) sits up to about 100 m off the ellipsoid, which rarely matters here.
- **Altitude above ground level (AGL):** the camera's height minus the terrain height beneath it. It's only as good as the terrain estimate.

## Where the ground comes in

Some features plainly need the ground, and some plainly don't. The interesting ones are in between.

**Needs the ground:**

- **Minimum altitude:** keeping the camera above the terrain.
- **Speed**, when it's defined relative to the ground, so it's the same over hills and valleys.
- **Placing a view in the volume:** the map has to sit inside the box, so the ground has to land on its base plane.

**Doesn't need the ground:**

- **Immersive at human scale:** the camera is your eye, at 1:1, level, facing its heading. The ground ends up wherever it really is below you.
- **Far out:** terrain is at most about 9 km high, so at 1,000 km up the ellipsoid is close enough.

**In between: scale and placement.**

## Scale

Scale on its own doesn't need the ground. It can be:

- fixed, like human scale (1:1);
- set by the user, with a slider;
- a function of height above the ellipsoid.

Scale only matters in VR. On a flat screen, rescaling the world about the viewpoint gives exactly the same image, so you can't see the scale. In VR two things give it away:

- **Stereo:** your eyes are about 63 mm apart.
- **Parallax:** your head moves through real metres.

So in VR scale is something you perceive, not just a number: up close, a tower at 1:1,000 reads as a model, not as a real tower far away. Stereo and parallax show the scale when things are close enough in the room: a few tens of metres for stereo, which works from your eyes' 63 mm, and further the more your head moves for parallax. The same view of the whole Earth is a ball a metre away at adaptive scale, and a small head movement shows it; at 1:1 it's thousands of kilometres away, and nothing tells it from a huge distant planet.

**Placement is where the ground comes in.** Choosing a scale so that the ground lands on the floor (or on the volume's base plane) means scaling from AGL, and that needs a terrain estimate. Immersive does this today. Human scale doesn't, so its ground lands wherever it is.

### Human scale or model scale

Human scale is honest about distance, but far up it puts everything beyond the reach of stereo and parallax: moving your head changes nothing, and the world reads as a backdrop. In mixed immersion that sits next to a real room with full depth; in full immersion there's nothing near to move relative to. Model scale brings the world back into reach, so you can lean around it. A near frame of reference, such as a cockpit, vehicle or platform, is another way to keep depth cues while the world is far away.

### A scale change needs a fixed point

Changing the scale shrinks or grows everything about some point, and that point decides what you see:

- **About the point between your eyes:** everything gets nearer and smaller by the same factor, so the picture from that point doesn't change. Each eye sits slightly to one side, so its view changes a little, and so does the view when you move your head. Those changes are stereo and parallax, and they show things as smaller and closer.
- **About the Earth's centre:** the surface drops away below you, and what's on it shrinks and recedes until it disappears. That looks like climbing, and is equivalent to it.
- **About a point on the map:** that point stays put and you seem to fly away from it.

### Easily confused with scale

These three change how size and depth look, but they come from the flat picture itself: where the viewpoint is and how wide its field of view is. Scaling about the point between your eyes changes neither, and in a headset the field of view is fixed by the optics.

- **Perspective distortion:** near things look stretched, as in a wide-angle selfie. It comes from being close, plus stretching toward the edges of a wide view.
- **Lens compression:** through a telephoto lens, depth looks squashed. It's really the distance; the long lens only crops a far-away view.
- **Dolly zoom** (the *Vertigo* effect): moving the camera while changing the field of view keeps the subject the same size while the background swells or shrinks. It needs a changing field of view.
