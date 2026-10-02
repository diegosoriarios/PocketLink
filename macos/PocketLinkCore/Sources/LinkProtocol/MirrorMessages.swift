import Foundation

/// Wire messages for screen mirroring (B3).
///
/// MIRROR_FRAME binary payload layout (all integers big-endian, matching the
/// frame header convention):
/// ```
/// offset 0:  u64 timestampMs
/// offset 8:  u8  keyframe (0/1)
/// offset 9:  u32 accessUnitLength
/// offset 13: Annex-B access unit bytes
/// ```
public enum MirrorMessages {
    // MARK: - Control (start/stop)

    public static func startFrame(streamId: UInt32) -> Frame {
        Frame(messageType: .mirrorStart, streamId: streamId, payload: [UInt8]("{}".utf8))
    }

    public static func stopFrame(streamId: UInt32) -> Frame {
        Frame(messageType: .mirrorStop, streamId: streamId, payload: [UInt8]("{}".utf8))
    }

    // MARK: - Config (phone → Mac)

    public struct Config: Sendable, Equatable {
        public let width: Int
        public let height: Int
        public let fps: Int
        public let bitrateBps: Int
        /// CSD blobs in Annex-B form (start-code delimited NAL units).
        /// `sps` may contain SPS+PPS concatenated (MediaCodec csd-0);
        /// `pps` may be empty when the device packs everything into csd-0.
        public let sps: Data
        public let pps: Data

        public init(width: Int, height: Int, fps: Int, bitrateBps: Int, sps: Data, pps: Data) {
            self.width = width
            self.height = height
            self.fps = fps
            self.bitrateBps = bitrateBps
            self.sps = sps
            self.pps = pps
        }
    }

    public static func configFrame(_ config: Config, streamId: UInt32) throws -> Frame {
        let object: [String: Any] = [
            "width": config.width,
            "height": config.height,
            "fps": config.fps,
            "bitrateBps": config.bitrateBps,
            "sps": config.sps.base64EncodedString(),
            "pps": config.pps.base64EncodedString()
        ]
        let data = try JSONSerialization.data(withJSONObject: object)
        return Frame(messageType: .mirrorConfig, streamId: streamId, payload: [UInt8](data))
    }

    public static func parseConfig(_ frame: Frame) -> Config? {
        guard frame.messageType == .mirrorConfig,
              let object = try? JSONSerialization.jsonObject(with: Data(frame.payload)) as? [String: Any],
              let width = object["width"] as? Int,
              let height = object["height"] as? Int,
              width > 0, height > 0 else {
            return nil
        }
        let fps = object["fps"] as? Int ?? 30
        let bitrate = object["bitrateBps"] as? Int ?? 4_000_000
        let sps = (object["sps"] as? String).flatMap { Data(base64Encoded: $0) } ?? Data()
        let pps = (object["pps"] as? String).flatMap { Data(base64Encoded: $0) } ?? Data()
        return Config(width: width, height: height, fps: fps, bitrateBps: bitrate, sps: sps, pps: pps)
    }

    // MARK: - Video frame (phone → Mac)

    public struct EncodedFrame: Sendable, Equatable {
        public let timestampMs: Int64
        public let keyframe: Bool
        public let accessUnit: Data

        public init(timestampMs: Int64, keyframe: Bool, accessUnit: Data) {
            self.timestampMs = timestampMs
            self.keyframe = keyframe
            self.accessUnit = accessUnit
        }
    }

    public static func frameFrame(_ encoded: EncodedFrame, streamId: UInt32) throws -> Frame {
        var payload = Data()
        payload.reserveCapacity(13 + encoded.accessUnit.count)
        var timestamp = encoded.timestampMs.bigEndian
        withUnsafeBytes(of: &timestamp) { payload.append(contentsOf: $0) }
        payload.append(encoded.keyframe ? 1 : 0)
        var length = UInt32(encoded.accessUnit.count).bigEndian
        withUnsafeBytes(of: &length) { payload.append(contentsOf: $0) }
        payload.append(encoded.accessUnit)
        return Frame(messageType: .mirrorFrame, streamId: streamId, payload: [UInt8](payload))
    }

    public static func parseFrame(_ frame: Frame) -> EncodedFrame? {
        guard frame.messageType == .mirrorFrame, frame.payload.count >= 13 else { return nil }
        let payload = frame.payload
        let timestamp: Int64 = payload[0..<8].reduce(0) { ($0 << 8) | Int64($1) }
        let keyframe = payload[8] == 1
        let length: UInt32 = payload[9..<13].reduce(0) { ($0 << 8) | UInt32($1) }
        let accessUnitLength = Int(length)
        guard accessUnitLength >= 0, 13 + accessUnitLength <= payload.count else { return nil }
        let accessUnit = Data(payload[13..<(13 + accessUnitLength)])
        return EncodedFrame(timestampMs: timestamp, keyframe: keyframe, accessUnit: accessUnit)
    }

    // MARK: - Touch (Mac → phone)

    public enum TouchAction: String, Sendable, CaseIterable {
        case down
        case move
        case up
    }

    public struct TouchPoint: Sendable, Equatable {
        public let action: TouchAction
        /// Normalized 0...1 coordinates relative to the captured display.
        public let x: Double
        public let y: Double

        public init(action: TouchAction, x: Double, y: Double) {
            self.action = action
            self.x = x
            self.y = y
        }
    }

    public static func touchFrame(_ point: TouchPoint, streamId: UInt32) throws -> Frame {
        let object: [String: Any] = [
            "action": point.action.rawValue,
            "x": point.x,
            "y": point.y
        ]
        let data = try JSONSerialization.data(withJSONObject: object)
        return Frame(messageType: .remoteTouch, streamId: streamId, payload: [UInt8](data))
    }

    public static func parseTouch(_ frame: Frame) -> TouchPoint? {
        guard frame.messageType == .remoteTouch,
              let object = try? JSONSerialization.jsonObject(with: Data(frame.payload)) as? [String: Any],
              let rawAction = object["action"] as? String,
              let action = TouchAction(rawValue: rawAction),
              let xNumber = object["x"] as? NSNumber,
              let yNumber = object["y"] as? NSNumber else {
            return nil
        }
        return TouchPoint(action: action, x: xNumber.doubleValue, y: yNumber.doubleValue)
    }
}
