import Foundation
import XCTest
@testable import UsageButlerCore
@testable import UsageButlerDomain

final class LoginRecoveryVerificationTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_786_500_000)

    func testOnlyConnectedFreshFailureFreeStateWithSuccessIsVerified() {
        var state = initialState()
        state.connection = .connected(observedAt: now)
        state.freshness = .fresh(asOf: now)
        state.refresh.lastSuccessAt = now
        state.authentication = .healthy(authenticationEvidence())

        XCTAssertEqual(
            LoginRecoveryVerifier.classify(state),
            .verifiedFresh
        )
    }

    func testConnectedFreshWarningIsNotMisreportedAsRenewed() {
        var state = initialState()
        state.connection = .connected(observedAt: now)
        state.freshness = .fresh(asOf: now)
        state.refresh.lastSuccessAt = now
        state.authentication = .warning(authenticationEvidence())

        XCTAssertEqual(
            LoginRecoveryVerifier.classify(state),
            .authorizationNotRenewed
        )
    }

    func testFlowExitWithoutFreshReadIsNotVerified() {
        var state = initialState()
        state.connection = .connected(observedAt: now)
        state.freshness = .stale(
            asOf: now.addingTimeInterval(-300),
            evaluatedAt: now
        )
        state.refresh.lastSuccessAt = now.addingTimeInterval(-300)

        XCTAssertEqual(
            LoginRecoveryVerifier.classify(state),
            .verificationFailed(nil)
        )
    }

    func testCurrentFailureIsReturnedForTruthfulFeedback() {
        var state = initialState()
        state.connection = .connected(observedAt: now)
        state.freshness = .fresh(asOf: now)
        state.refresh.lastSuccessAt = now
        state.scopedFailures.record(
            ProviderFailure(
                code: .networkUnavailable,
                retryClass: .backoff,
                userMessageKey: "provider.failure.network",
                diagnosticCode: "fixture.network",
                recovery: .retry
            ),
            scope: .read(.provider),
            at: now
        )

        XCTAssertEqual(
            LoginRecoveryVerifier.classify(state),
            .verificationFailed(.networkUnavailable)
        )
    }

    func testRequiresLoginCannotBeVerifiedEvenWithHistoricalFreshness() {
        var state = initialState()
        state.connection = .requiresLogin(
            AuthenticationEvidence(
                authority: .providerReport(
                    sourceField: "fixture.auth",
                    contractVersion: "fixture-v1"
                ),
                observedAt: now
            )
        )
        state.freshness = .fresh(asOf: now)
        state.refresh.lastSuccessAt = now

        XCTAssertEqual(
            LoginRecoveryVerifier.classify(state),
            .verificationFailed(nil)
        )
    }

    private func initialState() -> ProviderState {
        ProviderBootstrap.initialState(
            id: .ark,
            capabilities: ProviderCapabilities(
                contractVersion: "fixture-v1",
                loginMethod: .sso,
                hasOfficialDocumentation: true,
                allowsExecutableSelection: true
            ),
            now: now
        )
    }

    private func authenticationEvidence() -> AuthenticationEvidence {
        AuthenticationEvidence(
            authority: .providerReport(
                sourceField: "fixture.auth",
                contractVersion: "fixture-v1"
            ),
            observedAt: now,
            expiresAt: now.addingTimeInterval(3_600)
        )
    }
}
