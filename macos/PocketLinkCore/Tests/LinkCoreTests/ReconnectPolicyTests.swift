import XCTest

@testable import LinkConnection

final class ReconnectPolicyTests: XCTestCase {
    func testDefaultDelaysBackOffAndExpire() {
        let policy = ReconnectPolicy()
        XCTAssertEqual(policy.delay(forAttempt: 0), .seconds(1))
        XCTAssertEqual(policy.delay(forAttempt: 1), .seconds(2))
        XCTAssertEqual(policy.delay(forAttempt: 2), .seconds(5))
        XCTAssertEqual(policy.delay(forAttempt: 3), .seconds(10))
        XCTAssertNil(policy.delay(forAttempt: 4))
    }

    func testNegativeAttemptReturnsNil() {
        XCTAssertNil(ReconnectPolicy().delay(forAttempt: -1))
    }

    func testCustomDelays() {
        let policy = ReconnectPolicy(delays: [.milliseconds(250), .milliseconds(250)])
        XCTAssertEqual(policy.delay(forAttempt: 0), .milliseconds(250))
        XCTAssertEqual(policy.delay(forAttempt: 1), .milliseconds(250))
        XCTAssertNil(policy.delay(forAttempt: 2))
    }

    func testZeroAttemptPolicyNeverReconnects() {
        let policy = ReconnectPolicy(delays: [])
        XCTAssertNil(policy.delay(forAttempt: 0))
    }
}
