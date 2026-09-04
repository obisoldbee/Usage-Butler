import Foundation
import XCTest
@testable import UsageButlerCore
@testable import UsageButlerDomain

final class ProviderControllerTests: XCTestCase {
    func testFirstSuccessPatchWithoutCacheCommitsCachesAndSchedulesAutomaticRefresh() async throws {
        let clock = TestClock()
        let fetchedAt = ControllerFixture.fixedDate.addingTimeInterval(10)
        let patch = ProviderQuotaPatch(
            providerID: .ark,
            source: ControllerFixture.source(),
            fetchedAt: fetchedAt,
            productCollectionMutation: .replaceAll([]),
            balanceMutation: .replace([]),
            resetEntitlementMutation: .retain
        )
        let adapter = FakeProviderAdapter(
            id: .ark,
            capabilities: ControllerFixture.capabilities,
            discoveryResults: [.success(ControllerFixture.discovery())],
            readResults: [.successPatch(patch)]
        )
        let cache = FakeProviderQuotaCache()
        let (controller, scheduler) = try makeController(
            adapter: adapter,
            cache: cache,
            clock: clock
        )

        let outcome = await controller.send(.start)
        XCTAssertEqual(outcome, .completed)

        let projection = await controller.projection()
        XCTAssertEqual(projection.state.lastGood?.fetchedAt, fetchedAt)
        XCTAssertEqual(projection.state.freshness, .fresh(asOf: fetchedAt))
        XCTAssertNil(projection.state.failure)
        let savedData = await cache.savedData
        XCTAssertEqual(savedData.count, 1)
        XCTAssertEqual(savedData.first?.fetchedAt, fetchedAt)
        let scheduled = await scheduler.scheduledToken(
            for: RefreshScheduleKey(providerID: .ark, scope: .provider)
        )
        XCTAssertEqual(scheduled?.reason, .automatic)
    }

    func testStartupLoadsCacheAsStaleBeforeDiscoveryThenPerformsLiveRead() async throws {
        let recorder = TestCallRecorder()
        let clock = TestClock()
        let cached = ControllerFixture.quotaData(
            fetchedAt: ControllerFixture.fixedDate.addingTimeInterval(-300)
        )
        let live = ControllerFixture.quotaData(
            fetchedAt: ControllerFixture.fixedDate.addingTimeInterval(10)
        )
        let adapter = FakeProviderAdapter(
            id: .ark,
            capabilities: ControllerFixture.capabilities,
            recorder: recorder,
            readResults: [.success(live)]
        )
        await adapter.blockNextDiscovery()
        let cache = FakeProviderQuotaCache(
            recorder: recorder,
            loadResult: .hit(cached)
        )
        let (controller, scheduler) = try makeController(
            adapter: adapter,
            cache: cache,
            clock: clock
        )

        let startTask = Task { await controller.send(.start) }
        await adapter.waitUntilDiscoveryIsBlocked()

        let duringDiscovery = await controller.projection()
        XCTAssertEqual(duringDiscovery.state.lastGood?.fetchedAt, cached.fetchedAt)
        guard case let .stale(asOf, _) = duringDiscovery.state.freshness else {
            return XCTFail("A cache hit must be stale while discovery is in flight")
        }
        XCTAssertEqual(asOf, cached.fetchedAt)
        let beforeResume = await recorder.entries()
        XCTAssertEqual(beforeResume, ["cache.load", "adapter.discover"])

        await adapter.resumeDiscovery(with: .success(ControllerFixture.discovery()))
        let startOutcome = await startTask.value
        XCTAssertEqual(startOutcome, .completed)

        let final = await controller.projection()
        XCTAssertEqual(final.state.lastGood, live)
        XCTAssertEqual(final.state.freshness, .fresh(asOf: live.fetchedAt))
        let completedOrder = await recorder.entries()
        XCTAssertEqual(
            completedOrder,
            ["cache.load", "adapter.discover", "adapter.read", "cache.save"]
        )
    }

    func testDiscoverySuccessTransitionsDirectlyIntoRefreshingWithoutIdleStalePublish() async throws {
        let clock = TestClock()
        let cached = ControllerFixture.quotaData(
            fetchedAt: ControllerFixture.fixedDate.addingTimeInterval(-300)
        )
        let live = ControllerFixture.quotaData(
            fetchedAt: ControllerFixture.fixedDate.addingTimeInterval(10)
        )
        let adapter = FakeProviderAdapter(
            id: .ark,
            capabilities: ControllerFixture.capabilities,
            readResults: [.success(live)]
        )
        await adapter.blockNextDiscovery()
        await adapter.blockNextRead()
        let cache = FakeProviderQuotaCache(loadResult: .hit(cached))
        let (controller, _) = try makeController(
            adapter: adapter,
            cache: cache,
            clock: clock
        )

        let startTask = Task { await controller.send(.start) }
        await adapter.waitUntilDiscoveryIsBlocked()
        let duringDiscovery = await controller.projection()
        guard case .detecting = duringDiscovery.state.refresh.activity else {
            return XCTFail("Discovery must remain visibly in flight")
        }

        await adapter.resumeDiscovery(with: .success(ControllerFixture.discovery()))
        await adapter.waitUntilReadIsBlocked()
        let duringRead = await controller.projection()
        XCTAssertEqual(duringRead.revision, duringDiscovery.revision + 1)
        guard case .connected = duringRead.state.connection else {
            return XCTFail("Successful discovery must publish the connected state")
        }
        guard case .refreshing = duringRead.state.refresh.activity else {
            return XCTFail("Discovery success and read start must publish atomically")
        }
        guard case .stale = duringRead.state.freshness else {
            return XCTFail("Retained cache must remain stale until read succeeds")
        }

        await adapter.resumeRead(with: .success(live))
        let outcome = await startTask.value
        XCTAssertEqual(outcome, .completed)
        let final = await controller.projection()
        XCTAssertEqual(final.state.freshness, .fresh(asOf: live.fetchedAt))
    }

    func testSameScopeCoalescesAndToggleOffRejectsLateReadCommitWithoutLogout() async throws {
        let clock = TestClock()
        let first = ControllerFixture.quotaData()
        let late = ControllerFixture.quotaData(
            fetchedAt: ControllerFixture.fixedDate.addingTimeInterval(600)
        )
        let adapter = FakeProviderAdapter(
            id: .ark,
            capabilities: ControllerFixture.capabilities,
            discoveryResults: [.success(ControllerFixture.discovery())],
            readResults: [.success(first)]
        )
        let cache = FakeProviderQuotaCache()
        let (controller, scheduler) = try makeController(
            adapter: adapter,
            cache: cache,
            clock: clock
        )
        let startOutcome = await controller.send(.start)
        XCTAssertEqual(startOutcome, .completed)

        await adapter.blockNextRead()
        let firstManual = Task {
            await controller.send(.refresh(.manual(scope: .provider)))
        }
        await adapter.waitUntilReadIsBlocked()
        let readScopesAtBlock = await adapter.readScopes
        XCTAssertEqual(
            readScopesAtBlock.count,
            2,
            "The blocked manual read must start"
        )

        let joined = await controller.send(.refresh(.manual(scope: .provider)))
        guard case .joined = joined else {
            return XCTFail("The second request for the same scope must join")
        }

        let disableOutcome = await controller.send(.setEnabled(false))
        XCTAssertEqual(disableOutcome, .completed)
        await adapter.resumeRead(with: .success(late))
        let lateOutcome = await firstManual.value
        XCTAssertEqual(lateOutcome, .cancelled)

        let projection = await controller.projection()
        XCTAssertFalse(projection.isEnabled)
        XCTAssertEqual(projection.state.connection, .disabled)
        XCTAssertEqual(projection.state.refresh.activity, .idle)
        XCTAssertEqual(projection.state.lastGood?.fetchedAt, first.fetchedAt)
        guard case .stale = projection.state.freshness else {
            return XCTFail("Toggle OFF must retain the prior data as stale")
        }
        let readScopes = await adapter.readScopes
        let shutdownCount = await adapter.shutdownCallCount
        let schedules = await scheduler.scheduledTokens(providerID: .ark)
        XCTAssertEqual(readScopes.count, 2)
        XCTAssertEqual(shutdownCount, 0, "Toggle OFF is not adapter shutdown or logout")
        XCTAssertTrue(schedules.isEmpty)
    }

    func testFirstRetryableFailureImmediatelyArmsBackoffAndRetriesAtDeadline() async throws {
        let clock = TestClock()
        let initial = ControllerFixture.quotaData()
        let recovered = ControllerFixture.quotaData(
            fetchedAt: ControllerFixture.fixedDate.addingTimeInterval(60)
        )
        let adapter = FakeProviderAdapter(
            id: .ark,
            capabilities: ControllerFixture.capabilities,
            discoveryResults: [.success(ControllerFixture.discovery())],
            readResults: [
                .success(initial),
                .failure(ControllerFixture.failure(retryClass: .backoff))
            ]
        )
        let cache = FakeProviderQuotaCache()
        let policy = RefreshPolicy(
            cadence: .automatic(interval: .seconds(300)),
            manualCooldown: .seconds(20),
            retryBackoff: [.seconds(60), .seconds(120)],
            shutdownGrace: .seconds(2)
        )
        let (controller, scheduler) = try makeController(
            adapter: adapter,
            cache: cache,
            clock: clock,
            policy: policy
        )
        let startOutcome = await controller.send(.start)
        XCTAssertEqual(startOutcome, .completed)

        let failureOutcome = await controller.send(.refresh(.manual(scope: .provider)))
        XCTAssertEqual(failureOutcome, .completed)
        let scheduledToken = await scheduler.scheduledToken(
            for: RefreshScheduleKey(providerID: .ark, scope: .provider)
        )
        let token = try XCTUnwrap(scheduledToken)
        XCTAssertEqual(
            token.reason,
            .refreshRetry(attempt: 1, initiatedBy: .manual)
        )
        let failedProjection = await controller.projection()
        XCTAssertEqual(
            failedProjection.state.refresh.gate,
            .backoff(until: token.deadline, attempt: 1)
        )
        XCTAssertEqual(failedProjection.state.lastGood?.fetchedAt, initial.fetchedAt)

        await adapter.blockNextRead()
        await clock.waitUntilSleepIsRegistered(until: token.deadline)
        await clock.advance(to: token.deadline.nanoseconds - 1)
        let readsBeforeDeadline = await adapter.readScopes.count
        XCTAssertEqual(readsBeforeDeadline, 2)
        await clock.advance(to: token.deadline.nanoseconds)
        await adapter.waitUntilReadIsBlocked()
        let readsAtDeadline = await adapter.readScopes.count
        XCTAssertEqual(readsAtDeadline, 3)
        await adapter.resumeRead(with: .success(recovered))
        await cache.waitUntilSaveCount(2)
        let recoveredProjection = await controller.projection()
        XCTAssertEqual(
            recoveredProjection.state.freshness,
            .fresh(asOf: recovered.fetchedAt)
        )
    }

    func testTerminalReadFailureUnderAutomaticCadenceProbesAtIntervalAndSelfHeals() async throws {
        let clock = TestClock()
        let initial = ControllerFixture.quotaData()
        let recovered = ControllerFixture.quotaData(
            fetchedAt: ControllerFixture.fixedDate.addingTimeInterval(360)
        )
        let adapter = FakeProviderAdapter(
            id: .ark,
            capabilities: ControllerFixture.capabilities,
            discoveryResults: [.success(ControllerFixture.discovery())],
            readResults: [
                .success(initial),
                .failure(
                    ControllerFixture.failure(
                        retryClass: .never,
                        code: .schemaMismatch,
                        diagnosticCode: "ark.adapter.response.schema_mismatch"
                    )
                ),
                .success(recovered)
            ]
        )
        let cache = FakeProviderQuotaCache()
        let policy = RefreshPolicy(
            cadence: .automatic(interval: .seconds(300)),
            manualCooldown: .seconds(20),
            retryBackoff: [.seconds(60)],
            shutdownGrace: .seconds(2)
        )
        let (controller, scheduler) = try makeController(
            adapter: adapter,
            cache: cache,
            clock: clock,
            policy: policy
        )
        let startOutcome = await controller.send(.start)
        XCTAssertEqual(startOutcome, .completed)

        let failureOutcome = await controller.send(.refresh(.manual(scope: .provider)))
        XCTAssertEqual(failureOutcome, .completed)
        let scheduledToken = await scheduler.scheduledToken(
            for: RefreshScheduleKey(providerID: .ark, scope: .provider)
        )
        let token = try XCTUnwrap(
            scheduledToken,
            "A terminal read failure must keep a cadence probe scheduled"
        )
        XCTAssertEqual(token.reason, .automatic)
        let failedProjection = await controller.projection()
        XCTAssertEqual(
            failedProjection.state.refresh.gate,
            .backoff(until: token.deadline, attempt: 1)
        )
        XCTAssertEqual(failedProjection.state.failure?.code, .schemaMismatch)
        XCTAssertEqual(failedProjection.state.lastGood?.fetchedAt, initial.fetchedAt)

        let manualDuringProbe = await controller.send(.refresh(.manual(scope: .provider)))
        guard case .deferred = manualDuringProbe else {
            return XCTFail("Manual refresh during the probe window must defer, not suspend forever")
        }

        await clock.advance(to: token.deadline.nanoseconds)
        let probeHealed = await eventually {
            let projection = await controller.projection()
            return projection.state.lastGood?.fetchedAt == recovered.fetchedAt
        }
        XCTAssertTrue(probeHealed, "The cadence probe must retry the read at the interval")
        let healedProjection = await controller.projection()
        XCTAssertEqual(healedProjection.state.freshness, .fresh(asOf: recovered.fetchedAt))
        XCTAssertNil(healedProjection.state.failure)
        XCTAssertEqual(healedProjection.state.refresh.gate, .open)
        let resumedToken = await scheduler.scheduledToken(
            for: RefreshScheduleKey(providerID: .ark, scope: .provider)
        )
        XCTAssertEqual(resumedToken?.reason, .automatic)
    }

