import XCTest
import Network

@testable import LinkDiscovery

final class ServiceAdvertiser: @unchecked Sendable {
    private let queue = DispatchQueue(label: "test.link.advertiser")
    private let listener: NWListener

    init(name: String) throws {
        listener = try NWListener(using: .tcp, on: .any)
        listener.service = NWListener.Service(name: name, type: "_link._tcp.")
        listener.newConnectionHandler = { _ in }
        listener.start(queue: queue)
    }

    var port: UInt16 {
        listener.port?.rawValue ?? 0
    }

    func stop() {
        queue.sync { listener.cancel() }
    }
}

final class LinkBrowserIntegrationTests: XCTestCase {
    func testBrowserDiscoversAdvertisedService() async throws {
        let uniqueName = "TestAndroid-\(ProcessInfo.processInfo.processIdentifier)"
        let advertiser = try ServiceAdvertiser(name: uniqueName)
        defer { advertiser.stop() }

        let browser = LinkBrowser()
        let found = expectation(description: "service discovered")

        let devicesTask = Task {
            for await devices in browser.devices {
                if devices.contains(where: { $0.name == uniqueName }) {
                    found.fulfill()
                    break
                }
            }
        }
        defer { devicesTask.cancel() }

        await browser.start()
        await fulfillment(of: [found], timeout: 20)
        await browser.stop()
    }

    func testStopFinishesStreams() async throws {
        let browser = LinkBrowser()
        await browser.start()
        await browser.stop()

        var seenStates: [DiscoveryState] = []
        for await state in browser.states {
            seenStates.append(state)
        }
        var deviceBatches = 0
        for await _ in browser.devices {
            deviceBatches += 1
        }

        XCTAssertEqual(seenStates.first, .browsing)
        XCTAssertEqual(deviceBatches, 2)
    }

    func testDiscoveredDeviceExposesServiceEndpoint() {
        let endpoint = NWEndpoint.service(name: "Pixel", type: "_link._tcp.", domain: "local.", interface: nil)
        let device = DiscoveredDevice(name: "Pixel", endpoint: endpoint)
        XCTAssertEqual(device.id, "Pixel")
        XCTAssertEqual(device.endpoint, endpoint)
        XCTAssertEqual(device.hostText, "")
    }
}

final class EndpointResolverIntegrationTests: XCTestCase {
    func testResolvesAdvertisedServiceToIPAndPort() async throws {
        let uniqueName = "TestResolve-\(ProcessInfo.processInfo.processIdentifier)"
        let advertiser = try ServiceAdvertiser(name: uniqueName)
        defer { advertiser.stop() }

        let resolver = EndpointResolver()
        var resolved: ResolvedEndpoint?
        for _ in 0..<10 {
            resolved = await resolver.resolve(name: uniqueName, type: "_link._tcp.", domain: "local.", timeout: 2)
            if resolved != nil { break }
        }

        let endpoint = try XCTUnwrap(resolved, "service was not resolved to an address")
        XCTAssertFalse(endpoint.ip.isEmpty)
        XCTAssertEqual(endpoint.ip.split(separator: ".").count, 4)
        let advertisedPort = advertiser.port
        if advertisedPort != 0 {
            XCTAssertEqual(endpoint.port, advertisedPort)
        }
    }

    func testResolveReturnsNilAfterTimeout() async throws {
        let resolver = EndpointResolver()
        let resolved = await resolver.resolve(
            name: "no-such-service-\(UUID().uuidString)",
            type: "_link._tcp.",
            domain: "local.",
            timeout: 0.5
        )
        XCTAssertNil(resolved)
    }
}

final class LocalIPAddressTests: XCTestCase {
    func testPrimaryIPv4IsUsableWhenPresent() {
        guard let address = LocalIPAddress.primaryIPv4() else {
            return
        }
        XCTAssertFalse(address.hasPrefix("127."), "must not return loopback")
        XCTAssertFalse(address.hasPrefix("169.254."), "must not return link-local")

        let parts = address.split(separator: ".")
        XCTAssertEqual(parts.count, 4, "expected a dotted quad, got \(address)")
        XCTAssertTrue(
            parts.allSatisfy { part in Int(part).map { (0...255).contains($0) } == true },
            "expected a dotted quad, got \(address)"
        )
    }
}
