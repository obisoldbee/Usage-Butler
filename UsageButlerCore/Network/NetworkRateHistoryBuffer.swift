import Foundation
import UsageButlerDomain

/// One buffered rate observation for one interface.
///
/// It is stamped with the *source counter sample* identity, never with the
/// publish time of the snapshot that happened to carry it. A snapshot that
/// re-emits an unchanged rate therefore cannot add a phantom "fresh" point.
public struct NetworkRateSample: Equatable, Sendable {
    public let captureSessionID: CaptureSessionID
    /// Counter epoch of the underlying interface sample. A change means the
    /// totals are not comparable and the trend must break.
    public let counterEpoch: CounterEpoch
    /// Wall time of the source counter sample (display axis only).
    public let sampledAt: Date
    /// Monotonic time of the source counter sample (ordering and dedup).
    public let sampledMonotonic: MonotonicInstant
    /// `nil` when that direction's rate was unknown; unknown is not zero.
    public let uploadBytesPerSecond: Double?
    public let downloadBytesPerSecond: Double?

    public init(
        captureSessionID: CaptureSessionID,
        counterEpoch: CounterEpoch,
        sampledAt: Date,
        sampledMonotonic: MonotonicInstant,
        uploadBytesPerSecond: Double?,
        downloadBytesPerSecond: Double?
    ) {
        self.captureSessionID = captureSessionID
        self.counterEpoch = counterEpoch
        self.sampledAt = sampledAt
        self.sampledMonotonic = sampledMonotonic
        self.uploadBytesPerSecond = uploadBytesPerSecond
        self.downloadBytesPerSecond = downloadBytesPerSecond
    }

    /// A sample with neither direction known still carries information: it is a
    /// hole in the observation, and dropping it would let the chart bridge the
    /// gap with a fabricated straight line.
    public var isGap: Bool {
        uploadBytesPerSecond == nil && downloadBytesPerSecond == nil
    }
}

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
    public mutating func record(_ snapshot: NetworkSnapshot) {
        for (name, rate) in snapshot.interfaceRates {
            // Without the originating interface sample there is no honest time
            // or epoch to attach, so the rate cannot become a trend point.
            guard let source = snapshot.interfaces[name] else { continue }
            var series = samples[name] ?? []
            if let last = series.last {
                if last.captureSessionID == snapshot.sessionID,
                   last.sampledMonotonic == source.monotonicAsOf {
                    republishedSampleCount += 1
                    continue
                }
                guard source.monotonicAsOf > last.sampledMonotonic else { continue }
            }
            series.append(NetworkRateSample(
                captureSessionID: snapshot.sessionID,
                counterEpoch: source.counters.epoch,
                sampledAt: source.asOf,
                sampledMonotonic: source.monotonicAsOf,
                uploadBytesPerSecond: rate.uploadBytesPerSecond,
                downloadBytesPerSecond: rate.downloadBytesPerSecond
            ))
            if series.count > capacity {
                series.removeFirst(series.count - capacity)
            }
            samples[name] = series
        }
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