    func testTerminalDiscoveryFailureUnderAutomaticCadenceProbesRedetectAtInterval() async throws {
        let clock = TestClock()
        let initial = ControllerFixture.quotaData()
        let recovered = ControllerFixture.quotaData(
            fetchedAt: ControllerFixture.fixedDate.addingTimeInterval(360)
        )
        let adapter = FakeProviderAdapter(
            id: .ark,
            capabilities: ControllerFixture.capabilities,
            discoveryResults: [
                .success(ControllerFixture.discovery()),
                .failure(
                    ControllerFixture.failure(
                        retryClass: .never,
                        code: .schemaMismatch,
                        diagnosticCode: "ark.discovery.response.schema_mismatch"
                    )
                ),
                .success(ControllerFixture.discovery())
            ],
            readResults: [.success(initial), .success(recovered)]
        )
        let cache = FakeProviderQuotaCache()
        let policy = RefreshPolicy(
            cadence: .automatic(interval: .seconds(300)),
            manualCooldown: .seconds(20),
            retryBackoff: [.seconds(60)],
            shutdownGrace: .seconds(2)
        )
        let (controller, scheduler) = try makeController(
            adapter: adapter,
            cache: cache,
            clock: clock,
            policy: policy
        )
        let startOutcome = await controller.send(.start)
        XCTAssertEqual(startOutcome, .completed)

        let redetectOutcome = await controller.send(.redetect)
        XCTAssertEqual(redetectOutcome, .completed)
        let scheduledToken = await scheduler.scheduledToken(
            for: RefreshScheduleKey(providerID: .ark, scope: .provider)
        )
        let token = try XCTUnwrap(
            scheduledToken,
            "A terminal discovery failure must keep a redetect probe scheduled"
        )
        XCTAssertEqual(token.reason, .discoveryRetry(attempt: 1, initiatedBy: .manual))
        let failedProjection = await controller.projection()
        XCTAssertEqual(
            failedProjection.state.refresh.gate,
            .backoff(until: token.deadline, attempt: 1)
        )
        XCTAssertEqual(failedProjection.state.lastGood?.fetchedAt, initial.fetchedAt)

        await clock.advance(to: token.deadline.nanoseconds)
        let probeHealed = await eventually {
            let projection = await controller.projection()
            return projection.state.lastGood?.fetchedAt == recovered.fetchedAt
        }
        XCTAssertTrue(probeHealed, "The redetect probe must rediscover and read at the interval")
        let healedProjection = await controller.projection()
        XCTAssertEqual(healedProjection.state.freshness, .fresh(asOf: recovered.fetchedAt))
        XCTAssertNil(healedProjection.state.failure)
    }

    func testTerminalReadFailureUnderManualOnlyCadenceKeepsSuspendedGate() async throws {
        let clock = TestClock()
        let adapter = FakeProviderAdapter(
            id: .ark,
            capabilities: ControllerFixture.capabilities,
            discoveryResults: [.success(ControllerFixture.discovery())],
            readResults: [
                .failure(
                    ControllerFixture.failure(
                        retryClass: .never,
                        code: .schemaMismatch,
                        diagnosticCode: "ark.adapter.response.schema_mismatch"
                    )
                )
            ]
        )
        let cache = FakeProviderQuotaCache()
        let policy = RefreshPolicy(
            cadence: .manualOnly,
            manualCooldown: .seconds(20),
            retryBackoff: [.seconds(60)],
            shutdownGrace: .seconds(2)
        )
        let (controller, scheduler) = try makeController(
            adapter: adapter,
            cache: cache,
            clock: clock,
            policy: policy
        )
        _ = await controller.send(.start)

        let manualOutcome = await controller.send(.refresh(.manual(scope: .provider)))
        XCTAssertEqual(manualOutcome, .completed)

        let projection = await controller.projection()
        guard case .suspended = projection.state.refresh.gate else {
            return XCTFail("Manual-only cadence must keep the suspended gate for terminal failures")
        }
        XCTAssertEqual(projection.state.failure?.code, .schemaMismatch)
        let schedules = await scheduler.scheduledTokens(providerID: .ark)
        XCTAssertTrue(schedules.isEmpty)
    }

    func testRetryableSchemaPartialSchedulesBackoffInsteadOfPermanentSuspension() async throws {
        let clock = TestClock()
        let initialProduct = controllerProduct(
            sourceProductID: "codex",
            usedPercent: 20,
            fetchedAt: ControllerFixture.fixedDate
        )
        let retainedProduct = controllerProduct(
            sourceProductID: "spark",
            usedPercent: 1,
            fetchedAt: ControllerFixture.fixedDate
        )
        let initial = ProviderQuotaData(
            providerID: .ark,
            source: ControllerFixture.source(),
            fetchedAt: ControllerFixture.fixedDate,
            products: [initialProduct, retainedProduct],
            balances: [],
            resetEntitlements: []
        )
        let partialAt = ControllerFixture.fixedDate.addingTimeInterval(60)
        let failure = ControllerFixture.failure(
            retryClass: .backoff,
            code: .schemaMismatch,
            diagnosticCode: "openai.rate_limits.partial_schema"
        )
        let patch = ProviderQuotaPatch(
            providerID: .ark,
            source: ControllerFixture.source(),
            fetchedAt: partialAt,
            productMutations: [
                .replace(
                    controllerProduct(
                        sourceProductID: "codex",
                        usedPercent: 35,
                        fetchedAt: partialAt
                    )
                )
            ],
            balanceMutation: .retain,
            resetEntitlementMutation: .retain
        )
        let adapter = FakeProviderAdapter(
            id: .ark,
            capabilities: ControllerFixture.capabilities,
            discoveryResults: [.success(ControllerFixture.discovery())],
            readResults: [
                .success(initial),
                .partial(patch, failure)
            ]
        )
        let cache = FakeProviderQuotaCache()
        let policy = RefreshPolicy(
            cadence: .automatic(interval: .seconds(300)),
            manualCooldown: .seconds(20),
            retryBackoff: [.seconds(60)],
            shutdownGrace: .seconds(2)
        )
        let (controller, scheduler) = try makeController(
            adapter: adapter,
            cache: cache,
            clock: clock,
            policy: policy
        )
        let startOutcome = await controller.send(.start)
        XCTAssertEqual(startOutcome, .completed)
        let manualOutcome = await controller.send(.refresh(.manual(scope: .provider)))
        XCTAssertEqual(manualOutcome, .completed)

        let scheduledToken = await scheduler.scheduledToken(
            for: RefreshScheduleKey(providerID: .ark, scope: .provider)
        )
        let token = try XCTUnwrap(scheduledToken)
        XCTAssertEqual(token.reason, .refreshRetry(attempt: 1, initiatedBy: .manual))
        let projection = await controller.projection()
        XCTAssertEqual(
            projection.state.refresh.gate,
            .backoff(until: token.deadline, attempt: 1)
        )
        XCTAssertEqual(projection.state.scopedFailures.current?.failure, failure)
        let savedData = await cache.savedData
        XCTAssertEqual(savedData.count, 2)
        let persisted = try XCTUnwrap(savedData.last)
        XCTAssertEqual(persisted.fetchedAt, partialAt)
        XCTAssertEqual(persisted.products.map(\.sourceProductID), ["codex", "spark"])
        guard case let .percent(codexValue) = try XCTUnwrap(
            persisted.products.first { $0.sourceProductID == "codex" }?.metrics.first
        ).value else {
            return XCTFail("Expected persisted Codex percent")
        }
        XCTAssertEqual(codexValue.sourceValue, Decimal(35))
        guard case .stale = try XCTUnwrap(
            persisted.products.first { $0.sourceProductID == "spark" }
        ).state.freshness else {
            return XCTFail("The normalized cache must retain stale failed siblings")
        }
    }

    func testAgeTickIntentAgesRetainedFreshDataOnlyAfterTheFreshnessSLA() async throws {
        let clock = TestClock()
        let initial = ControllerFixture.quotaData(
            fetchedAt: ControllerFixture.fixedDate
        )
        let adapter = FakeProviderAdapter(
            id: .ark,
            capabilities: ControllerFixture.capabilities,
            discoveryResults: [.success(ControllerFixture.discovery())],
            readResults: [.success(initial)]
        )
        let cache = FakeProviderQuotaCache()
        // A long automatic interval keeps the scheduled read far outside the
        // test window, so the only freshness transitions come from ageTick.
        let policy = RefreshPolicy(
            cadence: .automatic(interval: .seconds(3_600)),
            manualCooldown: .seconds(20),
            retryBackoff: [.seconds(60)],
            shutdownGrace: .seconds(2)
        )
        let (controller, _) = try makeController(
            adapter: adapter,
            cache: cache,
            clock: clock,
            policy: policy
        )
        let startOutcome = await controller.send(.start)
        XCTAssertEqual(startOutcome, .completed)

        let freshProjection = await controller.projection()
        XCTAssertEqual(
            freshProjection.state.freshness,
            .fresh(asOf: ControllerFixture.fixedDate)
        )

        await clock.advance(by: .seconds(599))
        let beforeSLA = await controller.send(
            .ageTick(staleAfter: ProviderFreshnessSLA.staleAfter(frequency: .fiveMinutes))
        )
        XCTAssertEqual(beforeSLA, .completed)
        let stillFresh = await controller.projection()
        XCTAssertEqual(
            stillFresh.state.freshness,
            .fresh(asOf: ControllerFixture.fixedDate),
            "A snapshot younger than the SLA must not be aged by a tick"
        )

        await clock.advance(by: .seconds(2))
        let afterSLA = await controller.send(
            .ageTick(staleAfter: ProviderFreshnessSLA.staleAfter(frequency: .fiveMinutes))
        )
        XCTAssertEqual(afterSLA, .completed)
        let aged = await controller.projection()
        guard case let .stale(asOf, evaluatedAt) = aged.state.freshness else {
            return XCTFail("A retained snapshot past the SLA must become stale")
        }
        XCTAssertEqual(asOf, ControllerFixture.fixedDate)
        XCTAssertEqual(
            evaluatedAt,
            ControllerFixture.fixedDate.addingTimeInterval(601),
            "Aging must use the controller clock, not wall-clock Date()"
        )
        XCTAssertEqual(
            aged.state.lastGood?.fetchedAt,
            ControllerFixture.fixedDate,
            "Aging must keep the retained last-good payload intact"
        )
    }

    func testImmediateRetryCannotRaceTheFailureCommitAndBeMistakenForAJoin() async throws {
        let clock = TestClock()
        let initial = ControllerFixture.quotaData()
        let recovered = ControllerFixture.quotaData(
            fetchedAt: ControllerFixture.fixedDate.addingTimeInterval(1)
        )
        let adapter = FakeProviderAdapter(
            id: .ark,
            capabilities: ControllerFixture.capabilities,
            discoveryResults: [.success(ControllerFixture.discovery())],
            readResults: [
                .success(initial),
                .failure(ControllerFixture.failure(retryClass: .immediate)),
                .success(recovered)
            ]
        )
        let cache = FakeProviderQuotaCache()
        let (controller, _) = try makeController(
            adapter: adapter,
            cache: cache,
            clock: clock
        )
        let startOutcome = await controller.send(.start)
        XCTAssertEqual(startOutcome, .completed)

        let failureOutcome = await controller.send(.refresh(.manual(scope: .provider)))
        XCTAssertEqual(failureOutcome, .completed)
        let retryCommitted = await eventually {
            let scopes = await adapter.readScopes
            let projection = await controller.projection()
            return scopes.count == 3
                && projection.state.lastGood?.fetchedAt == recovered.fetchedAt
        }
        XCTAssertTrue(retryCommitted)
    }

