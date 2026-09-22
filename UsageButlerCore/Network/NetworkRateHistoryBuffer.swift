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

    public init(capacity: Int = NetworkRateHistoryBuffer.defaultCapacity, series: [String: [NetworkRateSample]] = [:]) {
        self.capacity = max(1, capacity)
        samples = series.mapValues { Array($0.suffix(max(1, capacity))) }
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
            samples = history.mapValues { series in
                Self.identifyingContinuity(Array(series.suffix(capacity)))
            }
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
        let next = NetworkRateSample(
            captureSessionID: session, counterEpoch: source.counters.epoch,
            sampledAt: source.asOf, sampledMonotonic: source.monotonicAsOf,
            uploadBytesPerSecond: rate?.uploadBytesPerSecond,
            downloadBytesPerSecond: rate?.downloadBytesPerSecond,
            interfaceName: source.name, samplingInterval: source.samplingInterval
        )
        series.append(Self.identify(next, after: series.last))
        // Time and point limits both apply, including when the source is faster
        // or slower than 1 Hz. Monotonic retention ignores wall-clock changes.
        let cutoff = source.monotonicAsOf.nanoseconds > 7_200_000_000_000
            ? source.monotonicAsOf.nanoseconds - 7_200_000_000_000 : 0
        series.removeAll { $0.captureSessionID == session && $0.sampledMonotonic.nanoseconds < cutoff }
        if series.count > capacity { series.removeFirst(series.count - capacity) }
        samples[source.name] = series
    }

    /// Source-owned IDs carry through subsequent windows and bounded trims.
    public static func identifyingContinuity(_ series: [NetworkRateSample]) -> [NetworkRateSample] {
        var result: [NetworkRateSample] = []
        for sample in series { result.append(identify(sample, after: result.last)) }
        return result
    }

    private static func identify(_ sample: NetworkRateSample, after previous: NetworkRateSample?) -> NetworkRateSample {
        func id(_ direction: NetworkChartDirection) -> String? {
            let value = direction == .upload ? sample.uploadBytesPerSecond : sample.downloadBytesPerSecond
            guard value != nil else { return nil }
            let supplied = direction == .upload ? sample.uploadContinuityID : sample.downloadContinuityID
            if let previous, NetworkChartProjector.areContinuous(previous, sample, direction: direction) {
                return supplied ?? (direction == .upload ? previous.uploadContinuityID : previous.downloadContinuityID) ?? sample.sampleID
            }
            return supplied ?? sample.sampleID
        }
        return sample.withContinuity(upload: id(.upload), download: id(.download))
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
