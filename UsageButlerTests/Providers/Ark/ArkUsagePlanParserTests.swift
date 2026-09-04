import Foundation
import UsageButlerCore
import UsageButlerDomain
import XCTest
@testable import UsageButlerProviders

final class ArkUsagePlanParserTests: XCTestCase {
    private let fixedNow = Date(timeIntervalSince1970: 1_786_300_000)

    func testPlanMetadataParserKeepsOnlyUniqueSupportedPersonalTiers() throws {
        let snapshot = try ArkPlanMetadataParser.parse(
            Data(
                """
                {
                  "plans": [
                    { "key": "agent-plan", "scope": "personal", "tier": "Medium" },
                    { "key": "coding-plan", "scope": "personal", "tier": "PRO" },
                    { "key": "coding-plan", "scope": "team", "tier": "lite" },
                    { "key": "future-plan", "scope": "personal", "tier": "pro" },
                    { "key": "coding-plan", "scope": "personal" }
                  ]
                }
                """.utf8
            ),
            fetchedAt: fixedNow
        )

        XCTAssertEqual(snapshot.tiers[.agentPlan]?.tier, "medium")
        XCTAssertEqual(snapshot.tiers[.codingPlan]?.tier, "pro")
        XCTAssertEqual(snapshot.tiers[.codingPlan]?.fetchedAt, fixedNow)
        XCTAssertEqual(snapshot.tiers.count, 2)
    }

    func testPlanMetadataParserFailsClosedForDuplicatePersonalTier() throws {
        let snapshot = try ArkPlanMetadataParser.parse(
            Data(
                """
                {
                  "plans": [
                    { "key": "coding-plan", "scope": "personal", "tier": "pro" },
                    { "key": "coding-plan", "scope": "personal", "tier": "lite" }
                  ]
                }
                """.utf8
            ),
            fetchedAt: fixedNow
        )

        XCTAssertNil(snapshot.tiers[.codingPlan])
    }

    func testPlanMetadataOnlyFillsMissingUsageTier() throws {
        let metadata: [ParsedArkProductID: ParsedArkPlanTierObservation] = [
            .agentPlan: ParsedArkPlanTierObservation(
                productID: .agentPlan,
                tier: "pro",
                fetchedAt: fixedNow.addingTimeInterval(10)
            ),
            .codingPlan: ParsedArkPlanTierObservation(
                productID: .codingPlan,
                tier: "pro",
                fetchedAt: fixedNow.addingTimeInterval(10)
            )
        ]
        let data = try ArkDomainMapper.map(
            try parse(receiptJSON),
            source: sourceIdentity,
            planMetadata: metadata
        )
        let agent = try XCTUnwrap(data.products.first { $0.sourceProductID == "agent-plan" })
        let coding = try XCTUnwrap(data.products.first { $0.sourceProductID == "coding-plan" })

        XCTAssertEqual(agent.planLevel?.value, "medium")
        XCTAssertEqual(agent.planLevel?.origin, .reported(sourceField: "items[].tier"))
        XCTAssertEqual(agent.planLevel?.fetchedAt, fixedNow)
        XCTAssertEqual(coding.planLevel?.value, "pro")
        XCTAssertEqual(
            coding.planLevel?.origin,
            .reported(sourceField: "plans.get.plans[].tier")
        )
        XCTAssertEqual(coding.planLevel?.fetchedAt, fixedNow.addingTimeInterval(10))
    }

    func testReceiptPreservesIndependentProductsTierAndOptionalAbsoluteValues() throws {
        let snapshot = try parse(receiptJSON)

        XCTAssertEqual(snapshot.droppedItemCount, 0)
        XCTAssertEqual(snapshot.effectiveCompleteness, .completeSuccess)
        XCTAssertEqual(snapshot.agentPlan.presence, .entitled)
        XCTAssertEqual(snapshot.codingPlan.presence, .entitled)

        let agent = try XCTUnwrap(snapshot.agentPlan.uniqueItem)
        XCTAssertEqual(agent.edition, "personal")
        XCTAssertEqual(agent.tier, "medium")
        XCTAssertEqual(agent.periods.map(\.label), ["5h", "weekly", "monthly"])
        XCTAssertEqual(agent.periods[0].used, decimal("404.039"))
        XCTAssertEqual(agent.periods[0].total, 10_000)
        XCTAssertEqual(agent.periods[0].percent, decimal("4.04039"))
        guard case let .parsed(rawValue, _) = agent.periods[0].resetAt else {
            return XCTFail("Agent reset_at should parse without losing its source text")
        }
        XCTAssertEqual(rawValue, "2026-08-10T03:44:02+08:00")

        let coding = try XCTUnwrap(snapshot.codingPlan.uniqueItem)
        XCTAssertNil(coding.tier)
        XCTAssertEqual(coding.periods.map(\.label), ["session", "weekly", "monthly"])
        XCTAssertNil(coding.periods[0].used)
        XCTAssertNil(coding.periods[0].total)
        XCTAssertEqual(coding.periods[0].percent, 0)
        XCTAssertEqual(coding.periods[0].resetAt, .absent)
        XCTAssertEqual(coding.updatedAt, .unixSeconds(1_786_286_695))
    }

    func testProjectionKeepsUsedDirectionLabelsAndProductSpecificTimeEvents() throws {
        let projections = ArkUsageProjector.project(try parse(receiptJSON))
        let agent = try XCTUnwrap(projections.first { $0.productID == .agentPlan })
        let coding = try XCTUnwrap(projections.first { $0.productID == .codingPlan })

        XCTAssertEqual(agent.tier, "medium")
        XCTAssertEqual(agent.metrics.map(\.sourceLabel), ["5h", "weekly", "monthly"])
        XCTAssertEqual(agent.metrics.map(\.window), [.rollingHours(5), .weekly, .monthly])
        XCTAssertTrue(agent.metrics.allSatisfy { $0.event?.kind == .reset })

        guard case let .used(agentValue) = agent.metrics[0].value else {
            return XCTFail("Agent metric should retain used/total/percent")
        }
        XCTAssertEqual(agentValue.direction, .used)
        XCTAssertEqual(agentValue.used, decimal("404.039"))
        XCTAssertEqual(agentValue.total, 10_000)
        XCTAssertEqual(agentValue.percent, decimal("4.04039"))

        XCTAssertNil(coding.tier)
        XCTAssertEqual(coding.metrics.map(\.sourceLabel), ["session", "weekly", "monthly"])
        XCTAssertEqual(coding.metrics.map(\.window), [.session, .weekly, .monthly])
        XCTAssertNil(coding.metrics[0].event)
        XCTAssertEqual(coding.metrics[1].event?.kind, .refresh)
        XCTAssertEqual(coding.metrics[2].event?.kind, .refresh)

        guard case let .used(sessionValue) = coding.metrics[0].value else {
            return XCTFail("Coding session should retain percent-only omission")
        }
        XCTAssertEqual(sessionValue.percent, 0)
        XCTAssertNil(sessionValue.used)
        XCTAssertNil(sessionValue.total)
    }

    func testResetAtAcceptsFractionalAndNonfractionalRFC3339() throws {
        let snapshot = try parse(
            """
            {
              "items": [
                {
                  "product": "agent-plan",
                  "subscribed": true,
                  "periods": [
                    {
                      "label": "5h",
                      "percent": 1,
                      "reset_at": "2026-08-12T00:00:00.123456+08:00"
                    }
                  ]
                },
                {
                  "product": "coding-plan",
                  "subscribed": true,
                  "periods": [
                    {
                      "label": "weekly",
                      "percent": 2,
                      "reset_at": "2026-08-12T00:00:00+08:00"
                    }
                  ]
                }
              ]
            }
            """
        )

        XCTAssertEqual(snapshot.effectiveCompleteness, .completeSuccess)
        guard case let .parsed(fractionalRaw, fractionalDate) = try XCTUnwrap(
            snapshot.agentPlan.uniqueItem?.periods.first
        ).resetAt else {
            return XCTFail("Fractional RFC3339 reset_at must parse")
        }
        guard case let .parsed(nonfractionalRaw, nonfractionalDate) = try XCTUnwrap(
            snapshot.codingPlan.uniqueItem?.periods.first
        ).resetAt else {
            return XCTFail("Nonfractional RFC3339 reset_at must keep parsing")
        }
        XCTAssertEqual(fractionalRaw, "2026-08-12T00:00:00.123456+08:00")
        XCTAssertEqual(nonfractionalRaw, "2026-08-12T00:00:00+08:00")
        XCTAssertEqual(
            fractionalDate.timeIntervalSince(nonfractionalDate),
            0.123,
            accuracy: 0.000_1
        )
    }

