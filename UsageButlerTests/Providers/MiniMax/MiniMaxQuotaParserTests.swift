import Foundation
import UsageButlerCore
import UsageButlerDomain
import XCTest
@testable import UsageButlerProviders

final class MiniMaxQuotaParserTests: XCTestCase {
    private let fixedNow = Date(timeIntervalSince1970: 1_786_300_000)

    func testParserPreservesAllKnownRawWindowFields() throws {
        let snapshot = try parse(receiptJSON)

        XCTAssertEqual(snapshot.baseStatusCode, 0)
        XCTAssertEqual(snapshot.droppedRowCount, 0)
        XCTAssertEqual(snapshot.duplicateRowCount, 0)
        XCTAssertEqual(snapshot.effectiveCompleteness, .completeSuccess)

        let general = try XCTUnwrap(snapshot.uniqueModel(named: "general"))
        XCTAssertEqual(general.current.startTimeMilliseconds, 1_786_309_200_000)
        XCTAssertEqual(general.current.endTimeMilliseconds, 1_786_327_200_000)
        XCTAssertEqual(general.current.remainsTimeMilliseconds, 8_288_354)
        XCTAssertEqual(general.current.totalCount, 0)
        XCTAssertEqual(general.current.usageCount, 0)
        XCTAssertEqual(general.current.remainingPercent, 96)
        XCTAssertEqual(general.current.status, 1)
        XCTAssertEqual(general.weekly.startTimeMilliseconds, 1_786_291_200_000)
        XCTAssertEqual(general.weekly.endTimeMilliseconds, 1_786_896_000_000)
        XCTAssertEqual(general.weekly.remainsTimeMilliseconds, 577_088_354)
        XCTAssertEqual(general.weekly.remainingPercent, 100)
        XCTAssertEqual(general.weekly.status, 3)

        let video = try XCTUnwrap(snapshot.uniqueModel(named: "video"))
        XCTAssertEqual(video.current.totalCount, 3)
        XCTAssertEqual(video.current.usageCount, 0)
        XCTAssertEqual(video.current.remainingPercent, 100)
        XCTAssertEqual(video.weekly.totalCount, 21)
        XCTAssertEqual(video.weekly.usageCount, 0)
        XCTAssertEqual(video.weekly.remainingPercent, 100)
    }

    func testProjectionUsesProviderFaithfulDirectionsWithoutInventingFiveHourLabel() throws {
        let metrics = MiniMaxQuotaProjector.project(try parse(receiptJSON))

        let generalCurrent = try XCTUnwrap(
            metrics.first { $0.sourceModelName == "general" && $0.window == .providerDefinedCurrent }
        )
        guard case let .usedPercent(percent) = generalCurrent.value else {
            return XCTFail("general current must be a finite used-percent projection")
        }
        XCTAssertEqual(percent.value, 4)
        XCTAssertEqual(percent.rawRemainingPercent, 96)
        XCTAssertEqual(percent.direction, .used)
        XCTAssertEqual(percent.derivation, .complementOfRemaining)
        XCTAssertEqual(generalCurrent.event?.remainingMilliseconds, 8_288_354)

        let generalWeekly = try XCTUnwrap(
            metrics.first { $0.sourceModelName == "general" && $0.window == .weekly }
        )
        XCTAssertEqual(generalWeekly.value, .unlimited(sourceStatus: 3))

        let videoCurrent = try XCTUnwrap(
            metrics.first { $0.sourceModelName == "video" && $0.window == .providerDefinedCurrent }
        )
        guard case let .usedCount(count) = videoCurrent.value else {
            return XCTFail("video current must use raw usage_count/total_count")
        }
        XCTAssertEqual(count.usageCount, 0)
        XCTAssertEqual(count.totalCount, 3)
        XCTAssertEqual(count.direction, .used)
        XCTAssertEqual(videoCurrent.placement, .overview)

        let videoWeekly = try XCTUnwrap(
            metrics.first { $0.sourceModelName == "video" && $0.window == .weekly }
        )
        guard case let .usedCount(weeklyCount) = videoWeekly.value else {
            return XCTFail("video weekly must remain a used count")
        }
        XCTAssertEqual(weeklyCount.usageCount, 0)
        XCTAssertEqual(weeklyCount.totalCount, 21)
        XCTAssertEqual(videoWeekly.placement, .detailOnly)
    }

    func testVersionedInferenceMapsApprovedDailyEntitlements() throws {
        let max = MiniMaxPlanInference.resolve(try parse(videoJSON(currentTotal: 3)))
        XCTAssertEqual(max.observation?.level, .max)
        XCTAssertEqual(max.observation?.ruleID, "minimax-video-daily-v1")
        XCTAssertEqual(max.observation?.catalogID, "minimax-token-plan-zh-cn-2026-08-10")
        XCTAssertEqual(max.observation?.sourceVersion, "1.0.19")

        let ultra = MiniMaxPlanInference.resolve(try parse(videoJSON(currentTotal: 5)))
        XCTAssertEqual(ultra.observation?.level, .ultra)

        let plus = MiniMaxPlanInference.resolve(
            try parse(videoJSON(currentTotal: 0, currentStatus: 3, weeklyTotal: 0, weeklyStatus: 3))
        )
        XCTAssertEqual(plus.observation?.level, .plus)
        XCTAssertEqual(plus.observation?.evidenceFields.count, 4)
    }

    func testStatusThreeMakesOnlyThatWindowUnlimited() throws {
        let snapshot = try parse(
            videoJSON(currentTotal: 3, currentStatus: 1, weeklyTotal: 0, weeklyStatus: 3)
        )
        let metrics = MiniMaxQuotaProjector.project(snapshot)
        let current = try XCTUnwrap(metrics.first { $0.window == .providerDefinedCurrent })
        let weekly = try XCTUnwrap(metrics.first { $0.window == .weekly })

        guard case .usedCount = current.value else {
            return XCTFail("A finite current video window must remain a used count")
        }
        XCTAssertEqual(weekly.value, .unlimited(sourceStatus: 3))
    }

    func testInferenceIsUnknownForPartialVersionAndCatalogMismatch() throws {
        let partial = try parse(videoJSON(currentTotal: 3), completeness: .partial)
        XCTAssertEqual(MiniMaxPlanInference.resolve(partial), .unknown(.incompleteRead))

        let wrongVersion = try parse(videoJSON(currentTotal: 3), sourceVersion: "1.0.20")
        XCTAssertEqual(MiniMaxPlanInference.resolve(wrongVersion), .unknown(.sourceVersionMismatch))

        let oldVersionPlus = try parse(
            videoJSON(currentTotal: 0, currentStatus: 3, weeklyTotal: 0, weeklyStatus: 3),
            sourceVersion: "1.0.18"
        )
        XCTAssertEqual(
            MiniMaxPlanInference.resolve(oldVersionPlus),
            .unknown(.sourceVersionMismatch)
        )

        let wrongCatalog = try parse(videoJSON(currentTotal: 3), catalogID: "future-catalog")
        XCTAssertEqual(MiniMaxPlanInference.resolve(wrongCatalog), .unknown(.catalogMismatch))
    }

    func testInferenceRejectsMissingVideoTotalZeroOnlyAndWeeklyEntitlementCounts() throws {
        let generalOnly = videoJSON(currentTotal: 3).replacingOccurrences(
            of: "\"model_name\": \"video\"",
            with: "\"model_name\": \"general\""
        )
        XCTAssertEqual(
            MiniMaxPlanInference.resolve(try parse(generalOnly)),
            .unknown(.videoRowMissing)
        )

        let zeroOnly = try parse(videoJSON(currentTotal: 0, currentStatus: 1, weeklyTotal: 21))
        XCTAssertEqual(
            MiniMaxPlanInference.resolve(zeroOnly),
            .unknown(.unsupportedEntitlementTuple)
        )

        let unknownDaily = try parse(videoJSON(currentTotal: 7, weeklyTotal: 3))
        XCTAssertEqual(
            MiniMaxPlanInference.resolve(unknownDaily),
            .unknown(.unsupportedEntitlementTuple)
        )
    }

