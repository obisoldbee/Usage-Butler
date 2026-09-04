import Foundation
import UsageButlerDomain

public enum LoginRecoveryVerification: Equatable, Sendable {
    case verifiedFresh
    case authorizationNotRenewed
    case verificationFailed(FailureCode?)
}

/// Classifies the state after an official login flow has exited successfully.
/// A flow exit is not authentication or quota evidence; only the subsequent
/// discovery/read state can make the recovery user-visible as successful.
public enum LoginRecoveryVerifier {
    public static func classify(
        _ state: ProviderState
    ) -> LoginRecoveryVerification {
        guard case .connected = state.connection,
              case .fresh = state.freshness,
              state.refresh.lastSuccessAt != nil,
              state.scopedFailures.current == nil else {
            return .verificationFailed(
                state.scopedFailures.current?.failure.code
            )
        }
        guard case .healthy = state.authentication else {
            return .authorizationNotRenewed
        }
        return .verifiedFresh
    }
}
