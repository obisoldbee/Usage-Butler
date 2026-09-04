import Foundation
import UsageButlerDomain

enum OpenAIQuotaDomainMappingError: Error, Equatable, Sendable {
    case sourceProviderMismatch
}

enum OpenAIResetEntitlementPresentation: Equatable, Sendable {
    case hidden
    case countOnly
    case detail(ResetEntitlementDetail)
    case invalid
}

struct OpenAIQuotaDomainDiagnostics: Equatable, Sendable {
    let invalidBucketSourceIDs: [String]
    let invalidWindowSourceIDs: [String]
    let invalidCreditSourceIDs: [String]
    let invalidResetCreditDetailCount: Int
    let invalidResetSummaryCount: Int
    let invalidProductIdentityCount: Int
    let invalidBalanceCount: Int
    let invalidLegacyRateLimits: Bool

    var hasPartialFailure: Bool {
        !invalidBucketSourceIDs.isEmpty
            || !invalidWindowSourceIDs.isEmpty
            || !invalidCreditSourceIDs.isEmpty
            || invalidResetSummaryCount > 0
            || invalidProductIdentityCount > 0
            || invalidBalanceCount > 0
    }
}

struct OpenAIQuotaDomainMapping: Equatable, Sendable {
    let data: ProviderQuotaData
    let presentationRules: [MetricID: QuotaPresentationRule]
    let resetEntitlementPresentation: OpenAIResetEntitlementPresentation?
    let diagnostics: OpenAIQuotaDomainDiagnostics

    /// Only these products are safe to replace during a partial read. Products omitted
    /// because their bucket/window was malformed must remain last-good in Core.
    let authoritativeProductIDs: Set<ProductID>
    let productsAreAuthoritative: Bool
    let balancesAreAuthoritative: Bool
    let resetEntitlementsAreAuthoritative: Bool
}

enum OpenAIQuotaDomainMapper {
    private static let posixLocale = Locale(identifier: "en_US_POSIX")

