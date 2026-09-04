import Foundation
import UsageButlerDomain

enum ProviderQuotaPersistenceDTOError: Error, Equatable {
    case invalidIdentity
    case invalidShape
    case unsafePersistedValue
}

struct ProviderQuotaCacheEnvelopeDTO: Codable {
    static let schemaIdentifier = "usage-butler.provider-quota-last-good"
    static let formatVersion = 1

    let schema: String
    let version: Int
    let providerID: ProviderID
    let source: ProviderSourceIdentityDTO
    let payload: ProviderQuotaDataDTO

    init(domain data: ProviderQuotaData) throws {
        try ProviderQuotaDomainPersistenceValidator.validate(data)
        schema = Self.schemaIdentifier
        version = Self.formatVersion
        providerID = data.providerID
        source = ProviderSourceIdentityDTO(data.source)
        payload = try ProviderQuotaDataDTO(data)
        try validatePrivacy()
    }

    func domain(requestedProviderID: ProviderID) throws -> ProviderQuotaData {
        guard schema == Self.schemaIdentifier else {
            throw ProviderQuotaCacheEnvelopeValidationError.unknownSchema
        }
        guard version == Self.formatVersion else {
            throw ProviderQuotaCacheEnvelopeValidationError.unknownVersion
        }
        guard providerID == requestedProviderID,
              payload.providerID == requestedProviderID,
              source.providerID == requestedProviderID else {
            throw ProviderQuotaCacheEnvelopeValidationError.identityMismatch
        }
        try validatePrivacy()

        let domain = try payload.domain(source: source.domain())
        try ProviderQuotaDomainPersistenceValidator.validate(domain)
        return domain
    }

    private func validatePrivacy() throws {
        for value in persistedStrings() {
            guard CachePersistedStringPolicy.isAllowed(value) else {
                throw ProviderQuotaPersistenceDTOError.unsafePersistedValue
            }
        }
    }

    private func persistedStrings() -> [String] {
        [schema] + source.persistedStrings() + payload.persistedStrings()
    }
}

enum ProviderQuotaCacheEnvelopeValidationError: Error, Equatable {
    case unknownSchema
    case unknownVersion
    case identityMismatch
}

struct ProviderSourceIdentityDTO: Codable, Equatable {
    let providerID: ProviderID
    let adapterID: String
    let executableIdentity: String
    let cliVersion: String
    let schemaVersion: String
    let contractVersion: String

    init(_ source: ProviderSourceIdentity) {
        providerID = source.providerID
        adapterID = source.adapterID
        executableIdentity = source.executableIdentity
        cliVersion = source.cliVersion
        schemaVersion = source.schemaVersion
        contractVersion = source.contractVersion
    }

    func domain() -> ProviderSourceIdentity {
        ProviderSourceIdentity(
            providerID: providerID,
            adapterID: adapterID,
            executableIdentity: executableIdentity,
            cliVersion: cliVersion,
            schemaVersion: schemaVersion,
            contractVersion: contractVersion
        )
    }

    func persistedStrings() -> [String] {
        [adapterID, executableIdentity, cliVersion, schemaVersion, contractVersion]
    }
}

struct ProviderQuotaDataDTO: Codable {
    let providerID: ProviderID
    let fetchedAt: Date
    let products: [QuotaProductDTO]
    let balances: [QuotaBalanceDTO]
    let resetEntitlements: [ResetEntitlementSummaryDTO]

    init(_ data: ProviderQuotaData) throws {
        providerID = data.providerID
        fetchedAt = data.fetchedAt
        products = try data.products.map(QuotaProductDTO.init)
        balances = data.balances.map(QuotaBalanceDTO.init)
        resetEntitlements = data.resetEntitlements.map(ResetEntitlementSummaryDTO.init)
    }

    func domain(source: ProviderSourceIdentity) throws -> ProviderQuotaData {
        ProviderQuotaData(
            providerID: providerID,
            source: source,
            fetchedAt: fetchedAt,
            products: try products.map { try $0.domain(source: source, providerFetchedAt: fetchedAt) },
            balances: try balances.map { try $0.domain(source: source) },
            resetEntitlements: try resetEntitlements.map { try $0.domain(source: source) }
        )
    }

