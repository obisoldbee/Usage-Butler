import Foundation

/// A helper-only cooldown. All time is injected uptime; wall-clock changes do
/// not trigger retries. Collector generations bind every delayed decision.
public struct BackgroundSourceRecovery: Sendable {
    public struct Source: Sendable {
        public let generation: UInt64
        public let enabled: Bool
        public let suspended: Bool
        public let exhausted: Bool
        public let healthy: Bool
        public let issue: String?
        public init(generation: UInt64, enabled: Bool, suspended: Bool, exhausted: Bool, healthy: Bool, issue: String?) {
            self.generation = generation; self.enabled = enabled; self.suspended = suspended
            self.exhausted = exhausted; self.healthy = healthy; self.issue = issue
        }
    }
    public private(set) var deadline: UInt64?
    private var generation: UInt64?
    private var attempt = 0
    private static let transient: Set<String> = ["source-ended", "source-eof", "source-exited", "source-timeout", "read-failed"]
    public init() {}
    public mutating func cancel() { deadline = nil; generation = nil; attempt = 0 }
    public mutating func observe(_ source: Source, now: UInt64, permitted: Bool) -> UInt64? {
        guard permitted, source.enabled, !source.suspended else { cancel(); return nil }
        if source.healthy { cancel(); return nil }
        guard source.exhausted, let issue = source.issue, Self.transient.contains(issue) else {
            deadline = nil; generation = nil; return nil
        }
        if generation != source.generation {
            generation = source.generation
            let minutes = [5, 10, 20, 30][min(attempt, 3)]
            deadline = now.addingReportingOverflow(UInt64(minutes) * 60_000_000_000).partialValue
        }
        guard let deadline, now >= deadline else { return nil }
        self.deadline = nil; generation = nil; attempt = min(attempt + 1, 3)
        return source.generation
    }
    public func secondsRemaining(at now: UInt64) -> Int? {
        deadline.map { $0 > now ? Int(($0 - now + 999_999_999) / 1_000_000_000) : 0 }
    }
}
