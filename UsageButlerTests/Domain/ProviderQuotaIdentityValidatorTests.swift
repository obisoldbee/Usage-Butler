import Foundation
import XCTest
@testable import UsageButlerDomain

final class ProviderQuotaIdentityValidatorTests: XCTestCase {
    private let fetchedAt = Date(timeIntervalSince1970: 1_786_300_000)

    func testValidRecursiveIdentityGraphIsAccepted() throws {
        XCTAssertNoThrow(
            try ProviderQuotaIdentityValidator.validate(
                fixture(),
                expectedProviderID: .ark
            )
        )
    }

    func testMaliciousMixedProviderFixturesAreRejectedAtEveryNestedKind() throws {
        let valid = fixture()
        let product = try XCTUnwrap(valid.products.first)
        let metric = try XCTUnwrap(product.metrics.first)
        let balance = try XCTUnwrap(valid.balances.first)
        let reset = try XCTUnwrap(valid.resetEntitlements.first)
        let foreignSource = providerSource(.miniMax)

        let mixedRoot = ProviderQuotaData(
            providerID: .miniMax,
            source: valid.source,
            fetchedAt: valid.fetchedAt,
            products: valid.products,
            balances: valid.balances,
            resetEntitlements: valid.resetEntitlements
        )
        assertRejected(mixedRoot)

        let mixedSource = replacing(valid, source: foreignSource)
        assertRejected(mixedSource)

        let foreignProduct = QuotaProductData(
            id: ProductID(providerID: .miniMax, sourceProductID: product.sourceProductID),
            sourceProductID: product.sourceProductID,
            titleKey: product.titleKey,
            canonicalOrder: product.canonicalOrder,
            planLevel: product.planLevel,
            state: product.state,
            metrics: product.metrics
        )
        assertRejected(replacing(valid, products: [foreignProduct]))

        let foreignMetricIdentity = MetricSourceIdentity(
            providerID: .miniMax,
            sourceProductID: product.sourceProductID,
            sourceBucketID: "weekly",
            sourceMetricID: "usage"
        )
        let foreignMetric = replacing(
            metric,
            id: MetricID(sourceIdentity: foreignMetricIdentity),
            provenance: MetricProvenance(
                sourceIdentity: foreignMetricIdentity,
                providerSource: foreignSource,
                fetchedAt: fetchedAt
            )
        )
        assertRejected(replacing(valid, products: [replacing(product, metrics: [foreignMetric])]))

        let mismatchedProvenanceIdentity = MetricSourceIdentity(
            providerID: .ark,
            sourceProductID: product.sourceProductID,
            sourceBucketID: "monthly",
            sourceMetricID: "usage"
        )
        let mismatchedProvenanceMetric = replacing(
            metric,
            id: metric.id,
            provenance: MetricProvenance(
                sourceIdentity: mismatchedProvenanceIdentity,
                providerSource: valid.source,
                fetchedAt: fetchedAt
            )
        )
        assertRejected(
            replacing(valid, products: [replacing(product, metrics: [mismatchedProvenanceMetric])])
        )

        let foreignBalance = QuotaBalance(
            sourceBalanceID: balance.sourceBalanceID,
            amount: balance.amount,
            unit: balance.unit,
            provenance: MetricProvenance(
                sourceIdentity: MetricSourceIdentity(
                    providerID: .miniMax,
                    sourceProductID: "account",
                    sourceBucketID: "credits",
                    sourceMetricID: "balance"
                ),
                providerSource: foreignSource,
                fetchedAt: fetchedAt
            ),
            state: balance.state
        )
        assertRejected(replacing(valid, balances: [foreignBalance]))

        let foreignReset = ResetEntitlementSummary(
            availableCount: reset.availableCount,
            details: reset.details,
            provenance: MetricProvenance(
                sourceIdentity: MetricSourceIdentity(
                    providerID: .miniMax,
                    sourceProductID: "account",
                    sourceBucketID: "resets",
                    sourceMetricID: "availableCount"
                ),
                providerSource: foreignSource,
                fetchedAt: fetchedAt
            ),
            state: reset.state
        )
        assertRejected(replacing(valid, resetEntitlements: [foreignReset]))
    }

    func testDuplicateStableIDsAreRejectedForEveryCollectionAndResetDetails() throws {
        let valid = fixture()
        let product = try XCTUnwrap(valid.products.first)
        let metric = try XCTUnwrap(product.metrics.first)
        let balance = try XCTUnwrap(valid.balances.first)
        let reset = try XCTUnwrap(valid.resetEntitlements.first)

        assertRejected(replacing(valid, products: [product, product]))
        assertRejected(
            replacing(valid, products: [replacing(product, metrics: [metric, metric])])
        )
        assertRejected(replacing(valid, balances: [balance, balance]))
        assertRejected(replacing(valid, resetEntitlements: [reset, reset]))

        let duplicateDetails = ResetEntitlementSummary(
            availableCount: reset.availableCount,
            details: [
                resetDetail(sourceID: "duplicate"),
                resetDetail(sourceID: "duplicate")
            ],
            provenance: reset.provenance,
            state: reset.state
        )
        assertRejected(replacing(valid, resetEntitlements: [duplicateDetails]))
    }

