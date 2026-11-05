# How navigation should feel

Written 2026-11-05. This is the human-terms companion to [camera-core.md](camera-core.md) (the mechanism) and [navigation-handoff.md](navigation-handoff.md) (what the owner decided). It describes what using the app should be like, how that changes with mode, altitude and scale, and what VR and Google's tiles allow.

**Limits here are real-world limits:** human perception, headset hardware, and what the tile data contains. Today's implementation is never a limit; where it falls short of these goals, that's a bug or a design to change. Code appears only in §10, to diagnose bugs, and numbers taken from it (such as the 55 m minimum altitude) are current settings used as examples, not constraints.

Each claim is marked:

- **Owner:** decided by the project owner (from the hand-off note or this request).
- **Proposal:** a suggestion, not decided.
- **Observed** or **Inferred:** a finding about the code or the data, as in `notes/`.
- Statements about VR perception are general knowledge from the field, not measured in this app unless marked Observed.

## 1. Who it's for, today

**Owner.** The user today is mostly the owner: someone who wants to play around and look at things, and for whom it's cool when it feels like flying. Not a task tool, not a wayfinding app, not a training simulator.

That sets priorities:

- **Delight beats precision.** It matters more that climbing over a ridge feels good than that the altitude readout is right to the metre.
- **Freedom beats guard rails,** except where a guard rail stops something that breaks the illusion (falling through the ground, the world lurching on its own).
- **Exploring beats arriving.** Places are starting points; the time is spent drifting, circling and looking.
- **Later users** (spatial visualisation, drawing) will need more predictable, precise behaviour. Design so that can be added as a mode, not so today's feel has to anticipate it.

## 2. What it should feel like, in any mode

These are the experience goals the mechanism must serve. Most restate the owner's decisions in felt terms.

1. **You are flying, not operating a map.** (Owner: flight-sim feel, "like Google Earth VR".) Input moves *you*; the world stays where it is.
2. **The world never moves by itself.** Nothing tilts, rescales, slides or jumps unless you asked for it, or unless it's a deliberate, gentle, explainable transition (a toggle, a place jump). A changing estimate, a tile finishing loading, a host switch or a head turn must never visibly move the world. This is the goal the recent bugs broke most often (§10).
3. **Level means level.** (Owner.) In VR, the floor defines level. When the ground is meant to look flat, it *is* flat with the floor; when it's tilted, that's a choice the mode made, and you could say why.
4. **The ground is solid.** You can skim it, but you never see it from underneath, and you never find yourself inside a hill.
5. **Speed feels the same everywhere.** (Owner: speed scales with height above the ground.) A second of "forward" covers the same fraction of what you see at 100 m and at 100 km, over a valley and over a ridge.
6. **What you grab stays in your hand.** (Owner.) Drag, pinch and twist feel like handling a physical thing.
7. **Detail comes in where you are and where you look,** nearest first (owner), and what has loaded doesn't flicker away while you look at it.
8. **Climbing, turning and moving behave the same in every host.** (Owner.)

## 3. Two ways to be in the map: pilot and giant

A map in VR has a property a flat map doesn't: **scale**. How big the world looks is a separate choice from where you are. Two metaphors help.

### Pilot (fixed human scale)

The world is life-size. Your eye is a real eye at the camera's height. At 1,000 m the ground is really 1,000 m below, so in stereo it's flat and infinitely far, like the view from a plane window. To cross a city you must move fast, and the world rushes past.

- **Good at:** standing in a plaza, flying along a street, the thrill of real height.
- **Bad at:** anything above a few hundred metres. Depth from stereo vanishes beyond a few tens of metres, so the landscape reads as a painting. Crossing a region takes minutes, or speeds that are hard to watch.

### Giant (adaptive scale, today's immersive default)

The world shrinks as you climb so the ground under you always sits on the floor, and your eye is always at your real eye height (about 1.6 m) above it. **Climbing is growing; descending is shrinking.** At 55 m altitude you're a 34× giant; at 500 km you're standing on a ball about 40 m across.

Two consequences in plain terms:

- **The floor always passes at walking pace.** Moving at 0.75 × altitude per second, scaled to the room, is about 1.2 m/s at every altitude. That's why speed-from-altitude feels natural here: you walk; the world's scale does the rest.
- **Giant at eye height is pilot.** If the giant descends until altitude equals eye height, the scale reaches 1:1. Adaptive scale is human scale continued upward. That makes moving in and out of human scale automatically (which the owner finds interesting) a matter of *where the shrinking stops*, not a separate mode (§7).

- **Good at:** everything from neighbourhood to planet. Terrain has real stereo depth because it's metres away in the room. You feel the landscape's shape.
- **Bad at:** low, close work. Nearby buildings become small objects very close to your face (§7), and the world's size changes whenever "the ground under you" changes, which is exactly the estimate we don't have reliably (§8).

### Model (the volume)

The map is an object in a box you look into, like a model on a table. You don't stand in it; you look at it from outside, from a fixed viewpoint in front. Tilting a model toward you to see it better is natural here in a way it isn't when you stand in the world. "Flying" in the volume is moving the model under your gaze.

### Flat screens (Mac, iPhone, iPad)

**Scale doesn't exist on a flat screen.** With one eye and no head movement, a world scaled about the camera looks identical. Only speed, field of view and pitch are left. "Level" means the camera's pitch (owner). Flat screens get speed-from-altitude and the same flight controls, but none of the scale and tilt questions in this document.

## 4. How it should vary with altitude

Heights are above the ground under you. The bands are rough.

| Band | What you're looking at | What you want to do | What feels right | What limits bite |
|---|---|---|---|---|
| **Street** (under ~20 m) | Facades, street furniture, trees | Stand somewhere, look around, drift along a street | Pilot scale; walking-to-running speeds; level always | The data is worst here: melted facades, blobby trees, no interiors (§9). Walls are as close as the ground, so collisions matter sideways, not just below. |
| **Rooftop / drone** (~20–300 m) | Blocks, building shapes, parks, the city's grain | Weave between towers, follow a river, circle a landmark | Giant or pilot; level; speed from the *nearest* surface, not just the ground (§6) | Tall buildings beside you are closer than the ground below. Ground under you jumps at every roof edge (§8). |
| **City** (~300 m–10 km) | Whole districts, the shape of a city against hills and water | Survey, find things, get somewhere | Giant; level; ground on the floor | The ground under you varies by hundreds of metres in hilly places; the "lowest ground in view" sits on the floor, so hills rise toward your eye (§8). |
| **Region** (~10–200 km) | Mountain ranges, coastlines, the curve beginning | Travel between places, appreciate terrain | Giant; level, with the Earth starting to curve away like a dome; detail far out matters less | To see the horizon you look down at the floor; far terrain is many room-metres away. |
| **Planet** (above ~200 km) | The globe | Spin it, pick somewhere to go | A globe in front of you, like holding or facing a planet, not standing on it | A level ground is mostly below the floor and behind you; this is why some tilt is needed (§5). |

Moving through the bands should be continuous for the drone mode: climbing from a plaza to orbit is one motion. **Owner:** in a Google Earth VR-style mode, the planet band is behind a toggle instead (§5).

## 5. How it should vary with mode

| Mode | Status | The feeling | Tilt | Scale |
|---|---|---|---|---|
| **Drone** (immersive) | Today | You're a drone pilot riding the drone: you fly anywhere, climb to orbit in one go | **Owner:** the ground is level. Far up, some tilt helps so you needn't look straight down; the current tilt-with-altitude curve (none below 50 km, a quarter turn by 500 km) is arbitrary and tunable | Giant |
| **Ground / globe** (Google Earth VR-style) | Future | Two distinct experiences: standing over the land, or facing a planet. A button switches between them with a short, deliberate transition | **Owner:** ground is level, globe is fully tilted toward you; nothing in between except during the transition | Giant; ground mode has a ceiling, globe mode a floor, and the ranges overlap |
| **Human scale** | Test toggle today | You're life-size, flying; a real sense of height and speed | Level always | Pilot |
| **Volume** | Today | A model on a table that you fly over | The model can tilt toward you, as you'd tilt a model; at low altitude it should look level with the box | Model |
| **Flat screen** (Mac, iPhone) | Today | A flight view on a screen, or orbit/pan/zoom on the Mac | Camera pitch | None |