    func testInferenceRejectsInvalidCurrentOrWeeklyWindowTuple() throws {
        let valid = videoJSON(currentTotal: 3)
        let invalidPayloads = [
            valid.replacingOccurrences(
                of: "\"current_interval_usage_count\": 0",
                with: "\"current_interval_usage_count\": -1"
            ),
            valid.replacingOccurrences(
                of: "\"current_interval_usage_count\": 0",
                with: "\"current_interval_usage_count\": 4"
            ),
            valid.replacingOccurrences(
                of: "\"current_interval_remaining_percent\": 100",
                with: "\"current_interval_remaining_percent\": 101"
            ),
            valid.replacingOccurrences(
                of: "\"start_time\": 1000",
                with: "\"start_time\": -1"
            ),
            valid.replacingOccurrences(
                of: "\"remains_time\": 5000",
                with: "\"remains_time\": 10001"
            ),
            valid.replacingOccurrences(
                of: "\"current_weekly_usage_count\": 0",
                with: "\"current_weekly_usage_count\": 22"
            ),
            valid.replacingOccurrences(
                of: "\"current_weekly_remaining_percent\": 100",
                with: "\"current_weekly_remaining_percent\": -1"
            ),
            valid.replacingOccurrences(
                of: "\"weekly_end_time\": 21000",
                with: "\"weekly_end_time\": 1000"
            ),
            valid.replacingOccurrences(
                of: "\"weekly_remains_time\": 15000",
                with: "\"weekly_remains_time\": -1"
            )
        ]

        for payload in invalidPayloads {
            XCTAssertEqual(
                MiniMaxPlanInference.resolve(try parse(payload)),
                .unknown(.invalidVideoWindowTuple)
            )
        }
    }

    func testDroppedAndDuplicateRowsMakeInferenceUnknown() throws {
        let withMalformedRow = envelope(
            rows: [
                videoRow(currentTotal: 3, currentStatus: 1, weeklyTotal: 21, weeklyStatus: 1),
                #"{ "model_name": "broken" }"#
            ]
        )
        let dropped = try parse(withMalformedRow)
        XCTAssertEqual(dropped.droppedRowCount, 1)
        XCTAssertEqual(MiniMaxPlanInference.resolve(dropped), .unknown(.droppedRows(1)))

        let duplicateRows = envelope(
            rows: [
                videoRow(currentTotal: 3, currentStatus: 1, weeklyTotal: 21, weeklyStatus: 1),
                videoRow(currentTotal: 3, currentStatus: 1, weeklyTotal: 21, weeklyStatus: 1)
            ]
        )
        let duplicate = try parse(duplicateRows)
        XCTAssertEqual(duplicate.duplicateRowCount, 1)
        XCTAssertEqual(MiniMaxPlanInference.resolve(duplicate), .unknown(.duplicateRows(1)))
    }

