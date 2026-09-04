import Foundation
import UsageButlerDomain

public enum ProviderLoginEvent: Equatable, Sendable {
    case started(method: LoginMethod, generation: UInt64)
    case cancelled
    case failed(ProviderFailure)
    case recoverySucceeded
}

public enum ProviderRedetectEvent: Equatable, Sendable {
    case started(generation: UInt64)
    case cancelled
}

public enum ProviderDiscoveryEvent: Equatable, Sendable {
    case succeeded(SuccessfulProviderDiscovery)
    case failed(ProviderFailure)
}

public enum ProviderEvent: Equatable, Sendable {
    case cacheLoaded(ProviderQuotaData)
    case cacheLoadFailed(ProviderFailure)
    case cacheCleared
    case operationsCancelled
    case refreshStarted(scope: ProviderScope, generation: UInt64)
    case refreshSucceeded(ProviderQuotaData)
    case refreshPatchSucceeded(ProviderQuotaPatch)
    case refreshPartiallySucceeded(ProviderQuotaPatch, ProviderFailure)
    case refreshFailed(ProviderFailure)
    case authenticationObserved(AuthenticationState)
    case gateChanged(RefreshGateState)
    case ageTick(staleAfter: TimeInterval)
    case gateReset
    case login(ProviderLoginEvent)
    case redetect(ProviderRedetectEvent)
    case discovery(ProviderDiscoveryEvent)
    case persistenceChanged(PersistenceHealth)
    case disabled
    case shutdown
    case shutdownCompleted
}

