import Foundation
import UsageButlerDomain

public enum ProcessNetworkFreshness {
    public static func isFresh(_ app: ProcessNetworkApplication, state: ProcessNetworkState?,
                               now: MonotonicInstant) -> Bool {
        guard state == .active, app.presence == .present, now >= app.sampledMonotonic else { return false }
        return now.nanoseconds - app.sampledMonotonic.nanoseconds <= 12_000_000_000
    }
}
