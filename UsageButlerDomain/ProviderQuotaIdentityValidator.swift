public enum ProviderQuotaIdentityError: Error, Equatable, Sendable {
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

    private static func validate(
        provenance: MetricProvenance,
        expectedProviderID: ProviderID
    ) throws {
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