    static func map(
        account: ParsedOpenAIAccount?,
        rateLimits: ParsedOpenAIRateLimits,
        source: ProviderSourceIdentity,
        fetchedAt: Date
    ) throws -> OpenAIQuotaDomainMapping {
        guard source.providerID == .openAI else {
            throw OpenAIQuotaDomainMappingError.sourceProviderMismatch
        }

        var invalidProductIdentityCount = 0
        var invalidBalanceCount = 0
        var products: [QuotaProductData] = []
        var balances: [QuotaBalance] = []
        var presentationRules: [MetricID: QuotaPresentationRule] = [:]
        var authoritativeProductIDs: Set<ProductID> = []

        let invalidWindowBucketIDs = Set(
            rateLimits.diagnostics.invalidWindowSourceIDs.compactMap(bucketID(fromWindowSourceID:))
        )

        for bucket in rateLimits.buckets {
            guard let identity = sourceIdentity(for: bucket, source: rateLimits.source) else {
                invalidProductIdentityCount += 1
                continue
            }

            let productID = ProductID(providerID: .openAI, sourceProductID: identity.productID)
            var metrics: [QuotaMetric] = []

            for window in bucket.windows {
                let metricIdentity = MetricSourceIdentity(
                    providerID: .openAI,
                    sourceProductID: identity.productID,
                    sourceBucketID: identity.bucketID,
                    sourceMetricID: "\(window.sourceSlot.rawValue).used_percent"
                )
                let metricID = MetricID(sourceIdentity: metricIdentity)
                let metric = QuotaMetric(
                    id: metricID,
                    sourceMetricID: metricIdentity.sourceMetricID,
                    sourceLabel: bucket.identity.limitName,
                    window: quotaWindow(from: window),
                    value: .percent(
                        DirectedPercent(
                            sourceValue: decimal(from: window.usedPercent),
                            sourceDirection: .used
                        )
                    ),
                    sourceStatus: bucket.rateLimitReachedType.map {
                        SourceStatus(code: $0, message: nil)
                    },
                    provenance: MetricProvenance(
                        sourceIdentity: metricIdentity,
                        providerSource: source,
                        fetchedAt: fetchedAt
                    ),
                    state: successfulNodeState(fetchedAt: fetchedAt)
                )
                metrics.append(metric)
                presentationRules[metricID] = presentationRule(for: metric)
            }

            metrics.sort(by: metricComesBefore)
            let product = QuotaProductData(
                id: productID,
                sourceProductID: identity.productID,
                titleKey: titleKey(for: bucket.kind),
                canonicalOrder: canonicalOrder(for: bucket.kind),
                planLevel: planLevel(
                    bucketPlanType: bucket.planType,
                    accountPlanType: account?.planType,
                    source: source,
                    fetchedAt: fetchedAt
                ),
                state: successfulNodeState(fetchedAt: fetchedAt),
                metrics: metrics
            )
            products.append(product)

            if !invalidWindowBucketIDs.contains(identity.windowDiagnosticBucketID) {
                authoritativeProductIDs.insert(productID)
            }

            if let credits = bucket.credits {
                switch balance(
                    from: credits,
                    productID: identity.productID,
                    bucketID: identity.bucketID,
                    source: source,
                    fetchedAt: fetchedAt
                ) {
                case let .success(balance):
                    if let balance { balances.append(balance) }
                case .invalid:
                    invalidBalanceCount += 1
                }
            }
        }

        products.sort(by: productComesBefore)
        balances.sort { $0.sourceBalanceID < $1.sourceBalanceID }

        let resetMapping = mapResetEntitlements(
            rateLimits.resetCredits,
            invalidSummaryCount: rateLimits.diagnostics.invalidResetCreditSummaryCount,
            source: source,
            fetchedAt: fetchedAt
        )
        let invalidResetDetailCount =
            rateLimits.diagnostics.invalidResetCreditDetailCount
            + resetMapping.invalidDetailCount

        let diagnostics = OpenAIQuotaDomainDiagnostics(
            invalidBucketSourceIDs: rateLimits.diagnostics.invalidBucketSourceKeys,
            invalidWindowSourceIDs: rateLimits.diagnostics.invalidWindowSourceIDs,
            invalidCreditSourceIDs: rateLimits.diagnostics.invalidCreditSourceIDs,
            invalidResetCreditDetailCount: invalidResetDetailCount,
            invalidResetSummaryCount: resetMapping.invalidSummaryCount,
            invalidProductIdentityCount: invalidProductIdentityCount,
            invalidBalanceCount: invalidBalanceCount,
            invalidLegacyRateLimits: rateLimits.diagnostics.invalidLegacyRateLimits
        )

        return OpenAIQuotaDomainMapping(
            data: ProviderQuotaData(
                providerID: .openAI,
                source: source,
                fetchedAt: fetchedAt,
                products: products,
                balances: balances,
                resetEntitlements: resetMapping.summaries
            ),
            presentationRules: presentationRules,
            resetEntitlementPresentation: resetMapping.presentation,
            diagnostics: diagnostics,
            authoritativeProductIDs: authoritativeProductIDs,
            productsAreAuthoritative:
                rateLimits.diagnostics.invalidBucketSourceKeys.isEmpty
                && rateLimits.diagnostics.invalidWindowSourceIDs.isEmpty
                && invalidProductIdentityCount == 0,
            balancesAreAuthoritative:
                rateLimits.diagnostics.invalidBucketSourceKeys.isEmpty
                && rateLimits.diagnostics.invalidCreditSourceIDs.isEmpty
                && invalidProductIdentityCount == 0
                && invalidBalanceCount == 0,
            resetEntitlementsAreAuthoritative: resetMapping.isAuthoritative
        )
    }

    static func presentationRule(for metric: QuotaMetric) -> QuotaPresentationRule {
        QuotaPresentationRule(
            contractVersion: metric.provenance.providerSource.contractVersion,
            displayDirection: .remaining,
            timeEventKind: .reset,
            timeStyle: .absoluteDateTime,
            percentDerivation: .complementOfUsed
        )
    }

    private struct BucketSourceIdentity {
        let productID: String
        let bucketID: String
        let windowDiagnosticBucketID: String
    }

    private static func sourceIdentity(
        for bucket: ParsedOpenAIRateLimitBucket,
        source: ParsedOpenAIRateLimitSource
    ) -> BucketSourceIdentity? {
        let dictionaryKey = nonEmpty(bucket.identity.dictionaryKey)
        let limitID = nonEmpty(bucket.identity.limitID)

        if source == .multiBucket, dictionaryKey == nil {
            return nil
        }

        let fallback = source == .legacyFallback ? "legacy.rateLimits" : nil
        guard let productID = dictionaryKey ?? limitID ?? fallback,
              let bucketID = limitID ?? dictionaryKey ?? fallback else {
            return nil
        }

        return BucketSourceIdentity(
            productID: productID,
            bucketID: bucketID,
            windowDiagnosticBucketID: limitID ?? dictionaryKey ?? fallback ?? bucketID
        )
    }