public enum ProviderReducer {
    public static func reduce(
        state: ProviderState,
        event: ProviderEvent,
        now: Date
    ) -> ProviderState {
        var next = state

        switch event {
        case let .cacheLoaded(data):
            guard dataBelongsToState(data, state: state) else {
                return rejectingIdentityMismatch(state: state, now: now)
            }
            next.lastGood = markingAllNodesStale(in: data, now: now)
            next.freshness = .stale(asOf: data.fetchedAt, evaluatedAt: now)
            next.persistence = .healthy(
                lastReadAt: now,
                lastWriteAt: lastWriteAt(from: state.persistence)
            )
            next.scopedFailures.clear(.identityValidation)

        case let .cacheLoadFailed(failure):
            next.persistence = .degraded(failure)

        case .cacheCleared:
            next.lastGood = nil
            next.freshness = .unknown
            next.persistence = .healthy(lastReadAt: now, lastWriteAt: nil)

        case .operationsCancelled:
            next.refresh.activity = .idle
            if case .detecting = next.discovery {
                next.discovery = .notStarted
            }
            if case .detecting = next.connection {
                next.connection = .unavailable(observedAt: nil)
            }

        case let .refreshStarted(scope, generation):
            next.refresh.activity = .refreshing(
                scope: scope,
                generation: generation,
                startedAt: now
            )
            next.refresh.lastAttemptAt = now

        case let .refreshSucceeded(data):
            let scope = activeReadScope(in: state)
            guard dataBelongsToState(data, state: state) else {
                return rejectingIdentityMismatch(state: state, now: now)
            }
            next.refresh.activity = .idle
            next.refresh.gate = .open
            next.refresh.lastSuccessAt = now
            next.lastGood = data
            next.freshness = .fresh(asOf: data.fetchedAt)
            next.scopedFailures.clearReadFailures(resolvedBy: scope)
            next.scopedFailures.clear(.identityValidation)

        case let .refreshPatchSucceeded(patch):
            let scope = activeReadScope(in: state)
            guard patchBelongsToState(patch, state: state) else {
                return rejectingIdentityMismatch(state: state, now: now)
            }
            guard let merged = merging(
                patch: patch,
                into: state.lastGood,
                now: now
            ), dataBelongsToState(merged, state: state) else {
                return rejectingIdentityMismatch(state: state, now: now)
            }
            next.refresh.activity = .idle
            next.refresh.gate = .open
            next.refresh.lastSuccessAt = now
            next.lastGood = merged
            if let staleAsOf = latestStaleVisibleNodeDate(in: merged) {
                next.freshness = .stale(asOf: staleAsOf, evaluatedAt: now)
            } else {
                next.freshness = .fresh(asOf: patch.fetchedAt)
            }
            next.scopedFailures.clearReadFailures(resolvedBy: scope)
            next.scopedFailures.clear(.identityValidation)

        case let .refreshPartiallySucceeded(patch, failure):
            let scope = activeReadScope(in: state)
            guard patchBelongsToState(patch, state: state) else {
                return rejectingIdentityMismatch(state: state, now: now)
            }
            guard let merged = merging(
                patch: patch,
                into: state.lastGood,
                now: now
            ), dataBelongsToState(merged, state: state) else {
                return rejectingIdentityMismatch(state: state, now: now)
            }
            next.refresh.activity = .idle
            next.lastGood = merged
            next.scopedFailures.clear(.identityValidation)
            next.scopedFailures.record(failure, scope: .read(scope), at: now)
            markProviderAggregateStale(state: &next, now: now)

        case let .refreshFailed(failure):
            let scope = activeReadScope(in: state)
            next.refresh.activity = .idle
            next.scopedFailures.record(failure, scope: .read(scope), at: now)
            markRetainedDataStale(state: &next, now: now)

        case let .gateChanged(gate):
            next.refresh.gate = gate

        case let .authenticationObserved(authentication):
            next.authentication = authentication
            if case .healthy = authentication,
               next.scopedFailures.failure(for: .login)?.code == .rateLimited {
                next.scopedFailures.clear(.login)
            }

        case let .ageTick(staleAfter):
            next.authentication = AuthenticationExpiryPolicy.evaluate(state.authentication, now: now)
            guard let lastGood = state.lastGood else { break }
            let threshold = max(0, staleAfter)
            let asOf = freshnessDate(from: state.freshness) ?? lastGood.fetchedAt
            if now.timeIntervalSince(asOf) >= threshold {
                next.freshness = .stale(asOf: asOf, evaluatedAt: now)
            }
            next.lastGood = agingNodes(
                in: lastGood,
                staleAfter: threshold,
                now: now
            )

        case .gateReset:
            next.refresh.gate = .open

        case let .login(loginEvent):
            reduceLogin(state: &next, event: loginEvent, now: now)

        case let .redetect(redetectEvent):
            reduceRedetect(state: &next, event: redetectEvent, now: now)

        case let .discovery(discoveryEvent):
            reduceDiscovery(state: &next, event: discoveryEvent, now: now)

        case let .persistenceChanged(health):
            next.persistence = health

        case .disabled:
            next.refresh.activity = .idle
            next.connection = .disabled
            markRetainedDataStale(state: &next, now: now)

        case .shutdown:
            next.refresh.activity = .shuttingDown(startedAt: now)
            next.connection = .disabled
            markRetainedDataStale(state: &next, now: now)

        case .shutdownCompleted:
            next.refresh.activity = .idle
        }

        return next
    }

    private static func reduceLogin(
        state: inout ProviderState,
        event: ProviderLoginEvent,
        now: Date
    ) {
        switch event {
        case let .started(method, generation):
            state.refresh.activity = .loggingIn(
                method: method,
                generation: generation,
                startedAt: now
            )
        case .cancelled:
            state.refresh.activity = .idle
        case let .failed(failure):
            state.refresh.activity = .idle
            state.scopedFailures.record(failure, scope: .login, at: now)
            markRetainedDataStale(state: &state, now: now)
        case .recoverySucceeded:
            // Login success is not quota or authentication evidence. It only opens gates.
            state.refresh.activity = .idle
            state.refresh.gate = .open
            state.scopedFailures.clear(.login)
        }
    }

    private static func reduceRedetect(
        state: inout ProviderState,
        event: ProviderRedetectEvent,
        now: Date
    ) {
        switch event {
        case let .started(generation):
            state.connection = .detecting(startedAt: now)
            state.discovery = .detecting(startedAt: now, generation: generation)
            state.refresh.activity = .detecting(generation: generation, startedAt: now)
            markRetainedDataStale(state: &state, now: now)
        case .cancelled:
            state.refresh.activity = .idle
        }
    }

