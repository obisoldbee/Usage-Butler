import Foundation
import XCTest
@testable import UsageButlerCore
@testable import UsageButlerDomain

final class ProviderReducerTests: XCTestCase {
    private let successAt = Date(timeIntervalSince1970: 1_786_300_000)
    private let failureAt = Date(timeIntervalSince1970: 1_786_303_600)

    func testRefreshFailureDoesNotCreateNotEntitledClearLastGoodOrAdvanceSuccess() {
        var before = providerState()
        let sourceDataAt = successAt.addingTimeInterval(-300)
        before.freshness = .fresh(asOf: sourceDataAt)
        let failure = networkFailure()

        let after = ProviderReducer.reduce(
            state: before,
            event: .refreshFailed(failure),
            now: failureAt
        )

        XCTAssertEqual(after.presence, .unknown)
        assertSameRetainedPayload(after.lastGood, before.lastGood)
        XCTAssertEqual(after.refresh.lastSuccessAt, before.refresh.lastSuccessAt)
        XCTAssertEqual(
            after.freshness,
            .stale(asOf: sourceDataAt, evaluatedAt: failureAt)
        )
        XCTAssertEqual(after.failure, failure)
        let retained = try? XCTUnwrap(after.lastGood)
        if let retained {
            assertEveryNodeStale(in: retained, evaluatedAt: failureAt)
        }
    }

    func testRefreshFailurePreservesUnrelatedRequiredProviderFields() {
        let before = providerState()

        let after = ProviderReducer.reduce(
            state: before,
            event: .refreshFailed(networkFailure()),
            now: failureAt
        )

        XCTAssertEqual(after.id, before.id)
        XCTAssertEqual(after.capabilities, before.capabilities)
        XCTAssertEqual(after.connection, before.connection)
        XCTAssertEqual(after.presence, before.presence)
        XCTAssertEqual(after.authentication, before.authentication)
        XCTAssertEqual(after.refresh.gate, before.refresh.gate)
        XCTAssertEqual(after.refresh.lastAttemptAt, before.refresh.lastAttemptAt)
        XCTAssertEqual(after.refresh.lastSuccessAt, before.refresh.lastSuccessAt)
        assertSameRetainedPayload(after.lastGood, before.lastGood)
        XCTAssertEqual(after.discovery, before.discovery)
        XCTAssertEqual(after.persistence, before.persistence)
        XCTAssertEqual(after.refresh.activity, .idle)
    }

    func testDiscoveryFailureCannotGenerateNotEntitledOrExpireAuthentication() {
        let before = providerState()
        let failure = ProviderFailure(
            code: .schemaMismatch,
            retryClass: .never,
            userMessageKey: "provider.failure.schema",
            diagnosticCode: "fixture.schema.invalid",
            recovery: nil
        )

        let after = ProviderReducer.reduce(
            state: before,
            event: .discovery(.failed(failure)),
            now: failureAt
        )

        XCTAssertEqual(after.presence, .unknown)
        XCTAssertEqual(after.authentication, before.authentication)
        assertSameRetainedPayload(after.lastGood, before.lastGood)
        XCTAssertEqual(after.refresh.lastSuccessAt, before.refresh.lastSuccessAt)
        XCTAssertEqual(
            after.freshness,
            .stale(asOf: successAt, evaluatedAt: failureAt)
        )
    }

    func testOnlySuccessfulAuthoritativeDiscoveryAppliesNotEntitledEvidence() {
        let before = providerState()
        let source = providerSource()
        let authority = DiscoveryAuthority(
            source: source,
            operationID: "ark.usage-plan.discovery.v1"
        )
        let authentication = AuthenticationState.healthy(
            AuthenticationEvidence(
                authority: .providerReport(
                    sourceField: "viewer.authenticated",
                    contractVersion: "provider-contract-v0.8"
                ),
                observedAt: failureAt
            )
        )
        let discovery = SuccessfulProviderDiscovery(
            providerID: .ark,
            authority: authority,
            observedAt: failureAt,
            connection: .connected,
            authentication: authentication,
            presence: .notEntitled
        )

        let after = ProviderReducer.reduce(
            state: before,
            event: .discovery(.succeeded(discovery)),
            now: failureAt
        )

        guard case let .notEntitled(evidence) = after.presence else {
            return XCTFail("Authoritative success should apply its explicit absence decision")
        }
        XCTAssertEqual(evidence.authority, authority)
        XCTAssertEqual(evidence.observedAt, failureAt)
        XCTAssertEqual(after.authentication, authentication)
        XCTAssertEqual(after.connection, .connected(observedAt: failureAt))
    }

    func testLoginRecoverySuccessOnlyClearsGate() {
        var before = providerState()
        let expiredEvidence = AuthenticationExpiryEvidence(
            authority: .explicitExpiration(
                sourceField: "auth.status",
                contractVersion: "provider-contract-v0.8"
            ),
            observedAt: successAt
        )
        before.authentication = .expired(expiredEvidence)
        before.refresh.gate = .suspended(diagnosticCode: "auth.expired")
        before.freshness = .stale(asOf: successAt, evaluatedAt: failureAt)

        let after = ProviderReducer.reduce(
            state: before,
            event: .login(.recoverySucceeded),
            now: failureAt.addingTimeInterval(30)
        )

        XCTAssertEqual(after.refresh.gate, .open)
        XCTAssertEqual(after.authentication, .expired(expiredEvidence))
        XCTAssertEqual(after.refresh.lastSuccessAt, successAt)
        XCTAssertEqual(after.freshness, before.freshness)
        XCTAssertEqual(after.lastGood, before.lastGood)
    }