    private static func quotaWindow(from window: ParsedOpenAIRateLimitWindow) -> QuotaWindow {
        let duration = window.windowDurationMins.map { TimeInterval($0) * 60 }
        let kind: QuotaWindowKind
        switch window.windowDurationMins {
        case 300:
            kind = .shortCycle
        case 10_080:
            kind = .weekly
        case let minutes?:
            kind = .providerDefined("openai.duration.\(minutes)m")
        case nil:
            kind = .providerDefined("openai.\(window.sourceSlot.rawValue)")
        }

        let resetDate = window.resetsAt.map { Date(timeIntervalSince1970: TimeInterval($0)) }
        return QuotaWindow(
            kind: kind,
            duration: duration,
            startsAt: nil,
            endsAt: resetDate,
            timeEvent: resetDate.map { QuotaTimeEvent(kind: .reset, occursAt: $0) }
        )
    }

    private static func planLevel(
        bucketPlanType: String?,
        accountPlanType: String?,
        source: ProviderSourceIdentity,
        fetchedAt: Date
    ) -> PlanLevelObservation? {
        if let value = nonEmpty(bucketPlanType) {
            return PlanLevelObservation(
                value: value,
                origin: .reported(sourceField: "account/rateLimits/read.bucket.planType"),
                contractVersion: source.contractVersion,
                fetchedAt: fetchedAt
            )
        }
        if let value = nonEmpty(accountPlanType) {
            return PlanLevelObservation(
                value: value,
                origin: .reported(sourceField: "account/read.account.planType"),
                contractVersion: source.contractVersion,
                fetchedAt: fetchedAt
            )
        }
        return nil
    }

    private enum BalanceMapping {
        case success(QuotaBalance?)
        case invalid
    }

    private static func balance(
        from credits: ParsedOpenAICredits,
        productID: String,
        bucketID: String,
        source: ProviderSourceIdentity,
        fetchedAt: Date
    ) -> BalanceMapping {
        guard let rawBalance = credits.balance else {
            return .success(nil)
        }

        let amount: Decimal?
        switch rawBalance {
        case let .string(value):
            amount = Decimal(
                string: value.trimmingCharacters(in: .whitespacesAndNewlines),
                locale: posixLocale
            )
        case let .number(value):
            amount = value.isFinite ? decimal(from: value) : nil
        case .boolean:
            amount = nil
        }
        guard let amount else { return .invalid }

        let identity = MetricSourceIdentity(
            providerID: .openAI,
            sourceProductID: productID,
            sourceBucketID: bucketID,
            sourceMetricID: "credits.balance"
        )
        return .success(
            QuotaBalance(
                sourceBalanceID: "\(productID).credits.balance",
                amount: amount,
                unit: "credits",
                provenance: MetricProvenance(
                    sourceIdentity: identity,
                    providerSource: source,
                    fetchedAt: fetchedAt
                ),
                state: successfulNodeState(fetchedAt: fetchedAt)
            )
        )
    }

    private struct ResetMapping {
        let summaries: [ResetEntitlementSummary]
        let presentation: OpenAIResetEntitlementPresentation?
        let invalidDetailCount: Int
        let invalidSummaryCount: Int
        let isAuthoritative: Bool
    }

