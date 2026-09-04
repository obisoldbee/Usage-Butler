import Foundation
import UsageButlerDomain
import XCTest
@testable import UsageButlerProviders

final class OpenAIQuotaDomainMapperTests: XCTestCase {
    func testMapperPreservesSourceIdentityRawUsedPercentAndPresentationDerivation() throws {
        let fetchedAt = Date(timeIntervalSince1970: 1_786_300_000)
        let source = providerSource()
        let account = try parsedAccount(planType: "pro")
        let rateLimits = try parsedRateLimits(fullRateLimitsJSON(codexUsed: 40, sparkUsed: 1))

        let mapping = try OpenAIQuotaDomainMapper.map(
            account: account,
            rateLimits: rateLimits,
            source: source,
            fetchedAt: fetchedAt
        )

        XCTAssertFalse(mapping.diagnostics.hasPartialFailure)
        XCTAssertTrue(mapping.productsAreAuthoritative)
        XCTAssertEqual(mapping.data.providerID, .openAI)
        XCTAssertEqual(mapping.data.source, source)
        XCTAssertEqual(mapping.data.fetchedAt, fetchedAt)
        XCTAssertEqual(mapping.data.products.map(\.sourceProductID), ["codex", "codex_bengalfox"])

        let codex = try XCTUnwrap(mapping.data.products.first { $0.sourceProductID == "codex" })
        XCTAssertEqual(codex.titleKey, "provider.openai.product.codex")
        XCTAssertEqual(codex.planLevel?.value, "pro")
        XCTAssertEqual(
            codex.planLevel?.origin,
            .reported(sourceField: "account/read.account.planType")
        )

        let metric = try XCTUnwrap(codex.metrics.first)
        guard case let .percent(rawPercent) = metric.value else {
            return XCTFail("Expected a source percent")
        }
        XCTAssertEqual(rawPercent.sourceValue, Decimal(40))
        XCTAssertEqual(rawPercent.sourceDirection, .used)
        XCTAssertEqual(metric.sourceMetricID, "primary.used_percent")
        XCTAssertEqual(metric.id.sourceIdentity.sourceProductID, "codex")
        XCTAssertEqual(metric.id.sourceIdentity.sourceBucketID, "codex")
        XCTAssertEqual(metric.provenance.providerSource, source)
        XCTAssertEqual(metric.provenance.fetchedAt, fetchedAt)
        XCTAssertEqual(metric.window?.kind, .weekly)
        XCTAssertEqual(
            metric.window?.timeEvent,
            QuotaTimeEvent(
                kind: .reset,
                occursAt: Date(timeIntervalSince1970: 1_786_846_755)
            )
        )

        let rule = try XCTUnwrap(mapping.presentationRules[metric.id])
        XCTAssertEqual(rule.contractVersion, source.contractVersion)
        XCTAssertEqual(rule.displayDirection, .remaining)
        XCTAssertEqual(rule.percentDerivation, .complementOfUsed)
        XCTAssertEqual(rule.timeEventKind, .reset)
        XCTAssertEqual(rule.timeStyle, .absoluteDateTime)

        let spark = try XCTUnwrap(
            mapping.data.products.first { $0.sourceProductID == "codex_bengalfox" }
        )
        XCTAssertEqual(spark.titleKey, "provider.openai.product.spark")
        XCTAssertEqual(spark.metrics.count, 1)
        XCTAssertTrue(mapping.authoritativeProductIDs.contains(spark.id))

        let balance = try XCTUnwrap(mapping.data.balances.first)
        XCTAssertEqual(balance.sourceBalanceID, "codex.credits.balance")
        XCTAssertEqual(balance.amount, decimal("12.5"))
        XCTAssertEqual(balance.provenance.sourceIdentity.sourceProductID, "codex")
        XCTAssertEqual(balance.provenance.sourceIdentity.sourceBucketID, "codex")
        XCTAssertEqual(balance.provenance.sourceIdentity.sourceMetricID, "credits.balance")
    }

    func testMapperUsesAuthoritativeResetCountAndSelectsEarliestAvailableExpiry() throws {
        let mapping = try OpenAIQuotaDomainMapper.map(
            account: try parsedAccount(planType: nil),
            rateLimits: try parsedRateLimits(resetRateLimitsJSON()),
            source: providerSource(),
            fetchedAt: Date(timeIntervalSince1970: 10_000)
        )

        let summary = try XCTUnwrap(mapping.data.resetEntitlements.first)
        XCTAssertEqual(summary.availableCount, Decimal(4))
        XCTAssertEqual(summary.details?.count, 4)
        XCTAssertEqual(summary.provenance.sourceIdentity.sourceProductID, "account")
        XCTAssertEqual(summary.provenance.sourceIdentity.sourceBucketID, "rateLimitResetCredits")
        XCTAssertEqual(summary.provenance.sourceIdentity.sourceMetricID, "availableCount")

        guard case let .detail(selected)? = mapping.resetEntitlementPresentation else {
            return XCTFail("Expected earliest available reset detail")
        }
        XCTAssertEqual(selected.sourceID, "winner")
        XCTAssertEqual(selected.grantedAt, Date(timeIntervalSince1970: 10))
        XCTAssertEqual(selected.expiresAt, Date(timeIntervalSince1970: 200))
    }

