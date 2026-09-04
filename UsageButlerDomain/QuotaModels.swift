import Foundation

public struct ProductID: Equatable, Hashable, Identifiable, Sendable {
    public let providerID: ProviderID
    public let sourceProductID: String

    public init(providerID: ProviderID, sourceProductID: String) {
        self.providerID = providerID
        self.sourceProductID = sourceProductID
    }

    public var id: Self { self }
}

public struct MetricSourceIdentity: Equatable, Hashable, Sendable {
    public let providerID: ProviderID
    public let sourceProductID: String
    public let sourceBucketID: String?
    public let sourceMetricID: String

    public init(
        providerID: ProviderID,
        sourceProductID: String,
        sourceBucketID: String?,
        sourceMetricID: String
    ) {
        self.providerID = providerID
        self.sourceProductID = sourceProductID
        self.sourceBucketID = sourceBucketID
        self.sourceMetricID = sourceMetricID
    }
}

/// Stable identity is made only from source identity, never display text or array position.
public struct MetricID: Equatable, Hashable, Identifiable, Sendable {
    public let sourceIdentity: MetricSourceIdentity

    public init(sourceIdentity: MetricSourceIdentity) {
        self.sourceIdentity = sourceIdentity
    }

    public var id: Self { self }
}

public struct ProviderSourceIdentity: Equatable, Hashable, Sendable {
    public let providerID: ProviderID
    public let adapterID: String
    public let executableIdentity: String
    public let cliVersion: String
    public let schemaVersion: String
    public let contractVersion: String

    public init(
        providerID: ProviderID,
        adapterID: String,
        executableIdentity: String,
        cliVersion: String,
        schemaVersion: String,
        contractVersion: String
    ) {
        self.providerID = providerID
        self.adapterID = adapterID
        self.executableIdentity = executableIdentity
        self.cliVersion = cliVersion
        self.schemaVersion = schemaVersion
        self.contractVersion = contractVersion
    }
}

public struct MetricProvenance: Equatable, Sendable {
    public let sourceIdentity: MetricSourceIdentity
    public let providerSource: ProviderSourceIdentity
    public let fetchedAt: Date

    public init(
        sourceIdentity: MetricSourceIdentity,
        providerSource: ProviderSourceIdentity,
        fetchedAt: Date
    ) {
        self.sourceIdentity = sourceIdentity
        self.providerSource = providerSource
        self.fetchedAt = fetchedAt
    }
}

public enum QuotaDirection: Equatable, Sendable {
    case used
    case remaining
    case neutral
}

public struct DirectedPercent: Equatable, Sendable {
    public let sourceValue: Decimal
    public let sourceDirection: QuotaDirection

    public init(sourceValue: Decimal, sourceDirection: QuotaDirection) {
        self.sourceValue = sourceValue
        self.sourceDirection = sourceDirection
    }
}

public struct DirectedCount: Equatable, Sendable {
    public let sourceValue: Decimal
    public let total: Decimal?
    public let sourceDirection: QuotaDirection
    public let unit: String

    public init(
        sourceValue: Decimal,
        total: Decimal?,
        sourceDirection: QuotaDirection,
        unit: String
    ) {
        self.sourceValue = sourceValue
        self.total = total
        self.sourceDirection = sourceDirection
        self.unit = unit
    }
}

public struct UsedTotalAmount: Equatable, Sendable {
    public let used: Decimal
    public let total: Decimal
    public let unit: String
    public let sourcePercent: DirectedPercent?

    public init(
        used: Decimal,
        total: Decimal,
        unit: String,
        sourcePercent: DirectedPercent?
    ) {
        self.used = used
        self.total = total
        self.unit = unit
        self.sourcePercent = sourcePercent
    }
}

public enum UnavailableReason: Equatable, Sendable {
    case notReported
    case missingRequiredField(String)
    case invalidSourceValue(field: String)
    case unsupportedSemantics(sourceKind: String)
    case partialFailure(diagnosticCode: String)
}

public enum QuotaMetricValue: Equatable, Sendable {
    case percent(DirectedPercent)
    case count(DirectedCount)
    case usedTotal(UsedTotalAmount)
    case unlimited
    case absolute(value: Decimal, unit: String, direction: QuotaDirection)
    case unavailable(reason: UnavailableReason)
}