    private func fixture() -> ProviderQuotaData {
        let source = providerSource(.ark)
        let productID = ProductID(providerID: .ark, sourceProductID: "agent-plan")
        let metricIdentity = MetricSourceIdentity(
            providerID: .ark,
            sourceProductID: productID.sourceProductID,
            sourceBucketID: "weekly",
            sourceMetricID: "usage"
        )
        let metric = QuotaMetric(
            id: MetricID(sourceIdentity: metricIdentity),
            sourceMetricID: "usage",
            sourceLabel: "weekly",
            window: nil,
            value: .percent(DirectedPercent(sourceValue: 13, sourceDirection: .used)),
            sourceStatus: nil,
            provenance: MetricProvenance(
                sourceIdentity: metricIdentity,
                providerSource: source,
                fetchedAt: fetchedAt
            ),
            state: .authoritativeData(asOf: fetchedAt)
        )
        let product = QuotaProductData(
            id: productID,
            sourceProductID: productID.sourceProductID,
            titleKey: "provider.ark.agent-plan",
            canonicalOrder: 0,
            planLevel: nil,
            state: .authoritativeData(asOf: fetchedAt),
            metrics: [metric]
        )
        let balanceIdentity = MetricSourceIdentity(
            providerID: .ark,
            sourceProductID: "account",
            sourceBucketID: "credits",
            sourceMetricID: "balance"
        )
        let balance = QuotaBalance(
            sourceBalanceID: "account.credits",
            amount: 12,
            unit: "credits",
            provenance: MetricProvenance(
                sourceIdentity: balanceIdentity,
                providerSource: source,
                fetchedAt: fetchedAt
            ),
            state: .authoritativeData(asOf: fetchedAt)
        )
        let resetIdentity = MetricSourceIdentity(
            providerID: .ark,
            sourceProductID: "account",
            sourceBucketID: "resets",
            sourceMetricID: "availableCount"
        )
        let reset = ResetEntitlementSummary(
            availableCount: 2,
            details: [resetDetail(sourceID: "reset-1"), resetDetail(sourceID: "reset-2")],
            provenance: MetricProvenance(
                sourceIdentity: resetIdentity,
                providerSource: source,
                fetchedAt: fetchedAt
            ),
            state: .authoritativeData(asOf: fetchedAt)
        )
        return ProviderQuotaData(
            providerID: .ark,
            source: source,
            fetchedAt: fetchedAt,
            products: [product],
            balances: [balance],
            resetEntitlements: [reset]
        )
    }

    private func providerSource(_ providerID: ProviderID) -> ProviderSourceIdentity {
        ProviderSourceIdentity(
            providerID: providerID,
            adapterID: "fixture.\(providerID.rawValue)",
            executableIdentity: "fixture",
            cliVersion: "1",
            schemaVersion: "v1",
            contractVersion: "v1"
        )
    }

    private func resetDetail(sourceID: String) -> ResetEntitlementDetail {
        ResetEntitlementDetail(
            sourceID: sourceID,
            status: "available",
            grantedAt: nil,
            expiresAt: nil,
            title: nil
        )
    }

    private func assertRejected(
        _ data: ProviderQuotaData,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(
            try ProviderQuotaIdentityValidator.validate(data, expectedProviderID: .ark),
            file: file,
            line: line
        )
    }

    private func replacing(
        _ data: ProviderQuotaData,
        source: ProviderSourceIdentity? = nil,
        products: [QuotaProductData]? = nil,
        balances: [QuotaBalance]? = nil,
        resetEntitlements: [ResetEntitlementSummary]? = nil
    ) -> ProviderQuotaData {
        ProviderQuotaData(
            providerID: data.providerID,
            source: source ?? data.source,
            fetchedAt: data.fetchedAt,
            products: products ?? data.products,
            balances: balances ?? data.balances,
            resetEntitlements: resetEntitlements ?? data.resetEntitlements
        )
    }

    private func replacing(
        _ product: QuotaProductData,
        metrics: [QuotaMetric]
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

    private func replacing(
        _ metric: QuotaMetric,
        id: MetricID,
        provenance: MetricProvenance
    ) -> QuotaMetric {
        QuotaMetric(
            id: id,
            sourceMetricID: metric.sourceMetricID,
            sourceLabel: metric.sourceLabel,
            window: metric.window,
            value: metric.value,
            sourceStatus: metric.sourceStatus,
            provenance: provenance,
            state: metric.state
        )
    }
}
