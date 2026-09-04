import Foundation
import XCTest
@testable import UsageButlerDomain

final class QuotaContractTests: XCTestCase {
    func testQuotaAlgebraPreservesEverySourceKindAndDirection() {
        let remaining = DirectedPercent(
            sourceValue: decimal("88.25"),
            sourceDirection: .remaining
        )
        let usedCount = DirectedCount(
            sourceValue: 2,
            total: 5,
            sourceDirection: .used,
            unit: "count"
        )
        let arkAmount = UsedTotalAmount(
            used: 20,
            total: 100,
            unit: "AFP",
            sourcePercent: DirectedPercent(sourceValue: 23, sourceDirection: .used)
        )

        XCTAssertEqual(QuotaMetricValue.percent(remaining), .percent(remaining))
        XCTAssertEqual(QuotaMetricValue.count(usedCount), .count(usedCount))
        XCTAssertEqual(QuotaMetricValue.usedTotal(arkAmount), .usedTotal(arkAmount))
        XCTAssertEqual(QuotaMetricValue.unlimited, .unlimited)
        XCTAssertEqual(
            QuotaMetricValue.absolute(value: 42, unit: "credits", direction: .remaining),
            .absolute(value: 42, unit: "credits", direction: .remaining)
        )
        XCTAssertEqual(
            QuotaMetricValue.unavailable(reason: .missingRequiredField("period.percent")),
            .unavailable(reason: .missingRequiredField("period.percent"))
        )
        XCTAssertEqual(arkAmount.sourcePercent?.sourceValue, 23)
        XCTAssertEqual(arkAmount.sourcePercent?.sourceDirection, .used)
    }

    func testMetricIdentityUsesRawSourceIdentityInsteadOfDisplayTextOrPosition() {
        let weeklyIdentity = MetricSourceIdentity(
            providerID: .openAI,
            sourceProductID: "codex",
            sourceBucketID: "weekly",
            sourceMetricID: "primary.used_percent"
        )
        let sparkIdentity = MetricSourceIdentity(
            providerID: .openAI,
            sourceProductID: "codex",
            sourceBucketID: "spark-weekly",
            sourceMetricID: "primary.used_percent"
        )

        XCTAssertEqual(
            MetricID(sourceIdentity: weeklyIdentity),
            MetricID(sourceIdentity: weeklyIdentity)
        )
        XCTAssertNotEqual(
            MetricID(sourceIdentity: weeklyIdentity),
            MetricID(sourceIdentity: sparkIdentity)
        )
    }

    func testProvenanceRetainsProviderProductBucketMetricAndContractVersions() {
        let source = ProviderSourceIdentity(
            providerID: .miniMax,
            adapterID: "minimax.mmx",
            executableIdentity: "mmx-selected-v1",
            cliVersion: "1.0.19",
            schemaVersion: "quota-show-v1",
            contractVersion: "usage-butler-provider-contract-v0.8"
        )
        let identity = MetricSourceIdentity(
            providerID: .miniMax,
            sourceProductID: "token-plan",
            sourceBucketID: "video.current",
            sourceMetricID: "usage_count"
        )
        let fetchedAt = Date(timeIntervalSince1970: 1_786_300_000)
        let provenance = MetricProvenance(
            sourceIdentity: identity,
            providerSource: source,
            fetchedAt: fetchedAt
        )

        XCTAssertEqual(provenance.sourceIdentity, identity)
        XCTAssertEqual(provenance.providerSource.providerID, .miniMax)
        XCTAssertEqual(provenance.providerSource.cliVersion, "1.0.19")
        XCTAssertEqual(provenance.providerSource.schemaVersion, "quota-show-v1")
        XCTAssertEqual(
            provenance.providerSource.contractVersion,
            "usage-butler-provider-contract-v0.8"
        )
        XCTAssertEqual(provenance.fetchedAt, fetchedAt)
    }

    private func decimal(_ value: String) -> Decimal {
        guard let result = Decimal(string: value, locale: Locale(identifier: "en_US_POSIX")) else {
            XCTFail("Invalid decimal fixture: \(value)")
            return 0
        }
        return result
    }
}
