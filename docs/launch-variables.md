# Launch variables

`ALSOMAPS_*` environment variables set up the app at launch, so a state can be reached without going through the UI. Set them in the Xcode scheme (the visionOS scheme has the Cesium sample ones ready to tick), in the shell when running the Mac binary, or with `SIMCTL_CHILD_` in front when launching in a simulator (see [visionos-simulator.md](visionos-simulator.md)).

Flags are on when set to `1`. The Metal switches are on by default and turned off with `0`. Grep for a variable to see exactly what it does.

## Starting view

| Variable | Apps | Sets |
|---|---|---|
| `ALSOMAPS_LAT`, `ALSOMAPS_LON`, `ALSOMAPS_HEADING` | visionOS | Starting position and direction |
| `ALSOMAPS_RADIUS` | all | Starting view half-width (visionOS) or area of interest (screen apps), in metres |
| `ALSOMAPS_PLACE=<id>` | visionOS, iOS, tvOS | Starting place, from `Sources/Places/Places.json` |
| `ALSOMAPS_PRESENTATION=volume` or `immersive` | visionOS | Starting mode |
| `ALSOMAPS_STATE=<JSON>` | visionOS, macOS | A view state from Copy View State |
| `ALSOMAPS_VIEW=bay` or `ferry` | macOS, iOS, tvOS | A fixed camera preset |

## Streaming

| Variable | Apps | Sets |
|---|---|---|
| `ALSOMAPS_TILESET_URL=<url>` | all | A 3D Tiles tileset to stream instead of the tile source, with no key |
| `ALSOMAPS_DETAIL`, `ALSOMAPS_OUTER_DETAIL` | macOS, iOS, tvOS | Detail, in pixels of screen-space error |
| `ALSOMAPS_LOADS`, `ALSOMAPS_UPLOADS` | macOS, iOS, tvOS | Tile request and upload concurrency |

## Services

| Variable | Sets |
|---|---|
| `ALSOMAPS_CONFIG_URL=<url>` | Another remote config file ([remote-config.md](remote-config.md)) |
| `ALSOMAPS_CREDENTIALS_URL=<url>` | Another deployment of the credentials API |

## Panels and overlays

| Variable | Apps | Opens or shows |
|---|---|---|
| `ALSOMAPS_OPEN_SETTINGS=1` | visionOS | The Settings window |
| `ALSOMAPS_DEBUG_PANEL=1` | visionOS | The debug panel |
| `ALSOMAPS_DIAGRAM` | macOS | The camera diagram |
| `ALSOMAPS_MARKERS=1` | visionOS | Pivot and centre markers |
| `ALSOMAPS_TILE_BOUNDS=1` | visionOS | Tile bounds |
| `ALSOMAPS_SHOW_TRACK=1` | visionOS | The latest track |
| `ALSOMAPS_PLAY_TRACK=1` | visionOS | Playback of the latest track |

## Immersion (visionOS)

| Variable | Sets |
|---|---|
| `ALSOMAPS_FULL_IMMERSION=1` | Full immersion |
| `ALSOMAPS_HUMAN_SCALE=1` | Human scale |

## Metal renderer

| Variable | Sets |
|---|---|
| `ALSOMAPS_METAL=1` | Draws with the Metal renderer |
| `ALSOMAPS_METAL_CULLING=0` | Turns off off-screen culling |
| `ALSOMAPS_METAL_FOVEATION=0` | Turns off foveation (visionOS) |
| `ALSOMAPS_METAL_STATS=1` | Prints draw counters once a second |

How these are used for measurements is in [notes/metal-renderer.md](../notes/metal-renderer.md).

When you add a variable, add it here.
