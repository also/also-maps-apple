# Agent notes

## tvOS is a proof of concept

The `Also Maps tvOS` target exists to show that rendering works on Apple TV, and only barely. It isn't a supported platform, so it doesn't need to get every feature.

- When a feature spans the platforms, leave tvOS out by default. Don't design around it, add tvOS-specific UI, or let its limits shape the other platforms.
- Keep the target building. Beyond that, the simplest thing that keeps it working is enough.
- Credentials: tvOS keeps the baked-in key or uses only the attested key. It doesn't get user-supplied keys.

## Google tile requests aren't the cost

Google meters Photorealistic 3D Tiles by root tileset request, not by tile. Its [usage limits](https://developers.google.com/maps/documentation/tile/usage-and-billing) say root requests count against the daily quota and "Tile requests for Photorealistic 3D Tiles don't impact your daily quota"; renderer tile requests are unlimited per day.

- Don't treat loading more tiles (higher detail, height queries, preloading) as a billing or quota cost. Judge it on time, bandwidth and memory.
- What does cost is a new root request: each streamer the app creates makes one, and a session lasts up to three hours. Avoid designs that recreate the streamer often.
- The limit that can bite on tiles is the rate: 12,000 tile requests per minute per project.
