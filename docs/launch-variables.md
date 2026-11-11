# Launch variables

`ALSOMAPS_*` environment variables set up the app at launch: where it starts, what it streams, and what it shows. They're for development and testing, so a state can be reached without going through the UI. Set them in the Xcode scheme (the visionOS scheme has the Cesium sample ones ready to tick), in the shell when running the Mac binary, or with `SIMCTL_CHILD_` in front when launching in a simulator (see [visionos-simulator.md](visionos-simulator.md)).

Flags are on only when set to exactly `1`, except the Metal switches, which are on by default and turned off with `0`.

## Starting view

| Variable | Apps | Effect |
|---|---|---|
| `ALSOMAPS_LAT`, `ALSOMAPS_LON` | visionOS | Starting position, in degrees. Defaults to the Ferry Building. |
| `ALSOMAPS_RADIUS` | visionOS | Starting view half-width, in metres. On the screen apps, see Static views. |
| `ALSOMAPS_HEADING` | visionOS | Starting direction, in degrees clockwise from north. |
| `ALSOMAPS_PLACE=<id>` | visionOS, iOS, tvOS | Starts at that place from `Sources/Places/Places.json`. |
| `ALSOMAPS_PRESENTATION=volume` or `immersive` | visionOS | Starts in that mode. Ignored when `ALSOMAPS_STATE` is set. |
| `ALSOMAPS_STATE=<JSON>` | visionOS, macOS | Restores a view state from Settings → Advanced → Copy View State. Older focus-centric states are rejected. On macOS it sets the camera diagram's values, with `ALSOMAPS_DIAGRAM`. |

## Static views (macOS, iOS, tvOS)

| Variable | Effect |
|---|---|
| `ALSOMAPS_VIEW=bay` or `ferry` | Starts at that fixed camera preset instead of a place (`bay` is the default). |
| `ALSOMAPS_RADIUS` | Area of interest half-width, in metres. |
| `ALSOMAPS_DETAIL`, `ALSOMAPS_OUTER_DETAIL` | Screen-space error, in pixels, inside and outside the LOD camera's view. |
| `ALSOMAPS_LOADS`, `ALSOMAPS_UPLOADS` | Concurrent tile requests and tile uploads. |
| `ALSOMAPS_DIAGRAM` | macOS only. Opens the camera diagram beside the map. Set it to `window`, `volume` or `immersive` to pick the host it shows; any other value shows the volume. |

## What it streams and where it connects

| Variable | Effect |
|---|---|
| `ALSOMAPS_TILESET_URL=<url>` | Streams any 3D Tiles tileset instead of the selected tile source, with no key. The visionOS scheme has the public Cesium sample. |
| `ALSOMAPS_CONFIG_URL=<url>` | Reads another remote config file (http, https or `file://`) without touching the saved copy. See [remote-config.md](remote-config.md). |
| `ALSOMAPS_CREDENTIALS_URL=<url>` | Talks to another deployment of the credentials API. |

## What's shown (visionOS)

| Variable | Effect |
|---|---|
| `ALSOMAPS_OPEN_SETTINGS=1` | Opens the Settings window. |
| `ALSOMAPS_DEBUG_PANEL=1` | Opens the debug panel beside the volume, even with Show debug controls off. |
| `ALSOMAPS_MARKERS=1` | Shows the pivot and centre markers. |
| `ALSOMAPS_TILE_BOUNDS=1` | Shows tile bounds. |
| `ALSOMAPS_SHOW_TRACK=1` | Draws the latest track. |
| `ALSOMAPS_PLAY_TRACK=1` | Plays the latest track, after the rest of the launch setup. |
| `ALSOMAPS_FULL_IMMERSION=1` | Opens immersive modes with full immersion. |
| `ALSOMAPS_HUMAN_SCALE=1` | Keeps immersive modes at human scale. |

## Metal renderer

| Variable | Effect |
|---|---|
| `ALSOMAPS_METAL=1` | Draws with the Metal renderer for this run, as the setting does. |
| `ALSOMAPS_METAL_CULLING=0` | Turns off off-screen tile culling, for A/B profiling. |
| `ALSOMAPS_METAL_FOVEATION=0` | Turns off foveation in the visionOS immersive space. |
| `ALSOMAPS_METAL_STATS=1` | Prints draw submission counters once a second. |

How these are used for measurements is in [notes/metal-renderer.md](../notes/metal-renderer.md).

When you add a variable, add it here.
