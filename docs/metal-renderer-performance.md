# Metal rendering performance

The experimental renderer culls content against the actual render camera
before binding buffers/textures and encoding indexed draws. Whole tiles are
tested first; tiles with several primitives also get a per-primitive test.
This targets detailed geometry behind the viewer and outside the viewport.
It does not detect geometry hidden behind other buildings.

This is **render-only culling**. Tile selection, refinement, loading, and the
all-around streaming area are unchanged. Turning around can immediately draw
content that is already loaded. Each eye is tested separately from its current
compositor projection and predicted pose. Held/Fly tiles use their current
render transform, just like live tiles.

Bounds are computed once from the uploaded positions, before discarding the
CPU buffers. A box is rejected only if it is wholly outside a homogeneous
clip plane. Crossing the eye/near plane or touching a frustum boundary keeps
it drawable; missing bounds keep content drawable. Reverse Z, asymmetric
eye projections, and tile/root transforms use the same clip matrix as the
vertex shader. The core test target exercises these cases without a key or GPU.

On visionOS, the renderer also enables foveation when the compositor supports
it with dedicated eye textures, and binds each texture's rasterization-rate
map to its render pass. This reduces peripheral pixel work while keeping the
same projections and per-eye culling. Unsupported configurations retain the
unfoveated dedicated/shared layout. Stereo still uses a separate draw loop
per eye; vertex amplification is a later change.

## Counters and A/B comparison

Environment variables:

- `ALSOMAPS_METAL=1`: use Metal.
- `ALSOMAPS_METAL_STATS=1`: log submission counts once per second on macOS,
  iOS, and immersive visionOS.
- `ALSOMAPS_METAL_CULLING=0`: disable render culling for a baseline run.
  Culling is enabled by default.
- `ALSOMAPS_METAL_FOVEATION=0`: disable visionOS foveation for a baseline
  run. It is enabled by default where the dedicated layout supports it.

The log reports submitted/considered tiles, draws, and triangles, summed over
the interval. Stereo counts each eye separately. These are CPU submission
counts, not presented FPS. The existing screen FPS overlay counts RealityKit
updates, and the original immersive log counts frame-loop iterations.

`MetalEncode` signposts (subsystem `dev.also.maps`, category `Frame`) cover
culling and draw encoding for one view. Use [profiling.md](profiling.md) to
record them, including `env -u OS_ACTIVITY_DT_MODE`, and summarize with
`Scripts/signpost_summary.py`. Use Metal System Trace/GPU timing to assess
GPU execution and missed deadlines; fewer submitted triangles alone doesn't
prove a frame-rate improvement.

Once a key is configured, compare a fixed NYC saved view at street level with
culling on and off, keeping drawable resolution and detail settings identical.
Use a deliberately **warm cache** for both runs and check request counters
([tile-caching.md](tile-caching.md)). Separate settled idle, movement, and
streaming measurements. Inspect a full turn, narrow view edges, both eyes,
and near-plane crossings for missing geometry. Record submitted/considered
draws and triangles, CPU encode p50/p95, GPU time, and missed deadlines.
On Vision Pro, compare foveation separately with culling held fixed. Check
peripheral image quality, both eyes, and compositor depth. Simulator builds
do not establish foveated rendering quality; validate it on the device.

Synthetic geometry tests establish the culling behavior. After implementation,
the macOS app was launched with a Google Maps key and Metal enabled; New York
tiles rendered, the window was inspected through Computer Use, and submission
counters were confirmed active. A controlled culling-on/off performance
comparison and on-device visionOS foveation validation are still pending.
