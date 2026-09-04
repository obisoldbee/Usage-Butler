import Foundation
import UsageButlerDomain

public struct ClockReading: Equatable, Sendable {
    public let wallTime: Date
    public let monotonicTime: MonotonicInstant

    public init(wallTime: Date, monotonicTime: MonotonicInstant) {
        self.wallTime = wallTime
        self.monotonicTime = monotonicTime
    }
}

public protocol ClockPort: Sendable {
    func reading() async -> ClockReading
    func sleep(until deadline: MonotonicInstant) async throws
}
