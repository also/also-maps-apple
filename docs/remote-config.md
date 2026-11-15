# Remote config

Every platform reads `https://maps.also.dev/config/v1.json`, a static file, on launch, on returning to the foreground and every 15 minutes while active (every minute while blocked). [`Sources/Config/`](../Sources/Config/) holds the file's model and rules (`AppConfig`), its fetching and saved copy (`AppConfigStore`) and how the app applies it (`AppGate`).

```json
{
  "notices": [
    {
      "id": "update-required-1.2",
      "severity": "blocking",
      "title": "Update required",
      "body": "This version of Also Maps no longer works.",
      "link": { "title": "Update", "url": "https://apps.apple.com/app/id0000000000" },
      "platforms": ["visionos", "ios", "macos", "tvos"],
      "minVersion": "1.0",
      "maxVersion": "1.1.9",
      "keySource": "app",
      "expires": "2027-01-01T00:00:00Z"
    }
  ],
  "places": []
}
```

All the top-level keys are optional. A notice needs `id`, `severity`, `title` and `body`; everything else narrows who sees it. Versions compare against `CFBundleShortVersionString`, inclusive at both ends, so a fix that a notice shouldn't reach needs a new version number. `expires` takes ISO 8601 without fractional seconds.

- **`info`** shows as an alert, once. Give a new message a new `id`.
- **`blocking`** replaces the app, stopping streaming, until it no longer applies. With no version range it's the kill switch; with `maxVersion` it's a minimum version. Don't let one match a build in App Review, or the reviewer sees a blocked app.
- **`places`** has the format of `Places.json`, and replaces the bundled list when it has at least one usable entry.
- **`keySource`** on a notice limits it to people on the app's key (`"app"`) or their own (`"own"`). Having your own Google key counts as `"own"`, since that's the quota the notice protects. A blocking `"app"` notice offers **Use Your Own Key**, so it can stop the shared key without stopping everyone.
- **`"appKeys": false`** at the top level turns off the app's key. People on it see how to add their own.

The app fails open: launch never waits for the file, it starts from the last good copy (or the bundled places), and an outage or a bad file leaves that in place. Unusable notices and places are skipped, while older builds ignore unknown fields. Don't add a new way to narrow a notice's audience to a live notice: older builds would ignore it and show the notice more widely. Change the format incompatibly only at a new URL (`v2.json`). The file is public, so it must never hold secrets. The block is enforced by the app, so it doesn't reach older builds or protect the API keys; those need quotas on the services themselves.

`ALSOMAPS_CONFIG_URL=<url>` reads another file instead, without touching the saved copy, and accepts `file://` URLs.
