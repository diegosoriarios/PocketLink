import SwiftUI
import UserNotifications

@main
struct PocketLinkApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = ConnectionViewModel()
    private var statusItemController: StatusItemController?
    private var hotKeys: GlobalHotKeys?
    private let notificationPresenter = NotificationPresenter()

    func applicationDidFinishLaunching(_ notification: Notification) {
        UNUserNotificationCenter.current().delegate = notificationPresenter
        NSApp.servicesProvider = ServicesProvider(model: model)
        statusItemController = StatusItemController(model: model)
        model.startBrowsingIfNeeded()
        registerHotKeys()
    }

    private func registerHotKeys() {
        let hotKeys = GlobalHotKeys()
        hotKeys.install()
        hotKeys.register(GlobalHotKeys.togglePanel) { [weak self] in
            self?.statusItemController?.togglePanel()
        }
        hotKeys.register(GlobalHotKeys.toggleMirroring) { [weak self] in
            self?.model.toggleMirroring()
        }
        self.hotKeys = hotKeys
    }
}

/// Keeps low-battery banners visible even while the app is active (e.g.
/// the menu bar panel is focused).
final class NotificationPresenter: NSObject, UNUserNotificationCenterDelegate {
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }
}