    func testGateChangeUpdatesOnlyTheAuthoritativeRefreshGate() {
        let before = providerState()
        let replacement = RefreshGateState.cooldown(
            until: MonotonicInstant(nanoseconds: 42_000)
        )

        let after = ProviderReducer.reduce(
            state: before,
            event: .gateChanged(replacement),
            now: failureAt
        )

        XCTAssertEqual(after.refresh.gate, replacement)
        XCTAssertEqual(after.id, before.id)
        XCTAssertEqual(after.capabilities, before.capabilities)
        XCTAssertEqual(after.connection, before.connection)
        XCTAssertEqual(after.presence, before.presence)
        XCTAssertEqual(after.authentication, before.authentication)
        XCTAssertEqual(after.refresh.activity, before.refresh.activity)
        XCTAssertEqual(after.refresh.lastAttemptAt, before.refresh.lastAttemptAt)
        XCTAssertEqual(after.refresh.lastSuccessAt, before.refresh.lastSuccessAt)
        XCTAssertEqual(after.lastGood, before.lastGood)
        XCTAssertEqual(after.freshness, before.freshness)
        XCTAssertEqual(after.discovery, before.discovery)
        XCTAssertEqual(after.persistence, before.persistence)
        XCTAssertEqual(after.scopedFailures, before.scopedFailures)
    }

    func testPartialSuccessMergesSuccessfulProductsWithoutDroppingRetainedFields() throws {
        let before = providerState()
        let retained = try XCTUnwrap(before.lastGood)
        let newProduct = product(
            sourceProductID: "coding-plan",
            canonicalOrder: 1,
            fetchedAt: failureAt
        )
        let patch = ProviderQuotaPatch(
            providerID: .ark,
            source: providerSource(),
            fetchedAt: failureAt,
            updatedProducts: [newProduct],
            balances: nil,
            resetEntitlements: nil
        )

        let after = ProviderReducer.reduce(
            state: before,
            event: .refreshPartiallySucceeded(patch, networkFailure()),
            now: failureAt
        )
        let merged = try XCTUnwrap(after.lastGood)

        XCTAssertEqual(merged.products.count, 2)
        XCTAssertEqual(merged.products.first?.id, retained.products.first?.id)
        XCTAssertEqual(
            merged.products.first?.metrics.first?.value,
            retained.products.first?.metrics.first?.value
        )
        XCTAssertEqual(merged.products.last, newProduct)
        assertStale(try XCTUnwrap(merged.products.first).state, evaluatedAt: failureAt)
        assertStale(
            try XCTUnwrap(merged.products.first?.metrics.first).state,
            evaluatedAt: failureAt
        )
        assertFresh(newProduct.state, asOf: failureAt)
        assertFresh(try XCTUnwrap(newProduct.metrics.first).state, asOf: failureAt)
        XCTAssertEqual(merged.balances.first?.amount, retained.balances.first?.amount)
        assertStale(try XCTUnwrap(merged.balances.first).state, evaluatedAt: failureAt)
        XCTAssertEqual(
            merged.resetEntitlements.first?.availableCount,
            retained.resetEntitlements.first?.availableCount
        )
        assertStale(
            try XCTUnwrap(merged.resetEntitlements.first).state,
            evaluatedAt: failureAt
        )
        XCTAssertEqual(after.refresh.lastSuccessAt, successAt)
        XCTAssertEqual(
            after.freshness,
            .stale(asOf: successAt, evaluatedAt: failureAt)
        )
    }

    func testCacheLoadMarksProviderProductMetricBalanceAndResetNodesStale() throws {
        let cached = quotaData()
        let initial = ProviderBootstrap.initialState(
            id: .ark,
            capabilities: providerState().capabilities,
            now: successAt.addingTimeInterval(-60)
        )

        let after = ProviderReducer.reduce(
            state: initial,
            event: .cacheLoaded(cached),
            now: failureAt
        )

        XCTAssertEqual(
            after.freshness,
            .stale(asOf: successAt, evaluatedAt: failureAt)
        )
        assertEveryNodeStale(in: try XCTUnwrap(after.lastGood), evaluatedAt: failureAt)
    }

    func testCacheClearedDropsOnlyRetainedQuotaAndPersistenceMetadata() {
        let before = providerState()

        let after = ProviderReducer.reduce(
            state: before,
            event: .cacheCleared,
            now: failureAt
        )

        XCTAssertNil(after.lastGood)
        XCTAssertEqual(after.freshness, .unknown)
        XCTAssertEqual(
            after.persistence,
            .healthy(lastReadAt: failureAt, lastWriteAt: nil)
        )
        XCTAssertEqual(after.id, before.id)
        XCTAssertEqual(after.capabilities, before.capabilities)
        XCTAssertEqual(after.connection, before.connection)
        XCTAssertEqual(after.presence, before.presence)
        XCTAssertEqual(after.authentication, before.authentication)
        XCTAssertEqual(after.refresh, before.refresh)
        XCTAssertEqual(after.discovery, before.discovery)
        XCTAssertEqual(after.scopedFailures, before.scopedFailures)
    }

