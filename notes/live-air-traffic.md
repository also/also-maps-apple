# Live air traffic: working notes

A spike: live aircraft flying over the 3D city, at their real positions
and heights, with fading trails. Settings › General › **Live air traffic**,
or `ALSOMAPS_AIR_TRAFFIC=1` for a run. Off by default. Branch
`spike/live-air-traffic`.

**Observed** means seen running. **Inferred** means read from docs or
code, or reasoned, but not confirmed. **Nothing in this spike has been
built or run yet.** It was written in a Linux container with no Xcode,
Apple SDKs or Swift toolchain (download.swift.org was blocked too), and
the ADS-B providers' APIs weren't reachable from it either, so even the
JSON samples in the tests are written by hand from the documentation.
Every finding below is Inferred.

## Goals

- Around an airport at tabletop scale (the volume), see approaches and
  departures as small planes with trails, at their real positions and
  heights over Google's tiles.
- The same in the immersive space and on the Mac's screen map.
- Planes glide between reports rather than jumping.
- Free data source, no key, attribution shown, polling within the
  provider's limits and only while the map is on screen.
- The app's default behaviour doesn't change.

## Log (newest first)

### 2026-11-05: first cut

Everything below is the first version of the spike.

## Data source

Read from the providers' docs and source (GitHub), not their live APIs.

| | adsb.lol | OpenSky Network | airplanes.live |
|---|---|---|---|
| Query by area | `/v2/point/{lat}/{lon}/{radius nm}`, ≤ 250 nm | `/states/all?lamin=…` bounding box | `/v2/point/…`, ≤ 250 nm |
| Account | None today; "in the future" a key for feeders | Optional; OAuth2 client credentials (a secret, can't ship in an app) | None today |
| Limits | "Dynamic, based on load"; none published | Anonymous: 400 credits/day per IP, 10 s resolution. Account: 4,000/day, 5 s. A small box is 1 credit | 1 request/s |
| Use by a public app | "You can use the API for free"; nothing against commercial use found | Research and non-commercial only; commercial needs a licence | Labelled non-commercial |
| Licence / attribution | ODbL 1.0 for the API and all its data | Cite their paper in publications; terms page | Not found |

**Chosen: adsb.lol** (Inferred to be the best fit). It's the only one
that's free, keyless and not limited to non-commercial use, and its
answer is readsb's well-documented JSON. OpenSky's anonymous allowance
runs out in about 67 minutes of polling every 10 s, and a registered
client's secret can't be shipped. Risks: adsb.lol says keys (for feeders)
are coming, and limits are unpublished.

Sources: adsb.lol's API source (github.com/adsblol/api: README,
`app.py`'s description, `api_v2.py`, `models.py`); readsb's
`README-json.md` (github.com/wiedehopf/readsb); OpenSky's
`docs/free/rest.rst`, `index.rst` and `states-response.rst`
(github.com/openskynetwork/opensky-api); airplanes.live's API guide, via
search results only.

### The response

adsb.lol's v2 API passes the query to readsb with `jv2` (ADS-B Exchange v2
format): aircraft under `ac`, `now` in **milliseconds**. A local readsb's
`aircraft.json` has `aircraft` and `now` in seconds; the decoder reads
both, so `ALSOMAPS_AIR_TRAFFIC_URL` can point at a receiver.

Fields used (readsb's README-json.md):

- `hex`: ICAO address, the aircraft's id. `~` first for non-ICAO.
- `flight`: callsign, 8 chars padded (trimmed).
- `lat`, `lon`: degrees. `seen_pos`: seconds before `now` the position was
  measured. Positions over 30 s old are dropped.
- `alt_baro`: **barometric** (pressure) altitude, feet, referenced to the
  standard 1013.25 hPa, not corrected for the day's pressure; or the
  string `"ground"`.
- `alt_geom`: **geometric** (GNSS/INS) altitude, feet, "referenced to the
  WGS84 ellipsoid".
- `gs`: ground speed, knots. `track`: true track over ground, degrees.
  This is where it's going, not where the nose points (`true_heading` is
  usually only sent on the ground).