    func testMissingTopLevelContractFieldIsTypedFailure() {
        XCTAssertThrowsError(try parse(#"{ "model_remains": [] }"#)) { error in
            XCTAssertEqual(
                error as? ParsedMiniMaxParsingFailure,
                ParsedMiniMaxParsingFailure(
                    code: .missingRequiredField,
                    codingPath: "$.base_resp"
                )
            )
        }
    }

    func testDomainMapperKeepsRawRemainingAndComplementProvenance() throws {
        let data = try MiniMaxDomainMapper.map(
            try parse(receiptJSON),
            source: sourceIdentity
        )
        let product = try XCTUnwrap(data.products.first)
        XCTAssertEqual(product.sourceProductID, "token-plan")
        XCTAssertEqual(product.planLevel?.value, "Max")
        guard case .entitled = product.state.presence else {
            return XCTFail("A complete non-empty successful quota read is entitled evidence")
        }

        let generalCurrent = try XCTUnwrap(product.metrics.first {
            $0.id.sourceIdentity.sourceBucketID == "general.current_interval"
        })
        guard case let .percent(raw) = generalCurrent.value else {
            return XCTFail("General current must retain the raw percentage")
        }
        XCTAssertEqual(raw.sourceValue, 96)
        XCTAssertEqual(raw.sourceDirection, .remaining)
        let rule = MiniMaxDomainMapper.presentationRule(for: generalCurrent)
        XCTAssertEqual(rule.displayDirection, .used)
        XCTAssertEqual(rule.percentDerivation, .complementOfRemaining)
        let resetAt = try XCTUnwrap(generalCurrent.window?.timeEvent?.occursAt)
        XCTAssertEqual(resetAt.timeIntervalSince(fixedNow), 8_288.354, accuracy: 0.000_1)

        let generalWeekly = try XCTUnwrap(product.metrics.first {
            $0.id.sourceIdentity.sourceBucketID == "general.weekly"
        })
        XCTAssertEqual(generalWeekly.value, .unlimited)

        let videoCurrent = try XCTUnwrap(product.metrics.first {
            $0.id.sourceIdentity.sourceBucketID == "video.current_interval"
        })
        guard case let .count(videoCount) = videoCurrent.value else {
            return XCTFail("Video must map the source usage count")
        }
        XCTAssertEqual(videoCount.sourceValue, 0)
        XCTAssertEqual(videoCount.total, 3)
        XCTAssertEqual(videoCount.sourceDirection, .used)
        XCTAssertNotNil(product.metrics.first {
            $0.id.sourceIdentity.sourceBucketID == "video.weekly"
        })
    }

    func testDomainPercentValueBoundariesDoNotClampDecodableInvalidInput() throws {
        for remaining in [-1, 0, 100, 101] {
            let payload = receiptJSON.replacingOccurrences(
                of: "\"current_interval_remaining_percent\": 96",
                with: "\"current_interval_remaining_percent\": \(remaining)"
            )
            let snapshot = try parse(payload)
            let general = try XCTUnwrap(snapshot.uniqueModel(named: "general"))
            XCTAssertEqual(general.current.remainingPercent, Decimal(remaining))
            XCTAssertEqual(snapshot.droppedRowCount, 0, "Numeric validity is not JSON decodability")
            let data = try MiniMaxDomainMapper.map(snapshot, source: sourceIdentity)
            let metric = try XCTUnwrap(data.products.first?.metrics.first {
                $0.id.sourceIdentity.sourceBucketID == "general.current_interval"
            })
            if (0...100).contains(remaining) {
                XCTAssertEqual(metric.value, .percent(DirectedPercent(
                    sourceValue: Decimal(remaining), sourceDirection: .remaining
                )))
            } else {
                XCTAssertEqual(metric.value, .unavailable(reason: .invalidSourceValue(field: "remaining_percent")))
            }
        }
    }

    func testDomainCountValueBoundariesRejectNegativeAndContradictoryPairs() throws {
        let pairs: [(used: Int, total: Int)] = [(0, 0), (0, 3), (3, 3), (-1, 3), (4, 3), (0, -1)]
        for pair in pairs {
            let payload = videoJSON(currentTotal: pair.total).replacingOccurrences(
                of: "\"current_interval_usage_count\": 0",
                with: "\"current_interval_usage_count\": \(pair.used)"
            )
            let snapshot = try parse(payload)
            let video = try XCTUnwrap(snapshot.uniqueModel(named: "video"))
            XCTAssertEqual(video.current.usageCount, Decimal(pair.used))
            XCTAssertEqual(video.current.totalCount, Decimal(pair.total))
            XCTAssertEqual(snapshot.droppedRowCount, 0)
            let data = try MiniMaxDomainMapper.map(snapshot, source: sourceIdentity)
            let metric = try XCTUnwrap(data.products.first?.metrics.first {
                $0.id.sourceIdentity.sourceBucketID == "video.current_interval"
            })
            if pair.used >= 0, pair.total >= 0, pair.used <= pair.total {
                XCTAssertEqual(metric.value, .count(DirectedCount(
                    sourceValue: Decimal(pair.used), total: Decimal(pair.total),
                    sourceDirection: .used, unit: "count"
                )))
            } else {
                XCTAssertEqual(metric.value, .unavailable(reason: .invalidSourceValue(field: "usage_count")))
            }
        }
    }

    func testParserPreservesWeeklyBoostEvidenceAndRawRemainingValues() throws {
        let payload = receiptJSON
            .replacingOccurrences(
                of: "\"current_interval_remaining_percent\": 96",
                with: "\"weekly_boost_permille\": 250, \"current_interval_remaining_percent\": 101"
            )
            .replacingOccurrences(
                of: "\"current_weekly_remaining_percent\": 100",
                with: "\"current_weekly_remaining_percent\": 125"
            )
        let snapshot = try parse(payload)
        let general = try XCTUnwrap(snapshot.uniqueModel(named: "general"))
        XCTAssertEqual(general.weeklyBoostPermille, 250)
        XCTAssertEqual(general.current.remainingPercent, 101)
        XCTAssertEqual(general.weekly.remainingPercent, 125)
        XCTAssertEqual(snapshot.droppedRowCount, 0)
    }

    func testSemanticInvalidReadRetainsLastGoodWhileValidSiblingsAdvance() async throws {
        guard case let .success(good) = await quotaRead(numericJSON(), at: fixedNow) else {
            return XCTFail("Expected an initial successful quota read")
        }
        let state = ProviderReducer.reduce(
            state: providerState(lastGood: nil), event: .refreshSucceeded(good), now: fixedNow
        )
        try await assertInvalidReadSequence(state: state, good: good)
    }

    func testSemanticInvalidReadRetainsCacheLoadedMetricsWithoutAdapterHistory() async throws {
        guard case let .success(good) = await quotaRead(numericJSON(), at: fixedNow) else {
            return XCTFail("Expected valid cache input")
        }
        let state = ProviderReducer.reduce(
            state: providerState(lastGood: nil), event: .cacheLoaded(good),
            now: fixedNow.addingTimeInterval(10)
        )
        try await assertInvalidReadSequence(state: state, good: good)
    }

    func testSemanticInvalidReadWithoutHistoryOrAfterClearNeverInventsSuccess() async throws {
        guard case let .success(good) = await quotaRead(numericJSON(), at: fixedNow) else {
            return XCTFail("Expected an initial successful quota read")
        }
        let cleared = ProviderReducer.reduce(
            state: providerState(lastGood: good), event: .cacheCleared,
            now: fixedNow.addingTimeInterval(30)
        )
        for initial in [providerState(lastGood: nil), cleared] {
            var state = initial
            for offset in [60.0, 120.0] {
                let date = fixedNow.addingTimeInterval(offset)
                guard case let .partial(patch, failure) = await quotaRead(
                    numericJSON(currentRemaining: "101"), at: date
                ) else { return XCTFail("Invalid values must not become successful without history") }
                state = ProviderReducer.reduce(
                    state: state, event: .refreshPartiallySucceeded(patch, failure), now: date
                )
                let product = try XCTUnwrap(state.lastGood?.products.first)
                let invalid = try XCTUnwrap(product.metrics.first {
                    $0.id.sourceIdentity.sourceBucketID == "general.current_interval"
                })
                XCTAssertEqual(invalid.value, .unavailable(reason: .invalidSourceValue(field: "remaining_percent")))
                XCTAssertEqual(invalid.state.freshness, .unknown)
                XCTAssertNil(invalid.state.lastSuccessAt)
                XCTAssertNil(invalid.state.refresh.lastSuccessAt)
                XCTAssertEqual(invalid.state.failure?.code, .schemaMismatch)
                XCTAssertNil(product.state.lastSuccessAt)
                for metric in product.metrics where metric.id != invalid.id {
                    XCTAssertEqual(metric.state.freshness, .fresh(asOf: date))
                }
            }
        }
    }

    func testInvalidFiniteWindowNumbersArePartialAndNeverAllowInference() async throws {
        let samples: [(String, String)] = [
            (numericJSON(currentRemaining: "-1"), "general.current_interval"),
            (numericJSON(currentRemaining: "101"), "general.current_interval"),
            (numericJSON(weeklyRemaining: "-1"), "general.weekly"),
            (numericJSON(weeklyRemaining: "101"), "general.weekly"),
            (numericJSON(videoUsed: "-1"), "video.current_interval"),
            (numericJSON(videoUsed: "4"), "video.current_interval"),
            (numericJSON().replacingOccurrences(of: "\"current_interval_total_count\": 3", with: "\"current_interval_total_count\": -1"), "video.current_interval"),
            (numericJSON().replacingOccurrences(of: "\"current_weekly_total_count\": 21", with: "\"current_weekly_total_count\": -1"), "video.weekly"),
            (numericJSON().replacingOccurrences(of: "\"current_weekly_usage_count\": 0", with: "\"current_weekly_usage_count\": 22"), "video.weekly"),
            (numericJSON().replacingOccurrences(of: "\"current_interval_total_count\": 0", with: "\"current_interval_total_count\": -1"), "general.current_interval")
        ]
        for (json, bucket) in samples {
            let snapshot = try parse(json)
            XCTAssertEqual(snapshot.effectiveCompleteness, .partial, bucket)
            XCTAssertNil(MiniMaxPlanInference.resolve(snapshot).observation, bucket)
            guard case let .partial(patch, failure) = await quotaRead(json, at: fixedNow) else {
                return XCTFail("Invalid \(bucket) must produce a partial read")
            }
            XCTAssertEqual(failure.code, .schemaMismatch)
            XCTAssertEqual(failure.retryClass, .backoff)
            let product = try XCTUnwrap(patch.updatedProducts.first)
            let metric = try XCTUnwrap(product.metrics.first { $0.id.sourceIdentity.sourceBucketID == bucket })
            guard case .unavailable = metric.value else { return XCTFail("An invalid number is not quota") }
            XCTAssertEqual(metric.state.freshness, .unknown)
            XCTAssertNil(metric.state.lastSuccessAt)
            XCTAssertNotNil(metric.state.failure)
            XCTAssertNotNil(product.state.failure)
            XCTAssertNil(product.planLevel)
        }
    }

    func testWeeklyBoostCannotAuthorizeCurrentOverflowOrPretendSupportedProjection() async throws {
        for boost in ["0", "250", "-1"] {
            let json = numericJSON(currentRemaining: "101", weeklyRemaining: "125", weeklyBoost: boost)
            let snapshot = try parse(json)
            XCTAssertEqual(snapshot.uniqueModel(named: "general")?.weeklyBoostPermille, Decimal(string: boost))
            XCTAssertEqual(snapshot.effectiveCompleteness, .partial)
            guard case let .success(good) = await quotaRead(numericJSON(), at: fixedNow) else {
                return XCTFail("Expected prior finite data")
            }
            let date = fixedNow.addingTimeInterval(60)
            guard case let .partial(patch, failure) = await quotaRead(json, at: date) else {
                return XCTFail("Unrepresentable boost must not claim success")
            }
            let product = try XCTUnwrap(patch.updatedProducts.first)
            let current = try XCTUnwrap(product.metrics.first { $0.id.sourceIdentity.sourceBucketID == "general.current_interval" })
            let weekly = try XCTUnwrap(product.metrics.first { $0.id.sourceIdentity.sourceBucketID == "general.weekly" })
            XCTAssertEqual(current.value, .unavailable(reason: .invalidSourceValue(field: "remaining_percent")))
            if boost == "250" {
                XCTAssertEqual(weekly.value, .unavailable(reason: .unsupportedSemantics(sourceKind: "minimax.weekly.boost")))
            }
            XCTAssertNotNil(weekly.state.failure)
            let merged = ProviderReducer.reduce(
                state: providerState(lastGood: good), event: .refreshPartiallySucceeded(patch, failure), now: date
            )
            for metric in try XCTUnwrap(merged.lastGood?.products.first).metrics where metric.sourceLabel == "general" {
                XCTAssertEqual(metric.value, good.products.first?.metrics.first { $0.id == metric.id }?.value)
                XCTAssertEqual(metric.state.freshness, .stale(asOf: fixedNow, evaluatedAt: date))
                XCTAssertNotNil(metric.state.failure)
            }
        }
        guard case .success = await quotaRead(numericJSON(weeklyBoost: "250"), at: fixedNow) else {
            return XCTFail("Boost evidence alone must not invalidate an otherwise representable quota")
        }
    }

    func testUnknownWindowSemanticsArePartialNotFreshUnavailable() async throws {
        let samples = [
            numericJSON().replacingOccurrences(of: "\"current_interval_status\": 1", with: "\"current_interval_status\": 99"),
            numericJSON().replacingOccurrences(of: "\"model_name\": \"general\"", with: "\"model_name\": \"future\"")
        ]
        for json in samples {
            guard case let .partial(patch, _) = await quotaRead(json, at: fixedNow) else {
                return XCTFail("Unknown model or status must not yield fresh unavailable")
            }
            for metric in patch.updatedProducts.flatMap(\.metrics) {
                if case .unavailable = metric.value {
                    XCTAssertNotNil(metric.state.failure)
                    XCTAssertEqual(metric.state.freshness, .unknown)
                    XCTAssertNil(metric.state.lastSuccessAt)
                }
            }
        }
    }

    func testDuplicateRowsKeepTheExistingWholeProductRetentionContract() async throws {
        guard case let .success(good) = await quotaRead(numericJSON(), at: fixedNow) else {
            return XCTFail("Expected previous good data")
        }
        let duplicate = videoRow(currentTotal: 3, currentStatus: 1, weeklyTotal: 21, weeklyStatus: 1)
        let date = fixedNow.addingTimeInterval(60)
        guard case let .partial(patch, failure) = await quotaRead(
            envelope(rows: [duplicate, duplicate]), at: date
        ) else { return XCTFail("Duplicate model identities must be partial") }
        XCTAssertTrue(patch.updatedProducts.isEmpty)
        guard case .mutate = try XCTUnwrap(patch.productMutations.first) else {
            return XCTFail("A duplicate row must not authoritatively replace the metric set")
        }
        let after = ProviderReducer.reduce(
            state: providerState(lastGood: good), event: .refreshPartiallySucceeded(patch, failure), now: date
        )
        let retained = try XCTUnwrap(after.lastGood?.products.first)
        XCTAssertEqual(retained.metrics.map(\.value), good.products.first?.metrics.map(\.value))
        XCTAssertTrue(retained.metrics.allSatisfy { $0.state.freshness == .stale(asOf: fixedNow, evaluatedAt: date) })
        XCTAssertNil(retained.planLevel)
    }

    func testZeroHundredAndExplicitUnlimitedRemainSuccessful() async throws {
        for remaining in ["0", "100"] {
            guard case let .success(data) = await quotaRead(
                numericJSON(currentRemaining: remaining, weeklyRemaining: remaining), at: fixedNow
            ) else { return XCTFail("Finite boundary \(remaining) must remain valid") }
            XCTAssertTrue(data.products.flatMap(\.metrics).allSatisfy { $0.state.failure == nil })
        }
        guard case let .success(data) = await quotaRead(
            numericJSON(currentRemaining: "101", generalStatus: 3), at: fixedNow
        ) else { return XCTFail("Explicit unlimited must not be judged as a finite percentage") }
        let current = try XCTUnwrap(data.products.first?.metrics.first)
        XCTAssertEqual(current.value, .unlimited)
        XCTAssertEqual(current.state.freshness, .fresh(asOf: fixedNow))
        XCTAssertNil(current.state.failure)
    }

    func testNonfiniteJSONCannotBecomeSuccessfulQuota() async throws {
        for invalid in ["NaN", "Infinity", "1e9999", "\"NaN\""] {
            switch await quotaRead(numericJSON(currentRemaining: invalid), at: fixedNow) {
            case let .partial(_, failure), let .failure(failure):
                XCTAssertEqual(failure.code, .schemaMismatch)
            case .success, .successPatch:
                XCTFail("Nonfinite JSON must not yield success: \(invalid)")
            }
        }
    }

    func testNonfiniteParsedNumbersCannotBypassSemanticValidation() throws {
        let valid = try parse(numericJSON())
        let general = try XCTUnwrap(valid.uniqueModel(named: "general"))
        let window = general.current
        for field in ["remaining", "usage", "total"] {
            let invalid = ParsedMiniMaxQuotaWindow(
                startTimeMilliseconds: window.startTimeMilliseconds,
                endTimeMilliseconds: window.endTimeMilliseconds,
                remainsTimeMilliseconds: window.remainsTimeMilliseconds,
                totalCount: field == "total" ? .nan : window.totalCount,
                usageCount: field == "usage" ? .nan : window.usageCount,
                remainingPercent: field == "remaining" ? .nan : window.remainingPercent,
                status: 1
            )
            let snapshot = ParsedMiniMaxQuotaSnapshot(
                baseStatusCode: 0,
                models: [ParsedMiniMaxModelQuota(
                    modelName: "general", current: invalid, weekly: general.weekly, weeklyBoostPermille: nil
                ), try XCTUnwrap(valid.uniqueModel(named: "video"))],
                droppedRowCount: 0, duplicateRowCount: 0, context: valid.context
            )
            XCTAssertEqual(snapshot.effectiveCompleteness, .partial)
            XCTAssertNil(MiniMaxPlanInference.resolve(snapshot).observation)
            let metric = try XCTUnwrap(MiniMaxDomainMapper.map(snapshot, source: sourceIdentity).products.first?.metrics.first)
            XCTAssertEqual(metric.state.freshness, .unknown)
            XCTAssertEqual(metric.state.failure?.code, .schemaMismatch)
        }
    }

    private func assertInvalidReadSequence(state initial: ProviderState, good: ProviderQuotaData) async throws {
        var state = initial
        let original = try XCTUnwrap(good.products.first?.metrics.first {
            $0.id.sourceIdentity.sourceBucketID == "general.current_interval"
        })
        for offset in [60.0, 120.0] {
            let attemptedAt = fixedNow.addingTimeInterval(offset)
            guard case let .partial(patch, failure) = await quotaRead(
                numericJSON(currentRemaining: "101", weeklyRemaining: "80", videoUsed: "2"),
                at: attemptedAt
            ) else {
                return XCTFail("A decodable invalid percent must be partial, not successful")
            }
            XCTAssertEqual(failure.code, .schemaMismatch)
            XCTAssertEqual(failure.retryClass, .backoff)
            state = ProviderReducer.reduce(
                state: state, event: .refreshPartiallySucceeded(patch, failure), now: attemptedAt
            )
            let product = try XCTUnwrap(state.lastGood?.products.first)
            let retained = try XCTUnwrap(product.metrics.first { $0.id == original.id })
            XCTAssertEqual(retained.value, original.value)
            XCTAssertEqual(retained.window, original.window)
            XCTAssertEqual(retained.provenance, original.provenance)
            XCTAssertEqual(retained.sourceStatus, original.sourceStatus)
            XCTAssertEqual(retained.state.lastSuccessAt, fixedNow)
            XCTAssertEqual(retained.state.refresh.lastSuccessAt, fixedNow)
            XCTAssertEqual(retained.state.lastAttemptAt, attemptedAt)
            XCTAssertEqual(retained.state.refresh.lastAttemptAt, attemptedAt)
            XCTAssertEqual(retained.state.freshness, .stale(asOf: fixedNow, evaluatedAt: attemptedAt))
            XCTAssertEqual(retained.state.failure?.code, .schemaMismatch)
            XCTAssertEqual(state.refresh.lastSuccessAt, initial.refresh.lastSuccessAt)
            XCTAssertNotNil(state.failure)
            XCTAssertNotNil(product.state.failure)
            XCTAssertNil(product.planLevel)
            let weekly = try XCTUnwrap(product.metrics.first {
                $0.id.sourceIdentity.sourceBucketID == "general.weekly"
            })
            XCTAssertEqual(weekly.value, .percent(DirectedPercent(sourceValue: 80, sourceDirection: .remaining)))
            let video = try XCTUnwrap(product.metrics.first {
                $0.id.sourceIdentity.sourceBucketID == "video.current_interval"
            })
            XCTAssertEqual(video.value, .count(DirectedCount(sourceValue: 2, total: 3, sourceDirection: .used, unit: "count")))
            for metric in product.metrics where metric.id != original.id {
                XCTAssertEqual(metric.state.freshness, .fresh(asOf: attemptedAt))
                XCTAssertEqual(metric.state.lastSuccessAt, attemptedAt)
                XCTAssertNil(metric.state.failure)
            }
        }
        let recoveredAt = fixedNow.addingTimeInterval(180)
        guard case let .success(recovered) = await quotaRead(numericJSON(currentRemaining: "70"), at: recoveredAt) else {
            return XCTFail("A later valid snapshot must recover normally")
        }
        state = ProviderReducer.reduce(state: state, event: .refreshSucceeded(recovered), now: recoveredAt)
        XCTAssertNil(state.failure)
        XCTAssertEqual(state.refresh.lastSuccessAt, recoveredAt)
        XCTAssertEqual(state.lastGood, recovered)
        XCTAssertEqual(recovered.products.first?.planLevel?.value, "Max")
    }

    private func quotaRead(_ json: String, at date: Date) async -> ProviderReadResult {
        // A fresh adapter on every read proves that last-good belongs to Core.
        let adapter = MiniMaxProviderAdapter(
            processClient: MiniMaxFakeChildProcessClient(results: [.success(output(json))]),
            executableURL: URL(fileURLWithPath: "/fixture/mmx"), now: { date }
        )
        return await adapter.read(scope: .provider)
    }

    private func numericJSON(
        currentRemaining: String = "50", weeklyRemaining: String = "60", videoUsed: String = "0",
        generalStatus: Int = 1, weeklyBoost: String? = nil
    ) -> String {
        var general = videoRow(currentTotal: 0, currentStatus: generalStatus, weeklyTotal: 0, weeklyStatus: 1)
            .replacingOccurrences(of: "\"model_name\": \"video\"", with: "\"model_name\": \"general\"")
            .replacingOccurrences(of: "\"current_interval_remaining_percent\": 100", with: "\"current_interval_remaining_percent\": \(currentRemaining)")
            .replacingOccurrences(of: "\"current_weekly_remaining_percent\": 100", with: "\"current_weekly_remaining_percent\": \(weeklyRemaining)")
        if let weeklyBoost {
            general = general.replacingOccurrences(
                of: "\"model_name\": \"general\"",
                with: "\"model_name\": \"general\", \"weekly_boost_permille\": \(weeklyBoost)"
            )
        }
        let video = videoRow(currentTotal: 3, currentStatus: 1, weeklyTotal: 21, weeklyStatus: 1)
            .replacingOccurrences(of: "\"current_interval_usage_count\": 0", with: "\"current_interval_usage_count\": \(videoUsed)")
        return envelope(rows: [general, video])
    }

    func testPartialDomainMappingDoesNotInferPlanOrPresence() throws {
        let partial = try parse(receiptJSON, completeness: .partial)
        let data = try MiniMaxDomainMapper.map(partial, source: sourceIdentity)
        let product = try XCTUnwrap(data.products.first)

        XCTAssertNil(product.planLevel)
        XCTAssertEqual(product.state.presence, .unknown)
        XCTAssertEqual(product.state.freshness, .unknown)
    }

    func testOneShotAdapterUsesQuotaAndOfficialOAuthContractsWithInjectedFake() async throws {
        let opaqueLoginOutput = "LOGIN FAILED user@example.invalid /Users/private"
        let process = MiniMaxFakeChildProcessClient(results: [
            .success(output(receiptJSON)),
            .success(
                ChildProcessOutput(
                    termination: .exited(code: 0),
                    standardOutput: Data(opaqueLoginOutput.utf8),
                    redactedStandardError: Data("fatal-looking text".utf8)
                )
            )
        ])
        let executableURL = URL(fileURLWithPath: "/opt/usage-butler/bin/mmx")
        let environment = ["LANG": "en_US.UTF-8", "HOME": "/safe-home"]
        let now = fixedNow
        let adapter = MiniMaxProviderAdapter(
            processClient: process,
            executableURL: executableURL,
            environment: environment,
            now: { now }
        )

        let result = await adapter.read(scope: .provider)
        guard case let .success(data) = result else {
            return XCTFail("Expected a complete fake read")
        }
        let product = try XCTUnwrap(data.products.first)
        let plan = try XCTUnwrap(product.planLevel)
        XCTAssertEqual(plan.value, "Max")
        guard case let .inferred(ruleID, catalogID, sourceVersion, evidenceFields) = plan.origin else {
            return XCTFail("An all-unverified production read must use the approved inference rule")
        }
        XCTAssertEqual(ruleID, "minimax-video-daily-v1")
        XCTAssertEqual(catalogID, "minimax-token-plan-zh-cn-2026-08-10")
        XCTAssertEqual(sourceVersion, "1.0.19")
        XCTAssertEqual(
            evidenceFields,
            ["model_remains[video].current_interval_total_count"]
        )
        XCTAssertEqual(product.metrics.count, 4)
        XCTAssertEqual(data.source.cliVersion, "runtime-unverified")
        let requests = await process.capturedRequests()
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests[0].executableURL, executableURL)
        XCTAssertEqual(requests[0].arguments, ["quota", "show", "--output", "json"])
        XCTAssertEqual(requests[0].environment, environment)
        XCTAssertNil(requests[0].standardInput)
        XCTAssertEqual(requests[0].limits, MiniMaxProviderAdapter.defaultLimits)

        let login = await adapter.login(method: .oauth)
        XCTAssertEqual(login, .success, "Only exit status, never output text, decides success")
        let requestsAfterLogin = await process.capturedRequests()
        XCTAssertEqual(requestsAfterLogin.count, 2)
        XCTAssertEqual(requestsAfterLogin[1].executableURL, executableURL)
        XCTAssertEqual(requestsAfterLogin[1].arguments, ["auth", "login", "--recommend"])
        XCTAssertEqual(requestsAfterLogin[1].environment, environment)
        XCTAssertNil(requestsAfterLogin[1].standardInput)
        XCTAssertEqual(
            requestsAfterLogin[1].limits,
            ChildProcessLimits(
                timeout: .seconds(300),
                standardOutputByteLimit: 65_536,
                standardErrorByteLimit: 65_536,
                lineLimit: 1_000
            )
        )
        XCTAssertEqual(adapter.capabilities.loginMethod, .oauth)
        let diagnostic = await adapter.diagnosticSnapshot()
        XCTAssertEqual(diagnostic.safeFields["cliVersion"], "runtime-unverified")
        XCTAssertFalse(diagnostic.safeFields.values.joined().contains(opaqueLoginOutput))
        XCTAssertFalse(diagnostic.diagnosticCode.contains(opaqueLoginOutput))
    }

