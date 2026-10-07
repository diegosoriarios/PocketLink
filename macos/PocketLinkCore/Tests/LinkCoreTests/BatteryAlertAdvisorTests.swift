import XCTest

@testable import LinkProtocol

final class BatteryAlertAdvisorTests: XCTestCase {
    func testFiresLowOncePerCrossing() {
        var advisor = BatteryAlertAdvisor()
        XCTAssertNil(advisor.alert(for: 80, isCharging: false))
        XCTAssertEqual(advisor.alert(for: 14, isCharging: false), .low)
        XCTAssertNil(advisor.alert(for: 12, isCharging: false))
        XCTAssertNil(advisor.alert(for: 10, isCharging: false))
    }

    func testEscalatesToCriticalThenStaysQuiet() {
        var advisor = BatteryAlertAdvisor()
        XCTAssertEqual(advisor.alert(for: 10, isCharging: false), .low)
        XCTAssertEqual(advisor.alert(for: 4, isCharging: false), .critical)
        XCTAssertNil(advisor.alert(for: 3, isCharging: false))
        XCTAssertNil(advisor.alert(for: 2, isCharging: false))
    }

    func testCriticalSkipsLowIfFirstReading() {
        var advisor = BatteryAlertAdvisor()
        XCTAssertEqual(advisor.alert(for: 2, isCharging: false), .critical)
        XCTAssertNil(advisor.alert(for: 1, isCharging: false))
    }

    func testNeverFiresWhileCharging() {
        var advisor = BatteryAlertAdvisor()
        for level in [100, 15, 4] {
            XCTAssertNil(advisor.alert(for: level, isCharging: true))
        }
    }

    func testReArmsAfterHysteresisBand() {
        var advisor = BatteryAlertAdvisor()
        XCTAssertEqual(advisor.alert(for: 9, isCharging: false), .low)
        // Charging back up: quiet while charging…
        XCTAssertNil(advisor.alert(for: 100, isCharging: true))
        // …the first discharging reading above 20% silently re-arms…
        XCTAssertNil(advisor.alert(for: 60, isCharging: false))
        // …and a later discharge re-alerts at the next crossing.
        XCTAssertEqual(advisor.alert(for: 14, isCharging: false), .low)
        XCTAssertNil(advisor.alert(for: 12, isCharging: false))
    }

    func testBandEdges() {
        var advisor = BatteryAlertAdvisor()
        XCTAssertNil(advisor.alert(for: 16, isCharging: false))
        XCTAssertEqual(advisor.alert(for: 15, isCharging: false), .low)
        XCTAssertEqual(advisor.alert(for: 5, isCharging: false), .critical)
        XCTAssertNil(advisor.alert(for: 21, isCharging: false))
        XCTAssertEqual(advisor.alert(for: 15, isCharging: false), .low)
    }
}
