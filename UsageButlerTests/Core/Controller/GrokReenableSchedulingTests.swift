import Foundation
import XCTest
@testable import UsageButlerCore
@testable import UsageButlerDomain
import UsageButlerProviders

/// Exercise production Controller/Scheduler reentrancy with only offline ports.
/// Cache continuations establish the old-off/new-on order; clock registrations
/// and blocked reads establish timer execution without polling or wall-clock waits.
final class GrokReenableSchedulingTests: XCTestCase {
    private let key = RefreshScheduleKey(providerID: .grokBot, scope: .provider)

    func testObsoleteOffPreservesNewAutomaticTokenAndItsDueRead() async throws {
        let fixture = try Fixture()
        _ = await fixture.controller.send(.start)
        let oldToken = await fixture.scheduler.scheduledToken(for: key)
        XCTAssertNotNil(oldToken)

        await fixture.cache.blockClear()
        let off = Task { await fixture.controller.send(.setEnabled(false)) }
        await fixture.cache.waitUntilClearIsBlocked()
        await fixture.adapter.enqueueDiscovery(.success(Fixture.discovery()))
        await fixture.adapter.enqueueRead(.success(try Fixture.data()))
        let on = await fixture.controller.send(.setEnabled(true))
        XCTAssertEqual(on, .completed)
        let newToken = await fixture.scheduler.scheduledToken(for: key)
        let expected = try XCTUnwrap(newToken)
        XCTAssertEqual(expected.reason, .automatic)
        XCTAssertNotEqual(expected, oldToken)
        let beforeOffReturns = await fixture.controller.projection()
        XCTAssertEqual(beforeOffReturns.state.lastGood, try Fixture.data())

        await fixture.cache.resumeClear()
        let offOutcome = await off.value
        XCTAssertEqual(offOutcome, .cancelled)
        let surviving = await fixture.scheduler.scheduledToken(for: key)
        XCTAssertEqual(surviving, expected, "Obsolete off must preserve the new on automatic token")
        guard surviving == expected else {
            _ = await fixture.controller.send(.shutdown)
            return
        }
        let projection = await fixture.controller.projection()
        XCTAssertTrue(projection.isEnabled)
        XCTAssertNotNil(projection.state.lastGood)
        try await assertDueRead(expected, fixture: fixture, readsBefore: 2, savesAfter: 3)
        _ = await fixture.controller.send(.shutdown)
    }

    func testObsoleteOffPreservesNewRefreshRetryAndItsDueRead() async throws {
        let fixture = try Fixture()
        _ = await fixture.controller.send(.start)
        await fixture.cache.blockClear()
        let off = Task { await fixture.controller.send(.setEnabled(false)) }
        await fixture.cache.waitUntilClearIsBlocked()
        await fixture.adapter.enqueueDiscovery(.success(Fixture.discovery()))
        await fixture.adapter.enqueueRead(.failure(ControllerFixture.failure(retryClass: .backoff)))
        _ = await fixture.controller.send(.setEnabled(true))
        let token = await fixture.scheduler.scheduledToken(for: key)
        let expected = try XCTUnwrap(token)
        XCTAssertEqual(expected.reason, .refreshRetry(attempt: 1, initiatedBy: .toggleOn))

        await fixture.cache.resumeClear()
        let offOutcome = await off.value
        XCTAssertEqual(offOutcome, .cancelled)
        let surviving = await fixture.scheduler.scheduledToken(for: key)
        XCTAssertEqual(surviving, expected, "Obsolete off must preserve the new on retry token")
        guard surviving == expected else {
            _ = await fixture.controller.send(.shutdown)
            return
        }
        try await assertDueRead(expected, fixture: fixture, readsBefore: 2, savesAfter: 2)
        _ = await fixture.controller.send(.shutdown)
    }

