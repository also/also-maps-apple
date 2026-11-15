# Navigation and tile loading: findings

Findings carried over from the navigation hand-off note of 2026-10-26, which has been removed. They describe the code as it was then. Newest first.

## 2026-10-26

**Ground and easing**

- **Observed:** tile heights are unreliable while loading. The lowest vertex of a coarse rendered tile can be kilometers below the real ground; −10,500 m was seen near San Francisco.
- **Observed:** placing the map from rendered-tile heights each frame created a feedback loop: new height → rescaled map → moved level-of-detail camera → different tiles → new height. The view bounced. Nothing derived from the current tile selection should continuously move the view.
- **Observed:** a newly opened RealityKit scene's first frames can have a near-zero time step. Easing loops must test whether they've reached their target, not whether the last step was small.

**visionOS**

- **Observed:** `onWorldRecenter` (XROS 27.0) exists only for Compositor Services content, not RealityView immersive spaces.
- **Observed:** the tracked head (`DeviceAnchor`) is only available in immersive spaces.

**Tile loading (cesium-native v0.64.0, as built)**

- **Observed:** tiles are chosen for one virtual camera (the LOD camera). In the immersive space it sat 1.6 m above the immersive origin, pointed about 16° down at a point 5.6 m ahead, with a 60° view. It doesn't follow the head.
- **Observed:** frustum culling is off (`23e2502`). While it was on, tiles outside that view were dropped, and the floor from the viewer's feet to about 1.5 m ahead had no tiles.
- **Observed:** a tile is refined until its screen-space error (roughly geometric error ÷ distance, in pixels) meets **Detail** (16) inside the view or **Outer detail** (64) outside it. Both fall with distance; setting them equal removes the direction penalty, not the distance falloff.
- **Observed:** load order is fixed (`computeTilePriority`): `(1 − cos angle) × distance` from each view's position and direction, best across views, smallest first, within the urgent, normal and preload groups. Tiles near the view's direction load first, even far away, and the floor under the viewer loads last. It isn't configurable without a patch.
- **Observed:** a straight-down view gives distance order: for ground tiles the score becomes distance minus the camera's height. It needs Outer detail ≈ Detail, because a 60° downward view leaves most tiles "outside".
- **Observed:** adding views takes the best score. A wide forward view alongside a down view brings distant on-axis tiles to the front again, so the two together don't give distance order.
- **Observed:** `updateViewGroup` takes a list of views, so cesium-native can select tiles for several viewpoints at once.
- **Observed:** v0.65.0 (Oct 2026) adds a `ViewStateMeasureDelegate`: an app-defined error measure per tile, which can express detail by distance from a point with no frustum. Load priority is unchanged, and it has breaking `ViewState` changes.
- **Observed:** fog culling with the default table never culls anything here. The cutoff is about 27 ÷ density, which is 135 km or more at every height in the table.
- **Observed:** the area of interest is the hard limit on what loads. The bridge's excluder skips tiles whose bounding sphere is entirely outside an east/north-aligned square around the streaming anchor, enlarged to contain the square turned to the heading. With culling off, it's the only limit on what loads behind the viewer.
- **Inferred:** cesium-native's selection and ordering are built around one view direction per camera, which is a poor fit for VR. Streaming, decoding, caching and hole-free loading are fine.

**Tile bounds overlay** (Tuning "Show tile bounds", or `ALSOMAPS_TILE_BOUNDS=1`)

- each drawn tile's box: cyan inside the LOD camera's view, orange outside;
- yellow: the area-of-interest square;
- pink: the LOD camera's view;
- white: its view direction.