    func testLiveShapeTotalWithoutUsedIsCompleteAuthoritativeAndPercentOnly() async throws {
        let snapshot = try parse(liveShapeTotalWithoutUsedJSON)

        XCTAssertEqual(snapshot.effectiveCompleteness, .completeSuccess)
        XCTAssertEqual(snapshot.agentPlan.presence, .entitled)
        XCTAssertEqual(snapshot.codingPlan.presence, .entitled)
        let agent = try XCTUnwrap(snapshot.agentPlan.uniqueItem)
        let fiveHour = try XCTUnwrap(agent.periods.first { $0.label == "5h" })
        XCTAssertNil(fiveHour.used)
        XCTAssertNotNil(fiveHour.total)
        XCTAssertNil(fiveHour.contractIssue)

        let parsedProjection = ArkUsageProjector.project(snapshot.agentPlan)
        let projectedFiveHour = try XCTUnwrap(
            parsedProjection.metrics.first { $0.sourceLabel == "5h" }
        )
        guard case let .used(projectedValue) = projectedFiveHour.value else {
            return XCTFail("The live-shape period must retain its authoritative percent")
        }
        XCTAssertNil(projectedValue.used)
        XCTAssertNil(projectedValue.total, "A lone total must not reach presentation")

        let data = try ArkDomainMapper.map(snapshot, source: sourceIdentity)
        XCTAssertEqual(ArkDomainMapper.authoritativeProducts(from: data).count, 2)
        XCTAssertTrue(ArkDomainMapper.isCompleteKnownProductRead(snapshot, data: data))
        let agentProduct = try XCTUnwrap(
            data.products.first { $0.sourceProductID == "agent-plan" }
        )
        let fiveHourMetric = try XCTUnwrap(agentProduct.metrics.first {
            $0.id.sourceIdentity.sourceBucketID == "5h"
        })
        guard case let .percent(percent) = fiveHourMetric.value else {
            return XCTFail("A lone total must not manufacture an absolute used/total value")
        }
        XCTAssertEqual(percent.sourceDirection, .used)
        XCTAssertNil(fiveHourMetric.state.failure)

        let process = ArkFakeChildProcessClient(results: [
            .success(output(liveShapeTotalWithoutUsedJSON))
        ])
        let now = fixedNow
        let adapter = ArkProviderAdapter(
            processClient: process,
            executableURL: URL(fileURLWithPath: "/opt/usage-butler/bin/arkcli"),
            now: { now }
        )
        guard case .success = await adapter.read(scope: .provider) else {
            return XCTFail("The observed total-without-used shape must be a complete read")
        }
        let diagnostic = await adapter.diagnosticSnapshot()
        XCTAssertEqual(diagnostic.safeFields["schema"], "ark-usage-plan-json-v1:valid")
        XCTAssertEqual(diagnostic.safeFields["errorClass"], "none")
    }

    func testUnsupportedTeamAndUnknownRowsDoNotPoisonSupportedCompleteness() throws {
        let snapshot = try parse(supportedAndUnsupportedJSON)

        XCTAssertEqual(snapshot.effectiveCompleteness, .completeSuccess)
        XCTAssertEqual(snapshot.agentPlan.presence, .entitled)
        XCTAssertEqual(snapshot.codingPlan.presence, .entitled)
        XCTAssertEqual(snapshot.envelopeDiagnostics.supportedItemCount, 2)
        XCTAssertEqual(snapshot.envelopeDiagnostics.unsupportedItemCount, 3)
        XCTAssertEqual(snapshot.envelopeDiagnostics.droppedSupportedItemCount, 0)
        XCTAssertEqual(snapshot.envelopeDiagnostics.droppedUnsupportedItemCount, 0)
        XCTAssertEqual(snapshot.envelopeDiagnostics.droppedUnclassifiedItemCount, 0)
    }

    func testMalformedOptionalMetadataDoesNotDiscardValidSupportedQuota() throws {
        let snapshot = try parse(
            """
            {
              "items": [
                {
                  "product": "agent-plan",
                  "edition": ["personal"],
                  "tier": 42,
                  "subscribed": true,
                  "seat_id": { "opaque": true },
                  "updated_at": { "opaque": true },
                  "updated_at_iso8601": 123,
                  "periods": [
                    { "label": "5h", "percent": 4, "reset_at": null }
                  ]
                },
                {
                  "product": "coding-plan",
                  "subscribed": true,
                  "periods": [
                    { "label": "weekly", "percent": 5, "reset_at": null }
                  ]
                }
              ]
            }
            """
        )

        XCTAssertEqual(snapshot.effectiveCompleteness, .completeSuccess)
        let agent = try XCTUnwrap(snapshot.agentPlan.uniqueItem)
        XCTAssertNil(agent.edition)
        XCTAssertNil(agent.tier)
        XCTAssertNil(agent.seatID)
        XCTAssertNil(agent.updatedAt)
        XCTAssertNil(agent.updatedAtISO8601)
        XCTAssertEqual(agent.periods.count, 1)
        XCTAssertEqual(snapshot.envelopeDiagnostics.supportedItemCount, 2)
        XCTAssertEqual(snapshot.envelopeDiagnostics.droppedSupportedItemCount, 0)

        let data = try ArkDomainMapper.map(snapshot, source: sourceIdentity)
        let agentProduct = try XCTUnwrap(
            data.products.first { $0.sourceProductID == "agent-plan" }
        )
        XCTAssertNil(agentProduct.planLevel)
        XCTAssertEqual(agentProduct.metrics.count, 1)
        XCTAssertNil(agentProduct.state.failure)
    }

    func testLoneUsedAndLoneTotalRemainCompletePercentOnlyEnrichment() throws {
        let snapshot = try parse(
            """
            {
              "items": [
                {
                  "product": "agent-plan",
                  "subscribed": true,
                  "periods": [
                    { "label": "5h", "used": 1, "percent": 10 },
                    { "label": "weekly", "total": 20, "percent": 25 }
                  ]
                },
                { "product": "coding-plan", "subscribed": false, "periods": [] }
              ]
            }
            """
        )

        XCTAssertEqual(snapshot.effectiveCompleteness, .completeSuccess)
        let item = try XCTUnwrap(snapshot.agentPlan.uniqueItem)
        XCTAssertEqual(item.periods.count, 2)
        XCTAssertTrue(item.periods.allSatisfy { $0.contractIssue == nil })
        XCTAssertNotNil(item.periods.first { $0.label == "5h" }?.used)
        XCTAssertNil(item.periods.first { $0.label == "5h" }?.total)
        XCTAssertNil(item.periods.first { $0.label == "weekly" }?.used)
        XCTAssertNotNil(item.periods.first { $0.label == "weekly" }?.total)

        let parsedProjection = ArkUsageProjector.project(snapshot.agentPlan)
        XCTAssertTrue(parsedProjection.metrics.allSatisfy { metric in
            if case let .used(value) = metric.value {
                return value.used == nil && value.total == nil
            }
            return false
        })

        let data = try ArkDomainMapper.map(snapshot, source: sourceIdentity)
        let agent = try XCTUnwrap(data.products.first { $0.sourceProductID == "agent-plan" })
        XCTAssertEqual(agent.metrics.count, 2)
        XCTAssertTrue(agent.metrics.allSatisfy { metric in
            if case let .percent(percent) = metric.value {
                return percent.sourceDirection == .used && metric.state.failure == nil
            }
            return false
        })
    }

    func testInvalidOptionalAbsoluteFieldsRemainMetricLocalPartialAndIsolated() throws {
        let snapshot = try parse(
            """
            {
              "items": [
                {
                  "product": "agent-plan",
                  "subscribed": true,
                  "periods": [
                    { "label": "5h", "total": "opaque", "percent": 10 },
                    { "label": "weekly", "used": -1, "percent": 20 },
                    { "label": "monthly", "total": -1, "percent": 30 }
                  ]
                },
                {
                  "product": "coding-plan",
                  "subscribed": true,
                  "periods": [
                    { "label": "session", "percent": 4 }
                  ]
                }
              ]
            }
            """
        )

        XCTAssertEqual(snapshot.effectiveCompleteness, .partial)
        let item = try XCTUnwrap(snapshot.agentPlan.uniqueItem)
        XCTAssertEqual(item.periods[0].contractIssue, .invalidFieldType("total"))
        XCTAssertEqual(item.periods[1].contractIssue, .invalidSourceValue("used"))
        XCTAssertEqual(item.periods[2].contractIssue, .invalidSourceValue("total"))

        let data = try ArkDomainMapper.map(snapshot, source: sourceIdentity)
        let agent = try XCTUnwrap(data.products.first { $0.sourceProductID == "agent-plan" })
        let coding = try XCTUnwrap(data.products.first { $0.sourceProductID == "coding-plan" })
        XCTAssertNil(agent.state.failure, "Absolute-field failures stay metric-local")
        XCTAssertTrue(agent.metrics.allSatisfy { metric in
            if case .unavailable = metric.value {
                return metric.state.failure?.code == .schemaMismatch
            }
            return false
        })
        XCTAssertNil(coding.state.failure)
        XCTAssertEqual(coding.metrics.count, 1)
        guard case .percent = try XCTUnwrap(coding.metrics.first).value else {
            return XCTFail("A malformed Agent metric must not poison its Coding sibling")
        }
        XCTAssertFalse(ArkDomainMapper.isCompleteKnownProductRead(snapshot, data: data))
    }

    func testErrorPlusSubscribedFalseRemainsUnknownAndDoesNotCoverSibling() throws {
        let snapshot = try parse(
            """
            {
              "items": [
                {
                  "product": "agent-plan",
                  "subscribed": false,
                  "periods": [],
                  "error": { "code": "unauthorized" }
                },
                {
                  "product": "coding-plan",
                  "subscribed": true,
                  "periods": [
                    { "label": "session", "percent": 7, "reset_at": null }
                  ],
                  "error": null
                }
              ]
            }
            """
        )

        XCTAssertEqual(snapshot.agentPlan.presence, .unknown(.itemError))
        XCTAssertEqual(snapshot.codingPlan.presence, .entitled)
        XCTAssertEqual(ArkUsageProjector.project(snapshot.agentPlan).metrics, [])
        XCTAssertEqual(ArkUsageProjector.project(snapshot.codingPlan).metrics.count, 1)
    }

    func testNotEntitledRequiresAuthoritativeCompleteErrorFreeDiscovery() throws {
        let json =
            """
            {
              "items": [
                { "product": "agent-plan", "subscribed": false, "periods": [], "error": null }
              ]
            }
            """

        let authoritative = try parse(json)
        guard case let .notEntitled(evidence) = authoritative.agentPlan.presence else {
            return XCTFail("A complete authoritative subscribed:false may be notEntitled")
        }
        XCTAssertEqual(evidence.authority, "ark.usage-plan.subscribed")
        XCTAssertEqual(evidence.observedAt, fixedNow)

        let partial = try parse(json, completeness: .partial)
        XCTAssertEqual(partial.agentPlan.presence, .unknown(.incompleteDiscovery))

        let nonAuthoritative = try parse(json, authoritativeDiscovery: false)
        XCTAssertEqual(nonAuthoritative.agentPlan.presence, .unknown(.incompleteDiscovery))
    }