public struct SourceStatus: Equatable, Sendable {
    public let code: String?
    public let message: String?

    public init(code: String?, message: String?) {
        self.code = code
        self.message = message
    }
}

public struct QuotaTimeEvent: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case reset
        case refresh
        case entitlementExpiry
        case subscriptionExpiry
    }

    public let kind: Kind
    public let occursAt: Date

    public init(kind: Kind, occursAt: Date) {
        self.kind = kind
        self.occursAt = occursAt
    }
}

public enum QuotaWindowKind: Equatable, Sendable {
    case session
    case shortCycle
    case weekly
    case monthly
    case providerDefined(String)
}

public struct QuotaWindow: Equatable, Sendable {
    public let kind: QuotaWindowKind
    public let duration: TimeInterval?
    public let startsAt: Date?
    public let endsAt: Date?
    public let timeEvent: QuotaTimeEvent?

    public init(
        kind: QuotaWindowKind,
        duration: TimeInterval?,
        startsAt: Date?,
        endsAt: Date?,
        timeEvent: QuotaTimeEvent?
    ) {
        self.kind = kind
        self.duration = duration
        self.startsAt = startsAt
        self.endsAt = endsAt
        self.timeEvent = timeEvent
    }
}

public enum DerivationKind: Equatable, Sendable {
    case complementOfRemaining
    case complementOfUsed
    case remainingFromUsedTotal
    case providerRule(String)
}

public enum QuotaTimeStyle: Equatable, Sendable {
    case absoluteDateTime
    case relativeCountdown
}

public struct QuotaPresentationRule: Equatable, Sendable {
    public let contractVersion: String
    public let displayDirection: QuotaDirection
    public let timeEventKind: QuotaTimeEvent.Kind
    public let timeStyle: QuotaTimeStyle
    public let percentDerivation: DerivationKind?

    public init(
        contractVersion: String,
        displayDirection: QuotaDirection,
        timeEventKind: QuotaTimeEvent.Kind,
        timeStyle: QuotaTimeStyle,
        percentDerivation: DerivationKind?
    ) {
        self.contractVersion = contractVersion
        self.displayDirection = displayDirection
        self.timeEventKind = timeEventKind
        self.timeStyle = timeStyle
        self.percentDerivation = percentDerivation
    }
}

public enum DetailOnlyReason: Equatable, Sendable {
    case lowOverviewDecisionValue
    case providerDefined
    case unsupportedOverviewKind
}

public enum MetricPlacement: Equatable, Sendable {
    case overview
    case detailOnly(reason: DetailOnlyReason)
    case hiddenByUser
}

public struct QuotaMetric: Equatable, Identifiable, Sendable {
    public let id: MetricID
    public let sourceMetricID: String
    public let sourceLabel: String?
    public let window: QuotaWindow?
    public let value: QuotaMetricValue
    public let sourceStatus: SourceStatus?
    public let provenance: MetricProvenance
    public var state: QuotaNodeState

    public init(
        id: MetricID,
        sourceMetricID: String,
        sourceLabel: String?,
        window: QuotaWindow?,
        value: QuotaMetricValue,
        sourceStatus: SourceStatus?,
        provenance: MetricProvenance,
        state: QuotaNodeState
    ) {
        self.id = id
        self.sourceMetricID = sourceMetricID
        self.sourceLabel = sourceLabel
        self.window = window
        self.value = value
        self.sourceStatus = sourceStatus
        self.provenance = provenance
        self.state = state
    }
}

public enum PlanLevelOrigin: Equatable, Sendable {
    case reported(sourceField: String)
    case inferred(
        ruleID: String,
        catalogID: String,
        sourceVersion: String,
        evidenceFields: [String]
    )
}

public struct PlanLevelObservation: Equatable, Sendable {
    public let value: String
    public let origin: PlanLevelOrigin
    public let contractVersion: String
    public let fetchedAt: Date

    public init(
        value: String,
        origin: PlanLevelOrigin,
        contractVersion: String,
        fetchedAt: Date
    ) {
        self.value = value
        self.origin = origin
        self.contractVersion = contractVersion
        self.fetchedAt = fetchedAt
    }
}

public struct QuotaProductData: Equatable, Identifiable, Sendable {
    public let id: ProductID
    public let sourceProductID: String
    public let titleKey: String
    public let canonicalOrder: Int
    public let planLevel: PlanLevelObservation?
    public var state: QuotaNodeState
    public let metrics: [QuotaMetric]

