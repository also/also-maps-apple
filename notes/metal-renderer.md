# Metal renderer: working notes

Notes on the experimental Metal renderer (Settings › Advanced › Draw with
Metal): how its performance work fits together, how to measure it, and a
running log of what was found, newest first. **Observed** means seen on a
device or in logs. **Inferred** means a hypothesis that fits the evidence but
wasn't confirmed.

## How it works

### Culling

The renderer culls against the actual render camera before binding buffers
and textures and encoding indexed draws. Whole tiles are tested first; tiles
with several primitives also get a per-primitive test. This targets detailed
geometry behind the viewer and outside the viewport. It doesn't detect
geometry hidden behind other buildings.

It's render-only. Tile selection, refinement, loading and the all-around
streaming area are unchanged, so turning around can immediately draw content
that's already loaded. Each eye is tested separately, from its current
compositor projection and predicted pose. Held (Fly) tiles use their current
render transform, like live tiles.

Bounds are computed once from the uploaded positions, before the CPU buffers
are discarded. A box is rejected only if it's wholly outside a homogeneous
clip plane. Crossing the eye or near plane, or touching a frustum boundary,
keeps it drawable, and so do missing bounds. Reverse Z, asymmetric eye
projections and tile and root transforms all go through the same clip matrix
as the vertex shader. The core test target covers these cases without a key
or GPU.

### Foveation (visionOS)

The immersive space enables foveation when the compositor supports it with
dedicated eye textures, and binds each texture's rasterization-rate map to its
render pass. Unsupported configurations keep the unfoveated dedicated or
shared layout. Stereo still uses a separate draw loop per eye; vertex
amplification would be a later change.

## Measuring

Environment variables:

- `ALSOMAPS_METAL=1`: use Metal for this run.
- `ALSOMAPS_METAL_STATS=1`: log submission counts once a second on macOS,
  iOS and immersive visionOS.
- `ALSOMAPS_METAL_CULLING=0`: turn culling off, for a baseline. On by default.
- `ALSOMAPS_METAL_FOVEATION=0`: turn visionOS foveation off, for a baseline.
  On by default where the dedicated layout supports it.

The log reports submitted out of considered tiles, draws and triangles,
summed over the interval. "Considered" is what would be submitted with
culling off, so one run gives both numbers. Stereo counts each eye
separately. These are CPU submission counts, not presented frames a second;
the screen FPS overlay counts RealityKit updates, and the immersive log counts
frame-loop iterations.

`MetalEncode` signposts (subsystem `dev.also.maps`, category `Frame`) cover
culling and draw encoding for one view; record and summarise them as in
[docs/profiling.md](../docs/profiling.md). Use Metal System Trace or GPU timing
for GPU execution and missed deadlines: fewer submitted triangles alone don't
prove a frame-rate gain.

For a controlled comparison, use a fixed saved view (New York at street level,
say) with culling on and off, the same drawable resolution and detail
settings, and a deliberately warm cache for both runs
([docs/tile-caching.md](../docs/tile-caching.md)). Measure settled idle,
movement and streaming separately. Check a full turn, the view's edges, both
eyes and near-plane crossings for missing geometry. On Vision Pro, compare
foveation separately with culling held fixed, and check peripheral image
quality, both eyes and compositor depth. The simulator can't show foveation
quality.

## Log

### 2026-11-03: culling and foveation on a Vision Pro

- **Observed:** with #33 (culling and foveation) against #32 (neither), the
  frame rate didn't look noticeably different, but the image looked much
  better: #32 looked aliased and #33 didn't. Nothing else looked wrong.
  Judged by eye; no counters or traces.
- **Inferred:** the image difference is foveation, not culling, which only
  skips off-screen geometry. Neither branch multisamples. Unfoveated eye
  textures have one uniform pixel density, while the foveated ones render
  where you look at a higher density. Untested: running #33 with
  `ALSOMAPS_METAL_FOVEATION=0` should look like #32 if so.

### 2026-11-03: culling on macOS

- **Observed:** default view (San Francisco), Metal with
  `ALSOMAPS_METAL_STATS=1`, one second's totals over 59 frames: tiles
  16,166 of 28,143 submitted, draws 18,703 of 31,152, triangles 12,248,872 of
  19,213,704. About 43% fewer tiles and 36% fewer triangles. One view, one
  sample, submission counts only.
- **Observed:** with a Google Maps key and Metal on, New York rendered in the
  Mac window and the submission counters were active.
