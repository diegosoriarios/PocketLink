import Foundation
import Network

public struct DiscoveredDevice: Sendable, Equatable, Identifiable {
    public let name: String
    public let endpoint: NWEndpoint
    public private(set) var hostText: String

    public var id: String { name }

    public init(name: String, endpoint: NWEndpoint, hostText: String = "") {
        self.name = name
        self.endpoint = endpoint
        self.hostText = hostText
    }

    public mutating func resolveHost(_ text: String) {
        hostText = text
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
    private let resolver = EndpointResolver()
    private var resolutionTasks: [String: Task<Void, Never>] = [:]
    private var resolutionAttempted: Set<String> = []

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
        resolutionAttempted = []
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
        for task in resolutionTasks.values {
            task.cancel()
        }
        resolutionTasks.removeAll()
        resolutionAttempted.removeAll()
        currentDevices = []
        devicesContinuation.yield([])
        devicesContinuation.finish()
        statesContinuation.finish()
    }

    private func handleResults(_ results: Set<NWBrowser.Result>) {
        var found: [DiscoveredDevice] = []
        for result in results {
            guard case .service(let name, _, _, _) = result.endpoint else { continue }
            let existing = currentDevices.first { $0.name == name }
            found.append(existing ?? DiscoveredDevice(name: name, endpoint: result.endpoint))
        }
        let sorted = found.sorted { $0.name < $1.name }
        guard sorted != currentDevices else { return }
        currentDevices = sorted
        devicesContinuation.yield(sorted)
        for device in sorted where device.hostText.isEmpty {
            scheduleResolution(for: device)
        }
    }

    private func scheduleResolution(for device: DiscoveredDevice) {
        guard !resolutionAttempted.contains(device.name),
              resolutionTasks[device.name] == nil,
              case .service(let name, let type, let domain, let interface) = device.endpoint else { return }
        resolutionAttempted.insert(device.name)
        let resolver = self.resolver
        let interfaceIndex = UInt32(bitPattern: Int32(interface?.index ?? 0))
        resolutionTasks[device.name] = Task { [weak self] in
            let resolved = await resolver.resolve(
                name: name,
                type: type,
                domain: domain,
                interfaceIndex: interfaceIndex
            )
            await self?.applyResolution(device: device, resolved: resolved)
        }
    }

    private func applyResolution(device: DiscoveredDevice, resolved: ResolvedEndpoint?) {
        resolutionTasks[device.name] = nil
        guard let resolved,
              let index = currentDevices.firstIndex(where: { $0.name == device.name }),
              currentDevices[index].hostText.isEmpty else { return }
        currentDevices[index].resolveHost("\(resolved.ip):\(resolved.port)")
        devicesContinuation.yield(currentDevices)
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
