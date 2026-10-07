import AppKit
import SwiftUI

/// Owns the status bar item, its popover panel, and the file-drop overlay
/// that lets users drag files directly onto the menu bar icon.
@MainActor
final class StatusItemController: NSObject {
    private let model: ConnectionViewModel
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let popover = NSPopover()
    private var lastPopoverClose: Date?
    private var unreadDot: StatusItemBadgeDot?
    private var currentDropHover = false
    private var currentProgress: Double?

    init(model: ConnectionViewModel) {
        self.model = model
        super.init()

        guard let button = statusItem.button else { return }
        button.image = Self.iconImage(dropHover: false)

        let overlay = StatusItemDropOverlay()
        overlay.canAccept = { [weak self] in self?.model.isConnected ?? false }
        overlay.hoverChanged = { [weak self] hovering in
            self?.setDropHover(hovering)
        }
        overlay.droppedFiles = { [weak self] urls in
            self?.handleDrop(urls)
        }
        button.addSubview(overlay)
        overlay.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            overlay.leadingAnchor.constraint(equalTo: button.leadingAnchor),
            overlay.trailingAnchor.constraint(equalTo: button.trailingAnchor),
            overlay.topAnchor.constraint(equalTo: button.topAnchor),
            overlay.bottomAnchor.constraint(equalTo: button.bottomAnchor)
        ])

        let dot = StatusItemBadgeDot()
        dot.translatesAutoresizingMaskIntoConstraints = false
        button.addSubview(dot)
        NSLayoutConstraint.activate([
            dot.trailingAnchor.constraint(equalTo: button.trailingAnchor, constant: -1),
            dot.topAnchor.constraint(equalTo: button.topAnchor, constant: 1),
            dot.widthAnchor.constraint(equalToConstant: 7),
            dot.heightAnchor.constraint(equalToConstant: 7)
        ])
        unreadDot = dot
        unreadDot?.isHidden = !model.hasUnreadNotifications
        model.onUnreadNotificationsChanged = { [weak self] hasUnread in
            self?.unreadDot?.isHidden = !hasUnread
        }
        model.onTransferProgressChanged = { [weak self] progress in
            self?.setTransferProgress(progress)
        }
        let hostingController = NSHostingController(rootView: ConnectionStatusView(model: model))
        hostingController.sizingOptions = .preferredContentSize
        popover.contentViewController = hostingController
        popover.behavior = .transient
        popover.delegate = self

        button.target = self
        button.action = #selector(statusItemClicked)
    }

    private static func iconImage(dropHover: Bool) -> NSImage? {
        let image = NSImage(
            systemSymbolName: dropHover ? "arrow.down.circle.fill" : "link.circle",
            accessibilityDescription: dropHover ? "Drop to send to phone" : "PocketLink"
        )
        image?.isTemplate = true
        return image
    }

    /// Circular progress ring shown while transfers are active. Rendered as
    /// a template image so the menu bar tints it for light/dark/highlighted
    /// states; the track is drawn at partial alpha for contrast.
    private static func progressImage(fraction: Double) -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let clamped = min(max(fraction, 0), 1)
        let image = NSImage(size: size, flipped: false) { rect in
            let center = NSPoint(x: rect.midX, y: rect.midY)
            let radius = rect.width / 2 - 1.5
            let lineWidth: CGFloat = 2

            let track = NSBezierPath()
            track.appendArc(withCenter: center, radius: radius, startAngle: 90, endAngle: 90 - 360, clockwise: true)
            track.lineWidth = lineWidth
            NSColor.black.withAlphaComponent(0.3).setStroke()
            track.stroke()

            let progress = NSBezierPath()
            progress.lineWidth = lineWidth
            progress.lineCapStyle = .round
            if clamped >= 0.999 {
                progress.appendArc(withCenter: center, radius: radius, startAngle: 90, endAngle: 90 - 360, clockwise: true)
            } else {
                progress.appendArc(withCenter: center, radius: radius, startAngle: 90, endAngle: 90 - 360 * clamped, clockwise: true)
            }
            NSColor.black.setStroke()
            progress.stroke()
            return true
        }
        image.isTemplate = true
        return image
    }

    private func setDropHover(_ hovering: Bool) {
        currentDropHover = hovering
        refreshIcon()
    }

    private func setTransferProgress(_ progress: Double?) {
        if let progress {
            if let current = currentProgress, abs(current - progress) < 0.005 { return }
        } else {
            guard currentProgress != nil else { return }
        }
        currentProgress = progress
        refreshIcon()
    }

    /// Single place that decides what the icon shows; drop hover wins, then
    /// the transfer ring, then the plain link icon.
    private func refreshIcon() {
        guard let button = statusItem.button else { return }
        if currentDropHover {
            button.contentTintColor = .controlAccentColor
            button.image = Self.iconImage(dropHover: true)
        } else if let progress = currentProgress {
            button.contentTintColor = nil
            button.image = Self.progressImage(fraction: progress)
        } else {
            button.contentTintColor = nil
            button.image = Self.iconImage(dropHover: false)
        }
    }

    private func handleDrop(_ urls: [URL]) {
        setDropHover(false)
        model.sendDroppedFiles(urls)
        lastPopoverClose = nil
        showPopover()
    }

    private func showPopover() {
        guard let button = statusItem.button else { return }
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
    }

    @objc private func statusItemClicked() {
        togglePanel()
    }

    /// Toggles the panel — shared by the status item click and the ⌥⌘M hot key.
    func togglePanel() {
        if popover.isShown {
            popover.performClose(nil)
            return
        }
        // A transient popover closes itself when the status item is clicked;
        // ignore the synthetic toggle that follows so it doesn't reopen.
        if let last = lastPopoverClose, Date().timeIntervalSince(last) < 0.2 { return }
        showPopover()
    }
}