    func testEmptyItemsNeverBecomeNotEntitled() throws {
        let snapshot = try parse(#"{ "items": [] }"#)

        XCTAssertEqual(snapshot.agentPlan.presence, .unknown(.missingFromResponse))
        XCTAssertEqual(snapshot.codingPlan.presence, .unknown(.missingFromResponse))
        XCTAssertTrue(ArkUsageProjector.project(snapshot).allSatisfy(\.metrics.isEmpty))
    }

    func testMalformedItemDoesNotEraseSuccessfulSiblingOrCreateAbsenceEvidence() throws {
        let snapshot = try parse(
            """
            {
              "items": [
                { "subscribed": false, "periods": [] },
                {
                  "product": "coding-plan",
                  "subscribed": true,
                  "periods": [
                    { "label": "weekly", "percent": 12, "reset_at": null }
                  ]
                }
              ]
            }
            """
        )

        XCTAssertEqual(snapshot.droppedItemCount, 1)
        XCTAssertEqual(snapshot.envelopeDiagnostics.droppedSupportedItemCount, 0)
        XCTAssertEqual(snapshot.envelopeDiagnostics.droppedUnsupportedItemCount, 0)
        XCTAssertEqual(snapshot.envelopeDiagnostics.droppedUnclassifiedItemCount, 1)
        XCTAssertEqual(snapshot.effectiveCompleteness, .partial)
        XCTAssertEqual(snapshot.agentPlan.presence, .unknown(.missingFromResponse))
        XCTAssertEqual(snapshot.codingPlan.presence, .entitled)
    }

    func testMissingAndNullPeriodsArePartialUnknownQuotaNotAuthoritativeEmpty() throws {
        let snapshot = try parse(
            """
            {
              "items": [
                { "product": "agent-plan", "subscribed": true },
                { "product": "coding-plan", "subscribed": true, "periods": null }
              ]
            }
            """
        )

        XCTAssertEqual(snapshot.effectiveCompleteness, .partial)
        XCTAssertEqual(snapshot.agentPlan.uniqueItem?.periodsFieldState, .missing)
        XCTAssertEqual(snapshot.codingPlan.uniqueItem?.periodsFieldState, .null)

        let data = try ArkDomainMapper.map(snapshot, source: sourceIdentity)
        let agent = try XCTUnwrap(data.products.first { $0.sourceProductID == "agent-plan" })
        let coding = try XCTUnwrap(data.products.first { $0.sourceProductID == "coding-plan" })
        XCTAssertEqual(agent.state.failure?.diagnosticCode, "ark.mapper.periods_missing")
        XCTAssertEqual(coding.state.failure?.diagnosticCode, "ark.mapper.periods_null")
        XCTAssertEqual(agent.state.freshness, .unknown)
        XCTAssertEqual(coding.state.freshness, .unknown)
        XCTAssertTrue(agent.metrics.isEmpty)
        XCTAssertTrue(coding.metrics.isEmpty)
    }

    func testMalformedPeriodOnlyMakesThatMetricUnavailableAndKeepsValidSibling() throws {
        let snapshot = try parse(
            """
            {
              "items": [
                {
                  "product": "agent-plan",
                  "subscribed": true,
                  "periods": [
                    { "label": "5h", "percent": "opaque", "reset_at": null },
                    { "label": "weekly", "percent": 25, "reset_at": null }
                  ]
                },
                { "product": "coding-plan", "subscribed": false, "periods": [] }
              ]
            }
            """
        )

        XCTAssertEqual(snapshot.effectiveCompleteness, .partial)
        let item = try XCTUnwrap(snapshot.agentPlan.uniqueItem)
        XCTAssertEqual(item.droppedPeriodCount, 0)
        XCTAssertEqual(item.periods.count, 2)
        XCTAssertEqual(item.periods[0].contractIssue, .invalidFieldType("percent"))

        let data = try ArkDomainMapper.map(snapshot, source: sourceIdentity)
        let agent = try XCTUnwrap(data.products.first { $0.sourceProductID == "agent-plan" })
        XCTAssertNil(agent.state.failure)
        XCTAssertEqual(agent.metrics.count, 2)

        let invalid = try XCTUnwrap(agent.metrics.first {
            $0.id.sourceIdentity.sourceBucketID == "5h"
        })
        guard case .unavailable = invalid.value else {
            return XCTFail("Only the malformed period should be unavailable")
        }
        XCTAssertEqual(invalid.state.failure?.code, .schemaMismatch)

        let valid = try XCTUnwrap(agent.metrics.first {
            $0.id.sourceIdentity.sourceBucketID == "weekly"
        })
        guard case let .percent(percent) = valid.value else {
            return XCTFail("The valid sibling must remain usable")
        }
        XCTAssertEqual(percent.sourceValue, 25)
        XCTAssertNil(valid.state.failure)
    }

    func testCodingOptionalAbsoluteValuesArePreservedWhenSupplied() throws {
        let snapshot = try parse(
            """
            {
              "items": [
                {
                  "product": "coding-plan",
                  "tier": "pro",
                  "subscribed": true,
                  "periods": [
                    {
                      "label": "weekly",
                      "used": 12,
                      "total": 80,
                      "percent": 15,
                      "reset_at": "2026-08-12T00:00:00+08:00"
                    }
                  ]
                }
              ]
            }
            """
        )

        let coding = ArkUsageProjector.project(snapshot.codingPlan)
        XCTAssertEqual(coding.tier, "pro")
        guard case let .used(value) = try XCTUnwrap(coding.metrics.first).value else {
            return XCTFail("Expected a used quota value")
        }
        XCTAssertEqual(value.used, 12)
        XCTAssertEqual(value.total, 80)
        XCTAssertEqual(value.percent, 15)
        XCTAssertEqual(coding.metrics.first?.event?.kind, .refresh)
    }

    func testMissingTopLevelItemsIsTypedFailureNotPresence() {
        XCTAssertThrowsError(try parse(#"{ "viewer": {} }"#)) { error in
            XCTAssertEqual(
                error as? ParsedArkParsingFailure,
                ParsedArkParsingFailure(
                    code: .missingRequiredField,
                    codingPath: "$.items"
                )
            )
        }
    }

    func testDomainMapperPreservesIndependentPresenceUsedValuesAndTimeKinds() throws {
        let data = try ArkDomainMapper.map(try parse(receiptJSON), source: sourceIdentity)
        let agent = try XCTUnwrap(data.products.first { $0.sourceProductID == "agent-plan" })
        let coding = try XCTUnwrap(data.products.first { $0.sourceProductID == "coding-plan" })
        guard case .entitled = agent.state.presence,
              case .entitled = coding.state.presence else {
            return XCTFail("Both successful products need independent entitled evidence")
        }
        XCTAssertEqual(agent.planLevel?.value, "medium")
        XCTAssertNil(coding.planLevel)

        let agentFiveHour = try XCTUnwrap(agent.metrics.first {
            $0.id.sourceIdentity.sourceBucketID == "5h"
        })
        guard case let .usedTotal(amount) = agentFiveHour.value else {
            return XCTFail("Agent must preserve AFP and reported used percent")
        }
        XCTAssertEqual(amount.used, decimal("404.039"))
        XCTAssertEqual(amount.total, 10_000)
        XCTAssertEqual(amount.unit, "AFP")
        XCTAssertEqual(amount.sourcePercent?.sourceValue, decimal("4.04039"))
        XCTAssertEqual(amount.sourcePercent?.sourceDirection, .used)
        XCTAssertEqual(agentFiveHour.window?.timeEvent?.kind, .reset)

        let codingSession = try XCTUnwrap(coding.metrics.first {
            $0.id.sourceIdentity.sourceBucketID == "session"
        })
        guard case let .percent(sessionPercent) = codingSession.value else {
            return XCTFail("Coding omission must remain percent-only")
        }
        XCTAssertEqual(sessionPercent.sourceValue, 0)
        XCTAssertEqual(sessionPercent.sourceDirection, .used)
        XCTAssertNil(codingSession.window?.timeEvent)
        let codingWeekly = try XCTUnwrap(coding.metrics.first {
            $0.id.sourceIdentity.sourceBucketID == "weekly"
        })
        XCTAssertEqual(codingWeekly.window?.timeEvent?.kind, .refresh)
        XCTAssertEqual(
            ArkDomainMapper.presentationRule(for: coding.id).timeEventKind,
            .refresh
        )
    }

    func testDomainMapperKeepsErroringProductUnknownWithoutCoveringSibling() throws {
        let snapshot = try parse(
            """
            {
              "items": [
                {
                  "product": "agent-plan",
                  "subscribed": false,
                  "periods": [],
                  "error": { "code": "redacted" }
                },
                {
                  "product": "coding-plan",
                  "subscribed": true,
                  "periods": [
                    { "label": "session", "percent": 7, "reset_at": null }
                  ],
                  "error": null
                }
              ]
            }
            """
        )
        let data = try ArkDomainMapper.map(snapshot, source: sourceIdentity)
        let agent = try XCTUnwrap(data.products.first { $0.sourceProductID == "agent-plan" })
        let coding = try XCTUnwrap(data.products.first { $0.sourceProductID == "coding-plan" })

        XCTAssertEqual(agent.state.presence, .unknown)
        XCTAssertEqual(agent.state.failure?.code, .serviceUnavailable)
        XCTAssertTrue(agent.metrics.isEmpty)
        guard case .entitled = coding.state.presence else {
            return XCTFail("The successful sibling remains independently entitled")
        }
        XCTAssertEqual(coding.metrics.count, 1)
    }

    func testOneShotAdapterUsesUsagePlanAndOfficialSSOContractsWithInjectedFake() async throws {
        let opaqueLoginOutput = "LOGIN FAILED user@example.invalid /Users/private"
        let process = ArkFakeChildProcessClient(results: [
            .success(output(receiptJSON)),
            .success(
                ChildProcessOutput(
                    termination: .exited(code: 0),
                    standardOutput: Data(opaqueLoginOutput.utf8),
                    redactedStandardError: Data("fatal-looking text".utf8)
                )
            )
        ])
        let executableURL = URL(fileURLWithPath: "/opt/usage-butler/bin/arkcli")
        let environment = ["LANG": "en_US.UTF-8", "HOME": "/safe-home"]
        let now = fixedNow
        let adapter = ArkProviderAdapter(
            processClient: process,
            executableURL: executableURL,
            environment: environment,
            now: { now }
        )

        let result = await adapter.read(scope: .provider)
        guard case let .success(data) = result else {
            return XCTFail("Expected a complete fake Ark read")
        }
        XCTAssertEqual(data.products.count, 2)
        XCTAssertEqual(data.source.cliVersion, "runtime-unverified")
        XCTAssertFalse(
            data.products.flatMap(\.metrics).isEmpty,
            "An unverified CLI version must not block schema-valid Ark quota parsing"
        )
        let requests = await process.capturedRequests()
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests[0].executableURL, executableURL)
        XCTAssertEqual(requests[0].arguments, ["usage", "plan", "--format", "json"])
        XCTAssertEqual(requests[0].environment, environment)
        XCTAssertNil(requests[0].standardInput)
        XCTAssertEqual(requests[0].limits, ArkProviderAdapter.defaultLimits)

        let login = await adapter.login(method: .sso)
        XCTAssertEqual(login, .success, "Only exit status, never output text, decides success")
        let requestsAfterLogin = await process.capturedRequests()
        XCTAssertEqual(requestsAfterLogin.count, 2)
        XCTAssertEqual(requestsAfterLogin[1].executableURL, executableURL)
        XCTAssertEqual(
            requestsAfterLogin[1].arguments,
            ["auth", "login", "volc-sso"]
        )
        XCTAssertEqual(requestsAfterLogin[1].environment, environment)
        XCTAssertNil(requestsAfterLogin[1].standardInput)
        XCTAssertEqual(
            requestsAfterLogin[1].limits,
            ChildProcessLimits(
                timeout: .seconds(330),
                standardOutputByteLimit: 65_536,
                standardErrorByteLimit: 65_536,
                lineLimit: 1_000
            )
        )
        XCTAssertEqual(
            requestsAfterLogin[1].nonZeroExitPolicy,
            .returnBoundedOutput
        )
        XCTAssertEqual(adapter.capabilities.loginMethod, .sso)
        let diagnostic = await adapter.diagnosticSnapshot()
        XCTAssertEqual(diagnostic.safeFields["cliVersion"], "runtime-unverified")
        XCTAssertFalse(diagnostic.safeFields.values.joined().contains(opaqueLoginOutput))
        XCTAssertFalse(diagnostic.diagnosticCode.contains(opaqueLoginOutput))
    }

    func testPlanMetadataReaderUsesReadOnlyPlansGetContract() async throws {
        let now = fixedNow
        let process = ArkFakeChildProcessClient(results: [
            .success(output(
                #"{"plans":[{"key":"coding-plan","scope":"personal","tier":"pro"}]}"#
            ))
        ])
        let executableURL = URL(fileURLWithPath: "/opt/usage-butler/bin/arkcli")
        let environment = ["LANG": "en_US.UTF-8"]
        let reader = ArkPlanMetadataReader(
            processClient: process,
            executableURL: executableURL,
            environment: environment,
            now: { now }
        )

        guard case let .success(snapshot) = await reader.readPlanMetadata() else {
            return XCTFail("Expected a parsed personal Coding tier")
        }
        XCTAssertEqual(snapshot.tiers[.codingPlan]?.tier, "pro")
        let requests = await process.capturedRequests()
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests[0].executableURL, executableURL)
        XCTAssertEqual(requests[0].arguments, ["plans", "get", "--format", "json"])
        XCTAssertEqual(requests[0].environment, environment)
        XCTAssertNil(requests[0].standardInput)
        XCTAssertEqual(requests[0].limits, ArkPlanMetadataReader.defaultLimits)
    }

