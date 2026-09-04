import Foundation
import UsageButlerDomain

public enum ProviderLifecycleRefreshReason: Equatable, Sendable, CaseIterable {
    case panelPresented
    case systemWake
}

/// Decides whether an app-lifecycle signal should request a scheduled refresh.
/// The Controller still owns cadence, gate, coalescing, and retry decisions.
public enum ProviderLifecycleRefreshPolicy {
    /// A successful snapshot older than this may be refreshed when the panel is
    /// presented or the system wakes. Being refresh-due is not itself an error
    /// and must not mutate the snapshot to stale before the read finishes.
    public static let refreshDueAfter: TimeInterval = 60

    public static func shouldRequestRefresh(
        freshness: FreshnessState,
        reason: ProviderLifecycleRefreshReason,
        now: Date
    ) -> Bool {
        switch (freshness, reason) {
        case (.stale, _):
            true
        case (.unknown, .systemWake):
            true
        case (.unknown, .panelPresented):
            false
        case let (.fresh(asOf), _):
            now.timeIntervalSince(asOf) >= refreshDueAfter
        }
    }
}
