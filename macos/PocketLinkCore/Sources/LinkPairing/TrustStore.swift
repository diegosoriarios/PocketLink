import Foundation

public struct TrustedPeer: Sendable, Equatable, Codable {
    public let id: String
    public let name: String
    public let addedAt: Date

    public init(id: String, name: String, addedAt: Date) {
        self.id = id
        self.name = name
        self.addedAt = addedAt
    }
}

public actor TrustStore {
    private let fileURL: URL
    private var peers: [String: TrustedPeer] = [:]

    public init(directory: URL) {
        fileURL = directory.appendingPathComponent("trusted-peers.json")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        peers = TrustStore.load(from: fileURL)
    }

    public func isTrusted(_ id: String) -> Bool {
        peers[id] != nil
    }

    public func trust(_ id: String, name: String) throws {
        if let existing = peers[id], existing.name == name { return }
        peers[id] = TrustedPeer(id: id, name: name, addedAt: Date())
        try persist()
    }

    public func revoke(_ id: String) throws {
        guard peers.removeValue(forKey: id) != nil else { return }
        try persist()
    }

    public func trustedPeers() -> [TrustedPeer] {
        peers.values.sorted { $0.name < $1.name }
    }

    private func persist() throws {
        let data = try JSONEncoder().encode(peers)
        try data.write(to: fileURL, options: .atomic)
    }

    private static func load(from url: URL) -> [String: TrustedPeer] {
        guard let data = try? Data(contentsOf: url) else { return [:] }
        return (try? JSONDecoder().decode([String: TrustedPeer].self, from: data)) ?? [:]
    }
}
