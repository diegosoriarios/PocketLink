import XCTest

import LinkProtocol

@testable import LinkNotifications

final class LinkNotificationTests: XCTestCase {
    private func payload(_ json: String) -> Frame {
        Frame(messageType: .notification, streamId: 7, payload: [UInt8](json.utf8))
    }

    func testParseFullPayload() throws {
        let frame = payload(
            #"{"id":"pkg_123_456","packageName":"com.whatsapp","appName":"WhatsApp","title":"Alice","text":"Hello there","postTime":1690000000000,"hasQuickReply":true}"#
        )
        let notification = try XCTUnwrap(NotificationMessage.parse(frame))
        XCTAssertEqual(notification.id, "pkg_123_456")
        XCTAssertEqual(notification.packageName, "com.whatsapp")
        XCTAssertEqual(notification.appName, "WhatsApp")
        XCTAssertEqual(notification.title, "Alice")
        XCTAssertEqual(notification.text, "Hello there")
        XCTAssertEqual(notification.postTime.timeIntervalSince1970, 1_690_000_000, accuracy: 0.001)
        XCTAssertTrue(notification.hasQuickReply)
    }

    func testParseIgnoresWrongMessageType() {
        let frame = Frame(messageType: .ping, streamId: 0, payload: [UInt8](#"{"id":"x"}"#.utf8))
        XCTAssertNil(NotificationMessage.parse(frame))
    }

    func testParseReturnsNilWithoutId() {
        XCTAssertNil(NotificationMessage.parse(payload(#"{"title":"no id"}"#)))
    }

    func testParseToleratesMissingAndExtraFields() throws {
        let frame = payload(#"{"id":"only","unknown":"value","appName":"App"}"#)
        let notification = try XCTUnwrap(NotificationMessage.parse(frame))
        XCTAssertEqual(notification.id, "only")
        XCTAssertEqual(notification.appName, "App")
        XCTAssertEqual(notification.text, "")
        XCTAssertEqual(notification.title, "")
        XCTAssertFalse(notification.hasQuickReply)
        XCTAssertEqual(notification.postTime.timeIntervalSince1970, 0, accuracy: 0.001)
    }

    func testParseReturnsNilForNonJson() {
        XCTAssertNil(NotificationMessage.parse(payload("not json")))
    }

    func testSymbolMappingKnownPackages() {
        let whatsapp = LinkNotification(
            id: "1", packageName: "com.whatsapp", appName: "WhatsApp",
            title: "t", text: "", postTime: Date(), hasQuickReply: false
        )
        XCTAssertEqual(whatsapp.symbolName, "message.fill")
        let gmail = LinkNotification(
            id: "2", packageName: "com.google.android.gm", appName: "Gmail",
            title: "t", text: "", postTime: Date(), hasQuickReply: false
        )
        XCTAssertEqual(gmail.symbolName, "envelope.fill")
        let unknown = LinkNotification(
            id: "3", packageName: "com.unknown.app", appName: "Unknown",
            title: "t", text: "", postTime: Date(), hasQuickReply: false
        )
        XCTAssertEqual(unknown.symbolName, "bell.fill")
    }

    func testNotificationReplyFrameEncodesIdAndText() throws {
        let frame = try NotificationReply.frame(id: "pkg_1_2", text: "On my way", streamId: 9)
        XCTAssertEqual(frame.messageType, .notificationReply)
        XCTAssertEqual(frame.streamId, 9)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(frame.payload)) as? [String: Any])
        XCTAssertEqual(object["id"] as? String, "pkg_1_2")
        XCTAssertEqual(object["text"] as? String, "On my way")
    }

    func testNotificationReplyTrimsWhitespace() throws {
        let frame = try NotificationReply.frame(id: "pkg_1_2", text: "  ok  ", streamId: 1)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(frame.payload)) as? [String: Any])
        XCTAssertEqual(object["text"] as? String, "ok")
    }

    func testNotificationReplyRejectsEmptyText() {
        XCTAssertThrowsError(try NotificationReply.frame(id: "pkg_1_2", text: "   ", streamId: 1))
        XCTAssertThrowsError(try NotificationReply.frame(id: "", text: "hi", streamId: 1))
    }
}
