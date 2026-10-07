import AppKit
import SwiftUI

/// Embeds the session's touch-forwarding video view (hosting the decoder's
/// display layer) inside SwiftUI. The underlying view is owned by the view
/// model, so the live video survives the menu bar panel being closed and is
/// simply re-parented when it reopens.
struct MirrorVideoView: NSViewRepresentable {
    let videoView: NSView

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        container.wantsLayer = true
        container.layer?.masksToBounds = true
        install(into: container)
        return container
    }

    func updateNSView(_ container: NSView, context: Context) {
        install(into: container)
    }

    private func install(into container: NSView) {
        guard videoView !== container.subviews.first else { return }
        container.subviews.forEach { $0.removeFromSuperview() }
        videoView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(videoView)
        NSLayoutConstraint.activate([
            videoView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            videoView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            videoView.topAnchor.constraint(equalTo: container.topAnchor),
            videoView.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])
    }
}
