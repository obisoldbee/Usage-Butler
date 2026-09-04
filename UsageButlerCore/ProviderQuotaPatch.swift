import Foundation
import UsageButlerDomain

public enum QuotaFieldMutation<Value: Equatable & Sendable>: Equatable, Sendable {
    case retain
    case replace(Value)
}

public struct QuotaNodeMutation: Equatable, Sendable {
    public let presence: QuotaFieldMutation<PresenceState>
    public let freshness: QuotaFieldMutation<FreshnessState>
    public let refresh: QuotaFieldMutation<RefreshState>
    public let lastAttemptAt: QuotaFieldMutation<Date?>
    public let lastSuccessAt: QuotaFieldMutation<Date?>
    public let failure: QuotaFieldMutation<ProviderFailure?>

    public init(
        presence: QuotaFieldMutation<PresenceState> = .retain,
        freshness: QuotaFieldMutation<FreshnessState> = .retain,
        refresh: QuotaFieldMutation<RefreshState> = .retain,
        lastAttemptAt: QuotaFieldMutation<Date?> = .retain,
        lastSuccessAt: QuotaFieldMutation<Date?> = .retain,
        failure: QuotaFieldMutation<ProviderFailure?> = .retain
    ) {
        self.presence = presence
        self.freshness = freshness
        self.refresh = refresh
        self.lastAttemptAt = lastAttemptAt
        self.lastSuccessAt = lastSuccessAt
        self.failure = failure
    }
}

public enum PlanLevelMutation: Equatable, Sendable {
    case retain
    case replace(PlanLevelObservation?)
    /// Removes only a current-resolution inference. Reported metadata is retained.
    case clearCurrentInferred
}

public struct QuotaProductNodeMutation: Equatable, Sendable {
    public let planLevel: PlanLevelMutation
    public let state: QuotaNodeMutation

    public init(
        planLevel: PlanLevelMutation = .retain,
        state: QuotaNodeMutation = QuotaNodeMutation()
    ) {
        self.planLevel = planLevel
        self.state = state
    }
}

public enum QuotaProductMutation: Equatable, Sendable {
    /// An authoritative payload replacement or insertion. Its nested states are kept.
    case replace(QuotaProductData)
    /// Replaces the current metric set, but retains a matching successful payload
    /// when an incoming metric carries a failure. Missing metrics are not retained.
    /// Failed metrics without history must carry unavailable/unknown, not success.
    case replaceRetainingFailedMetrics(QuotaProductData)
    /// Mutates resolution state while retaining the prior payload and its provenance.
    /// If no retained product exists yet, the mutation is a deterministic no-op.
    case mutate(id: ProductID, mutation: QuotaProductNodeMutation)

    public var productID: ProductID {
        switch self {
        case let .replace(product), let .replaceRetainingFailedMetrics(product):
            product.id
        case let .mutate(id, _):
            id
        }
    }
}

public enum QuotaProductCollectionMutation: Equatable, Sendable {
    /// Patch only the named products; omitted siblings retain last-good stale.
    case patch([QuotaProductMutation])
    /// The current quota surface authoritatively replaces the complete product set.
    case replaceAll([QuotaProductData])
}

public enum QuotaCollectionMutation<Element: Equatable & Sendable>: Equatable, Sendable {
    case retain
    /// Empty is an authoritative empty resolution.
    case replace([Element])
}

public struct ProviderQuotaPatch: Equatable, Sendable {
    public let providerID: ProviderID
    public let source: ProviderSourceIdentity
    public let fetchedAt: Date
    public let productCollectionMutation: QuotaProductCollectionMutation
    public let balanceMutation: QuotaCollectionMutation<QuotaBalance>
    public let resetEntitlementMutation: QuotaCollectionMutation<ResetEntitlementSummary>

    public init(
        providerID: ProviderID,
        source: ProviderSourceIdentity,
        fetchedAt: Date,
        productCollectionMutation: QuotaProductCollectionMutation,
        balanceMutation: QuotaCollectionMutation<QuotaBalance>,
        resetEntitlementMutation: QuotaCollectionMutation<ResetEntitlementSummary>
    ) {
        self.providerID = providerID
        self.source = source
        self.fetchedAt = fetchedAt
        self.productCollectionMutation = productCollectionMutation
        self.balanceMutation = balanceMutation
        self.resetEntitlementMutation = resetEntitlementMutation
    }

    public init(
        providerID: ProviderID,
        source: ProviderSourceIdentity,
        fetchedAt: Date,
        productMutations: [QuotaProductMutation],
        balanceMutation: QuotaCollectionMutation<QuotaBalance>,
        resetEntitlementMutation: QuotaCollectionMutation<ResetEntitlementSummary>
    ) {
        self.init(
            providerID: providerID,
            source: source,
            fetchedAt: fetchedAt,
            productCollectionMutation: .patch(productMutations),
            balanceMutation: balanceMutation,
            resetEntitlementMutation: resetEntitlementMutation
        )
    }

    /// Source-compatible initializer for existing Provider mappers. New partial
    /// adapters should construct typed mutations when a failed resolution needs to
    /// retain payload while changing plan or node state.
    public init(
        providerID: ProviderID,
        source: ProviderSourceIdentity,
        fetchedAt: Date,
        updatedProducts: [QuotaProductData],
        balances: [QuotaBalance]?,
        resetEntitlements: [ResetEntitlementSummary]?
    ) {
        self.init(
            providerID: providerID,
            source: source,
            fetchedAt: fetchedAt,
            productMutations: updatedProducts.map(QuotaProductMutation.replace),
            balanceMutation: balances.map(QuotaCollectionMutation.replace) ?? .retain,
            resetEntitlementMutation: resetEntitlements.map(QuotaCollectionMutation.replace)
                ?? .retain
        )
    }

    /// Compatibility projection for Provider tests and staged migrations.
    public var productMutations: [QuotaProductMutation] {
        switch productCollectionMutation {
        case let .patch(mutations):
            mutations
        case let .replaceAll(products):
            products.map(QuotaProductMutation.replace)
        }
    }

    /// Compatibility projection for Provider tests and staged migrations.
    public var updatedProducts: [QuotaProductData] {
        productMutations.compactMap { mutation in
            switch mutation {
            case let .replace(product), let .replaceRetainingFailedMetrics(product):
                product
            case .mutate:
                nil
            }
        }
    }

    /// `nil` retains the prior collection; an empty array is authoritative empty.
    public var balances: [QuotaBalance]? {
        guard case let .replace(balances) = balanceMutation else { return nil }
        return balances
    }

    /// `nil` retains the prior collection; an empty array is authoritative empty.
    public var resetEntitlements: [ResetEntitlementSummary]? {
        guard case let .replace(resetEntitlements) = resetEntitlementMutation else {
            return nil
        }
        return resetEntitlements
    }
}
