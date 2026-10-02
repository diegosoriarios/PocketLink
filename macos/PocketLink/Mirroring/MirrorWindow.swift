import AVFoundation
import AppKit
import LinkProtocol

/// Layer-backed view that installs the decoder's display layer, keeps it
/// aspect-fitted, and forwards mouse events as normalized video-space points.
final class TouchForwardingView: NSView {
    var onGesture: ((MirrorMessages.TouchAction, CGPoint) -> Void)?

    private var videoAspect: CGFloat = 9.0 / 19.5
    private var isTracking = false

    func install(_ videoLayer: AVSampleBufferDisplayLayer) {
        wantsLayer = true
        layer = CALayer()
        videoLayer.videoGravity = .resizeAspect
        videoLayer.frame = bounds
        videoLayer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        layer?.addSublayer(videoLayer)
    }

    func updateVideoAspect(width: Int, height: Int) {
        guard width > 0, height > 0 else { return }
        videoAspect = CGFloat(width) / CGFloat(height)
    }

    override func layout() {
        super.layout()
        guard let videoLayer = layer?.sublayers?.first as? AVSampleBufferDisplayLayer else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        videoLayer.frame = bounds
        CATransaction.commit()
    }

    /// Maps a point in view coordinates to normalized video coordinates
    /// (0…1 within the aspect-fit video rect), or nil if outside the video.
    func normalizedVideoPoint(at location: CGPoint) -> CGPoint? {
        let viewAspect = bounds.width / max(bounds.height, 1)
        var rect = bounds
        if viewAspect > videoAspect {
            let width = bounds.height * videoAspect
            rect = CGRect(x: (bounds.width - width) / 2, y: 0, width: width, height: bounds.height)
        } else {
            let height = bounds.width / videoAspect
            rect = CGRect(x: 0, y: (bounds.height - height) / 2, width: bounds.width, height: height)
        }
        guard rect.contains(location) else { return nil }
        let x = (location.x - rect.minX) / rect.width
        // Video Y axis runs top-down; AppKit view Y runs bottom-up.
        let y = 1.0 - (location.y - rect.minY) / rect.height
        return CGPoint(x: min(max(x, 0), 1), y: min(max(y, 0), 1))
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let videoPoint = normalizedVideoPoint(at: point) else { return }
        isTracking = true
        onGesture?(.down, videoPoint)
    }

    override func mouseDragged(with event: NSEvent) {
        guard isTracking else { return }
        let point = convert(event.locationInWindow, from: nil)
        guard let videoPoint = normalizedVideoPoint(at: point) else { return }
        onGesture?(.move, videoPoint)
    }

    override func mouseUp(with event: NSEvent) {
        guard isTracking else { return }
        isTracking = false
        let point = convert(event.locationInWindow, from: nil)
        guard let videoPoint = normalizedVideoPoint(at: point) else { return }
        onGesture?(.up, videoPoint)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Window controller hosting the mirrored video surface.
final class MirrorWindowController: NSWindowController, NSWindowDelegate {
    var onWindowClosed: (() -> Void)?

    init(videoView: NSView, dimensions: CGSize) {
        let aspect = dimensions.height > 0 ? dimensions.width / dimensions.height : 9.0 / 19.5
        let height: CGFloat = 640
        let width = min(420, height * aspect)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: width, height: height),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "PocketLink — Screen Mirroring"
        window.isReleasedWhenClosed = false
        window.contentView = videoView
        window.center()

        super.init(window: window)
        window.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func showAndActivate() {
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        onWindowClosed?()
    }
}