- `baro_rate`, `geom_rate`: feet per minute.
- `category`: emitter category. `C*` (surface vehicles, obstacles) is
  skipped.

## Design

All the logic is plain Swift in `Sources/AirTraffic/`, tested in `Also
Maps Core Tests` (`Tests/AirTraffic/`). Only drawing touches RealityKit.

- `AircraftReport.swift`: `ADSBDecoder` turns a response into
  `AircraftReport`s in SI units, heights above the ellipsoid, lossy per
  aircraft like `AppConfig`.
- `AircraftMotion.swift`: `AircraftMotion` (dead reckoning, easing,
  trail), `AirTrafficTracker` (all aircraft, merge and advance),
  `TrailBands` (cutting trails by age) and `AircraftPose` (marker
  orientation).
- `AirTrafficFeed.swift`: `AirTrafficArea` (what to ask about),
  `AirTrafficQuery` (the URL and attribution), `AirTrafficSchedule`
  (when, with back-off) and `AirTrafficFeed` (the poller, fails open like
  `AppConfigStore`).
- `Sources/AirTrafficOverlay.swift`: the RealityKit drawing, owned by
  `MapModel` (visionOS) and `ScreenMap` (macOS, iOS) next to their track
  overlays.

### Heights

Google's tiles are in ellipsoidal heights, so the goal is height above
the WGS84 ellipsoid (HAE).

1. **Geometric altitude** is used as is. ADS-B version 2 defines it as
   HAE (Inferred from readsb's docs; DO-260B). Error, Inferred: GNSS
   vertical error is typically 10–30 m (the `gva` field bounds it), plus
   25 ft (7.6 m) steps. Some older transponders may send height above
   mean sea level instead, which would be off by the geoid (−32 m around
   San Francisco, −106 m to +85 m worldwide).
2. **Barometric only** (common on older and MLAT targets): pressure
   altitude differs from true height by the day's weather, about 8 m per
   hPa away from 1013.25 and a few percent per 10 °C away from standard
   temperature, so typically 30–300 m, plus the geoid. The decoder
   estimates the weather term from aircraft in the same answer that
   report both: the median of (geometric − barometric) among those within
   3,000 ft of the aircraft's altitude if there are two, else of all of
   them if there are three. Inferred: that brings it to within a few tens
   of metres where there's other traffic. With no estimate it's used as
   is (`heightSource == .barometric`).
3. **On the ground** with only `"ground"`: the host's ground estimate
   (the streaming anchor's height: the low envelope in `MapModel`, the
   camera's ground on a screen). This is only used to place aircraft
   while rendering, which the terms allow; nothing is stored. Inferred:
   it can sit a few metres under the runway, since it's a low envelope.

Vertical rate goes with the altitude used (geometric rate with geometric
altitude).

### Polling

- The area is the streaming area of interest (anchor and radius) widened
  by 1.5×, at least 15 km so approaches show before they reach a small
  map, and at most 75 km so a globe doesn't ask for a continent. Radius in
  whole nautical miles, at most 250.
- Every 10 s while answers come. Failures double the wait from 20 s up to
  2 minutes; a 429 or 503's `Retry-After` is honoured (up to 10 minutes).
  Moving more than half the area's radius asks again early, but never
  within 5 s of the last request or during a back-off.
- **Only while the map is drawn**: the overlay tells the feed about every
  frame, and the feed (checking once a second) only polls if the last
  frame was under 2 s ago. The map ticks from RealityKit's scene update
  (or the Metal frame loop), so a closed or backgrounded map stops
  polling. The feature switch is read once a second, so the toggle
  applies live.
- Ephemeral `URLSession`, cache bypassed: nothing about the traffic is
  written to disk.

### Motion

- Each report's fix time is the device time it arrived minus
  `seen_pos`, so the server's clock never matters (latency, about a
  second, is ignored).
- Between reports: great-circle step along `track` at `gs`, height plus
  vertical rate × time, for at most 20 s past the fix. Aircraft not heard
  of for 45 s are dropped.
- A new report: the aircraft stays where it was shown, and the offset to
  the new dead-reckoned position decays exponentially (95% gone in 2 s).
  More than 3 km snaps and restarts the trail. The same report served
  again (no newer, same place) changes nothing.
- Trails: a point every 2 s, kept for 3 minutes, ending at the aircraft.

### Drawing

- **Markers**: a small dart mesh (fuselage, swept wings, tailplane, fin),
  unit length with its nose along −z, one shared `MeshResource` and
  material, one `ModelEntity` per aircraft placed in the map frame from
  double each frame. Turned to the track, pitched by the climb angle
  (`atan2(vertical rate, ground speed)`, capped at ±30°), wings level.
- **Size**, the track tube's rule: in a room (volume, immersive) 4 cm nose
  to tail at any map scale, trails 2 mm in radius; on a screen 0.04 × the
  camera's height above the ground, trails 0.6× the track tube.
- **Trails**: four age bands (0–45 s … 135–180 s) at opacity 0.85, 0.55,
  0.3 and 0.12, so they fade without per-vertex colour. Each band is one
  `TubeExtruder` mesh for every aircraft, relative to an ECEF origin near
  the area (moved when the area is 150 km away), placed like
  `TrackOverlay`. Rebuilt four times a second.
- Cyan, lit, with some emission, to stand apart from the orange track.
- **Attribution**: "Aircraft: adsb.lol (ODbL)" after the tiles' credits,
  in the visionOS attribution panel and the screen attribution bar, while
  the feature runs. The Google logo and credits are unchanged.
- Show stats adds the aircraft count, or the last error.

### Choices and scope

- Switch: a view preference (`ShowsAirTraffic`, beside Show stats and
  Draw with Metal), not a `StreamingSettings` field, so Reset to Defaults
  leaves it alone. `ALSOMAPS_AIR_TRAFFIC=1` turns it on for a run without
  moving the toggle, like `ALSOMAPS_METAL`.
- iOS gets it for free through `ScreenMap`; it wasn't a goal. tvOS has
  neither host and doesn't compile any of it (only `AttributionBar` grew
  a defaulted parameter).