    private static func mapResetEntitlements(
        _ parsed: ParsedOpenAIResetCredits?,
        invalidSummaryCount: Int,
        source: ProviderSourceIdentity,
        fetchedAt: Date
    ) -> ResetMapping {
        guard let parsed else {
            return ResetMapping(
                summaries: [],
                presentation: nil,
                invalidDetailCount: 0,
                invalidSummaryCount: invalidSummaryCount,
                // Missing/null is a legal optional omission, not an authoritative
                // availableCount == 0 observation. Retain any prior entitlement.
                isAuthoritative: false
            )
        }
        guard parsed.availableCount >= 0 else {
            return ResetMapping(
                summaries: [],
                presentation: .invalid,
                invalidDetailCount: 0,
                invalidSummaryCount: max(1, invalidSummaryCount),
                isAuthoritative: false
            )
        }

        var invalidDetailCount = 0
        let details: [ResetEntitlementDetail]? = parsed.details.map { sourceDetails in
            sourceDetails.compactMap { detail in
                guard let sourceID = nonEmpty(detail.sourceID),
                      let status = nonEmpty(detail.status) else {
                    invalidDetailCount += 1
                    return nil
                }

                let grantedAt = validDate(detail.grantedAt, invalidCount: &invalidDetailCount)
                let expiresAt = validDate(detail.expiresAt, invalidCount: &invalidDetailCount)
                return ResetEntitlementDetail(
                    sourceID: sourceID,
                    status: status,
                    grantedAt: grantedAt,
                    expiresAt: expiresAt,
                    title: detail.title
                )
            }
        }

        let provenanceIdentity = MetricSourceIdentity(
            providerID: .openAI,
            sourceProductID: "account",
            sourceBucketID: "rateLimitResetCredits",
            sourceMetricID: "availableCount"
        )
        let summary = ResetEntitlementSummary(
            availableCount: Decimal(parsed.availableCount),
            details: details,
            provenance: MetricProvenance(
                sourceIdentity: provenanceIdentity,
                providerSource: source,
                fetchedAt: fetchedAt
            )
        )

        let presentation: OpenAIResetEntitlementPresentation
        if parsed.availableCount == 0 {
            presentation = .hidden
        } else if let selected = details?
            .filter(isAvailableExpiringDetail)
            .sorted(by: resetDetailComesBefore)
            .first {
            presentation = .detail(selected)
        } else {
            presentation = .countOnly
        }

        return ResetMapping(
            // An explicit zero is the only authoritative clear. Do not retain a
            // synthetic zero-valued entitlement in last-good state.
            summaries: parsed.availableCount == 0 ? [] : [summary],
            presentation: presentation,
            invalidDetailCount: invalidDetailCount,
            invalidSummaryCount: invalidSummaryCount,
            isAuthoritative: true
        )
    }

    private static func validDate(_ timestamp: Int64?, invalidCount: inout Int) -> Date? {
        guard let timestamp else { return nil }
        guard timestamp > 0 else {
            invalidCount += 1
            return nil
        }
        return Date(timeIntervalSince1970: TimeInterval(timestamp))
    }

    private static func isAvailableExpiringDetail(_ detail: ResetEntitlementDetail) -> Bool {
        detail.status.caseInsensitiveCompare("available") == .orderedSame
            && detail.expiresAt != nil
    }

    private static func resetDetailComesBefore(
        _ lhs: ResetEntitlementDetail,
        _ rhs: ResetEntitlementDetail
    ) -> Bool {
        let lhsExpiry = lhs.expiresAt ?? .distantFuture
        let rhsExpiry = rhs.expiresAt ?? .distantFuture
        if lhsExpiry != rhsExpiry { return lhsExpiry < rhsExpiry }

        let lhsGranted = lhs.grantedAt ?? .distantFuture
        let rhsGranted = rhs.grantedAt ?? .distantFuture
        if lhsGranted != rhsGranted { return lhsGranted < rhsGranted }
        return lhs.sourceID < rhs.sourceID
    }

    private static func successfulNodeState(fetchedAt: Date) -> QuotaNodeState {
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

    private static func canonicalOrder(for kind: ParsedOpenAIBucketKind) -> Int {
        switch kind {
        case .codex: 0
        case .spark: 1
        case .providerDefined: 100
        }
    }

    private static func titleKey(for kind: ParsedOpenAIBucketKind) -> String {
        switch kind {
        case .codex: "provider.openai.product.codex"
        case .spark: "provider.openai.product.spark"
        case .providerDefined: "provider.openai.product.provider-defined"
        }
    }

    private static func productComesBefore(
        _ lhs: QuotaProductData,
        _ rhs: QuotaProductData
    ) -> Bool {
        if lhs.canonicalOrder != rhs.canonicalOrder {
            return lhs.canonicalOrder < rhs.canonicalOrder
        }
        return lhs.sourceProductID < rhs.sourceProductID
    }

    private static func metricComesBefore(_ lhs: QuotaMetric, _ rhs: QuotaMetric) -> Bool {
        let lhsOrder = windowOrder(lhs.window?.kind)
        let rhsOrder = windowOrder(rhs.window?.kind)
        if lhsOrder != rhsOrder { return lhsOrder < rhsOrder }
        return lhs.sourceMetricID < rhs.sourceMetricID
    }

    private static func windowOrder(_ kind: QuotaWindowKind?) -> Int {
        switch kind {
        case .session, .shortCycle: 0
        case .weekly: 1
        case .monthly: 2
        case .providerDefined: 3
        case nil: 4
        }
    }

    private static func bucketID(fromWindowSourceID sourceID: String) -> String? {
        guard let separator = sourceID.lastIndex(of: ".") else { return nil }
        return String(sourceID[..<separator])
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value,
              !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return value
    }

    private static func decimal(from value: Double) -> Decimal {
        Decimal(string: String(value), locale: posixLocale) ?? Decimal(value)
    }
}