    func testOperationsCancelledClearsTransientDiscoveryWithoutInventingEvidence() {
        let before = ProviderReducer.reduce(
            state: providerState(),
            event: .redetect(.started(generation: 10)),
            now: failureAt
        )
        let after = ProviderReducer.reduce(
            state: before, event: .operationsCancelled, now: failureAt
        )
        XCTAssertEqual(after.refresh.activity, .idle)
        XCTAssertEqual(after.discovery, .notStarted)
        XCTAssertEqual(after.connection, .unavailable(observedAt: nil))
        XCTAssertEqual(after.authentication, before.authentication)
        XCTAssertEqual(after.presence, before.presence)
        XCTAssertEqual(after.lastGood, before.lastGood)
        XCTAssertEqual(after.freshness, before.freshness)
        XCTAssertEqual(after.scopedFailures, before.scopedFailures)
        XCTAssertEqual(after.refresh.lastSuccessAt, before.refresh.lastSuccessAt)
    }

    func testOperationsCancelledPreservesEstablishedEvidenceAndGateForReadAndLogin() {
        for event in [
            ProviderEvent.refreshStarted(scope: .provider, generation: 10),
            .login(.started(method: .sso, generation: 10))
        ] {
            let before = ProviderReducer.reduce(state: providerState(), event: event, now: failureAt)
            var expected = before
            expected.refresh.activity = .idle
            let after = ProviderReducer.reduce(
                state: before, event: .operationsCancelled, now: failureAt
            )
            XCTAssertEqual(after, expected)
        }
    }

    func testAgeTickEvaluatesEachNodeFromItsOwnFreshnessDate() throws {
        let recentAt = failureAt.addingTimeInterval(-30)
        let oldData = quotaData()
        let recentProduct = product(
            sourceProductID: "coding-plan",
            canonicalOrder: 1,
            fetchedAt: recentAt
        )
        let mixedAgeData = ProviderQuotaData(
            providerID: .ark,
            source: providerSource(),
            fetchedAt: recentAt,
            products: [try XCTUnwrap(oldData.products.first), recentProduct],
            balances: oldData.balances,
            resetEntitlements: oldData.resetEntitlements
        )
        var before = providerState()
        before.lastGood = mixedAgeData
        before.freshness = .fresh(asOf: recentAt)

        let after = ProviderReducer.reduce(
            state: before,
            event: .ageTick(staleAfter: 60),
            now: failureAt
        )
        let aged = try XCTUnwrap(after.lastGood)

        XCTAssertEqual(after.freshness, .fresh(asOf: recentAt))
        assertStale(aged.products[0].state, evaluatedAt: failureAt)
        assertStale(try XCTUnwrap(aged.products[0].metrics.first).state, evaluatedAt: failureAt)
        assertFresh(aged.products[1].state, asOf: recentAt)
        assertFresh(try XCTUnwrap(aged.products[1].metrics.first).state, asOf: recentAt)
        assertStale(try XCTUnwrap(aged.balances.first).state, evaluatedAt: failureAt)
        assertStale(
            try XCTUnwrap(aged.resetEntitlements.first).state,
            evaluatedAt: failureAt
        )
    }

    func testEmptyPartialPatchPreservesAggregateSourceTimeAndStalesRetainedNodes() throws {
        let before = providerState()
        let previous = try XCTUnwrap(before.lastGood)
        let patch = ProviderQuotaPatch(
            providerID: .ark,
            source: ProviderSourceIdentity(
                providerID: .ark,
                adapterID: "ark.cli.next",
                executableIdentity: "ark-selected-v2",
                cliVersion: "1.0.14",
                schemaVersion: "usage-plan-v2",
                contractVersion: "provider-contract-v0.9"
            ),
            fetchedAt: failureAt,
            productMutations: [],
            balanceMutation: .retain,
            resetEntitlementMutation: .retain
        )

        let after = ProviderReducer.reduce(
            state: before,
            event: .refreshPartiallySucceeded(patch, networkFailure()),
            now: failureAt
        )
        let retained = try XCTUnwrap(after.lastGood)

        XCTAssertEqual(retained.fetchedAt, previous.fetchedAt)
        XCTAssertEqual(retained.source, previous.source)
        assertEveryNodeStale(in: retained, evaluatedAt: failureAt)
    }

    func testExplicitMutationClearsOnlyCurrentInferredPlan() throws {
        let inferred = replacingPlan(
            in: product(
                sourceProductID: "agent-plan",
                canonicalOrder: 0,
                fetchedAt: successAt
            ),
            with: PlanLevelObservation(
                value: "Max",
                origin: .inferred(
                    ruleID: "rule-v1",
                    catalogID: "catalog-v1",
                    sourceVersion: "1.0.19",
                    evidenceFields: ["video.current.totalCount"]
                ),
                contractVersion: "provider-contract-v0.8",
                fetchedAt: successAt
            )
        )
        let reported = product(
            sourceProductID: "coding-plan",
            canonicalOrder: 1,
            fetchedAt: successAt
        )
        var before = providerState()
        before.lastGood = replacingProducts(in: try XCTUnwrap(before.lastGood), with: [inferred, reported])
        let patch = ProviderQuotaPatch(
            providerID: .ark,
            source: providerSource(),
            fetchedAt: failureAt,
            productMutations: [
                .mutate(
                    id: inferred.id,
                    mutation: QuotaProductNodeMutation(planLevel: .clearCurrentInferred)
                ),
                .mutate(
                    id: reported.id,
                    mutation: QuotaProductNodeMutation(planLevel: .clearCurrentInferred)
                )
            ],
            balanceMutation: .retain,
            resetEntitlementMutation: .retain
        )

        let after = ProviderReducer.reduce(
            state: before,
            event: .refreshPartiallySucceeded(patch, networkFailure()),
            now: failureAt
        )
        let products = try XCTUnwrap(after.lastGood).products

        XCTAssertNil(products[0].planLevel)
        XCTAssertEqual(products[1].planLevel, reported.planLevel)
        assertStale(products[0].state, evaluatedAt: failureAt)
        assertStale(products[1].state, evaluatedAt: failureAt)
    }

