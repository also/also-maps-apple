# Metal renderer: feature ideas

A prioritised brainstorm for the experimental Metal tile renderer
([metal-renderer.md](metal-renderer.md)). Nothing here is decided or built.
Effort is rough: **S** is a day or less, **M** a few days, **L** a week or
more. "Files" are where the change would land today.

## What the renderer is now (the constraints behind the ideas)

Read from `Sources/Metal/*` and `Sources/MetalImmersiveSpace.swift`:

- **One pipeline, one tiny shader.** `tileVertex` / `tileFragment`, compiled
  from a source string at launch. The fragment is `baseColor * texture`, plus a
  fixed "light from above" only when the primitive has normals. Google's
  photogrammetry tiles are unlit with baked lighting and (per the JS study §8)
  carry no normals, so in practice nothing is lit.
- **No anti-aliasing.** Single-sample colour and depth. Foveation looked much
  better than no foveation on a Vision Pro (metal-renderer.md, 2026-11-03),
  inferred to be pixel density, not AA.
- **Textures are uncompressed.** The bridge hands over decoded RGBA8, uploaded
  as `rgba8Unorm_srgb` with a blit-generated mip chain (one command buffer and
  `waitUntilCompleted` per texture, on a background thread). Sampler is
  trilinear, no anisotropy (`TileUploader.samplerDescriptor`).
- **CPU-driven draws.** Per part: six `set…` calls, 192 bytes of uniforms
  through `setVertexBytes`/`setFragmentBytes`, one indexed draw. Culling is on
  the CPU per tile and per primitive. Vertex positions and normals are
  `float4` (16 bytes) with a padding lane.
- **Stereo is two passes' worth of work.** The immersive loop encodes each eye's
  viewport in turn, re-walking every tile. Foveation uses dedicated textures.
- **Main-thread frame.** Selection, unloading and encoding all run on the main
  actor in series (metal-renderer.md, 2026-11-03: ~3 ms tick plus ~0.5 ms
  render in an optimised build, 90 fps clean).
- **Depth is reverse Z, cleared to 0**, with a depth-only sky pass because the
  compositor drops far-plane pixels. Sky colour is a flat clear.
- **Missing, by design today:** tracks, tile bounds, look-and-pinch, anything
  but full immersion.

## Already covered by sibling sessions (not detailed here)

| Topic | Session | What this note adds |
|---|---|---|
| Tracks / routes in Metal | metal-tracks | Only: draping (see 14) as an alternative technique |
| Mixed and progressive immersion | metal-immersion | Notes on what the *renderer* needs (alpha, sky depth), see 17 |
| System gestures (look-and-pinch) on the map | metal-gestures | Picking (see 6) is the shared dependency |
| Custom hand-tracking control schemes | hand-controls | None |
| Artistic shaders (toon, tilt-shift, etc.) | metal-shaders | The shared plumbing: a lighting/uniform block (see 3) |
| Tile fades / fog | metal-fades | Fog and sky scattering overlap (see 5); coordinate on the sky |

Where an item below touches one of these it says so; the owners decide.

## Priority summary

Ordered by value for effort, with the quick wins and the unblockers first.

| # | Idea | Category | Effort | Value |
|---|---|---|---|---|
| 1 | MSAA (or at least resolve-friendly foveation tuning) | Quality | S–M | High |
| 2 | Anisotropic filtering, plus a mip/LOD-bias knob | Quality | S | High |
| 3 | A real uniform/lighting block and sun direction | Quality (enabler) | S | High |
| 4 | Selection and unload off the main thread | Perf | L | High |
| 5 | Sky and atmosphere (gradient, then scattering) | Quality | M | High |
| 6 | Picking / ray-cast against the tile meshes | Interaction | M | High (unblocks several) |
| 7 | Vertex amplification for single-pass stereo | Perf | M | Medium |
| 8 | Texture compression (ASTC/BC) | Perf / memory | M–L | Medium |
| 9 | Argument buffers + indirect command buffers | Perf | L | Medium (conditional) |
| 10 | Labels / POIs drawn in Metal | Interaction | L | Medium |
| 11 | Shadows from a sun position, time of day | Quality | L | Medium |
| 12 | Screen-space AO | Quality | M | Low–Medium |
| 13 | Water | Quality | L | Low–Medium |
| 14 | Draped overlays (render-to-texture) | Tracks / data | L | Medium |
| 15 | Measuring tool | Interaction | S–M after 6 | Low–Medium |
| 16 | Sun-shadow study | Interaction | M after 11 | Low |
| 17 | Table-top map in mixed immersion | Immersion | M–L | Medium |
| 18 | Room-aware lighting / occlusion | Immersion | L | Low |
| 19 | Clouds | Quality | M–L | Low |
| 20 | Occlusion culling | Perf | L | Low |
| 21 | Temporal AA | Quality | L | Low |
| 22 | Surprising extras (photo mode, attribution, debug views, GPU timing) | Misc | S each | Several are high value |
| 23 | Tone mapping and exposure | Quality | S | Low |