    func testPlanMetadataFailureNeverBlocksAuthoritativeUsageQuota() async throws {
        let now = fixedNow
        let usageProcess = ArkFakeChildProcessClient(results: [
            .success(output(receiptJSON))
        ])
        let metadataReader = ArkScriptedPlanMetadataReader(results: [
            .failure(metadataFailure)
        ])
        let adapter = ArkProviderAdapter(
            processClient: usageProcess,
            planMetadataReader: metadataReader,
            executableURL: URL(fileURLWithPath: "/opt/usage-butler/bin/arkcli"),
            now: { now }
        )

        guard case let .success(data) = await adapter.read(scope: .provider) else {
            return XCTFail("Tier enrichment failure must not change usage quota success")
        }
        XCTAssertEqual(data.products.count, 2)
        XCTAssertFalse(data.products.flatMap(\.metrics).isEmpty)
        XCTAssertNil(
            data.products.first { $0.sourceProductID == "coding-plan" }?.planLevel
        )
    }

    func testPlanMetadataCachesLastSuccessfulPersonalTierAcrossLaterFailure() async throws {
        let now = fixedNow
        let usageProcess = ArkFakeChildProcessClient(results: [
            .success(output(receiptJSON)),
            .success(output(receiptJSON))
        ])
        let metadataReader = ArkScriptedPlanMetadataReader(results: [
            .success(
                ParsedArkPlanMetadataSnapshot(tiers: [
                    .codingPlan: ParsedArkPlanTierObservation(
                        productID: .codingPlan,
                        tier: "pro",
                        fetchedAt: fixedNow
                    )
                ])
            ),
            .failure(metadataFailure)
        ])
        let adapter = ArkProviderAdapter(
            processClient: usageProcess,
            planMetadataReader: metadataReader,
            executableURL: URL(fileURLWithPath: "/opt/usage-butler/bin/arkcli"),
            now: { now }
        )

        for _ in 0..<2 {
            guard case let .success(data) = await adapter.read(scope: .provider) else {
                return XCTFail("A metadata outcome must never change usage quota success")
            }
            XCTAssertEqual(
                data.products.first { $0.sourceProductID == "coding-plan" }?.planLevel?.value,
                "pro"
            )
        }
        let readCallCount = await metadataReader.readCallCount()
        XCTAssertEqual(readCallCount, 2)
    }