    func testFailedProductMutationRetainsPayloadButUpdatesFailureWhileSiblingIsFresh() throws {
        let agent = product(
            sourceProductID: "agent-plan",
            canonicalOrder: 0,
            fetchedAt: successAt
        )
        let oldCoding = product(
            sourceProductID: "coding-plan",
            canonicalOrder: 1,
            fetchedAt: successAt
        )
        let freshCoding = product(
            sourceProductID: "coding-plan",
            canonicalOrder: 1,
            fetchedAt: failureAt
        )
        var before = providerState()
        before.lastGood = replacingProducts(
            in: try XCTUnwrap(before.lastGood),
            with: [agent, oldCoding]
        )
        let productFailure = ProviderFailure(
            code: .serviceUnavailable,
            retryClass: .backoff,
            userMessageKey: "provider.failure.service",
            diagnosticCode: "ark.product.agent.item_error",
            recovery: .retry
        )
        let patch = ProviderQuotaPatch(
            providerID: .ark,
            source: providerSource(),
            fetchedAt: failureAt,
            productMutations: [
                .mutate(
                    id: agent.id,
                    mutation: QuotaProductNodeMutation(
                        state: QuotaNodeMutation(failure: .replace(productFailure))
                    )
                ),
                .replace(freshCoding)
            ],
            balanceMutation: .retain,
            resetEntitlementMutation: .retain
        )

        let after = ProviderReducer.reduce(
            state: before,
            event: .refreshPartiallySucceeded(patch, networkFailure()),
            now: failureAt
        )
        let merged = try XCTUnwrap(after.lastGood)
        let retainedAgent = try XCTUnwrap(merged.products.first { $0.id == agent.id })
        let updatedCoding = try XCTUnwrap(merged.products.first { $0.id == freshCoding.id })

        XCTAssertEqual(retainedAgent.metrics.map(\.value), agent.metrics.map(\.value))
        XCTAssertEqual(retainedAgent.state.failure, productFailure)
        assertStale(retainedAgent.state, evaluatedAt: failureAt)
        assertStale(try XCTUnwrap(retainedAgent.metrics.first).state, evaluatedAt: failureAt)
        XCTAssertEqual(updatedCoding, freshCoding)
        assertFresh(updatedCoding.state, asOf: failureAt)
    }

    func testDiscoveryReadAndLoginFailuresRemainIndependentUntilTheirScopeSucceeds() {
        let discoveryFailure = ProviderFailure(
            code: .schemaMismatch,
            retryClass: .never,
            userMessageKey: "provider.failure.schema",
            diagnosticCode: "fixture.discovery.schema",
            recovery: nil
        )
        let loginFailure = ProviderFailure(
            code: .authenticationRequired,
            retryClass: .afterRecovery,
            userMessageKey: "provider.failure.login",
            diagnosticCode: "fixture.login.required",
            recovery: .login(.sso)
        )
        var state = providerState()
        state = ProviderReducer.reduce(
            state: state,
            event: .discovery(.failed(discoveryFailure)),
            now: failureAt
        )
        state = ProviderReducer.reduce(
            state: state,
            event: .refreshStarted(scope: .provider, generation: 8),
            now: failureAt.addingTimeInterval(1)
        )
        state = ProviderReducer.reduce(
            state: state,
            event: .refreshFailed(networkFailure()),
            now: failureAt.addingTimeInterval(2)
        )
        state = ProviderReducer.reduce(
            state: state,
            event: .login(.failed(loginFailure)),
            now: failureAt.addingTimeInterval(3)
        )

        XCTAssertEqual(state.scopedFailures.entries.count, 3)
        XCTAssertEqual(state.failure, loginFailure)

        let discovery = successfulDiscovery(observedAt: failureAt.addingTimeInterval(4))
        state = ProviderReducer.reduce(
            state: state,
            event: .discovery(.succeeded(discovery)),
            now: failureAt.addingTimeInterval(4)
        )
        XCTAssertNil(state.scopedFailures.failure(for: .discovery))
        XCTAssertEqual(
            state.scopedFailures.failure(for: .read(.provider)),
            networkFailure()
        )
        XCTAssertEqual(state.scopedFailures.failure(for: .login), loginFailure)
        XCTAssertEqual(state.failure, loginFailure)

        state = ProviderReducer.reduce(
            state: state,
            event: .refreshStarted(scope: .provider, generation: 9),
            now: failureAt.addingTimeInterval(5)
        )
        state = ProviderReducer.reduce(
            state: state,
            event: .refreshSucceeded(quotaData()),
            now: failureAt.addingTimeInterval(6)
        )
        XCTAssertNil(state.scopedFailures.failure(for: .read(.provider)))
        XCTAssertEqual(state.failure, loginFailure)

        state = ProviderReducer.reduce(
            state: state,
            event: .login(.recoverySucceeded),
            now: failureAt.addingTimeInterval(7)
        )
        XCTAssertNil(state.failure)
        XCTAssertTrue(state.scopedFailures.entries.isEmpty)
    }

