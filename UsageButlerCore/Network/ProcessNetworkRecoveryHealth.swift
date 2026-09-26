import Foundation
import UsageButlerDomain

/// Source-time evidence only. Rejected/replayed/partial frames cannot advance
/// health, and a gap starts a new window rather than counting the missing time.
struct ProcessNetworkRecoveryHealth {
    private var first: UInt64?
    private var previous: (sequence: UInt64, time: UInt64, cadence: TimeInterval)?
    mutating func reset() { first = nil; previous = nil }
    mutating func observe(_ frame: ProcessNetworkFrame, accepted: Bool, session: CaptureSessionID) -> Bool {
        let cadence = frame.samplingInterval
        guard accepted, frame.complete, frame.issue == nil,
              frame.envelope.sessionID == session, cadence.isFinite, cadence > 0 else {
            reset(); return false
        }
        let now = frame.envelope.monotonicOccurredAt.nanoseconds
        defer { previous = (frame.envelope.sequence, now, cadence) }
        guard let previous else { first = now; return false }
        let before = previous.time
        guard previous.sequence < UInt64.max,
              frame.envelope.sequence == previous.sequence + 1, now > before else {
            first = now; return false
        }
        let dt = Double(now - before) / 1e9
        // Same lower/upper cadence tolerance used by the owned 1 Hz reader.
        // Both adjacent declarations must agree with this real interval.
        let minimum = max(previous.cadence, cadence) * 0.5
        let maximum = min(previous.cadence, cadence) * 2.5
        guard dt >= minimum, dt <= maximum else { first = now; return false }
        guard let first, now >= first else { self.first = now; return false }
        return now - first >= 60_000_000_000
    }
}