    func testManualOnlyAllowsManualReadButToggleOnOnlyRedetectsRetainedStaleData() async throws {
        let clock = TestClock()
        let live = ControllerFixture.quotaData()
        let adapter = FakeProviderAdapter(
            id: .ark,
            capabilities: ControllerFixture.capabilities,
            discoveryResults: [
                .success(ControllerFixture.discovery()),
                .success(ControllerFixture.discovery())
            ],
            readResults: [.success(live)]
        )
        let cache = FakeProviderQuotaCache()
        let manualOnly = RefreshPolicy(
            cadence: .manualOnly,
            manualCooldown: .seconds(20),
            retryBackoff: [.seconds(60)],
            shutdownGrace: .seconds(2)
        )
        let (controller, _) = try makeController(
            adapter: adapter,
            cache: cache,
            clock: clock,
            policy: manualOnly
        )

        let startOutcome = await controller.send(.start)
        XCTAssertEqual(startOutcome, .deferred(.suspend(.manualOnly)))
        let startupReadScopes = await adapter.readScopes
        XCTAssertTrue(startupReadScopes.isEmpty)
        let manualOutcome = await controller.send(.refresh(.manual(scope: .provider)))
        XCTAssertEqual(manualOutcome, .completed)
        let cooldown = await controller.send(.refresh(.manual(scope: .provider)))
        guard case .deferred(.cooldown) = cooldown else {
            return XCTFail("A second manual request must observe manual cooldown")
        }

        let disableOutcome = await controller.send(.setEnabled(false))
        XCTAssertEqual(disableOutcome, .completed)
        let enableOutcome = await controller.send(.setEnabled(true))
        XCTAssertEqual(enableOutcome, .deferred(.suspend(.manualOnly)))
        let projection = await controller.projection()
        XCTAssertTrue(projection.isEnabled)
        XCTAssertEqual(projection.state.lastGood?.fetchedAt, live.fetchedAt)
        guard case .stale = projection.state.freshness else {
            return XCTFail("Toggle ON must expose retained data as stale before/after redetect")
        }
        let finalReadScopes = await adapter.readScopes
        let discoverCount = await adapter.discoverCallCount
        let shutdownCount = await adapter.shutdownCallCount
        XCTAssertEqual(finalReadScopes.count, 1)
        XCTAssertEqual(discoverCount, 2)
        XCTAssertEqual(shutdownCount, 0)
    }

    func testAutomaticToManualPolicyUpdateCancelsRetryAndPreservesProviderState() async throws {
        let clock = TestClock()
        let initial = ControllerFixture.quotaData()
        let adapter = FakeProviderAdapter(
            id: .ark,
            capabilities: ControllerFixture.capabilities,
            discoveryResults: [.success(ControllerFixture.discovery())],
            readResults: [
                .success(initial),
                .failure(ControllerFixture.failure(retryClass: .backoff))
            ]
        )
        let cache = FakeProviderQuotaCache()
        let (controller, scheduler) = try makeController(
            adapter: adapter,
            cache: cache,
            clock: clock
        )
        let startOutcome = await controller.send(.start)
        XCTAssertEqual(startOutcome, .completed)

        let failureOutcome = await controller.send(
            .refresh(.manual(scope: .provider))
        )
        XCTAssertEqual(failureOutcome, .completed)
        let retry = await scheduler.scheduledToken(
            for: RefreshScheduleKey(providerID: .ark, scope: .provider)
        )
        XCTAssertEqual(
            retry?.reason,
            .refreshRetry(attempt: 1, initiatedBy: .manual)
        )
        let beforeUpdate = await controller.projection()

        let manualPolicy = ProviderRefreshPolicyResolver.policy(
            providerID: .ark,
            globalFrequency: .manualOnly,
            override: .followGlobal
        )
        let policyOutcome = await controller.send(.setRefreshPolicy(manualPolicy))
        XCTAssertEqual(policyOutcome, .completed)

        let afterUpdate = await controller.projection()
        XCTAssertEqual(afterUpdate.state.authentication, beforeUpdate.state.authentication)
        XCTAssertEqual(afterUpdate.state.presence, beforeUpdate.state.presence)
        XCTAssertEqual(afterUpdate.state.lastGood, beforeUpdate.state.lastGood)
        XCTAssertEqual(afterUpdate.state.refresh.gate, .open)
        let schedulesAfterUpdate = await scheduler.scheduledTokens(providerID: .ark)
        XCTAssertTrue(schedulesAfterUpdate.isEmpty)

        if let retry {
            await clock.advance(to: retry.deadline.nanoseconds)
            await Task.yield()
        }
        let readScopes = await adapter.readScopes
        XCTAssertEqual(readScopes.count, 2)
    }

    func testManualToAutomaticPolicyUpdateSchedulesNewCadenceWithoutDuplicates() async throws {
        let clock = TestClock()
        let refreshed = ControllerFixture.quotaData(
            fetchedAt: ControllerFixture.fixedDate.addingTimeInterval(60)
        )
        let adapter = FakeProviderAdapter(
            id: .ark,
            capabilities: ControllerFixture.capabilities,
            discoveryResults: [.success(ControllerFixture.discovery())],
            readResults: [.success(refreshed)]
        )
        let cache = FakeProviderQuotaCache()
        let manualPolicy = ProviderRefreshPolicyResolver.policy(
            providerID: .ark,
            globalFrequency: .manualOnly,
            override: .followGlobal
        )
        let (controller, scheduler) = try makeController(
            adapter: adapter,
            cache: cache,
            clock: clock,
            policy: manualPolicy
        )
        let startOutcome = await controller.send(.start)
        XCTAssertEqual(startOutcome, .deferred(.suspend(.manualOnly)))
        let initialSchedules = await scheduler.scheduledTokens(providerID: .ark)
        XCTAssertTrue(initialSchedules.isEmpty)

        let automaticPolicy = ProviderRefreshPolicyResolver.policy(
            providerID: .ark,
            globalFrequency: .oneMinute,
            override: .followGlobal
        )
        let policyOutcome = await controller.send(.setRefreshPolicy(automaticPolicy))
        XCTAssertEqual(policyOutcome, .completed)
        let firstSchedules = await scheduler.scheduledTokens(providerID: .ark)
        let firstToken = try XCTUnwrap(firstSchedules.first)
        XCTAssertEqual(firstSchedules.count, 1)
        XCTAssertEqual(firstToken.reason, .automatic)
        XCTAssertEqual(firstToken.deadline.nanoseconds, 60_000_000_000)

        await clock.advance(to: firstToken.deadline.nanoseconds)
        let readCompleted = await eventually {
            let projection = await controller.projection()
            return projection.state.lastGood?.fetchedAt == refreshed.fetchedAt
        }
        XCTAssertTrue(readCompleted)

        let rearmedSchedules = await scheduler.scheduledTokens(providerID: .ark)
        XCTAssertEqual(rearmedSchedules.count, 1)
        XCTAssertEqual(rearmedSchedules.first?.reason, .automatic)
        XCTAssertEqual(
            rearmedSchedules.first?.deadline.nanoseconds,
            120_000_000_000
        )
    }

    func testPolicyUpdateDoesNotCancelInFlightReadOrRearmManualOnlyTimer() async throws {
        let clock = TestClock()
        let initial = ControllerFixture.quotaData()
        let updated = ControllerFixture.quotaData(
            fetchedAt: ControllerFixture.fixedDate.addingTimeInterval(30)
        )
        let adapter = FakeProviderAdapter(
            id: .ark,
            capabilities: ControllerFixture.capabilities,
            discoveryResults: [.success(ControllerFixture.discovery())],
            readResults: [.success(initial)]
        )
        let cache = FakeProviderQuotaCache()
        let (controller, scheduler) = try makeController(
            adapter: adapter,
            cache: cache,
            clock: clock
        )
        let startOutcome = await controller.send(.start)
        XCTAssertEqual(startOutcome, .completed)
        let beforeRead = await controller.projection()

        await adapter.blockNextRead()
        let readTask = Task {
            await controller.send(.refresh(.manual(scope: .provider)))
        }
        await adapter.waitUntilReadIsBlocked()
        let readCount = await adapter.readScopes.count
        XCTAssertEqual(readCount, 2)

        let manualPolicy = ProviderRefreshPolicyResolver.policy(
            providerID: .ark,
            globalFrequency: .manualOnly,
            override: .followGlobal
        )
        let policyOutcome = await controller.send(.setRefreshPolicy(manualPolicy))
        XCTAssertEqual(policyOutcome, .completed)
        await adapter.resumeRead(with: .success(updated))
        let readOutcome = await readTask.value
        XCTAssertEqual(readOutcome, .completed)

        let afterRead = await controller.projection()
        XCTAssertEqual(afterRead.state.lastGood, updated)
        XCTAssertEqual(afterRead.state.authentication, beforeRead.state.authentication)
        XCTAssertEqual(afterRead.state.presence, beforeRead.state.presence)
        let schedules = await scheduler.scheduledTokens(providerID: .ark)
        XCTAssertTrue(schedules.isEmpty)
    }

    func testRefreshPolicyResolverHonorsOverrideDefaultAndProviderCooldowns() {
        XCTAssertEqual(
            ProviderRefreshFrequency.validated(storedSeconds: -99),
            .fiveMinutes
        )
        XCTAssertEqual(
            ProviderRefreshOverride.validated(storedSeconds: -1),
            .followGlobal
        )
        XCTAssertEqual(
            ProviderRefreshOverride.validated(storedSeconds: 42),
            .followGlobal
        )

        let followGlobal = ProviderRefreshPolicyResolver.policy(
            providerID: .openAI,
            globalFrequency: .fifteenMinutes,
            override: .followGlobal
        )
        XCTAssertEqual(followGlobal.cadence, .automatic(interval: .seconds(900)))
        XCTAssertEqual(followGlobal.manualCooldown, .seconds(20))

        let arkOverride = ProviderRefreshPolicyResolver.policy(
            providerID: .ark,
            globalFrequency: .thirtyMinutes,
            override: .frequency(.manualOnly)
        )
        XCTAssertEqual(arkOverride.cadence, .manualOnly)
        XCTAssertEqual(arkOverride.manualCooldown, .seconds(30))

        let miniMaxOverride = ProviderRefreshPolicyResolver.policy(
            providerID: .miniMax,
            globalFrequency: .manualOnly,
            override: .frequency(.oneMinute)
        )
        XCTAssertEqual(miniMaxOverride.cadence, .automatic(interval: .seconds(60)))
        XCTAssertEqual(miniMaxOverride.manualCooldown, .seconds(20))
    }

    func testLoginSuccessClearsGateThenRedetectsAndOnlyReadSuccessBecomesFresh() async throws {
        let clock = TestClock()
        let authEvidence = AuthenticationEvidence(
            authority: .providerReport(
                sourceField: "fake.requires-login",
                contractVersion: "provider-contract-v0.8"
            ),
            observedAt: ControllerFixture.fixedDate
        )
        let requiresLogin = ControllerFixture.discovery(
            connection: .requiresLogin(authEvidence)
        )
        let recovered = ControllerFixture.quotaData(
            fetchedAt: ControllerFixture.fixedDate.addingTimeInterval(30)
        )
        let recorder = TestCallRecorder()
        let adapter = FakeProviderAdapter(
            id: .ark,
            capabilities: ControllerFixture.capabilities,
            recorder: recorder,
            discoveryResults: [
                .success(requiresLogin),
                .success(ControllerFixture.discovery())
            ],
            loginResults: [.success]
        )
        let cache = FakeProviderQuotaCache(recorder: recorder)
        let manualOnly = RefreshPolicy(
            cadence: .manualOnly,
            manualCooldown: .seconds(20),
            retryBackoff: [.seconds(60)],
            shutdownGrace: .seconds(2)
        )
        let (controller, _) = try makeController(
            adapter: adapter,
            cache: cache,
            clock: clock,
            policy: manualOnly
        )
        let startOutcome = await controller.send(.start)
        XCTAssertEqual(startOutcome, .completed)
        let gated = await controller.projection()
        XCTAssertNil(gated.state.refresh.lastSuccessAt)
        XCTAssertEqual(gated.state.freshness, .unknown)
        guard case .suspended = gated.state.refresh.gate else {
            return XCTFail("A requires-login discovery must suspend reads")
        }

        await adapter.blockNextRead()
        let loginTask = Task { await controller.send(.login) }
        await adapter.waitUntilReadIsBlocked()
        let recoveryReadScopes = await adapter.readScopes
        XCTAssertEqual(
            recoveryReadScopes,
            [.provider],
            "The post-login recovery read must start"
        )
        let beforeReadCompletes = await controller.projection()
        XCTAssertNil(beforeReadCompletes.state.refresh.lastSuccessAt)
        XCTAssertEqual(beforeReadCompletes.state.freshness, .unknown)

        await adapter.resumeRead(with: .success(recovered))
        let loginOutcome = await loginTask.value
        XCTAssertEqual(loginOutcome, .completed)
        let final = await controller.projection()
        XCTAssertEqual(final.state.refresh.lastSuccessAt, ControllerFixture.fixedDate)
        XCTAssertEqual(final.state.freshness, .fresh(asOf: recovered.fetchedAt))
        let order = await recorder.entries()
        XCTAssertEqual(
            order,
            [
                "cache.load",
                "adapter.discover",
                "adapter.login",
                "adapter.discover",
                "adapter.read",
                "cache.save"
            ]
        )
    }