---

## Image quality

### 1. MSAA

- **What:** render with 4 samples (or 2) and resolve, in both the Mac/iOS
  `MTKView` (set `sampleCount`) and the compositor path.
- **Why:** the only anti-aliasing today is foveation's higher central density,
  and the notes already saw aliasing on the unfoveated path. Photogrammetry
  has long thin silhouettes (roof edges, tree lines, wires) that shimmer in a
  headset, where shimmer is the thing people notice. On Mac/iOS it is a
  one-line change plus a pipeline `rasterSampleCount`.
- **Effort:** S on Mac/iOS. M on visionOS: CompositorServices gives
  you its own colour and depth textures, so MSAA means rendering into our own
  multisample textures and resolving into the drawable's (extra memory
  bandwidth; tile-memory resolve with `storeAction = .multisampleResolve` keeps
  it on-chip). It needs checking against foveation: rasterization rate maps and
  multisample targets don't obviously combine, so this may be either/or on
  device. Measure before committing.
- **Risks:** bandwidth and memory on Vision Pro at 90 fps with already ~7 ms
  spare (optimised build); depth must be resolved too for the compositor (use
  `.depth` resolve filter `.min`/`.max` carefully with reverse Z: keep the
  nearest, i.e. the max); the sky-depth pass must run per sample.
- **Files:** `Sources/Metal/MetalTiles.swift` (pipeline key gains a sample
  count; `encode` unchanged), `Sources/Metal/MetalMapView.swift`,
  `Sources/MetalImmersiveSpace.swift` (own multisample targets, resolve).
- **Alternative:** alpha-to-coverage isn't relevant (no cutouts). Tree
  silhouettes are mesh edges, so MSAA is the right tool.

### 2. Anisotropic filtering and LOD bias

- **What:** set `maxAnisotropy` (4–8) on the tile samplers. Optionally a small
  negative `lodBias` for crispness, or a clamp on the max LOD.
- **Why:** the app's main view is a low oblique camera over flat-ish
  ground and roofs, the exact case where trilinear blurs texture detail into the
  distance. This is often the biggest visible sharpness win per line of code.
- **Effort:** S. `TileUploader.samplerDescriptor` is shared with RealityKit; set
  anisotropy only on the Metal side (copy the descriptor in
  `MetalTileRenderer.sampler(for:)`), so RealityKit doesn't change.
- **Risks:** texture fetch cost (watch GPU time on Vision Pro; 4× is usually
  cheap). Samplers are keyed by glTF sampler fields, so the cache key stays valid.
- **Files:** `Sources/Metal/MetalTiles.swift`.

### 3. A uniform/lighting block and a sun direction (enabler)

- **What:** split the per-draw `Uniforms` into per-frame data (view-projection,
  camera position, sun direction and colour, exposure, time) and per-tile data
  (model matrix, base colour), bound once per frame/tile instead of per part.
  Add a `FrameState` struct passed to `encode`.
- **Why:** shadows, sky, fog, fades, artistic shaders and tone mapping all want
  the same frame-level inputs. Doing it once avoids each session inventing its
  own, and it cuts the redundant 192-byte-per-part copying. Sun direction can
  come from lat/lon and date (a few lines of solar position maths) so every
  later lighting feature agrees.
