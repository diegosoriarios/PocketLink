import Foundation

/// Severity bands for phone battery alerts.
public enum BatteryAlertLevel: Equatable, Sendable {
    case none
    case low
    case critical
}

/// Pure decision logic for phone low-battery alerts: fires once per
/// threshold crossing (≤5% critical, ≤15% low) while discharging, and
/// re-arms above 20% hysteresis so a charge/discharge cycle can alert again.
public struct BatteryAlertAdvisor: Sendable, Equatable {
    public private(set) var lastAlert: BatteryAlertLevel

    public init() {
        self.lastAlert = .none
    }

    /// Returns the alert to post for this reading, or nil to stay quiet,
    /// advancing the internal crossing state.
    public mutating func alert(for level: Int, isCharging: Bool) -> BatteryAlertLevel? {
        guard !isCharging else { return nil }
        if level <= 5 {
            guard lastAlert != .critical else { return nil }
            lastAlert = .critical
            return .critical
        }
        if level <= 15 {
            guard lastAlert == .none else { return nil }
            lastAlert = .low
            return .low
        }
        if level > 20, lastAlert != .none {
            lastAlert = .none
        }
        return nil
    }
}
