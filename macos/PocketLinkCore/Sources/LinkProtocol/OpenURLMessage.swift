import Foundation

/// OPEN_URL (0x0065, Mac→phone): asks the phone to open a URL via an
/// implicit `ACTION_VIEW` intent. Payload: `{"url": "<str>"}`.
public enum OpenURLMessage {
    public static func frame(url: String, streamId: UInt32) -> Frame {
        Frame(messageType: .openURL, streamId: streamId, payloadString: payloadString(url: url))
    }

    public static func parse(_ frame: Frame) -> String? {
        guard frame.messageType == .openURL,
              let data = try? JSONSerialization.jsonObject(with: Data(frame.payload)) as? [String: Any],
              let url = data["url"] as? String,
              !url.isEmpty else {
            return nil
        }
        return url
    }

    private static func payloadString(url: String) -> String {
        let object: [String: Any] = ["url": url]
        guard let data = try? JSONSerialization.data(withJSONObject: object),
              let string = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return string
    }
}
