public enum ProviderQuotaIdentityError: Error, Equatable, Sendable {
    case invalidTransport
    case rootProviderMismatch(expected: ProviderID, actual: ProviderID)
    case sourceProviderMismatch(expected: ProviderID, actual: ProviderID)
    case productProviderMismatch(ProductID)
    case productSourceIDMismatch(id: ProductID, declared: String)
    case duplicateProductID(ProductID)
    case metricProviderMismatch(MetricID)
    case metricProductMismatch(id: MetricID, expectedProductID: ProductID)
    case metricSourceIDMismatch(id: MetricID, declared: String)
    case metricProvenanceMismatch(MetricID)
    case provenanceSourceProviderMismatch(MetricSourceIdentity)
    case provenanceProviderMismatch(MetricSourceIdentity)
    case duplicateMetricID(MetricID)
    case balanceProviderMismatch(QuotaBalanceID)
    case duplicateBalanceID(QuotaBalanceID)
    case duplicateBalanceProvenance(MetricSourceIdentity)
    case resetProviderMismatch(ResetEntitlementID)
    case duplicateResetEntitlementID(ResetEntitlementID)
    case duplicateResetDetailID(summary: ResetEntitlementID, sourceID: String)
}

/// Validates the complete identity graph before quota data enters retained state.
/// Version fields may differ between retained siblings after a partial refresh, but
/// every source identity must remain owned by the same Provider.
public enum ProviderQuotaIdentityValidator {
    public static func validate(
        _ data: ProviderQuotaData,
        expectedProviderID: ProviderID
    ) throws {
        try validate(
            providerID: data.providerID,
            source: data.source,
            products: data.products,
            balances: data.balances,
            resetEntitlements: data.resetEntitlements,
            expectedProviderID: expectedProviderID
        )
        if expectedProviderID == .grokBot {
            if data.source.adapterID == "cursor-grok-shared" {
                guard let observation = data.grokBotUsage, observation.meteringSystem == .xShared,
                      let shared = observation.shared, observation.usagePercent == shared.usagePercent,
                      observation.currentPeriodStart == shared.periodStart, observation.nextResetAt == shared.resetsAt,
                      observation.trialExpiresAt == nil else { throw ProviderQuotaIdentityError.invalidTransport }
            } else if data.grokBotUsage?.shared != nil { throw ProviderQuotaIdentityError.invalidTransport }
        }
    }

