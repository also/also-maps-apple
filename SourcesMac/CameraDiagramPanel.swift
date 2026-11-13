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

    struct Values: Equatable {
        var camera: CameraPose
        var terrain: Double
        /// The placement ground a room host puts on its base plane.
        var ground: Double
    }

    @State private var host: Host
    /// Nil follows the map.
    @State private var manual: Values?
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
                CameraDiagramReadouts(diagram: diagram).font(.callout)
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
        case .volume: .room(Self.room(.volume))
        case .immersive: .room(Self.room(.immersive))
        }
        return CameraDiagram.Inputs(camera: values.camera, presentation: presentation,
                                    terrainHeight: values.terrain, groundHeight: values.ground,
                                    containerSize: host == .volume ? MapPresentation.volumeSize : nil,
                                    areaPolicy: (host == .immersive ? MapPresentation.immersive : .volume)
                                        .areaPolicy(map.settings))
    }

    /// The map's camera, with the placement ground settled on its ground.
    private var live: Values {
        let ground = map.groundHeight
        return Values(camera: map.navigation.camera, terrain: ground, ground: ground)
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
                if host == .window {
                    LabeledContent("Pitch") {
                        Slider(value: value(\.camera.pitch, scale: 180 / .pi), in: -90...0)
                    }
                }
                TextField("Terrain (m)", value: value(\.terrain), format: .number.precision(.fractionLength(0...1)))
                if host != .window {
                    TextField("Placement ground (m)", value: value(\.ground),
                              format: .number.precision(.fractionLength(0...1)))
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
        Text("Moving here doesn't move the map. Descend and Climb fly the diagram's camera as a held controller would, with the placement ground unchanged, as while moving.")
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

    /// A view state's camera and placement ground, in its own host unless
    /// `host` is given. A view state doesn't record the terrain; the
    /// placement ground is the best guess, to edit if you know better.
    private static func values(from state: MapViewState, host: Host?) -> (Host, Values?) {
        let own: Host = MapPresentation.withID(state.host)?.host == .immersive ? .immersive : .volume
        let ground = state.groundEstimate.ray
        return (host ?? own, Values(camera: state.navigationState.camera, terrain: ground, ground: ground))
    }

    /// Climbs (+1) or descends (−1) the diagram's camera as a held
    /// controller would: model flight's climb (MapModel's steer). Stops at
    /// the host's lowest altitude, 1,000 km up, or after 20 seconds.
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
                let camera = flight.step(NavigationState(camera: values.camera), input: ControlInput(climb: climb),
                                         deltaTime: deltaTime, context: context).camera
                let altitude = camera.height - values.terrain
                values.camera = camera
                manual = values
                if climb < 0 ? altitude <= minimumAltitude + 0.5 : altitude >= 1_000_000 { break }
            }
            animation = nil
        }
    }
}