    func testObsoleteOffPreservesDiscoveryRetryAttemptProgressionAndRecovery() async throws {
        let fixture = try Fixture()
        _ = await fixture.controller.send(.start)
        await fixture.cache.blockClear()
        let off = Task { await fixture.controller.send(.setEnabled(false)) }
        await fixture.cache.waitUntilClearIsBlocked()
        await fixture.adapter.enqueueDiscovery(.failure(ControllerFixture.failure(retryClass: .backoff)))
        _ = await fixture.controller.send(.setEnabled(true))
        let token = await fixture.scheduler.scheduledToken(for: key)
        let expected = try XCTUnwrap(token)
        XCTAssertEqual(expected.reason, .discoveryRetry(attempt: 1, initiatedBy: .toggleOn))

        await fixture.cache.resumeClear()
        let offOutcome = await off.value
        XCTAssertEqual(offOutcome, .cancelled)
        let surviving = await fixture.scheduler.scheduledToken(for: key)
        XCTAssertEqual(surviving, expected, "Obsolete off must preserve discovery retry bookkeeping")
        guard surviving == expected else {
            _ = await fixture.controller.send(.shutdown)
            return
        }

        await fixture.adapter.enqueueDiscovery(.failure(ControllerFixture.failure(retryClass: .backoff)))
        await fixture.clock.waitUntilSleepIsRegistered(until: expected.deadline)
        await fixture.clock.advance(to: expected.deadline.nanoseconds)
        // Exact registration of the second backoff proves the discovery handler
        // completed. Resetting retryAttempts would choose the first delay again.
        let secondDeadline = RefreshDecisionEngine.adding(.seconds(120), to: expected.deadline)
        await fixture.clock.waitUntilSleepIsRegistered(until: secondDeadline)
        let secondToken = await fixture.scheduler.scheduledToken(for: key)
        let second = try XCTUnwrap(secondToken)
        XCTAssertEqual(second.reason, .discoveryRetry(attempt: 2, initiatedBy: .toggleOn))
        XCTAssertEqual(second.deadline, secondDeadline)
        let failedDiscoveries = await fixture.adapter.discoverCallCount
        XCTAssertEqual(failedDiscoveries, 3)

        await fixture.adapter.enqueueDiscovery(.success(Fixture.discovery()))
        try await assertDueRead(second, fixture: fixture, readsBefore: 1, savesAfter: 2)
        let recoveredDiscoveries = await fixture.adapter.discoverCallCount
        XCTAssertEqual(recoveredDiscoveries, 4)
        _ = await fixture.controller.send(.shutdown)
    }

    func testCurrentOffCancelsAutomaticOrRetryAndClearsGrokData() async throws {
        for retry in [false, true] {
            let fixture = try Fixture()
            _ = await fixture.controller.send(.start)
            if retry {
                await fixture.adapter.enqueueRead(.failure(ControllerFixture.failure(retryClass: .backoff)))
                _ = await fixture.controller.send(.refresh(.manual(scope: .provider)))
            }
            let token = await fixture.scheduler.scheduledToken(for: key)
            XCTAssertNotNil(token)
            let off = await fixture.controller.send(.setEnabled(false))
            XCTAssertEqual(off, .completed)
            let tokens = await fixture.scheduler.scheduledTokens(providerID: .grokBot)
            XCTAssertTrue(tokens.isEmpty)
            let projection = await fixture.controller.projection()
            XCTAssertFalse(projection.isEnabled)
            XCTAssertNil(projection.state.lastGood)
            XCTAssertEqual(projection.state.connection, .disabled)
            let clears = await fixture.cache.clearedProviderIDs
            XCTAssertEqual(clears, [.grokBot])
            let refresh = await fixture.controller.send(.refresh(.manual(scope: .provider)))
            XCTAssertEqual(refresh, .cancelled)
            _ = await fixture.controller.send(.shutdown)
        }
    }

    func testObsoleteOffUnderManualOnlyCreatesNoTimerAndAllowsManualRead() async throws {
        let fixture = try Fixture(manualOnly: true)
        _ = await fixture.controller.send(.start)
        await fixture.cache.blockClear()
        let off = Task { await fixture.controller.send(.setEnabled(false)) }
        await fixture.cache.waitUntilClearIsBlocked()
        await fixture.adapter.enqueueDiscovery(.success(Fixture.discovery()))
        _ = await fixture.controller.send(.setEnabled(true))
        await fixture.cache.resumeClear()
        let offOutcome = await off.value
        XCTAssertEqual(offOutcome, .cancelled)
        let tokens = await fixture.scheduler.scheduledTokens(providerID: .grokBot)
        XCTAssertTrue(tokens.isEmpty)
        let beforeManual = await fixture.adapter.readScopes.count
        await fixture.adapter.enqueueRead(.success(try Fixture.data()))
        let manual = await fixture.controller.send(.refresh(.manual(scope: .provider)))
        XCTAssertEqual(manual, .completed)
        let afterManual = await fixture.adapter.readScopes.count
        XCTAssertEqual(afterManual, beforeManual + 1)
        let afterTokens = await fixture.scheduler.scheduledTokens(providerID: .grokBot)
        XCTAssertTrue(afterTokens.isEmpty)
        _ = await fixture.controller.send(.shutdown)
    }

