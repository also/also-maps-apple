# Fundamentals

The ideas behind how Also Maps places the world, for readers new to 3D and VR.

This doc describes the options, not what the app must do. Where the app's current behavior matches one of them, that's one choice among several. These choices should be cheap to change, can differ by mode, and more than one can exist at once. Nothing here is a rule.

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
- **Placing the ground:** to put the ground on the room's floor or somewhere in the volume, you need to know where it is.

**Doesn't need the ground:**

- **Immersive at human scale:** the world is presented at 1:1, without trying to line the ground up with the room’s floor. No terrain estimate is needed for that placement.
- **Far out:** terrain is at most about 9 km high, so at 1,000 km up the ellipsoid is close enough.

**In between: scale and placement.** Scale alone doesn't need the ground. Placement can, and one way of placing the ground also sets the scale. The next two sections cover them.

## Scale

Scale on its own doesn't need the ground. It can be:

- fixed, like human scale (1:1);
- set by the user, with a slider;
- a function of height above the ellipsoid.

It can also be a function of AGL, and then it does need the ground ([Placement](#placement)).

In VR the headset draws two images, one for each eye, each from where that eye really is in the room, with a field of view fixed by the optics. What can change is where the world sits in the room: its scale, rotation and position. Scale changes how big the world is in the room's own meters, and two things make that visible:

- **Stereo:** your eyes are about 63 mm apart, and the world's scale doesn't change that.
- **Motion parallax:** your head moves through the room, and the view shifts as it does. The world's scale doesn't change how far your head moves.

In VR, a small tower nearby can occupy the same amount of your view as a full-size tower far away. But the different views from your two eyes, and how the tower shifts as you move your head, let you perceive it as a nearby model. Stereo and motion parallax tell you how far away things are in the room, and distance together with apparent size tells you the scale. Both work only when things are close enough: stereo out to a few tens of meters, because it works from your eyes' 63 mm, and motion parallax further, the more your head moves. The whole Earth can appear as a ball a meter away at model scale, and a small head movement reveals its depth. At 1:1 it's thousands of kilometers away: moving your head barely changes the view, which tells you it's distant, but gives little sense of just how far away it is.

**A flat screen is different.** It shows one image, drawn from one point. Rescaling the world about that point leaves the image unchanged: objects change size and distance by the same factor. So on a flat screen the world's scale can't be seen, and moving the camera does everything. VR has no such point, because each eye's image is drawn from a different place.

### Human scale or model scale

Human scale is 1:1. Model scale is anything much smaller, so the world appears as a model in the room.

Human scale preserves real-world distances, but far away it makes stereo and motion parallax negligible, so the world can read as a backdrop. In mixed immersion that sits next to a real room with full depth; in full immersion there's nothing near to move relative to. Model scale brings the world back into reach, so you can lean around it. A near frame of reference, such as a cockpit, vehicle or platform, is another way to keep depth cues while the world is far away.

### A scale change needs a fixed point

Changing the scale shrinks or grows everything about some point, and that point decides what you see. When the world shrinks (growing is the reverse):

- **About the point between your eyes:** everything gets nearer and smaller by the same factor, so the picture from that point doesn't change. Each eye sits slightly to one side, so its view changes a little, and so does the view when you move your head. Those changes are stereo and motion parallax, and they show things as smaller and closer. This point is your real head, wherever it is at that moment. A scale change about a fixed point in the room, such as a reference head pose ([Easily misused terms](#easily-misused-terms)), leaves the picture unchanged only while your head is there.
- **About a point on the ground that sits on the floor:** that point stays on the floor, so the ground stays lined up with the floor there. The ground spreads out from that point or draws in toward it. If the point is at your feet, shrinking the world looks like rising straight up above it, and growing it looks like descending. This is what choosing the scale from AGL does ([Placement](#placement)): raising the point whose AGL sets the scale and shrinking the world are the same change.
- **About the Earth's center:** the surface drops away below you, and what's on it shrinks and recedes until it disappears.
- **About any other point on the map:** that point stays put and you seem to fly away from it.

Only the fixed point keeps its place in the room. If the ground was lined up with the floor and the fixed point isn't on the floor, the ground moves off the floor and has to be placed again.

### Easily confused with scale

These three change how size and depth look, but they come from a single flat picture: where it's taken from and how wide its field of view is. Scaling about the point between your eyes changes neither, and in a headset the field of view is fixed by the optics.

- **Perspective distortion:** near things look stretched, as in a wide-angle selfie. It comes from being close, plus stretching toward the edges of a wide view.
- **Lens compression:** through a telephoto lens, depth looks squashed. It's really the distance; the long lens only crops a far-away view.
- **Dolly zoom** (the *Vertigo* effect): moving the camera while changing the field of view keeps the subject the same size while the background swells or shrinks. It needs a changing field of view.

## Placement

Placement decides where the scaled world sits in the room or the volume. **Placement is where the ground comes in.** To line the ground up with the room's floor or the volume's base plane, you need a terrain estimate. There are two ways to line it up:

- **Keep the scale and move the world** up or down until the ground meets the floor. The scale stays independent of the ground.
- **Choose the scale** so that a point at a known AGL lands at a chosen height above the floor: scale = height above the floor ÷ AGL. The scale then depends on the terrain estimate too. As the AGL changes, the world scales about the ground point on the floor ([A scale change needs a fixed point](#a-scale-change-needs-a-fixed-point)).

A mode can use either, or not line the ground up at all.

## Tilt

TODO.

## Design considerations

Observations and opinions from using this app and others. They are about what the experience is like, not how to build it.

### Choices of scale

- **Human scale (1:1).**
  - It's easy to build, easy to understand and consistent, and good to have as an option.
  - Moving around the room is most interesting when the world's content is close, and pointless when it's far.
  - It suits a flight simulator, a "street view" or driving. Seeing much depends on moving the world, not yourself.
  - When you can see a lot of the world because you're far from it, it's disappointing that you can't put your head near it to see it from another angle or in more detail. It's far away.
- **A fixed small scale, or a scale the user sets directly,** not derived from position. This is more interesting than human scale. An app limited to it would still be a good use of VR.
- **A scale that varies as you move.** Moving around freely, anywhere from street level to orbit, pushes you toward this.
  - Near content, the scale is at or close to human scale, so it doesn't look like you're flying around a small model. Further away, it's smaller.
  - You can miss the cues that the scale has changed, and go on perceiving steady flight.
  - At any point you can still move around the room and see the content from another angle, or feel like a giant.
- **There is no well-defined, obvious scale for a given point in the world.**

### Scale changes

A scale change about your head is noticeable and close to disconcerting. Everything changes distance at once, so your eyes have to re-converge, and it can feel like crossing your eyes for a moment.

It's worst when it's out of proportion to any other change or motion:

- crossing a threshold, such as an altitude line or an exact distance to the mesh or the ground;
- a toggle, such as human scale, flipped while nothing is moving.

### Getting the ground

With cesium-native and Google's 3D tiles, it can be surprisingly hard to get data that exists, and the data you want may not be provided at all.

- **The tiles have no "ground".** They are a mesh that includes buildings and other features.
- **The mesh under a point changes as tiles load.** A less detailed tile can load first and be replaced by a more detailed one for the same place, with different heights. A height read from the tiles loaded for rendering changes with them.
- **Or you fetch more detail than you need.** cesium-native's `sampleHeightMostDetailed` always gives the most detailed height. To do that it fetches tiles more detailed than rendering needs at greater distances, and the answer arrives later.

## Easily misused terms

**Camera**, **viewpoint** and **eye** have no single meaning in VR, and this doc doesn't give them one. They come from 3D on a flat screen, where there is one image, drawn from one point, and the app decides where that point is. There, "camera" is clear enough. In VR there are two images, and the app doesn't decide where either is drawn from, so the words have nothing definite to attach to. Each has been used for all of these, often without saying which:

- the current head pose;
- a reference head pose: a fixed pose chosen to stand in for the head pose;
- where one eye's image is actually drawn from;
- the navigation position: the point in the world that input moves.

These are four different things, and they are rarely in the same place. A sentence like "the camera is the eye" could mean almost any pair of them.

So avoid the three words when writing about VR, and name the thing you mean. When you read one of them in a doc, an issue or a name in the code, don't assume which meaning was intended: work it out from what the text or code does, or ask.

### What to say instead

- **Head pose:** the tracked position and orientation of the headset in the room, changing all the time. VR normally uses this one value for the head, the eyes and the device together, though they aren't the same place: the tracked point is near your eyes, not at the middle of your head, so turning your head moves it by several centimeters. Each eye's own position and field of view are worked out from the head pose when the images are drawn, usually by the system, using the distance between your eyes. Most of an app never needs the separate eye positions, and may not be given them. An app may not be given the head pose either: visionOS provides it only in an immersive space, not in a volume.
- **Reference head pose:** a stable stand-in for the head pose, for anything that shouldn't move every time your head does. It almost never matches the current head pose exactly. It can be:
  - an estimate or default, such as 1.6 m above the floor at the room's origin. That is a standing height, and a seated head is nearer 1.2 m;
  - the head pose at some moment, such as when you recentered, if the app can get it;
  - a mix: some parts taken from the recenter and others chosen. For example, the position and heading from the recenter, but looking level or slightly down, even if your head was tipped toward the ceiling at the time.

Anything worked out from a reference head pose is exact only while your head is there. When you write about where something is seen from, say which you mean: the current head pose, a reference head pose, or one eye's position. The navigation position is none of these.

### Navigation position

The **navigation position** is the point in the world that input moves: a latitude, a longitude and a height. That is all it is. No image is drawn from it, and nothing about it says where it sits in the room. Where it sits is a placement choice, and the choice decides what it means. It's easy to use words that give it more meaning than it has, such as "you", "the viewer", or the three words above.

Two examples of roles it could play:

- **Where you are.** The navigation position is put at a reference head pose, so it stands for you in the world, and its height is how high up you are. You can't look at it, because you're at it. The ground at its latitude and longitude is directly beneath you, so seeing that means looking straight down, which isn't a natural or comfortable way to hold your head. What you look at is somewhere else. With the world level, a comfortable place to look on the ground is ahead of you: looking 30° below level, about 1.7 times your height above the ground. How far that is depends on which meters you count:
  - **On the Earth,** it grows with your AGL: 3 m ahead at standing height, 1.7 km ahead at 1 km up.
  - **In the room,** it's the distance on the Earth times the scale. At 1:1 the two are the same. If the scale follows AGL, so the ground is on the floor and you're at standing height above it, the spot is always about 3 m in front of you on the floor. What changes as you go up is which place on the Earth is there.
- **What you're looking at.** The navigation position is put at a point in what's shown, such as the horizontal center of a volume. It then stands for the place on show, not for you. Its height doesn't say how high up you are, and how much is shown comes from the scale.

Roles like these give different answers to the same request. To go to a place, "what you're looking at" puts the navigation position on the place, and "where you are" has to put it some way back from the place, further back the higher up it is.

In an immersive space, "where you are" is a rough fit. A volume is harder, because you are never inside it. Two of the possible ways to handle it:

- use "what you're looking at", with the navigation position at the volume's horizontal center;
- keep "where you are", and treat the volume as a small slice of what the immersive view would show, with the navigation position at a reference head pose outside the volume.

Using one description for both an immersive space and a volume is confusing unless it says which role the navigation position has in each.
