import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// What remote control needs from a map, beyond running commands.
@MainActor
protocol ControllableMap: MapCommandTarget {
    /// A commanded climb, turn or move is still easing.
    var isRunningCommandMotion: Bool { get }
    /// 0–100; 100 when everything wanted for this view has loaded.
    var tileLoadProgress: Double { get }
    /// How the map is shown: "window", "volume", "immersive"…
    var controlMode: String { get }
}

/// Remote control for one map: the host, and the methods and events that
/// connect it to the map. The map merges `host.input` and
/// `host.takeActions()` with its other controls, and calls `tick` each
/// frame. See docs/remote-control.md for the methods.
@MainActor
final class MapControl {
    let host: ControlHost
    let runner: MapCommandRunner
    private weak var map: (any ControllableMap)?

    private var lastCamera: CameraPose?
    private var lastCameraEvent = ContinuousClock.now
    private var wasMoving = false
    private var wasSettled = true

    static let methods = ["command.run", "state.get", "places.list", "tiles.waitSettled", "action.perform"]
    static let events = ["camera", "motion.finished", "tiles.settled", "command"]

    /// `voice`: the voice control's runner, so voice commands are reported
    /// as `command` events too.
    init(map: any ControllableMap, platform: String, voice: MapCommandRunner? = nil) {
        self.map = map
        host = ControlHost(platform: platform, name: Self.defaultName)
        runner = MapCommandRunner(target: map)
        host.methods = Self.methods
        host.eventNames = Self.events
        host.handler = { [weak self] request in
            guard let self else { throw ControlHost.Failure("The map has closed") }
            return try await self.answer(request)
        }
        voice?.didRun = { [weak self] result in self?.report(result, source: "voice") }
        #if os(macOS) && DEBUG
        host.localFile = ControlLocalInfo.defaultURL
        #endif
        // ALSOMAPS_CONTROL=1 turns it on at launch (for agents launching the
        // Mac app), =0 keeps it off; otherwise it's as it was left.
        switch ProcessInfo.processInfo.environment["ALSOMAPS_CONTROL"] {
        case "1": host.start()
        case "0": break
        default: if host.wasEnabled { host.start() }
        }
    }

    private static var defaultName: String {
        #if os(macOS)
        "Also Maps on \(Host.current().localizedName ?? "Mac")"
        #elseif canImport(UIKit)
        "Also Maps on \(UIDevice.current.name)"
        #else
        "Also Maps"
        #endif
    }

    // MARK: Events

    /// Call once per frame, after the camera has moved.
    func tick() {
        guard let map, host.isEnabled, !host.clients.isEmpty else { return }
        let now = ContinuousClock.now
        let camera = map.commandCamera
        if now - lastCameraEvent >= .milliseconds(500), lastCamera.map({ Self.differs(camera, $0) }) ?? true {
            lastCamera = camera
            lastCameraEvent = now
            host.broadcast("camera", Self.json(camera))
        }
        let moving = map.isRunningCommandMotion
        if wasMoving, !moving { host.broadcast("motion.finished", state()) }
        wasMoving = moving
        let settled = map.tileLoadProgress >= 100
        if settled, !wasSettled { host.broadcast("tiles.settled", state()) }
        wasSettled = settled
    }

    private func report(_ result: MapCommandResult, source: String) {
        host.broadcast("command", Self.json(result, source: source))
    }

    // MARK: Methods

