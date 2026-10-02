import Foundation

public struct PhoneBattery: Sendable, Equatable {
    public let level: Int
    public let isCharging: Bool
    public let powerSave: Bool

    public init(level: Int, isCharging: Bool, powerSave: Bool) {
        self.level = level
        self.isCharging = isCharging
        self.powerSave = powerSave
    }

    public var symbolName: String {
        let clamped = max(0, min(100, level))
        if isCharging {
            return "battery.100.bolt"
        }
        switch clamped {
        case 76...100: return "battery.100"
        case 51...75: return "battery.75"
        case 26...50: return "battery.50"
        case 1...25: return "battery.25"
        default: return "battery.0"
        }
    }

    public var summaryText: String {
        var text = "\(level)%"
        if isCharging {
            text += " · charging"
        }
        if powerSave {
            text += " · power save"
        }
        return text
    }
}

public enum BatteryMessage {
    public static func parse(_ frame: Frame) -> PhoneBattery? {
        guard frame.messageType == .battery,
              let data = try? JSONSerialization.jsonObject(with: Data(frame.payload)) as? [String: Any],
              let levelNumber = data["level"] as? NSNumber else {
            return nil
        }
        return PhoneBattery(
            level: levelNumber.intValue,
            isCharging: (data["isCharging"] as? NSNumber)?.boolValue ?? false,
            powerSave: (data["powerSave"] as? NSNumber)?.boolValue ?? false
        )
    }
}