    func testLoginRateLimitKeepsDiscoveryProbeAndExternalRecoveryClearsFailure() async throws {
        let clock = TestClock()
        let authEvidence = AuthenticationEvidence(
            authority: .providerReport(
                sourceField: "fake.requires-login",
                contractVersion: "provider-contract-v0.8"
            ),
            observedAt: ControllerFixture.fixedDate
        )
        let requiresLogin = ControllerFixture.discovery(
            connection: .requiresLogin(authEvidence)
        )
        let recovered = ControllerFixture.quotaData(
            fetchedAt: ControllerFixture.fixedDate.addingTimeInterval(60)
        )
        let rateLimited = ProviderFailure(
            code: .rateLimited,
            retryClass: .backoff,
            userMessageKey: "provider.failure.login-rate-limited",
            diagnosticCode: "ark.adapter.login.rate_limited",
            recovery: .retry
        )
        let adapter = FakeProviderAdapter(
            id: .ark,
            capabilities: ControllerFixture.capabilities,
            discoveryResults: [
                .success(requiresLogin),
                .success(ControllerFixture.discovery())
            ],
            readResults: [.success(recovered)],
            loginResults: [.failure(rateLimited)]
        )
        let cache = FakeProviderQuotaCache()
        let policy = RefreshPolicy(
            cadence: .automatic(interval: .seconds(60)),
            manualCooldown: .seconds(20),
            retryBackoff: [.seconds(60)],
            shutdownGrace: .seconds(2)
        )
        let (controller, scheduler) = try makeController(
            adapter: adapter,
            cache: cache,
            clock: clock,
            policy: policy
        )

        let startOutcome = await controller.send(.start)
        let loginOutcome = await controller.send(.login)
        XCTAssertEqual(startOutcome, .completed)
        XCTAssertEqual(loginOutcome, .completed)
        let failed = await controller.projection()
        XCTAssertEqual(
            failed.state.scopedFailures.failure(for: .login)?.code,
            .rateLimited
        )
        let scheduledToken = await scheduler.scheduledToken(
            for: RefreshScheduleKey(providerID: .ark, scope: .provider)
        )
        let scheduled = try XCTUnwrap(scheduledToken)
        XCTAssertEqual(
            scheduled.reason,
            .discoveryRetry(attempt: 1, initiatedBy: .recovery)
        )
        XCTAssertEqual(
            scheduled.deadline.nanoseconds,
            RefreshDuration.seconds(15 * 60).nanoseconds,
            "Ark authentication recovery must not inherit the 60-second quota cadence"
        )
        XCTAssertEqual(
            failed.state.refresh.gate,
            .backoff(until: scheduled.deadline, attempt: 1)
        )

        await clock.waitUntilSleepIsRegistered(until: scheduled.deadline)
        await clock.advance(to: scheduled.deadline.nanoseconds)
        let didRecover = await eventually {
            let projection = await controller.projection()
            return projection.state.freshness == .fresh(asOf: recovered.fetchedAt)
        }
        XCTAssertTrue(didRecover)
        let final = await controller.projection()
        XCTAssertNil(final.state.scopedFailures.failure(for: .login))
        XCTAssertEqual(
            final.state.connection,
            .connected(observedAt: ControllerFixture.fixedDate)
        )
        let loginMethods = await adapter.loginMethods
        XCTAssertEqual(loginMethods, [.sso])
    }

    func testWarningLoginRateLimitKeepsUsableQuotaRefreshOpen() async throws {
        let warningEvidence = AuthenticationEvidence(
            authority: .providerReport(
                sourceField: "fake.expires-soon",
                contractVersion: "provider-contract-v0.8"
            ),
            observedAt: ControllerFixture.fixedDate,
            expiresAt: ControllerFixture.fixedDate.addingTimeInterval(3_600)
        )
        let healthyEvidence = AuthenticationEvidence(
            authority: .providerReport(
                sourceField: "fake.renewed",
                contractVersion: "provider-contract-v0.8"
            ),
            observedAt: ControllerFixture.fixedDate.addingTimeInterval(60),
            expiresAt: ControllerFixture.fixedDate.addingTimeInterval(172_800)
        )
        let baseDiscovery = ControllerFixture.discovery()
        let warningDiscovery = SuccessfulProviderDiscovery(
            providerID: baseDiscovery.providerID,
            authority: baseDiscovery.authority,
            observedAt: baseDiscovery.observedAt,
            connection: .connected,
            authentication: .warning(warningEvidence),
            presence: baseDiscovery.presence
        )
        let rateLimited = ProviderFailure(
            code: .rateLimited,
            retryClass: .backoff,
            userMessageKey: "provider.failure.login-rate-limited",
            diagnosticCode: "ark.adapter.login.rate_limited",
            recovery: .retry
        )
        let adapter = FakeProviderAdapter(
            id: .ark,
            capabilities: ControllerFixture.capabilities,
            discoveryResults: [.success(warningDiscovery)],
            readResults: [
                .success(ControllerFixture.quotaData()),
                .success(
                    ControllerFixture.quotaData(
                        fetchedAt: ControllerFixture.fixedDate.addingTimeInterval(60)
                    )
                )
            ],
            loginResults: [.failure(rateLimited)]
        )
        let (controller, _) = try makeController(
            adapter: adapter,
            cache: FakeProviderQuotaCache(),
            clock: TestClock(),
            policy: RefreshPolicy(
                cadence: .manualOnly,
                manualCooldown: .seconds(20),
                retryBackoff: [.seconds(60)],
                shutdownGrace: .seconds(2)
            )
        )

        let startOutcome = await controller.send(.start)
        let loginOutcome = await controller.send(.login)
        XCTAssertEqual(
            startOutcome,
            .deferred(.suspend(.manualOnly))
        )
        XCTAssertEqual(loginOutcome, .completed)
        var projection = await controller.projection()
        XCTAssertEqual(projection.state.refresh.gate, .open)
        XCTAssertEqual(
            projection.state.scopedFailures.failure(for: .login)?.code,
            .rateLimited
        )

        await adapter.setReadAuthentication(.healthy(healthyEvidence))
        let refreshOutcome = await controller.send(.refresh(.manual(scope: .provider)))
        XCTAssertEqual(refreshOutcome, .completed)
        projection = await controller.projection()
        XCTAssertEqual(projection.state.authentication, .healthy(healthyEvidence))
        XCTAssertNil(projection.state.scopedFailures.failure(for: .login))
        let readScopes = await adapter.readScopes
        XCTAssertEqual(readScopes, [.provider])
    }

    func testWarningLoginRateLimitPreservesAutomaticQuotaCadence() async throws {
        let clock = TestClock()
        let warningEvidence = AuthenticationEvidence(
            authority: .providerReport(
                sourceField: "fake.expires-soon",
                contractVersion: "provider-contract-v0.8"
            ),
            observedAt: ControllerFixture.fixedDate,
            expiresAt: ControllerFixture.fixedDate.addingTimeInterval(3_600)
        )
        let baseDiscovery = ControllerFixture.discovery()
        let warningDiscovery = SuccessfulProviderDiscovery(
            providerID: baseDiscovery.providerID,
            authority: baseDiscovery.authority,
            observedAt: baseDiscovery.observedAt,
            connection: .connected,
            authentication: .warning(warningEvidence),
            presence: baseDiscovery.presence
        )
        let rateLimited = ProviderFailure(
            code: .rateLimited,
            retryClass: .backoff,
            userMessageKey: "provider.failure.login-rate-limited",
            diagnosticCode: "ark.adapter.login.rate_limited",
            recovery: .retry
        )
        let adapter = FakeProviderAdapter(
            id: .ark,
            capabilities: ControllerFixture.capabilities,
            discoveryResults: [.success(warningDiscovery)],
            readResults: [
                .success(ControllerFixture.quotaData()),
                .success(
                    ControllerFixture.quotaData(
                        fetchedAt: ControllerFixture.fixedDate.addingTimeInterval(60)
                    )
                )
            ],
            loginResults: [.failure(rateLimited)]
        )
        let cache = FakeProviderQuotaCache()
        let (controller, scheduler) = try makeController(
            adapter: adapter,
            cache: cache,
            clock: clock,
            policy: RefreshPolicy(
                cadence: .automatic(interval: .seconds(60)),
                manualCooldown: .seconds(20),
                retryBackoff: [.seconds(60)],
                shutdownGrace: .seconds(2)
            )
        )

        let startOutcome = await controller.send(.start)
        let loginOutcome = await controller.send(.login)
        XCTAssertEqual(startOutcome, .completed)
        XCTAssertEqual(loginOutcome, .completed)
        let scheduledToken = await scheduler.scheduledToken(
            for: RefreshScheduleKey(providerID: .ark, scope: .provider)
        )
        let scheduled = try XCTUnwrap(scheduledToken)
        XCTAssertEqual(scheduled.reason, .automatic)
        XCTAssertEqual(
            scheduled.deadline.nanoseconds,
            RefreshDuration.seconds(60).nanoseconds,
            "A failed proactive login must not replace usable quota refresh with the auth cooldown"
        )

        await clock.waitUntilSleepIsRegistered(until: scheduled.deadline)
        await clock.advance(to: scheduled.deadline.nanoseconds)
        await cache.waitUntilSaveCount(2)
        let readScopes = await adapter.readScopes
        XCTAssertEqual(readScopes, [.provider, .provider])
        let invalidations = await adapter.authenticationCacheInvalidationCount
        XCTAssertEqual(invalidations, 0, "Automatic quota reads must retain the auth cache")
    }

    func testArkReadAuthenticationFailureKeepsFifteenMinuteDiscoveryFloor() async throws {
        let clock = TestClock()
        let expired = AuthenticationState.expired(
            AuthenticationExpiryEvidence(
                authority: .explicitExpiration(
                    sourceField: "identity_store.refresh_token.exp",
                    contractVersion: ControllerFixture.capabilities.contractVersion
                ),
                observedAt: ControllerFixture.fixedDate
            )
        )
        let authenticationFailure = ProviderFailure(
            code: .authenticationExpired,
            retryClass: .afterRecovery,
            userMessageKey: "provider.failure.authentication-expired",
            diagnosticCode: "ark.adapter.process.auth_expired",
            recovery: .login(.sso)
        )
        let probeFailure = ProviderFailure(
            code: .networkUnavailable,
            retryClass: .backoff,
            userMessageKey: "provider.failure.network",
            diagnosticCode: "ark.auth-status.child.networkUnavailable",
            recovery: .retry
        )
        let adapter = FakeProviderAdapter(
            id: .ark,
            capabilities: ControllerFixture.capabilities,
            discoveryResults: [
                .success(ControllerFixture.discovery()),
                .failure(probeFailure)
            ],
            readResults: [
                .success(ControllerFixture.quotaData()),
                .failure(authenticationFailure)
            ]
        )
        let (controller, scheduler) = try makeController(
            adapter: adapter,
            cache: FakeProviderQuotaCache(),
            clock: clock,
            policy: RefreshPolicy(
                cadence: .automatic(interval: .seconds(60)),
                manualCooldown: .seconds(20),
                retryBackoff: [.seconds(60)],
                shutdownGrace: .seconds(2)
            )
        )

        let startOutcome = await controller.send(.start)
        XCTAssertEqual(startOutcome, .completed)
        await adapter.setReadAuthentication(expired)
        let refreshOutcome = await controller.send(.refresh(.manual(scope: .provider)))
        XCTAssertEqual(refreshOutcome, .completed)
        let firstToken = await scheduler.scheduledToken(
            for: RefreshScheduleKey(providerID: .ark, scope: .provider)
        )
        let first = try XCTUnwrap(firstToken)
        XCTAssertEqual(first.reason, .discoveryRetry(attempt: 1, initiatedBy: .manual))
        XCTAssertEqual(first.deadline.nanoseconds, RefreshDuration.seconds(15 * 60).nanoseconds)
        let failedRead = await controller.projection()
        XCTAssertEqual(failedRead.state.failure?.code, .authenticationExpired)
        XCTAssertEqual(failedRead.state.authentication, expired)

        await clock.waitUntilSleepIsRegistered(until: first.deadline)
        await clock.advance(to: first.deadline.nanoseconds)
        let secondDeadline = MonotonicInstant(
            nanoseconds: RefreshDuration.seconds(30 * 60).nanoseconds
        )
        await clock.waitUntilSleepIsRegistered(until: secondDeadline)
        let secondToken = await scheduler.scheduledToken(
            for: RefreshScheduleKey(providerID: .ark, scope: .provider)
        )
        let second = try XCTUnwrap(secondToken)
        XCTAssertEqual(second.reason, .discoveryRetry(attempt: 1, initiatedBy: .manual))
        XCTAssertEqual(second.deadline, secondDeadline)
        let discoveryCalls = await adapter.discoverCallCount
        XCTAssertEqual(discoveryCalls, 2)
        let invalidations = await adapter.authenticationCacheInvalidationCount
        XCTAssertEqual(
            invalidations,
            1,
            "Only the direct manual action may invalidate; its scheduled retry must keep the cache"
        )
    }

