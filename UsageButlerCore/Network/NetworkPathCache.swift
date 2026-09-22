import Foundation
import UsageButlerDomain

/// The wall clock labels observations only. Both throttle and expiry use the
/// injected monotonic clock; a backwards/future monotonic stamp is invalid.
public struct NetworkPathCache: Equatable, Sendable {
    public static let reuseNanoseconds: UInt64 = 5_000_000_000
    public static let freshnessNanoseconds: UInt64 = 15_000_000_000
    public private(set) var lastAttempt: ClockReading?
    public private(set) var lastConfirmation: ClockReading?
    public private(set) var retainedPath: NetworkSystemPath = .unreadable

    public init() {}

    private func age(from earlier: ClockReading?, at now: ClockReading) -> UInt64? {
        guard let earlier, now.monotonicTime >= earlier.monotonicTime else { return nil }
        return now.monotonicTime.nanoseconds - earlier.monotonicTime.nanoseconds
    }
    public func shouldRead(at now: ClockReading) -> Bool {
        guard let age = age(from: lastAttempt, at: now) else { return true }
        return age >= Self.reuseNanoseconds
    }
    public func isFresh(at now: ClockReading) -> Bool {
        guard let age = age(from: lastConfirmation, at: now) else { return false }
        return age < Self.freshnessNanoseconds
    }
    public func path(at now: ClockReading) -> NetworkSystemPath {
        isFresh(at: now) ? retainedPath : .unreadable
    }
    public mutating func record(_ path: NetworkSystemPath, at now: ClockReading) {
        lastAttempt = now
        if path.isReadable { retainedPath = path; lastConfirmation = now }
    }
    /// Called on both sleep and wake; uptime may stop during sleep.
    public mutating func invalidate() { lastAttempt = nil; lastConfirmation = nil }
}