- Not drawn by the Metal renderers (visionOS immersive or the screen).
- No callsign or altitude label yet (the stretch goal). `State` carries
  the callsign and height for it.

## Unverified

Things the owner's first build will check:

- It compiles: none of it has been through a compiler. Most likely
  trouble: `PhysicallyBasedMaterial.Opacity(scale:)` in
  `AirTrafficOverlay.material(opacity:)` (marked `UNVERIFIED:`), the
  `@Observable` feed's `@ObservationIgnored let`s, and the Swift Testing
  tuple comparison in `AirTrafficFeedTests`.
- The tests pass: their expected values were worked by hand.
- Front faces: the marker's triangles are wound counter-clockwise seen
  from outside, assuming RealityKit culls clockwise ones. If the planes
  look inside out, swap the winding in `makeMarkerMesh`.
- RealityKit stops sending scene updates for a closed or hidden window,
  so polling stops. If a minimised Mac window keeps ticking, polling
  continues there (still capped at one request per 10 s).
- adsb.lol's live answer matches the documented format, including `now`
  in milliseconds and `seen_pos` present with a position.
- Transparent tubes sort acceptably against the tiles and each other.
- Performance: trails for a few hundred aircraft are about 100k vertices
  rewritten on the main thread four times a second; decoding is on the
  main thread too.

## Test plan

### Mac

1. `xcodegen generate`, then the core tests:
   `xcodebuild -scheme 'Also Maps Core Tests' -destination 'platform=macOS' test`.
   Expect the AirTraffic suites (`ADSBDecoderTests`, `DeadReckoningTests`,
   `AirTrafficTrackerTests`, `TrailBandTests`, `AircraftPoseTests`,
   `AirTrafficAreaTests`, `AirTrafficScheduleTests`, `AirTrafficFeedTests`)
   to pass.