    func testApprovedEntitlementRuleDoesNotRewriteUnverifiedParserContext() throws {
        let snapshot = try MiniMaxQuotaParser.parse(
            Data(receiptJSON.utf8),
            context: ParsedMiniMaxParsingContext(
                completeness: .completeSuccess,
                sourceVersion: "runtime-unverified",
                region: "runtime-unverified",
                catalogID: "runtime-unverified",
                contractVersion: "runtime-unverified",
                fetchedAt: fixedNow
            )
        )

        XCTAssertEqual(snapshot.context.sourceVersion, "runtime-unverified")
        XCTAssertEqual(snapshot.context.region, "runtime-unverified")
        XCTAssertEqual(snapshot.context.catalogID, "runtime-unverified")
        XCTAssertEqual(snapshot.context.contractVersion, "runtime-unverified")

        let data = try MiniMaxDomainMapper.map(
            snapshot,
            source: ProviderSourceIdentity(
                providerID: .miniMax,
                adapterID: MiniMaxDomainContract.adapterID,
                executableIdentity: MiniMaxDomainContract.executableIdentity,
                cliVersion: "runtime-unverified",
                schemaVersion: MiniMaxDomainContract.schemaVersion,
                contractVersion: MiniMaxDomainContract.quotaContractVersion
            ),
            planInferencePolicy: .approvedEntitlementRule(.approvedV1)
        )
        let plan = try XCTUnwrap(data.products.first?.planLevel)
        XCTAssertEqual(data.source.cliVersion, "runtime-unverified")
        guard case let .inferred(_, _, sourceVersion, _) = plan.origin else {
            return XCTFail("The badge must retain inferred provenance")
        }
        XCTAssertEqual(sourceVersion, "1.0.19", "This is the rule basis, not a runtime read")
    }