- **Effort:** S. The risk is entirely merge conflict, not complexity.
- **Risks:** `MetalTiles.swift` is the file every sibling touches. Land this
  early or coordinate with metal-shaders and metal-fades before anyone builds
  on the current struct. The Swift and MSL structs are matched by hand
  (comment "Must match"); adding a size/offset test would help.
- **Files:** `Sources/Metal/MetalTiles.swift`, plus a tiny new
  `MetalSun.swift` for solar position.

### 5. Sky and atmosphere

- **What:** replace the flat clear colour with a full-screen sky pass (the
  depth-only sky pass already draws a full-screen triangle, so the plumbing is
  there): a horizon-to-zenith gradient first, then analytic scattering
  (Preetham/Hosek-Wilkie or a precomputed Bruneton-style LUT) driven by the sun
  direction. Add aerial perspective on the tiles: a distance- and
  height-based blend toward the sky colour in the fragment shader.
- **Why:** the horizon is a stepped band against a flat sky today. The map is a
  photographic city seen from a low angle; haze and a sun disc do more for
  realism than almost any geometry work, and aerial perspective makes distance
  read in stereo. It is also the thing that makes the sky depth workaround
  look intentional.
- **Effort:** gradient S, analytic scattering M, aerial perspective S once the
  sky exists.
- **Risks:** overlaps metal-fades (fog) and metal-immersion (mixed immersion
  wants a transparent sky, not a painted one): the sky must be switchable off
  and keep the `skyDepth` behaviour. Colour: the target is sRGB, so compute in
  linear and let the target encode. Tile textures have baked photographic
  lighting from a different time of day, so a sunset sky over a noon texture
  looks off (see 11).
- **Files:** `Sources/Metal/MetalTiles.swift` (new `encodeSky`), shader
  source, `Sources/MetalImmersiveSpace.swift` and `MetalMapView.swift`
  (call sites; clear colour becomes irrelevant once sky draws everything).

### 23. Tone mapping, exposure and colour handling

- **What:** an optional tone curve and exposure, plus saturation/contrast tuning
  on the tile colour; check that sRGB handling is right end to end (sRGB
  textures sampled linear, written to an sRGB target; `skyColour` is already
  pre-linearised).
- **Why:** low priority for photogrammetry that is already display-referred. It
  matters only if lighting (3, 11) is added; then a simple filmic curve stops
  sunlit roofs from clipping. Keep it as a knob, not a default.
- **Effort:** S. **Risks:** HDR on Vision Pro (the compositor can take
  extended-range formats; not explored here). **Files:** shader source.

### 11. Shadows from a sun position and time of day

- **What:** a cascaded or single large shadow map rendered from the sun, the
  tiles drawing into it with the same buffers (a depth-only pipeline), then a
  PCF lookup in `tileFragment`. Without normals, shade from the shadow term
  alone, multiplied over the baked texture.
- **Why:** it makes a time-of-day control possible and is the backbone of the
  sun-shadow study (16). It also grounds the map visually in mixed immersion.
- **Effort:** L. Cascades over a km-scale city, fit to the view; per-tile
  culling against the light frustum; stable texel snapping to avoid shimmer.
