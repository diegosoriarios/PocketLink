import Foundation

import LinkProtocol

public enum ClipboardMessage {
    public static func frame(text: String, streamId: UInt32, timestamp: Date = Date()) throws -> Frame {
        let object: [String: Any] = [
            "text": text,
            "timestamp": Int64((timestamp.timeIntervalSince1970 * 1000).rounded())
        ]
        let data = try JSONSerialization.data(withJSONObject: object)
        return Frame(messageType: .clipboard, streamId: streamId, payload: [UInt8](data))
    }

    public static func parse(_ frame: Frame) -> String? {
        guard frame.messageType == .clipboard,
              let object = try? JSONSerialization.jsonObject(with: Data(frame.payload)) as? [String: Any],
              let text = object["text"] as? String, !text.isEmpty else {
            return nil
        }
        return text
    }
}
