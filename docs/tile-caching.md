# Tile caching

How tile requests are cached between loads, what Google's responses allow, and how to measure it.

## What Google sends

Tile (`.glb`) and sub-tileset (`.json`) responses carry:

```
Cache-Control: private, max-age=14400, must-revalidate, no-transform
ETag: ...
Vary: Origin
Vary: X-Origin
Vary: Referer
```

There is no `Age`, `Expires` or `Last-Modified`. The root tileset JSON is the exception: `max-age=0`, so it is revalidated on every load. Request URLs carry a `session` token and the API key, and both are part of the cache key.

## What the app does

Requests go through `URLSessionAssetAccessor` in `Sources/Cesium/CNTileStreamer.mm` (`NSURLSession`; cesium-native is built without curl). It uses:

- **A dedicated `NSURLCache`** (`CNTileCache`): 64 MB memory, 1 GB disk, at `~/Library/Caches/<bundle id>/tiles/` (inside the container when sandboxed). The shared cache is about 10 MB on disk, and one scene is about 56 MB, so entries were evicted before the next load. `NSURLCache` doesn't store a response larger than 5% of its disk capacity, which is far above any tile.
- **`must-revalidate` stripped on store**: By the HTTP spec the directive only applies once a response is stale. CFNetwork applies it to fresh entries too, so every request made a network round trip that came back 304. `CNTileCache` removes it in `storeCachedResponse:forRequest:`, so `max-age` is honoured as sent: tiles are served from disk for four hours, then revalidated by `ETag`.
- **Counters** from `URLSessionTaskMetrics` (`CNFetchStats`, via `CNTileStreamer.fetchStats`): served from cache, revalidated (304), or downloaded, plus bytes over the network. They show in the Mac window overlay, the Tuning stats and the DEBUG log line.

`willCacheResponse` can't do the rewrite: it isn't called for completion-handler tasks, which this accessor uses.

## Results

Ferry Building, 800 m radius, Mac Debug build:

| Run | Time to 100% | Cached | Revalidated | Downloaded |
|---|---|---|---|---|
| Cold (cache deleted) | 8.4 s | 0 | 0 | 611 (56.3 MB) |
| Warm | 4.2 s | 610 | 1 (root JSON) | 0 |

| Cache | Warm result |
|---|---|
| Shared `URLCache` (about 10 MB) | 0 cached, 611 downloaded; evicted before reuse |
| 1 GB cache, `must-revalidate` kept | 611 revalidated (304), 0 MB, about 5.3 s |
| 1 GB cache, `must-revalidate` stripped | 610 cached, 1 revalidated, 0 MB, about 4.2 s |

The remaining 4.2 s is not network time. It is probably decode, mesh and texture upload, and the concurrent-request limit; this hasn't been profiled.

## Which headers cause revalidation

Same 40 KB body served from a local server under each header set, fetched twice with a fresh `URLCache`; second request:

| Response headers | Second request |
|---|---|
| `max-age=14400` | cache |
| `max-age=14400, must-revalidate` | cache + network 200 |
| `private, max-age=14400` | cache |
| `max-age=14400`, `Vary: Origin` | cache |
| `max-age=14400`, `ETag` | cache |
| `max-age=14400, no-transform` | cache |
| Google's full set (above) | cache + network 304 |
| Google's full set, `must-revalidate` stripped | cache |

Only `must-revalidate` matters.

## Policy compliance

Google's policy says clients must respect `max-age`, `stale-while-revalidate`, `must-revalidate` and `private`, and implement `ETag` revalidation. `must-revalidate` means a stale response must not be used without a successful revalidation. It doesn't require revalidating a fresh one. To check that stripping the directive keeps that behavior, a local server sent `Cache-Control: private, max-age=4, must-revalidate, no-transform` with an `ETag`, and the same sequence ran with the directive kept and with it stripped:

| Step | Directive kept | Directive stripped |
|---|---|---|
| Fresh load | download (200) | download (200) |
| Within `max-age` | cache, then 304 round trip | **cache, no network** |
| Stale (after `max-age`), server up | cache, then 304 | cache, then 304 (`If-None-Match`) |
| Stale, server unreachable | error (-1004), stale copy not used | error (-1004), stale copy not used |

Stripped, `max-age` is honoured, stale entries are revalidated by `ETag`, and a stale entry is never served without a successful revalidation. Those are the semantics of `must-revalidate`, even though the stored copy no longer carries the directive. `private` is kept in the header, and the cache is per-user on disk.

Not covered: Google doesn't currently send `stale-while-revalidate`, so nothing implements it. If it appears, check what CFNetwork does with it. This was tested against a local server, not Google's; the Google-header run showed the same cache and 304 behavior but wasn't repeated past 4 hours.

## Measuring

Run the unsandboxed Debug Mac app (see the README) and read the counters in the log, or from outside:

- Delete `~/Library/Caches/com.ryanberdeen.MapVolume/tiles` for a cold run.
- `Cache.db` there is SQLite. `cfurl_cache_response` lists request URLs (which include the API key). `cfurl_cache_blob_data.response_object` is a binary plist of the stored response headers. Copy `Cache.db*` before querying while the app runs.
- Time to 100% comes from the `progress 100%` log line; the log is line-buffered (`setvbuf` in `MapVolumeMacApp`), so it survives the process being killed.

## Open questions

- Stripping `must-revalidate` from the stored copy is behaviorally equivalent in the tests above, but it is a literal change to a header the policy names. Whether that is acceptable is a judgment about the policy's wording; keeping the directive would cost a 304 round trip per tile on every load.
- The visionOS and Release builds compile the same bridge but haven't been run.