    func persistedStrings() -> [String] {
        products.flatMap { $0.persistedStrings() }
            + balances.flatMap { $0.persistedStrings() }
            + resetEntitlements.flatMap { $0.persistedStrings() }
    }
}

struct QuotaProductDTO: Codable {
    let sourceProductID: String
    let titleLocalizationID: String
    let canonicalOrder: Int
    let reportedPlanLevel: ReportedPlanLevelDTO?
    let metrics: [QuotaMetricDTO]

    init(_ product: QuotaProductData) throws {
        sourceProductID = product.sourceProductID
        titleLocalizationID = product.titleKey
        canonicalOrder = product.canonicalOrder
        if let planLevel = product.planLevel,
           case let .reported(sourceField) = planLevel.origin {
            reportedPlanLevel = ReportedPlanLevelDTO(
                value: planLevel.value,
                sourceField: sourceField,
                contractVersion: planLevel.contractVersion,
                fetchedAt: planLevel.fetchedAt
            )
        } else {
            // Inferred plan metadata is deliberately not last-good cache material.
            reportedPlanLevel = nil
        }
        metrics = try product.metrics.map(QuotaMetricDTO.init)
    }

    func domain(
        source: ProviderSourceIdentity,
        providerFetchedAt: Date
    ) throws -> QuotaProductData {
        QuotaProductData(
            id: ProductID(providerID: source.providerID, sourceProductID: sourceProductID),
            sourceProductID: sourceProductID,
            titleKey: titleLocalizationID,
            canonicalOrder: canonicalOrder,
            planLevel: reportedPlanLevel?.domain(),
            state: CachedQuotaNodeState.make(asOf: providerFetchedAt),
            metrics: try metrics.map {
                try $0.domain(source: source, sourceProductID: sourceProductID)
            }
        )
    }

    func persistedStrings() -> [String] {
        [sourceProductID, titleLocalizationID]
            + (reportedPlanLevel?.persistedStrings() ?? [])
            + metrics.flatMap { $0.persistedStrings() }
    }
}

struct ReportedPlanLevelDTO: Codable {
    let value: String
    let sourceField: String
    let contractVersion: String
    let fetchedAt: Date

    func domain() -> PlanLevelObservation {
        PlanLevelObservation(
            value: value,
            origin: .reported(sourceField: sourceField),
            contractVersion: contractVersion,
            fetchedAt: fetchedAt
        )
    }

    func persistedStrings() -> [String] {
        [value, sourceField, contractVersion]
    }
}

struct QuotaMetricDTO: Codable {
    let sourceBucketID: String?
    let sourceMetricID: String
    let sourceLabel: String?
    let window: QuotaWindowDTO?
    let value: QuotaMetricValueDTO
    let sourceStatusCode: String?
    let provenance: MetricProvenanceDTO

    init(_ metric: QuotaMetric) throws {
        sourceBucketID = metric.id.sourceIdentity.sourceBucketID
        sourceMetricID = metric.sourceMetricID
        sourceLabel = metric.sourceLabel
        window = metric.window.map(QuotaWindowDTO.init)
        value = try QuotaMetricValueDTO(metric.value)
        // Provider status messages can contain raw service text. Only the normalized code is durable.
        sourceStatusCode = metric.sourceStatus?.code
        provenance = MetricProvenanceDTO(metric.provenance)
    }

    func domain(
        source: ProviderSourceIdentity,
        sourceProductID: String
    ) throws -> QuotaMetric {
        let identity = MetricSourceIdentity(
            providerID: source.providerID,
            sourceProductID: sourceProductID,
            sourceBucketID: sourceBucketID,
            sourceMetricID: sourceMetricID
        )
        let domainProvenance = try provenance.domain(
            sourceIdentity: identity
        )
        return QuotaMetric(
            id: MetricID(sourceIdentity: identity),
            sourceMetricID: sourceMetricID,
            sourceLabel: sourceLabel,
            window: try window?.domain(),
            value: try value.domain(),
            sourceStatus: sourceStatusCode.map { SourceStatus(code: $0, message: nil) },
            provenance: domainProvenance,
            state: CachedQuotaNodeState.make(asOf: domainProvenance.fetchedAt)
        )
    }

    func persistedStrings() -> [String] {
        [sourceBucketID, sourceMetricID, sourceLabel, sourceStatusCode].compactMap { $0 }
            + (window?.persistedStrings() ?? [])
            + value.persistedStrings()
            + provenance.persistedStrings()
    }
}