    func testProductReadSuccessClearsOnlyTheCoveredReadFailureScope() {
        let agentID = ProductID(providerID: .ark, sourceProductID: "agent-plan")
        let codingID = ProductID(providerID: .ark, sourceProductID: "coding-plan")
        let agentFailure = ProviderFailure(
            code: .serviceUnavailable,
            retryClass: .backoff,
            userMessageKey: "provider.failure.agent",
            diagnosticCode: "ark.agent.failed",
            recovery: .retry
        )
        let codingFailure = ProviderFailure(
            code: .schemaMismatch,
            retryClass: .never,
            userMessageKey: "provider.failure.coding",
            diagnosticCode: "ark.coding.failed",
            recovery: nil
        )
        var state = providerState()

        state = ProviderReducer.reduce(
            state: state,
            event: .refreshStarted(scope: .product(agentID), generation: 10),
            now: failureAt
        )
        state = ProviderReducer.reduce(
            state: state,
            event: .refreshFailed(agentFailure),
            now: failureAt.addingTimeInterval(1)
        )
        state = ProviderReducer.reduce(
            state: state,
            event: .refreshStarted(scope: .product(codingID), generation: 11),
            now: failureAt.addingTimeInterval(2)
        )
        state = ProviderReducer.reduce(
            state: state,
            event: .refreshFailed(codingFailure),
            now: failureAt.addingTimeInterval(3)
        )
        state = ProviderReducer.reduce(
            state: state,
            event: .refreshStarted(scope: .product(agentID), generation: 12),
            now: failureAt.addingTimeInterval(4)
        )
        state = ProviderReducer.reduce(
            state: state,
            event: .refreshSucceeded(quotaData()),
            now: failureAt.addingTimeInterval(5)
        )

        XCTAssertNil(state.scopedFailures.failure(for: .read(.product(agentID))))
        XCTAssertEqual(
            state.scopedFailures.failure(for: .read(.product(codingID))),
            codingFailure
        )
        XCTAssertEqual(state.failure, codingFailure)
    }

    func testReducerRejectsNestedForeignProvenanceAndDuplicateProductIDs() throws {
        let valid = quotaData()
        let product = try XCTUnwrap(valid.products.first)
        let metric = try XCTUnwrap(product.metrics.first)
        let foreignSource = ProviderSourceIdentity(
            providerID: .miniMax,
            adapterID: "malicious.adapter",
            executableIdentity: "mixed",
            cliVersion: "0",
            schemaVersion: "mixed",
            contractVersion: "mixed"
        )
        let maliciousMetric = QuotaMetric(
            id: metric.id,
            sourceMetricID: metric.sourceMetricID,
            sourceLabel: metric.sourceLabel,
            window: metric.window,
            value: metric.value,
            sourceStatus: metric.sourceStatus,
            provenance: MetricProvenance(
                sourceIdentity: metric.id.sourceIdentity,
                providerSource: foreignSource,
                fetchedAt: metric.provenance.fetchedAt
            ),
            state: metric.state
        )
        let maliciousProduct = replacingMetrics(in: product, with: [maliciousMetric])
        let malicious = ProviderQuotaData(
            providerID: .ark,
            source: providerSource(),
            fetchedAt: successAt,
            products: [maliciousProduct],
            balances: [],
            resetEntitlements: []
        )
        let before = providerState()

        let foreignRejected = ProviderReducer.reduce(
            state: before,
            event: .refreshSucceeded(malicious),
            now: failureAt
        )
        XCTAssertEqual(foreignRejected.failure?.code, .identityMismatch)
        XCTAssertEqual(foreignRejected.lastGood?.products.map(\.id), before.lastGood?.products.map(\.id))

        let duplicate = ProviderQuotaData(
            providerID: .ark,
            source: providerSource(),
            fetchedAt: successAt,
            products: [product, product],
            balances: [],
            resetEntitlements: []
        )
        let duplicateRejected = ProviderReducer.reduce(
            state: before,
            event: .refreshSucceeded(duplicate),
            now: failureAt
        )
        XCTAssertEqual(duplicateRejected.failure?.code, .identityMismatch)
        XCTAssertNotNil(
            duplicateRejected.scopedFailures.failure(for: .identityValidation)
        )
    }

