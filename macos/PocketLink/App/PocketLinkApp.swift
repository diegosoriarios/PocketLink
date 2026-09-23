import SwiftUI

@main
struct PocketLinkApp: App {
    var body: some Scene {
        MenuBarExtra("PocketLink", systemImage: "link.circle") {
            ConnectionStatusView()
        }
        .menuBarExtraStyle(.window)
    }
}
