import Foundation
import UsageButlerDomain

public enum ProviderRetryTiming {
    public static func date(for gate: RefreshGateState, reading: ClockReading) -> Date? {
        let deadline: MonotonicInstant
        switch gate {
        case let .backoff(until, _), let .cooldown(until): deadline = until
        default: return nil
        }
        let remaining = deadline > reading.monotonicTime ? deadline.nanoseconds - reading.monotonicTime.nanoseconds : 0
        return reading.wallTime.addingTimeInterval(Double(remaining) / 1_000_000_000)
    }
}
