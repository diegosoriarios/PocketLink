import Foundation

public struct TransferHistoryEntry: Sendable, Equatable, Codable, Identifiable {
    public enum Direction: String, Sendable, Codable {
        case send
        case receive
    }

    public enum State: Sendable, Equatable, Codable {
        case delivered
        case completed
        case mismatch
        case cancelled
        case failed(String)
    }

    public let id: String
    public let direction: Direction
    public let fileName: String
    public let totalBytes: Int64
    public let state: State
    public let date: Date

    public init(
        id: String,
        direction: Direction,
        fileName: String,
        totalBytes: Int64,
        state: State,
        date: Date = Date()
    ) {
        self.id = id
        self.direction = direction
        self.fileName = fileName
        self.totalBytes = totalBytes
        self.state = state
        self.date = date
    }
}

public actor TransferHistoryStore {
    private let fileURL: URL
    private var entries: [TransferHistoryEntry] = []
    private let maxEntries: Int

    public init(directory: URL, maxEntries: Int = 50) {
        fileURL = directory.appendingPathComponent("transfer-history.json")
        self.maxEntries = maxEntries
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        entries = Self.load(from: fileURL)
    }

    public func record(_ entry: TransferHistoryEntry) {
        entries.removeAll { $0.id == entry.id }
        entries.insert(entry, at: 0)
        if entries.count > maxEntries {
            entries.removeLast(entries.count - maxEntries)
        }
        persist()
    }

    public func all() -> [TransferHistoryEntry] {
        entries
    }

    public func clear() {
        entries = []
        try? FileManager.default.removeItem(at: fileURL)
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    private static func load(from url: URL) -> [TransferHistoryEntry] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([TransferHistoryEntry].self, from: data)) ?? []
    }
}