    func testOneShotAdapterEnablesPlanInferenceWithFullyVerifiedRuntimeProvenance() async throws {
        let process = MiniMaxFakeChildProcessClient(results: [
            .success(output(receiptJSON))
        ])
        let now = fixedNow
        let adapter = MiniMaxProviderAdapter(
            processClient: process,
            executableURL: URL(fileURLWithPath: "/opt/usage-butler/bin/mmx"),
            cliVersion: .runtimeRead("1.0.19", operationID: "test.mmx.version.read"),
            region: .runtimeRead("cn", operationID: "test.mmx.region.read"),
            catalogID: .runtimeRead(
                "minimax-token-plan-zh-cn-2026-08-10",
                operationID: "test.mmx.catalog.read"
            ),
            now: { now }
        )

        guard case let .success(data) = await adapter.read(scope: .provider) else {
            return XCTFail("Expected a complete fake read")
        }
        let product = try XCTUnwrap(data.products.first)
        XCTAssertEqual(product.planLevel?.value, "Max")
        XCTAssertEqual(data.source.cliVersion, "1.0.19")
    }

    func testOneShotAdapterRequiresVerifiedProvenanceForEveryInferenceField() async throws {
        let verifiedVersion = RuntimeContractFieldObservation.runtimeRead(
            "1.0.19",
            operationID: "test.mmx.version.read"
        )
        let verifiedRegion = RuntimeContractFieldObservation.runtimeRead(
            "cn",
            operationID: "test.mmx.region.read"
        )
        let verifiedCatalog = RuntimeContractFieldObservation.runtimeRead(
            "minimax-token-plan-zh-cn-2026-08-10",
            operationID: "test.mmx.catalog.read"
        )
        let cases: [(
            name: String,
            version: RuntimeContractFieldObservation,
            region: RuntimeContractFieldObservation,
            catalog: RuntimeContractFieldObservation
        )] = [
            ("version", .unverified, verifiedRegion, verifiedCatalog),
            ("region", verifiedVersion, .unverified, verifiedCatalog),
            ("catalog", verifiedVersion, verifiedRegion, .unverified)
        ]

        for testCase in cases {
            let process = MiniMaxFakeChildProcessClient(results: [
                .success(output(receiptJSON))
            ])
            let now = fixedNow
            let adapter = MiniMaxProviderAdapter(
                processClient: process,
                executableURL: URL(fileURLWithPath: "/opt/usage-butler/bin/mmx"),
                cliVersion: testCase.version,
                region: testCase.region,
                catalogID: testCase.catalog,
                now: { now }
            )

            guard case let .success(data) = await adapter.read(scope: .provider) else {
                return XCTFail("Expected schema-valid quota data for missing \(testCase.name) provenance")
            }
            let product = try XCTUnwrap(data.products.first)
            XCTAssertNil(product.planLevel, "Missing \(testCase.name) provenance must block inference")
            XCTAssertEqual(
                product.metrics.count,
                4,
                "Missing \(testCase.name) provenance must not block quota parsing"
            )
        }
    }

