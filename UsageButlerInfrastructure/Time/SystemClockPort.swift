import Dispatch
import Foundation
import UsageButlerCore
import UsageButlerDomain

/// Production wall/monotonic clock for Provider scheduling.
/// Wall time is display/persistence metadata only; deadlines use system uptime.
public struct SystemClockPort: ClockPort, Sendable {
    private let wallNow: @Sendable () -> Date
    private let monotonicNow: @Sendable () -> UInt64
    private let sleepNanoseconds: @Sendable (UInt64) async throws -> Void

    public init() {
        wallNow = { Date() }
        monotonicNow = { DispatchTime.now().uptimeNanoseconds }
        sleepNanoseconds = { nanoseconds in
            try await Task<Never, Never>.sleep(nanoseconds: nanoseconds)
        }
    }

    init(
        wallNow: @escaping @Sendable () -> Date,
        monotonicNow: @escaping @Sendable () -> UInt64,
        sleepNanoseconds: @escaping @Sendable (UInt64) async throws -> Void
    ) {
        self.wallNow = wallNow
        self.monotonicNow = monotonicNow
        self.sleepNanoseconds = sleepNanoseconds
    }

    public func reading() async -> ClockReading {
        ClockReading(
            wallTime: wallNow(),
            monotonicTime: MonotonicInstant(nanoseconds: monotonicNow())
        )
    }

    public func sleep(until deadline: MonotonicInstant) async throws {
        let current = monotonicNow()
        guard deadline.nanoseconds > current else { return }
        try await sleepNanoseconds(deadline.nanoseconds - current)
    }
}
