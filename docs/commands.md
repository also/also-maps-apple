# Map commands

Map commands are discrete instructions to the map: go somewhere, climb, turn, move. They aren't continuous input like sticks and gestures. Voice control is the first source. The same commands are meant for external control later: an MCP server, so an agent can fly the map, and the iPhone remote.

## Pieces

- **`MapCommand`** (`Sources/Commands/MapCommand.swift`) is the vocabulary. It's Codable, and amounts are in metres and degrees, so every source converts units the same way before a command reaches the map.
- **`MapCommandRunner`** carries a command out. It resolves names first: a saved place by whole name or id, otherwise the first MapKit search result, with the view sized from the result's region. It then hands the map a `Place` or a `CommandMotion`, and returns a `MapCommandResult` saying what happened.
- **`MapCommandTarget`** is what a map implements: `ScreenMap` (Mac, iPhone) and `MapModel` (visionOS). The map decides how a command looks. Climbs, turns and moves ease over 1.2 s through the same `NavigationOperations` the controls use, so climbing changes height only and turning happens in place. Taking the controls cancels a motion. On visionOS, pitch is dropped because the hosts set it, and a motion stops at the held region while tiles are held.

## JSON

Each command is a single-key object, the shape Swift synthesizes for enums with labelled associated values:

```json
{"goTo": {"destination": {"named": {"name": "Eiffel Tower"}}}}
{"goTo": {"destination": {"coordinate": {"latitude": 36.7418, "longitude": -5.167, "radius": 500}}}}
{"climb": {"meters": 304.8}}
{"setAltitude": {"meters": 150}}
{"turn": {"degrees": -45}}
{"face": {"headingDegrees": 90}}
{"move": {"forwardMeters": 2000, "rightMeters": 0}}
{"pitch": {"degrees": -15}}
```

- **`climb`**: negative descends.
- **`setAltitude`**: height above the ground under the camera.
- **`turn`**: clockwise seen from above, so negative turns left.
- **`face`**: degrees clockwise from north.
- **`move`**: along and across the direction of travel, at constant height.
- **`pitch`**: positive looks up. The visionOS hosts ignore it.

`MapCommandCodingTests` pins this shape. Renaming a case or label changes the wire format.

## Voice

`Sources/Voice/` turns speech into commands, entirely on device.

1. **Listen.** `SpeechListener` runs SpeechAnalyzer with SpeechTranscriber, using volatile results. Recognition is biased toward the saved places' names. Hold the talk button while speaking, or tap it to listen until the first pause. The talk button is the mic button in the voice panel, Space on a keyboard, or RB on a controller.
2. **Interpret.** `CommandInterpreter` sends the transcript to the Apple Intelligence model. In the default **tools** mode, the model calls one tool per command it hears (`MapTools.swift`: `goTo`, `changeAltitude`, `turn`, `move`, `look`, `zoom`), or `notACommand`. Arguments keep the numbers and units as spoken. The calls are collected rather than run.
3. **Convert.** `SpokenCommand.mapCommand(altitude:)` converts units and fills in defaults in code. For example, "climb" with no amount doubles the height above the ground, and "turn left" turns 90°.
4. **Run.** `VoiceControl` runs the commands in order, waiting for each motion to finish.

The **guided** mode generates a whole `VoicePlan` by guided generation instead. It's faster (about 0.8 s against 1.2–2 s on an M-series Mac), but it wouldn't call a request "not a command" or split a compound request.

**The trace.** `VoicePanel` shows, for each request, the recognised speech (volatile text greyed), the tool calls and their arguments, the model's reply, each command, its result and the timings. The text field runs a typed request through the same pipeline. While you type, the map stops reading the keyboard.

**Testing.** `InterpreterTests` sends sample phrases to the real model, and is off by default:

```
TEST_RUNNER_ALSOMAPS_MODEL_TESTS=1 xcodebuild -scheme 'Also Maps Core Tests' -destination 'platform=macOS' test -only-testing:'Also Maps Core Tests/InterpreterTests'
```

Add `TEST_RUNNER_ALSOMAPS_MODEL_MODE=guided` to compare modes. `ALSOMAPS_VOICE="ascend 1000 ft; go to Ronda"` runs requests at launch, and Debug builds log each turn to stdout as `[AlsoMaps] voice:`.

**Known limits.**

- **Order:** the model sometimes calls tools in a compound request out of the order spoken. Calls are put back in the order the transcript records, but that's the model's own order.
- **Device:** this needs Apple Intelligence, so an eligible device with it turned on. The panel says why when it's unavailable.
- **Search:** a search result's region can be large. "Ronda" frames the whole municipality, about 28 km across.

## External control

Remote control sends this JSON from outside the app: the `alsomaps-control` CLI, its MCP server for agents, or anything speaking the protocol. The method `command.run` takes `{"command": <MapCommand>, "wait": "started" | "finished"}`. The app runs it through its own `MapCommandRunner`, the one voice uses, and answers with the result and the camera state. Commands from voice and from clients are also sent as `command` events. See [remote-control.md](remote-control.md).

The MCP tools (`Sources/Remote/ControlTools.swift`) mirror `MapTools`, but in SI units, since an agent can convert units itself. They build this JSON by hand because the CLI doesn't link the map. `ControlToolsTests` checks that each one decodes to the intended `MapCommand`.
