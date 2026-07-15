import SwiftUI
#if canImport(AppIntents)
import AppIntents
#endif

/// Tiny inbox that forwards an incoming `vkturnproxy://import?data=…`
/// URL from the App's `.onOpenURL` (which fires reliably on cold and
/// warm launches at the WindowGroup level) into the main connection screen.
/// The main screen imports, activates and connects in one flow; the Servers
/// tab remains available for manual profile management.
@MainActor
final class ConnectionLinkInbox: ObservableObject {
    static let shared = ConnectionLinkInbox()
    @Published var pendingURL: URL?
    @Published var pendingAction: String?
    private init() {}
}

@main
struct VKTurnProxyApp: App {
    init() {
        // Version comes from Bundle's CFBundleVersion = $(CURRENT_PROJECT_VERSION)
        // (per project.yml info.properties). Both main app and PacketTunnel
        // extension log their own build number on startup so post-mortem log
        // analysis can immediately tell whether the running binary matches
        // the source git state — earlier confusion (2026-05-10) was caused
        // by an extension running stale Go code from a not-rebuilt xcframework
        // while the source had moved on.
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        SharedLogger.shared.log("[App] Orbit launched (build \(build))")
    }

    var body: some Scene {
        WindowGroup {
            OrbitRootView()
                .onOpenURL { url in
                    let scheme = url.scheme?.lowercased()
                    if scheme == "vkturnproxy", url.host?.lowercased() == "action" {
                        ConnectionLinkInbox.shared.pendingAction = url.pathComponents.last?.lowercased()
                    } else if scheme == "vkturnproxy" || scheme == "wdtt" || scheme == "qwdtt" || scheme == "freeturn" {
                        ConnectionLinkInbox.shared.pendingURL = url
                    }
                }
        }
    }
}

#if canImport(AppIntents)
@available(iOS 16.0, *)
struct OrbitToggleIntent: AppIntent {
    static var title: LocalizedStringResource = "Переключить Orbit"
    static var description = IntentDescription("Подключает или отключает VPN Orbit.")
    static var openAppWhenRun = true

    func perform() async throws -> some IntentResult {
        await MainActor.run { ConnectionLinkInbox.shared.pendingAction = "toggle" }
        return .result()
    }
}

@available(iOS 16.0, *)
struct OrbitConnectIntent: AppIntent {
    static var title: LocalizedStringResource = "Подключить Orbit"
    static var openAppWhenRun = true

    func perform() async throws -> some IntentResult {
        await MainActor.run { ConnectionLinkInbox.shared.pendingAction = "connect" }
        return .result()
    }
}

@available(iOS 16.0, *)
struct OrbitShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: OrbitToggleIntent(), phrases: ["Переключить VPN в \(.applicationName)", "Включить или выключить \(.applicationName)"], shortTitle: "Переключить Orbit", systemImageName: "bolt.shield")
        AppShortcut(intent: OrbitConnectIntent(), phrases: ["Подключить VPN \(.applicationName)", "Запустить \(.applicationName)"], shortTitle: "Подключить Orbit", systemImageName: "lock.shield")
    }
}
#endif
