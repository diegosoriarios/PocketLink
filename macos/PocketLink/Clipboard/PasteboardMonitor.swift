import AppKit

@MainActor
final class PasteboardMonitor {
    var onCopy: ((String) -> Void)?

    private var timer: Timer?
    private var lastChangeCount = NSPasteboard.general.changeCount
    private var lastSentText: String?
    private var lastReceivedText: String?

    func start() {
        guard timer == nil else { return }
        lastChangeCount = NSPasteboard.general.changeCount
        timer = Timer.scheduledTimer(withTimeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.poll()
            }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func poll() {
        let pasteboard = NSPasteboard.general
        guard pasteboard.changeCount != lastChangeCount else { return }
        lastChangeCount = pasteboard.changeCount
        guard let text = pasteboard.string(forType: .string), !text.isEmpty else { return }
        guard text != lastSentText, text != lastReceivedText else { return }
        lastSentText = text
        onCopy?(text)
    }

    func markSent(_ text: String) {
        lastSentText = text
        lastChangeCount = NSPasteboard.general.changeCount
    }

    func markReceived(_ text: String) {
        lastReceivedText = text
        lastChangeCount = NSPasteboard.general.changeCount
    }

    private static let pollInterval: TimeInterval = 0.5
}

struct AppSettings: Codable {
    var sendClipboardOnCopy = false

    static func load(directory: URL) -> AppSettings {
        let url = directory.appendingPathComponent("settings.json")
        guard let data = try? Data(contentsOf: url),
              let settings = try? JSONDecoder().decode(AppSettings.self, from: data) else {
            return AppSettings()
        }
        return settings
    }

    func save(directory: URL) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        try? data.write(to: directory.appendingPathComponent("settings.json"), options: .atomic)
    }
}