    func testOneShotAdapterRejectsFullyVerifiedContractMismatch() async throws {
        let now = fixedNow
        let process = MiniMaxFakeChildProcessClient(results: [
            .success(output(receiptJSON))
        ])
        let adapter = MiniMaxProviderAdapter(
            processClient: process,
            executableURL: URL(fileURLWithPath: "/opt/usage-butler/bin/mmx"),
            cliVersion: .runtimeRead("1.0.20", operationID: "test.mmx.version.read"),
            region: .runtimeRead("cn", operationID: "test.mmx.region.read"),
            catalogID: .runtimeRead(
                "minimax-token-plan-zh-cn-2026-08-10",
                operationID: "test.mmx.catalog.read"
            ),
            now: { now }
        )

        guard case let .success(data) = await adapter.read(scope: .provider) else {
            return XCTFail("A tier mismatch must not block authoritative quota data")
        }
        XCTAssertNil(data.products.first?.planLevel)
        XCTAssertEqual(data.source.cliVersion, "1.0.20")
    }

    func testOfficialOAuthLoginRejectsUnsupportedMethodWithoutStartingProcess() async {
        let process = MiniMaxFakeChildProcessClient(results: [])
        let adapter = MiniMaxProviderAdapter(
            processClient: process,
            executableURL: URL(fileURLWithPath: "/opt/usage-butler/bin/mmx")
        )

        guard case let .failure(failure) = await adapter.login(method: .sso) else {
            return XCTFail("MiniMax must reject every login method except OAuth")
        }
        XCTAssertEqual(failure.code, .protocolViolation)
        XCTAssertEqual(failure.diagnosticCode, "minimax.adapter.login.unsupported_method")
        let requests = await process.capturedRequests()
        XCTAssertTrue(requests.isEmpty)
    }

