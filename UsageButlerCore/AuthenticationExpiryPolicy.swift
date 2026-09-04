import Foundation
import UsageButlerDomain

public enum AuthenticationExpiryPolicy {
    public static let warningThreshold: TimeInterval = 24 * 60 * 60

    /// Re-evaluate a previously observed deadline even while quota reads are
    /// offline or on a long cadence. This does not create new provider evidence.
    public static func evaluate(_ authentication: AuthenticationState, now: Date) -> AuthenticationState {
        let evidence: AuthenticationEvidence
        switch authentication {
        case let .healthy(value), let .warning(value): evidence = value
        case .unknown, .expired: return authentication
        }
        guard let expiresAt = evidence.expiresAt else { return authentication }
        if expiresAt <= now,
           case let .providerReport(field, version) = evidence.authority {
            return .expired(AuthenticationExpiryEvidence(
                authority: .explicitExpiration(sourceField: field, contractVersion: version),
                observedAt: evidence.observedAt
            ))
        }
        return expiresAt.timeIntervalSince(now) <= warningThreshold
            ? .warning(evidence) : .healthy(evidence)
    }
}
