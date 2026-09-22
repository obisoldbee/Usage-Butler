import Foundation
import UsageButlerDomain

/// Which of the two independent traffic directions a chart point belongs to.
public enum NetworkChartDirection: String, Equatable, Hashable, Sendable, CaseIterable {
    case upload
    case download

    /// Stable scale value. The view binds these to fixed colors once, so line,
    /// legend and VoiceOver cannot drift apart.
    public var scaleKey: String { rawValue }
}

/// One plottable point. Points may only be joined to other points sharing the
/// same `seriesKey`, which is what keeps upload and download, and separate
/// observation stretches, from being connected to each other.
public struct NetworkChartPoint: Identifiable, Equatable, Sendable {
    public let seriesKey: String
    public let direction: NetworkChartDirection
    public let at: Date
    public let value: Double
    /// A segment of one point has no line to draw; the view renders it as a
    /// visible dot instead of silently dropping the only evidence there was.
    public let isIsolated: Bool

    public var id: String { seriesKey + "@" + at.fixedSeconds }

    public init(
        seriesKey: String,
        direction: NetworkChartDirection,
        at: Date,
        value: Double,
        isIsolated: Bool
    ) {
        self.seriesKey = seriesKey
        self.direction = direction
        self.at = at
        self.value = value
        self.isIsolated = isIsolated
    }
}

public struct NetworkChartProjection: Equatable, Sendable {
    public let points: [NetworkChartPoint]
    public let segmentCount: Int
    public let isolatedPointCount: Int
    /// True when any segment lost interior points to downsampling. The view
    /// must say the trend is thinned rather than imply full fidelity.
    public let thinnedSegmentCount: Int
    /// Silence length that was treated as a hole for this projection. Reported
    /// so a test or caption can state the rule that produced the gaps.
    public let gapThreshold: TimeInterval

    public init(
        points: [NetworkChartPoint],
        segmentCount: Int,
        isolatedPointCount: Int,
        thinnedSegmentCount: Int,
        gapThreshold: TimeInterval = 0
    ) {
        self.points = points
        self.segmentCount = segmentCount
        self.isolatedPointCount = isolatedPointCount
        self.thinnedSegmentCount = thinnedSegmentCount
        self.gapThreshold = gapThreshold
    }

    public static let empty = NetworkChartProjection(
        points: [], segmentCount: 0, isolatedPointCount: 0, thinnedSegmentCount: 0
    )

    public func points(_ direction: NetworkChartDirection) -> [NetworkChartPoint] {
        points.filter { $0.direction == direction }
    }
}

/// The sampling cadence the collector is expected to deliver at. The gap
/// threshold is derived from it, so a slower source does not turn every
/// interval into a "gap" and a stalled source is not smoothed over by an
/// unrelated UI constant.
///
/// Source cadence is carried with each sample. UI publication throttling does
/// not change this contract or justify bridging missing source observations.
public struct NetworkChartSamplingContract: Equatable, Sendable {
    /// Nominal source sample spacing while the panel is visible.
    public let nominalSampleInterval: TimeInterval
    /// Silence longer than this multiple of declared spacing breaks the line.
    public let gapMultiplier: Double
    /// Never accept a threshold below this, so a jittery cluster of samples
    /// cannot make every ordinary interval look like a hole.
    public let minimumThreshold: TimeInterval

    public init(
        nominalSampleInterval: TimeInterval = 1,
        gapMultiplier: Double = 2.5,
        minimumThreshold: TimeInterval = 2
    ) {
        self.nominalSampleInterval = max(0.2, nominalSampleInterval)
        self.gapMultiplier = max(1.5, gapMultiplier)
        self.minimumThreshold = max(0.5, minimumThreshold)
    }

    public func effectiveGapThreshold(for samples: [NetworkRateSample]) -> TimeInterval {
        max(minimumThreshold, nominalSampleInterval * gapMultiplier)
    }

    public func threshold(between earlier: NetworkRateSample, and later: NetworkRateSample) -> TimeInterval {
        // Missing cadence is not reconstructed from point spacing. Legacy
        // samples use the explicitly supplied conservative nominal contract.
        let cadence = max(earlier.samplingInterval ?? nominalSampleInterval,
                          later.samplingInterval ?? nominalSampleInterval)
        return max(minimumThreshold, cadence * gapMultiplier)
    }

}