    func testOfficialOAuthLoginUsesExitStatusWithoutGuessingFromOutput() async {
        let output = ChildProcessOutput(
            termination: .exited(code: 23),
            standardOutput: Data("success authenticated user@example.invalid".utf8),
            redactedStandardError: Data("token redacted".utf8)
        )
        let process = MiniMaxFakeChildProcessClient(results: [.success(output)])
        let adapter = MiniMaxProviderAdapter(
            processClient: process,
            executableURL: URL(fileURLWithPath: "/opt/usage-butler/bin/mmx")
        )

        guard case let .failure(failure) = await adapter.login(method: .oauth) else {
            return XCTFail("A nonzero exit must fail regardless of output text")
        }
        XCTAssertEqual(failure.code, .processFailed)
        XCTAssertEqual(failure.retryClass, .backoff)
        XCTAssertEqual(failure.diagnosticCode, "minimax.adapter.login.process.nonzero_exit")
        XCTAssertEqual(failure.recovery, .retry)
        XCTAssertFalse(failure.diagnosticCode.contains("user@example.invalid"))
    }

    func testOfficialOAuthLoginSanitizesTypedChildFailure() async {
        let secretDiagnostic = "child.timeout.user@example.invalid./Users/private"
        let childFailure = ProviderFailure(
            code: .timedOut,
            retryClass: .backoff,
            userMessageKey: "provider.failure.timed_out",
            diagnosticCode: secretDiagnostic,
            recovery: .retry
        )
        let process = MiniMaxFakeChildProcessClient(results: [.failure(childFailure)])
        let adapter = MiniMaxProviderAdapter(
            processClient: process,
            executableURL: URL(fileURLWithPath: "/opt/usage-butler/bin/mmx")
        )

        guard case let .failure(failure) = await adapter.login(method: .oauth) else {
            return XCTFail("A typed child failure must stay a typed login failure")
        }
        XCTAssertEqual(failure.code, .timedOut)
        XCTAssertEqual(failure.retryClass, .backoff)
        XCTAssertEqual(failure.userMessageKey, "provider.failure.timed_out")
        XCTAssertEqual(failure.diagnosticCode, "minimax.adapter.login.child.timedOut")
        XCTAssertEqual(failure.recovery, .retry)
        XCTAssertFalse(failure.diagnosticCode.contains(secretDiagnostic))
        let diagnostic = await adapter.diagnosticSnapshot()
        XCTAssertFalse(diagnostic.safeFields.values.joined().contains(secretDiagnostic))
    }

    func testOfficialOAuthLoginTaskCancellationReturnsCancelled() async {
        let process = MiniMaxSuspendingChildProcessClient()
        let adapter = MiniMaxProviderAdapter(
            processClient: process,
            executableURL: URL(fileURLWithPath: "/opt/usage-butler/bin/mmx")
        )
        let loginTask = Task { await adapter.login(method: .oauth) }

        let didStart = await process.waitForRequest()
        XCTAssertTrue(didStart)
        loginTask.cancel()
        let result = await loginTask.value
        XCTAssertEqual(result, .cancelled)

        await adapter.shutdown()
    }

    func testShutdownCancelsInFlightOfficialOAuthLogin() async {
        let process = MiniMaxSuspendingChildProcessClient()
        let adapter = MiniMaxProviderAdapter(
            processClient: process,
            executableURL: URL(fileURLWithPath: "/opt/usage-butler/bin/mmx")
        )
        let loginTask = Task { await adapter.login(method: .oauth) }

        let didStart = await process.waitForRequest()
        XCTAssertTrue(didStart)
        await adapter.shutdown()

        let result = await loginTask.value
        XCTAssertEqual(result, .cancelled)
        let requests = await process.capturedRequests()
        XCTAssertEqual(requests.count, 1)
        let shutdownCallCount = await process.shutdownCallCount()
        XCTAssertEqual(shutdownCallCount, 1)

        guard case let .failure(failure) = await adapter.login(method: .oauth) else {
            return XCTFail("Shutdown must reject a later login")
        }
        XCTAssertEqual(failure.code, .shutdown)
        let requestCountAfterRejectedLogin = await process.capturedRequests().count
        XCTAssertEqual(requestCountAfterRejectedLogin, 1)
    }

    func testPartialAdapterClearsInferenceAndMutatesOnlyHistoricalProductState() async throws {
        let partialJSON = envelope(rows: [
            videoRow(currentTotal: 3, currentStatus: 1, weeklyTotal: 21, weeklyStatus: 1),
            #"{ "model_name": "broken" }"#
        ])
        let process = MiniMaxFakeChildProcessClient(results: [
            .success(output(partialJSON)),
            .success(output(""))
        ])
        let now = fixedNow
        let adapter = MiniMaxProviderAdapter(
            processClient: process,
            executableURL: URL(fileURLWithPath: "/private/secret/bin/mmx"),
            now: { now }
        )

        let partial = await adapter.read(scope: .provider)
        guard case let .partial(patch, failure) = partial else {
            return XCTFail("A dropped row must be partial")
        }
        XCTAssertTrue(patch.updatedProducts.isEmpty)
        XCTAssertEqual(failure.code, .schemaMismatch)
        XCTAssertEqual(
            failure.retryClass,
            .backoff,
            "A MiniMax partial schema read must back off and retry, not suspend automatic refresh"
        )

        let productMutation = try XCTUnwrap(patch.productMutations.first)
        guard case let .mutate(productID, mutation) = productMutation else {
            return XCTFail("A partial MiniMax read must retain the Token Plan payload")
        }
        XCTAssertEqual(productID.sourceProductID, MiniMaxDomainContract.sourceProductID)
        XCTAssertEqual(mutation.planLevel, .clearCurrentInferred)
        XCTAssertEqual(mutation.state.presence, .retain)
        XCTAssertEqual(mutation.state.freshness, .retain)
        guard case let .replace(currentFailure) = mutation.state.failure else {
            return XCTFail("The current partial-schema failure must be attached to the Product")
        }
        XCTAssertEqual(currentFailure?.code, .schemaMismatch)

        let failureAt = fixedNow.addingTimeInterval(60)
        let withoutHistory = ProviderReducer.reduce(
            state: providerState(lastGood: nil),
            event: .refreshPartiallySucceeded(patch, failure),
            now: failureAt
        )
        XCTAssertTrue(
            withoutHistory.lastGood?.products.isEmpty == true,
            "A mutation must not synthesize a Token Plan payload without history"
        )

        let historical = try MiniMaxDomainMapper.map(
            try parse(receiptJSON),
            source: sourceIdentity
        )
        let historicalProduct = try XCTUnwrap(historical.products.first)
        XCTAssertEqual(historicalProduct.planLevel?.value, "Max")
        let withHistory = ProviderReducer.reduce(
            state: providerState(lastGood: historical),
            event: .refreshPartiallySucceeded(patch, failure),
            now: failureAt
        )
        let retainedProduct = try XCTUnwrap(withHistory.lastGood?.products.first)
        XCTAssertNil(retainedProduct.planLevel)
        XCTAssertEqual(retainedProduct.metrics.map(\.id), historicalProduct.metrics.map(\.id))
        XCTAssertEqual(
            retainedProduct.metrics.map(\.value),
            historicalProduct.metrics.map(\.value)
        )
        XCTAssertEqual(
            retainedProduct.metrics.map(\.provenance),
            historicalProduct.metrics.map(\.provenance)
        )
        XCTAssertEqual(retainedProduct.state.presence, historicalProduct.state.presence)
        XCTAssertEqual(retainedProduct.state.failure?.code, .schemaMismatch)
        guard case let .stale(asOf, evaluatedAt) = retainedProduct.state.freshness else {
            return XCTFail("Retained partial MiniMax payload must be stale")
        }
        XCTAssertEqual(asOf, historical.fetchedAt)
        XCTAssertEqual(evaluatedAt, failureAt)
        guard case .stale = try XCTUnwrap(retainedProduct.metrics.first).state.freshness else {
            return XCTFail("Retained MiniMax metrics must be stale with their Product")
        }

        let empty = await adapter.read(scope: .provider)
        guard case let .failure(emptyFailure) = empty else {
            return XCTFail("An empty successful process output must fail")
        }
        XCTAssertEqual(emptyFailure.code, .sessionEOF)
        let diagnostic = await adapter.diagnosticSnapshot()
        XCTAssertEqual(
            Set(diagnostic.safeFields.keys),
            Set(["adapter", "cliVersion", "errorClass", "schema"])
        )
        XCTAssertFalse(diagnostic.safeFields.values.joined().contains("/private/secret"))
    }

