# Review: Camera-centric navigation core

Reviewed: 2026-10-25  
Source: [camera-core.md](camera-core.md), revision 2  
Scope: Design review only; the existing implementation and cesium-native integration were not verified.

## Assessment

The architectural direction is good, but the design should be revised before implementation. A camera pose, pure display mapping, explicit coordinate frames, and a platform-neutral navigation core are strong foundations. Several mathematical and streaming assumptions currently undermine the promised behavior.

Approve the overall separation of responsibilities, but defer the pose migration until the intersection, gesture, legacy-conversion, and held-content contracts are resolved.

## Findings

### 1. [P1] A downward pitch does not guarantee a globe intersection

**Reference:** §3.1, step 1.

The design assumes a −5° pitch always hits the reference surface. At sufficient altitude, that ray passes above the horizon. On a spherical Earth, a −5° ray stops intersecting at roughly 24 km altitude, well inside the proposed range. Manual pitch, held flight, and restored states can therefore leave G, range, and scale undefined.

Define an explicit miss result and fallback policy. Use a robust surface-intersection algorithm with a documented error tolerance rather than assuming a sphere intersection followed by one correction is sufficient. Handle tangent rays, cameras below the reference surface, and degenerate ranges explicitly.

### 2. [P1] Tile minimum height is not a reliable movement floor

**Reference:** §7, ground under the camera.

The minimum vertex height anywhere in a containing tile is not necessarily the ground directly under the camera. On hills, cliffs, bridges, or building meshes, it can be far below the local surface. This affects collision limits and terrain following, not just movement speed. A bounding volume containing the column also does not establish that geometry covers that column.

Separate a smoothed speed estimate from a spatially accurate surface/clearance query. Give query results explicit validity and freshness. Use local mesh intersection or an appropriate terrain source when enforcing clearance. Define what happens when no reliable surface is available, including when terrain loads after the camera has entered an area.

### 3. [P1] The window gesture derivation violates fixed scale

**Reference:** §5.1, window manipulation.

The proposed composition applies a scaling similarity to a transform that must remain rigid, with scale equal to 1. Extracting a camera position from that composition does not reproduce the scaled view for arbitrary 3D geometry. Dolly and world scaling produce different parallax.

Specify window pinch as an anchored dolly with a screen-space constraint. Specify rotation as a camera operation with an explicit axis. State which constraint takes priority when a combined gesture cannot reproduce the target similarity exactly.

### 4. [P1] Exact legacy conversion requires a representability proof

**Reference:** §3.1, check against today; §9, v1 conversion; §10, stage 1 verification.

Deriving a camera position from the inverse legacy transform establishes eye coincidence, but does not establish that the new display mapping reproduces the complete legacy transform. The new mapping also imposes C(pitch), a derived scale, and no independent roll. An arbitrary Fly-composed similarity may fall outside that family.

Prove which legacy states are representable before making exact conversion a migration requirement. Compare the full transform, not only the eye position or view ray. For unrepresentable states, choose a documented approximation or retain a compatibility placement. Treat this as an early design experiment, before removing the legacy state.

### 5. [P2] Held inputs and held rendered content are different contracts

**Reference:** §4.2, explicit hold; §9, held-state restoration.

A fixed streaming view does not by itself establish unchanged rendered selection or prevent eviction. Outstanding loads can still change refinement. The document currently promises fixed detail while also allowing loads to finish into the selection. Persisting streaming inputs likewise does not guarantee restoration of the exact previous tile set.

Choose one contract:

- Freeze the request/view region while refinement continues.
- Freeze and retain a specific rendered tile set, with explicit memory ownership.

Use the same contract in the bridge, UI, and persistence. If exact rendered content must survive a restart, inputs alone are insufficient; the design needs a content identity and availability policy. Otherwise describe restoration as recreating the held view request, with potentially different loaded content.

### 6. [P2] Clarify navigation dependencies and state ownership

**Reference:** §2, StreamingInputs; §4.2, hold ownership; §5, pure operations.

The navigation core depends on TileStreaming types despite its intended independence. Operations are described as pure functions on CameraPose, although their results also depend on ground, host constraints, and held-region state. The model and streamer both hold snapshots, leaving authority and synchronization unclear.

Define core-owned value types and an explicit operation context. Keep the platform and streaming adapters outside the navigation core. Give one component ownership of hold state and make the other consume its authoritative snapshot.

## Recommended long-term boundaries

Keep three responsibilities explicit:

1. **Navigation:** pose, movement, anchored operations, and constraints.
2. **Presentation:** world-to-room mapping and actual render views, including future head/eye offsets.
3. **Streaming:** view requests, coverage, refinement, cache retention, and anchor generations.

The logical navigation camera and the actual rendering eyes should have an explicit relationship. A nominal room eye is useful for the display mapping, but eventual tracked head and stereo views should fit without changing the meaning of the stored navigation pose.

## Anchor and asynchronous loading contract

Applying streaming inputs and the root transform in one tick does not by itself explain how existing tile placements and asynchronous load completions remain consistent during rebasing.

Document whether tile transforms are regenerated for the current anchor or tagged with an anchor generation, how stale completions are handled, and which state becomes visible atomically. Verify that rebasing preserves room-space positions for both already-rendered tiles and newly completed tiles.

## Testing and acceptance criteria

Make the permanent macOS unit-test target part of the design. Temporary self-tests are useful during migration, but should not replace regression coverage for the core mathematics.

Prioritize:

- Horizon misses and tangent rays at all supported altitudes and pitches.
- Invalid or degenerate reference-surface configurations.
- Anchored gestures at high altitude, near the horizon, and over large distances.
- Pole crossings and heading transport.
- Terrain discontinuities, missing ground, and late-arriving surface data.
- Live/held transitions under the chosen content contract.
- Asynchronous tile completions across anchor changes.
- Full-transform legacy conversion, including representative Fly states.
- Window gestures over non-planar geometry.

The anchored solver needs a convergence criterion, iteration limit, and defined failure result. “One or two corrections” is not a sufficient correctness contract. Measure anchor error in room metres and use absolute positional tolerances where relative transform tolerances would hide visible errors.

## Suggested decision

Proceed with the core separation and the bridge seam. Resolve the P1 findings and define held-content and rebasing semantics before stage 2. With those changes, the proposal can become a strong long-term foundation for navigation through 3D map tiles.
