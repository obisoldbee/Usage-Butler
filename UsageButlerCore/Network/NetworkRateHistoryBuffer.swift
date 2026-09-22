import Foundation
import UsageButlerDomain

/// Bounded in-memory per-interface rate history for the trend chart. It is a
/// display buffer, not the history store: it never fabricates points, keys
/// every point on the source sample it came from, and drops the oldest
/// samples past capacity.
public struct NetworkRateHistoryBuffer: Equatable, Sendable {
    /// 2 h at 1 Hz — the longest visible trend range.
    public static let defaultCapacity = 7_200

    public let capacity: Int
    private var samples: [String: [NetworkRateSample]] = [:]
    /// Points suppressed because they repeated an already buffered source
    /// sample. Visible so a caller cannot mistake a quiet buffer for a
    /// recording one.
    public private(set) var republishedSampleCount: Int = 0

    public init(capacity: Int = NetworkRateHistoryBuffer.defaultCapacity) {
        self.capacity = max(1, capacity)
    }

    public var count: Int { samples.values.reduce(0) { $0 + $1.count } }

    /// Appends the rates of one snapshot, keyed by the counter sample each rate
    /// was derived from.
    ///
    /// A rate is skipped when its source sample is already buffered (the same
    /// snapshot republished) or when the source monotonic stamp does not
    /// advance. Wall-clock is never used for that ordering decision.
    public var allSeries: [String: [NetworkRateSample]] { samples }

    /// A source-owned complete batch replaces the display buffer. Legacy and
    /// fixture snapshots without a batch use the same source-identity gate.
    public mutating func record(_ snapshot: NetworkSnapshot) {
        if let history = snapshot.rateHistory {
            samples = history.mapValues { Array($0.suffix(capacity)) }
            return
        }
        for (name, rate) in snapshot.interfaceRates {
            guard let source = snapshot.interfaces[name] else { continue }
            record(source: source, rate: rate, session: snapshot.sessionID)
        }
    }

    public mutating func record(source: InterfaceCounters, rate: NetworkRate?, session: CaptureSessionID) {
        var series = samples[source.name] ?? []
        if let last = series.last, last.captureSessionID == session {
            if last.sampledMonotonic == source.monotonicAsOf {
                republishedSampleCount += 1
                return
            }
            guard source.monotonicAsOf > last.sampledMonotonic else { return }
        }
        series.append(NetworkRateSample(
            captureSessionID: session, counterEpoch: source.counters.epoch,
            sampledAt: source.asOf, sampledMonotonic: source.monotonicAsOf,
            uploadBytesPerSecond: rate?.uploadBytesPerSecond,
            downloadBytesPerSecond: rate?.downloadBytesPerSecond,
            interfaceName: source.name, samplingInterval: source.samplingInterval
        ))
        // Time and point limits both apply, including when the source is faster
        // or slower than 1 Hz. Monotonic retention ignores wall-clock changes.
        let cutoff = source.monotonicAsOf.nanoseconds > 7_200_000_000_000
            ? source.monotonicAsOf.nanoseconds - 7_200_000_000_000 : 0
        series.removeAll { $0.captureSessionID == session && $0.sampledMonotonic.nanoseconds < cutoff }
        if series.count > capacity { series.removeFirst(series.count - capacity) }
        samples[source.name] = series
    }

    public func series(for interface: String) -> [NetworkRateSample] {
        samples[interface] ?? []
    }

    /// Drops interfaces that are no longer observed so their stale series
    /// cannot be mistaken for live data.
    public mutating func prune(keeping names: Set<String>) {
        samples = samples.filter { names.contains($0.key) }
    }
}
