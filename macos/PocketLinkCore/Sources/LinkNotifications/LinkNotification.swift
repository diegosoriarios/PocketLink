import Foundation

import LinkProtocol

public struct LinkNotification: Sendable, Equatable, Identifiable {
    public let id: String
    public let packageName: String
    public let appName: String
    public let title: String
    public let text: String
    public let postTime: Date
    public let hasQuickReply: Bool

    public init(
        id: String,
        packageName: String,
        appName: String,
        title: String,
        text: String,
        postTime: Date,
        hasQuickReply: Bool
    ) {
        self.id = id
        self.packageName = packageName
        self.appName = appName
        self.title = title
        self.text = text
        self.postTime = postTime
        self.hasQuickReply = hasQuickReply
    }

    public var symbolName: String {
        switch packageName {
        case "com.google.android.apps.messaging", "com.google.android.talk", "com.whatsapp",
             "com.telegram.messenger", "org.telegram.messenger", "com.android.messaging",
             "com.samsung.android.messaging":
            return "message.fill"
        case "com.google.android.gm", "com.microsoft.office.outlook":
            return "envelope.fill"
        case "com.instagram.android", "com.facebook.katana", "com.facebook.orca":
            return "camera.fill"
        case "com.spotify.music", "com.google.android.apps.youtube.music":
            return "music.note"
        case "com.google.android.youtube":
            return "play.rectangle.fill"
        case "com.Slack":
            return "bubble.left.fill"
        case "com.google.android.dialer", "com.samsung.android.dialer", "com.android.phone",
             "com.android.server.telecom":
            return "phone.fill"
        case "com.android.chrome", "org.mozilla.firefox":
            return "globe"
        case "com.google.android.calendar", "com.android.calendar":
            return "calendar"
        default:
            return "bell.fill"
        }
    }
}

public enum NotificationMessage {
    public static func parse(_ frame: Frame) -> LinkNotification? {
        guard frame.messageType == .notification,
              let object = try? JSONSerialization.jsonObject(with: Data(frame.payload)) as? [String: Any],
              let id = object["id"] as? String, !id.isEmpty else {
            return nil
        }
        let postTimeMilliseconds = (object["postTime"] as? NSNumber)?.doubleValue ?? 0
        return LinkNotification(
            id: id,
            packageName: object["packageName"] as? String ?? "",
            appName: object["appName"] as? String ?? "",
            title: object["title"] as? String ?? "",
            text: object["text"] as? String ?? "",
            postTime: Date(timeIntervalSince1970: postTimeMilliseconds / 1000),
            hasQuickReply: (object["hasQuickReply"] as? NSNumber)?.boolValue ?? false
        )
    }
}

public enum NotificationReplyError: Error {
    case invalidReply
}

public enum NotificationReply {
    public static func frame(id: String, text: String, streamId: UInt32) throws -> Frame {
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty, !trimmedText.isEmpty else {
            throw NotificationReplyError.invalidReply
        }
        let payload: [String: String] = ["id": id, "text": trimmedText]
        let data = try JSONSerialization.data(withJSONObject: payload)
        return Frame(messageType: .notificationReply, streamId: streamId, payload: [UInt8](data))
    }
}
