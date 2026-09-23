import XCTest

@testable import LinkProtocol

final class LinkCoreTests: XCTestCase {
    func testProtocolConstantsMatchAndroidImplementation() {
        XCTAssertEqual(LinkProtocolConstants.magicASCII, "LINK")
        XCTAssertEqual(LinkProtocolConstants.headerSize, 16)
        XCTAssertEqual(LinkProtocolConstants.protocolVersion, 1)
        XCTAssertEqual(LinkProtocolConstants.maxPayloadSize, 8_388_608)
    }
}
