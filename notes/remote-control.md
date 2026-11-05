# Remote control: working notes

A running log, newest first. Each finding is marked **Observed** (seen running) or **Inferred** (reasoned, not yet seen). The design and reference are in [docs/remote-control.md](../docs/remote-control.md).

## 2026-11-05: version 2 written, not built

- **Inferred:** PR 20's random disconnects on devices may have come from its deadlines. The phone dropped the connection after 500 ms without an acknowledgement, and the host after 1 s without a snapshot. A Wi-Fi stall that short is ordinary, especially over peer-to-peer. Version 2 drops a connection only after about 6 s of silence, and only zeroes the sticks for stale input.
- **Inferred:** a second suspect is that the visionOS app stopped hosting on any scene phase other than `.active`. The app-level scene phase can become `.inactive` without going to the background. Version 2 suspends hosting only on `.background`, and resumes it with the same code.
- **Inferred:** a connection to a Bonjour service endpoint re-resolves on each new `NWConnection`. A client reconnecting after the host restarts should therefore find the new listener, even on a new port. `testReconnectsAfterTheHostRestarts` covers this once it runs.
- None of the code has been compiled. The likeliest compile problems are type inference on `JSONValue` literals, `NWListener.Service(…, txtRecord: NWTXTRecord)`, and concurrency diagnostics on `withCheckedThrowingContinuation` and `async let` in the tests.