    func testStatusMessageFreeTextNeverFlowsIntoParsedOrSafeDiagnosticState() async {
        let secret = "TOP-SECRET-user@example.invalid-/Users/private"
        let payload = receiptJSON.replacingOccurrences(
            of: "\"status_msg\": \"success\"",
            with: "\"status_msg\": \"\(secret)\""
        )
        let process = MiniMaxFakeChildProcessClient(results: [.success(output(payload))])
        let now = fixedNow
        let adapter = MiniMaxProviderAdapter(
            processClient: process,
            executableURL: URL(fileURLWithPath: "/opt/usage-butler/bin/mmx"),
            now: { now }
        )

        guard case .success = await adapter.read(scope: .provider) else {
            return XCTFail("Opaque status_msg must not alter the typed status_code result")
        }
        let diagnostic = await adapter.diagnosticSnapshot()
        XCTAssertFalse(diagnostic.safeFields.values.joined().contains(secret))
        XCTAssertFalse(diagnostic.diagnosticCode.contains(secret))
    }

    func testLoginAfterShutdownReturnsShutdownWithoutStartingProcess() async {
        let process = MiniMaxFakeChildProcessClient(results: [])
        let adapter = MiniMaxProviderAdapter(
            processClient: process,
            executableURL: URL(fileURLWithPath: "/opt/usage-butler/bin/mmx")
        )

        await adapter.shutdown()
        guard case let .failure(failure) = await adapter.login(method: .oauth) else {
            return XCTFail("Shutdown must reject later login")
        }
        XCTAssertEqual(failure.code, .shutdown)
        let requests = await process.capturedRequests()
        XCTAssertTrue(requests.isEmpty)
    }

    private func parse(
        _ json: String,
        completeness: ParsedMiniMaxReadCompleteness = .completeSuccess,
        sourceVersion: String = "1.0.19",
        catalogID: String = "minimax-token-plan-zh-cn-2026-08-10"
    ) throws -> ParsedMiniMaxQuotaSnapshot {
        try MiniMaxQuotaParser.parse(
            Data(json.utf8),
            context: ParsedMiniMaxParsingContext(
                completeness: completeness,
                sourceVersion: sourceVersion,
                region: "cn",
                catalogID: catalogID,
                contractVersion: "minimax-plan-inference-v1",
                fetchedAt: fixedNow
            )
        )
    }

    private var sourceIdentity: ProviderSourceIdentity {
        ProviderSourceIdentity(
            providerID: .miniMax,
            adapterID: MiniMaxDomainContract.adapterID,
            executableIdentity: MiniMaxDomainContract.executableIdentity,
            cliVersion: "1.0.19",
            schemaVersion: MiniMaxDomainContract.schemaVersion,
            contractVersion: MiniMaxDomainContract.quotaContractVersion
        )
    }

    private func providerState(lastGood: ProviderQuotaData?) -> ProviderState {
        let authentication = AuthenticationEvidence(
            authority: .providerReport(
                sourceField: "base_resp.status_code",
                contractVersion: MiniMaxDomainContract.quotaContractVersion
            ),
            observedAt: fixedNow
        )
        let freshness: FreshnessState = lastGood.map {
            .fresh(asOf: $0.fetchedAt)
        } ?? .unknown
        return ProviderState(
            id: .miniMax,
            capabilities: ProviderCapabilities(
                contractVersion: MiniMaxDomainContract.quotaContractVersion,
                loginMethod: .oauth,
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

    private func videoJSON(
        currentTotal: Int,
        currentStatus: Int = 1,
        weeklyTotal: Int = 21,
        weeklyStatus: Int = 1
    ) -> String {
        envelope(
            rows: [
                videoRow(
                currentTotal: currentTotal,
                currentStatus: currentStatus,
                weeklyTotal: weeklyTotal,
                weeklyStatus: weeklyStatus
                )
            ]
        )
    }

    private func envelope(rows: [String]) -> String {
        """
        {
          "base_resp": { "status_code": 0, "status_msg": "success" },
          "model_remains": [\(rows.joined(separator: ","))]
        }
        """
    }

    private func videoRow(
        currentTotal: Int,
        currentStatus: Int,
        weeklyTotal: Int,
        weeklyStatus: Int
    ) -> String {
        """
        {
          "model_name": "video",
          "start_time": 1000,
          "end_time": 11000,
          "remains_time": 5000,
          "current_interval_total_count": \(currentTotal),
          "current_interval_usage_count": 0,
          "current_interval_remaining_percent": 100,
          "current_interval_status": \(currentStatus),
          "weekly_start_time": 1000,
          "weekly_end_time": 21000,
          "weekly_remains_time": 15000,
          "current_weekly_total_count": \(weeklyTotal),
          "current_weekly_usage_count": 0,
          "current_weekly_remaining_percent": 100,
          "current_weekly_status": \(weeklyStatus)
        }
        """
    }

    private var receiptJSON: String {
        """
        {
          "base_resp": { "status_code": 0, "status_msg": "success" },
          "model_remains": [
            {
              "model_name": "general",
              "start_time": 1786309200000,
              "end_time": 1786327200000,
              "remains_time": 8288354,
              "current_interval_total_count": 0,
              "current_interval_usage_count": 0,
              "current_interval_remaining_percent": 96,
              "current_interval_status": 1,
              "weekly_start_time": 1786291200000,
              "weekly_end_time": 1786896000000,
              "weekly_remains_time": 577088354,
              "current_weekly_total_count": 0,
              "current_weekly_usage_count": 0,
              "current_weekly_remaining_percent": 100,
              "current_weekly_status": 3
            },
            {
              "model_name": "video",
              "start_time": 1786291200000,
              "end_time": 1786377600000,
              "remains_time": 58688354,
              "current_interval_total_count": 3,
              "current_interval_usage_count": 0,
              "current_interval_remaining_percent": 100,
              "current_interval_status": 1,
              "weekly_start_time": 1786291200000,
              "weekly_end_time": 1786896000000,
              "weekly_remains_time": 577088354,
              "current_weekly_total_count": 21,
              "current_weekly_usage_count": 0,
              "current_weekly_remaining_percent": 100,
              "current_weekly_status": 1
            }
          ]
        }
        """
    }
}

private actor MiniMaxFakeChildProcessClient: ChildProcessClient {
    private var results: [Result<ChildProcessOutput, ProviderFailure>]
    private var requests: [ChildProcessRequest] = []
    private var shutdownCalls = 0

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

    func shutdown() async {
        shutdownCalls += 1
    }

    func capturedRequests() -> [ChildProcessRequest] {
        requests
    }
}

private actor MiniMaxSuspendingChildProcessClient: ChildProcessClient {
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
