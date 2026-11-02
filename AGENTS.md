# Agent notes

## tvOS is a proof of concept

The `Also Maps tvOS` target exists to show that rendering works on Apple TV, and only barely. It isn't a supported platform, so it doesn't need to get every feature.

- When a feature spans the platforms, leave tvOS out by default. Don't design around it, add tvOS-specific UI, or let its limits shape the other platforms.
- Keep the target building. Beyond that, the simplest thing that keeps it working is enough.
- Credentials: tvOS keeps the baked-in key or uses only the attested key. It doesn't get user-supplied keys.
