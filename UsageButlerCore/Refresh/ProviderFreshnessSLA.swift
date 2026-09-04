import Foundation

/// The independent data-age SLA behind `ProviderIntent.ageTick(staleAfter:)`.
///
/// This policy is deliberately separate from
/// `ProviderLifecycleRefreshPolicy.refreshDueAfter`: reaching refresh-due may
/// request a scheduled read but never ages a snapshot, while only this policy
/// (driven through `ageTick`) may turn a retained fresh snapshot stale without
/// a new failure. The reducer keeps `staleAfter` authoritative per event, so a
/// runtime tick must always pass the value resolved here.
public enum ProviderFreshnessSLA {
    /// How often the runtime re-evaluates data age. This bounds how long a
    /// snapshot can outlive its SLA before the UI observes the transition,
    /// without producing per-second state churn across all providers.
    public static let tickInterval: TimeInterval = 30

    /// Manual-only providers have no automatic cadence, so their retained data
    /// still decays to stale after one hour to keep the data-age invariant
    /// truthful without nagging an explicit manual-refresh choice.
    public static let manualOnlyStaleAfter: TimeInterval = 3_600

    /// Scheduled cadences owe data for twice their interval before the
    /// retained snapshot may be marked stale, and never less than this floor,
    /// so short intervals tolerate a single missed automatic refresh.
    public static let minimumScheduledStaleAfter: TimeInterval = 600

    public static func staleAfter(frequency: ProviderRefreshFrequency) -> TimeInterval {
        switch frequency {
        case .manualOnly:
            manualOnlyStaleAfter
        case .oneMinute, .fiveMinutes, .fifteenMinutes, .thirtyMinutes:
            max(
                TimeInterval(frequency.rawValue) * 2,
                minimumScheduledStaleAfter
            )
        }
    }
}