extension StatusItemController: NSPopoverDelegate {
    func popoverWillShow(_ notification: Notification) {
        model.markNotificationsSeen()
    }

    func popoverDidClose(_ notification: Notification) {
        lastPopoverClose = Date()
        // Anything that arrived while the panel was open counts as seen.
        model.markNotificationsSeen()
    }
}

/// Small red dot at the top-trailing corner of the status item while there
/// are unseen notifications. Transparent to clicks and drags (the drop
/// overlay underneath keeps handling those).
final class StatusItemBadgeDot: NSView {
    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        wantsLayer = true
        layer?.backgroundColor = NSColor.systemRed.cgColor
    }

    override func layout() {
        super.layout()
        layer?.cornerRadius = bounds.width / 2
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// Invisible overlay on the status item button that accepts file drags.
/// hitTest returns nil for normal clicks so the button keeps working, and
/// self only while a drag session is in progress.
final class StatusItemDropOverlay: NSView {
    var canAccept: () -> Bool = { false }
    var hoverChanged: (Bool) -> Void = { _ in }
    var droppedFiles: ([URL]) -> Void = { _ in }

    private static let dragPasteboard = NSPasteboard(
        name: NSPasteboard.Name("Apple CFPasteboard drag")
    )

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([.fileURL])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let types = Self.dragPasteboard.types, !types.isEmpty else { return nil }
        return self
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        hoverChanged(true)
        return canAccept() ? .copy : []
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        canAccept() ? .copy : []
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        hoverChanged(false)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        defer { hoverChanged(false) }
        guard canAccept(),
              let urls = sender.draggingPasteboard.readObjects(
                forClasses: [NSURL.self],
                options: [.urlReadingFileURLsOnly: true]
              ) as? [URL],
              !urls.isEmpty else { return false }
        droppedFiles(urls)
        return true
    }

    // Safety net: if a stale drag pasteboard ever makes hitTest capture a
    // click, forward it to the status item button underneath.
    override func mouseDown(with event: NSEvent) {
        superview?.mouseDown(with: event)
    }

    override func rightMouseDown(with event: NSEvent) {
        superview?.rightMouseDown(with: event)
    }
}