    func testScheduledRetryFromManualReadDoesNotInvalidateAuthenticationAgain() async throws {
        let clock = TestClock()
        let recovered = ControllerFixture.quotaData(
            fetchedAt: ControllerFixture.fixedDate.addingTimeInterval(60)
        )
        let transientFailure = ProviderFailure(
            code: .networkUnavailable,
            retryClass: .backoff,
            userMessageKey: "provider.failure.network",
            diagnosticCode: "ark.adapter.child.networkUnavailable",
            recovery: .retry
        )
        let adapter = FakeProviderAdapter(
            id: .ark,
            capabilities: ControllerFixture.capabilities,
            discoveryResults: [.success(ControllerFixture.discovery())],
            readResults: [
                .success(ControllerFixture.quotaData()),
                .failure(transientFailure),
                .success(recovered)
            ]
        )
        let cache = FakeProviderQuotaCache()
        let (controller, scheduler) = try makeController(
            adapter: adapter,
            cache: cache,
            clock: clock,
            policy: RefreshPolicy(
                cadence: .automatic(interval: .seconds(60)),
                manualCooldown: .seconds(20),
                retryBackoff: [.seconds(60)],
                shutdownGrace: .seconds(2)
            )
        )

        let startOutcome = await controller.send(.start)
        XCTAssertEqual(startOutcome, .completed)
        let refreshOutcome = await controller.send(.refresh(.manual(scope: .provider)))
        XCTAssertEqual(refreshOutcome, .completed)
        let retryToken = await scheduler.scheduledToken(
            for: RefreshScheduleKey(providerID: .ark, scope: .provider)
        )
        let retry = try XCTUnwrap(retryToken)
        XCTAssertEqual(retry.reason, .refreshRetry(attempt: 1, initiatedBy: .manual))
        XCTAssertEqual(retry.deadline.nanoseconds, RefreshDuration.seconds(60).nanoseconds)

        await clock.waitUntilSleepIsRegistered(until: retry.deadline)
        await clock.advance(to: retry.deadline.nanoseconds)
        await cache.waitUntilSaveCount(2)
        let invalidations = await adapter.authenticationCacheInvalidationCount
        XCTAssertEqual(invalidations, 1)
    }

    func testPolicyChangeKeepsConnectedArkAuthenticationFailureOnDiscoveryLane() async throws {
        let clock = TestClock()
        let expired = AuthenticationState.expired(
            AuthenticationExpiryEvidence(
                authority: .explicitExpiration(
                    sourceField: "identity_store.refresh_token.exp",
                    contractVersion: ControllerFixture.capabilities.contractVersion
                ),
                observedAt: ControllerFixture.fixedDate
            )
        )
        let authenticationFailure = ProviderFailure(
            code: .authenticationExpired,
            retryClass: .afterRecovery,
            userMessageKey: "provider.failure.authentication-expired",
            diagnosticCode: "ark.adapter.process.auth_expired",
            recovery: .login(.sso)
        )
        let adapter = FakeProviderAdapter(
            id: .ark,
            capabilities: ControllerFixture.capabilities,
            discoveryResults: [.success(ControllerFixture.discovery())],
            readResults: [
                .success(ControllerFixture.quotaData()),
                .failure(authenticationFailure)
            ]
        )
        let (controller, scheduler) = try makeController(
            adapter: adapter,
            cache: FakeProviderQuotaCache(),
            clock: clock,
            policy: RefreshPolicy(
                cadence: .automatic(interval: .seconds(60)),
                manualCooldown: .seconds(20),
                retryBackoff: [.seconds(60)],
                shutdownGrace: .seconds(2)
            )
        )

        let startOutcome = await controller.send(.start)
        XCTAssertEqual(startOutcome, .completed)
        await adapter.setReadAuthentication(expired)
        let refreshOutcome = await controller.send(.refresh(.manual(scope: .provider)))
        XCTAssertEqual(refreshOutcome, .completed)
        let policyOutcome = await controller.send(.setRefreshPolicy(
            RefreshPolicy(
                cadence: .automatic(interval: .seconds(120)),
                manualCooldown: .seconds(20),
                retryBackoff: [.seconds(60)],
                shutdownGrace: .seconds(2)
            )
        ))
        XCTAssertEqual(policyOutcome, .completed)

        let tokenValue = await scheduler.scheduledToken(
            for: RefreshScheduleKey(providerID: .ark, scope: .provider)
        )
        let token = try XCTUnwrap(tokenValue)
        XCTAssertEqual(token.reason, .discoveryRetry(attempt: 1, initiatedBy: .scheduled))
        XCTAssertEqual(token.deadline.nanoseconds, RefreshDuration.seconds(15 * 60).nanoseconds)
        let invalidations = await adapter.authenticationCacheInvalidationCount
        XCTAssertEqual(invalidations, 1)
    }

    func testAuthenticationWarningAllowsProactiveSSOAndCoalescesUntilVerified() async throws {
        let healthyDiscovery = ControllerFixture.discovery()
        let evidence = AuthenticationEvidence(
            authority: .providerReport(
                sourceField: "fake.expires-soon",
                contractVersion: "provider-contract-v0.8"
            ),
            observedAt: ControllerFixture.fixedDate
        )
        let warningDiscovery = SuccessfulProviderDiscovery(
            providerID: healthyDiscovery.providerID,
            authority: healthyDiscovery.authority,
            observedAt: healthyDiscovery.observedAt,
            connection: .connected,
            authentication: .warning(evidence),
            presence: healthyDiscovery.presence
        )
        let original = ControllerFixture.quotaData()
        let recovered = ControllerFixture.quotaData(
            fetchedAt: ControllerFixture.fixedDate.addingTimeInterval(30)
        )
        let recorder = TestCallRecorder()
        let adapter = FakeProviderAdapter(
            id: .ark,
            capabilities: ControllerFixture.capabilities,
            recorder: recorder,
            discoveryResults: [.success(warningDiscovery), .success(healthyDiscovery)],
            readResults: [.success(original)]
        )
        let (controller, _) = try makeController(
            adapter: adapter,
            cache: FakeProviderQuotaCache(recorder: recorder),
            clock: TestClock()
        )
        let startOutcome = await controller.send(.start)
        XCTAssertEqual(startOutcome, .completed)
        let beforeLogin = await controller.projection()
        XCTAssertEqual(beforeLogin.state.authentication, .warning(evidence))
        XCTAssertEqual(beforeLogin.state.freshness, .fresh(asOf: original.fetchedAt))
        guard case .connected = beforeLogin.state.connection else {
            return XCTFail("Proactive authorization must start before the session expires")
        }

        await adapter.blockNextLogin()
        let loginTask = Task { await controller.send(.login) }
        await adapter.waitUntilLoginIsBlocked()
        let duringLogin = await controller.projection()
        guard case .loggingIn = duringLogin.state.refresh.activity else {
            return XCTFail("Proactive authorization must expose the cancellable login activity")
        }
        XCTAssertEqual(duringLogin.state.authentication, .warning(evidence))
        let duplicateLogin = await controller.send(.login)
        guard case .joined = duplicateLogin else {
            return XCTFail("Repeated clicks must not start another SSO process")
        }

        await adapter.blockNextRead()
        await adapter.resumeLogin(with: .success)
        await adapter.waitUntilReadIsBlocked()
        let duplicateVerification = await controller.send(.login)
        guard case .joined = duplicateVerification else {
            return XCTFail("The same login must remain in flight through quota verification")
        }
        await adapter.resumeRead(with: .success(recovered))

        let loginOutcome = await loginTask.value
        XCTAssertEqual(loginOutcome, .completed)
        let final = await controller.projection()
        XCTAssertEqual(final.state.authentication, healthyDiscovery.authentication)
        XCTAssertEqual(final.state.freshness, .fresh(asOf: recovered.fetchedAt))
        let methods = await adapter.loginMethods
        XCTAssertEqual(methods, [.sso])
        let order = await recorder.entries()
        XCTAssertEqual(order, [
            "cache.load", "adapter.discover", "adapter.read", "cache.save",
            "adapter.login", "adapter.discover", "adapter.read", "cache.save"
        ])
    }

    func testManualRefreshRechecksArkWarningAfterExternalAuthorization() async throws {
        try await checkArkWarningRecovery(automatic: false)
    }

    func testAutomaticRefreshRechecksArkWarningAfterExternalAuthorization() async throws {
        try await checkArkWarningRecovery(automatic: true)
    }

    private func checkArkWarningRecovery(automatic: Bool) async throws {
        let healthy = ControllerFixture.discovery()
        let evidence = AuthenticationEvidence(
            authority: .providerReport(
                sourceField: "fake.session-warning",
                contractVersion: "provider-contract-v0.8"
            ),
            observedAt: ControllerFixture.fixedDate
        )
        let warning = SuccessfulProviderDiscovery(
            providerID: healthy.providerID,
            authority: healthy.authority,
            observedAt: healthy.observedAt,
            connection: .connected,
            authentication: .warning(evidence),
            presence: healthy.presence
        )
        let recovered = ControllerFixture.quotaData(
            fetchedAt: ControllerFixture.fixedDate.addingTimeInterval(300)
        )
        let recorder = TestCallRecorder()
        let adapter = FakeProviderAdapter(
            id: .ark,
            capabilities: ControllerFixture.capabilities,
            recorder: recorder,
            discoveryResults: [.success(warning), .success(healthy)],
            readResults: [.success(ControllerFixture.quotaData()), .success(recovered)]
        )
        let cache = FakeProviderQuotaCache(recorder: recorder)
        let clock = TestClock()
        let (controller, scheduler) = try makeController(adapter: adapter, cache: cache, clock: clock)
        let started = await controller.send(.start)
        XCTAssertEqual(started, .completed)
        let before = await controller.projection()
        XCTAssertEqual(before.state.authentication, .warning(evidence))
        await adapter.setReadAuthentication(healthy.authentication)

        if automatic {
            let scheduled = await scheduler.scheduledToken(
                for: RefreshScheduleKey(providerID: .ark, scope: .provider)
            )
            let token = try XCTUnwrap(scheduled)
            XCTAssertEqual(token.reason, .automatic)
            await clock.waitUntilSleepIsRegistered(until: token.deadline)
            await clock.advance(to: token.deadline.nanoseconds)
            await cache.waitUntilSaveCount(2)
        } else {
            let refreshed = await controller.send(.refresh(.manual(scope: .provider)))
            XCTAssertEqual(refreshed, .completed)
        }

        let final = await controller.projection()
        XCTAssertEqual(final.state.authentication, healthy.authentication)
        XCTAssertEqual(final.state.freshness, .fresh(asOf: recovered.fetchedAt))
        let methods = await adapter.loginMethods
        XCTAssertTrue(methods.isEmpty, "External login recovery must not start another SSO flow")
        let order = await recorder.entries()
        XCTAssertEqual(order, [
            "cache.load", "adapter.discover", "adapter.read", "cache.save",
            "adapter.read", "cache.save"
        ])
    }

    func testSuccessfulQuotaRefreshCanEnterWarningWhileStillFresh() async throws {
        let adapter = FakeProviderAdapter(
            id: .ark, capabilities: ControllerFixture.capabilities,
            discoveryResults: [.success(ControllerFixture.discovery())],
            readResults: [.success(ControllerFixture.quotaData()), .success(ControllerFixture.quotaData())]
        )
        let (controller, _) = try makeController(
            adapter: adapter, cache: FakeProviderQuotaCache(), clock: TestClock()
        )
        _ = await controller.send(.start)
        let evidence = AuthenticationEvidence(
            authority: .providerReport(sourceField: "identity_store.refresh_token.exp", contractVersion: "test"),
            observedAt: ControllerFixture.fixedDate,
            expiresAt: ControllerFixture.fixedDate.addingTimeInterval(86_400)
        )
        await adapter.setReadAuthentication(.warning(evidence))
        _ = await controller.send(.refresh(.scheduled(scope: .provider)))
        let projection = await controller.projection()
        XCTAssertEqual(projection.state.authentication, .warning(evidence))
        guard case .fresh = projection.state.freshness else { return XCTFail("warning does not make quota stale") }
        let row = LiveProviderProjectionMapper.map(projection, now: ControllerFixture.fixedDate)
        XCTAssertEqual(row?.rowState, .authenticationWarning)
        XCTAssertEqual(row?.authenticationExpiresAt, evidence.expiresAt)
        let methods = await adapter.loginMethods
        XCTAssertTrue(methods.isEmpty)
    }