    func testExplicitFailedMetricMergeRetainsByIDAndPreservesSiblingCollections() throws {
        var before = providerState()
        let old = try XCTUnwrap(before.lastGood?.products.first)
        let oldMetric = try XCTUnwrap(old.metrics.first)
        let sibling = product(sourceProductID: "coding-plan", canonicalOrder: 1, fetchedAt: successAt)
        before.lastGood = replacingProducts(in: try XCTUnwrap(before.lastGood), with: [old, sibling])
        let fresh = mergeMetric(bucket: "monthly", at: failureAt)
        let failed = mergeMetric(bucket: "weekly", at: failureAt, failed: true)
        let incoming = mergeProduct(metrics: [fresh, failed])
        let patch = ProviderQuotaPatch(
            providerID: .ark, source: providerSource(), fetchedAt: failureAt,
            productMutations: [.replaceRetainingFailedMetrics(incoming)],
            balanceMutation: .retain, resetEntitlementMutation: .replace([])
        )
        XCTAssertEqual(patch.productMutations.first?.productID, incoming.id)
        XCTAssertEqual(patch.updatedProducts, [incoming])
        let after = ProviderReducer.reduce(
            state: before, event: .refreshPartiallySucceeded(patch, networkFailure()), now: failureAt
        )
        let merged = try XCTUnwrap(after.lastGood)
        let updated = try XCTUnwrap(merged.products.first)
        XCTAssertEqual(updated.metrics.first, fresh, "Matching must use MetricID, not array position")
        let retained = try XCTUnwrap(updated.metrics.last)
        XCTAssertEqual(retained.value, oldMetric.value)
        XCTAssertEqual(retained.window, oldMetric.window)
        XCTAssertEqual(retained.provenance, oldMetric.provenance)
        XCTAssertEqual(retained.sourceStatus, oldMetric.sourceStatus)
        XCTAssertEqual(retained.sourceLabel, oldMetric.sourceLabel)
        XCTAssertEqual(retained.state.failure, failed.state.failure)
        XCTAssertEqual(retained.state.lastSuccessAt, successAt)
        XCTAssertEqual(retained.state.refresh.lastSuccessAt, successAt)
        XCTAssertEqual(retained.state.lastAttemptAt, failureAt)
        XCTAssertEqual(retained.state.freshness, .stale(asOf: successAt, evaluatedAt: failureAt))
        XCTAssertEqual(updated.state.lastSuccessAt, successAt)
        XCTAssertEqual(updated.state.failure, incoming.state.failure)
        XCTAssertNil(updated.planLevel)
        XCTAssertEqual(merged.products.last?.metrics.map(\.value), sibling.metrics.map(\.value))
        assertStale(try XCTUnwrap(merged.products.last).state, evaluatedAt: failureAt)
        XCTAssertEqual(merged.balances.first?.amount, before.lastGood?.balances.first?.amount)
        assertStale(try XCTUnwrap(merged.balances.first).state, evaluatedAt: failureAt)
        XCTAssertTrue(merged.resetEntitlements.isEmpty)
        XCTAssertEqual(after.refresh.lastSuccessAt, before.refresh.lastSuccessAt)
    }

    func testOrdinaryProductReplacementStillReplacesFailedMetrics() throws {
        let incoming = mergeProduct(metrics: [mergeMetric(bucket: "weekly", at: failureAt, failed: true)])
        let patch = ProviderQuotaPatch(
            providerID: .ark, source: providerSource(), fetchedAt: failureAt,
            productMutations: [.replace(incoming)],
            balanceMutation: .retain, resetEntitlementMutation: .retain
        )
        let after = ProviderReducer.reduce(
            state: providerState(), event: .refreshPartiallySucceeded(patch, networkFailure()), now: failureAt
        )
        XCTAssertEqual(after.lastGood?.products.first, incoming, "Existing replace semantics must not change")
    }

    func testFailedMetricMergeCannotResurrectUnavailableOrAbsentHistory() throws {
        let failed = mergeMetric(bucket: "weekly", at: failureAt, failed: true)
        let incoming = mergeProduct(metrics: [failed])
        let patch = ProviderQuotaPatch(
            providerID: .ark, source: providerSource(), fetchedAt: failureAt,
            productMutations: [.replaceRetainingFailedMetrics(incoming)],
            balanceMutation: .retain, resetEntitlementMutation: .retain
        )
        for hasUnavailableHistory in [false, true] {
            var before = providerState()
            before.lastGood = hasUnavailableHistory
                ? replacingProducts(in: quotaData(), with: [mergeProduct(metrics: [
                    mergeMetric(bucket: "weekly", at: successAt, failed: true)
                ])])
                : nil
            for _ in 0..<2 {
                before = ProviderReducer.reduce(
                    state: before, event: .refreshPartiallySucceeded(patch, networkFailure()), now: failureAt
                )
                let actual = try XCTUnwrap(before.lastGood?.products.first?.metrics.first)
                XCTAssertEqual(actual, failed)
                XCTAssertEqual(actual.state.freshness, .unknown)
                XCTAssertNil(actual.state.lastSuccessAt)
            }
        }
    }

    func testFailedMetricMergeTreatsMissingMetricsAsCurrentAbsence() throws {
        let incoming = mergeProduct(metrics: [])
        let patch = ProviderQuotaPatch(
            providerID: .ark, source: providerSource(), fetchedAt: failureAt,
            productMutations: [.replaceRetainingFailedMetrics(incoming)],
            balanceMutation: .retain, resetEntitlementMutation: .retain
        )
        let after = ProviderReducer.reduce(
            state: providerState(), event: .refreshPatchSucceeded(patch), now: failureAt
        )
        XCTAssertEqual(after.lastGood?.products.first, incoming)
    }

    func testFailedMetricMergeRejectsInvalidIdentityBeforeRetainingOldPayload() throws {
        let failed = mergeMetric(bucket: "weekly", at: failureAt, failed: true)
        let foreign = QuotaMetric(
            id: failed.id, sourceMetricID: failed.sourceMetricID,
            sourceLabel: failed.sourceLabel, window: failed.window, value: failed.value,
            sourceStatus: failed.sourceStatus,
            provenance: MetricProvenance(
                sourceIdentity: failed.id.sourceIdentity,
                providerSource: ProviderSourceIdentity(
                    providerID: .miniMax, adapterID: "foreign", executableIdentity: "foreign",
                    cliVersion: "1", schemaVersion: "1", contractVersion: "1"
                ),
                fetchedAt: failureAt
            ),
            state: failed.state
        )
        for metrics in [[foreign], [failed, failed]] {
            let before = providerState()
            let patch = ProviderQuotaPatch(
                providerID: .ark, source: providerSource(), fetchedAt: failureAt,
                productMutations: [.replaceRetainingFailedMetrics(mergeProduct(metrics: metrics))],
                balanceMutation: .retain, resetEntitlementMutation: .retain
            )
            let after = ProviderReducer.reduce(
                state: before, event: .refreshPartiallySucceeded(patch, networkFailure()), now: failureAt
            )
            XCTAssertEqual(after.failure?.code, .identityMismatch)
            assertSameRetainedPayload(after.lastGood, before.lastGood)
        }
    }