**Tilt by altitude versus tilt by toggle.** Altitude-driven tilt is convenient (no button) but makes tilt depend on altitude, and altitude depends on a ground estimate, so tilt inherits the estimate's noise. A toggle makes tilt a pure choice that nothing can disturb. **Proposal:** if the drone keeps an altitude curve, compute it from something that changes only when you climb (the camera's height above a coarse, slowly varying ground), never from the per-frame estimate.

## 6. Speed and distance from the ground

**Owner:** speed scales with height above the ground under you.

### Is it natural? Yes, with care about *which* distance

- **Why it feels right.** What you perceive is not metres per second but how fast the scene sweeps past your eye. For ground directly below, that's speed ÷ height. Keeping speed proportional to height keeps the sweep constant (at 0.75 × height per second, about 43° per second below you). Pilots judge low flight by this, and every map that zooms works this way.
- **In giant scale it's built in:** the floor passes at walking pace (§3).
- **Where it breaks:** speed ÷ distance is about the *nearest thing in view*, and the ground below isn't always that.
  - **Beside a tower.** At 55 m over a street, moving at ~40 m/s, a facade 10 m to your side sweeps past at about 4 rad/s. That's dizzying and makes precise weaving impossible.
  - **Toward a cliff or hillside.** The ground below is far; the slope ahead is close. You reach it at a speed set by the valley floor.
  - **Over an edge.** Flying off a roof or a cliff, "height above the ground" jumps from 20 m to 200 m and speed jumps tenfold in a frame. Feels like hitting a boost you didn't press.
  - **Through a canyon or between buildings,** the speed depends on which surface the estimate happened to pick.

### Proposal

- **Speed from the nearest surface around you,** not just below: the smaller of height above the ground and distance to the closest surface ahead and to the sides, within a modest radius.
- **Slow down quickly, speed up slowly.** When something comes close, slow within a fraction of a second; when it falls away (off a roof edge), regain speed over a second or two. Unexpected slowing feels safe; unexpected surging feels like losing control.
- **Climbing** scales the same way (it already changes height by a fixed fraction per second).
- **The same idea gives a gentle floor:** if speed falls as you approach any surface, you ease to a stop near it instead of hitting a hard clamp (§8).

## 7. Should scale change when you come close to buildings sideways?

In giant scale, the world's size is set by the ground below you. A building beside you doesn't change it. Should it?

### Why it might

- **Comfort at close range.** At 55 m altitude (scale 1:34), a facade 10 m away is 30 cm from your eyes in the room. Eyes converge on it but focus at the headset's fixed focal distance; inside roughly half a metre that mismatch becomes uncomfortable, and geometry can clip against the near plane. Making the world bigger as you approach (shrinking you toward human scale) keeps close surfaces at a comfortable distance.
- **Seeing the thing you came to see.** Weaving between towers as a 34× giant, the towers are knee-to-waist-high blocks. Shrinking as you get close makes them tower over you, which is the experience of weaving between towers.
- **It's the automatic in-and-out of human scale the owner finds interesting.** Close to anything, you become small; out in the open, you grow.

### Why it might not

- **It moves the world.** Scale changes about your eye, so everything else in view grows or shrinks as you pass a building. That's the world moving by itself (§2.2) unless it's slow and clearly tied to what you're doing.
- **Approach feels faster than it is,** because looming (things growing as you approach) is the main cue for approach speed, and rescaling adds to it.
- **Passing a row of buildings** would make the scale pump unless it's heavily smoothed.
- **It needs a trustworthy "nearest surface"** (§8), which is hard with the data.

### Proposal