    private func answer(_ request: ControlHost.Request) async throws -> JSONValue {
        guard let map else { throw ControlHost.Failure("The map has closed") }
        switch request.method {
        case "command.run":
            guard let value = request.params?["command"] else {
                throw ControlHost.Failure("command.run needs params {\"command\": {...}}; see docs/commands.md")
            }
            let command: MapCommand
            do {
                command = try value.decode(MapCommand.self)
            } catch {
                throw ControlHost.Failure("Not a map command: \(value.jsonString). See docs/commands.md for the shapes.")
            }
            let result = await runner.run(command)
            report(result, source: request.client.name)
            if result.ok, request.params?["wait"]?.string == "finished" {
                try await waitForMotion(map)
            }
            var answer = Self.json(result, source: request.client.name)
            if case var .object(fields) = answer {
                fields["state"] = state()
                answer = .object(fields)
            }
            return answer
        case "state.get":
            return state()
        case "places.list":
            return .array(PlaceLibrary.all.map { place -> JSONValue in
                ["id": .string(place.id), "name": .string(place.name), "latitude": .number(place.latitude),
                 "longitude": .number(place.longitude), "radiusMeters": .number(place.radius),
                 "headingDegrees": .number(place.heading)]
            })
        case "tiles.waitSettled":
            let timeout = request.params?["timeoutSeconds"]?.number ?? 30
            return try await waitForTiles(map, timeout: min(max(timeout, 0.5), 300))
        case "action.perform":
            guard let raw = request.params?["action"]?.string, let action = MapInput.Action(rawValue: raw) else {
                throw ControlHost.Failure("action.perform needs {\"action\": one of previousPlace, nextPlace, faceNorth, toggleFly}")
            }
            host.enqueue(action)
            return ["ok": true]
        default:
            throw ControlHost.Failure("Unknown method \(request.method). This host has: \(Self.methods.joined(separator: ", "))")
        }
    }

    private func waitForMotion(_ map: any ControllableMap) async throws {
        let deadline = ContinuousClock.now + .seconds(30)
        while map.isRunningCommandMotion, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
    }

    /// Returns when loading has stayed at 100% for a moment, or at the
    /// timeout, with `settled` saying which. Waits briefly first, since a
    /// view that just changed may not have asked for its tiles yet.
    private func waitForTiles(_ map: any ControllableMap, timeout: Double) async throws -> JSONValue {
        let start = ContinuousClock.now
        let deadline = start + .milliseconds(Int(timeout * 1000))
        try await Task.sleep(for: .milliseconds(300))
        var settledChecks = 0
        while ContinuousClock.now < deadline {
            if map.tileLoadProgress >= 100, !map.isRunningCommandMotion {
                settledChecks += 1
                if settledChecks >= 3 { break }
            } else {
                settledChecks = 0
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        let elapsed = ContinuousClock.now - start
        let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
        var answer = state()
        if case var .object(fields) = answer {
            fields["settled"] = .bool(settledChecks >= 3)
            fields["waitedSeconds"] = .number((seconds * 10).rounded() / 10)
            answer = .object(fields)
        }
        return answer
    }

    // MARK: JSON

    func state() -> JSONValue {
        guard let map else { return ["error": "The map has closed"] }
        let progress = map.tileLoadProgress
        return [
            "platform": .string(host.platform),
            "mode": .string(map.controlMode),
            "camera": Self.json(map.commandCamera),
            "altitudeMeters": .number(map.commandAltitude.rounded()),
            "moving": .bool(map.isRunningCommandMotion),
            "tiles": ["progress": .number(progress.rounded()), "settled": .bool(progress >= 100)],
        ]
    }

    static func json(_ camera: CameraPose) -> JSONValue {
        var heading = (camera.heading * 180 / .pi).truncatingRemainder(dividingBy: 360)
        if heading < 0 { heading += 360 }
        return [
            "latitude": .number(rounded(camera.latitude, 6)),
            "longitude": .number(rounded(camera.longitude, 6)),
            "heightMeters": .number(camera.height.rounded()),
            "headingDegrees": .number(rounded(heading, 1)),
            "pitchDegrees": .number(rounded(camera.pitch * 180 / .pi, 1)),
        ]
    }

    static func json(_ result: MapCommandResult, source: String) -> JSONValue {
        [
            "command": (try? JSONValue(encoding: result.command)) ?? .null,
            "summary": .string(result.command.summary),
            "ok": .bool(result.ok),
            "detail": .string(result.detail),
            "source": .string(source),
        ]
    }

    private static func rounded(_ value: Double, _ places: Int) -> Double {
        let scale = pow(10, Double(places))
        return (value * scale).rounded() / scale
    }

    private static func differs(_ a: CameraPose, _ b: CameraPose) -> Bool {
        abs(a.latitude - b.latitude) > 1e-7 || abs(a.longitude - b.longitude) > 1e-7
            || abs(a.height - b.height) > 0.05 || abs(a.heading - b.heading) > 1e-4 || abs(a.pitch - b.pitch) > 1e-4
    }
}
