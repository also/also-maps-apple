# Agent notes

## Read the project's docs before the task

This project has its own ways of doing several routine things, and some differ from the usual approach. Before starting one of these, read the doc it names and follow it:

- **Timing or profiling anything:** [docs/profiling.md](docs/profiling.md). Launch through `env -u OS_ACTIVITY_DT_MODE` (without it, `xctrace --launch` records none of the app's signposts), and summarise with `Scripts/signpost_summary.py`.
- **Running, logging from, or inspecting the Mac app:** the README's "Running and inspecting the Mac app" section.
- **Comparing runs, or anything touching tile requests:** [docs/tile-caching.md](docs/tile-caching.md). Decide whether each run starts with a cold or warm cache.
- **Navigation or the camera:** [docs/camera-core.md](docs/camera-core.md) and [docs/navigation-handoff.md](docs/navigation-handoff.md), which records what the owner decided.
- **Setup, keys and building:** the README's "Setup" and "Keys" sections. The Xcode project is generated, so a fresh checkout or worktree needs `xcodegen generate` first. The core tests command is in the README's `Sources/Navigation/` entry.
- **App icons and artwork:** [docs/branding/README.md](docs/branding/README.md).

For any other task, check `docs/` and the README's headings for a matching section first.

## tvOS is a proof of concept

The `Also Maps tvOS` target exists to show that rendering works on Apple TV, and only barely. It isn't a supported platform, so it doesn't need to get every feature.

- When a feature spans the platforms, leave tvOS out by default. Don't design around it, add tvOS-specific UI, or let its limits shape the other platforms.
- Keep the target building. Beyond that, the simplest thing that keeps it working is enough.
- Credentials: tvOS keeps the baked-in key or uses only the attested key. It doesn't get user-supplied keys.