/// Turns buffered samples into strictly-ordered, independently-grouped chart
/// series. Pure and deterministic: no clock reads, no SwiftUI.
///
/// Ordering of the two steps matters and is deliberate: gaps are found on the
/// raw samples first, then each resulting segment is thinned while keeping its
/// peaks and valleys. Downsampling first would hide the very intervals that
/// prove a sample was lost.
public enum NetworkChartProjector {
    public static func project(
        _ samples: [NetworkRateSample],
        interface: String,
        now: Date,
        window: TimeInterval,
        contract: NetworkChartSamplingContract,
        maxPointsPerSegment: Int = 140
    ) -> NetworkChartProjection {
        let cutoff = now.addingTimeInterval(-abs(window))
        // A fixed `now` bounds both ends of the window, so a view that reads
        // the clock twice cannot produce a self-overlapping domain.
        let ordered = samples.filter { $0.sampledAt > cutoff && $0.sampledAt <= now }
        let gapThreshold = contract.effectiveGapThreshold(for: ordered)

        var points: [NetworkChartPoint] = []
        var segments = 0
        var isolated = 0
        var downsampled = 0

        for direction in NetworkChartDirection.allCases {
            for run in runs(of: ordered, direction: direction, contract: contract) {
                segments += 1
                let kept = thin(run, direction: direction, limit: max(2, maxPointsPerSegment))
                if kept.count != run.count { downsampled += 1 }
                let flag = kept.count == 1
                if flag { isolated += 1 }
                guard let first = run.first else { continue }
                let key = "\(interface)|\(first.captureSessionID.rawValue)|"
                    + "\(first.counterEpoch.rawValue)|\(direction.rawValue)|\(first.sampledAt.fixedSeconds)|\(first.sourceID)|\(first.sampledMonotonic.nanoseconds)"
                for sample in kept {
                    guard let value = value(of: sample, direction: direction) else { continue }
                    points.append(NetworkChartPoint(
                        seriesKey: key,
                        direction: direction,
                        at: sample.sampledAt,
                        value: value,
                        isIsolated: flag
                    ))
                }
            }
        }
        return NetworkChartProjection(
            points: points,
            segmentCount: segments,
            isolatedPointCount: isolated,
            thinnedSegmentCount: downsampled,
            gapThreshold: gapThreshold
        )
    }

    /// Contiguous same-direction stretches. A break happens on an unknown
    /// value, a new capture session, a counter epoch change, or a silent
    /// interval — and only ever for the direction being projected, so an
    /// upload hole cannot punch a hole in the download line.
    private static func runs(
        of samples: [NetworkRateSample],
        direction: NetworkChartDirection,
        contract: NetworkChartSamplingContract
    ) -> [[NetworkRateSample]] {
        var result: [[NetworkRateSample]] = []
        var current: [NetworkRateSample] = []
        var wall = Date.distantPast
        func flush() {
            if !current.isEmpty { result.append(current) }
            current = []
        }
        for sample in samples {
            // Suppress backward wall stamps, but retain their discontinuity.
            // Dropping them before segmentation would silently bridge the gap.
            guard sample.sampledAt > wall else { flush(); continue }
            wall = sample.sampledAt
            guard let value = value(of: sample, direction: direction) else {
                flush()
                continue
            }
            if let previous = current.last, breaks(before: sample, after: previous, value: value, gapThreshold: contract.threshold(between: previous, and: sample)) {
                flush()
            }
            current.append(sample)
        }
        flush()
        return result
    }

    private static func value(of sample: NetworkRateSample, direction: NetworkChartDirection) -> Double? {
        switch direction {
        case .upload: return sample.uploadBytesPerSecond
        case .download: return sample.downloadBytesPerSecond
        }
    }

    private static func breaks(
        before sample: NetworkRateSample,
        after previous: NetworkRateSample,
        value: Double,
        gapThreshold: TimeInterval
    ) -> Bool {
        if sample.sourceID != previous.sourceID || sample.interfaceName != previous.interfaceName { return true }
        if sample.sampledMonotonic <= previous.sampledMonotonic { return true }
        if sample.captureSessionID != previous.captureSessionID { return true }
        if sample.counterEpoch != previous.counterEpoch { return true }
        let elapsed = Double(
            sample.sampledMonotonic.nanoseconds > previous.sampledMonotonic.nanoseconds
                ? sample.sampledMonotonic.nanoseconds - previous.sampledMonotonic.nanoseconds
                : 0
        ) / 1_000_000_000
        if elapsed > gapThreshold { return true }
        // A zero reading is a measured fact and stays on the axis; only a
        // negative one would mean the contract above was violated upstream.
        return value < 0
    }

    /// Keeps the endpoints and, per bucket, both the highest and lowest point,
    /// so thinning a busy window never erases a peak or fills a valley.
    private static func thin(
        _ run: [NetworkRateSample],
        direction: NetworkChartDirection,
        limit: Int
    ) -> [NetworkRateSample] {
        guard run.count > limit else { return run }
        var keep = Set<Int>()
        keep.insert(0)
        keep.insert(run.count - 1)
        let buckets = max(1, limit / 2)
        let size = Double(run.count) / Double(buckets)
        for bucket in 0..<buckets {
            let lower = Int((Double(bucket) * size).rounded(.down))
            let upper = min(run.count - 1, Int((Double(bucket + 1) * size).rounded(.down)))
            guard lower <= upper, lower < run.count, upper < run.count else { continue }
            var peak = lower
            var valley = lower
            for index in lower...upper {
                // Read only the direction this segment belongs to; falling back
                // to the other one would pick peaks that are not plotted.
                // `Self.` avoids shadowing this static function with the local
                // binding below.
                guard let reading = Self.value(of: run[index], direction: direction) else { continue }
                let peakValue = Self.value(of: run[peak], direction: direction) ?? 0
                let valleyValue = Self.value(of: run[valley], direction: direction) ?? 0
                if reading > peakValue { peak = index }
                if reading < valleyValue { valley = index }
            }
            keep.insert(peak)
            keep.insert(valley)
        }
        return run.enumerated().filter { keep.contains($0.offset) }.map(\.element)
    }
}

private extension Date {
    /// Six decimal places keeps sub-second sample times distinct inside a
    /// stable series key without exposing float noise.
    var fixedSeconds: String { String(format: "%.6f", timeIntervalSince1970) }
}