- **Not for the drone mode by default.** Use nearest-surface distance for *speed* (§6), which fixes most of the "too fast near buildings" problem without moving the world.
- **Do try it as an experiment** with the scale set by the smaller of height above ground and a multiple of horizontal clearance, eased over a second or more, and limited to rooftop altitudes. Judge it on the headset; it's a feel question, not a correctness one.
- **A deliberate version may be better:** a "get closer" action (or descending below the giant's floor) that eases you down to human scale, and back up when you climb. That's the shrinking the owner finds interesting, under your control.

## 8. Knowing where the ground is

### Why it matters

We place tiles as if they're on the ground at a scale, so the app needs to know where "the ground" is for several different jobs. In human terms:

1. **What's on the floor** (giant scale): which ground surface sits at the room's floor. It sets the world's size. If it's wrong, the world is the wrong size and hills poke through the floor or float above it.
2. **How fast you go** (§6): distance to the nearest surface.
3. **What stops you:** the surface you can't pass through.
4. **What tilts, if anything:** a tilt computed from altitude needs a ground to measure from.

These want different things. (1) and (4) want something *stable*: if it changes, the world moves. (2) wants something *local and quick*. (3) wants something *exact and conservative*: better to stop a little early than pass through.

Any design will need answers for all four. §10 looks at how the current code answers them and where that produces bugs.

### What "the ground" even is, with this data

- **Google's tiles don't separate ground from buildings or trees.** The mesh is one skin over everything. Directly below you might be a street, a roof, a treetop or a bridge deck. There's no bare-earth layer.
- **Before detail loads, the mesh is coarse.** A coarse tile's lowest vertex can be kilometres below the real surface (−10,500 m was seen near San Francisco).
- **Heights are above the WGS84 ellipsoid,** not sea level. Over most of the world the difference is tens of metres; it's irrelevant to feel but matters when mixing in other data.
- **Asking "how high is the ground here" may need tiles that aren't loaded yet,** so answers arrive late, after the moment they were needed.

### What should be on the floor

Two reasonable answers with a real trade-off:

- **The ground under you.** Natural (your eye is always exactly eye-height above what's below), but it changes constantly over hills, roofs and cliffs, and each change resizes the world.
- **The lowest ground in view** (today, roughly). Stable and keeps everything at or above the floor, but over a hill the ground under you is above the floor, so the hill is closer to your eye than "eye height". In rugged places (Ronda was noted) your eye can be inside terrain.

**Proposal:** put a *smoothed, low* ground on the floor — terrain-like, ignoring buildings and treetops, averaged over the area you can see nearby, changing only slowly — and accept that local bumps rise above the floor. Guard the eye separately with job (3). Rooftops should never be "the floor".

## 9. Limits

### VR

- **Stereo depth only works up close.** Beyond a few tens of metres in the room, depth comes from parallax, size and occlusion. This is why giant scale feels more 3D than pilot scale above street level.
- **Very close is uncomfortable** (§7): inside roughly half a metre, focus and convergence disagree.
- **Motion you don't feel can make you sick.** Smooth constant-speed travel is usually fine; acceleration, smooth turning, vertical bobbing, and the world moving while you're still are the main triggers. This argues for easing speed changes, keeping turns gentle (or offering snap turns), and above all for §2.2: the world must not move on its own.
- **Ground flowing under your feet is a strong motion cue.** Giant scale puts the ground right at your feet, so drift there is very noticeable. Small wobbles in scale or tilt that'd be invisible on a screen are felt.
- **You're probably seated.** Looking down far is tiring; looking straight down at the floor is awkward. Content you need to see often should be ahead and somewhat below.
- **The real floor and the map's floor compete,** especially with passthrough. **Owner:** full immersion first.
- **The volume has no head pose,** so its detail is chosen for an assumed viewer. Only immersive spaces can track the head.

### Data (Google Photorealistic 3D Tiles)

- **Street level is the weakest view.** Photogrammetry is built from aerial imagery: facades are smeared, overhangs and arcades are filled in, trees are blobs, there are no interiors, and fine things (poles, signs, people) are missing or melted. The data is at its best from rooftop height up.
- **Coverage varies.** Many cities have full 3D; elsewhere it's terrain with imagery. A building-weaving experience works in some places only.
- **One skin over everything:** no separate terrain, buildings, water or vegetation (§8). Ground-finding, collision and "stay above the terrain" can't ask the data what's what.
- **Detail arrives late.** Tiles stream over the network; what's under you may be coarse or missing for a second or more after you arrive, especially after a jump or fast travel. Anything that relies on the mesh (ground height, collision) must handle "not known yet".
- **Coarse tiles lie about height** (§8), so estimates must use only detailed-enough tiles, and must not follow every new tile.
- **Terms of use** limit caching and require attribution; held tiles and recordings have to respect them (see the README and [tile-caching.md](tile-caching.md)).

### What this means for some use cases

| Use case | Fit | Why |
|---|---|---|
| Soaring over a city or mountains | Great | Rooftop-up is where the data shines and giant scale gives depth |
| Planet-to-street in one motion | Good | Needs stable ground and tilt; the hard part is the bottom end |
| Walking a street at human scale | Weak | Data quality, no interiors, and collision with walls needs a ground/wall estimate the data can't directly give |
| Weaving between towers | Promising | Needs nearest-surface speed (§6) and maybe a scale change (§7) |
| Precise measurement or drawing on the ground | Later | Needs a trustworthy surface query at the point, not an estimate |

## 10. What the recent bugs were really about

The owner reports frequent bugs with tilt, ground estimation, the viewpoint passing through the ground despite a ground estimate, and the volume showing tilted ground below the tilt threshold. In human terms, each is a case of **the world moving by itself** (§2.2) or **the ground not being solid** (§2.4), and each traces to one value doing several jobs.

- **Tilt glitches.** Tilt has been derived from something else: first from the camera's pitch, then from altitude. Altitude depends on a ground estimate, so when the estimate moves, tilt moves. **Inferred:** any tilt computed from an estimate will wobble when the estimate does. Tilt should be a choice (toggle), or follow only what you did (climbing).
- **Ground estimation.** "The ground" means four things (§8) and the data gives none of them directly. **Inferred:** much of the churn has come from finding one estimate that's stable enough to place the world, fast enough for speed, and exact enough to stop you.
- **Passing through the ground despite an estimate.** **Observed** in the code: the floor that stops you (`NavigationContext.clampHeight`) uses the camera ground estimate, which:
  - looks only directly below you (within max(20 m, 5% of altitude)), not ahead or to the sides, so you can fly horizontally into a hillside or a building and are only pushed up once you're over it;
  - updates only from tiles fine enough to trust, so after fast travel or a jump it can keep an old value (it's reset to 0 m, sea level, on a place jump) until detail loads;
  - eases toward new values rather than snapping;
  - takes the *lowest* point in its radius, so between buildings it finds the street, not the roofs.

  Meanwhile, what's drawn is the full mesh. **Inferred:** "the estimate says I'm 55 m up" and "I'm inside that hill" are both true because they're about different surfaces at different times. A solid ground needs its own job (3) answer: conservative, looking ahead, and stopping (or slowing, §6) when the answer is "not known yet".
- **The volume tilted below the tilt threshold.** **Observed:** the immersive space moved to the eye-level model (`2cdf8b1`), where tilt is explicit. The volume still uses the adaptive model, where the map's orientation comes from the camera's pitch: the map is level only while the pitch equals the angle from the volume's assumed eye to its centre point. **Inferred:** the pitch is only steered back to that angle while you climb or zoom and for a moment after a host switch. Anything else that leaves the pitch off it (a gesture whose solve stops short, a restored view or a track played back from another host, the horizon limit) leaves the volume's ground tilted at any altitude, so the 50 km threshold doesn't protect it. That's the rejected "tilt derived from pitch" rule, still live in the volume. Moving the volume to an explicit tilt, as the immersive space was, should fix this class of bug.

### A rule of thumb for future work

Before adding anything that can move the world (scale, tilt, position), ask: **would a person, at that moment, say they did that?** If not (it changed because an estimate settled, a tile loaded or a mode recomputed) it should be a stable choice, very slow, or not visible at all.

## 11. Open questions for the owner

1. **Drone tilt:** keep an altitude curve, switch to the ground/globe toggle, or both as options?
2. **The floor:** the ground under you, or a smoothed terrain-like ground with local bumps rising above the floor (§8)?
3. **Speed near buildings:** adopt nearest-surface speed (§6)?
4. **Scale near buildings:** worth an experiment (§7), and automatic or deliberate?
5. **Bottom of the giant:** should descending to street level ease into human scale, making the two one continuous mode?
6. **The volume:** is it still a primary way to fly, or mainly a control panel and overview now that immersive is the focus? It decides how much effort its tilt model deserves.
7. **Solid ground versus freedom:** stop at the ground (hard), slow near it (soft), or allow passing through with a clear visual cue (useful for exploring, but breaks the illusion)?