    public init(
        id: ProductID,
        sourceProductID: String,
        titleKey: String,
        canonicalOrder: Int,
        planLevel: PlanLevelObservation?,
        state: QuotaNodeState,
        metrics: [QuotaMetric]
    ) {
        self.id = id
        self.sourceProductID = sourceProductID
        self.titleKey = titleKey
        self.canonicalOrder = canonicalOrder
        self.planLevel = planLevel
        self.state = state
        self.metrics = metrics
    }
}

public struct ResetEntitlementDetail: Equatable, Sendable {
    public let sourceID: String
    public let status: String
    public let grantedAt: Date?
    public let expiresAt: Date?
    public let title: String?

    public init(
        sourceID: String,
        status: String,
        grantedAt: Date?,
        expiresAt: Date?,
        title: String?
    ) {
        self.sourceID = sourceID
        self.status = status
        self.grantedAt = grantedAt
        self.expiresAt = expiresAt
        self.title = title
    }
}

public struct ResetEntitlementID: Equatable, Hashable, Identifiable, Sendable {
    public let sourceIdentity: MetricSourceIdentity

    public init(sourceIdentity: MetricSourceIdentity) {
        self.sourceIdentity = sourceIdentity
    }

    public var id: Self { self }
}

public struct ResetEntitlementSummary: Equatable, Identifiable, Sendable {
    public let availableCount: Decimal
    public let details: [ResetEntitlementDetail]?
    public let provenance: MetricProvenance
    public var state: QuotaNodeState

    public var id: ResetEntitlementID {
        ResetEntitlementID(sourceIdentity: provenance.sourceIdentity)
    }

    public init(
        availableCount: Decimal,
        details: [ResetEntitlementDetail]?,
        provenance: MetricProvenance,
        state: QuotaNodeState
    ) {
        self.availableCount = availableCount
        self.details = details
        self.provenance = provenance
        self.state = state
    }

    /// Source-compatible bridge for mappers that predate reset node state.
    /// New mappers should pass the authoritative state explicitly.
    public init(
        availableCount: Decimal,
        details: [ResetEntitlementDetail]?,
        provenance: MetricProvenance
    ) {
        self.init(
            availableCount: availableCount,
            details: details,
            provenance: provenance,
            state: QuotaNodeState.authoritativeData(asOf: provenance.fetchedAt)
        )
    }
}

/// Balances remain distinct from rate-limit metrics and reset entitlements.
public struct QuotaBalanceID: Equatable, Hashable, Identifiable, Sendable {
    public let providerID: ProviderID
    public let sourceBalanceID: String

    public init(providerID: ProviderID, sourceBalanceID: String) {
        self.providerID = providerID
        self.sourceBalanceID = sourceBalanceID
    }

    public var id: Self { self }
}

public struct QuotaBalance: Equatable, Identifiable, Sendable {
    public let sourceBalanceID: String
    public let amount: Decimal
    public let unit: String
    public let provenance: MetricProvenance
    public var state: QuotaNodeState

    public var id: QuotaBalanceID {
        QuotaBalanceID(
            providerID: provenance.sourceIdentity.providerID,
            sourceBalanceID: sourceBalanceID
        )
    }

    public init(
        sourceBalanceID: String,
        amount: Decimal,
        unit: String,
        provenance: MetricProvenance,
        state: QuotaNodeState
    ) {
        self.sourceBalanceID = sourceBalanceID
        self.amount = amount
        self.unit = unit
        self.provenance = provenance
        self.state = state
    }
}

public struct ProviderQuotaData: Equatable, Sendable {
    public let providerID: ProviderID
    public let source: ProviderSourceIdentity
    public let fetchedAt: Date
    public let products: [QuotaProductData]
    public let balances: [QuotaBalance]
    public let resetEntitlements: [ResetEntitlementSummary]

    public init(
        providerID: ProviderID,
        source: ProviderSourceIdentity,
        fetchedAt: Date,
        products: [QuotaProductData],
        balances: [QuotaBalance],
        resetEntitlements: [ResetEntitlementSummary]
    ) {
        self.providerID = providerID
        self.source = source
        self.fetchedAt = fetchedAt
        self.products = products
        self.balances = balances
        self.resetEntitlements = resetEntitlements
    }
}
