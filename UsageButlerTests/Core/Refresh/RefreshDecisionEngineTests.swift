import Foundation
import XCTest
@testable import UsageButlerCore
@testable import UsageButlerDomain

final class RefreshDecisionEngineTests: XCTestCase {
    private let wallTime = Date(timeIntervalSince1970: 1_786_300_000)

    func testSameScopeRefreshJoinsTheExistingGeneration() {
        let state = decisionState(
            activity: .refreshing(
                scope: .provider,
                generation: 17,
                startedAt: wallTime
            ),
            gate: .backoff(
                until: MonotonicInstant(nanoseconds: 99_000),
                attempt: 3
            )
        )

        let decision = RefreshDecisionEngine.decide(
            state: state,
            trigger: .manual(scope: .provider),
            now: MonotonicInstant(nanoseconds: 1_000),
            policy: .standard
        )

        XCTAssertEqual(decision, .join(generation: 17))
    }

    func testDifferentScopeDoesNotCoalesceIntoTheActiveRead() {
        let productID = ProductID(providerID: .ark, sourceProductID: "coding")
        let state = decisionState(
            activity: .refreshing(
                scope: .provider,
                generation: 4,
                startedAt: wallTime
            )
        )

        XCTAssertEqual(
            RefreshDecisionEngine.decide(
                state: state,
                trigger: .manual(scope: .product(productID)),
                now: MonotonicInstant(nanoseconds: 1_000),
                policy: .standard
            ),
            .suspend(.operationInProgress)
        )
    }

    func testManualOnlyBlocksAutomaticTriggersButAllowsManualAndRecovery() {
        let policy = RefreshPolicy(
            cadence: .manualOnly,
            manualCooldown: .seconds(20),
            retryBackoff: [.seconds(60)],
            shutdownGrace: .seconds(2)
        )
        let state = decisionState()
        let now = MonotonicInstant(nanoseconds: 10)

        XCTAssertEqual(
            RefreshDecisionEngine.decide(
                state: state,
                trigger: .scheduled(scope: .provider),
                now: now,
                policy: policy
            ),
            .suspend(.manualOnly)
        )
        XCTAssertEqual(
            RefreshDecisionEngine.decide(
                state: state,
                trigger: .manual(scope: .provider),
                now: now,
                policy: policy
            ),
            .run
        )
        XCTAssertEqual(
            RefreshDecisionEngine.decide(
                state: state,
                trigger: .recovery(scope: .provider),
                now: now,
                policy: policy
            ),
            .run
        )
    }

    func testCooldownAndBackoffUseOnlyMonotonicDeadlines() {
        let cooldownUntil = MonotonicInstant(nanoseconds: 20)
        let cooldown = decisionState(gate: .cooldown(until: cooldownUntil))

        XCTAssertEqual(
            RefreshDecisionEngine.decide(
                state: cooldown,
                trigger: .manual(scope: .provider),
                now: MonotonicInstant(nanoseconds: 19),
                policy: .standard
            ),
            .cooldown(until: cooldownUntil)
        )
        XCTAssertEqual(
            RefreshDecisionEngine.decide(
                state: cooldown,
                trigger: .manual(scope: .provider),
                now: cooldownUntil,
                policy: .standard
            ),
            .run
        )

        let backoffUntil = MonotonicInstant(nanoseconds: 90)
        let backoff = decisionState(gate: .backoff(until: backoffUntil, attempt: 2))
        XCTAssertEqual(
            RefreshDecisionEngine.decide(
                state: backoff,
                trigger: .manual(scope: .provider),
                now: MonotonicInstant(nanoseconds: 50),
                policy: .standard
            ),
            .backoff(until: backoffUntil, attempt: 2)
        )
    }

    func testDisabledSuspendedAndShutdownStatesRejectRun() {
        XCTAssertEqual(
            RefreshDecisionEngine.decide(
                state: decisionState(isEnabled: false),
                trigger: .manual(scope: .provider),
                now: MonotonicInstant(nanoseconds: 0),
                policy: .standard
            ),
            .suspend(.disabled)
        )
        XCTAssertEqual(
            RefreshDecisionEngine.decide(
                state: decisionState(
                    gate: .suspended(diagnosticCode: "auth.required")
                ),
                trigger: .manual(scope: .provider),
                now: MonotonicInstant(nanoseconds: 0),
                policy: .standard
            ),
            .suspend(.diagnostic(code: "auth.required"))
        )
        XCTAssertEqual(
            RefreshDecisionEngine.decide(
                state: decisionState(acceptsIntents: false),
                trigger: .manual(scope: .provider),
                now: MonotonicInstant(nanoseconds: 0),
                policy: .standard
            ),
            .suspend(.shuttingDown)
        )
    }

    private func decisionState(
        activity: RefreshActivity = .idle,
        gate: RefreshGateState = .open,
        isEnabled: Bool = true,
        acceptsIntents: Bool = true
    ) -> RefreshDecisionState {
        RefreshDecisionState(
            activity: activity,
            gate: gate,
            isEnabled: isEnabled,
            acceptsIntents: acceptsIntents
        )
    }
}