struct MetricProvenanceDTO: Codable {
    let providerSource: ProviderSourceIdentityDTO
    let fetchedAt: Date

    init(_ provenance: MetricProvenance) {
        providerSource = ProviderSourceIdentityDTO(provenance.providerSource)
        fetchedAt = provenance.fetchedAt
    }

    func domain(
        sourceIdentity: MetricSourceIdentity
    ) throws -> MetricProvenance {
        MetricProvenance(
            sourceIdentity: sourceIdentity,
            providerSource: providerSource.domain(),
            fetchedAt: fetchedAt
        )
    }

    func persistedStrings() -> [String] {
        providerSource.persistedStrings()
    }
}

struct QuotaWindowDTO: Codable {
    let kind: QuotaWindowKindDTO
    let duration: TimeInterval?
    let startsAt: Date?
    let endsAt: Date?
    let timeEvent: QuotaTimeEventDTO?

    init(_ window: QuotaWindow) {
        kind = QuotaWindowKindDTO(window.kind)
        duration = window.duration
        startsAt = window.startsAt
        endsAt = window.endsAt
        timeEvent = window.timeEvent.map(QuotaTimeEventDTO.init)
    }

    func domain() throws -> QuotaWindow {
        QuotaWindow(
            kind: try kind.domain(),
            duration: duration,
            startsAt: startsAt,
            endsAt: endsAt,
            timeEvent: try timeEvent?.domain()
        )
    }

    func persistedStrings() -> [String] {
        kind.persistedStrings()
    }
}

struct QuotaWindowKindDTO: Codable {
    enum Kind: String, Codable {
        case session
        case shortCycle
        case weekly
        case monthly
        case providerDefined
    }

    let kind: Kind
    let providerValue: String?

    init(_ value: QuotaWindowKind) {
        switch value {
        case .session:
            kind = .session
            providerValue = nil
        case .shortCycle:
            kind = .shortCycle
            providerValue = nil
        case .weekly:
            kind = .weekly
            providerValue = nil
        case .monthly:
            kind = .monthly
            providerValue = nil
        case let .providerDefined(value):
            kind = .providerDefined
            providerValue = value
        }
    }

    func domain() throws -> QuotaWindowKind {
        switch kind {
        case .session:
            guard providerValue == nil else { throw ProviderQuotaPersistenceDTOError.invalidShape }
            return .session
        case .shortCycle:
            guard providerValue == nil else { throw ProviderQuotaPersistenceDTOError.invalidShape }
            return .shortCycle
        case .weekly:
            guard providerValue == nil else { throw ProviderQuotaPersistenceDTOError.invalidShape }
            return .weekly
        case .monthly:
            guard providerValue == nil else { throw ProviderQuotaPersistenceDTOError.invalidShape }
            return .monthly
        case .providerDefined:
            guard let providerValue else { throw ProviderQuotaPersistenceDTOError.invalidShape }
            return .providerDefined(providerValue)
        }
    }

    func persistedStrings() -> [String] {
        providerValue.map { [$0] } ?? []
    }
}

struct QuotaTimeEventDTO: Codable {
    enum Kind: String, Codable {
        case reset
        case refresh
        case entitlementExpiry
        case subscriptionExpiry
    }

    let kind: Kind
    let occursAt: Date

    init(_ event: QuotaTimeEvent) {
        switch event.kind {
        case .reset: kind = .reset
        case .refresh: kind = .refresh
        case .entitlementExpiry: kind = .entitlementExpiry
        case .subscriptionExpiry: kind = .subscriptionExpiry
        }
        occursAt = event.occursAt
    }

    func domain() throws -> QuotaTimeEvent {
        let domainKind: QuotaTimeEvent.Kind
        switch kind {
        case .reset: domainKind = .reset
        case .refresh: domainKind = .refresh
        case .entitlementExpiry: domainKind = .entitlementExpiry
        case .subscriptionExpiry: domainKind = .subscriptionExpiry
        }
        return QuotaTimeEvent(kind: domainKind, occursAt: occursAt)
    }
}

struct QuotaMetricValueDTO: Codable {
    enum Kind: String, Codable {
        case percent
        case count
        case usedTotal
        case unlimited
        case absolute
        case unavailable
    }

