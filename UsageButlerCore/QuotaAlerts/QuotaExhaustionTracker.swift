import Foundation

/// Edge-triggered, once-per-cycle exhaustion and recovery deduplication.
///
/// The marker map is the persisted `[metricKey: cycleKey]` dictionary. Three
/// rules keep it honest:
/// - **Re-arm**: when a provider's snapshot reports a metric as no longer
///   exhausted, its marker is dropped and a recovery status is emitted, so
///   the user learns the quota is usable again and a later exhaustion
///   notifies afresh.
/// - **Once per cycle**: a marker only suppresses re-notification while its
///   cycle key matches; a reset (new cycle key) re-arms automatically.
///   `reset:<seconds>` keys match with a tolerance (see
///   `resetCycleToleranceSeconds`): providers may report the same reset
///   instant with small second-level jitter between reads, and exact
///   matching would treat each jittered read as a new cycle and re-notify.
///   A genuine reset moves the instant by a whole window (hours to days),
///   far beyond the tolerance, so re-arming on real resets is unaffected.
///   The pinned marker value is retained on a tolerant match so successive
///   reads cannot accumulate drift. Non-`reset:` keys (`start:`, `unknown`,
///   `expiry:`) match exactly.
/// - **Silent retain**: a metric that stops reporting a usable status
///   (removed or `.unavailable`) keeps its marker - absence of a value is
///   neither proof of recovery nor license to re-arm, so a read that flaps
///   between partial and complete cannot re-notify the same cycle.
///
/// Only metric keys the refreshing provider's own snapshot reports are
/// examined, and every stable key embeds its provider, so one provider's
/// refresh never arms, drops, or clears another provider's markers.
public enum QuotaExhaustionTracker {
    /// Tolerance for `reset:<seconds>` cycle-key drift between reads of the
    /// same cycle. Far above observed second-level jitter and far below the
    /// shortest genuine cycle shift (the 5-hour short-cycle window).
    public static let resetCycleToleranceSeconds: TimeInterval = 15 * 60

    /// Returns the findings whose exhaustion edge is fresh for the current
    /// cycle plus the statuses whose recovery edge is fresh (marker existed,
    /// current snapshot reports them not exhausted), and mutates `markers`
    /// so those edges are armed for next time.
    public static func consume(
        statuses: [QuotaMetricStatus],
        into markers: inout [String: String]
    ) -> (freshExhaustions: [QuotaExhaustionFinding], recoveries: [QuotaMetricStatus]) {
        var freshExhaustions: [QuotaExhaustionFinding] = []
        var recoveries: [QuotaMetricStatus] = []
        for status in statuses {
            if status.isExhausted {
                if !isSameCycle(markers[status.metricKey], status.cycleKey) {
                    freshExhaustions.append(status.exhaustedFinding)
                    markers[status.metricKey] = status.cycleKey
                }
            } else if markers[status.metricKey] != nil {
                recoveries.append(status)
                markers[status.metricKey] = nil
            }
        }
        return (freshExhaustions, recoveries)
    }

    static func isSameCycle(_ marked: String?, _ current: String) -> Bool {
        guard let marked else { return false }
        if marked == current { return true }
        guard let markedReset = resetTimestamp(from: marked),
              let currentReset = resetTimestamp(from: current) else {
            return false
        }
        return abs(markedReset - currentReset) <= resetCycleToleranceSeconds
    }

    static func resetTimestamp(from cycleKey: String) -> TimeInterval? {
        guard cycleKey.hasPrefix("reset:") else { return nil }
        return TimeInterval(cycleKey.dropFirst("reset:".count))
    }
}
