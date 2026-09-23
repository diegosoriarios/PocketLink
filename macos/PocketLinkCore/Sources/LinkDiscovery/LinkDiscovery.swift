import Foundation
import Network

public struct DiscoveredDevice: Sendable, Equatable, Identifiable {
    public let name: String
    public let endpoint: NWEndpoint

    public var id: String { name }

    public init(name: String, endpoint: NWEndpoint) {
        self.name = name
        self.endpoint = endpoint
    }
}

public enum DiscoveryState: Sendable, Equatable {
    case idle
    case browsing
    case failed(reason: String)
}

public actor LinkBrowser {
    nonisolated public let devices: AsyncStream<[DiscoveredDevice]>

    nonisolated public let states: AsyncStream<DiscoveryState>
    private let devicesContinuation: AsyncStream<[DiscoveredDevice]>.Continuation
    private let statesContinuation: AsyncStream<DiscoveryState>.Continuation

    private var browser: NWBrowser?
    private var currentDevices: [DiscoveredDevice] = []

    public init() {
        (devices, devicesContinuation) = AsyncStream.makeStream(of: [DiscoveredDevice].self)
        (states, statesContinuation) = AsyncStream.makeStream(of: DiscoveryState.self)
    }

    public func start() {
        guard browser == nil else { return }
        let parameters = NWParameters()
        parameters.includePeerToPeer = true
        let newBrowser = NWBrowser(for: .bonjour(type: "_link._tcp.", domain: "local."), using: parameters)
        browser = newBrowser
        currentDevices = []
        devicesContinuation.yield([])
        statesContinuation.yield(.browsing)

        newBrowser.browseResultsChangedHandler = { [weak self] results, _ in
            Task { await self?.handleResults(results) }
        }
        newBrowser.stateUpdateHandler = { [weak self] state in
            Task { await self?.handleStateChange(state) }
        }
        newBrowser.start(queue: .global(qos: .userInitiated))
    }

    public func stop() {
        guard let oldBrowser = browser else { return }
        browser = nil
        oldBrowser.stateUpdateHandler = nil
        oldBrowser.browseResultsChangedHandler = nil
        oldBrowser.cancel()
        currentDevices = []
        devicesContinuation.yield([])
        devicesContinuation.finish()
        statesContinuation.finish()
    }

    private func handleResults(_ results: Set<NWBrowser.Result>) {
        var found: [DiscoveredDevice] = []
        for result in results {
            guard case .service(let name, _, _, _) = result.endpoint else { continue }
            found.append(DiscoveredDevice(name: name, endpoint: result.endpoint))
        }
        let sorted = found.sorted { $0.name < $1.name }
        guard sorted != currentDevices else { return }
        currentDevices = sorted
        devicesContinuation.yield(sorted)
    }

    private func handleStateChange(_ state: NWBrowser.State) {
        switch state {
        case .ready:
            statesContinuation.yield(.browsing)
        case .failed(let error):
            statesContinuation.yield(.failed(reason: "Discovery failed (error \(error.errorCode))"))
            stop()
        default:
            break
        }
    }
}
