import Foundation
import XCTest
@testable import UsageButlerProviders

final class OpenAIQuotaParserTests: XCTestCase {
    func testAccountReadPreservesOnlyRequiredAccountMetadata() throws {
        let response = try OpenAIAppServerDecoder.decodeAccountRead(from: data(#"""
        {
          "account": {
            "type": "chatgpt",
            "planType": "pro",
            "email": "intentionally-ignored@example.invalid"
          },
          "requiresOpenaiAuth": true,
          "futureField": { "ignored": true }
        }
        """#))

        let account = OpenAIQuotaProjector.projectAccount(response)
        XCTAssertEqual(account.accountType, "chatgpt")
        XCTAssertEqual(account.planType, "pro")
        XCTAssertTrue(account.requiresOpenAIAuth)
    }

    func testLoggedOutAccountDoesNotInventAccountMetadata() throws {
        let response = try OpenAIAppServerDecoder.decodeAccountRead(from: data(#"""
        {
          "account": null,
          "requiresOpenaiAuth": true
        }
        """#))

        let account = OpenAIQuotaProjector.projectAccount(response)
        XCTAssertNil(account.accountType)
        XCTAssertNil(account.planType)
        XCTAssertTrue(account.requiresOpenAIAuth)
    }

    func testProWithIndependentSparkPreservesRawWindowsAndSourceIdentity() throws {
        let projected = try projectRateLimits(#"""
        {
          "rateLimits": {
            "limitId": "codex",
            "primary": {
              "usedPercent": 99,
              "windowDurationMins": 300,
              "resetsAt": 1893456000
            },
            "planType": "pro"
          },
          "rateLimitsByLimitId": {
            "codex": {
              "limitId": "codex",
              "primary": {
                "usedPercent": 40,
                "windowDurationMins": 10080,
                "resetsAt": 1786846755
              },
              "secondary": null,
              "planType": "pro",
              "credits": {
                "hasCredits": true,
                "unlimited": false,
                "balance": "12.5"
              },
              "rateLimitReachedType": null
            },
            "codex_bengalfox": {
              "limitId": "codex_bengalfox",
              "limitName": "GPT-5.3-Codex-Spark",
              "primary": {
                "usedPercent": 1,
                "windowDurationMins": 10080,
                "resetsAt": 1786880818
              },
              "secondary": null,
              "planType": "pro",
              "futureBucketField": "ignored"
            }
          },
          "rateLimitResetCredits": {
            "availableCount": 1,
            "credits": [
              {
                "id": "sanitized-reset-1",
                "resetType": "full",
                "status": "available",
                "grantedAt": 1783965577,
                "expiresAt": 1786557577,
                "title": "Full reset",
                "description": "sanitized"
              }
            ]
          },
          "futureTopLevelField": true
        }
        """#)

        XCTAssertEqual(projected.source, .multiBucket)
        XCTAssertEqual(projected.buckets.count, 2)

        let codex = try XCTUnwrap(projected.buckets.first { $0.kind == .codex })
        XCTAssertEqual(codex.identity.dictionaryKey, "codex")
        XCTAssertEqual(codex.identity.limitID, "codex")
        XCTAssertEqual(codex.planType, "pro")
        XCTAssertEqual(codex.windows, [
            ParsedOpenAIRateLimitWindow(
                sourceSlot: .primary,
                usedPercent: 40,
                windowDurationMins: 10_080,
                resetsAt: 1_786_846_755
            )
        ])
        XCTAssertEqual(codex.credits?.hasCredits, true)
        XCTAssertEqual(codex.credits?.unlimited, false)
        XCTAssertEqual(codex.credits?.balance, .string("12.5"))

        let spark = try XCTUnwrap(projected.validIndependentSparkBucket)
        XCTAssertEqual(spark.identity.dictionaryKey, "codex_bengalfox")
        XCTAssertEqual(spark.identity.limitID, "codex_bengalfox")
        XCTAssertEqual(spark.identity.limitName, "GPT-5.3-Codex-Spark")
        XCTAssertEqual(spark.windows.first?.usedPercent, 1)
        XCTAssertEqual(spark.windows.first?.windowDurationMins, 10_080)
        XCTAssertEqual(spark.windows.first?.resetsAt, 1_786_880_818)

        let resetCredits = try XCTUnwrap(projected.resetCredits)
        XCTAssertEqual(resetCredits.availableCount, 1)
        guard case let .detail(selected) = resetCredits.display else {
            return XCTFail("Expected the available reset detail")
        }
        XCTAssertEqual(selected.sourceID, "sanitized-reset-1")
        XCTAssertEqual(selected.expiresAt, 1_786_557_577)
    }

    func testNonProWithoutSparkHasNoSparkBucket() throws {
        let projected = try projectRateLimits(singleBucketJSON(planType: "plus"))

        XCTAssertEqual(projected.buckets.map(\.planType), ["plus"])
        XCTAssertNil(projected.validIndependentSparkBucket)
    }

    func testPlanTypeDoesNotControlSparkPresence() throws {
        let proWithoutSpark = try projectRateLimits(singleBucketJSON(planType: "pro"))
        let nonProWithSpark = try projectRateLimits(#"""
        {
          "rateLimitsByLimitId": {
            "codex": {
              "limitId": "codex",
              "primary": { "usedPercent": 2, "windowDurationMins": 10080, "resetsAt": 2000 },
              "planType": "free"
            },
            "codex_bengalfox": {
              "limitId": "codex_bengalfox",
              "limitName": "GPT-5.3-Codex-Spark",
              "primary": { "usedPercent": 3, "windowDurationMins": 10080, "resetsAt": 3000 },
              "planType": "free"
            }
          }
        }
        """#)

        XCTAssertNil(proWithoutSpark.validIndependentSparkBucket)
        XCTAssertEqual(nonProWithSpark.validIndependentSparkBucket?.planType, "free")
    }

    func testMalformedBucketIsIsolatedAndCannotCreateSparkPresence() throws {
        let response = try OpenAIAppServerDecoder.decodeRateLimitsRead(from: data(#"""
        {
          "rateLimits": {
            "limitId": "codex_bengalfox",
            "limitName": "GPT-5.3-Codex-Spark",
            "primary": { "usedPercent": 1, "windowDurationMins": 10080, "resetsAt": 4000 }
          },
          "rateLimitsByLimitId": {
            "codex": {
              "limitId": "codex",
              "primary": { "usedPercent": 10, "windowDurationMins": 10080, "resetsAt": 5000 }
            },
            "codex_bengalfox": {
              "limitId": "codex_bengalfox",
              "limitName": "GPT-5.3-Codex-Spark",
              "primary": { "usedPercent": "not-a-number", "windowDurationMins": 10080 }
            }
          }
        }
        """#))
        let projected = try OpenAIQuotaProjector.projectRateLimits(response)

        XCTAssertEqual(projected.buckets.map(\.kind), [.codex])
        XCTAssertEqual(projected.diagnostics.invalidBucketSourceKeys, ["codex_bengalfox"])
        XCTAssertNil(projected.validIndependentSparkBucket)
    }

    func testMalformedPayloadReturnsTypedDecodeError() {
        XCTAssertThrowsError(
            try OpenAIAppServerDecoder.decodeRateLimitsRead(
                from: data(#"{"rateLimitsByLimitId": []}"#)
            )
        ) { error in
            XCTAssertEqual(error as? OpenAIAppServerDecodeError, .malformedRateLimitsRead)
        }
    }

    func testAvailableCountZeroIsHiddenEvenWhenDetailsExist() throws {
        let projected = try projectRateLimits(resetCreditsJSON(
            availableCount: 0,
            details: #"[{"id":"ignored","status":"available","expiresAt":100}]"#
        ))

        let summary = try XCTUnwrap(projected.resetCredits)
        XCTAssertEqual(summary.availableCount, 0)
        XCTAssertEqual(summary.details?.count, 1)
        XCTAssertEqual(summary.display, .hidden)
    }

    func testPositiveAvailableCountFallsBackToCountOnlyWithoutUsableDetails() throws {
        let projected = try projectRateLimits(resetCreditsJSON(
            availableCount: 2,
            details: #"[{"id":"used","status":"consumed","expiresAt":100}]"#
        ))

        let summary = try XCTUnwrap(projected.resetCredits)
        XCTAssertEqual(summary.availableCount, 2)
        XCTAssertEqual(summary.display, .countOnly)
    }

    func testMalformedResetDetailDoesNotHideAuthoritativeCount() throws {
        let projected = try projectRateLimits(resetCreditsJSON(
            availableCount: 3,
            details: #"[{"id":"malformed","status":"available","expiresAt":"not-a-timestamp"}]"#
        ))

        let summary = try XCTUnwrap(projected.resetCredits)
        XCTAssertEqual(summary.availableCount, 3)
        XCTAssertEqual(summary.details, [])
        XCTAssertEqual(summary.display, .countOnly)
        XCTAssertEqual(projected.diagnostics.invalidResetCreditDetailCount, 1)
    }

    func testMalformedResetSummaryIsLossyAndKeepsValidBuckets() throws {
        let response = try OpenAIAppServerDecoder.decodeRateLimitsRead(from: data(#"""
        {
          "rateLimitsByLimitId": {
            "codex": {
              "limitId": "codex",
              "primary": { "usedPercent": 20, "windowDurationMins": 10080 }
            }
          },
          "rateLimitResetCredits": { "details": [] }
        }
        """#))

        XCTAssertTrue(response.invalidRateLimitResetCredits)
        let projected = try OpenAIQuotaProjector.projectRateLimits(response)
        XCTAssertEqual(projected.buckets.map(\.identity.limitID), ["codex"])
        XCTAssertNil(projected.resetCredits)
    }

    func testExplicitZeroRemainsAuthoritativeWhenOptionalDetailsContainerIsMalformed() throws {
        let response = try OpenAIAppServerDecoder.decodeRateLimitsRead(from: data(#"""
        {
          "rateLimitsByLimitId": {},
          "rateLimitResetCredits": {
            "availableCount": 0,
            "details": { "opaque": true }
          }
        }
        """#))

        XCTAssertFalse(response.invalidRateLimitResetCredits)
        XCTAssertEqual(response.rateLimitResetCredits?.invalidDetailCount, 1)
        XCTAssertEqual(response.rateLimitResetCredits?.invalidDetailContainer, true)
        let projected = try OpenAIQuotaProjector.projectRateLimits(response)
        XCTAssertEqual(projected.resetCredits?.display, .hidden)
        XCTAssertEqual(projected.diagnostics.invalidResetCreditDetailCount, 1)
    }

    func testResetCreditsSelectEarliestAvailableExpiryWithGrantedAtTieBreak() throws {
        let projected = try projectRateLimits(resetCreditsJSON(
            availableCount: 4,
            details: #"""
            [
              {"id":"unavailable-earliest","status":"consumed","grantedAt":1,"expiresAt":50},
              {"id":"later-expiry","status":"available","grantedAt":1,"expiresAt":300},
              {"id":"same-expiry-later-grant","status":"AVAILABLE","grantedAt":20,"expiresAt":200},
              {"id":"winner","resetType":"full","status":"available","grantedAt":10,"expiresAt":200,"title":"Full reset"}
            ]
            """#
        ))

        let summary = try XCTUnwrap(projected.resetCredits)
        guard case let .detail(selected) = summary.display else {
            return XCTFail("Expected an expiring detail")
        }
        XCTAssertEqual(selected.sourceID, "winner")
        XCTAssertEqual(selected.grantedAt, 10)
        XCTAssertEqual(selected.expiresAt, 200)
        XCTAssertEqual(summary.details?.count, 4)
    }

    func testPresentEmptyMultiBucketIsAuthoritativeOverLegacyFallback() throws {
        let projected = try projectRateLimits(#"""
        {
          "rateLimits": {
            "limitId": "codex_bengalfox",
            "limitName": "GPT-5.3-Codex-Spark",
            "primary": { "usedPercent": 1, "windowDurationMins": 10080, "resetsAt": 9000 }
          },
          "rateLimitsByLimitId": {}
        }
        """#)

        XCTAssertEqual(projected.source, .multiBucket)
        XCTAssertTrue(projected.buckets.isEmpty)
        XCTAssertNil(projected.validIndependentSparkBucket)
    }

    func testUnknownLegalBucketIsPreservedAsProviderDefinedWithoutSparkPresence() throws {
        let projected = try projectRateLimits(#"""
        {
          "rateLimitsByLimitId": {
            "future_meter": {
              "limitName": "Future Meter",
              "primary": { "usedPercent": 25, "windowDurationMins": null, "resetsAt": null },
              "secondary": null,
              "futureField": { "ignored": true }
            }
          }
        }
        """#)

        let bucket = try XCTUnwrap(projected.buckets.first)
        XCTAssertEqual(bucket.identity.dictionaryKey, "future_meter")
        XCTAssertNil(bucket.identity.limitID)
        XCTAssertEqual(bucket.kind, .providerDefined)
        XCTAssertEqual(bucket.windows.first?.usedPercent, 25)
        XCTAssertNil(projected.validIndependentSparkBucket)
    }

    func testLegacyFallbackPreservesSecondaryButNeverCreatesIndependentSpark() throws {
        let projected = try projectRateLimits(#"""
        {
          "rateLimits": {
            "limitId": "codex_bengalfox",
            "limitName": "GPT-5.3-Codex-Spark",
            "primary": { "usedPercent": 12, "windowDurationMins": 300, "resetsAt": 1000 },
            "secondary": { "usedPercent": 34, "windowDurationMins": 10080, "resetsAt": 2000 },
            "planType": "pro",
            "rateLimitReachedType": "weekly"
          }
        }
        """#)

        XCTAssertEqual(projected.source, .legacyFallback)
        XCTAssertEqual(projected.buckets.first?.identity.dictionaryKey, nil)
        XCTAssertEqual(projected.buckets.first?.windows.map(\.sourceSlot), [.primary, .secondary])
        XCTAssertEqual(projected.buckets.first?.rateLimitReachedType, "weekly")
        XCTAssertNil(projected.validIndependentSparkBucket)
    }

    private func projectRateLimits(_ json: String) throws -> ParsedOpenAIRateLimits {
        let response = try OpenAIAppServerDecoder.decodeRateLimitsRead(from: data(json))
        return try OpenAIQuotaProjector.projectRateLimits(response)
    }

    private func singleBucketJSON(planType: String) -> String {
        #"""
        {
          "rateLimitsByLimitId": {
            "codex": {
              "limitId": "codex",
              "primary": { "usedPercent": 10, "windowDurationMins": 10080, "resetsAt": 6000 },
              "secondary": null,
              "planType": "\#(planType)"
            }
          }
        }
        """#
    }

    private func resetCreditsJSON(availableCount: Int, details: String) -> String {
        #"""
        {
          "rateLimitsByLimitId": {},
          "rateLimitResetCredits": {
            "availableCount": \#(availableCount),
            "details": \#(details)
          }
        }
        """#
    }

    private func data(_ json: String) -> Data {
        Data(json.utf8)
    }
}