- **Risks:** the textures already contain *baked* shadows from the capture time
  (Google doesn't say when), so adding computed shadows double-darkens and the
  two disagree. Realistic options are (a) accept it as a stylised overlay, or
  (b) only use it for the *study* tool, where the sun position is the whole
  point. No normals means no N·L shading, so only cast shadows, not diffuse
  falloff; flat ground gets no gradient. Cost: a second pass of the whole tile
  set per cascade, which is the same draw count again on a headset with
  millisecond margins. Self-shadow acne with thin photogrammetry needs bias.
- **Files:** `Sources/Metal/MetalTiles.swift` (shadow pass, new pipeline),
  new `MetalShadows.swift`, the immersive loop and map view (extra pass before
  the colour pass).

### 12. Screen-space ambient occlusion

- **What:** depth-based SSAO (or GTAO) over the resolved depth, multiplied into
  colour.
- **Why:** adds contact shading where buildings meet ground, without normals.
- **Effort:** M. **Risks:** baked lighting already contains ambient occlusion
  (it's photographed), so the gain is small and a haloed result is a real
  risk. Needs a depth readback pass, which fights foveation's variable rate and
  MSAA. Bandwidth heavy on device. I'd skip this unless 11 lands.
- **Files:** new pass, both frame loops.

### 13. Water

- **What:** Google's tiles bake water as ordinary textured geometry (flat
  and mostly dull). A water pass would detect it (flat, low, a colour/bounds
  heuristic, or the shoreline), then draw animated normals, fresnel and sky
  reflection.
- **Why:** San Francisco Bay, rivers and coasts are a large share of many
  views, and static water is the least photographic part of the picture.
- **Effort:** L, mostly the detection. The JS study (§5) notes Google's own
  client has a separate `rockwater` shader path and "water skirts", i.e. the
  client data *flags* water; the public 3D Tiles don't, so this would be a
  colour/flatness guess and will have false positives (flat blue roofs, pools).
- **Risks:** needs the sky (5) for reflection; needs the sun (3). Maybe a
  classification step at tile-build time (the build is already off the main
  thread) that tags a mask per primitive.
- **Files:** `MetalTiles.swift` (`build`: classification), shaders.

### 19. Clouds

- **What:** a few billboarded or volumetric cloud layers above the map, with
  shadows on the ground.
- **Why:** sells scale in immersion. **Effort:** M for a flat noise layer,
  L for volumetrics. **Risks:** expensive in a stereo foveated pass; easy to make
  look fake; cloud shadows conflict with baked lighting. Do after the sky (5).
- **Files:** new pass, depends on 3 and 5.

### 21. Temporal AA

- **What:** jitter the projection, accumulate with motion vectors.
- **Why:** best AA per cost on a flat panel, but the map has no object motion
  except camera motion, so it's the *simplest* possible TAA case.
- **Effort:** L. **Risks:** a stereo head-mounted display is the worst case
  for TAA: per-eye history, large camera rotation each frame, foveation
  mixing densities, ghosting on a 90 Hz display that people look at
  from centimetres. CompositorServices has a motion-vector/history story for
  some apps, but verify before investing. MSAA (1) is the better first step.
- **Files:** both loops, projection, a resolve pass.

---

## Performance

### 4. Move tile selection and unloading off the main thread

- **What:** the single biggest known frame cost. From the Vision Pro
  recordings: selection (`updateViewGroup`) is ~15% of main-thread samples
  and cesium-native unloading cached content (`~ModelSpec` freeing glTF
  images) is ~31% in a Debug build. Even optimised, `ImmersiveTick` averaged
  3.2 ms with max 5.6 ms, inside the frame, in series with render. Options:
  1. Run the streamer's `update` on a serial queue, publishing an immutable
     "drawn tiles + transforms" snapshot to the render loop (double-buffered,
     so the frame loop just reads the latest).
  2. Free the CPU-side images immediately after upload on the build thread
     (`discardCPUData()` already exists; the unload cost is cesium's own copy
     of the decoded images, which the bridge could drop or take ownership of
     earlier).
- **Why:** it removes the one known source of missed deadlines and gives
  headroom to spend on 1, 5 and 11. The 2026-11-03 notes show missed
  deadlines track tick length almost linearly.
- **Effort:** L. Thread-safety of `MapModel`, the camera inputs to selection
  (position as of tick N, tiles drawn as of tick N-1; at 90 Hz that lag is
  small but must not break "held" Fly tiles) and the RealityKit path, which
  shares `TileStreaming`.
- **Risks:** the worst: shared code with the RealityKit renderer, ordering
  between camera and selection, and cesium-native's thread rules (its main-thread
  `update` expectations). Probably needs the owner's design call
  (`docs/camera-core.md` territory). Stale snapshots could show one-frame
  popping.
- **Files:** `Sources/TileStreaming.swift`, `Sources/MapModel.swift`,
  `Sources/MetalImmersiveSpace.swift`, `Sources/Metal/MetalMapView.swift`.