    let kind: Kind
    let sourceValue: Decimal?
    let total: Decimal?
    let used: Decimal?
    let unit: String?
    let direction: QuotaDirectionDTO?
    let sourcePercent: DirectedPercentDTO?
    let unavailable: UnavailableReasonDTO?

    init(_ value: QuotaMetricValue) throws {
        switch value {
        case let .percent(percent):
            kind = .percent
            sourceValue = percent.sourceValue
            total = nil
            used = nil
            unit = nil
            direction = QuotaDirectionDTO(percent.sourceDirection)
            sourcePercent = nil
            unavailable = nil
        case let .count(count):
            kind = .count
            sourceValue = count.sourceValue
            total = count.total
            used = nil
            unit = count.unit
            direction = QuotaDirectionDTO(count.sourceDirection)
            sourcePercent = nil
            unavailable = nil
        case let .usedTotal(amount):
            kind = .usedTotal
            sourceValue = nil
            total = amount.total
            used = amount.used
            unit = amount.unit
            direction = nil
            sourcePercent = amount.sourcePercent.map(DirectedPercentDTO.init)
            unavailable = nil
        case .unlimited:
            kind = .unlimited
            sourceValue = nil
            total = nil
            used = nil
            unit = nil
            direction = nil
            sourcePercent = nil
            unavailable = nil
        case let .absolute(value, unit, direction):
            kind = .absolute
            sourceValue = value
            total = nil
            used = nil
            self.unit = unit
            self.direction = QuotaDirectionDTO(direction)
            sourcePercent = nil
            unavailable = nil
        case let .unavailable(reason):
            kind = .unavailable
            sourceValue = nil
            total = nil
            used = nil
            unit = nil
            direction = nil
            sourcePercent = nil
            unavailable = UnavailableReasonDTO(reason)
        }
    }

    func domain() throws -> QuotaMetricValue {
        switch kind {
        case .percent:
            guard let sourceValue, let direction,
                  total == nil, used == nil, unit == nil,
                  sourcePercent == nil, unavailable == nil else {
                throw ProviderQuotaPersistenceDTOError.invalidShape
            }
            return .percent(
                DirectedPercent(sourceValue: sourceValue, sourceDirection: direction.domain)
            )
        case .count:
            guard let sourceValue, let unit, let direction,
                  used == nil, sourcePercent == nil, unavailable == nil else {
                throw ProviderQuotaPersistenceDTOError.invalidShape
            }
            return .count(
                DirectedCount(
                    sourceValue: sourceValue,
                    total: total,
                    sourceDirection: direction.domain,
                    unit: unit
                )
            )
        case .usedTotal:
            guard sourceValue == nil, let total, let used, let unit,
                  direction == nil, unavailable == nil else {
                throw ProviderQuotaPersistenceDTOError.invalidShape
            }
            return .usedTotal(
                UsedTotalAmount(
                    used: used,
                    total: total,
                    unit: unit,
                    sourcePercent: sourcePercent?.domain()
                )
            )
        case .unlimited:
            guard sourceValue == nil, total == nil, used == nil, unit == nil,
                  direction == nil, sourcePercent == nil, unavailable == nil else {
                throw ProviderQuotaPersistenceDTOError.invalidShape
            }
            return .unlimited
        case .absolute:
            guard let sourceValue, let unit, let direction,
                  total == nil, used == nil, sourcePercent == nil, unavailable == nil else {
                throw ProviderQuotaPersistenceDTOError.invalidShape
            }
            return .absolute(value: sourceValue, unit: unit, direction: direction.domain)
        case .unavailable:
            guard sourceValue == nil, total == nil, used == nil, unit == nil,
                  direction == nil, sourcePercent == nil, let unavailable else {
                throw ProviderQuotaPersistenceDTOError.invalidShape
            }
            return .unavailable(reason: try unavailable.domain())
        }
    }

    func persistedStrings() -> [String] {
        (unit.map { [$0] } ?? []) + (unavailable?.persistedStrings() ?? [])
    }
}

enum QuotaDirectionDTO: String, Codable {
    case used
    case remaining
    case neutral

    init(_ direction: QuotaDirection) {
        switch direction {
        case .used: self = .used
        case .remaining: self = .remaining
        case .neutral: self = .neutral
        }
    }