    private static func reduceDiscovery(
        state: inout ProviderState,
        event: ProviderDiscoveryEvent,
        now: Date
    ) {
        switch event {
        case let .succeeded(discovery):
            guard discovery.providerID == state.id,
                  discovery.authority.source.providerID == state.id else {
                state = rejectingIdentityMismatch(state: state, now: now)
                return
            }

            state.discovery = .succeeded(
                authority: discovery.authority,
                observedAt: discovery.observedAt
            )
            state.authentication = discovery.authentication
            switch discovery.connection {
            case .connected:
                state.connection = .connected(observedAt: discovery.observedAt)
                // A healthy typed auth readback can heal the known OAuth
                // exchange-rate-limit failure after authorization later
                // completes outside the App. Connected alone is insufficient:
                // an unchanged expiring session is connected too.
                if case .healthy = discovery.authentication,
                   state.scopedFailures.failure(for: .login)?.code == .rateLimited {
                    state.scopedFailures.clear(.login)
                }
            case let .requiresLogin(evidence):
                state.connection = .requiresLogin(evidence)
            }

            if let resolvedPresence = discovery.resolvedPresence {
                state.presence = resolvedPresence
            }

            state.refresh.activity = .idle
            state.scopedFailures.clear(.discovery)
            state.scopedFailures.clear(.identityValidation)

        case let .failed(failure):
            state.discovery = .failed(at: now, diagnosticCode: failure.diagnosticCode)
            state.connection = .unavailable(observedAt: now)
            state.refresh.activity = .idle
            state.scopedFailures.record(failure, scope: .discovery, at: now)
            markRetainedDataStale(state: &state, now: now)
        }
    }

    private static func dataBelongsToState(
        _ data: ProviderQuotaData,
        state: ProviderState
    ) -> Bool {
        do {
            try ProviderQuotaIdentityValidator.validate(
                data,
                expectedProviderID: state.id
            )
            return true
        } catch {
            return false
        }
    }

    private static func patchBelongsToState(
        _ patch: ProviderQuotaPatch,
        state: ProviderState
    ) -> Bool {
        guard patch.providerID == state.id,
              patch.source.providerID == state.id else {
            return false
        }

        var targetIDs = Set<ProductID>()
        for mutation in patch.productMutations {
            guard mutation.productID.providerID == state.id,
                  targetIDs.insert(mutation.productID).inserted else {
                return false
            }
            if case let .replaceRetainingFailedMetrics(product) = mutation {
                // Validate the incoming identity before retained values could mask it.
                do {
                    try ProviderQuotaIdentityValidator.validate(
                        providerID: patch.providerID, source: patch.source,
                        products: [product], balances: [], resetEntitlements: [],
                        expectedProviderID: state.id
                    )
                } catch {
                    return false
                }
            }
        }
        return true
    }

    private static func rejectingIdentityMismatch(
        state: ProviderState,
        now: Date
    ) -> ProviderState {
        var next = state
        next.refresh.activity = .idle
        next.scopedFailures.record(
            ProviderFailure(
                code: .identityMismatch,
                retryClass: .never,
                userMessageKey: "provider.failure.identity-mismatch",
                diagnosticCode: "domain.provider.identity_mismatch",
                recovery: nil
            ),
            scope: .identityValidation,
            at: now
        )
        markRetainedDataStale(state: &next, now: now)
        return next
    }

    private static func markRetainedDataStale(
        state: inout ProviderState,
        now: Date
    ) {
        guard let lastGood = state.lastGood else { return }
        state.lastGood = markingAllNodesStale(in: lastGood, now: now)
        markProviderAggregateStale(state: &state, now: now)
    }

    private static func markProviderAggregateStale(
        state: inout ProviderState,
        now: Date
    ) {
        guard let lastGood = state.lastGood else { return }
        let asOf = freshnessDate(from: state.freshness) ?? lastGood.fetchedAt
        state.freshness = .stale(asOf: asOf, evaluatedAt: now)
    }

