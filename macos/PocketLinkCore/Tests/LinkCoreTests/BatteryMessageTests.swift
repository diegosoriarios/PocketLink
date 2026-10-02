import XCTest

@testable import LinkProtocol

final class BatteryMessageTests: XCTestCase {
    private func frame(_ json: String) -> Frame {
        Frame(messageType: .battery, streamId: 1, payload: [UInt8](json.utf8))
    }

    func testParseFullPayload() throws {
        let battery = try XCTUnwrap(
            BatteryMessage.parse(frame(#"{"level":85,"isCharging":true,"powerSave":false,"timestamp":1690000000000}"#))
        )
        XCTAssertEqual(battery.level, 85)
        XCTAssertTrue(battery.isCharging)
        XCTAssertFalse(battery.powerSave)
    }

    func testParseDefaultsMissingFlags() throws {
        let battery = try XCTUnwrap(BatteryMessage.parse(frame(#"{"level":40}"#)))
        XCTAssertEqual(battery.level, 40)
        XCTAssertFalse(battery.isCharging)
        XCTAssertFalse(battery.powerSave)
    }

    func testParseRejectsWrongTypeMissingLevelAndGarbage() {
        XCTAssertNil(BatteryMessage.parse(frame(#"{"isCharging":true}"#)))
        XCTAssertNil(BatteryMessage.parse(Frame(messageType: .ping, streamId: 0, payload: [UInt8](#"{"level":50}"#.utf8))))
        XCTAssertNil(BatteryMessage.parse(frame("garbage")))
    }

    func testSymbolNameTracksLevelAndCharging() {
        XCTAssertEqual(PhoneBattery(level: 100, isCharging: false, powerSave: false).symbolName, "battery.100")
        XCTAssertEqual(PhoneBattery(level: 60, isCharging: false, powerSave: false).symbolName, "battery.75")
        XCTAssertEqual(PhoneBattery(level: 40, isCharging: false, powerSave: false).symbolName, "battery.50")
        XCTAssertEqual(PhoneBattery(level: 10, isCharging: false, powerSave: false).symbolName, "battery.25")
        XCTAssertEqual(PhoneBattery(level: 0, isCharging: false, powerSave: false).symbolName, "battery.0")
        XCTAssertEqual(PhoneBattery(level: 30, isCharging: true, powerSave: false).symbolName, "battery.100.bolt")
    }

    func testSummaryTextIncludesStateFlags() {
        XCTAssertEqual(
            PhoneBattery(level: 85, isCharging: true, powerSave: true).summaryText,
            "85% · charging · power save"
        )
        XCTAssertEqual(PhoneBattery(level: 42, isCharging: false, powerSave: false).summaryText, "42%")
    }
}