    private func mergeMetric(bucket: String, at date: Date, failed: Bool = false) -> QuotaMetric {
        let provenance = provenance(product: "agent-plan", bucket: bucket, metric: "percent", fetchedAt: date)
        var state = nodeState(fetchedAt: date)
        if failed {
            state.freshness = .unknown
            state.lastSuccessAt = nil
            state.refresh.lastSuccessAt = nil
            state.failure = networkFailure()
        }
        return QuotaMetric(
            id: MetricID(sourceIdentity: provenance.sourceIdentity), sourceMetricID: "percent",
            sourceLabel: "Current \(bucket)", window: nil,
            value: failed ? .unavailable(reason: .invalidSourceValue(field: "percent"))
                : .percent(DirectedPercent(sourceValue: 75, sourceDirection: .used)),
            sourceStatus: SourceStatus(code: "current", message: nil),
            provenance: provenance, state: state
        )
    }

    private func mergeProduct(metrics: [QuotaMetric]) -> QuotaProductData {
        var state = nodeState(fetchedAt: failureAt)
        if let failure = metrics.compactMap(\.state.failure).first {
            state.freshness = .unknown
            state.lastSuccessAt = nil
            state.refresh.lastSuccessAt = nil
            state.failure = failure
        }
        return QuotaProductData(
            id: ProductID(providerID: .ark, sourceProductID: "agent-plan"),
            sourceProductID: "agent-plan", titleKey: "provider.ark.agent-plan",
            canonicalOrder: 0, planLevel: nil, state: state, metrics: metrics
        )
    }

    private func providerState() -> ProviderState {
        let authEvidence = AuthenticationEvidence(
            authority: .providerReport(
                sourceField: "viewer.authenticated",
                contractVersion: "provider-contract-v0.8"
            ),
            observedAt: successAt
        )

        return ProviderState(
            id: .ark,
            capabilities: ProviderCapabilities(
                contractVersion: "provider-contract-v0.8",
                loginMethod: .sso,
                hasOfficialDocumentation: true,
                allowsExecutableSelection: true
            ),
            connection: .connected(observedAt: successAt),
            presence: .unknown,
            authentication: .healthy(authEvidence),
            refresh: RefreshState(
                activity: .refreshing(
                    scope: .provider,
                    generation: 7,
                    startedAt: failureAt.addingTimeInterval(-10)
                ),
                gate: .backoff(
                    until: MonotonicInstant(nanoseconds: 9_000),
                    attempt: 2
                ),
                lastAttemptAt: failureAt.addingTimeInterval(-10),
                lastSuccessAt: successAt
            ),
            lastGood: quotaData(),
            freshness: .fresh(asOf: successAt),
            discovery: .succeeded(
                authority: DiscoveryAuthority(
                    source: providerSource(),
                    operationID: "ark.usage-plan.discovery.v1"
                ),
                observedAt: successAt
            ),
            persistence: .healthy(
                lastReadAt: successAt,
                lastWriteAt: successAt.addingTimeInterval(1)
            ),
            failure: nil
        )
    }

    private func quotaData() -> ProviderQuotaData {
        let source = providerSource()
        let metricProvenance = provenance(
            product: "agent-plan",
            bucket: "weekly",
            metric: "percent",
            fetchedAt: successAt
        )
        return ProviderQuotaData(
            providerID: .ark,
            source: source,
            fetchedAt: successAt,
            products: [
                product(
                    sourceProductID: "agent-plan",
                    canonicalOrder: 0,
                    fetchedAt: successAt
                )
            ],
            balances: [
                QuotaBalance(
                    sourceBalanceID: "credits",
                    amount: 12,
                    unit: "credits",
                    provenance: metricProvenance,
                    state: nodeState(fetchedAt: successAt)
                )
            ],
            resetEntitlements: [
                ResetEntitlementSummary(
                    availableCount: 1,
                    details: nil,
                    provenance: metricProvenance
                )
            ]
        )
    }

    private func product(
        sourceProductID: String,
        canonicalOrder: Int,
        fetchedAt: Date
    ) -> QuotaProductData {
        let identity = MetricSourceIdentity(
            providerID: .ark,
            sourceProductID: sourceProductID,
            sourceBucketID: "weekly",
            sourceMetricID: "percent"
        )
        let metric = QuotaMetric(
            id: MetricID(sourceIdentity: identity),
            sourceMetricID: "percent",
            sourceLabel: "Weekly source label",
            window: QuotaWindow(
                kind: .weekly,
                duration: nil,
                startsAt: nil,
                endsAt: fetchedAt.addingTimeInterval(7 * 86_400),
                timeEvent: QuotaTimeEvent(
                    kind: .reset,
                    occursAt: fetchedAt.addingTimeInterval(7 * 86_400)
                )
            ),
            value: .percent(
                DirectedPercent(sourceValue: 13, sourceDirection: .used)
            ),
            sourceStatus: SourceStatus(code: "active", message: nil),
            provenance: provenance(
                product: sourceProductID,
                bucket: "weekly",
                metric: "percent",
                fetchedAt: fetchedAt
            ),
            state: nodeState(fetchedAt: fetchedAt)
        )

        return QuotaProductData(
            id: ProductID(providerID: .ark, sourceProductID: sourceProductID),
            sourceProductID: sourceProductID,
            titleKey: "provider.ark.\(sourceProductID)",
            canonicalOrder: canonicalOrder,
            planLevel: PlanLevelObservation(
                value: "medium",
                origin: .reported(sourceField: "tier"),
                contractVersion: "provider-contract-v0.8",
                fetchedAt: fetchedAt
            ),
            state: nodeState(fetchedAt: fetchedAt),
            metrics: [metric]
        )
    }