- **Prototype (2026-11-05, unbuilt):** option 1 for the visionOS immersive
  space behind `ALSOMAPS_METAL_THREADED_SELECT=1`, and option 2 behind
  `ALSOMAPS_METAL_RELEASE_IMAGES=1`; design, thread rules and risks in
  [metal-renderer.md](metal-renderer.md).

### 7. Vertex amplification (single-pass stereo)

- **What:** use `setVertexAmplificationCount` with per-view transforms so one
  draw renders both eyes, instead of two walks of every tile. Requires the
  layered layout (a texture array), or two viewports with amplification routing.
- **Why:** halves CPU encoding (0.5 ms for both eyes today, so a small win in
  absolute terms) and API/driver overhead, and is already flagged as "later" in
  metal-renderer.md. Gains grow if the draw count grows (shadows, labels).
- **Effort:** M. **Risks:** the code currently chooses `.dedicated` + foveation
  because the notes found array-layout foveation unsupported by this renderer;
  amplification wants `.layered`. Layered + foveation has to be checked on the
  device. Culling becomes per-pair (union of two eye frusta) or per-view via
  indirect culling, so most of the culling win must be rethought; the notes say
  culling gave no visible fps change, so this is acceptable.
- **Verdict:** only worth it after 4 shows CPU encode time is the bottleneck.
  It isn't now (0.5 ms).
- **Files:** `MetalImmersiveSpace.swift` (configuration, pass setup),
  `MetalTiles.swift` (`encode` takes N views), shaders.

### 8. Texture compression

- **What:** transcode decoded RGBA to ASTC (Apple GPUs) at tile build time, or
  better, keep tiles compressed end to end. The JS study (§1, §4.6) shows
  Google's own client keeps Crunch/DXT on the GPU because textures are 44% of
  bytes. The public API ships JPEG/PNG/KTX2 depending on tileset, and
  cesium-native decodes to RGBA8 for us.
- **Why:** an uncompressed 512×512 RGBA8 texture is 1 MB plus 33% for mips;
  ASTC 6×6 is ~0.1 MB. A dense city view holds hundreds of tiles, so resident
  GPU memory (and memory bandwidth on Vision Pro) is a real constraint, and
  the build thread currently does a `waitUntilCompleted` blit per texture.