    func testRequiresLoginUnderAutomaticCadenceRedetectsAndRecoversExternalLogin() async throws {
        let clock = TestClock()
        let authEvidence = AuthenticationEvidence(
            authority: .providerReport(
                sourceField: "fake.requires-login",
                contractVersion: "provider-contract-v0.8"
            ),
            observedAt: ControllerFixture.fixedDate
        )
        let requiresLogin = ControllerFixture.discovery(
            connection: .requiresLogin(authEvidence)
        )
        let recovered = ControllerFixture.quotaData(
            fetchedAt: ControllerFixture.fixedDate.addingTimeInterval(60)
        )
        let recorder = TestCallRecorder()
        let adapter = FakeProviderAdapter(
            id: .ark,
            capabilities: ControllerFixture.capabilities,
            recorder: recorder,
            discoveryResults: [
                .success(requiresLogin),
                .success(ControllerFixture.discovery())
            ],
            readResults: [.success(recovered)]
        )
        let cache = FakeProviderQuotaCache(recorder: recorder)
        let policy = RefreshPolicy(
            cadence: .automatic(interval: .seconds(60)),
            manualCooldown: .seconds(20),
            retryBackoff: [.seconds(60)],
            shutdownGrace: .seconds(2)
        )
        let (controller, scheduler) = try makeController(
            adapter: adapter,
            cache: cache,
            clock: clock,
            policy: policy
        )

        let startOutcome = await controller.send(.start)
        XCTAssertEqual(startOutcome, .completed)
        let scheduledToken = await scheduler.scheduledToken(
            for: RefreshScheduleKey(providerID: .ark, scope: .provider)
        )
        let token = try XCTUnwrap(scheduledToken)
        XCTAssertEqual(
            token.reason,
            .discoveryRetry(attempt: 1, initiatedBy: .startup)
        )
        XCTAssertEqual(
            token.deadline.nanoseconds,
            RefreshDuration.seconds(15 * 60).nanoseconds,
            "Requires-login detection must respect the Ark authentication cooldown"
        )
        let waiting = await controller.projection()
        XCTAssertEqual(waiting.state.connection, .requiresLogin(authEvidence))
        XCTAssertEqual(
            waiting.state.refresh.gate,
            .backoff(until: token.deadline, attempt: 1)
        )

        await adapter.blockNextRead()
        await clock.waitUntilSleepIsRegistered(until: token.deadline)
        await clock.advance(to: token.deadline.nanoseconds)
        await adapter.waitUntilReadIsBlocked()
        await adapter.resumeRead(with: .success(recovered))
        await cache.waitUntilSaveCount(1)
        let final = await controller.projection()
        XCTAssertEqual(final.state.freshness, .fresh(asOf: recovered.fetchedAt))
        let order = await recorder.entries()
        XCTAssertEqual(
            order,
            [
                "cache.load",
                "adapter.discover",
                "adapter.discover",
                "adapter.read",
                "cache.save"
            ]
        )
    }

    func testManualRefreshRedetectsRequiresLoginBeforeReading() async throws {
        let clock = TestClock()
        let authEvidence = AuthenticationEvidence(
            authority: .providerReport(
                sourceField: "fake.requires-login",
                contractVersion: "provider-contract-v0.8"
            ),
            observedAt: ControllerFixture.fixedDate
        )
        let recovered = ControllerFixture.quotaData(
            fetchedAt: ControllerFixture.fixedDate.addingTimeInterval(30)
        )
        let recorder = TestCallRecorder()
        let adapter = FakeProviderAdapter(
            id: .ark,
            capabilities: ControllerFixture.capabilities,
            recorder: recorder,
            discoveryResults: [
                .success(
                    ControllerFixture.discovery(
                        connection: .requiresLogin(authEvidence)
                    )
                ),
                .success(ControllerFixture.discovery())
            ],
            readResults: [.success(recovered)]
        )
        let cache = FakeProviderQuotaCache(recorder: recorder)
        let manualOnly = RefreshPolicy(
            cadence: .manualOnly,
            manualCooldown: .seconds(20),
            retryBackoff: [.seconds(60)],
            shutdownGrace: .seconds(2)
        )
        let (controller, _) = try makeController(
            adapter: adapter,
            cache: cache,
            clock: clock,
            policy: manualOnly
        )

        let startOutcome = await controller.send(.start)
        XCTAssertEqual(startOutcome, .completed)
        let manualOutcome = await controller.send(.refresh(.manual(scope: .provider)))
        XCTAssertEqual(
            manualOutcome,
            .completed
        )
        let final = await controller.projection()
        XCTAssertEqual(final.state.freshness, .fresh(asOf: recovered.fetchedAt))
        let order = await recorder.entries()
        XCTAssertEqual(
            order,
            [
                "cache.load",
                "adapter.discover",
                "adapter.discover",
                "adapter.read",
                "cache.save"
            ]
        )
    }

    func testConcurrentLoginCoalescesUntilRecoveryReadCompletes() async throws {
        let clock = TestClock()
        let authEvidence = AuthenticationEvidence(
            authority: .providerReport(
                sourceField: "fake.requires-login",
                contractVersion: "provider-contract-v0.8"
            ),
            observedAt: ControllerFixture.fixedDate
        )
        let requiresLogin = ControllerFixture.discovery(
            connection: .requiresLogin(authEvidence)
        )
        let recovered = ControllerFixture.quotaData(
            fetchedAt: ControllerFixture.fixedDate.addingTimeInterval(30)
        )
        let recorder = TestCallRecorder()
        let adapter = FakeProviderAdapter(
            id: .ark,
            capabilities: ControllerFixture.capabilities,
            recorder: recorder,
            discoveryResults: [
                .success(requiresLogin),
                .success(ControllerFixture.discovery())
            ],
            readResults: [.success(recovered)]
        )
        let cache = FakeProviderQuotaCache(recorder: recorder)
        let manualOnly = RefreshPolicy(
            cadence: .manualOnly,
            manualCooldown: .seconds(20),
            retryBackoff: [.seconds(60)],
            shutdownGrace: .seconds(2)
        )
        let (controller, _) = try makeController(
            adapter: adapter,
            cache: cache,
            clock: clock,
            policy: manualOnly
        )
        let startOutcome = await controller.send(.start)
        XCTAssertEqual(startOutcome, .completed)

        await adapter.blockNextLogin()
        let firstLogin = Task { await controller.send(.login) }
        await adapter.waitUntilLoginIsBlocked()

        let secondOutcome = await controller.send(.login)
        guard case .joined = secondOutcome else {
            return XCTFail("A concurrent login must join the active recovery")
        }
        let methodsWhileBlocked = await adapter.loginMethods
        XCTAssertEqual(methodsWhileBlocked, [.sso])

        await adapter.blockNextRead()
        await adapter.resumeLogin(with: .success)
        await adapter.waitUntilReadIsBlocked()
        let duringVerificationOutcome = await controller.send(.login)
        guard case .joined = duringVerificationOutcome else {
            return XCTFail("Login must remain joined through post-login verification")
        }
        let methodsDuringVerification = await adapter.loginMethods
        XCTAssertEqual(methodsDuringVerification, [.sso])

        await adapter.resumeRead(with: .success(recovered))
        let firstOutcome = await firstLogin.value
        XCTAssertEqual(firstOutcome, .completed)
        let finalLoginMethods = await adapter.loginMethods
        let discoverCallCount = await adapter.discoverCallCount
        let readScopes = await adapter.readScopes
        XCTAssertEqual(finalLoginMethods, [.sso])
        XCTAssertEqual(discoverCallCount, 2)
        XCTAssertEqual(readScopes, [.provider])

        let projection = await controller.projection()
        XCTAssertEqual(projection.state.freshness, .fresh(asOf: recovered.fetchedAt))
        let order = await recorder.entries()
        XCTAssertEqual(
            order,
            [
                "cache.load",
                "adapter.discover",
                "adapter.login",
                "adapter.discover",
                "adapter.read",
                "cache.save"
            ]
        )
    }

    func testCancelLoginRestoresIdleAllowsRetryAndRejectsLateCommit() async throws {
        let clock = TestClock()
        let authEvidence = AuthenticationEvidence(
            authority: .providerReport(
                sourceField: "fake.requires-login",
                contractVersion: "provider-contract-v0.8"
            ),
            observedAt: ControllerFixture.fixedDate
        )
        let requiresLogin = ControllerFixture.discovery(
            connection: .requiresLogin(authEvidence)
        )
        let recovered = ControllerFixture.quotaData(
            fetchedAt: ControllerFixture.fixedDate.addingTimeInterval(30)
        )
        let adapter = FakeProviderAdapter(
            id: .ark,
            capabilities: ControllerFixture.capabilities,
            discoveryResults: [
                .success(requiresLogin),
                .success(ControllerFixture.discovery())
            ],
            readResults: [.success(recovered)]
        )
        let cache = FakeProviderQuotaCache()
        let (controller, scheduler) = try makeController(
            adapter: adapter,
            cache: cache,
            clock: clock
        )
        let startOutcome = await controller.send(.start)
        XCTAssertEqual(startOutcome, .completed)

        await adapter.blockNextLogin()
        let firstLogin = Task { await controller.send(.login) }
        await adapter.waitUntilLoginIsBlocked()
        let duringLogin = await controller.projection()
        guard case .loggingIn = duringLogin.state.refresh.activity else {
            return XCTFail("The official login flow must be visible while blocked")
        }

        let cancelTask = Task { await controller.send(.cancelLogin) }
        await Task.yield()
        let retryDuringCancellation = await controller.send(.login)
        guard case .joined = retryDuringCancellation else {
            return XCTFail("A cancelling login must retain the single-login slot")
        }
        let loginMethodsDuringCancellation = await adapter.loginMethods
        XCTAssertEqual(loginMethodsDuringCancellation.count, 1)

        await adapter.resumeLogin(with: .success)
        let cancelOutcome = await cancelTask.value
        XCTAssertEqual(cancelOutcome, .completed)
        let afterCancel = await controller.projection()
        XCTAssertEqual(afterCancel.state.refresh.activity, .idle)

        let firstLoginOutcome = await firstLogin.value
        XCTAssertEqual(firstLoginOutcome, .cancelled)
        let afterLateSuccess = await controller.projection()
        XCTAssertEqual(afterLateSuccess.state.connection, .requiresLogin(authEvidence))
        let rearmedToken = await scheduler.scheduledToken(
            for: RefreshScheduleKey(providerID: .ark, scope: .provider)
        )
        let rearmed = try XCTUnwrap(rearmedToken)
        XCTAssertEqual(
            rearmed.reason,
            .discoveryRetry(attempt: 1, initiatedBy: .scheduled)
        )
        XCTAssertEqual(
            rearmed.deadline.nanoseconds,
            RefreshDuration.seconds(15 * 60).nanoseconds
        )

        await adapter.enqueueLogin(.success)
        let retryOutcome = await controller.send(.login)
        XCTAssertEqual(retryOutcome, .completed)
        let afterRetry = await controller.projection()
        XCTAssertEqual(afterRetry.state.freshness, .fresh(asOf: recovered.fetchedAt))
    }

    func testCacheSaveFailureOnlyDegradesPersistenceAndKeepsSuccessfulData() async throws {
        let clock = TestClock()
        let data = ControllerFixture.quotaData()
        let cacheFailure = ControllerFixture.failure(
            retryClass: .never,
            code: .cacheUnavailable,
            diagnosticCode: "fake.cache.write"
        )
        let adapter = FakeProviderAdapter(
            id: .ark,
            capabilities: ControllerFixture.capabilities,
            discoveryResults: [.success(ControllerFixture.discovery())],
            readResults: [.success(data)]
        )
        let cache = FakeProviderQuotaCache(
            saveResults: [.failure(cacheFailure)]
        )
        let (controller, _) = try makeController(
            adapter: adapter,
            cache: cache,
            clock: clock
        )

        let startOutcome = await controller.send(.start)
        XCTAssertEqual(startOutcome, .completed)
        let projection = await controller.projection()
        XCTAssertEqual(projection.state.lastGood, data)
        XCTAssertEqual(projection.state.freshness, .fresh(asOf: data.fetchedAt))
        XCTAssertEqual(projection.state.persistence, .degraded(cacheFailure))
        XCTAssertEqual(projection.state.refresh.lastSuccessAt, ControllerFixture.fixedDate)
    }

    func testShutdownIsBoundedAndRejectsNewIntentsImmediately() async throws {
        let clock = TestClock()
        let adapter = FakeProviderAdapter(
            id: .ark,
            capabilities: ControllerFixture.capabilities,
            discoveryResults: [.success(ControllerFixture.discovery())]
        )
        let cache = FakeProviderQuotaCache()
        await adapter.blockShutdown()
        await cache.blockShutdown()
        let policy = RefreshPolicy(
            cadence: .manualOnly,
            manualCooldown: .seconds(20),
            retryBackoff: [.seconds(60)],
            shutdownGrace: RefreshDuration(nanoseconds: 100)
        )
        let (controller, _) = try makeController(
            adapter: adapter,
            cache: cache,
            clock: clock,
            policy: policy
        )
        _ = await controller.send(.start)

        let shutdownTask = Task { await controller.send(.shutdown) }
        let shutdownStarted = await eventually {
            let adapterCount = await adapter.shutdownCallCount
            let cacheCount = await cache.shutdownCallCount
            return adapterCount == 1 && cacheCount == 1
        }
        XCTAssertTrue(shutdownStarted)
        let duringShutdown = await controller.send(.refresh(.manual(scope: .provider)))
        XCTAssertEqual(duringShutdown, .rejected(.shuttingDown))

        await clock.advance(to: 100)
        let shutdownOutcome = await shutdownTask.value
        XCTAssertEqual(shutdownOutcome, .shutdown(completedWithinGrace: false))
        let afterShutdown = await controller.send(.refresh(.manual(scope: .provider)))
        XCTAssertEqual(afterShutdown, .rejected(.stopped))
        let projection = await controller.projection()
        XCTAssertEqual(projection.phase, .stopped)
        XCTAssertEqual(projection.state.connection, .disabled)
        XCTAssertEqual(projection.state.refresh.activity, .idle)

        await adapter.resumeShutdown()
        await cache.resumeShutdown()
    }