    private static func freshnessDate(from freshness: FreshnessState) -> Date? {
        switch freshness {
        case .unknown:
            nil
        case let .fresh(asOf), let .stale(asOf, _):
            asOf
        }
    }

    private static func merging(
        patch: ProviderQuotaPatch,
        into previous: ProviderQuotaData?,
        now: Date
    ) -> ProviderQuotaData? {
        let stalePrevious = previous.map { markingAllNodesStale(in: $0, now: now) }
        var products: [QuotaProductData]
        var hasAuthoritativePayloadUpdate = false

        switch patch.productCollectionMutation {
        case let .patch(mutations):
            products = stalePrevious?.products ?? []
            for productMutation in mutations {
                switch productMutation {
                case let .replace(product):
                    hasAuthoritativePayloadUpdate = true
                    if let index = products.firstIndex(where: { $0.id == product.id }) {
                        products[index] = product
                    } else {
                        products.append(product)
                    }
                case let .replaceRetainingFailedMetrics(product):
                    hasAuthoritativePayloadUpdate = true
                    if let index = products.firstIndex(where: { $0.id == product.id }) {
                        products[index] = retainingFailedMetrics(
                            in: product, from: products[index], now: now
                        )
                    } else {
                        products.append(product)
                    }
                case let .mutate(id, mutation):
                    guard let index = products.firstIndex(where: { $0.id == id }) else {
                        continue
                    }
                    products[index] = applying(mutation, to: products[index])
                }
            }
        case let .replaceAll(replacements):
            products = replacements
            hasAuthoritativePayloadUpdate = true
        }
        products.sort {
            if $0.canonicalOrder != $1.canonicalOrder {
                return $0.canonicalOrder < $1.canonicalOrder
            }
            return $0.sourceProductID < $1.sourceProductID
        }

        let balances: [QuotaBalance]
        switch patch.balanceMutation {
        case .retain:
            balances = stalePrevious?.balances ?? []
        case let .replace(replacements):
            balances = replacements
            hasAuthoritativePayloadUpdate = true
        }

        let resetEntitlements: [ResetEntitlementSummary]
        switch patch.resetEntitlementMutation {
        case .retain:
            resetEntitlements = stalePrevious?.resetEntitlements ?? []
        case let .replace(replacements):
            resetEntitlements = replacements
            hasAuthoritativePayloadUpdate = true
        }

        return ProviderQuotaData(
            providerID: patch.providerID,
            source: hasAuthoritativePayloadUpdate
                ? patch.source
                : previous?.source ?? patch.source,
            fetchedAt: hasAuthoritativePayloadUpdate
                ? patch.fetchedAt
                : previous?.fetchedAt ?? patch.fetchedAt,
            products: products,
            balances: balances,
            resetEntitlements: resetEntitlements
        )
    }

    private static func retainingFailedMetrics(
        in product: QuotaProductData,
        from previous: QuotaProductData,
        now: Date
    ) -> QuotaProductData {
        let metrics = product.metrics.map { metric in
            guard metric.state.failure != nil,
                  let retained = previous.metrics.first(where: { $0.id == metric.id }),
                  retained.state.lastSuccessAt != nil else { return metric }
            if case .unavailable = retained.value { return metric }
            return QuotaMetric(
                id: retained.id,
                sourceMetricID: retained.sourceMetricID,
                sourceLabel: retained.sourceLabel,
                window: retained.window,
                value: retained.value,
                sourceStatus: retained.sourceStatus,
                provenance: retained.provenance,
                state: retainingSuccess(in: metric.state, from: retained.state, now: now)
            )
        }
        return QuotaProductData(
            id: product.id,
            sourceProductID: product.sourceProductID,
            titleKey: product.titleKey,
            canonicalOrder: product.canonicalOrder,
            planLevel: product.planLevel,
            state: product.state.failure == nil ? product.state
                : retainingSuccess(in: product.state, from: previous.state, now: now),
            metrics: metrics
        )
    }

