# Remote control

Remote control lets clients control a running Also Maps app from outside it. Agents connect over MCP, people use a CLI, and the iPhone works as a joystick. The owner's decisions are marked **(owner)**. The rest is how it's built, and can change.

**Status (2026-11-05): written but never compiled or run.** It was written in a session that couldn't build Swift. The first job is to build every target, run `AlsoMapsRemoteTests` and `Also Maps Core Tests`, and work through "Checking it" below. Record what you find in `notes/remote-control.md`.

## Goals (owner)

- An agent on the Mac, or anywhere on the same local network, can send the map the commands voice uses, and get results and events back. It's for debugging, and for an agent to fly the user around to look at things or show data (GeoJSON and the like, later). Over time, most app features should be controllable this way.
- It's available from the Mac app and from a CLI.
- It works on the local network only, and stays simple.
- One protocol carries both commands and the iPhone joystick.
- The MCP server keeps a persistent connection so it can receive events. That means it inherits the iPhone connection's robustness problems, and the connection has to be reliable for both uses.
- The first targets are the Mac and Vision Pro. Test on the Mac first, then validate on the headset.
- The headless renderer (PR 37) should later accept the same command set. Its own CLI stays.
- tvOS is left out (AGENTS.md).

## Shape

```
 agent ──stdio MCP──▶ alsomaps-control mcp ─┐
 person ──────────▶ alsomaps-control send ──┼── TLS-PSK / TCP, Bonjour ──▶ Mac app (host)
 iPhone joystick ───────────────────────────┘                          └─▶ Vision Pro app (host)
```

The apps are hosts, and clients connect to them. MCP lives in the CLI, and the apps speak only the protocol below.