    func testMalformedSparkBucketMakesOnlyCodexAuthoritativeAndPlanNeverCreatesSpark() throws {
        let projected = try parsedRateLimits(#"""
        {
          "rateLimitsByLimitId": {
            "codex": {
              "limitId": "codex",
              "primary": { "usedPercent": 20, "windowDurationMins": 10080, "resetsAt": 5000 },
              "planType": "pro"
            },
            "codex_bengalfox": {
              "limitId": "codex_bengalfox",
              "limitName": "GPT-Codex-Spark",
              "primary": { "usedPercent": "malformed", "windowDurationMins": 10080 }
            }
          }
        }
        """#)
        let mapping = try OpenAIQuotaDomainMapper.map(
            account: try parsedAccount(planType: "pro"),
            rateLimits: projected,
            source: providerSource(),
            fetchedAt: Date(timeIntervalSince1970: 5_000)
        )

        XCTAssertTrue(mapping.diagnostics.hasPartialFailure)
        XCTAssertFalse(mapping.productsAreAuthoritative)
        XCTAssertEqual(mapping.diagnostics.invalidBucketSourceIDs, ["codex_bengalfox"])
        XCTAssertEqual(mapping.data.products.map(\.sourceProductID), ["codex"])
        XCTAssertEqual(mapping.authoritativeProductIDs, [
            ProductID(providerID: .openAI, sourceProductID: "codex")
        ])
        XCTAssertFalse(
            mapping.data.products.contains { $0.sourceProductID == "codex_bengalfox" },
            "planType must never synthesize Spark"
        )
    }

    func testPositiveResetCountWithoutUsableDetailsRemainsCountOnly() throws {
        let projected = try parsedRateLimits(#"""
        {
          "rateLimitsByLimitId": {},
          "rateLimitResetCredits": {
            "availableCount": 2,
            "details": [
              { "id": "consumed", "status": "consumed", "expiresAt": 100 }
            ]
          }
        }
        """#)
        let mapping = try OpenAIQuotaDomainMapper.map(
            account: nil,
            rateLimits: projected,
            source: providerSource(),
            fetchedAt: Date(timeIntervalSince1970: 100)
        )

        XCTAssertEqual(mapping.data.resetEntitlements.first?.availableCount, Decimal(2))
        XCTAssertEqual(mapping.resetEntitlementPresentation, .countOnly)
    }

    func testMalformedCreditsArePartialWithoutDiscardingValidQuotaProduct() throws {
        let projected = try parsedRateLimits(#"""
        {
          "rateLimitsByLimitId": {
            "codex": {
              "limitId": "codex",
              "primary": { "usedPercent": 20, "windowDurationMins": 10080 },
              "credits": { "balance": { "opaque": "must-not-escape" } }
            }
          }
        }
        """#)
        let mapping = try OpenAIQuotaDomainMapper.map(
            account: nil,
            rateLimits: projected,
            source: providerSource(),
            fetchedAt: Date(timeIntervalSince1970: 100)
        )

        XCTAssertEqual(mapping.data.products.map(\.sourceProductID), ["codex"])
        XCTAssertEqual(mapping.diagnostics.invalidCreditSourceIDs, ["codex"])
        XCTAssertTrue(mapping.diagnostics.hasPartialFailure)
        XCTAssertFalse(mapping.balancesAreAuthoritative)
        XCTAssertTrue(mapping.data.balances.isEmpty)
    }

    func testNegativeResetCountIsPartialAndCannotAuthoritativelyClearLastGood() throws {
        let projected = try parsedRateLimits(#"""
        {
          "rateLimitsByLimitId": {},
          "rateLimitResetCredits": { "availableCount": -1, "details": null }
        }
        """#)
        let mapping = try OpenAIQuotaDomainMapper.map(
            account: nil,
            rateLimits: projected,
            source: providerSource(),
            fetchedAt: Date(timeIntervalSince1970: 100)
        )

        XCTAssertEqual(mapping.resetEntitlementPresentation, .invalid)
        XCTAssertEqual(mapping.diagnostics.invalidResetSummaryCount, 1)
        XCTAssertTrue(mapping.diagnostics.hasPartialFailure)
        XCTAssertFalse(mapping.resetEntitlementsAreAuthoritative)
        XCTAssertTrue(mapping.data.resetEntitlements.isEmpty)
    }

    func testMissingOrNullResetContainerIsLegalOmissionNotZeroOrPartialFailure() throws {
        for json in [
            #"{"rateLimitsByLimitId": {}}"#,
            #"{"rateLimitsByLimitId": {}, "rateLimitResetCredits": null}"#
        ] {
            let mapping = try OpenAIQuotaDomainMapper.map(
                account: nil,
                rateLimits: try parsedRateLimits(json),
                source: providerSource(),
                fetchedAt: Date(timeIntervalSince1970: 100)
            )

            XCTAssertNil(mapping.resetEntitlementPresentation)
            XCTAssertFalse(mapping.resetEntitlementsAreAuthoritative)
            XCTAssertTrue(mapping.data.resetEntitlements.isEmpty)
            XCTAssertEqual(mapping.diagnostics.invalidResetSummaryCount, 0)
            XCTAssertFalse(mapping.diagnostics.hasPartialFailure)
            XCTAssertTrue(mapping.productsAreAuthoritative)
        }
    }

    func testExplicitAvailableCountZeroIsAuthoritativeClear() throws {
        let mapping = try OpenAIQuotaDomainMapper.map(
            account: nil,
            rateLimits: try parsedRateLimits(#"""
            {
              "rateLimitsByLimitId": {},
              "rateLimitResetCredits": { "availableCount": 0, "details": null }
            }
            """#),
            source: providerSource(),
            fetchedAt: Date(timeIntervalSince1970: 100)
        )

        XCTAssertEqual(mapping.resetEntitlementPresentation, .hidden)
        XCTAssertTrue(mapping.resetEntitlementsAreAuthoritative)
        XCTAssertTrue(mapping.data.resetEntitlements.isEmpty)
        XCTAssertEqual(mapping.diagnostics.invalidResetSummaryCount, 0)
    }

    private func parsedAccount(planType: String?) throws -> ParsedOpenAIAccount {
        let planField = planType.map { #", "planType": "\#($0)""# } ?? ""
        let data = Data(
            #"{"account":{"type":"chatgpt"\#(planField)},"requiresOpenaiAuth":false}"#.utf8
        )
        return OpenAIQuotaProjector.projectAccount(
            try OpenAIAppServerDecoder.decodeAccountRead(from: data)
        )
    }

    private func parsedRateLimits(_ json: String) throws -> ParsedOpenAIRateLimits {
        try OpenAIQuotaProjector.projectRateLimits(
            OpenAIAppServerDecoder.decodeRateLimitsRead(from: Data(json.utf8))
        )
    }

    private func providerSource() -> ProviderSourceIdentity {
        ProviderSourceIdentity(
            providerID: .openAI,
            adapterID: "openai.codex-app-server",
            executableIdentity: "selected-codex-v1",
            cliVersion: "0.147.0",
            schemaVersion: "account-rate-limits-v1",
            contractVersion: "usage-butler-provider-contract-v0.8"
        )
    }

    private func fullRateLimitsJSON(codexUsed: Int, sparkUsed: Int) -> String {
        #"""
        {
          "rateLimitsByLimitId": {
            "codex": {
              "limitId": "codex",
              "primary": {
                "usedPercent": \#(codexUsed),
                "windowDurationMins": 10080,
                "resetsAt": 1786846755
              },
              "credits": {
                "hasCredits": true,
                "unlimited": false,
                "balance": "12.5"
              }
            },
            "codex_bengalfox": {
              "limitId": "codex_bengalfox",
              "limitName": "GPT-5.3-Codex-Spark",
              "primary": {
                "usedPercent": \#(sparkUsed),
                "windowDurationMins": 10080,
                "resetsAt": 1786880818
              }
            }
          },
          "rateLimitResetCredits": {
            "availableCount": 0,
            "details": []
          }
        }
        """#
    }

    private func resetRateLimitsJSON() -> String {
        #"""
        {
          "rateLimitsByLimitId": {},
          "rateLimitResetCredits": {
            "availableCount": 4,
            "details": [
              { "id": "consumed-earliest", "status": "consumed", "grantedAt": 1, "expiresAt": 50 },
              { "id": "later", "status": "available", "grantedAt": 1, "expiresAt": 300 },
              { "id": "tie-later-grant", "status": "AVAILABLE", "grantedAt": 20, "expiresAt": 200 },
              { "id": "winner", "status": "available", "grantedAt": 10, "expiresAt": 200 }
            ]
          }
        }
        """#
    }

    private func decimal(_ value: String) -> Decimal {
        Decimal(string: value, locale: Locale(identifier: "en_US_POSIX")) ?? 0
    }
}