2. Build and launch the Debug app over SFO (README, "Running and
   inspecting the Mac app"):

   ```
   ALSOMAPS_AIR_TRAFFIC=1 ALSOMAPS_LAT=37.6189 ALSOMAPS_LON=-122.375 ALSOMAPS_RADIUS=4000 \
     "build/Build/Products/Debug/Also Maps.app/Contents/MacOS/Also Maps" > run.log 2>&1 &
   ```

   Within a second or two the log should show `air traffic on`, then
   `air traffic: N aircraft within 15 km of 37.6…`, every 10 s.
3. Look for cyan darts over the airport and bay, pointing along their
   direction of travel, nose up on departure and down on approach, and
   "Aircraft: adsb.lol (ODbL)" after Google's credits. Turn on Show stats
   (Settings › General) for "N aircraft".
4. Follow one plane for a minute: it should move smoothly, with at most a
   short slide every 10 s, never a jump, and leave a trail that fades
   over three minutes. Compare a few against globe.adsb.lol (position,
   altitude, callsign is in the log only).
5. Heights: arrivals on final should sit on a line down to the runway
   threshold, and aircraft on the ground (taxiing) on the surface, not
   under it or floating. A consistent offset for all aircraft suggests
   geometric altitude isn't HAE; note how big.
6. Zoom out to a 50 km view and back in: planes stay a similar size on
   screen relative to the view.
7. Settings › General › Live air traffic off: within a second the planes,
   trails and attribution go and the log stops. On again: they return
   within ~10 s.
8. Minimise the window for 20 s: no `air traffic:` lines while it's
   hidden. Turn Wi-Fi off: errors back off (20, 40, 80, 120 s, logged in
   Debug); back on, it recovers.

### Vision Pro

1. In the `Also Maps visionOS (Optimised)` scheme, add
   `ALSOMAPS_AIR_TRAFFIC=1`, and tick `ALSOMAPS_LAT` = 37.6189,
   `ALSOMAPS_LON` = -122.375 and `ALSOMAPS_RADIUS` = 3000 (or turn the
   toggle on in Settings, then go to San Francisco and pan to SFO).
2. Volume: 4 cm planes over the table. With a 3 km half-width the
   volume's 0.6 m height is about 3.6 km of sky, so approaches,
   departures and taxiing traffic should all fit, and anything higher is
   clipped by the volume. At a 600 m half-width only the last few hundred
   metres of an approach fit. Check the attribution ornament shows the
   adsb.lol credit.
3. Immersive: planes around the room at their true positions, still 4 cm
   at every scale; far up, traffic over the whole area.
4. Zoom the volume out to 50 km half-width: arrivals and departures
   should show as lines of trails converging on the airport.
5. Close the volume (in volume mode) for 20 s, reopen: polling should
   have stopped meanwhile (Xcode console).
6. tvOS: only check the `Also Maps tvOS` scheme still builds.

## Open questions

- **Privacy**: while it's on, the map's location (to 4 decimal places,
  about 10 m) and the device's IP go to adsb.lol every 10 s. The privacy
  policy and terms probably need to say so before this ships. Round the
  centre more coarsely?
- **Terms**: is drawing aircraft over Google's tiles fine under "no other
  providers' map content"? Inferred yes: it's live data about objects,
  not a basemap, but it's the owner's call.
- **ODbL**: is "Aircraft: adsb.lol (ODbL)" enough notice? adsb.lol
  doesn't ask for specific wording. Should Settings link to adsb.lol and
  the licence?
- **Provider**: is adsb.lol acceptable for the App Store build, given
  unpublished limits and keys coming for feeders? Cost of a commercial
  source if not?
- **Sizes**: are 4 cm in a room and 0.04 × altitude on a screen right? A
  real 70 m airliner is about 0.06 m at a 600 m volume, so markers are
  exaggerated for anything but the closest views.
- **Labels**: callsign and altitude on look (visionOS hover effect) or
  pointer hover (Mac) as the next step?
- **Filtering**: show helicopters, light aircraft, ground traffic? Colour
  by category or by height?
