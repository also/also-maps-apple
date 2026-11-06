import AppKit
import SwiftUI

/// The camera explainer beside the Mac map: side views of how the camera is
/// shown in each host, from the map's camera or from values you set (a
/// pasted visionOS view state, say), with a descent or climb to watch.
struct CameraDiagramPanel: View {
    let map: ScreenMap

    enum Host: String, CaseIterable, Identifiable {
        case window = "Window", volume = "Volume", immersive = "Immersive"
        var id: Self { self }
    }

    /// What the volume's estimates do while the animation moves the camera.
    enum Estimates: String, CaseIterable, Identifiable {
        /// Unchanged, as during a gesture.
        case frozen = "Frozen (gesture)"
        /// Following the Earth's curve while the shown region is over 50 km
        /// across, then unchanged until motion settles, as with a controller.
        case curve = "Curve, then frozen (controller)"
        var id: Self { self }
    }

    struct Values: Equatable {
        var camera: CameraPose
        var terrain: Double
        var ray: Double
        var envelope: Double
    }

    @State private var host: Host
    /// Nil follows the map.
    @State private var manual: Values?
    @State private var estimates: Estimates = .curve
    @State private var animation: Task<Void, Never>?
    @State private var pasteError: String?

    /// At launch, ALSOMAPS_DIAGRAM can name the host (window, volume or
    /// immersive) and ALSOMAPS_STATE a view state to start from.
    init(map: ScreenMap) {
        self.map = map
        let env = ProcessInfo.processInfo.environment
        var host = Host.allCases.first { $0.rawValue.lowercased() == env["ALSOMAPS_DIAGRAM"]?.lowercased() } ?? .volume
        var manual: Values?
        if let text = env["ALSOMAPS_STATE"], let state = try? MapViewState.parse(text) {
            (host, manual) = Self.values(from: state, host: env["ALSOMAPS_DIAGRAM"] == nil ? nil : host)
        }
        _host = State(initialValue: host)
        _manual = State(initialValue: manual)
    }

    var body: some View {
        let diagram = CameraDiagram(inputs(manual ?? live))
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Picker("Host", selection: $host) {
                    ForEach(Host.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                panel("World, along the camera's heading") {
                    CameraDiagramWorldView(diagram: diagram).frame(height: 260)
                }
                if diagram.room != nil {
                    panel(host == .volume ? "The volume, from the side" : "The immersive space, from the side") {
                        CameraDiagramRoomView(diagram: diagram).frame(height: 220)
                    }
                } else {
                    Text("In the window the render camera is the camera, so nothing is placed in a room.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                CameraDiagramLegend(diagram: diagram)
                readouts(diagram)
                Divider()
                controls
            }
            .padding()
        }
    }

    // MARK: Inputs

    private static func room(_ presentation: MapPresentation) -> RoomGeometry {
        guard case let .room(room) = presentation.geometry else { preconditionFailure("not a room host") }
        return room
    }

    private func inputs(_ values: Values) -> CameraDiagram.Inputs {
        let presentation: CameraDiagram.Presentation = switch host {
        case .window: .window(fieldOfView: ScreenMap.fieldOfView)
        case .volume: .adaptive(Self.room(.volume))
        case .immersive: .eyeLevel(Self.room(.immersive))
        }
        let settings = map.settings
        return CameraDiagram.Inputs(camera: values.camera, presentation: presentation,
                                    terrainHeight: values.terrain, rayHeight: values.ray,
                                    envelopeHeight: values.envelope,
                                    containerSize: host == .volume ? MapPresentation.volumeSize : nil,
                                    areaPolicy: host == .immersive
                                        ? .horizon(limitPerAltitude: settings.limitsImmersiveReach
                                                   ? settings.immersiveReach : nil)
                                        : .georeference(regionMultiplier: 1))
    }

    /// The map's camera and ground, with the estimates the host would
    /// settle on over that ground. The volume also eases pitch to its own
    /// target for the altitude (MapModel's pitch assist), so the window's
    /// shallow pitch would tilt its map.
    private var live: Values {
        var camera = map.navigation.camera
        let ground = map.groundHeight
        guard host == .volume else { return Values(camera: camera, terrain: ground, ray: ground, envelope: ground) }
        let room = Self.room(.volume)
        camera.pitch = AdaptiveModel.assistedPitch(for: camera, room: room, rayHeight: ground, cameraGround: ground)
        let settled = CameraDiagram.settledEstimates(camera: camera, room: room, terrainHeight: ground)
        return Values(camera: camera, terrain: ground, ray: settled.ray, envelope: settled.envelope)
    }

    // MARK: Views

    private func panel(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.headline)
            content()
                .background(.background.secondary, in: RoundedRectangle(cornerRadius: 6))
                .clipShape(RoundedRectangle(cornerRadius: 6))
        }
    }