    private static func retainingSuccess(
        in failed: QuotaNodeState,
        from previous: QuotaNodeState,
        now: Date
    ) -> QuotaNodeState {
        var state = failed
        if case .unknown = state.presence {
            state.presence = previous.presence
        }
        state.lastSuccessAt = previous.lastSuccessAt
        state.refresh.lastSuccessAt = previous.refresh.lastSuccessAt
        state.freshness = previous.lastSuccessAt.map {
            .stale(asOf: freshnessDate(from: previous.freshness) ?? $0, evaluatedAt: now)
        } ?? .unknown
        return state
    }

    private static func latestStaleVisibleNodeDate(
        in data: ProviderQuotaData
    ) -> Date? {
        let freshness = data.products.flatMap { product in
            [product.state.freshness] + product.metrics.map(\.state.freshness)
        } + data.resetEntitlements.map(\.state.freshness)

        return freshness.compactMap { state -> Date? in
            guard case let .stale(asOf, _) = state else { return nil }
            return asOf
        }.max()
    }

    private static func applying(
        _ mutation: QuotaProductNodeMutation,
        to product: QuotaProductData
    ) -> QuotaProductData {
        let planLevel: PlanLevelObservation?
        switch mutation.planLevel {
        case .retain:
            planLevel = product.planLevel
        case let .replace(replacement):
            planLevel = replacement
        case .clearCurrentInferred:
            if let current = product.planLevel {
                switch current.origin {
                case .inferred:
                    planLevel = nil
                case .reported:
                    planLevel = current
                }
            } else {
                planLevel = nil
            }
        }

        return QuotaProductData(
            id: product.id,
            sourceProductID: product.sourceProductID,
            titleKey: product.titleKey,
            canonicalOrder: product.canonicalOrder,
            planLevel: planLevel,
            state: applying(mutation.state, to: product.state),
            metrics: product.metrics
        )
    }

    private static func applying(
        _ mutation: QuotaNodeMutation,
        to state: QuotaNodeState
    ) -> QuotaNodeState {
        QuotaNodeState(
            presence: applying(mutation.presence, to: state.presence),
            freshness: applying(mutation.freshness, to: state.freshness),
            refresh: applying(mutation.refresh, to: state.refresh),
            lastAttemptAt: applying(mutation.lastAttemptAt, to: state.lastAttemptAt),
            lastSuccessAt: applying(mutation.lastSuccessAt, to: state.lastSuccessAt),
            failure: applying(mutation.failure, to: state.failure)
        )
    }

    private static func applying<Value: Equatable & Sendable>(
        _ mutation: QuotaFieldMutation<Value>,
        to value: Value
    ) -> Value {
        switch mutation {
        case .retain:
            value
        case let .replace(replacement):
            replacement
        }
    }

    private static func markingAllNodesStale(
        in data: ProviderQuotaData,
        now: Date
    ) -> ProviderQuotaData {
        ProviderQuotaData(
            providerID: data.providerID,
            source: data.source,
            fetchedAt: data.fetchedAt,
            products: data.products.map {
                markingAllNodesStale(
                    in: $0,
                    fallbackAsOf: data.fetchedAt,
                    now: now
                )
            },
            balances: data.balances.map { balance in
                QuotaBalance(
                    sourceBalanceID: balance.sourceBalanceID,
                    amount: balance.amount,
                    unit: balance.unit,
                    provenance: balance.provenance,
                    state: markingStale(
                        balance.state,
                        fallbackAsOf: balance.provenance.fetchedAt,
                        now: now
                    )
                )
            },
            resetEntitlements: data.resetEntitlements.map { summary in
                ResetEntitlementSummary(
                    availableCount: summary.availableCount,
                    details: summary.details,
                    provenance: summary.provenance,
                    state: markingStale(
                        summary.state,
                        fallbackAsOf: summary.provenance.fetchedAt,
                        now: now
                    )
                )
            }
        )
    }