    public static func validate(
        providerID: ProviderID,
        source: ProviderSourceIdentity,
        products: [QuotaProductData],
        balances: [QuotaBalance],
        resetEntitlements: [ResetEntitlementSummary],
        expectedProviderID: ProviderID
    ) throws {
        guard providerID == expectedProviderID else {
            throw ProviderQuotaIdentityError.rootProviderMismatch(
                expected: expectedProviderID,
                actual: providerID
            )
        }
        guard source.providerID == expectedProviderID else {
            throw ProviderQuotaIdentityError.sourceProviderMismatch(
                expected: expectedProviderID,
                actual: source.providerID
            )
        }

        try validateTransport(source)

        if expectedProviderID == .grokBot {
            guard let scope = source.sessionScope, !scope.isEmpty,
                  products.flatMap(\.metrics).allSatisfy({ $0.provenance.providerSource == source }) else {
                throw ProviderQuotaIdentityError.invalidTransport
            }
            if source.adapterID == "cursor-grok-shared" {
                guard products.count == 1, products.first?.sourceProductID == "x-shared",
                      products.first?.metrics.count == 1,
                      products.first?.metrics.first?.sourceMetricID == "weeklyIncludedUsage",
                      products.first?.metrics.first?.id.sourceIdentity.sourceBucketID == "weekly",
                      products.first?.metrics.first?.window?.kind == .weekly,
                      balances.isEmpty, resetEntitlements.isEmpty else { throw ProviderQuotaIdentityError.invalidTransport }
            }
        }
        var productIDs = Set<ProductID>()
        var metricIDs = Set<MetricID>()
        for product in products {
            guard product.id.providerID == expectedProviderID else {
                throw ProviderQuotaIdentityError.productProviderMismatch(product.id)
            }
            guard product.id.sourceProductID == product.sourceProductID else {
                throw ProviderQuotaIdentityError.productSourceIDMismatch(
                    id: product.id,
                    declared: product.sourceProductID
                )
            }
            guard productIDs.insert(product.id).inserted else {
                throw ProviderQuotaIdentityError.duplicateProductID(product.id)
            }

            for metric in product.metrics {
                let identity = metric.id.sourceIdentity
                guard identity.providerID == expectedProviderID else {
                    throw ProviderQuotaIdentityError.metricProviderMismatch(metric.id)
                }
                guard identity.sourceProductID == product.sourceProductID else {
                    throw ProviderQuotaIdentityError.metricProductMismatch(
                        id: metric.id,
                        expectedProductID: product.id
                    )
                }
                guard identity.sourceMetricID == metric.sourceMetricID else {
                    throw ProviderQuotaIdentityError.metricSourceIDMismatch(
                        id: metric.id,
                        declared: metric.sourceMetricID
                    )
                }
                guard metric.provenance.sourceIdentity == identity else {
                    throw ProviderQuotaIdentityError.metricProvenanceMismatch(metric.id)
                }
                try validate(
                    provenance: metric.provenance,
                    expectedProviderID: expectedProviderID
                )
                guard metricIDs.insert(metric.id).inserted else {
                    throw ProviderQuotaIdentityError.duplicateMetricID(metric.id)
                }
            }
        }

        var balanceIDs = Set<QuotaBalanceID>()
        var balanceProvenanceIDs = Set<MetricSourceIdentity>()
        for balance in balances {
            try validate(
                provenance: balance.provenance,
                expectedProviderID: expectedProviderID
            )
            guard balance.id.providerID == expectedProviderID else {
                throw ProviderQuotaIdentityError.balanceProviderMismatch(balance.id)
            }
            guard balanceIDs.insert(balance.id).inserted else {
                throw ProviderQuotaIdentityError.duplicateBalanceID(balance.id)
            }
            guard balanceProvenanceIDs.insert(balance.provenance.sourceIdentity).inserted else {
                throw ProviderQuotaIdentityError.duplicateBalanceProvenance(
                    balance.provenance.sourceIdentity
                )
            }
        }

        var resetIDs = Set<ResetEntitlementID>()
        for summary in resetEntitlements {
            try validate(
                provenance: summary.provenance,
                expectedProviderID: expectedProviderID
            )
            guard summary.id.sourceIdentity.providerID == expectedProviderID else {
                throw ProviderQuotaIdentityError.resetProviderMismatch(summary.id)
            }
            guard resetIDs.insert(summary.id).inserted else {
                throw ProviderQuotaIdentityError.duplicateResetEntitlementID(summary.id)
            }

            var detailIDs = Set<String>()
            for detail in summary.details ?? [] {
                guard detailIDs.insert(detail.sourceID).inserted else {
                    throw ProviderQuotaIdentityError.duplicateResetDetailID(
                        summary: summary.id,
                        sourceID: detail.sourceID
                    )
                }
            }
        }
    }

    public static func validateTransport(_ source: ProviderSourceIdentity) throws {
        switch source.transport {
        case .cli:
            guard source.providerID != .grokBot else {
                throw ProviderQuotaIdentityError.invalidTransport
            }
        case let .https(origin, version, evidence):
            guard source.providerID == .grokBot, origin == "https://cursor.com", !version.isEmpty,
                  !source.schemaVersion.isEmpty,
                  !source.contractVersion.isEmpty, source.executableIdentity.isEmpty, source.cliVersion.isEmpty else {
                throw ProviderQuotaIdentityError.invalidTransport
            }
            let legacy = source.adapterID == "cursor-sand" && evidence == "CodexBar-910dc82e78e212f8904f3725a756ad03fa86c551"
            let shared = source.adapterID == "cursor-grok-shared" && version == "1"
                && source.schemaVersion == "cursor-shared-usage-status-2" && source.contractVersion == "cursor-shared-weekly-v1"
                && evidence == "official-cursor-native-usage-status-20261016-v1"
            guard legacy || shared else { throw ProviderQuotaIdentityError.invalidTransport }
        }
    }

    private static func validate(
        provenance: MetricProvenance,
        expectedProviderID: ProviderID
    ) throws {
        try validateTransport(provenance.providerSource)
        guard provenance.sourceIdentity.providerID == expectedProviderID else {
            throw ProviderQuotaIdentityError.provenanceSourceProviderMismatch(
                provenance.sourceIdentity
            )
        }
        guard provenance.providerSource.providerID == expectedProviderID else {
            throw ProviderQuotaIdentityError.provenanceProviderMismatch(
                provenance.sourceIdentity
            )
        }
    }
}