    private func readouts(_ d: CameraDiagram) -> some View {
        let camera = d.inputs.camera
        let degrees = 180 / Double.pi
        return Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
            row("Camera", String(format: "%.4f°, %.4f°", camera.latitude, camera.longitude))
            row("Height (ellipsoid)", Self.distance(camera.height))
            row("Heading, pitch", String(format: "%.1f°, %.1f°", camera.heading * degrees, camera.pitch * degrees))
            row("Terrain height", Self.distance(d.inputs.terrainHeight))
            if host == .volume { row("Ray surface height", Self.distance(d.inputs.rayHeight)) }
            if host != .window { row("Envelope height", Self.distance(d.inputs.envelopeHeight)) }
            Divider().gridCellUnsizedAxes(.horizontal)
            row("Camera above terrain", Self.distance(d.cameraAltitude))
            row("Eye above terrain", Self.distance(d.viewerAltitude), color: d.viewerAltitude < 0 ? .red : nil)
            if host == .volume { row("Lift (ray − envelope)", Self.distance(d.lift)) }
            if let scale = d.scale { row("Scale", "1 : \((1 / scale).formatted(.number.precision(.significantDigits(3))))") }
            if let rho = d.shownRadius {
                row(host == .immersive ? "Content square half-width" : "Shown half-width", Self.distance(rho))
            }
            row("Streamed half-width", Self.distance(d.streamingRadius))
            if let range = d.rangeToGeoreference, let ground = d.groundDistanceToGeoreference {
                row("G: range, along ground", "\(Self.distance(range)), \(Self.distance(ground))")
            } else {
                row("G", "none: the view ray misses")
            }
            row("Horizon, along ground", Self.distance(d.horizonDistance))
            if let fieldOfView = d.viewer.fieldOfView {
                row("LOD field of view", String(format: "%.0f°", fieldOfView * degrees))
            }
            if d.usesNadirFallback { row("Framing", "looks straight down (the volume's fallback)") }
        }
        .font(.callout)
    }

    private func row(_ name: String, _ value: String, color: Color? = nil) -> some View {
        GridRow {
            Text(name).foregroundStyle(.secondary)
            Text(value).monospacedDigit().foregroundStyle(color ?? .primary)
        }
    }

    @ViewBuilder private var controls: some View {
        Toggle("Follow the map", isOn: Binding(
            get: { manual == nil },
            set: { follows in
                animation?.cancel()
                manual = follows ? nil : live
            }))
        HStack {
            Button("Paste View State") { pasteViewState() }
            if let pasteError {
                Text(pasteError).font(.caption).foregroundStyle(.red).lineLimit(2)
            }
        }
        if manual != nil {
            Form {
                LabeledContent("Above terrain") {
                    Slider(value: altitude, in: log10(2)...log10(11_000_000))
                }
                LabeledContent("Pitch") {
                    Slider(value: value(\.camera.pitch, scale: 180 / .pi), in: -90...0)
                }
                TextField("Terrain (m)", value: value(\.terrain), format: .number.precision(.fractionLength(0...1)))
                if host != .window {
                    TextField("Ray surface (m)", value: value(\.ray), format: .number.precision(.fractionLength(0...1)))
                    TextField("Envelope (m)", value: value(\.envelope), format: .number.precision(.fractionLength(0...1)))
                }
                if host == .volume {
                    Picker("While moving", selection: $estimates) {
                        ForEach(Estimates.allCases) { Text($0.rawValue).tag($0) }
                    }
                }
            }
            .formStyle(.columns)
        }
        HStack {
            Button("Descend") { fly(climb: -1) }
            Button("Climb") { fly(climb: 1) }
            if animation != nil {
                Button("Stop") { animation?.cancel(); animation = nil }
            }
        }
        Text("Moving here doesn't move the map. Descend and Climb fly the diagram's camera as a held controller would, with the volume's pitch assist and its estimates as chosen above.")
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    // MARK: Editing

    private func value(_ keyPath: WritableKeyPath<Values, Double>, scale: Double = 1) -> Binding<Double> {
        Binding(
            get: { (manual?[keyPath: keyPath] ?? 0) * scale },
            set: { manual?[keyPath: keyPath] = $0 / scale })
    }

    /// log₁₀ of the camera's height above the terrain.
    private var altitude: Binding<Double> {
        Binding(
            get: { manual.map { log10(max($0.camera.height - $0.terrain, 1)) } ?? 0 },
            set: { manual?.camera.height = (manual?.terrain ?? 0) + pow(10, $0) })
    }

    private func pasteViewState() {
        guard let text = NSPasteboard.general.string(forType: .string) else {
            pasteError = "The clipboard has no text."
            return
        }
        do {
            let state = try MapViewState.parse(text)
            animation?.cancel()
            pasteError = nil
            (host, manual) = Self.values(from: state, host: nil)
        } catch {
            pasteError = error.localizedDescription
        }
    }

    /// A view state's camera and estimates, in its own host unless `host`
    /// is given. A view state doesn't record the terrain; the ray surface
    /// is the best guess, to edit if you know better.
    private static func values(from state: MapViewState, host: Host?) -> (Host, Values?) {
        let own: Host = MapPresentation.withID(state.host)?.host == .immersive ? .immersive : .volume
        return (host ?? own, Values(camera: state.navigationState.camera, terrain: state.groundEstimate.ray,
                                    ray: state.groundEstimate.ray, envelope: state.groundEstimate.envelope))
    }

    /// Climbs (+1) or descends (−1) the diagram's camera as a held
    /// controller would: model flight's climb, then in the volume the pitch
    /// assist and horizon limit (MapModel's steer). Stops at the host's
    /// lowest altitude, 1,000 km up, or after 20 seconds.
    private func fly(climb: Double) {
        animation?.cancel()
        if manual == nil { manual = live }
        let minimumAltitude = host == .window ? 2.0 : 55.0
        let maximumAltitude = 11_000_000.0  // MapModel's and ScreenMap's
        animation = Task { @MainActor in
            let flight = ModelFlightStyle()
            let deltaTime = 1.0 / 60
            for _ in 0..<(20 * 60) {
                try? await Task.sleep(for: .milliseconds(16))
                guard !Task.isCancelled, var values = manual else { return }
                let context = NavigationContext(cameraGround: values.terrain, minimumAltitude: minimumAltitude,
                                                maximumAltitude: maximumAltitude)
                var camera = flight.step(NavigationState(camera: values.camera), input: ControlInput(climb: climb),
                                         deltaTime: deltaTime, context: context).camera
                if host == .volume {
                    let room = Self.room(.volume)
                    camera = AdaptiveModel.easedPitch(camera, room: room, rayHeight: values.ray,
                                                      envelopeHeight: min(values.envelope, values.ray),
                                                      context: context, deltaTime: deltaTime)
                    camera.pitch = min(camera.pitch, AdaptiveModel.pitchLimit(cameraHeight: camera.height,
                                                                              rayHeight: values.ray,
                                                                              latitude: camera.latitude))
                }
                let altitude = camera.height - values.terrain
                values.camera = camera
                if host == .volume, estimates == .curve,
                   let shown = CameraDiagram(inputs(values)).shownRadius,
                   shown >= CameraDiagram.curvatureAnchorRadius {
                    values.envelope = values.ray - GroundEstimates.curvatureDrop(shown)
                }
                manual = values
                if climb < 0 ? altitude <= minimumAltitude + 0.5 : altitude >= 1_000_000 { break }
            }
            animation = nil
        }
    }

    private static func distance(_ metres: Double) -> String {
        abs(metres) < 1_000
            ? "\(metres.formatted(.number.precision(.fractionLength(0)))) m"
            : "\((metres / 1_000).formatted(.number.precision(.fractionLength(1)))) km"
    }
}
