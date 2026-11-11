# Mac window restoration

## 2026-11-05 — SIGTERM followed by a windowless launch

**Observed:** after terminating the macOS Also Maps process with plain
`kill <pid>` (SIGTERM), relaunching the same executable could leave the app
running with no map window and no stdout or stderr output. The failure
occurred after the second SIGTERM/relaunch cycle in this investigation;
the first cycle reopened the map normally. The cause remains unresolved.

The test used an unsandboxed Debug build on macOS 27.0.1 (26A434),
launched directly with `ALSOMAPS_LAT=37.7955`,
`ALSOMAPS_LON=-122.3937`, and `ALSOMAPS_RADIUS=800`. No source changes,
rebuilds, defaults resets, cache deletions, or saved-state deletions were made.
The bundle ID was `dev.also.maps`.

Build tested:

```
/private/tmp/claude-501/-Users-ryan-work-maps/dfd136c3-5119-4bf1-b605-a8d928795e81/scratchpad/dd-sign/Build/Products/Debug/Also Maps.app
```

**Observed:** the failure was intermittent, rather than occurring after every
SIGTERM. Each signal targeted the launched executable's PID; relaunch used
the same binary and environment, with stdout and stderr redirected together.

| Launch | PID | Result |
| --- | --- | --- |
| Initial | 59083 | Map window; 2,478 bytes of output captured before SIGTERM. |
| After first SIGTERM | 59436 | Map window; nonempty output. |
| After second SIGTERM | 59828 | Process alive, AppKit reported launch finished, no Core Graphics windows, zero output after eight seconds. |
| Later launches | 59990, 60155 | Both reported launch finished with no windows; PID 60155 still had zero output after eight seconds. |

**Observed:** PID 59990 appeared during a computer-use accessibility check
after PID 59828 was terminated. That check timed out. Treat it as a
tool-triggered launch, not an independently controlled direct-launch trial.
PID 60155 was a direct launch. Both windowless processes were then quit
using `NSRunningApplication(processIdentifier:).terminate()`.

**Observed:** the system log contained
`has no restoredWindow, skipping ordering` for both the successful PID 59436
and the windowless PIDs 59828, 59990 and 60155. This message by itself does
not establish that no new window was presented. Collect actual window
evidence and process status alongside it:

```sh
log show --last 5m --style compact \
  --predicate 'process == "Also Maps" AND eventMessage CONTAINS "restoredWindow"'
```

**Observed:** after cleanly quitting the windowless processes, a launch with
`-ApplePersistenceIgnoreState YES` opened a 1200 × 800 map window and
produced output. Subsequent checks also succeeded: a plain launch after
SIGTERM, a plain launch after a clean AppKit quit, and an ignore-state launch
after SIGTERM. The last test process was cleanly quit. These checks establish
working launch paths, but do not isolate which recovery step repaired the
original bad state or prove either workaround always succeeds.

**Observed:** `~/Library/Saved Application State/dev.also.maps.savedState`
was absent when checked, including after a successful relaunch. No saved
state was removed. The reported conventional path is not a reliable presence
check for restoration state on this system.

**Observed:** a later examination of the same runs' AppKit
`StateRestoration` logs showed a difference between SIGTERM and a clean
quit. AppKit wrote restoration records while the app was running; it did
not wait until exit to save them.

| Event | Log evidence |
| --- | --- |
| Initial launch, PID 59083 | `hasPersistentStateToRestore=0`; later `flushAllChanges` and `writing records`. |
| Relaunch after SIGTERM, PID 59436 | `hasPersistentStateToRestore=1`; a map window appeared, and AppKit later wrote records again. |
| Windowless launches, PIDs 59828, 59990, 60155 | Each reported `hasPersistentStateToRestore=1`. |
| Clean quit of PIDs 59990 and 60155 | Each logged `discardAllPersistentStateAndClose`. |
| Next launch, PID 60383, with the ignore-state flag | `hasPersistentStateToRestore=0`; a map window appeared. |
| Later plain launch, PID 60649, and its clean quit | `hasPersistentStateToRestore=0`, followed at quit by `discardAllPersistentStateAndClose`. |
| Plain launch after that clean quit, PID 60723 | `hasPersistentStateToRestore=0`; a map window appeared. |

**Inferred:** SIGTERM can leave the state written during execution available
for restoration, whereas the clean quits observed here discarded it. The
problem need not involve a partially written or corrupt file. These logs
do not establish that every normal quit, under every window-restoration
preference, discards state.

**Observed:** the saved SwiftUI window identifier included private view
types with address-bearing names, for example
`AlsoMaps.(unknown context at $1050fd0b4).CredentialGate` and
`AlsoMaps.(unknown context at $1050fc62c).AppGate`. These addresses differed
between launches of the same binary. The successful PID 59436 tried to
restore the previous launch's identifier containing `$1033790b4`; the
windowless launches tried to restore PID 59436's identifier containing
`$1050fd0b4`. In both cases, `SwiftUI.AppWindowsController` returned
`window=0x0` with `error=(null)` to AppKit's restoration callback.

**Inferred:** an unstable generated window identifier is a candidate for
the failed restoration. It does not yet explain why PID 59436 created a
new map window despite that callback returning no window, while later
launches did not. No experiment has isolated identifier stability as the
cause.

**Observed:** an attempt to locate the actual state files under
`~/Library/Daemon Containers` failed with `Operation not permitted`, even
outside the shell sandbox. No snapshots or decoded state-file comparisons
were obtained. The log evidence above is not a file comparison.

[Mothers Ruin's investigation of the saved-state format](https://www.mothersruin.com/software/Archaeology/reverse/appstate.html)
describes macOS 15 and later moving this storage into the `talagentd`
daemon container. Its `ApplicationMapping.plist` maps apps to UUID-named
state directories. `windows.plist` holds window metadata, while `data.data`
holds encrypted responder archives. This is external format research,
not a verified inspection of this app's files on this machine.

**Inferred / next experiment:** with access to the daemon container,
snapshot the app's state while a map window is open, after SIGTERM, and
after a clean AppKit quit, keeping the binary and launch environment the
same. Wait for a logged state flush before each exit; short runs that have
not written state are not comparable. Compare directory presence, window
records and identifiers, then decoded archives rather than ciphertext
alone. Snapshot again after a windowless relaunch to see whether that
launch changes the state. Access requires Full Disk Access for the process
copying the files, or copies provided from an already authorized process.

**Inferred:** restoration state is involved, given the restoration messages
and the recovery sequence. The exact stored state and cause are not yet
isolated. Builds using `dev.also.maps` share the same restoration namespace;
a different build directory is not sufficient isolation.

**Inferred / untested:** adding `.defaultLaunchBehavior(.presented)` to the
Mac `WindowGroup` may ensure a new window when restoration fails. This run
did not change or validate that modifier. A regression check should first
capture a repeatable bad-state baseline, then compare the modified build
without the ignore-state flag.

Raw local captures and the inspection helper were saved in
`/private/tmp/alsomaps-relaunch-check/` (temporary, not checked in). The
detailed restoration log was no longer present when this note was updated
on 2026-11-11; the findings above were retained from the investigation's
captured output. Agent launch instructions are in the README's
[Running and inspecting the Mac app](../README.md#running-and-inspecting-the-mac-app-for-tools-and-agents)
section.
