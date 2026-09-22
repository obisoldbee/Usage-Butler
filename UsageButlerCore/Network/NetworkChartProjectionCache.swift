import Foundation
import UsageButlerDomain

/// Built once per data/window version, independently of cursor changes.
public struct NetworkTrendFrame: Equatable, Sendable {
    public let now: Date
    public let window: TimeInterval
    public let samples: [NetworkRateSample]
    public let projection: NetworkChartProjection
    public let uploadPoints: [NetworkChartPoint]
    public let downloadPoints: [NetworkChartPoint]
    /// Observed zero and no observation are deliberately different.
    public let uploadPeak: Double?
    public let downloadPeak: Double?
    public let inspection: NetworkChartInspectionIndex
}

public struct NetworkChartProjectionCache: Sendable {
    private struct Key: Equatable, Sendable {
        let revision: UInt64
        let interface: String
        let now: Date
        let window: TimeInterval
        let contract: NetworkChartSamplingContract
        let limit: Int
    }
    private var key: Key?
    private var value: NetworkTrendFrame?
    public private(set) var buildCount = 0
    public init() {}
    public mutating func frame(samples: [NetworkRateSample], revision: UInt64, interface: String,
                               now: Date, window: TimeInterval,
                               contract: NetworkChartSamplingContract = .init(),
                               maxPointsPerSegment: Int = 140) -> NetworkTrendFrame {
        let nextKey = Key(revision: revision, interface: interface, now: now, window: window,
                          contract: contract, limit: maxPointsPerSegment)
        if key == nextKey, let value { return value }
        let visible = samples.filter { $0.sampledAt > now.addingTimeInterval(-window) && $0.sampledAt <= now }
        let projection = NetworkChartProjector.project(samples, interface: interface, now: now, window: window,
            contract: contract, maxPointsPerSegment: maxPointsPerSegment)
        let frame = NetworkTrendFrame(now: now, window: window, samples: visible, projection: projection,
            uploadPoints: projection.points(.upload), downloadPoints: projection.points(.download),
            uploadPeak: visible.compactMap(\.uploadBytesPerSecond).max(),
            downloadPeak: visible.compactMap(\.downloadBytesPerSecond).max(),
            inspection: .init(samples: visible))
        key = nextKey; value = frame; buildCount += 1
        return frame
    }
}

/// A stable raw-sample index: cursor lookup does not sort/filter/project the
/// history. Sorting here permits honest wall-clock rollback gaps in the plot.
public struct NetworkChartInspectionIndex: Equatable, Sendable {
    private let samples: [NetworkRateSample]
    public init(samples: [NetworkRateSample]) { self.samples = samples.sorted { $0.sampledAt < $1.sampledAt } }
    public func sample(at time: Date) -> NetworkRateSample? {
        guard !samples.isEmpty else { return nil }
        var low = 0, high = samples.count
        while low < high {
            let mid = (low + high) / 2
            if samples[mid].sampledAt < time { low = mid + 1 } else { high = mid }
        }
        let candidates = [max(0, low - 1), min(samples.count - 1, low)]
        guard let index = candidates.min(by: { abs(samples[$0].sampledAt.timeIntervalSince(time)) < abs(samples[$1].sampledAt.timeIntervalSince(time)) }) else { return nil }
        let result = samples[index]
        return abs(result.sampledAt.timeIntervalSince(time)) <= max(0.5, (result.samplingInterval ?? 1) * 0.55) ? result : nil
    }
}
