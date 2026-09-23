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
    }
}
