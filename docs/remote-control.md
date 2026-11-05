# Remote control: design and hand-off

This is the design for controlling a running Also Maps app from outside it. Agents (over MCP), people (from a CLI) and the iPhone joystick are the clients. It was written on 2026-11-05 to hand to an agent that can build and run the apps. Nothing here is built yet. The owner's decisions are marked **(owner)**. Everything else is a proposal, so change it if building shows it's wrong, and say so in the PR.

## Goals

- **(owner)** An agent on the Mac, or anywhere on the same local network, can send the map commands that voice already uses, and get results and events back. It's for debugging, and for letting an agent fly the user around to look at things or show data (GeoJSON and the like, later). Over time, most app features should be controllable this way.
- **(owner)** The same thing is available from the Mac app and from a CLI.
- **(owner)** Local network only. Keep it simple.
- **(owner)** One protocol for both commands and the iPhone joystick.
- **(owner)** The MCP server holds a persistent connection so it can receive events. That means it inherits the iPhone connection's robustness problems (PR 20's random disconnects), and the connection has to be made reliable for both uses.
- **(owner)** The first targets are the Mac app and Vision Pro. Develop and test on the Mac first, because the cycles are faster, then validate on the headset.
- **(owner)** The headless renderer (PR 37) should eventually take the same command set. Its existing CLI stays.
- tvOS is left out (AGENTS.md).

## What already exists

- **PR 20 (`feature/iphone-remote`), `Sources/Remote/`.** visionOS hosts an `NWListener` that advertises `_alsomaps-rc._tcp` over Bonjour, with peer-to-peer enabled. The phone browses for it and connects over TLS 1.2 with a pre-shared key (PSK) derived by HKDF from a 6-digit code shown on the headset. Frames are length-prefixed JSON, at most 4 KB. The phone sends joystick snapshots at about 60 Hz, with one acknowledgement outstanding at a time, and sends button actions as separate messages. Limits: one connection at a time; the host is visionOS only; the code changes every time hosting is enabled.
- **PR 35 (`voice-control`), `Sources/Commands/`.** `MapCommand` is a Codable command set in SI units, and `MapCommandRunner` resolves names and returns `MapCommandResult`. `ScreenMap` (Mac, iPhone) and `MapModel` (visionOS) implement `MapCommandTarget`. The JSON shape is in `docs/commands.md`, which already names MCP and the iPhone remote as the intended next clients.
- **PR 37 (`stereo-video-capture`).** Offscreen Metal CLIs. Not needed for the first version.

Base the work on PR 20 and PR 35 together: a branch from `main` with both merged in. PR 35 currently conflicts with `main`, so resolve that first.

## Shape

```
 agent ──stdio MCP──▶ alsomaps-control mcp ─┐
 person ──────────▶ alsomaps-control send ──┼── TLS-PSK / TCP, Bonjour ──▶ Mac app (host)
 iPhone joystick ───────────────────────────┘                          └─▶ Vision Pro app (host)
```

- **The apps are hosts. Clients connect to them.** PR 20 already works this way on the headset, it lets one client reach several devices, and it keeps the apps simple. The Mac app gains a host. visionOS keeps its own, generalised. The iPhone stays a client only, for now.
- **MCP lives in the CLI, not the apps.** `alsomaps-control` is a macOS command-line target. Its `mcp` subcommand is a stdio MCP server, and its other subcommands are for people and scripts. The apps only speak the control protocol below.
- **The client library is shared.** The phone and the CLI use one Swift client (discovery, pairing, request/response, events) built from `Sources/Remote/`.

## Protocol (version 2)

Keep PR 20's transport: TCP with Nagle off, TLS-PSK from the code, 4-byte big-endian length prefix, JSON body. Replace the message set with an envelope that has a type field:

| `type` | Direction | Purpose |
|---|---|---|
| `hello` | both | First message. The client sends a name, its kind (`phone`, `cli`, `mcp`), the protocol version and the capabilities it wants (`input`, `commands`, `events`). The host replies with its device name, platform, version and supported methods. |
| `ping` / `pong` | both | Liveness only. Send about once a second, and drop a connection after about 5 s of silence. |
| `input` | client → host | A joystick snapshot (`RemoteControlState`, as now), acknowledged for backpressure as now. |
| `action` | client → host | A button press (`MapInput.Action`), as now. |
| `request` | client → host | `{id, method, params}`. |
| `response` | host → client | `{id, ok, result}` or `{id, ok: false, error}`. |
| `event` | host → client | `{name, data}`, sent only to clients that asked for `events`. |

**Liveness and input staleness are separate.** This is the main robustness change. Today the host disconnects after 1 s without input, and the phone disconnects after 500 ms without an acknowledgement. That would kill an idle MCP connection at once, and it's the leading suspect for PR 20's random disconnects (**Inferred**, not confirmed). In version 2:

- Stale input (250 ms without a snapshot) zeroes the joystick and never disconnects.
- Late acknowledgements make the phone skip snapshots, not drop the connection.
- Only ping silence, or a real network or TLS failure, ends a connection.
- The client reconnects automatically with backoff, using the code it already paired with. Record in `notes/` what the disconnects actually were.

**Several clients.** The host accepts a few connections at once (a cap of about 4): for example, the MCP server and the phone together. Joystick input comes from the most recent sender. Commands from any client queue in order.

**Frame size.** Keep a small limit for `input`, `action` and `ping`. Allow larger frames for `response` (about 8 MB) so a screenshot can come back later.

**Methods (first version):**

- `command.run`: params are a `MapCommand` and an optional `wait` (`"started"` by default, or `"finished"`, which returns once the eased motion ends). Returns `MapCommandResult`.
- `state.get`: returns the camera pose (latitude, longitude, height, heading, pitch), the height above ground, whether tiles are still loading, and the platform or mode (Mac window, visionOS volume or immersive).
- `places.list`: returns the saved places.
- `tiles.waitSettled`: returns when loading goes idle, or at a timeout. Agents need this before they judge what's on screen.

**Events (first version):** `camera` (throttled to a few Hz), `motion.finished`, `tiles.settled`, and `command` (any command run on this host, including voice and other clients, so the agent sees what the user did).

**Later:** `screenshot` (a PNG of the map, essential for an agent to look at things), layer and GeoJSON loading as those features arrive, and voice requests as text.

## Pairing

- **Phase 1.** Use PR 20's 6-digit code with PSK. The code stays the same for as long as hosting is enabled, so a persistent MCP server can reconnect without the user typing it again. Debug Mac builds run unsandboxed, so they also write the host's name, port and code to `~/Library/Application Support/AlsoMaps/control.json`. That lets a CLI on the same Mac connect with no human step. Release builds don't write the file.
- **Phase 2.** After the first pairing with a code, the host issues a per-client random key. The client keeps it in its Keychain and uses it as the PSK identity and secret from then on, so later connections are silent. The host lists paired clients and can forget them.
- Use the real device name in the Bonjour service name, not `Also Maps 1234`. Put the platform and protocol version in the TXT record.

## CLI

`alsomaps-control` (a macOS tool target in `project.yml`):

- `list`: hosts found on Bonjour, with name, platform and version.
- `send <host> '<MapCommand JSON>' [--wait]`: prints the result.
- `state <host>`: prints the camera and tile state.
- `watch <host>`: prints events.
- `mcp`: the stdio MCP server.

Host selection takes a name or `local`, where `local` means the file written by Debug Mac builds.

**MCP tools:** `list_devices`, `connect` (device, plus a code if needed), `go_to`, `climb`, `set_altitude`, `turn`, `face`, `move`, `pitch`, `get_state`, `list_places`, `wait_until_settled`, `recent_events`, and later `screenshot`. Amounts are in SI units, and tool descriptions take their wording from `docs/commands.md`. Many MCP clients ignore server notifications, so expose events through `recent_events` and through motion tools that wait until finished by default, as well as notifications. Use the official MCP Swift SDK if it builds cleanly through XcodeGen and SPM. Otherwise hand-write the small part of JSON-RPC over stdio that's needed.

## In the apps

- Split `RemoteControlSession` into a `ControlHost` and a `ControlClient`. The host feeds `input` and `action` into the existing `MapInput` merge, and sends `command.run` to the same `MapCommandRunner` that voice uses.
- The Mac `ScreenMap` gets a host. visionOS keeps its own.
- The host UI (generalised from `RemoteControlHostView`, and added to the Mac) offers **Allow remote control**, and shows the code, the connected clients and their kinds, and recent external commands. External commands also appear in the voice panel's trace.

## Phases and how to check each

1. **Protocol version 2 and a robust session.** Envelope, ping, separating liveness from input, several clients, reconnect. Move the phone joystick onto it. Extend `Tests/Remote` with loopback tests: an idle connection survives 30 s or more; stale input zeroes the joystick without disconnecting; two clients at once; reconnect after the host restarts.
2. **Mac host plus the `send`, `state` and `watch` CLI.** Check end to end against the Debug Mac app: run each command, check the result and the camera state, and see events arrive.
3. **MCP.** Register `alsomaps-control mcp` with Claude Code on the Mac, and fly the Mac app by asking ("go to the Eiffel Tower, climb 500 m, face north").
4. **Vision Pro.** The same CLI and MCP against the headset over Wi-Fi, and the phone joystick for a long session. Record what disconnected, and why, in `notes/`.
5. **Later.** Pairing keys, `screenshot`, the offscreen renderer as a command target, and new methods as app features land.

## Open questions

- Should the iPhone also host, so an agent can drive the phone's map? It's cheap once the Mac host exists, but it isn't asked for yet.
- `screenshot` on visionOS: the volume and immersive views may need a separate offscreen render rather than a capture of what's shown.
