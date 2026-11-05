import SwiftUI

/// A map that can show a guest place: MapModel on visionOS, ScreenMap on a
/// screen. What the Guest menu drives.
@MainActor
protocol GuestHost: AnyObject {
    var guest: GuestPlace? { get }
    func showGuest(_ place: Place, mode: GuestMode, heading: Double, radius: Double?)
    func hideGuest()
    func setGuestMode(_ mode: GuestMode)
    func turnGuest(by angle: Double)
}

/// The Guest menu beside Places, while Settings › Two places is on: pick a
/// place to show beside or over the map, how, and turn it off.
struct GuestMenu<Host: GuestHost>: View {
    let host: Host

    var body: some View {
        Menu("Guest", systemImage: "square.on.square.dashed") {
            Section("Compare With") {
                ForEach(PlaceLibrary.all) { place in
                    Button {
                        host.showGuest(place, mode: host.guest?.mode ?? .sideBySide, heading: 0, radius: nil)
                    } label: {
                        if host.guest?.place.id == place.id {
                            Label(place.name, systemImage: "checkmark")
                        } else {
                            Text(place.name)
                        }
                    }
                }
            }
            if let guest = host.guest {
                Picker("Show", selection: Binding(get: { guest.mode }, set: { host.setGuestMode($0) })) {
                    ForEach(GuestMode.allCases) { mode in
                        Text(mode.name).tag(mode)
                    }
                }
                Button("Turn 45°", systemImage: "rotate.right") {
                    host.turnGuest(by: .pi / 4)
                }
                Button("Hide \(guest.place.name)", systemImage: "xmark") {
                    host.hideGuest()
                }
            }
        }
        .help("Show another place beside or over this one")
    }
}

/// Whether to offer the Guest menu: Settings › Two places, or
/// ALSOMAPS_GUEST_PLACE. Turning the setting off hides any guest.
struct GuestMenuSwitch<Host: GuestHost>: ViewModifier {
    let host: Host
    @AppStorage(ViewPreferences.guestPlacesKey) private var setting = false

    func body(content: Content) -> some View {
        content.onChange(of: setting) { _, on in
            if !on { host.hideGuest() }
        }
    }
}

extension View {
    func hidesGuestWhenSwitchedOff<Host: GuestHost>(_ host: Host) -> some View {
        modifier(GuestMenuSwitch(host: host))
    }
}