| File | What |
|---|---|
| `Sources/Remote/ControlProtocol.swift` | The message envelope, framing, `ControlHello`, the joystick snapshot, and `ControlLocalInfo` (the Debug Mac app's `control.json`). |
| `Sources/Remote/ControlConnection.swift` | `ControlTransport`: the service type, TLS-PSK from the code, and timings. `ControlConnection`: one framed connection with pings and silence detection, used by both ends. |
| `Sources/Remote/ControlHost.swift` | The app's end: the listener, up to 4 clients, merged sticks, queued presses, requests answered in order through a handler, and events. |
| `Sources/Remote/ControlClient.swift` | `ControlBrowser` (Bonjour), and `ControlClient`: requests, events, streaming the sticks, and reconnecting. `ControlCodeBook` remembers codes that worked. |
| `Sources/Remote/MapControl.swift` | One map's host plus its methods and events. `ScreenMap` (Mac, iPhone) and `MapModel` (visionOS) implement `ControllableMap`, merge `host.input` and `takeActions()`, and call `tick()` each frame. |
| `Sources/Remote/RemoteControlPanel.swift` | The on/off switch, code and client list. Shown in a popover on the Mac and a window on visionOS. |
| `Sources/Remote/ControlTools.swift` | The MCP tools and the requests they become. Foundation-only. |
| `SourcesCLI/` | `alsomaps-control`: `Connector` (local file or Bonjour, and codes), `MCPServer`, and the subcommands. |
| `SourcesPhone/PhoneRemoteControlView.swift` | The iPhone joystick. See [iphone-controller.md](iphone-controller.md). |

The CLI target links only the client half (`JSONValue`, `ControlProtocol`, `ControlConnection`, `ControlClient`, `ControlTools`), not the map.

## Protocol (version 2)

Messages go over TCP with Nagle off and keepalive on, with TLS 1.2 PSK from the pairing code. Each frame is a 4-byte big-endian length followed by a JSON body. Every message is a `ControlMessage` with `type` and `v: 2`, and carries only the fields its type uses. A peer speaking another version is disconnected with a message saying so.

| `type` | Direction | Fields |
|---|---|---|
| `hello` | both, first | `hello`. A client sends `{name, kind, wants}`, where `kind` is `phone`, `cli` or `mcp` and `wants` can include `"events"`. The host replies `{name, kind: "host", platform, methods, events}`. |
| `ping` | both | Sent when nothing else has been sent for 1 s. |
| `input`, `inputAck` | client → host, host → client | `input`: a stick snapshot. Each snapshot is acknowledged. |
| `action` | client → host | `action`: a `MapInput.Action` raw value. Unknown values are ignored. |
| `request`, `response` | client → host, host → client | `id`, `method`, `params`. The response has `id`, `ok`, and `result` or `error`. |
| `event` | host → client | `event`, `data`. Sent only to clients that asked for `events`. |

**Liveness is separate from input.** A connection ends only after about 6 s with nothing received, on a network or TLS error, on a malformed frame, or after 10 s without completing the handshake. Stale input (250 ms without a snapshot) zeroes that client's sticks and keeps the connection. A client whose code has worked once reconnects with backoff (0.5 s, doubling to 8 s) until it's told to disconnect. Requests still waiting when a connection drops fail, and aren't resent, since they may have run.

**Limits.** A client's frames are at most 64 KB, and a host's at most 16 MB (room for a screenshot later). Each client can have at most 64 requests queued. A host holds at most 32 queued presses.

**Requests** from one client are answered one at a time, in the order sent, so "climb, then turn" happens in that order. Different clients' requests can interleave.

### Methods

| Method | Params | Result |
|---|---|---|
| `command.run` | `{command: MapCommand, wait?: "started" \| "finished"}` | `{command, summary, ok, detail, source, state}`. With `"finished"`, it answers when the eased motion ends (up to 30 s). A `goTo` is a jump, so it finishes at once. |
| `state.get` | — | `{platform, mode, camera: {latitude, longitude, heightMeters, headingDegrees, pitchDegrees}, altitudeMeters, moving, tiles: {progress, settled}}` |
| `places.list` | — | `[{id, name, latitude, longitude, radiusMeters, headingDegrees}]` |
| `tiles.waitSettled` | `{timeoutSeconds?}` (default 30, 0.5–300) | `state`, plus `settled` and `waitedSeconds`. It waits 0.3 s first, then for 3 readings in a row at 100% with no motion. |
| `action.perform` | `{action}` | `{ok}`. The same as a button press: `previousPlace`, `nextPlace`, `faceNorth` or `toggleFly`. |

### Events

`camera` (at most twice a second, when the camera has moved), `motion.finished`, `tiles.settled` (each time loading reaches 100%), and `command` (every command run on this map, from voice or any client, with its `source`). Events are only worked out while someone is connected.

## Pairing and finding a device

- The host advertises `_alsomaps-rc._tcp` as "Also Maps on <device name>", with `platform` and `v` in the TXT record. visionOS and iOS report a generic device name unless the app has the device-name entitlement.
- The code is 6 digits, kept in `UserDefaults` until **New Code** is pressed, which disconnects everyone. The listener reuses its last port when that port is free. Together, these let a client reconnect after either end restarts.
- Whether remote control is on is also kept. `ALSOMAPS_CONTROL=1` turns it on at launch, and `=0` keeps it off.
- Debug Mac builds write `{name, port, code, platform, pid}` to `~/Library/Application Support/AlsoMaps/control.json` (mode 0600). They remove it when remote control is turned off. The CLI's `local` target reads this file, checks that the pid is alive, and connects to `127.0.0.1:port` with no code.
- Clients remember codes that worked, by device name (`ControlCodeBook`, in `UserDefaults`).
- **Security:** the PSK comes from 6 digits, and nothing limits how many guesses an attacker on the network can make. That's acceptable for local-network debugging and not much more. Per-client keys are the next step (see below).

## CLI

```
alsomaps-control list [--seconds 2]
alsomaps-control state [--to <device>] [--code <code>]
alsomaps-control send [--wait] '<MapCommand JSON>'
alsomaps-control call <method> ['<params JSON>']
alsomaps-control watch
alsomaps-control mcp [--to <device>] [--code <code>]
```

`--to` defaults to `local` if the Debug Mac app is running, or else the only Also Maps on the network. The code comes from `--code`, the code book or `ALSOMAPS_CONTROL_CODE`. Output is JSON on stdout. Logs go to stderr.

## MCP

`alsomaps-control mcp` is a hand-written MCP server using newline-delimited JSON-RPC 2.0 over stdio. It accepts protocol versions 2025-06-18, 2025-03-26 and 2024-11-05, and offers tools only. The official Swift SDK wasn't used because it couldn't be built or tried here. Switching to it is an option if it builds cleanly through XcodeGen.

**Tools:** `list_devices`, `connect`, `go_to`, `climb`, `set_altitude`, `turn`, `face`, `move`, `pitch`, `run_command` (raw MapCommand JSON), `get_state`, `list_places`, `wait_until_settled`, `perform_action`, `recent_events`, and `call_method` (any host method, for ones newer than the tools). Motion tools wait for the motion to finish by default (`wait: false` returns at once). Map tools connect to `local` by themselves the first time. Many MCP clients ignore server notifications, so events are kept (the last 500) for `recent_events`, which takes `after: <sequence>`.

Register it with Claude Code:

```
claude mcp add alsomaps -- /path/to/alsomaps-control mcp
```

## Checking it

None of this has been done yet.

1. **Build:** `xcodegen generate`, then the Mac, iOS, visionOS and tvOS apps, and `alsomaps-control`.
2. **Tests:** run `AlsoMapsRemoteTests` (the loopback and Bonjour tests take about 30 s) and `Also Maps Core Tests` (`ControlToolsTests`).
3. **Mac, end to end:** launch the Debug app with `ALSOMAPS_CONTROL=1`, then:
   - Check `alsomaps-control state`.
   - Run `send --wait` with each command shape in docs/commands.md, and check the camera moves and the result is right.
   - Leave `watch` open while flying with the keyboard and with voice, and check the events.
   - Turn Remote Control off and on, then quit and relaunch the app, and check that `watch` reconnects by itself.
4. **MCP:** register it with Claude Code, then fly the Mac app by asking ("go to the Eiffel Tower, climb 500 m, face north, wait until it's loaded"). Check `recent_events` shows the moves.
5. **Vision Pro:** run the CLI and MCP against the headset over Wi-Fi. Use the iPhone joystick for a long session, together with an agent connected. Record any disconnects, with the reason the status gives, in `notes/remote-control.md`.

## Not done yet

- **`screenshot`:** essential for an agent to look at things. On the Mac it can capture the window. On visionOS the volume and immersive views may need an offscreen render.
- **Per-client pairing keys:** after pairing with the code once, the host would issue a random key that the client keeps in its Keychain, so later connections are silent and the code can be short-lived. The host's panel would list and forget paired clients.
- External commands don't appear in the voice panel's trace. They're in the remote control panel's "Recent Requests", and they're sent as `command` events.
- The iPhone can host (`ScreenMap` has a `MapControl`) but has no UI to turn it on.
- The offscreen renderer (PR 37) as a command target.
- New methods as app features land: layers, GeoJSON, tracks, settings.
