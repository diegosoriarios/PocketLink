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

    func testNotificationActionFrameRoundTrip() throws {
        let frame = try NotificationAction.frame(id: "pkg_1_2", action: NotificationAction.dismiss, streamId: 4)
        XCTAssertEqual(frame.messageType, .notificationAction)
        XCTAssertEqual(frame.streamId, 4)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(frame.payload)) as? [String: Any])
        XCTAssertEqual(object["id"] as? String, "pkg_1_2")
        XCTAssertEqual(object["action"] as? String, "dismiss")
    }

    func testNotificationActionRejectsEmptyFields() {
        XCTAssertThrowsError(try NotificationAction.frame(id: "", action: "dismiss", streamId: 1))
        XCTAssertThrowsError(try NotificationAction.frame(id: "x", action: "", streamId: 1))
    }

    func testReplyAckParse() {
        let frame = Frame(
            messageType: .notificationReplyAck,
            streamId: 2,
            payload: [UInt8](#"{"id":"pkg_1_2","success":true}"#.utf8)
        )
        let ack = NotificationReplyAck.parse(frame)
        XCTAssertEqual(ack?.id, "pkg_1_2")
        XCTAssertEqual(ack?.success, true)

        let failure = NotificationReplyAck.parse(
            Frame(
                messageType: .notificationReplyAck,
                streamId: 2,
                payload: [UInt8](#"{"id":"pkg_1_2","success":false}"#.utf8)
            )
        )
        XCTAssertEqual(failure?.success, false)

        XCTAssertNil(NotificationReplyAck.parse(payload(#"{"id":"x"}"#)))
        XCTAssertNil(NotificationReplyAck.parse(Frame(messageType: .ping, streamId: 0, payload: [UInt8](#"{"id":"x","success":true}"#.utf8))))
    }
}

final class NotificationStoreTests: XCTestCase {
    private func tempDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("notification-store-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func notification(id: String, postTime: Date = Date()) -> LinkNotification {
        LinkNotification(
            id: id, packageName: "com.test", appName: "Test",
            title: "t", text: "b", postTime: postTime, hasQuickReply: false
        )
    }

    func testRecordDeduplicatesAndCapsSize() async throws {
        let store = NotificationStore(directory: try tempDirectory(), maxEntries: 3)
        await store.record(notification(id: "1"))
        await store.record(notification(id: "2"))
        await store.record(notification(id: "3"))
        await store.record(notification(id: "2"))
        await store.record(notification(id: "4"))

        let entries = await store.all()
        XCTAssertEqual(entries.map(\.id), ["4", "2", "3"], "Newest first, deduped, capped at maxEntries")
    }

    func testPersistsAcrossInstancesAndClears() async throws {
        let directory = try tempDirectory()
        let store = NotificationStore(directory: directory)
        await store.record(notification(id: "persist-1"))

        let reloaded = NotificationStore(directory: directory)
        let entries = await reloaded.all()
        XCTAssertEqual(entries.map(\.id), ["persist-1"])

        await reloaded.clear()
        let cleared = NotificationStore(directory: directory)
        let empty = await cleared.all()
        XCTAssertTrue(empty.isEmpty)
    }
}
