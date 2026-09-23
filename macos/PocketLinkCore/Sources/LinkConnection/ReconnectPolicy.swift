import Foundation

public struct ReconnectPolicy: Sendable, Equatable {
    public let delays: [Duration]

    public init(delays: [Duration] = [.seconds(1), .seconds(2), .seconds(5), .seconds(10)]) {
        self.delays = delays
    }

    public func delay(forAttempt attempt: Int) -> Duration? {
        guard attempt >= 0, attempt < delays.count else { return nil }
        return delays[attempt]
    }
}