    private func nodeState(fetchedAt: Date) -> QuotaNodeState {
        QuotaNodeState(
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
    }

    private func providerSource() -> ProviderSourceIdentity {
        ProviderSourceIdentity(
            providerID: .ark,
            adapterID: "ark.cli",
            executableIdentity: "ark-selected-v1",
            cliVersion: "1.0.13",
            schemaVersion: "usage-plan-v1",
            contractVersion: "provider-contract-v0.8"
        )
    }

    private func provenance(
        product: String,
        bucket: String,
        metric: String,
        fetchedAt: Date
    ) -> MetricProvenance {
        MetricProvenance(
            sourceIdentity: MetricSourceIdentity(
                providerID: .ark,
                sourceProductID: product,
                sourceBucketID: bucket,
                sourceMetricID: metric
            ),
            providerSource: providerSource(),
            fetchedAt: fetchedAt
        )
    }

    private func replacingProducts(
        in data: ProviderQuotaData,
        with products: [QuotaProductData]
    ) -> ProviderQuotaData {
        ProviderQuotaData(
            providerID: data.providerID,
            source: data.source,
            fetchedAt: data.fetchedAt,
            products: products,
            balances: data.balances,
            resetEntitlements: data.resetEntitlements
        )
    }

    private func replacingPlan(
        in product: QuotaProductData,
        with planLevel: PlanLevelObservation?
    ) -> QuotaProductData {
        QuotaProductData(
            id: product.id,
            sourceProductID: product.sourceProductID,
            titleKey: product.titleKey,
            canonicalOrder: product.canonicalOrder,
            planLevel: planLevel,
            state: product.state,
            metrics: product.metrics
        )
    }

    private func replacingMetrics(
        in product: QuotaProductData,
        with metrics: [QuotaMetric]
    ) -> QuotaProductData {
        QuotaProductData(
            id: product.id,
            sourceProductID: product.sourceProductID,
            titleKey: product.titleKey,
            canonicalOrder: product.canonicalOrder,
            planLevel: product.planLevel,
            state: product.state,
            metrics: metrics
        )
    }

    private func successfulDiscovery(observedAt: Date) -> SuccessfulProviderDiscovery {
        let evidence = AuthenticationEvidence(
            authority: .providerReport(
                sourceField: "viewer.authenticated",
                contractVersion: "provider-contract-v0.8"
            ),
            observedAt: observedAt
        )
        return SuccessfulProviderDiscovery(
            providerID: .ark,
            authority: DiscoveryAuthority(
                source: providerSource(),
                operationID: "ark.usage-plan.discovery.v1"
            ),
            observedAt: observedAt,
            connection: .connected,
            authentication: .healthy(evidence),
            presence: .entitled
        )
    }

    private func assertEveryNodeStale(
        in data: ProviderQuotaData,
        evaluatedAt: Date,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        for product in data.products {
            assertStale(product.state, evaluatedAt: evaluatedAt, file: file, line: line)
            for metric in product.metrics {
                assertStale(metric.state, evaluatedAt: evaluatedAt, file: file, line: line)
            }
        }
        for balance in data.balances {
            assertStale(balance.state, evaluatedAt: evaluatedAt, file: file, line: line)
        }
        for reset in data.resetEntitlements {
            assertStale(reset.state, evaluatedAt: evaluatedAt, file: file, line: line)
        }
    }

    private func assertSameRetainedPayload(
        _ actual: ProviderQuotaData?,
        _ expected: ProviderQuotaData?,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(actual?.providerID, expected?.providerID, file: file, line: line)
        XCTAssertEqual(actual?.source, expected?.source, file: file, line: line)
        XCTAssertEqual(actual?.fetchedAt, expected?.fetchedAt, file: file, line: line)
        XCTAssertEqual(actual?.products.map(\.id), expected?.products.map(\.id), file: file, line: line)
        XCTAssertEqual(
            actual?.products.flatMap(\.metrics).map(\.value),
            expected?.products.flatMap(\.metrics).map(\.value),
            file: file,
            line: line
        )
        XCTAssertEqual(
            actual?.balances.map(\.amount),
            expected?.balances.map(\.amount),
            file: file,
            line: line
        )
        XCTAssertEqual(
            actual?.resetEntitlements.map(\.availableCount),
            expected?.resetEntitlements.map(\.availableCount),
            file: file,
            line: line
        )
    }

    private func assertStale(
        _ state: QuotaNodeState,
        evaluatedAt: Date,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard case let .stale(_, actualEvaluatedAt) = state.freshness else {
            return XCTFail("Expected stale node, got \(state.freshness)", file: file, line: line)
        }
        XCTAssertEqual(actualEvaluatedAt, evaluatedAt, file: file, line: line)
    }

    private func assertFresh(
        _ state: QuotaNodeState,
        asOf: Date,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(state.freshness, .fresh(asOf: asOf), file: file, line: line)
    }

    private func networkFailure() -> ProviderFailure {
        ProviderFailure(
            code: .networkUnavailable,
            retryClass: .backoff,
            userMessageKey: "provider.failure.network",
            diagnosticCode: "fixture.network.offline",
            recovery: .retry
        )
    }
}