    var domain: QuotaDirection {
        switch self {
        case .used: .used
        case .remaining: .remaining
        case .neutral: .neutral
        }
    }
}

struct DirectedPercentDTO: Codable {
    let sourceValue: Decimal
    let direction: QuotaDirectionDTO

    init(_ percent: DirectedPercent) {
        sourceValue = percent.sourceValue
        direction = QuotaDirectionDTO(percent.sourceDirection)
    }

    func domain() -> DirectedPercent {
        DirectedPercent(sourceValue: sourceValue, sourceDirection: direction.domain)
    }
}

struct UnavailableReasonDTO: Codable {
    enum Kind: String, Codable {
        case notReported
        case missingRequiredField
        case invalidSourceValue
        case unsupportedSemantics
        case partialFailure
    }

    let kind: Kind
    let detail: String?

    init(_ reason: UnavailableReason) {
        switch reason {
        case .notReported:
            kind = .notReported
            detail = nil
        case let .missingRequiredField(field):
            kind = .missingRequiredField
            detail = field
        case let .invalidSourceValue(field):
            kind = .invalidSourceValue
            detail = field
        case let .unsupportedSemantics(sourceKind):
            kind = .unsupportedSemantics
            detail = sourceKind
        case let .partialFailure(diagnosticCode):
            kind = .partialFailure
            detail = diagnosticCode
        }
    }

    func domain() throws -> UnavailableReason {
        switch kind {
        case .notReported:
            guard detail == nil else { throw ProviderQuotaPersistenceDTOError.invalidShape }
            return .notReported
        case .missingRequiredField:
            guard let detail else { throw ProviderQuotaPersistenceDTOError.invalidShape }
            return .missingRequiredField(detail)
        case .invalidSourceValue:
            guard let detail else { throw ProviderQuotaPersistenceDTOError.invalidShape }
            return .invalidSourceValue(field: detail)
        case .unsupportedSemantics:
            guard let detail else { throw ProviderQuotaPersistenceDTOError.invalidShape }
            return .unsupportedSemantics(sourceKind: detail)
        case .partialFailure:
            guard let detail else { throw ProviderQuotaPersistenceDTOError.invalidShape }
            return .partialFailure(diagnosticCode: detail)
        }
    }

    func persistedStrings() -> [String] {
        detail.map { [$0] } ?? []
    }
}

struct QuotaBalanceDTO: Codable {
    let sourceBalanceID: String
    let amount: Decimal
    let unit: String
    let sourceProductID: String
    let sourceBucketID: String?
    let sourceMetricID: String
    let provenance: MetricProvenanceDTO

    init(_ balance: QuotaBalance) {
        sourceBalanceID = balance.sourceBalanceID
        amount = balance.amount
        unit = balance.unit
        sourceProductID = balance.provenance.sourceIdentity.sourceProductID
        sourceBucketID = balance.provenance.sourceIdentity.sourceBucketID
        sourceMetricID = balance.provenance.sourceIdentity.sourceMetricID
        provenance = MetricProvenanceDTO(balance.provenance)
    }

    func domain(source: ProviderSourceIdentity) throws -> QuotaBalance {
        let identity = MetricSourceIdentity(
            providerID: source.providerID,
            sourceProductID: sourceProductID,
            sourceBucketID: sourceBucketID,
            sourceMetricID: sourceMetricID
        )
        let domainProvenance = try provenance.domain(
            sourceIdentity: identity
        )
        return QuotaBalance(
            sourceBalanceID: sourceBalanceID,
            amount: amount,
            unit: unit,
            provenance: domainProvenance,
            state: CachedQuotaNodeState.make(asOf: domainProvenance.fetchedAt)
        )
    }

    func persistedStrings() -> [String] {
        [sourceBalanceID, unit, sourceProductID, sourceMetricID]
            + (sourceBucketID.map { [$0] } ?? [])
            + provenance.persistedStrings()
    }
}

struct ResetEntitlementSummaryDTO: Codable {
    let availableCount: Decimal
    let details: [ResetEntitlementDetailDTO]?
    let sourceProductID: String
    let sourceBucketID: String?
    let sourceMetricID: String
    let provenance: MetricProvenanceDTO

