import Foundation
import UsageButlerDomain

/// Stateful per-direction axis. Only monotonic uptime controls hysteresis.
public struct NetworkChartAxis: Equatable, Sendable {
    public private(set) var upperBound: Double = 1
    private var initialized = false
    private var lowerSince: TimeInterval?
    private var changedAt: TimeInterval = 0

    public init() {}

    public static func ceiling(for peak: Double) -> Double {
        guard peak.isFinite, peak > 0 else { return 1 }
        let target = peak * 1.12
        let magnitude = pow(10, floor(log10(target)))
        for step in [1.0, 2, 3, 5, 8, 10] where step * magnitude >= target {
            return step * magnitude
        }
        return target
    }

    public mutating func update(peak: Double, monotonicNow: TimeInterval) {
        let target = Self.ceiling(for: peak)
        if !initialized || target > upperBound {
            upperBound = target; changedAt = monotonicNow; lowerSince = nil; initialized = true
        } else if target < upperBound && peak < upperBound * 0.45 {
            if lowerSince == nil { lowerSince = monotonicNow }
            if monotonicNow - (lowerSince ?? monotonicNow) >= 8 && monotonicNow - changedAt >= 8 {
                upperBound = target; changedAt = monotonicNow; lowerSince = nil
            }
        } else { lowerSince = nil }
    }
}

/// Inspect only a nearby original point, never interpolate through a hole.
public enum NetworkChartInspection {
    public static func sample(at time: Date, in samples: [NetworkRateSample]) -> NetworkRateSample? {
        guard let sample = samples.min(by: { abs($0.sampledAt.timeIntervalSince(time)) < abs($1.sampledAt.timeIntervalSince(time)) }) else { return nil }
        let tolerance = max(0.5, (sample.samplingInterval ?? 1) * 0.55)
        guard abs(sample.sampledAt.timeIntervalSince(time)) <= tolerance else { return nil }
        return sample
    }
}