    func testSuccessfulMetadataSnapshotRevokesUnsupportedCachedTiers() async throws {
        let replacementPlans = [
            "[]",
            #"[{"key":"coding-plan","scope":"personal","tier":"future"}]"#,
            #"[{"key":"coding-plan","scope":"team","tier":"pro"}]"#,
            #"[{"key":"coding-plan","scope":"personal","tier":"pro"},{"key":"coding-plan","scope":"personal","tier":"lite"}]"#,
            #"[{"key":"coding-plan","scope":"personal"}]"#,
            #"[{"key":"future-plan","scope":"personal","tier":"pro"}]"#,
            #"[{"key":"agent-plan","scope":"personal","tier":"medium"}]"#
        ]
        let now = fixedNow
        let executableURL = URL(fileURLWithPath: "/opt/usage-butler/bin/arkcli")
        for plans in replacementPlans {
            let usageProcess = ArkFakeChildProcessClient(results: Array(
                repeating: .success(output(receiptJSON)), count: 4
            ))
            let metadataProcess = ArkFakeChildProcessClient(results: [
                .success(output(#"{"plans":[{"key":"coding-plan","scope":"personal","tier":"pro"}]}"#)),
                .success(output("{\"plans\":\(plans)}")),
                .failure(metadataFailure),
                .success(output(#"{"plans":[{"key":"coding-plan","scope":"personal","tier":"lite"}]}"#))
            ])
            let reader = ArkPlanMetadataReader(
                processClient: metadataProcess, executableURL: executableURL, now: { now }
            )
            let adapter = ArkProviderAdapter(
                processClient: usageProcess,
                planMetadataReader: reader,
                executableURL: executableURL,
                now: { now }
            )
            var firstMetrics: [QuotaMetric]?
            let expectedTiers: [String?] = ["pro", nil, nil, "lite"]
            for expectedTier in expectedTiers {
                guard case let .success(data) = await adapter.read(scope: .provider) else {
                    return XCTFail("Metadata must not change quota success: \(plans)")
                }
                let coding = try XCTUnwrap(data.products.first { $0.sourceProductID == "coding-plan" })
                let agent = try XCTUnwrap(data.products.first { $0.sourceProductID == "agent-plan" })
                XCTAssertEqual(coding.planLevel?.value, expectedTier, plans)
                XCTAssertEqual(agent.planLevel?.value, "medium", "Usage tier remains authoritative")
                XCTAssertEqual(agent.planLevel?.origin, .reported(sourceField: "items[].tier"))
                let metrics = data.products.flatMap(\.metrics)
                if let firstMetrics {
                    XCTAssertEqual(metrics, firstMetrics, "Metadata must not alter quota nodes")
                } else {
                    firstMetrics = metrics
                }
                XCTAssertTrue(metrics.allSatisfy { $0.state.freshness == .fresh(asOf: now) })
                XCTAssertTrue(data.products.allSatisfy { $0.state.failure == nil })
            }
        }
    }

    func testUsageTierWinsAcrossMetadataSuccessRevocationAndReadFailures() async throws {
        let now = fixedNow
        let executableURL = URL(fileURLWithPath: "/opt/usage-butler/bin/arkcli")
        let usage = receiptJSON.replacingOccurrences(of: "\"tier\": null", with: "\"tier\": \"lite\"")
        let metadataProcess = ArkFakeChildProcessClient(results: [
            .success(output(#"{"plans":[{"key":"coding-plan","scope":"personal","tier":"pro"}]}"#)),
            .success(output(#"{"plans":[]}"#)),
            .success(output(#"{"plans":[{"key":"coding-plan","scope":"team","tier":"pro"}]}"#)),
            .failure(metadataFailure)
        ])
        let adapter = ArkProviderAdapter(
            processClient: ArkFakeChildProcessClient(results: Array(repeating: .success(output(usage)), count: 4)),
            planMetadataReader: ArkPlanMetadataReader(
                processClient: metadataProcess, executableURL: executableURL, now: { now }
            ),
            executableURL: executableURL,
            now: { now }
        )
        for _ in 0..<4 {
            guard case let .success(data) = await adapter.read(scope: .provider) else {
                return XCTFail("Metadata must not change authoritative usage success")
            }
            let coding = try XCTUnwrap(data.products.first { $0.sourceProductID == "coding-plan" })
            XCTAssertEqual(coding.planLevel?.value, "lite")
            XCTAssertEqual(coding.planLevel?.origin, .reported(sourceField: "items[].tier"))
            XCTAssertEqual(coding.state.freshness, .fresh(asOf: now))
        }
    }

    func testMetadataReaderFailuresReuseLastSuccessfulSnapshot() async throws {
        let failures: [Result<ChildProcessOutput, ProviderFailure>] = [
            .failure(metadataFailure),
            .success(output(#"{"plans":null}"#)),
            .success(ChildProcessOutput(
                termination: .exited(code: 1), standardOutput: Data(), redactedStandardError: Data()
            ))
        ]
        let now = fixedNow
        let executableURL = URL(fileURLWithPath: "/opt/usage-butler/bin/arkcli")
        for failure in failures {
            let metadataProcess = ArkFakeChildProcessClient(results: [
                .success(output(#"{"plans":[{"key":"coding-plan","scope":"personal","tier":"pro"}]}"#)),
                failure
            ])
            let adapter = ArkProviderAdapter(
                processClient: ArkFakeChildProcessClient(results: Array(repeating: .success(output(receiptJSON)), count: 2)),
                planMetadataReader: ArkPlanMetadataReader(
                    processClient: metadataProcess, executableURL: executableURL, now: { now }
                ),
                executableURL: executableURL,
                now: { now }
            )
            for _ in 0..<2 {
                guard case let .success(data) = await adapter.read(scope: .provider) else {
                    return XCTFail("A metadata read failure must not fail quota")
                }
                let coding = try XCTUnwrap(data.products.first { $0.sourceProductID == "coding-plan" })
                XCTAssertEqual(coding.planLevel?.value, "pro")
                XCTAssertEqual(coding.planLevel?.origin, .reported(sourceField: "plans.get.plans[].tier"))
                XCTAssertEqual(coding.planLevel?.fetchedAt, now)
                XCTAssertEqual(coding.state.freshness, .fresh(asOf: now))
                XCTAssertNil(coding.state.failure)
            }
        }
    }

    func testSupportedCompleteReadBecomesFreshAndIsCachedDespiteUnsupportedRows() async throws {
        let process = ArkFakeChildProcessClient(results: [
            .success(output(supportedAndUnsupportedJSON)),
            .success(output(supportedAndUnsupportedJSON))
        ])
        let now = fixedNow
        let adapter = ArkProviderAdapter(
            processClient: process,
            executableURL: URL(fileURLWithPath: "/opt/usage-butler/bin/arkcli"),
            now: { now }
        )
        let cache = ArkRecordingQuotaCache(loadResult: .miss)
        let clock = ArkFixedClock(
            reading: ClockReading(
                wallTime: fixedNow,
                monotonicTime: MonotonicInstant(nanoseconds: 1)
            )
        )
        let controller = try ProviderController(
            initialState: controllerState(capabilities: adapter.capabilities),
            initiallyEnabled: true,
            adapter: adapter,
            cache: cache,
            clock: clock,
            scheduler: RefreshScheduler(clock: clock),
            policy: automaticTestPolicy
        )

        let outcome = await controller.send(.start)
        XCTAssertEqual(outcome, .completed)
        let projection = await controller.projection()
        XCTAssertEqual(projection.state.freshness, .fresh(asOf: fixedNow))
        XCTAssertEqual(projection.state.lastGood?.products.count, 2)
        let savedData = await cache.savedData()
        XCTAssertEqual(savedData.count, 1)

        let diagnostic = await adapter.diagnosticSnapshot()
        XCTAssertEqual(diagnostic.safeFields["schema"], "ark-usage-plan-json-v1:valid")
        XCTAssertEqual(diagnostic.safeFields["parserCode"], "none")
        XCTAssertEqual(diagnostic.safeFields["parserPath"], "none")
        XCTAssertEqual(diagnostic.safeFields["supportedItems"], "2")
        XCTAssertEqual(diagnostic.safeFields["unsupportedItems"], "3")
        XCTAssertEqual(diagnostic.safeFields["droppedSupportedItems"], "0")
        XCTAssertEqual(diagnostic.safeFields["droppedUnsupportedItems"], "0")
        XCTAssertEqual(diagnostic.safeFields["droppedUnclassifiedItems"], "0")

        let safeDiagnosticText = diagnostic.safeFields.keys.joined(separator: " ")
            + diagnostic.safeFields.values.joined(separator: " ")
            + diagnostic.diagnosticCode
        for forbidden in [
            "viewer-secret@example.invalid",
            "future-plan-private",
            "agent-plan-team",
            "coding-plan-team",
            "sensitive_unknown_key",
            "/private/identity"
        ] {
            XCTAssertFalse(safeDiagnosticText.contains(forbidden))
        }
    }

    func testKnownSupportedBadPeriodIsPartialStaleAndCachesMergedLastGood() async throws {
        let historical = try ArkDomainMapper.map(
            try parse(receiptJSON),
            source: sourceIdentity
        )
        let process = ArkFakeChildProcessClient(results: [
            .success(output(receiptJSON)),
            .success(output(knownSupportedBadPeriodJSON))
        ])
        let now = fixedNow
        let adapter = ArkProviderAdapter(
            processClient: process,
            executableURL: URL(fileURLWithPath: "/opt/usage-butler/bin/arkcli"),
            now: { now }
        )
        let cache = ArkRecordingQuotaCache(loadResult: .hit(historical))
        let clock = ArkFixedClock(
            reading: ClockReading(
                wallTime: fixedNow,
                monotonicTime: MonotonicInstant(nanoseconds: 1)
            )
        )
        let controller = try ProviderController(
            initialState: controllerState(capabilities: adapter.capabilities),
            initiallyEnabled: true,
            adapter: adapter,
            cache: cache,
            clock: clock,
            scheduler: RefreshScheduler(clock: clock),
            policy: automaticTestPolicy
        )

        let outcome = await controller.send(.start)
        XCTAssertEqual(outcome, .completed)
        let projection = await controller.projection()
        guard case .stale = projection.state.freshness else {
            return XCTFail("A supported Product period contract failure must remain partial/stale")
        }
        XCTAssertNil(projection.state.refresh.lastSuccessAt)
        let savedData = await cache.savedData()
        XCTAssertEqual(savedData.count, 1)
        XCTAssertEqual(
            try XCTUnwrap(savedData.first),
            try XCTUnwrap(projection.state.lastGood),
            "A partial read must persist the normalized merged snapshot instead of rolling back after restart"
        )

        let diagnostic = await adapter.diagnosticSnapshot()
        XCTAssertEqual(diagnostic.safeFields["schema"], "ark-usage-plan-json-v1:partial")
        XCTAssertEqual(diagnostic.safeFields["supportedItems"], "2")
        XCTAssertEqual(diagnostic.safeFields["unsupportedItems"], "0")
    }

    func testFatalEnvelopeMismatchIsFailureWithSafeParserCodeAndPath() async {
        let secret = "viewer-secret@example.invalid"
        let process = ArkFakeChildProcessClient(results: [
            .success(
                output(
                    """
                    {
                      "viewer": { "email": "\(secret)" },
                      "items": { "sensitive_unknown_key": "/private/identity" }
                    }
                    """
                )
            )
        ])
        let now = fixedNow
        let adapter = ArkProviderAdapter(
            processClient: process,
            executableURL: URL(fileURLWithPath: "/opt/usage-butler/bin/arkcli"),
            now: { now }
        )

        guard case let .failure(failure) = await adapter.read(scope: .provider) else {
            return XCTFail("A fatal top-level envelope mismatch must not become partial")
        }
        XCTAssertEqual(failure.code, .schemaMismatch)

        let diagnostic = await adapter.diagnosticSnapshot()
        XCTAssertEqual(diagnostic.safeFields["parserCode"], "invalidFieldType")
        XCTAssertEqual(diagnostic.safeFields["parserPath"], "$.items")
        XCTAssertEqual(diagnostic.safeFields["supportedItems"], "0")
        XCTAssertEqual(diagnostic.safeFields["unsupportedItems"], "0")
        let safeDiagnosticText = diagnostic.safeFields.keys.joined(separator: " ")
            + diagnostic.safeFields.values.joined(separator: " ")
            + diagnostic.diagnosticCode
        XCTAssertFalse(safeDiagnosticText.contains(secret))
        XCTAssertFalse(safeDiagnosticText.contains("sensitive_unknown_key"))
        XCTAssertFalse(safeDiagnosticText.contains("/private/identity"))
    }

    func testOfficialSSOLoginRejectsUnsupportedMethodWithoutStartingProcess() async {
        let process = ArkFakeChildProcessClient(results: [])
        let adapter = ArkProviderAdapter(
            processClient: process,
            executableURL: URL(fileURLWithPath: "/opt/usage-butler/bin/arkcli")
        )

        guard case let .failure(failure) = await adapter.login(method: .oauth) else {
            return XCTFail("Ark must reject every login method except SSO")
        }
        XCTAssertEqual(failure.code, .protocolViolation)
        XCTAssertEqual(failure.diagnosticCode, "ark.adapter.login.unsupported_method")
        let requests = await process.capturedRequests()
        XCTAssertTrue(requests.isEmpty)
    }

    func testOfficialSSOLoginUsesExitStatusWithoutGuessingFromOutput() async {
        let output = ChildProcessOutput(
            termination: .exited(code: 23),
            standardOutput: Data("success authenticated user@example.invalid".utf8),
            redactedStandardError: Data("token redacted".utf8)
        )
        let process = ArkFakeChildProcessClient(results: [.success(output)])
        let adapter = ArkProviderAdapter(
            processClient: process,
            executableURL: URL(fileURLWithPath: "/opt/usage-butler/bin/arkcli")
        )

        guard case let .failure(failure) = await adapter.login(method: .sso) else {
            return XCTFail("A nonzero exit must fail regardless of output text")
        }
        XCTAssertEqual(failure.code, .processFailed)
        XCTAssertEqual(failure.retryClass, .backoff)
        XCTAssertEqual(failure.diagnosticCode, "ark.adapter.login.process.nonzero_exit")
        XCTAssertEqual(failure.recovery, .retry)
        XCTAssertFalse(failure.diagnosticCode.contains("user@example.invalid"))
    }

    func testOfficialSSOLoginClassifiesTokenExchangeRateLimitWithoutLeakingOutput() async {
        let secret = "private-user@example.invalid"
        let output = ChildProcessOutput(
            termination: .exited(code: 1),
            standardOutput: Data(
                """
                {"ok":false,"error":{"message":"token exchange failed: invalid_request - Too many requests, rate limit exceeded"},"identity":"\(secret)"}
                """.utf8
            ),
            redactedStandardError: Data()
        )
        let process = ArkFakeChildProcessClient(results: [.success(output)])
        let adapter = ArkProviderAdapter(
            processClient: process,
            executableURL: URL(fileURLWithPath: "/opt/usage-butler/bin/arkcli")
        )

        guard case let .failure(failure) = await adapter.login(method: .sso) else {
            return XCTFail("A rate-limited token exchange must remain a failed login")
        }
        XCTAssertEqual(failure.code, .rateLimited)
        XCTAssertEqual(failure.retryClass, .backoff)
        XCTAssertEqual(failure.diagnosticCode, "ark.adapter.login.rate_limited")
        XCTAssertEqual(failure.recovery, .retry)
        let diagnostic = await adapter.diagnosticSnapshot()
        XCTAssertEqual(diagnostic.safeFields["errorClass"], "login_rateLimited")
        XCTAssertFalse(diagnostic.safeFields.values.joined().contains(secret))
        XCTAssertFalse(diagnostic.diagnosticCode.contains(secret))
    }

    func testOfficialSSOLoginNonzeroExitUsesTypedAuthReadbackAsRecoveryProof() async {
        let evidence = AuthenticationEvidence(
            authority: .providerReport(
                sourceField: "identity_store.refresh_token.exp",
                contractVersion: ArkDomainContract.quotaContractVersion
            ),
            observedAt: fixedNow,
            expiresAt: fixedNow.addingTimeInterval(172_800)
        )
        let authReader = ArkLoginStatusReader(
            result: .success(
                ArkAuthenticationObservation(
                    authentication: .healthy(evidence),
                    requiresLoginEvidence: nil,
                    observedAt: fixedNow
                )
            )
        )
        let process = ArkFakeChildProcessClient(results: [
            .success(
                ChildProcessOutput(
                    termination: .exited(code: 1),
                    standardOutput: Data("opaque post-callback failure".utf8),
                    redactedStandardError: Data()
                )
            )
        ])
        let adapter = ArkProviderAdapter(
            processClient: process,
            authenticationStatusReader: authReader,
            executableURL: URL(fileURLWithPath: "/opt/usage-butler/bin/arkcli")
        )

        let loginResult = await adapter.login(method: .sso)
        let authReadCount = await authReader.readCallCount()
        XCTAssertEqual(loginResult, .success)
        XCTAssertEqual(authReadCount, 1)
    }

    func testOfficialSSOLoginNonzeroExitDoesNotTreatWarningAsRenewed() async {
        let evidence = AuthenticationEvidence(
            authority: .providerReport(
                sourceField: "identity_store.refresh_token.exp",
                contractVersion: ArkDomainContract.quotaContractVersion
            ),
            observedAt: fixedNow,
            expiresAt: fixedNow.addingTimeInterval(3_600)
        )
        let authReader = ArkLoginStatusReader(
            result: .success(
                ArkAuthenticationObservation(
                    authentication: .warning(evidence),
                    requiresLoginEvidence: nil,
                    observedAt: fixedNow
                )
            )
        )
        let process = ArkFakeChildProcessClient(results: [
            .success(
                ChildProcessOutput(
                    termination: .exited(code: 1),
                    standardOutput: Data("opaque post-callback failure".utf8),
                    redactedStandardError: Data()
                )
            )
        ])
        let adapter = ArkProviderAdapter(
            processClient: process,
            authenticationStatusReader: authReader,
            executableURL: URL(fileURLWithPath: "/opt/usage-butler/bin/arkcli")
        )

        guard case let .failure(failure) = await adapter.login(method: .sso) else {
            return XCTFail("An unchanged warning session must not prove renewal")
        }
        XCTAssertEqual(failure.code, .processFailed)
        let authReadCount = await authReader.readCallCount()
        XCTAssertEqual(authReadCount, 1)
    }

    func testOfficialSSOLoginSanitizesTypedChildFailure() async {
        let secretDiagnostic = "child.timeout.user@example.invalid./Users/private"
        let childFailure = ProviderFailure(
            code: .timedOut,
            retryClass: .backoff,
            userMessageKey: "provider.failure.timed_out",
            diagnosticCode: secretDiagnostic,
            recovery: .retry
        )
        let process = ArkFakeChildProcessClient(results: [.failure(childFailure)])
        let adapter = ArkProviderAdapter(
            processClient: process,
            executableURL: URL(fileURLWithPath: "/opt/usage-butler/bin/arkcli")
        )

        guard case let .failure(failure) = await adapter.login(method: .sso) else {
            return XCTFail("A typed child failure must stay a typed login failure")
        }
        XCTAssertEqual(failure.code, .timedOut)
        XCTAssertEqual(failure.retryClass, .backoff)
        XCTAssertEqual(failure.userMessageKey, "provider.failure.timed_out")
        XCTAssertEqual(failure.diagnosticCode, "ark.adapter.login.child.timedOut")
        XCTAssertEqual(failure.recovery, .retry)
        XCTAssertFalse(failure.diagnosticCode.contains(secretDiagnostic))
        let diagnostic = await adapter.diagnosticSnapshot()
        XCTAssertFalse(diagnostic.safeFields.values.joined().contains(secretDiagnostic))
    }

    func testOfficialSSOLoginTaskCancellationReturnsCancelled() async {
        let process = ArkSuspendingChildProcessClient()
        let adapter = ArkProviderAdapter(
            processClient: process,
            executableURL: URL(fileURLWithPath: "/opt/usage-butler/bin/arkcli")
        )
        let loginTask = Task { await adapter.login(method: .sso) }

        let didStart = await process.waitForRequest()
        XCTAssertTrue(didStart)
        loginTask.cancel()
        let result = await loginTask.value
        XCTAssertEqual(result, .cancelled)

        await adapter.shutdown()
    }

    func testShutdownCancelsInFlightOfficialSSOLogin() async {
        let process = ArkSuspendingChildProcessClient()
        let adapter = ArkProviderAdapter(
            processClient: process,
            executableURL: URL(fileURLWithPath: "/opt/usage-butler/bin/arkcli")
        )
        let loginTask = Task { await adapter.login(method: .sso) }

        let didStart = await process.waitForRequest()
        XCTAssertTrue(didStart)
        await adapter.shutdown()

        let result = await loginTask.value
        XCTAssertEqual(result, .cancelled)
        let requests = await process.capturedRequests()
        XCTAssertEqual(requests.count, 1)
        let shutdownCallCount = await process.shutdownCallCount()
        XCTAssertEqual(shutdownCallCount, 1)

        guard case let .failure(failure) = await adapter.login(method: .sso) else {
            return XCTFail("Shutdown must reject a later login")
        }
        XCTAssertEqual(failure.code, .shutdown)
        let requestCountAfterRejectedLogin = await process.capturedRequests().count
        XCTAssertEqual(requestCountAfterRejectedLogin, 1)
    }

    func testAdapterPartialReplacesSuccessfulProductAndMutatesFailedHistoricalProduct() async throws {
        let partialJSON =
            """
            {
              "items": [
                {
                  "product": "agent-plan",
                  "subscribed": false,
                  "periods": [],
                  "error": { "code": "redacted" }
                },
                {
                  "product": "coding-plan",
                  "subscribed": true,
                  "periods": [
                    { "label": "session", "percent": 7, "reset_at": null }
                  ]
                }
              ]
            }
            """
        let process = ArkFakeChildProcessClient(results: [
            .success(output(partialJSON)),
            .success(output(#"{ "items": [] }"#))
        ])
        let now = fixedNow
        let adapter = ArkProviderAdapter(
            processClient: process,
            executableURL: URL(fileURLWithPath: "/private/secret/bin/arkcli"),
            now: { now }
        )

        let partial = await adapter.read(scope: .provider)
        guard case let .partial(patch, failure) = partial else {
            return XCTFail("One valid sibling must be retained as a partial patch")
        }
        XCTAssertEqual(patch.updatedProducts.map(\.sourceProductID), ["coding-plan"])
        XCTAssertEqual(failure.code, .serviceUnavailable)

        let agentMutation = try XCTUnwrap(patch.productMutations.first {
            $0.productID.sourceProductID == "agent-plan"
        })
        guard case let .mutate(agentID, mutation) = agentMutation else {
            return XCTFail("The failed Agent Product must retain payload through a node mutation")
        }
        XCTAssertEqual(agentID.sourceProductID, "agent-plan")
        XCTAssertEqual(mutation.planLevel, .retain)
        XCTAssertEqual(mutation.state.presence, .retain)
        XCTAssertEqual(mutation.state.freshness, .retain)
        guard case let .replace(currentFailure) = mutation.state.failure else {
            return XCTFail("The failed Product must expose its current failure")
        }
        XCTAssertEqual(currentFailure?.code, .serviceUnavailable)

        let codingMutation = try XCTUnwrap(patch.productMutations.first {
            $0.productID.sourceProductID == "coding-plan"
        })
        guard case let .replace(freshCoding) = codingMutation else {
            return XCTFail("The successful Coding Product must be replaced authoritatively")
        }
        XCTAssertEqual(freshCoding.sourceProductID, "coding-plan")

        let failureAt = fixedNow.addingTimeInterval(60)
        let withoutHistory = ProviderReducer.reduce(
            state: providerState(lastGood: nil),
            event: .refreshPartiallySucceeded(patch, failure),
            now: failureAt
        )
        XCTAssertEqual(
            withoutHistory.lastGood?.products.map(\.sourceProductID),
            ["coding-plan"],
            "A failed Product mutation must not synthesize payload when history is absent"
        )

        let historical = try ArkDomainMapper.map(
            try parse(receiptJSON),
            source: sourceIdentity
        )
        let historicalAgent = try XCTUnwrap(historical.products.first {
            $0.sourceProductID == "agent-plan"
        })
        let withHistory = ProviderReducer.reduce(
            state: providerState(lastGood: historical),
            event: .refreshPartiallySucceeded(patch, failure),
            now: failureAt
        )
        let retainedAgent = try XCTUnwrap(withHistory.lastGood?.products.first {
            $0.sourceProductID == "agent-plan"
        })
        XCTAssertEqual(retainedAgent.metrics.map(\.id), historicalAgent.metrics.map(\.id))
        XCTAssertEqual(retainedAgent.metrics.map(\.value), historicalAgent.metrics.map(\.value))
        XCTAssertEqual(
            retainedAgent.metrics.map(\.provenance),
            historicalAgent.metrics.map(\.provenance)
        )
        XCTAssertEqual(retainedAgent.state.presence, historicalAgent.state.presence)
        XCTAssertEqual(retainedAgent.state.failure?.code, .serviceUnavailable)
        guard case let .stale(asOf, evaluatedAt) = retainedAgent.state.freshness else {
            return XCTFail("Retained failed Product payload must be stale")
        }
        XCTAssertEqual(asOf, historical.fetchedAt)
        XCTAssertEqual(evaluatedAt, failureAt)
        guard case .stale = try XCTUnwrap(retainedAgent.metrics.first).state.freshness else {
            return XCTFail("Retained metric payload must be stale with its Product")
        }

        let empty = await adapter.read(scope: .provider)
        guard case let .failure(emptyFailure) = empty else {
            return XCTFail("Empty items are unknown, not notEntitled")
        }
        XCTAssertEqual(emptyFailure.code, .schemaMismatch)
        let diagnostic = await adapter.diagnosticSnapshot()
        XCTAssertEqual(
            Set(diagnostic.safeFields.keys),
            expectedSafeDiagnosticKeys
        )
        XCTAssertFalse(diagnostic.safeFields.values.joined().contains("/private/secret"))
    }

    func testDiscoverDoesNotTurnOpaqueUsageErrorIntoAuthenticationState() async {
        let process = ArkFakeChildProcessClient(results: [
            .success(output(
                """
                {
                  "items": [
                    {
                      "product": "agent-plan",
                      "subscribed": false,
                      "periods": [],
                      "error": { "code": "redacted" }
                    }
                  ]
                }
                """
            ))
        ])
        let now = fixedNow
        let adapter = ArkProviderAdapter(
            processClient: process,
            executableURL: URL(fileURLWithPath: "/opt/usage-butler/bin/arkcli"),
            now: { now }
        )

        let result = await adapter.discover()
        guard case let .failure(failure) = result else {
            return XCTFail("Opaque usage errors are not typed auth evidence")
        }
        XCTAssertEqual(failure.code, .serviceUnavailable)
        XCTAssertEqual(failure.recovery, .retry)
    }

    func testDiscoverBothKnownProductsNotEntitledIsConnectedHealthySuccess() async {
        let process = ArkFakeChildProcessClient(results: [
            .success(output(
                """
                {
                  "items": [
                    { "product": "agent-plan", "subscribed": false, "periods": [] },
                    { "product": "coding-plan", "subscribed": false, "periods": [] }
                  ]
                }
                """
            ))
        ])
        let now = fixedNow
        let adapter = ArkProviderAdapter(
            processClient: process,
            executableURL: URL(fileURLWithPath: "/opt/usage-butler/bin/arkcli"),
            now: { now }
        )

        guard case let .success(discovery) = await adapter.discover() else {
            return XCTFail("Error-free product absence is still successful provider discovery")
        }
        XCTAssertEqual(discovery.connection, .connected)
        guard case .healthy = discovery.authentication else {
            return XCTFail("The authenticated discovery should remain healthy")
        }
        XCTAssertNil(discovery.presence, "Ark product presence is expressed per Product")
    }

    func testLoginAfterShutdownReturnsShutdownWithoutStartingProcess() async {
        let process = ArkFakeChildProcessClient(results: [])
        let adapter = ArkProviderAdapter(
            processClient: process,
            executableURL: URL(fileURLWithPath: "/opt/usage-butler/bin/arkcli")
        )

        await adapter.shutdown()
        guard case let .failure(failure) = await adapter.login(method: .sso) else {
            return XCTFail("Shutdown must reject later login")
        }
        XCTAssertEqual(failure.code, .shutdown)
        let requests = await process.capturedRequests()
        XCTAssertTrue(requests.isEmpty)
    }

    private func parse(
        _ json: String,
        completeness: ParsedArkReadCompleteness = .completeSuccess,
        authoritativeDiscovery: Bool = true
    ) throws -> ParsedArkUsageSnapshot {
        try ArkUsagePlanParser.parse(
            Data(json.utf8),
            context: ParsedArkParsingContext(
                completeness: completeness,
                authoritativeDiscovery: authoritativeDiscovery,
                sourceVersion: "1.0.13",
                fetchedAt: fixedNow
            )
        )
    }

    private var sourceIdentity: ProviderSourceIdentity {
        ProviderSourceIdentity(
            providerID: .ark,
            adapterID: ArkDomainContract.adapterID,
            executableIdentity: ArkDomainContract.executableIdentity,
            cliVersion: "1.0.13",
            schemaVersion: ArkDomainContract.schemaVersion,
            contractVersion: ArkDomainContract.quotaContractVersion
        )
    }

    private var automaticTestPolicy: RefreshPolicy {
        RefreshPolicy(
            cadence: .automatic(interval: .seconds(3_600)),
            manualCooldown: .seconds(30),
            retryBackoff: [.seconds(60)],
            shutdownGrace: .seconds(1)
        )
    }

    private var expectedSafeDiagnosticKeys: Set<String> {
        Set([
            "adapter",
            "cliVersion",
            "errorClass",
            "schema",
            "parserCode",
            "parserPath",
            "supportedItems",
            "unsupportedItems",
            "droppedSupportedItems",
            "droppedUnsupportedItems",
            "droppedUnclassifiedItems"
        ])
    }

    private func controllerState(capabilities: ProviderCapabilities) -> ProviderState {
        let evidence = AuthenticationEvidence(
            authority: .initialDetection,
            observedAt: fixedNow
        )
        return ProviderState(
            id: .ark,
            capabilities: capabilities,
            connection: .detecting(startedAt: fixedNow),
            presence: .unknown,
            authentication: .unknown(evidence),
            refresh: RefreshState(
                activity: .idle,
                gate: .open,
                lastAttemptAt: nil,
                lastSuccessAt: nil
            ),
            lastGood: nil,
            freshness: .unknown,
            discovery: .notStarted,
            persistence: .unknown,
            failure: nil
        )
    }

    private func providerState(lastGood: ProviderQuotaData?) -> ProviderState {
        let authentication = AuthenticationEvidence(
            authority: .providerReport(
                sourceField: "items[].subscribed",
                contractVersion: ArkDomainContract.quotaContractVersion
            ),
            observedAt: fixedNow
        )
        let freshness: FreshnessState = lastGood.map {
            .fresh(asOf: $0.fetchedAt)
        } ?? .unknown
        return ProviderState(
            id: .ark,
            capabilities: ProviderCapabilities(
                contractVersion: ArkDomainContract.quotaContractVersion,
                loginMethod: .sso,
                hasOfficialDocumentation: true,
                allowsExecutableSelection: true
            ),
            connection: .connected(observedAt: fixedNow),
            presence: .unknown,
            authentication: .healthy(authentication),
            refresh: RefreshState(
                activity: .refreshing(
                    scope: .provider,
                    generation: 1,
                    startedAt: fixedNow
                ),
                gate: .open,
                lastAttemptAt: fixedNow,
                lastSuccessAt: lastGood?.fetchedAt
            ),
            lastGood: lastGood,
            freshness: freshness,
            discovery: .notStarted,
            persistence: .unknown,
            failure: nil
        )
    }

    private func output(_ json: String) -> ChildProcessOutput {
        ChildProcessOutput(
            termination: .exited(code: 0),
            standardOutput: Data(json.utf8),
            redactedStandardError: Data()
        )
    }

    private func decimal(_ value: String) -> Decimal {
        Decimal(string: value, locale: Locale(identifier: "en_US_POSIX"))!
    }

    private var metadataFailure: ProviderFailure {
        ProviderFailure(
            code: .serviceUnavailable,
            retryClass: .backoff,
            userMessageKey: "provider.failure.service",
            diagnosticCode: "test.ark.metadata.failure",
            recovery: .retry
        )
    }

    private var supportedAndUnsupportedJSON: String {
        """
        {
          "viewer": { "email": "viewer-secret@example.invalid" },
          "items": [
            {
              "product": "agent-plan",
              "edition": "personal",
              "subscribed": true,
              "periods": [
                {
                  "label": "5h",
                  "percent": 4,
                  "reset_at": "2026-08-12T00:00:00.123456+08:00"
                }
              ]
            },
            {
              "product": "coding-plan",
              "edition": "personal",
              "subscribed": true,
              "periods": [
                {
                  "label": "weekly",
                  "percent": 5,
                  "reset_at": "2026-08-12T00:00:00+08:00"
                }
              ]
            },
            {
              "product": "agent-plan-team",
              "subscribed": false,
              "periods": null,
              "sensitive_unknown_key": "/private/identity"
            },
            {
              "product": "coding-plan-team",
              "subscribed": false,
              "periods": { "sensitive_unknown_key": "/private/identity" }
            },
            {
              "product": "future-plan-private",
              "subscribed": false
            }
          ]
        }
        """
    }

    private var knownSupportedBadPeriodJSON: String {
        """
        {
          "items": [
            {
              "product": "agent-plan",
              "subscribed": true,
              "periods": [
                { "label": "5h", "percent": "opaque", "reset_at": null },
                { "label": "weekly", "percent": 25, "reset_at": null }
              ]
            },
            {
              "product": "coding-plan",
              "subscribed": true,
              "periods": [
                { "label": "session", "percent": 7, "reset_at": null }
              ]
            }
          ]
        }
        """
    }

    private var liveShapeTotalWithoutUsedJSON: String {
        """
        {
          "viewer": {},
          "items": [
            {
              "product": "agent-plan",
              "edition": "personal",
              "tier": "medium",
              "subscribed": true,
              "periods": [
                {
                  "label": "5h",
                  "total": 100,
                  "percent": 10
                },
                {
                  "label": "weekly",
                  "used": 20,
                  "total": 100,
                  "percent": 20,
                  "reset_at": "2026-08-12T00:00:00+08:00"
                },
                {
                  "label": "monthly",
                  "used": 30,
                  "total": 100,
                  "percent": 30,
                  "reset_at": "2026-09-12T00:00:00+08:00"
                }
              ]
            },
            {
              "product": "coding-plan",
              "edition": "personal",
              "subscribed": true,
              "updated_at": 1,
              "periods": [
                {
                  "label": "session",
                  "percent": 4,
                  "reset_at": "2026-08-12T00:00:00+08:00"
                },
                {
                  "label": "weekly",
                  "percent": 5,
                  "reset_at": "2026-08-19T00:00:00+08:00"
                },
                {
                  "label": "monthly",
                  "percent": 6,
                  "reset_at": "2026-09-12T00:00:00+08:00"
                }
              ]
            }
          ]
        }
        """
    }

    private var receiptJSON: String {
        """
        {
          "items": [
            {
              "product": "agent-plan",
              "edition": "personal",
              "tier": "medium",
              "subscribed": true,
              "periods": [
                {
                  "label": "5h",
                  "used": 404.039,
                  "total": 10000,
                  "percent": 4.04039,
                  "reset_at": "2026-08-10T03:44:02+08:00"
                },
                {
                  "label": "weekly",
                  "used": 30278.9618,
                  "total": 35000,
                  "percent": 86.51131942857143,
                  "reset_at": "2026-08-10T00:00:00+08:00"
                },
                {
                  "label": "monthly",
                  "used": 30278.9618,
                  "total": 100000,
                  "percent": 30.278961799999998,
                  "reset_at": "2026-09-04T23:59:59+08:00"
                }
              ],
              "error_present": false
            },
            {
              "product": "coding-plan",
              "edition": "personal",
              "tier": null,
              "subscribed": true,
              "updated_at": 1786286695,
              "updated_at_iso8601": "2026-08-09T22:44:55+08:00",
              "periods": [
                { "label": "session", "percent": 0, "reset_at": null },
                {
                  "label": "weekly",
                  "percent": 3.953061866666667,
                  "reset_at": "2026-08-10T00:00:00+08:00"
                },
                {
                  "label": "monthly",
                  "percent": 13.0259233,
                  "reset_at": "2026-08-18T23:59:59+08:00"
                }
              ],
              "error_present": false
            }
          ]
        }
        """
    }
}

private actor ArkFixedClock: ClockPort {
    private let fixedReading: ClockReading

    init(reading: ClockReading) {
        fixedReading = reading
    }

    func reading() async -> ClockReading {
        fixedReading
    }

    func sleep(until deadline: MonotonicInstant) async throws {
        throw CancellationError()
    }
}

private actor ArkRecordingQuotaCache: ProviderQuotaCache {
    private let loadResult: ProviderQuotaCacheLoadResult
    private var saved: [ProviderQuotaData] = []

    init(loadResult: ProviderQuotaCacheLoadResult) {
        self.loadResult = loadResult
    }

    func load(providerID: ProviderID) async -> ProviderQuotaCacheLoadResult {
        loadResult
    }

    func save(_ data: ProviderQuotaData) async -> ProviderQuotaCacheWriteResult {
        saved.append(data)
        return .success(writtenAt: data.fetchedAt)
    }

    func clear(providerID: ProviderID) async -> ProviderQuotaCacheClearResult {
        .success(clearedAt: Date(timeIntervalSince1970: 0), removedEntry: false)
    }

    func shutdown() async {}

    func savedData() -> [ProviderQuotaData] {
        saved
    }
}

private actor ArkFakeChildProcessClient: ChildProcessClient {
    private var results: [Result<ChildProcessOutput, ProviderFailure>]
    private var requests: [ChildProcessRequest] = []

    init(results: [Result<ChildProcessOutput, ProviderFailure>]) {
        self.results = results
    }

    func run(
        _ request: ChildProcessRequest
    ) async -> Result<ChildProcessOutput, ProviderFailure> {
        requests.append(request)
        guard !results.isEmpty else {
            return .failure(
                ProviderFailure(
                    code: .protocolViolation,
                    retryClass: .never,
                    userMessageKey: "test.fake.exhausted",
                    diagnosticCode: "test.fake.exhausted",
                    recovery: nil
                )
            )
        }
        return results.removeFirst()
    }

    func shutdown() async {}

    func capturedRequests() -> [ChildProcessRequest] {
        requests
    }
}

private actor ArkLoginStatusReader: ArkAuthenticationStatusReading {
    private let result: Result<ArkAuthenticationObservation, ProviderFailure>
    private var reads = 0

    init(result: Result<ArkAuthenticationObservation, ProviderFailure>) {
        self.result = result
    }

    func readAuthenticationStatus() async
        -> Result<ArkAuthenticationObservation, ProviderFailure> {
        reads += 1
        return result
    }

    func shutdown() async {}

    func readCallCount() -> Int { reads }
}

private actor ArkScriptedPlanMetadataReader: ArkPlanMetadataReading {
    private var results: [Result<ParsedArkPlanMetadataSnapshot, ProviderFailure>]
    private var readCalls = 0

    init(results: [Result<ParsedArkPlanMetadataSnapshot, ProviderFailure>]) {
        self.results = results
    }

    func readPlanMetadata() async -> Result<ParsedArkPlanMetadataSnapshot, ProviderFailure> {
        readCalls += 1
        guard !results.isEmpty else {
            return .failure(
                ProviderFailure(
                    code: .protocolViolation,
                    retryClass: .never,
                    userMessageKey: "test.fake.exhausted",
                    diagnosticCode: "test.fake.exhausted",
                    recovery: nil
                )
            )
        }
        return results.removeFirst()
    }

    func shutdown() async {}

    func readCallCount() -> Int {
        readCalls
    }
}

private actor ArkSuspendingChildProcessClient: ChildProcessClient {
    private var requests: [ChildProcessRequest] = []
    private var isShutdown = false
    private var shutdownCalls = 0

    func run(
        _ request: ChildProcessRequest
    ) async -> Result<ChildProcessOutput, ProviderFailure> {
        requests.append(request)
        while !isShutdown {
            do {
                try await Task.sleep(for: .milliseconds(5))
            } catch {
                return .failure(Self.cancelledFailure)
            }
        }
        return .failure(Self.shutdownFailure)
    }

    func shutdown() async {
        isShutdown = true
        shutdownCalls += 1
    }

    func waitForRequest() async -> Bool {
        for _ in 0..<200 {
            if !requests.isEmpty { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return false
    }

    func capturedRequests() -> [ChildProcessRequest] {
        requests
    }

    func shutdownCallCount() -> Int {
        shutdownCalls
    }

    private static let cancelledFailure = ProviderFailure(
        code: .cancelled,
        retryClass: .never,
        userMessageKey: "provider.failure.cancelled",
        diagnosticCode: "test.process.cancelled",
        recovery: nil
    )

    private static let shutdownFailure = ProviderFailure(
        code: .shutdown,
        retryClass: .never,
        userMessageKey: "provider.failure.shutdown",
        diagnosticCode: "test.process.shutdown",
        recovery: nil
    )
}