    init(_ summary: ResetEntitlementSummary) {
        availableCount = summary.availableCount
        details = summary.details?.map(ResetEntitlementDetailDTO.init)
        sourceProductID = summary.provenance.sourceIdentity.sourceProductID
        sourceBucketID = summary.provenance.sourceIdentity.sourceBucketID
        sourceMetricID = summary.provenance.sourceIdentity.sourceMetricID
        provenance = MetricProvenanceDTO(summary.provenance)
    }

    func domain(source: ProviderSourceIdentity) throws -> ResetEntitlementSummary {
        let identity = MetricSourceIdentity(
            providerID: source.providerID,
            sourceProductID: sourceProductID,
            sourceBucketID: sourceBucketID,
            sourceMetricID: sourceMetricID
        )
        return ResetEntitlementSummary(
            availableCount: availableCount,
            details: details?.map { $0.domain() },
            provenance: try provenance.domain(
                sourceIdentity: identity
            ),
            state: CachedQuotaNodeState.make(asOf: provenance.fetchedAt)
        )
    }

    func persistedStrings() -> [String] {
        [sourceProductID, sourceMetricID]
            + (sourceBucketID.map { [$0] } ?? [])
            + (details?.flatMap { $0.persistedStrings() } ?? [])
            + provenance.persistedStrings()
    }
}

struct ResetEntitlementDetailDTO: Codable {
    let sourceID: String
    let status: String
    let grantedAt: Date?
    let expiresAt: Date?
    let title: String?

    init(_ detail: ResetEntitlementDetail) {
        sourceID = detail.sourceID
        status = detail.status
        grantedAt = detail.grantedAt
        expiresAt = detail.expiresAt
        title = detail.title
    }

    func domain() -> ResetEntitlementDetail {
        ResetEntitlementDetail(
            sourceID: sourceID,
            status: status,
            grantedAt: grantedAt,
            expiresAt: expiresAt,
            title: title
        )
    }

    func persistedStrings() -> [String] {
        [sourceID, status] + (title.map { [$0] } ?? [])
    }
}

private enum CachedQuotaNodeState {
    static func make(asOf: Date) -> QuotaNodeState {
        QuotaNodeState(
            presence: .unknown,
            freshness: .unknown,
            refresh: RefreshState(
                activity: .idle,
                gate: .open,
                lastAttemptAt: nil,
                lastSuccessAt: asOf
            ),
            lastAttemptAt: nil,
            lastSuccessAt: asOf,
            failure: nil
        )
    }
}

private enum ProviderQuotaDomainPersistenceValidator {
    static func validate(_ data: ProviderQuotaData) throws {
        do {
            try ProviderQuotaIdentityValidator.validate(
                data,
                expectedProviderID: data.providerID
            )
        } catch {
            throw ProviderQuotaPersistenceDTOError.invalidIdentity
        }

        var sources = [data.source]
        sources += data.products.flatMap { product in
            product.metrics.map(\.provenance.providerSource)
        }
        sources += data.balances.map(\.provenance.providerSource)
        sources += data.resetEntitlements.map(\.provenance.providerSource)
        guard sources.allSatisfy(isCompleteSourceIdentity) else {
            throw ProviderQuotaPersistenceDTOError.invalidIdentity
        }
    }

    private static func isCompleteSourceIdentity(_ source: ProviderSourceIdentity) -> Bool {
        !source.adapterID.isEmpty
            && !source.executableIdentity.isEmpty
            && !source.cliVersion.isEmpty
            && !source.schemaVersion.isEmpty
            && !source.contractVersion.isEmpty
    }
}

private enum CachePersistedStringPolicy {
    static func isAllowed(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowercased = trimmed.lowercased()

        if trimmed.hasPrefix("/") || lowercased.hasPrefix("file://") {
            return false
        }
        if trimmed.contains("@") {
            return false
        }
        if (trimmed.hasPrefix("{") && trimmed.hasSuffix("}"))
            || (trimmed.hasPrefix("[") && trimmed.hasSuffix("]")) {
            return false
        }

        let secretMarkers = [
            "authorization:",
            "bearer ",
            "api_key",
            "api-key",
            "apikey",
            "access_token",
            "refresh_token",
            "token=",
            "token:",
            "secret=",
            "secret:"
        ]
        if secretMarkers.contains(where: lowercased.contains) {
            return false
        }
        if lowercased.hasPrefix("sk-") || lowercased.hasPrefix("tok_") {
            return false
        }
        return true
    }
}