    func testProjectionStreamStartsWithImmutableSnapshotAndPublishesIntentChanges() async throws {
        let clock = TestClock()
        let adapter = FakeProviderAdapter(
            id: .ark,
            capabilities: ControllerFixture.capabilities
        )
        let cache = FakeProviderQuotaCache()
        let (controller, _) = try makeController(
            adapter: adapter,
            cache: cache,
            clock: clock
        )
        let stream = await controller.projections()
        var iterator = stream.makeAsyncIterator()

        let initialValue = await iterator.next()
        let initial = try XCTUnwrap(initialValue)
        XCTAssertTrue(initial.isEnabled)
        XCTAssertEqual(initial.phase, .idle)

        let disableOutcome = await controller.send(.setEnabled(false))
        XCTAssertEqual(disableOutcome, .completed)
        let changedValue = await iterator.next()
        let changed = try XCTUnwrap(changedValue)
        XCTAssertFalse(changed.isEnabled)
        XCTAssertGreaterThan(changed.revision, initial.revision)
    }

    func testClearCacheRemovesRetainedProjectionWithoutChangingConnectionOrPreferences() async throws {
        let clock = TestClock()
        let cached = ControllerFixture.quotaData(
            fetchedAt: ControllerFixture.fixedDate.addingTimeInterval(-300)
        )
        let adapter = FakeProviderAdapter(
            id: .ark,
            capabilities: ControllerFixture.capabilities,
            discoveryResults: [.success(ControllerFixture.discovery())]
        )
        let cache = FakeProviderQuotaCache(loadResult: .hit(cached))
        let manualPolicy = RefreshPolicy(
            cadence: .manualOnly,
            manualCooldown: .seconds(20),
            retryBackoff: [.seconds(60)],
            shutdownGrace: .seconds(2)
        )
        let (controller, _) = try makeController(
            adapter: adapter,
            cache: cache,
            clock: clock,
            policy: manualPolicy
        )

        _ = await controller.send(.start)
        let before = await controller.projection()
        XCTAssertEqual(before.state.lastGood, cached)
        XCTAssertTrue(before.isEnabled)

        let outcome = await controller.send(.clearCache)
        XCTAssertEqual(outcome, .completed)

        let after = await controller.projection()
        XCTAssertNil(after.state.lastGood)
        XCTAssertEqual(after.state.freshness, .unknown)
        XCTAssertEqual(after.state.connection, before.state.connection)
        XCTAssertEqual(after.state.authentication, before.state.authentication)
        XCTAssertTrue(after.isEnabled)
        let clearedProviderIDs = await cache.clearedProviderIDs
        let readScopes = await adapter.readScopes
        XCTAssertEqual(clearedProviderIDs, [.ark])
        XCTAssertTrue(readScopes.isEmpty)
    }

    func testClearCacheFailurePreservesMemoryProjectionAndRecordsPersistenceFailure() async throws {
        let clock = TestClock()
        let cached = ControllerFixture.quotaData()
        let failure = ProviderFailure(
            code: .permissionDenied,
            retryClass: .never,
            userMessageKey: "provider.failure.permission",
            diagnosticCode: "cache.clear.permission_denied",
            recovery: nil
        )
        let adapter = FakeProviderAdapter(
            id: .ark,
            capabilities: ControllerFixture.capabilities,
            discoveryResults: [.success(ControllerFixture.discovery())]
        )
        let cache = FakeProviderQuotaCache(
            loadResult: .hit(cached),
            clearResults: [.failure(failure)]
        )
        let policy = RefreshPolicy(
            cadence: .manualOnly,
            manualCooldown: .seconds(20),
            retryBackoff: [.seconds(60)],
            shutdownGrace: .seconds(2)
        )
        let (controller, _) = try makeController(
            adapter: adapter,
            cache: cache,
            clock: clock,
            policy: policy
        )

        _ = await controller.send(.start)
        let outcome = await controller.send(.clearCache)
        XCTAssertEqual(outcome, .completed)

        let after = await controller.projection()
        XCTAssertEqual(after.state.lastGood, cached)
        XCTAssertEqual(after.state.persistence, .degraded(failure))
    }

    func testClearCacheSerializesControllerMutationsUntilDiskResultReturns() async throws {
        let clock = TestClock()
        let cached = ControllerFixture.quotaData()
        let adapter = FakeProviderAdapter(
            id: .ark,
            capabilities: ControllerFixture.capabilities,
            discoveryResults: [.success(ControllerFixture.discovery())]
        )
        let cache = FakeProviderQuotaCache(loadResult: .hit(cached))
        await cache.blockClear()
        let policy = RefreshPolicy(
            cadence: .manualOnly,
            manualCooldown: .seconds(20),
            retryBackoff: [.seconds(60)],
            shutdownGrace: .seconds(2)
        )
        let (controller, _) = try makeController(
            adapter: adapter,
            cache: cache,
            clock: clock,
            policy: policy
        )
        _ = await controller.send(.start)

        let clearTask = Task { await controller.send(.clearCache) }
        await cache.waitUntilClearIsBlocked()

        let toggleDuringClear = await controller.send(.setEnabled(false))
        XCTAssertEqual(
            toggleDuringClear,
            .deferred(.suspend(.operationInProgress))
        )

        await cache.resumeClear()
        let clearOutcome = await clearTask.value
        XCTAssertEqual(clearOutcome, .completed)
        let after = await controller.projection()
        XCTAssertTrue(after.isEnabled)
        XCTAssertNil(after.state.lastGood)
    }

    func testClearCacheDuringReadStartsAutomaticReplacementAndRejectsLateCompletion() async throws {
        try await checkClearCacheDuringRead(frequency: .oneMinute)
    }

    func testClearCacheDuringReadAllowsManualRecoveryAndRejectsLateCompletion() async throws {
        try await checkClearCacheDuringRead(frequency: .manualOnly)
    }

    private func checkClearCacheDuringRead(frequency: ProviderRefreshFrequency) async throws {
        let clock = TestClock()
        let initial = ControllerFixture.quotaData()
        let replacement = ControllerFixture.quotaData(
            fetchedAt: ControllerFixture.fixedDate.addingTimeInterval(60)
        )
        let late = ControllerFixture.quotaData(
            fetchedAt: ControllerFixture.fixedDate.addingTimeInterval(120)
        )
        let adapter = FakeProviderAdapter(
            id: .ark,
            capabilities: ControllerFixture.capabilities,
            discoveryResults: [.success(ControllerFixture.discovery())],
            readResults: frequency == .manualOnly
                ? [.success(replacement)] : [.success(initial), .success(replacement)]
        )
        let cache = FakeProviderQuotaCache(loadResult: .hit(initial))
        let (controller, scheduler) = try makeController(
            adapter: adapter, cache: cache, clock: clock,
            policy: recoveryPolicy(frequency)
        )
        _ = await controller.send(.start)
        await adapter.blockNextRead()
        let oldRead = Task { await controller.send(.refresh(.manual(scope: .provider))) }
        await adapter.waitUntilReadIsBlocked()

        let clear = await controller.send(.clearCache)
        XCTAssertEqual(clear, .completed)
        if frequency == .manualOnly {
            let cleared = await controller.projection()
            XCTAssertNil(cleared.state.lastGood)
            XCTAssertEqual(cleared.state.refresh.activity, .idle)
            XCTAssertEqual(cleared.state.refresh.gate, .open)
            let schedules = await scheduler.scheduledTokens(providerID: .ark)
            XCTAssertTrue(schedules.isEmpty)
            let recovered = await controller.send(.refresh(.manual(scope: .provider)))
            XCTAssertEqual(recovered, .completed)
        }
        let beforeLateRead = await controller.projection()
        XCTAssertEqual(beforeLateRead.state.lastGood, replacement)
        XCTAssertEqual(beforeLateRead.state.refresh.activity, .idle)

        await adapter.resumeRead(with: .success(late))
        let oldOutcome = await oldRead.value
        XCTAssertEqual(oldOutcome, .cancelled)
        let afterLateRead = await controller.projection()
        XCTAssertEqual(afterLateRead, beforeLateRead)
        let saved = await cache.savedData
        XCTAssertFalse(saved.contains(late))
        let schedules = await scheduler.scheduledTokens(providerID: .ark)
        XCTAssertEqual(schedules.count, frequency == .manualOnly ? 0 : 1)
        _ = await controller.send(.shutdown)
    }

    func testClearCacheDuringDiscoveryRestartsAutomaticDiscoveryAndRejectsLateCompletion() async throws {
        try await checkClearCacheDuringDiscovery(frequency: .oneMinute)
    }

    func testClearCacheDuringDiscoveryAllowsManualRedetectionAndRejectsLateCompletion() async throws {
        try await checkClearCacheDuringDiscovery(frequency: .manualOnly)
    }

    private func checkClearCacheDuringDiscovery(frequency: ProviderRefreshFrequency) async throws {
        let clock = TestClock()
        let live = ControllerFixture.quotaData()
        let adapter = FakeProviderAdapter(
            id: .ark,
            capabilities: ControllerFixture.capabilities,
            discoveryResults: [.success(ControllerFixture.discovery())],
            readResults: [.success(live)]
        )
        await adapter.blockNextDiscovery()
        let cache = FakeProviderQuotaCache()
        let (controller, scheduler) = try makeController(
            adapter: adapter, cache: cache, clock: clock,
            policy: recoveryPolicy(frequency)
        )
        let oldStart = Task { await controller.send(.start) }
        await adapter.waitUntilDiscoveryIsBlocked()

        let clear = await controller.send(.clearCache)
        XCTAssertEqual(clear, .completed)
        if frequency == .manualOnly {
            let cleared = await controller.projection()
            XCTAssertEqual(cleared.state.refresh.activity, .idle)
            XCTAssertEqual(cleared.state.discovery, .notStarted)
            XCTAssertEqual(cleared.state.connection, .unavailable(observedAt: nil))
            let schedules = await scheduler.scheduledTokens(providerID: .ark)
            XCTAssertTrue(schedules.isEmpty)
            let manual = await controller.send(.refresh(.manual(scope: .provider)))
            XCTAssertEqual(manual, .completed)
        }
        let beforeLateDiscovery = await controller.projection()
        XCTAssertEqual(beforeLateDiscovery.state.lastGood, live)
        XCTAssertEqual(beforeLateDiscovery.state.refresh.activity, .idle)
        let calls = await adapter.discoverCallCount
        XCTAssertEqual(calls, 2)

        let evidence = AuthenticationEvidence(
            authority: .initialDetection, observedAt: ControllerFixture.fixedDate
        )
        await adapter.resumeDiscovery(with: .success(
            ControllerFixture.discovery(connection: .requiresLogin(evidence))
        ))
        let oldOutcome = await oldStart.value
        XCTAssertEqual(oldOutcome, .cancelled)
        let afterLateDiscovery = await controller.projection()
        XCTAssertEqual(afterLateDiscovery, beforeLateDiscovery)
        _ = await controller.send(.shutdown)
    }

    func testClearCacheDuringLoginDrainsCancellationBeforeAutomaticRecovery() async throws {
        try await checkClearCacheDuringLogin(frequency: .oneMinute)
    }

    func testClearCacheDuringLoginPreservesAuthenticationUntilManualRecovery() async throws {
        try await checkClearCacheDuringLogin(frequency: .manualOnly)
    }

    private func checkClearCacheDuringLogin(frequency: ProviderRefreshFrequency) async throws {
        let clock = TestClock()
        let evidence = AuthenticationEvidence(
            authority: .initialDetection, observedAt: ControllerFixture.fixedDate
        )
        let live = ControllerFixture.quotaData()
        let adapter = FakeProviderAdapter(
            id: .ark,
            capabilities: ControllerFixture.capabilities,
            discoveryResults: [
                .success(ControllerFixture.discovery(connection: .requiresLogin(evidence))),
                .success(ControllerFixture.discovery())
            ],
            readResults: [.success(live)]
        )
        let cache = FakeProviderQuotaCache()
        let (controller, scheduler) = try makeController(
            adapter: adapter, cache: cache, clock: clock,
            policy: recoveryPolicy(frequency)
        )
        _ = await controller.send(.start)
        let before = await controller.projection()
        await adapter.blockNextLogin()
        let oldLogin = Task { await controller.send(.login) }
        await adapter.waitUntilLoginIsBlocked()
        let clearTask = Task { await controller.send(.clearCache) }
        await adapter.waitUntilLoginIsCancelled()

        let whileCancelling = await controller.send(.login)
        XCTAssertEqual(whileCancelling, .deferred(.suspend(.operationInProgress)))
        let clearsBeforeExit = await cache.clearedProviderIDs
        XCTAssertTrue(clearsBeforeExit.isEmpty, "Clear waits for the cancelled login to exit")
        await adapter.resumeLogin(with: .success)
        let oldOutcome = await oldLogin.value
        XCTAssertEqual(oldOutcome, .cancelled)
        let clear = await clearTask.value
        XCTAssertEqual(clear, .completed)

        if frequency == .manualOnly {
            let cleared = await controller.projection()
            XCTAssertEqual(cleared.state.refresh.activity, .idle)
            XCTAssertEqual(cleared.state.connection, before.state.connection)
            XCTAssertEqual(cleared.state.authentication, before.state.authentication)
            let schedules = await scheduler.scheduledTokens(providerID: .ark)
            XCTAssertTrue(schedules.isEmpty)
            let manual = await controller.send(.refresh(.manual(scope: .provider)))
            XCTAssertEqual(manual, .completed)
        }
        let final = await controller.projection()
        XCTAssertEqual(final.state.lastGood, live)
        XCTAssertEqual(final.state.refresh.activity, .idle)
        let loginMethods = await adapter.loginMethods
        XCTAssertEqual(loginMethods, [.sso], "Recovery must not start another login")
        _ = await controller.send(.shutdown)
    }

