import SwiftUI

extension View {
    /// Keeps the remote config fresh while this scene is active, and applies
    /// it: a blocking notice replaces this view, tearing down the map and its
    /// streaming, and other notices show as alerts. Scenes that share a window
    /// with another's alerts, or can't show them, pass `presentsNotices: false`.
    func appGate(presentsNotices: Bool = true) -> some View {
        modifier(AppGate(presentsNotices: presentsNotices))
    }
}

private struct AppGate: ViewModifier {
    /// How often to check while running: often enough to matter on a device
    /// that stays open for hours, and sooner when blocked, so lifting a block
    /// reaches a waiting app.
    private static let refreshInterval = Duration.seconds(15 * 60)
    private static let blockedRefreshInterval = Duration.seconds(60)

    let presentsNotices: Bool

    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openURL) private var openURL
    #if os(visionOS)
    @Environment(\.dismissImmersiveSpace) private var dismissImmersiveSpace
    #endif

    private var store: AppConfigStore { .shared }

    private var showsNotice: Binding<Bool> {
        Binding(get: { presentsNotices && store.blocking == nil && store.notice != nil },
                set: { if !$0, let notice = store.notice { store.dismiss(notice) } })
    }

    func body(content: Content) -> some View {
        Group {
            if let notice = store.blocking {
                BlockingNoticeView(notice: notice)
            } else {
                content
            }
        }
        .alert(store.notice?.title ?? "", isPresented: showsNotice, presenting: store.notice) { notice in
            if let link = notice.link {
                Button(link.title) { openURL(link.url) }
            }
            Button("OK", role: .cancel) {}
        } message: { notice in
            Text(notice.body)
        }
        .task(id: scenePhase == .active) {
            guard scenePhase == .active else { return }
            while !Task.isCancelled {
                await store.refresh()
                let interval = store.blocking == nil ? Self.refreshInterval : Self.blockedRefreshInterval
                try? await Task.sleep(for: interval)
            }
        }
        #if os(visionOS)
        .task(id: store.blocking != nil) {
            // The volume can show a block; the immersive space has to go.
            if store.blocking != nil { await dismissImmersiveSpace() }
        }
        #endif
    }
}

private struct BlockingNoticeView: View {
    let notice: Notice

    @Environment(\.openURL) private var openURL

    var body: some View {
        ContentUnavailableView {
            Label(notice.title, systemImage: "exclamationmark.triangle")
        } description: {
            Text(notice.body)
        } actions: {
            if let link = notice.link {
                Button(link.title) { openURL(link.url) }
                    .buttonStyle(.borderedProminent)
            }
            Button("Try Again") {
                Task { await AppConfigStore.shared.refresh(force: true) }
            }
            .disabled(AppConfigStore.shared.isRefreshing)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