- **Effort:** M–L. Options: (a) real-time encode on the GPU (a compute ASTC
  encoder, as in Apple's sample), (b) CPU encoder (e.g. a vendored astcenc) on the
  build thread, off the main thread (compression speed matters when
  streaming), (c) ask cesium-native to keep KTX2/Basis payloads (Google's
  tilesets may offer them; check) and transcode to ASTC with the Basis
  Universal transcoder.
- **Risks:** a vendored encoder is a new dependency and licence; encode time
  per tile vs streaming; quality loss on photogrammetry is modest at 6×6 and
  visible at 8×8 and up; `rgba8Unorm_srgb` -> `astc_6x6_srgb` is straightforward.
  Simulators on Mac may lack ASTC (Apple Silicon has it; Intel Macs don't).
- **Files:** `MetalTiles.swift` (`texture(for:)`), possibly `Sources/Cesium/*`
  (bridge) for the compressed route.

### 9. Argument buffers and indirect command buffers

- **What:** put all part data (buffer addresses, texture, bounds) in a
  GPU-resident table; cull with a compute pass; encode the draws with an
  ICB on the GPU.
- **Why:** moves cost from CPU per draw to a fixed dispatch; scales to many
  more draws (shadow cascades, both eyes, 10k tiles).
- **Effort:** L. **Risks:** the current CPU path has ~1–2 thousand draws at 90 fps
  with room to spare, so this is solving a problem that doesn't exist yet. It
  also pessimises the simple "tile loaded/unloaded" lifecycle (a resident table
  to maintain, `useResource`/heaps for residency). Revisit if shadows or labels
  multiply draw counts. Intermediate step with a good return: residency sets
  (`useHeap`) and fewer `set…` calls per part by binding one argument buffer per
  tile.
- **Files:** `MetalTiles.swift`, `MetalVisibility.swift` (the culling maths
  would be re-implemented in MSL).

### 20. Occlusion culling

- **What:** hierarchical-Z or occlusion-query-based culling of tiles hidden
  behind buildings/hills (the current culling is frustum-only and says so).
- **Why:** in a city canyon, most detailed tiles are behind others.
- **Effort:** L. **Risks:** one-frame latency, popping, complexity in stereo.
  Tile bounds are loose, so it culls less than hoped. cesium-native already
  skips refining tiles by screen-space error. I'd defer; measure first how much
  overdraw is actually present (GPU counters via Metal System Trace).
- **Files:** `MetalVisibility.swift`, loops.

### 22a. LowLevelTexture-style upload and zero-copy buffers

- **What:** avoid `replace(region:)` + CPU copy; allocate textures in a
  `MTLHeap`, upload via a shared staging buffer + blit on a dedicated upload
  queue, make buffers for positions with `bytesNoCopy` from the bridge's
  memory, and compact vertex formats (`half2` UVs, packed positions: 8 bytes
  instead of the 16-byte `float4`). The JS study (§1) shows Google's own
  format is 3 B/vertex positions, 2 B normals, so there is a lot of
  room.
- **Why:** less build-thread time (1.3 ms a tile now), less memory
  (`float4` positions and normals waste 25–50%), less pressure on cesium's
  retained copies (ties to 4).
- **Effort:** M. **Risks:** low-level; positions are tile-centre offsets in
  float, so `half` loses precision for big tiles (use snorm16 plus a per-tile
  scale: a clean fit). Needs the bridge changed to emit packed formats, which
  RealityKit's `TileUploader` also reads, so it must be additive.
- **Files:** `MetalTiles.swift` (build/shader), `Sources/Cesium/*` (bridge
  output).

---

## Interaction

### 6. Picking and ray-casting (unblocks the rest)

- **What:** a CPU ray against the drawn tiles. The bounds already exist per part
  (`MetalBounds`); add a triangle test against the CPU positions when a hit
  is within a tile's bounds. The catch: `discardCPUData()` throws the CPU copy
  away after upload. Options: (a) keep a decimated copy of positions and
  indices per tile (cheap on coarse tiles, costly on fine ones),
  (b) read back depth on demand (render a 1-pixel depth under the cursor, or a
  small pick pass writing object IDs) which is fast and always consistent with
  what's drawn, (c) use cesium-native's own ray-casting / `sampleHeightMostDetailed`
  where the app already uses it for ground height.
- **Why:** this is what's missing for any "click on the map" feature: a
  place under the pointer or hand (needed by the metal-gestures session's
  look-and-pinch and hand-control sessions: both need "what map point is
  here"), measuring, a drop pin, "fly to here", and POIs.
- **Effort:** M. (b) is the cheapest in code; (a) is the most flexible
  (arbitrary rays; useful in visionOS where the ray is a hand/eye ray not a
  pixel).
- **Risks:** a readback has a frame or two of latency (fine for taps, wrong
  for a continuously updated hover cursor); (a) costs memory.
- **Files:** `MetalTiles.swift` (retain CPU data or a pick pass),
  `MetalVisibility.swift` (ray vs box), `MetalMapView.swift` (input),
  `MapModel.swift` (surface the hit point).

### 10. Labels and POIs in Metal

- **What:** place names, street names, and POI markers rendered as camera-facing
  text (a glyph atlas / signed distance fields) positioned by lat/lon/height.
  Sources: `Sources/Places` (existing place data).
- **Why:** a map without labels is a model. In Metal there is no SwiftUI
  overlay in the immersive space, so this is the only way labels appear
  in the full-immersion view at all. Google's JS client draws labels from a
  separate vector tile stream (JS study §1: `maps/vt/proto`), not from the 3D
  tiles, which shows the data have to come from elsewhere.
- **Effort:** L: text shaping and an SDF atlas (Core Text -> bitmap atlas is
  fine for a few thousand glyphs), collision/declutter, depth testing and
  fading (blends in with metal-fades), picking (6).
- **Risks:** declutter is a real algorithm; legibility in stereo (size in
  angular terms, not metres) takes tuning; text rendering cost with foveation.
  An intermediate step: render labels into a few billboards from `Sources/Places`
  with a `CTLine` bitmap each, nothing fancy.
- **Files:** new `MetalLabels.swift`, pass appended to `encode` callers,
  `Sources/Places/*`.

### 15. Measuring tool

- **What:** two picked points, a line drawn between, and a distance /
  height-difference readout.
- **Effort:** S–M after 6 and (for the line) a tiny line-drawing pipeline
  (shared with tracks if that session lands one). **Risks:** photogrammetry
  roofs and trees are not ground (JS study §2: the public tiles carry no
  bare-earth layer), so heights are "top surface". Say so in the UI.
- **Files:** new `MetalMeasure.swift`, plus 6.

### 16. Sun-shadow study

- **What:** a time-and-date scrubber that moves the sun and shows cast
  shadows on the real city, with a shade-hours-per-day heat map as the
  extension.
- **Why:** a legitimately useful architecture/planning tool and a good
  demo of immersion at table scale. **Effort:** M after 11 and 3.
  **Risks:** (see 11) baked textures disagree; the study mode could render a
  flat-shaded, textures-dimmed view so computed shadows read clearly.
  Geometry at the edges of tiles loaded at lower detail changes shadows.
- **Files:** UI in `Sources/Settings` or the volume; renderer: 3, 11.

### 14. Draped overlays (render to texture)

- **What:** the JS study (§5) notes Google drapes ground-clamped shapes by
  rendering them top-down to a texture and projecting that onto the mesh in
  the mesh shader (only where the surface faces up). For tracks, routes, parcel
  boundaries, heat maps, selection highlights, search-radius circles and
  isochrones.
- **Why:** one technique for every ground overlay; avoids sampling heights
  per vertex (tracks that float above roofs or sink into hills are the usual
  failure) and gets proper shading for free; works while tiles refine and
  change shape, which per-vertex ground clamping doesn't.
- **Effort:** L. **Risks:** a top-down camera for a big area needs resolution
  management (tiled or cascaded drape textures); overlays on vertical
  surfaces are suppressed by the normal test, but the tiles have no normals, so
  derive from `dFdx/dFdy` of position in the fragment shader (cheap, no
  vertex data). Overlaps metal-tracks: that session should decide whether tracks
  are meshes (their natural choice, matching the RealityKit tube) or drape;
  this idea is for the *non-track* overlays and a possible later track mode.
- **Files:** `MetalTiles.swift` (overlay texture binding, shader),
  new `MetalDrape.swift`.

---

## Immersion

### 17. The map on a table in mixed immersion

> Mixed/progressive immersion is the metal-immersion session's scope. This
> entry is only about what *rendering* needs to support it and a table-top
> presentation.

- **What:** render the map as a bounded diorama (a clipped box or disc of tiles)
  placed on a real table or floor via ARKit plane detection, over passthrough
  (transparent background, correct alpha/depth), scaled by a pinch.
- **Why:** it's the "wow" scale on Vision Pro, and RealityKit's volume already does
  a version of this, so the Metal version would be the high-fidelity
  alternative (real depth, foveation, shadows on the table).
- **Effort:** M–L. Needs: a clip volume in the tile shader (discard / plane
  tests against a box in the tile model space), a pass without a sky, alpha
  write (premultiplied) with depth the compositor can use for occlusion, a
  root transform that is scaled and placed, and edge treatment (fade/skirt).
- **Risks:** the compositor's blend/alpha rules in mixed style (colour must be
  premultiplied; the sky-depth hack must be off so passthrough shows through);
  scale + reverse Z + near plane at very small scale (the near plane must be
  small); table detection quality; the `measuredEye` logic assumes an
  eye-level-centred map.
- **Files:** shader (clip box uniform), `MetalImmersiveSpace.swift`,
  `MapModel.swift` (placement). Depends on the metal-immersion work.

### 18. Room-aware lighting and occlusion

- **What:** use the room's ambient light estimate (ARKit has none on visionOS
  for apps; the environment lighting is private) or scene reconstruction meshes
  (with `SceneReconstructionProvider`) to occlude the map by real objects, and
  to cast the map's shadow onto the table. Hand occlusion comes from the
  compositor if depth is submitted.
- **Why:** makes a table-top map look *there*. **Effort:** L, **Risks:** the
  environment-light data is not exposed to Metal apps (as of this writing;
  verify), reconstruction meshes need the permission and are noisy; a
  hand-tuned warm/cool "ambient" is a cheaper proxy. Low priority.
- **Files:** `MetalImmersiveSpace.swift`, a new provider wrapper.

---

## Surprising extras

### 22. Smaller ideas worth a line each

- **Frame capture / photo mode.** A button to render a single high-res frame
  (4× resolution, MSAA 8×, no foveation) to a PNG on Mac/iOS, with the
  attribution overlaid. Cheap (S) with MTKView and an offscreen target, and
  good for sharing. Check the Map Tiles API terms on screenshots and keep
  attribution.
- **Attribution in Metal.** The Mac/iOS windows still get SwiftUI credits; the
  immersive Metal space has none. Google's terms require attribution to
  be visible, so a small camera-fixed text quad (a trivial case of 10) is
  needed before any wide release of the Metal immersive mode.
- **Debug views.** A shader debug mode: LOD level as colour, tile bounds
  (listed as missing), overdraw heat map, mip level as colour. Tile bounds are
  mostly `MetalBounds` already; drawing a wire box is S and helps every
  other item in this document be measured.
- **GPU timing in the stats log.** `MTLCommandBuffer.gpuStartTime/gpuEndTime`
  (or `addCompletedHandler`) in `MetalDrawLog`, since the notes explicitly say
  submission counts do not prove frame-rate gains. S; probably the best
  measurement investment, and makes 1, 7, 9 and 20 decidable.
- **Pre-warm pipelines and samplers.** Pipelines and samplers are made on first
  use, under a lock, on the render thread (pipelines) — the first frame
  can hitch. Make them in `init` for the known formats. S.
- **Heightfield-aware fly camera / ground contact.** Not rendering: reuse the
  depth buffer or picking (6) for "stay above ground", the kind of thing the
  JS study's altitude compensation (§5) does. Camera-core territory.
- **Time-based unpopping.** Covered by metal-fades; the JS study's
  per-octant masking (§5) is a clever alternative that doesn't apply to
  monolithic glTF tiles.
- **Tile shell skirts.** Cracks at LOD boundaries are hidden in Google's client
  with skirts; cesium-native's forbid-holes avoids gaps but if cracks appear
  in the Metal path, a small vertex-shader push-down of boundary vertices is
  the standard remedy. Only if observed.
- **Stereo comfort for close geometry.** At table scale, near-plane clipping
  and vergence discomfort are real; a user-facing "soft near fade" belongs with
  the fades session.
- **tvOS.** None of this applies; tvOS only needs to keep building.

## Suggested order

1. **Cheap and clearly good:** 2 (anisotropy), the GPU timing and pipeline
   pre-warm items from 22, 1 on Mac/iOS (MSAA), tile-bounds debug view.
2. **Enablers:** 3 (frame uniform block), attribution quad, 6 (picking).
3. **The next big win for visuals:** 5 (sky and aerial perspective), then 1 on
   visionOS if foveation can coexist with it.
4. **The next big win for frame time:** 4 (selection/unload off the main
   thread), once the owner agrees on the design.
5. **Memory:** 8 (texture compression) and the compact vertex formats in 22a.
6. **Only if measurements demand it:** 7, 9, 20.
7. **Speculative / product-defining:** 10 (labels), 11 + 16 (shadows and the
   study), 14 (draping), 17 (table-top).

## Open questions

- Does foveation with a rasterization rate map work with a multisampled
  colour target on visionOS? It decides whether 1 is "foveation or MSAA".
- How much GPU time does a frame use on a Vision Pro? Only CPU and display
  deadlines are measured today. Everything in Performance is guesswork until
  that is logged.
- Which Google tile format (JPEG / KTX2) does the bridge receive, and can it
  hand over the undecoded image? (8)
- Whether the Map Tiles API terms restrict baked-lighting modifications,
  screenshots, or attribution placement in immersive views; check before 11,
  22 (photo mode) or any wide release.