    func testFailedClearDuringReadSettlesActivityPreservesDataAndRearmsAutomaticCadence() async throws {
        let clock = TestClock()
        let initial = ControllerFixture.quotaData()
        let live = ControllerFixture.quotaData(
            fetchedAt: ControllerFixture.fixedDate.addingTimeInterval(60)
        )
        let failure = ControllerFixture.failure(
            retryClass: .never, code: .permissionDenied,
            diagnosticCode: "cache.clear.permission_denied"
        )
        let adapter = FakeProviderAdapter(
            id: .ark,
            capabilities: ControllerFixture.capabilities,
            discoveryResults: [.success(ControllerFixture.discovery())],
            readResults: [.success(initial)]
        )
        let cache = FakeProviderQuotaCache(clearResults: [.failure(failure)])
        let (controller, scheduler) = try makeController(
            adapter: adapter, cache: cache, clock: clock,
            policy: recoveryPolicy(.oneMinute)
        )
        _ = await controller.send(.start)
        await adapter.blockNextRead()
        let oldRead = Task { await controller.send(.refresh(.manual(scope: .provider))) }
        await adapter.waitUntilReadIsBlocked()
        let clear = await controller.send(.clearCache)
        XCTAssertEqual(clear, .completed)
        let after = await controller.projection()
        XCTAssertEqual(after.state.lastGood, initial)
        XCTAssertEqual(after.state.persistence, .degraded(failure))
        XCTAssertEqual(after.state.refresh.activity, .idle)
        XCTAssertEqual(after.state.refresh.gate, .open)
        await adapter.resumeRead(with: .success(live))
        let oldOutcome = await oldRead.value
        XCTAssertEqual(oldOutcome, .cancelled)
        let unchanged = await controller.projection()
        XCTAssertEqual(unchanged, after)

        let schedules = await scheduler.scheduledTokens(providerID: .ark)
        let token = try XCTUnwrap(schedules.first)
        XCTAssertEqual(schedules.count, 1)
        XCTAssertEqual(token.reason, .automatic)
        await adapter.blockNextRead()
        await clock.waitUntilSleepIsRegistered(until: token.deadline)
        await clock.advance(to: token.deadline.nanoseconds)
        await adapter.waitUntilReadIsBlocked()
        await adapter.resumeRead(with: .success(live))
        await cache.waitUntilSaveCount(2)
        let recovered = await controller.projection()
        XCTAssertEqual(recovered.state.lastGood, live)
        _ = await controller.send(.shutdown)
    }

    func testRequiresLoginManualToAutomaticPolicyArmsRepeatingDiscoveryRetry() async throws {
        try await checkRequiresLoginPolicyChange(from: .manualOnly)
    }

    func testRequiresLoginAutomaticIntervalChangePreservesRepeatingDiscoveryRetry() async throws {
        try await checkRequiresLoginPolicyChange(from: .fiveMinutes)
    }

    private func checkRequiresLoginPolicyChange(from frequency: ProviderRefreshFrequency) async throws {
        let clock = TestClock()
        let evidence = AuthenticationEvidence(
            authority: .initialDetection, observedAt: ControllerFixture.fixedDate
        )
        let requiresLogin = ControllerFixture.discovery(connection: .requiresLogin(evidence))
        let live = ControllerFixture.quotaData(
            fetchedAt: ControllerFixture.fixedDate.addingTimeInterval(120)
        )
        let adapter = FakeProviderAdapter(
            id: .ark,
            capabilities: ControllerFixture.capabilities,
            discoveryResults: [
                .success(requiresLogin), .success(requiresLogin),
                .success(ControllerFixture.discovery())
            ],
            readResults: [.success(live)]
        )
        let cache = FakeProviderQuotaCache()
        let (controller, scheduler) = try makeController(
            adapter: adapter, cache: cache, clock: clock,
            policy: recoveryPolicy(frequency)
        )
        _ = await controller.send(.start)
        let outcome = await controller.send(.setRefreshPolicy(recoveryPolicy(.oneMinute)))
        XCTAssertEqual(outcome, .completed)
        let schedules = await scheduler.scheduledTokens(providerID: .ark)
        XCTAssertEqual(schedules.count, 1)
        let token = try XCTUnwrap(schedules.first)
        XCTAssertEqual(
            token.deadline.nanoseconds,
            RefreshDuration.seconds(15 * 60).nanoseconds
        )
        guard case .discoveryRetry = token.reason else {
            _ = await controller.send(.shutdown)
            return XCTFail("Changing cadence must retain a discovery retry, not an ordinary read")
        }
        let waiting = await controller.projection()
        XCTAssertEqual(waiting.state.refresh.gate, .backoff(until: token.deadline, attempt: 1))

        await clock.waitUntilSleepIsRegistered(until: token.deadline)
        await clock.advance(to: token.deadline.nanoseconds)
        let nextDeadline = MonotonicInstant(
            nanoseconds: RefreshDuration.seconds(30 * 60).nanoseconds
        )
        await clock.waitUntilSleepIsRegistered(until: nextDeadline)
        let nextSchedules = await scheduler.scheduledTokens(providerID: .ark)
        XCTAssertEqual(nextSchedules.count, 1)
        let next = try XCTUnwrap(nextSchedules.first)
        XCTAssertEqual(next.reason, .discoveryRetry(attempt: 1, initiatedBy: .scheduled))
        let readsWhileLoginRequired = await adapter.readScopes
        XCTAssertTrue(readsWhileLoginRequired.isEmpty)

        await adapter.blockNextRead()
        await clock.advance(to: next.deadline.nanoseconds)
        await adapter.waitUntilReadIsBlocked()
        await adapter.resumeRead(with: .success(live))
        await cache.waitUntilSaveCount(1)
        let recovered = await controller.projection()
        XCTAssertEqual(recovered.state.freshness, .fresh(asOf: live.fetchedAt))
        XCTAssertEqual(recovered.state.connection, .connected(observedAt: ControllerFixture.fixedDate))
        let finalSchedules = await scheduler.scheduledTokens(providerID: .ark)
        XCTAssertEqual(finalSchedules.count, 1)
        XCTAssertEqual(finalSchedules.first?.reason, .automatic)
        let loginMethods = await adapter.loginMethods
        let discoveryCalls = await adapter.discoverCallCount
        XCTAssertTrue(loginMethods.isEmpty)
        XCTAssertEqual(discoveryCalls, 3)
        _ = await controller.send(.shutdown)
    }

    func testClearCacheRejectsReadCompletionPausedAtClockBoundary() async throws {
        try await checkClearCacheAtCompletionBoundary(.refresh(.manual(scope: .provider)))
    }

    func testClearCacheRejectsDiscoveryCompletionPausedAtClockBoundary() async throws {
        try await checkClearCacheAtCompletionBoundary(.redetect)
    }

    func testClearCacheRejectsLoginCompletionPausedAtClockBoundary() async throws {
        try await checkClearCacheAtCompletionBoundary(.login)
    }

    private func checkClearCacheAtCompletionBoundary(_ intent: ProviderIntent) async throws {
        let clock = TestClock()
        let initial = ControllerFixture.quotaData()
        let replacement = ControllerFixture.quotaData(
            fetchedAt: ControllerFixture.fixedDate.addingTimeInterval(60)
        )
        let late = ControllerFixture.quotaData(
            fetchedAt: ControllerFixture.fixedDate.addingTimeInterval(120)
        )
        let adapter = FakeProviderAdapter(
            id: .ark,
            capabilities: ControllerFixture.capabilities,
            discoveryResults: [
                .success(ControllerFixture.discovery()),
                .success(ControllerFixture.discovery())
            ],
            readResults: [.success(initial), .success(replacement)]
        )
        let cache = FakeProviderQuotaCache()
        let (controller, _) = try makeController(
            adapter: adapter, cache: cache, clock: clock
        )
        _ = await controller.send(.start)
        switch intent {
        case .redetect: await adapter.blockNextDiscovery()
        case .login: await adapter.blockNextLogin()
        default: await adapter.blockNextRead()
        }
        let oldOperation = Task { await controller.send(intent) }
        switch intent {
        case .redetect: await adapter.waitUntilDiscoveryIsBlocked()
        case .login: await adapter.waitUntilLoginIsBlocked()
        default: await adapter.waitUntilReadIsBlocked()
        }
        await clock.blockNextReading()
        switch intent {
        case .redetect: await adapter.resumeDiscovery(with: .success(ControllerFixture.discovery()))
        case .login: await adapter.resumeLogin(with: .success)
        default: await adapter.resumeRead(with: .success(late))
        }
        await clock.waitUntilReadingIsBlocked()

        let clear = await controller.send(.clearCache)
        XCTAssertEqual(clear, .completed)
        let beforeLateCompletion = await controller.projection()
        XCTAssertEqual(beforeLateCompletion.state.lastGood, replacement)
        await clock.resumeReading()
        let oldOutcome = await oldOperation.value
        XCTAssertEqual(oldOutcome, .cancelled)
        let afterLateCompletion = await controller.projection()
        XCTAssertEqual(afterLateCompletion, beforeLateCompletion)
        let saved = await cache.savedData
        XCTAssertEqual(saved, [initial, replacement])
        _ = await controller.send(.shutdown)
    }

    private func recoveryPolicy(_ frequency: ProviderRefreshFrequency) -> RefreshPolicy {
        ProviderRefreshPolicyResolver.policy(
            providerID: .ark, globalFrequency: frequency, override: .followGlobal
        )
    }

    private func makeController(
        adapter: FakeProviderAdapter,
        cache: FakeProviderQuotaCache,
        clock: TestClock,
        policy: RefreshPolicy = .standard
    ) throws -> (ProviderController, RefreshScheduler) {
        let scheduler = RefreshScheduler(clock: clock)
        let controller = try ProviderController(
            initialState: ControllerFixture.initialState(),
            initiallyEnabled: true,
            adapter: adapter,
            cache: cache,
            clock: clock,
            scheduler: scheduler,
            policy: policy
        )
        return (controller, scheduler)
    }

    private func controllerProduct(
        sourceProductID: String,
        usedPercent: Decimal,
        fetchedAt: Date
    ) -> QuotaProductData {
        let identity = MetricSourceIdentity(
            providerID: .ark,
            sourceProductID: sourceProductID,
            sourceBucketID: sourceProductID,
            sourceMetricID: "primary.used_percent"
        )
        let nodeState = QuotaNodeState(
            presence: .unknown,
            freshness: .fresh(asOf: fetchedAt),
            refresh: RefreshState(
                activity: .idle,
                gate: .open,
                lastAttemptAt: fetchedAt,
                lastSuccessAt: fetchedAt
            ),
            lastAttemptAt: fetchedAt,
            lastSuccessAt: fetchedAt,
            failure: nil
        )
        let metric = QuotaMetric(
            id: MetricID(sourceIdentity: identity),
            sourceMetricID: identity.sourceMetricID,
            sourceLabel: sourceProductID,
            window: QuotaWindow(
                kind: .weekly,
                duration: nil,
                startsAt: nil,
                endsAt: nil,
                timeEvent: nil
            ),
            value: .percent(
                DirectedPercent(sourceValue: usedPercent, sourceDirection: .used)
            ),
            sourceStatus: nil,
            provenance: MetricProvenance(
                sourceIdentity: identity,
                providerSource: ControllerFixture.source(),
                fetchedAt: fetchedAt
            ),
            state: nodeState
        )
        return QuotaProductData(
            id: ProductID(providerID: .ark, sourceProductID: sourceProductID),
            sourceProductID: sourceProductID,
            titleKey: "provider.ark.\(sourceProductID)",
            canonicalOrder: sourceProductID == "codex" ? 0 : 1,
            planLevel: nil,
            state: nodeState,
            metrics: [metric]
        )
    }

    private func eventually(
        _ predicate: @escaping @Sendable () async -> Bool
    ) async -> Bool {
        for _ in 0..<100 {
            if await predicate() {
                return true
            }
            await Task.yield()
        }
        return false
    }
}