    private static func markingAllNodesStale(
        in product: QuotaProductData,
        fallbackAsOf: Date,
        now: Date
    ) -> QuotaProductData {
        QuotaProductData(
            id: product.id,
            sourceProductID: product.sourceProductID,
            titleKey: product.titleKey,
            canonicalOrder: product.canonicalOrder,
            planLevel: product.planLevel,
            state: markingStale(product.state, fallbackAsOf: fallbackAsOf, now: now),
            metrics: product.metrics.map { metric in
                QuotaMetric(
                    id: metric.id,
                    sourceMetricID: metric.sourceMetricID,
                    sourceLabel: metric.sourceLabel,
                    window: metric.window,
                    value: metric.value,
                    sourceStatus: metric.sourceStatus,
                    provenance: metric.provenance,
                    state: markingStale(
                        metric.state,
                        fallbackAsOf: metric.provenance.fetchedAt,
                        now: now
                    )
                )
            }
        )
    }

    private static func markingStale(
        _ state: QuotaNodeState,
        fallbackAsOf: Date,
        now: Date
    ) -> QuotaNodeState {
        var stale = state
        let asOf = freshnessDate(from: state.freshness) ?? fallbackAsOf
        stale.freshness = .stale(asOf: asOf, evaluatedAt: now)
        return stale
    }

    private static func agingNodes(
        in data: ProviderQuotaData,
        staleAfter: TimeInterval,
        now: Date
    ) -> ProviderQuotaData {
        ProviderQuotaData(
            providerID: data.providerID,
            source: data.source,
            fetchedAt: data.fetchedAt,
            products: data.products.map { product in
                QuotaProductData(
                    id: product.id,
                    sourceProductID: product.sourceProductID,
                    titleKey: product.titleKey,
                    canonicalOrder: product.canonicalOrder,
                    planLevel: product.planLevel,
                    state: aging(
                        product.state,
                        fallbackAsOf: data.fetchedAt,
                        staleAfter: staleAfter,
                        now: now
                    ),
                    metrics: product.metrics.map { metric in
                        QuotaMetric(
                            id: metric.id,
                            sourceMetricID: metric.sourceMetricID,
                            sourceLabel: metric.sourceLabel,
                            window: metric.window,
                            value: metric.value,
                            sourceStatus: metric.sourceStatus,
                            provenance: metric.provenance,
                            state: aging(
                                metric.state,
                                fallbackAsOf: metric.provenance.fetchedAt,
                                staleAfter: staleAfter,
                                now: now
                            )
                        )
                    }
                )
            },
            balances: data.balances.map { balance in
                QuotaBalance(
                    sourceBalanceID: balance.sourceBalanceID,
                    amount: balance.amount,
                    unit: balance.unit,
                    provenance: balance.provenance,
                    state: aging(
                        balance.state,
                        fallbackAsOf: balance.provenance.fetchedAt,
                        staleAfter: staleAfter,
                        now: now
                    )
                )
            },
            resetEntitlements: data.resetEntitlements.map { summary in
                ResetEntitlementSummary(
                    availableCount: summary.availableCount,
                    details: summary.details,
                    provenance: summary.provenance,
                    state: aging(
                        summary.state,
                        fallbackAsOf: summary.provenance.fetchedAt,
                        staleAfter: staleAfter,
                        now: now
                    )
                )
            }
        )
    }

    private static func aging(
        _ state: QuotaNodeState,
        fallbackAsOf: Date,
        staleAfter: TimeInterval,
        now: Date
    ) -> QuotaNodeState {
        let asOf = freshnessDate(from: state.freshness) ?? fallbackAsOf
        guard now.timeIntervalSince(asOf) >= staleAfter else { return state }
        var aged = state
        aged.freshness = .stale(asOf: asOf, evaluatedAt: now)
        return aged
    }

    private static func activeReadScope(in state: ProviderState) -> ProviderScope {
        guard case let .refreshing(scope, _, _) = state.refresh.activity else {
            return .provider
        }
        return scope
    }

    private static func lastWriteAt(from health: PersistenceHealth) -> Date? {
        guard case let .healthy(_, lastWriteAt) = health else { return nil }
        return lastWriteAt
    }
}
