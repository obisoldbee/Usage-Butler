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
    private var lastExpiryTime: MonotonicInstant?
    /// Points suppressed because they repeated an already buffered source
    /// sample. Visible so a caller cannot mistake a quiet buffer for a
    /// recording one.
    public private(set) var republishedSampleCount: Int = 0

    public init(capacity: Int = NetworkRateHistoryBuffer.defaultCapacity, series: [String: [NetworkRateSample]] = [:]) {
        self.capacity = max(1, capacity)
        samples = series.mapValues { Array($0.suffix(max(1, capacity))) }
        lastExpiryTime = samples.values.reduce(nil as MonotonicInstant?) { latest, series in
            series.reduce(latest) { latest, point in max(latest ?? point.sampledMonotonic, point.sampledMonotonic) }
        }
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
            _ = expire(at: snapshot.monotonicAsOf)
            return
        }
        for (name, rate) in snapshot.interfaceRates {
            guard let source = snapshot.interfaces[name] else { continue }
            record(source: source, rate: rate, session: snapshot.sessionID)
        }
        _ = expire(at: snapshot.monotonicAsOf)
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
        if series.count > capacity { series.removeFirst(series.count - capacity) }
        samples[source.name] = series
        // The caller expires once at the complete source batch/publication
        // boundary. Sweeping all interfaces for every row is quadratic.
    }

    /// All interface/session histories use the collector process's monotonic
    /// domain. A backwards clock cannot justify subtraction across domains.
    /// Idle/failed/stopped publication also invokes this bounded cleanup.
    @discardableResult public mutating func expire(at now: MonotonicInstant) -> Bool {
        guard lastExpiryTime.map({ now > $0 }) ?? true else { return false }
        lastExpiryTime = now
        guard now.nanoseconds > 7_200_000_000_000 else { return false }
        let cutoff = now.nanoseconds - 7_200_000_000_000
        var changed = false
        for name in samples.keys {
            guard samples[name]?.contains(where: { $0.sampledMonotonic.nanoseconds < cutoff }) == true,
                  var series = samples.removeValue(forKey: name) else { continue }
            let before = series.count
            series.removeAll { $0.sampledMonotonic.nanoseconds < cutoff }
            changed = changed || series.count != before
            samples[name] = series
        }
        return changed
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