    func testShutdownWhileOffIsClearingCancelsNewOnTimerAndRejectsReenable() async throws {
        let fixture = try Fixture()
        _ = await fixture.controller.send(.start)
        await fixture.cache.blockClear()
        let off = Task { await fixture.controller.send(.setEnabled(false)) }
        await fixture.cache.waitUntilClearIsBlocked()
        await fixture.adapter.enqueueDiscovery(.success(Fixture.discovery()))
        await fixture.adapter.enqueueRead(.success(try Fixture.data()))
        _ = await fixture.controller.send(.setEnabled(true))
        let token = await fixture.scheduler.scheduledToken(for: key)
        XCTAssertNotNil(token)

        let shutdown = await fixture.controller.send(.shutdown)
        XCTAssertEqual(shutdown, .shutdown(completedWithinGrace: true))
        await fixture.cache.resumeClear()
        let offOutcome = await off.value
        XCTAssertEqual(offOutcome, .cancelled)
        let tokens = await fixture.scheduler.scheduledTokens(providerID: .grokBot)
        XCTAssertTrue(tokens.isEmpty)
        let projection = await fixture.controller.projection()
        XCTAssertEqual(projection.phase, .stopped)
        let reenable = await fixture.controller.send(.setEnabled(true))
        XCTAssertEqual(reenable, .rejected(.stopped))
        let reads = await fixture.adapter.readScopes.count
        XCTAssertEqual(reads, 2)
    }

    private func assertDueRead(
        _ token: RefreshScheduleToken,
        fixture: Fixture,
        readsBefore: Int,
        savesAfter: Int
    ) async throws {
        await fixture.adapter.blockNextRead()
        await fixture.clock.waitUntilSleepIsRegistered(until: token.deadline)
        await fixture.clock.advance(to: token.deadline.nanoseconds - 1)
        let before = await fixture.adapter.readScopes.count
        XCTAssertEqual(before, readsBefore)
        await fixture.clock.advance(to: token.deadline.nanoseconds)
        await fixture.adapter.waitUntilReadIsBlocked()
        let due = await fixture.adapter.readScopes.count
        XCTAssertEqual(due, readsBefore + 1, "The surviving timer must enter the production read path exactly once")
        await fixture.adapter.resumeRead(with: .success(try Fixture.data()))
        await fixture.cache.waitUntilSaveCount(savesAfter)
        let after = await fixture.adapter.readScopes.count
        XCTAssertEqual(after, readsBefore + 1)
        let next = await fixture.scheduler.scheduledToken(for: key)
        XCTAssertEqual(next?.reason, .automatic)
        XCTAssertNotEqual(next, token)
    }

    private struct Fixture {
        let clock = TestClock()
        let cache = FakeProviderQuotaCache()
        let adapter: FakeProviderAdapter
        let scheduler: RefreshScheduler
        let controller: ProviderController

        init(manualOnly: Bool = false) throws {
            try ProviderQuotaIdentityValidator.validate(Self.data(), expectedProviderID: .grokBot)
            adapter = FakeProviderAdapter(
                id: .grokBot,
                capabilities: ControllerFixture.capabilities,
                retainsDataWhenDisabled: false,
                discoveryResults: [.success(Self.discovery())],
                readResults: [.success(try Self.data())]
            )
            scheduler = RefreshScheduler(clock: clock)
            controller = try ProviderController(
                initialState: ProviderBootstrap.initialState(
                    id: .grokBot,
                    capabilities: adapter.capabilities,
                    now: ControllerFixture.fixedDate
                ),
                initiallyEnabled: true,
                adapter: adapter,
                cache: cache,
                clock: clock,
                scheduler: scheduler,
                policy: RefreshPolicy(
                    cadence: manualOnly ? .manualOnly : .automatic(interval: .seconds(300)),
                    manualCooldown: .seconds(0),
                    retryBackoff: [.seconds(60), .seconds(120)],
                    shutdownGrace: .seconds(2)
                )
            )
        }

        static func source() -> ProviderSourceIdentity {
            GrokSharedQuotaMapper.source(sessionScope: "offline-grok-scheduling")
        }

        static func data() throws -> ProviderQuotaData {
            try GrokSharedQuotaMapper.map(
                Data(#"{"availability":"available","weeklyIncludedStatus":{"status":"metered"},"weeklyIncludedUsage":{"usedCents":25,"budgetCents":100}}"#.utf8),
                fetchedAt: ControllerFixture.fixedDate,
                sessionScope: "offline-grok-scheduling"
            )
        }

        static func discovery() -> SuccessfulProviderDiscovery {
            SuccessfulProviderDiscovery(
                providerID: .grokBot,
                authority: DiscoveryAuthority(source: source(), operationID: "offline.grok.discovery"),
                observedAt: ControllerFixture.fixedDate,
                connection: .connected,
                authentication: .healthy(AuthenticationEvidence(
                    authority: .providerReport(sourceField: "fixture", contractVersion: "fixture"),
                    observedAt: ControllerFixture.fixedDate
                )),
                presence: .entitled
            )
        }
    }
}
