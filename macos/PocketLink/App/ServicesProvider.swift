import AppKit

/// Receives files sent from Finder via the Services menu (the NSServices
/// entry in Info.plist) and queues them for the phone through the shared
/// multi-file drop queue.
@MainActor
final class ServicesProvider {
    private let model: ConnectionViewModel

    init(model: ConnectionViewModel) {
        self.model = model
    }

    @objc func sendFilesToPhone(
        _ pboard: NSPasteboard,
        userData: String,
        error: AutoreleasingUnsafeMutablePointer<NSString?>
    ) {
        let urls = Self.fileURLs(from: pboard)
        guard !urls.isEmpty else {
            error.pointee = "No files provided" as NSString
            return
        }
        model.sendDroppedFiles(urls)
    }

    private static func fileURLs(from pboard: NSPasteboard) -> [URL] {
        if let urls = pboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL], !urls.isEmpty {
            return urls
        }
        // Legacy Finder pasteboard type (plain paths).
        if let paths = pboard.propertyList(
            forType: NSPasteboard.PasteboardType("NSFilenamesPboardType")
        ) as? [String] {
            return paths.map(URL.init(fileURLWithPath:))
        }
        return []
    }
}
