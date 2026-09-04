import Foundation
import XCTest
@testable import UsageButlerCore
@testable import UsageButlerDomain
@testable import UsageButlerUI

@MainActor
final class PresentationTests: XCTestCase {
    private let fixedNow = Date(timeIntervalSince1970: 1_786_400_000)

    func testActivityMonitorFieldTitlesMatchAcceptedCopy() {
        XCTAssertEqual(
            MemoryFieldID.allCases.map(MemoryFieldPresentation.title),
            ["物理内存", "已使用内存", "已缓存文件", "已使用的交换", "App 内存", "联动内存", "被压缩"]
        )
    }

    func testProviderNamesMatchProductCopy() {
        XCTAssertEqual(
            ProviderID.allCases.map(ProviderPresentation.displayName),
            ["OpenAI", "MiniMax", "火山方舟"]
        )
    }

    func testRateLimitedLoginUsesSpecificUserFacingCopy() {
        XCTAssertEqual(
            ProviderPresentation.failure(.rateLimited).title,
            "请求过于频繁"
        )
        XCTAssertEqual(
            ProviderPresentation.loginFeedbackMessage(.rateLimited, for: .ark),
            "火山方舟 登录请求过于频繁，请稍后再试"
        )
        XCTAssertEqual(
            ProviderPresentation.loginFeedbackMessage(
                .authorizationNotRenewed,
                for: .ark
            ),
            "火山方舟 登录流程已结束，但授权到期时间未更新"
        )
    }

    func testProviderSymbolNamesAreUniqueAndCoverAllProviders() {
        let symbolNames = ProviderID.allCases.map(
            ProviderPresentation.symbolName(for:)
        )
        XCTAssertEqual(
            symbolNames.count,
            ProviderID.allCases.count,
            "Every provider must have a neutral system symbol"
        )
        XCTAssertEqual(Set(symbolNames).count, symbolNames.count)
        XCTAssertEqual(
            symbolNames,
            ["circle.hexagongrid.fill", "waveform", "mountain.2.fill"]
        )
    }

    func testPlanBadgeAccessibilityDistinguishesReportedAndInferredTier() {
        XCTAssertEqual(
            PlanBadgePresentation.accessibilityLabel(
                for: Stage3PlanBadge(
                    value: "Max",
                    origin: .inferred(ruleID: "minimax-video-daily-v1")
                )
            ),
            "Max，根据视频权益推断"
        )
        XCTAssertEqual(
            PlanBadgePresentation.accessibilityLabel(
                for: Stage3PlanBadge(
                    value: "Pro",
                    origin: .reported(sourceField: "plans.get.plans[].tier")
                )
            ),
            "Pro 套餐"
        )
    }

    func testMemoryPressureFillGradientUsesWholeChartHeight() {
        let gradient = MemoryPressureFillGradientPlan.activityMonitorObserved

        XCTAssertEqual(gradient.startY, 0)
        XCTAssertEqual(gradient.endY, 1)
        XCTAssertEqual(gradient.topOpacity, 0.5)
        XCTAssertEqual(gradient.bottomOpacity, 1.0 / 3.0)
    }

    func testExpiredProviderMovesRecoveryIntoHeaderAndOffersOfficialLogin() throws {
        let provider = quotaProvider(
            rowState: .expired(lastSuccessAt: fixedNow),
            dataState: .stale(asOf: fixedNow),
            loginMethod: .sso,
            failureCode: .authenticationExpired,
            products: [
                Stage3QuotaProductProjection(
                    id: "agent-plan",
                    metrics: []
                )
            ]
        )

        let recovery = try XCTUnwrap(
            ProviderQuotaHeaderRecoveryPresentation(provider: provider)
        )
        XCTAssertEqual(recovery.title, "登录已过期")
        XCTAssertEqual(recovery.actionTitle, "重新登录")
        XCTAssertTrue(recovery.detail?.contains("旧数据") == true)
    }

    func testQuotaHeaderRecoveryDoesNotOfferUnwiredLoginOrConsumeOtherStates() {
        let expiredWithoutLogin = quotaProvider(
            rowState: .expired(lastSuccessAt: nil),
            dataState: .unknown,
            loginMethod: nil,
            failureCode: .authenticationExpired,
            products: []
        )
        let requiresLogin = quotaProvider(
            rowState: .requiresLogin,
            dataState: .unknown,
            loginMethod: .oauth,
            failureCode: .authenticationRequired,
            products: []
        )

        let recovery = ProviderQuotaHeaderRecoveryPresentation(
            provider: expiredWithoutLogin
        )
        XCTAssertEqual(recovery?.detail, "尚无成功数据")
        XCTAssertNil(recovery?.actionTitle)
        XCTAssertNil(
            ProviderQuotaHeaderRecoveryPresentation(provider: requiresLogin)
        )
    }

    func testExpiredHeaderDoesNotCallFreshOrMixedDataOld() throws {
        let products = [
            Stage3QuotaProductProjection(id: "agent-plan", metrics: [])
        ]
        let fresh = quotaProvider(
            rowState: .expired(lastSuccessAt: fixedNow),
            dataState: .fresh(asOf: fixedNow),
            loginMethod: .sso,
            failureCode: .authenticationExpired,
            products: products
        )
        let mixed = quotaProvider(
            rowState: .expired(lastSuccessAt: fixedNow),
            dataState: .stale(asOf: fixedNow.addingTimeInterval(-120)),
            partialDataState: Stage3PartialDataState(
                freshAsOf: fixedNow,
                retainedStaleAsOf: fixedNow.addingTimeInterval(-120)
            ),
            loginMethod: .sso,
            failureCode: .authenticationExpired,
            products: products
        )

        let freshDetail = try XCTUnwrap(
            ProviderQuotaHeaderRecoveryPresentation(provider: fresh)?.detail
        )
        let mixedDetail = try XCTUnwrap(
            ProviderQuotaHeaderRecoveryPresentation(provider: mixed)?.detail
        )
        XCTAssertTrue(freshDetail.contains("上次成功"))
        XCTAssertFalse(freshDetail.contains("旧数据"))
        XCTAssertTrue(mixedDetail.contains("上次成功"))
        XCTAssertFalse(mixedDetail.contains("旧数据"))
    }

    func testExpiredHeaderOnlyConsumesDuplicateAuthenticationStatus() {
        let products = [
            Stage3QuotaProductProjection(id: "agent-plan", metrics: [])
        ]
        let authenticationOnly = quotaProvider(
            rowState: .expired(lastSuccessAt: fixedNow),
            dataState: .stale(asOf: fixedNow),
            loginMethod: .sso,
            failureCode: .authenticationExpired,
            products: products
        )
        let mixedFreshness = quotaProvider(
            rowState: .expired(lastSuccessAt: fixedNow),
            dataState: .stale(asOf: fixedNow),
            partialDataState: Stage3PartialDataState(
                freshAsOf: fixedNow,
                retainedStaleAsOf: fixedNow.addingTimeInterval(-60)
            ),
            loginMethod: .sso,
            failureCode: .authenticationExpired,
            products: products
        )
        let independentFailure = quotaProvider(
            rowState: .expired(lastSuccessAt: fixedNow),
            dataState: .stale(asOf: fixedNow),
            loginMethod: .sso,
            failureCode: .schemaMismatch,
            products: products
        )

        XCTAssertFalse(
            ProviderQuotaStatusPlacement.showsBodyStatusRow(
                for: authenticationOnly
            )
        )
        XCTAssertTrue(
            ProviderQuotaStatusPlacement.showsBodyStatusRow(
                for: mixedFreshness
            )
        )
        XCTAssertTrue(
            ProviderQuotaStatusPlacement.showsBodyStatusRow(
                for: independentFailure
            )
        )
    }

    func testProviderStatusPriorityDoesNotHideIndependentFailureBehindPartialData() {
        let partial = Stage3PartialDataState(
            freshAsOf: fixedNow,
            retainedStaleAsOf: fixedNow.addingTimeInterval(-60)
        )
        let connectedFailure = quotaProvider(
            rowState: .connected,
            dataState: .stale(asOf: fixedNow.addingTimeInterval(-60)),
            partialDataState: partial,
            loginMethod: nil,
            failureCode: .schemaMismatch,
            products: [Stage3QuotaProductProjection(id: "codex", metrics: [])]
        )
        let expiredIndependentFailure = quotaProvider(
            rowState: .expired(lastSuccessAt: fixedNow),
            dataState: .stale(asOf: fixedNow.addingTimeInterval(-60)),
            partialDataState: partial,
            loginMethod: .sso,
            failureCode: .serviceUnavailable,
            products: [Stage3QuotaProductProjection(id: "agent-plan", metrics: [])]
        )
        let expiredAuthenticationOnly = quotaProvider(
            rowState: .expired(lastSuccessAt: fixedNow),
            dataState: .stale(asOf: fixedNow.addingTimeInterval(-60)),
            partialDataState: partial,
            loginMethod: .sso,
            failureCode: .authenticationExpired,
            products: [Stage3QuotaProductProjection(id: "agent-plan", metrics: [])]
        )
        let refreshing = quotaProvider(
            rowState: .connected,
            dataState: .stale(asOf: fixedNow.addingTimeInterval(-60)),
            activity: .refreshing,
            partialDataState: partial,
            loginMethod: nil,
            failureCode: .schemaMismatch,
            products: [Stage3QuotaProductProjection(id: "codex", metrics: [])]
        )

        XCTAssertEqual(
            ProviderStatusPriority.visibleFailure(for: connectedFailure),
            .schemaMismatch
        )
        XCTAssertNil(ProviderStatusPriority.visiblePartial(for: connectedFailure))
        XCTAssertEqual(
            ProviderStatusPriority.visibleFailure(for: expiredIndependentFailure),
            .serviceUnavailable
        )
        XCTAssertNil(
            ProviderStatusPriority.visiblePartial(for: expiredIndependentFailure)
        )
        XCTAssertNil(
            ProviderStatusPriority.visibleFailure(for: expiredAuthenticationOnly)
        )
        XCTAssertEqual(
            ProviderStatusPriority.visiblePartial(for: expiredAuthenticationOnly),
            partial
        )
        XCTAssertNil(ProviderStatusPriority.visibleFailure(for: refreshing))
        XCTAssertNil(ProviderStatusPriority.visiblePartial(for: refreshing))
    }

    func testAuthenticationWarningCopyIsDistinctFromRequiredAndExpiredLogin() {
        XCTAssertEqual(Stage3ProviderRowState.authenticationWarning.settingsTitle, "登录即将到期")
        XCTAssertEqual(
            Stage3ProviderRowState.authenticationWarning.authenticationWarningTitle,
            "登录即将到期"
        )
        for state: Stage3ProviderRowState in [
            .connected, .detecting, .requiresLogin, .expired(lastSuccessAt: fixedNow), .unavailable
        ] {
            XCTAssertNil(state.authenticationWarningTitle)
        }
        XCTAssertEqual(Stage3ProviderRowState.requiresLogin.settingsTitle, "需要登录")
        XCTAssertEqual(
            Stage3ProviderRowState.expired(lastSuccessAt: fixedNow).settingsTitle,
            "登录已过期"
        )
    }

    func testAuthenticationWarningUsesHeaderWithoutDuplicatingFreshQuotaStatus() {
        for activity: Stage3ProviderActivity in [.idle, .refreshing] {
            let provider = quotaProvider(
                rowState: .authenticationWarning,
                dataState: .fresh(asOf: fixedNow),
                activity: activity,
                loginMethod: .sso,
                failureCode: nil,
                products: [Stage3QuotaProductProjection(id: "agent-plan", metrics: [])]
            )

            XCTAssertEqual(provider.rowState.authenticationWarningTitle, "登录即将到期")
            XCTAssertFalse(ProviderQuotaStatusPlacement.showsBodyStatusRow(for: provider))
            XCTAssertNil(ProviderQuotaHeaderRecoveryPresentation(provider: provider))
        }
    }

    func testAuthenticationWarningKeepsStalePartialAndFailureStatusIndependent() {
        let partial = Stage3PartialDataState(
            freshAsOf: fixedNow,
            retainedStaleAsOf: fixedNow.addingTimeInterval(-60)
        )
        let cases: [(Stage3PartialDataState?, FailureCode?)] = [
            (nil, nil), (partial, nil), (partial, .schemaMismatch)
        ]
        for (partialState, failure) in cases {
            let provider = quotaProvider(
                rowState: .authenticationWarning,
                dataState: .stale(asOf: fixedNow.addingTimeInterval(-60)),
                partialDataState: partialState,
                loginMethod: .sso,
                failureCode: failure,
                products: [Stage3QuotaProductProjection(id: "agent-plan", metrics: [])]
            )

            XCTAssertEqual(provider.rowState.authenticationWarningTitle, "登录即将到期")
            XCTAssertTrue(ProviderQuotaStatusPlacement.showsBodyStatusRow(for: provider))
            XCTAssertEqual(ProviderStatusPriority.visibleFailure(for: provider), failure)
            XCTAssertEqual(
                ProviderStatusPriority.visiblePartial(for: provider),
                failure == nil ? partialState : nil
            )
        }
    }

    func testRefreshingProviderSignalsProgressInHeaderInsteadOfBodyRow() {
        let staleAt = fixedNow.addingTimeInterval(-300)
        let provider = quotaProvider(
            rowState: .connected,
            dataState: .stale(asOf: staleAt),
            activity: .refreshing,
            loginMethod: nil,
            failureCode: nil,
            products: [
                Stage3QuotaProductProjection(id: "codex", metrics: [])
            ]
        )

        XCTAssertEqual(
            ProviderActivityPresentation.title(for: provider.activity),
            "正在更新额度"
        )
        XCTAssertTrue(
            ProviderActivityPresentation.detail(for: provider)?
                .contains("暂时显示") == true
        )
        // The transient refresh state lives on the header timestamp spinner;
        // a body row would appear and disappear on every refresh cycle.
        XCTAssertFalse(
            ProviderQuotaStatusPlacement.showsBodyStatusRow(for: provider)
        )
    }

    func testQuotaAvailabilityBandReflectsAvailableShareForBothDirections() {
        let now = fixedNow
        let asOf = now.addingTimeInterval(-60)
        func band(_ value: Stage3QuotaValue) -> QuotaAvailabilityBand? {
            QuotaAvailabilityBand.band(
                value: value,
                asOf: asOf,
                now: now,
                refreshIntervalSeconds: 300
            )
        }

        XCTAssertEqual(band(.percent(value: 96, direction: .remaining)), .high)
        XCTAssertEqual(band(.percent(value: 60.5, direction: .remaining)), .high)
        XCTAssertEqual(band(.percent(value: 60, direction: .remaining)), .medium)
        XCTAssertEqual(band(.percent(value: 30.5, direction: .remaining)), .medium)
        XCTAssertEqual(band(.percent(value: 30, direction: .remaining)), .low)
        XCTAssertEqual(band(.percent(value: 0, direction: .remaining)), .low)
        XCTAssertEqual(band(.percent(value: 3, direction: .used)), .high)
        XCTAssertEqual(band(.percent(value: 40, direction: .used)), .medium)
        XCTAssertEqual(band(.percent(value: 70, direction: .used)), .low)
        XCTAssertEqual(band(.percent(value: 100, direction: .used)), .low)
        XCTAssertNil(band(.unlimited))
        XCTAssertNil(band(.usedCount(used: 0, total: 3, unit: "次")))
        XCTAssertNil(band(.entitlement(availableCount: 3)))
    }

    func testQuotaAvailabilityBandTurnsLostPastRefreshIntervalPlusGrace() {
        let now = fixedNow
        let value = Stage3QuotaValue.percent(value: 96, direction: .remaining)

        XCTAssertEqual(
            QuotaAvailabilityBand.band(
                value: value,
                asOf: now.addingTimeInterval(-900),
                now: now,
                refreshIntervalSeconds: 300
            ),
            .high
        )
        XCTAssertEqual(
            QuotaAvailabilityBand.band(
                value: value,
                asOf: now.addingTimeInterval(-901),
                now: now,
                refreshIntervalSeconds: 300
            ),
            .lost
        )
        XCTAssertEqual(
            QuotaAvailabilityBand.band(
                value: value,
                asOf: nil,
                now: now,
                refreshIntervalSeconds: 300
            ),
            .lost
        )
        // A manual-only cadence carries no freshness expectation.
        XCTAssertEqual(
            QuotaAvailabilityBand.band(
                value: value,
                asOf: now.addingTimeInterval(-86_400),
                now: now,
                refreshIntervalSeconds: 0
            ),
            .high
        )
        XCTAssertEqual(
            QuotaAvailabilityBand.band(
                value: value,
                asOf: nil,
                now: now,
                refreshIntervalSeconds: 0
            ),
            .high
        )
    }

    func testRefreshOverrideSecondsKeyIsPackagedPerProvider() {
        XCTAssertEqual(
            ProviderPreferenceKey.refreshOverrideSecondsKey(for: .openAI),
            ProviderPreferenceKey.openAIRefreshOverrideSeconds
        )
        XCTAssertEqual(
            ProviderPreferenceKey.refreshOverrideSecondsKey(for: .miniMax),
            ProviderPreferenceKey.miniMaxRefreshOverrideSeconds
        )
        XCTAssertEqual(
            ProviderPreferenceKey.refreshOverrideSecondsKey(for: .ark),
            ProviderPreferenceKey.arkRefreshOverrideSeconds
        )
    }

    func testExpiredProviderOffersCancellationWhileLoginIsInFlight() throws {
        let provider = quotaProvider(
            rowState: .expired(lastSuccessAt: fixedNow),
            dataState: .stale(asOf: fixedNow),
            activity: .loggingIn,
            loginMethod: .sso,
            failureCode: .authenticationExpired,
            products: []
        )

        let recovery = try XCTUnwrap(
            ProviderQuotaHeaderRecoveryPresentation(provider: provider)
        )
        XCTAssertEqual(recovery.title, "正在登录")
        XCTAssertEqual(recovery.actionTitle, "取消登录")
        XCTAssertFalse(
            ProviderQuotaStatusPlacement.showsBodyStatusRow(for: provider)
        )
    }

    func testMemoryPressureLayoutUsesTimestampsAndIndependentPressureRatio() throws {
        let layout = MemoryPressureChartLayout.make(
            points: [
                trendPoint(id: 0, secondsFromNow: -90, ratio: 0.2),
                trendPoint(id: 1, secondsFromNow: -80, ratio: 0.99),
                trendPoint(id: 2, secondsFromNow: -10, ratio: nil)
            ],
            windowStart: fixedNow.addingTimeInterval(-100),
            windowEnd: fixedNow,
            maximumContinuousInterval: 100
        )

        let trace = try XCTUnwrap(layout.traces.only)
        XCTAssertEqual(trace.points.count, 2)
        XCTAssertEqual(trace.points[0].x, 0.1, accuracy: 0.000_001)
        XCTAssertEqual(trace.points[1].x, 0.2, accuracy: 0.000_001)
        XCTAssertEqual(trace.points[0].y, 0.8, accuracy: 0.000_001)
        XCTAssertEqual(trace.points[1].y, 0.01, accuracy: 0.000_001)
    }

    func testMemoryPressureLayoutKeepsUnknownPressureWhenRatioIsAvailable() {
        let layout = MemoryPressureChartLayout.make(
            points: [
                trendPoint(id: 0, secondsFromNow: -50, ratio: 0.20),
                trendPoint(id: 1, secondsFromNow: -45, ratio: 0.25),
                trendPoint(
                    id: 2,
                    secondsFromNow: -40,
                    ratio: 0.30,
                    pressure: .unknown
                ),
                trendPoint(
                    id: 3,
                    secondsFromNow: -35,
                    ratio: 0.35,
                    pressure: .unknown
                ),
                trendPoint(
                    id: 4,
                    secondsFromNow: -30,
                    ratio: 0.40,
                    pressure: .warning
                ),
                trendPoint(
                    id: 5,
                    secondsFromNow: -25,
                    ratio: 0.45,
                    pressure: .warning
                )
            ],
            windowStart: fixedNow.addingTimeInterval(-60),
            windowEnd: fixedNow
        )

        XCTAssertEqual(layout.traces.map(\.pressure), [.normal, .unknown, .warning])
        XCTAssertEqual(Set(layout.traces.flatMap(\.points).map(\.timestamp)).count, 6)
        XCTAssertEqual(layout.markers.only?.timestamp, fixedNow.addingTimeInterval(-25))
    }

    func testMemoryPressureLayoutUsesCoreContinuityContract() {
        let continuity = MemoryHistoryDownsampler.maximumContinuousInterval
        let layout = MemoryPressureChartLayout.make(
            points: [
                trendPoint(
                    id: 0,
                    secondsFromNow: -((3 * continuity) + 11),
                    ratio: 0.2
                ),
                trendPoint(
                    id: 1,
                    secondsFromNow: -((2 * continuity) + 11),
                    ratio: 0.3
                ),
                trendPoint(
                    id: 2,
                    secondsFromNow: -(continuity + 10),
                    ratio: 0.7,
                    pressure: .critical
                ),
                trendPoint(
                    id: 3,
                    secondsFromNow: -10,
                    ratio: 0.8,
                    pressure: .critical
                )
            ],
            windowStart: fixedNow.addingTimeInterval(-((3 * continuity) + 11)),
            windowEnd: fixedNow
        )

        XCTAssertEqual(layout.traces.count, 2)
        XCTAssertEqual(layout.traces.map(\.pressure), [.normal, .critical])
        XCTAssertEqual(layout.traces.map(\.points.count), [2, 2])
    }

    func testMemoryPressureLayoutPressureChangesColorWithoutMovingGeometry() throws {
        let layout = MemoryPressureChartLayout.make(
            points: [
                trendPoint(id: 0, secondsFromNow: -50, ratio: 0.20),
                trendPoint(id: 1, secondsFromNow: -45, ratio: 0.25),
                trendPoint(
                    id: 2,
                    secondsFromNow: -40,
                    ratio: 0.30,
                    pressure: .warning
                ),
                trendPoint(
                    id: 3,
                    secondsFromNow: -35,
                    ratio: 0.35,
                    pressure: .warning
                )
            ],
            windowStart: fixedNow.addingTimeInterval(-60),
            windowEnd: fixedNow
        )

        XCTAssertEqual(layout.traces.map(\.pressure), [.normal, .warning])
        let shared = try XCTUnwrap(layout.traces[0].points.last)
        let warningStart = try XCTUnwrap(layout.traces[1].points.first)
        XCTAssertEqual(shared.timestamp, warningStart.timestamp)
        XCTAssertEqual(shared.timestamp, fixedNow.addingTimeInterval(-40))
        XCTAssertEqual(shared.x, warningStart.x, accuracy: 0.000_001)
        XCTAssertEqual(shared.y, warningStart.y, accuracy: 0.000_001)
    }

    func testMemoryPressureLayoutFailsClosedForInvalidOutsideAndDuplicatePoints() {
        let invalidDate = Date(timeIntervalSinceReferenceDate: .infinity)
        let layout = MemoryPressureChartLayout.make(
            points: [
                trendPoint(id: 0, secondsFromNow: -70, ratio: 0.1),
                trendPoint(id: 1, secondsFromNow: -50, ratio: .infinity),
                MemoryTrendPoint(
                    id: 2,
                    timestamp: invalidDate,
                    loadRatio: 0.4,
                    pressureRatio: 0.4,
                    pressure: .warning
                ),
                trendPoint(
                    id: 3,
                    secondsFromNow: -30,
                    ratio: 0.5,
                    pressure: .warning
                ),
                trendPoint(
                    id: 4,
                    secondsFromNow: -30,
                    ratio: 0.6,
                    pressure: .critical
                ),
                trendPoint(
                    id: 5,
                    secondsFromNow: -20,
                    ratio: 0.7,
                    pressure: .critical
                ),
                trendPoint(id: 6, secondsFromNow: 1, ratio: 0.8)
            ],
            windowStart: fixedNow.addingTimeInterval(-60),
            windowEnd: fixedNow
        )

        XCTAssertTrue(layout.traces.isEmpty)
        XCTAssertEqual(layout.markers.only?.timestamp, fixedNow.addingTimeInterval(-20))
    }

    func testMemoryPressureLayoutClampsLeadingEdgeWhenHistoryPrecedesWindow() throws {
        let layout = MemoryPressureChartLayout.make(
            points: [
                trendPoint(id: 0, secondsFromNow: -70, ratio: 0.2),
                trendPoint(id: 1, secondsFromNow: -50, ratio: 0.4),
                trendPoint(id: 2, secondsFromNow: -30, ratio: 0.6)
            ],
            windowStart: fixedNow.addingTimeInterval(-60),
            windowEnd: fixedNow
        )

        let trace = try XCTUnwrap(layout.traces.only)
        XCTAssertEqual(trace.points.count, 3)
        XCTAssertEqual(trace.points[0].x, 0, accuracy: 0.000_001)
        XCTAssertEqual(trace.points[0].y, 0.8, accuracy: 0.000_001)
        XCTAssertEqual(trace.points[0].timestamp, fixedNow.addingTimeInterval(-60))
        XCTAssertEqual(trace.points[1].x, 1.0 / 6.0, accuracy: 0.000_001)
        XCTAssertEqual(
            try XCTUnwrap(layout.markers.only).x,
            1.0 / 2.0,
            accuracy: 0.000_001
        )
    }

    func testMemoryPressureLayoutLeavesLeadingBlankWhenHistoryStartsInsideWindow() throws {
        let layout = MemoryPressureChartLayout.make(
            points: [
                trendPoint(id: 0, secondsFromNow: -50, ratio: 0.4),
                trendPoint(id: 1, secondsFromNow: -30, ratio: 0.6)
            ],
            windowStart: fixedNow.addingTimeInterval(-60),
            windowEnd: fixedNow
        )

        let trace = try XCTUnwrap(layout.traces.only)
        XCTAssertEqual(trace.points[0].x, 1.0 / 6.0, accuracy: 0.000_001)
        XCTAssertGreaterThan(trace.points[0].x, 0)
    }

    func testMemoryPressureLayoutDoesNotClampAcrossInvalidLeadingSample() throws {
        let layout = MemoryPressureChartLayout.make(
            points: [
                trendPoint(id: 0, secondsFromNow: -65, ratio: nil),
                trendPoint(id: 1, secondsFromNow: -50, ratio: 0.4),
                trendPoint(id: 2, secondsFromNow: -30, ratio: 0.6)
            ],
            windowStart: fixedNow.addingTimeInterval(-60),
            windowEnd: fixedNow
        )

        let trace = try XCTUnwrap(layout.traces.only)
        XCTAssertEqual(trace.points[0].x, 1.0 / 6.0, accuracy: 0.000_001)
    }

    func testMemoryPressureLayoutClampNeverBridgesARealHole() throws {
        let layout = MemoryPressureChartLayout.make(
            points: [
                trendPoint(id: 0, secondsFromNow: -70, ratio: 0.2),
                trendPoint(id: 1, secondsFromNow: -5, ratio: 0.6)
            ],
            windowStart: fixedNow.addingTimeInterval(-60),
            windowEnd: fixedNow
        )

        XCTAssertTrue(layout.traces.isEmpty)
        XCTAssertEqual(
            try XCTUnwrap(layout.markers.only).x,
            55.0 / 60.0,
            accuracy: 0.000_001
        )
    }

    func testMemoryPressureLayoutDoesNotHideCrossWindowGapByClamping() throws {
        let layout = MemoryPressureChartLayout.make(
            points: [
                trendPoint(id: 0, secondsFromNow: -100, ratio: 0.2),
                trendPoint(id: 1, secondsFromNow: -50, ratio: 0.4),
                trendPoint(id: 2, secondsFromNow: -30, ratio: 0.6)
            ],
            windowStart: fixedNow.addingTimeInterval(-60),
            windowEnd: fixedNow
        )

        let trace = try XCTUnwrap(layout.traces.only)
        XCTAssertEqual(
            trace.points.map { $0.timestamp.timeIntervalSince(fixedNow) },
            [-50, -30]
        )
        let drawing = MemoryPressureChartDrawingPlan.make(layout: layout)
        XCTAssertTrue(drawing.commands.flatMap(\.points).allSatisfy { $0.x > 0 })
    }

    func testMemoryPressureLeadingClampUsesOriginalContinuityThreshold() throws {
        for limit: TimeInterval in [
            MemoryHistoryDownsampler.maximumContinuousInterval,
            20
        ] {
            for excess: TimeInterval in [0, 0.001] {
                let layout = MemoryPressureChartLayout.make(
                    points: [
                        trendPoint(id: 0, secondsFromNow: -50 - limit - excess, ratio: 0.2),
                        trendPoint(id: 1, secondsFromNow: -50, ratio: 0.4),
                        trendPoint(id: 2, secondsFromNow: -30, ratio: 0.6)
                    ],
                    windowStart: fixedNow.addingTimeInterval(-60),
                    windowEnd: fixedNow,
                    maximumContinuousInterval: limit
                )

                let trace = try XCTUnwrap(layout.traces.only)
                XCTAssertEqual(
                    trace.points.map { $0.timestamp.timeIntervalSince(fixedNow) },
                    excess == 0 ? [-60, -50, -30] : [-50, -30],
                    "Original gap must be <= \(limit), not shortened by the clamp"
                )
            }
        }
    }

    func testMemoryPressureLeadingClampDoesNotInventDataForEmptyWindow() {
        for insideRatio: Double? in [nil, .infinity, -0.1, 1.1] {
            let layout = MemoryPressureChartLayout.make(
                points: [
                    trendPoint(id: 0, secondsFromNow: -65, ratio: 0.2),
                    trendPoint(id: 1, secondsFromNow: -50, ratio: insideRatio)
                ],
                windowStart: fixedNow.addingTimeInterval(-60),
                windowEnd: fixedNow
            )

            XCTAssertFalse(layout.hasKnownData)
            XCTAssertTrue(MemoryPressureChartDrawingPlan.make(layout: layout).commands.isEmpty)
        }
    }

    func testMemoryPressureLeadingClampDoesNotDuplicateExactBoundarySample() throws {
        let layout = MemoryPressureChartLayout.make(
            points: [
                trendPoint(id: 0, secondsFromNow: -70, ratio: 0.2),
                trendPoint(id: 1, secondsFromNow: -60, ratio: 0.4),
                trendPoint(id: 2, secondsFromNow: -40, ratio: 0.6)
            ],
            windowStart: fixedNow.addingTimeInterval(-60),
            windowEnd: fixedNow
        )

        let trace = try XCTUnwrap(layout.traces.only)
        XCTAssertEqual(
            trace.points.map { $0.timestamp.timeIntervalSince(fixedNow) },
            [-60, -40]
        )
        XCTAssertEqual(trace.points[0].y, 0.6, accuracy: 0.000_001)
    }

    func testQuotaUpdateHeaderLabelIsTruthfulToDataState() {
        XCTAssertNil(
            QuotaUpdatePresentation.headerLabel(dataState: .unknown)
        )
        for state in [
            Stage3ProviderDataState.fresh(asOf: fixedNow),
            Stage3ProviderDataState.stale(asOf: fixedNow)
        ] {
            let label = QuotaUpdatePresentation.headerLabel(dataState: state)
            XCTAssertTrue(
                label?.hasPrefix("更新于") == true,
                "Expected a 更新于 label for \(state)"
            )
        }
    }

    func testMemoryPressureLayoutSmoothsDenseRecentSamples() throws {
        let ratios: [Double?] = [0.1, 0.9, 0.1, 0.9, 0.1, 0.9, 0.1, 0.9, 0.1, 0.9, 0.1]
        let points = ratios.enumerated().map { index, ratio in
            trendPoint(id: index, secondsFromNow: -10 + TimeInterval(index), ratio: ratio)
        }
        let layout = MemoryPressureChartLayout.make(
            points: points,
            windowStart: fixedNow.addingTimeInterval(-10),
            windowEnd: fixedNow
        )

        let marker = try XCTUnwrap(layout.markers.only)
        // Window at t=0 covers the samples from -5 s: 0.9 0.1 0.9 0.1 0.9 0.1.
        XCTAssertEqual(marker.y, 0.5, accuracy: 0.000_001)
    }

    func testMemoryPressureLayoutLeavesCoarseHistoryUnsmoothed() throws {
        let layout = MemoryPressureChartLayout.make(
            points: [
                trendPoint(id: 0, secondsFromNow: -50, ratio: 0.1),
                trendPoint(id: 1, secondsFromNow: -40, ratio: 0.9),
                trendPoint(id: 2, secondsFromNow: -30, ratio: 0.6)
            ],
            windowStart: fixedNow.addingTimeInterval(-60),
            windowEnd: fixedNow
        )

        let ys = try XCTUnwrap(layout.traces.only).points.map(\.y)
        XCTAssertEqual(ys.count, 3)
        XCTAssertEqual(ys[0], 0.9, accuracy: 0.000_001)
        XCTAssertEqual(ys[1], 0.1, accuracy: 0.000_001)
        XCTAssertEqual(ys[2], 0.4, accuracy: 0.000_001)
    }

    func testMemoryPressureSmoothingIntervalAdaptsToWindowDuration() {
        XCTAssertEqual(
            MemoryPressureChartLayout.smoothingInterval(forWindowDuration: 60),
            5
        )
        XCTAssertEqual(
            MemoryPressureChartLayout.smoothingInterval(forWindowDuration: 600),
            10
        )
        XCTAssertEqual(
            MemoryPressureChartLayout.smoothingInterval(forWindowDuration: 3600),
            60
        )
        XCTAssertEqual(
            MemoryPressureChartLayout.smoothingInterval(forWindowDuration: 7200),
            120
        )
        XCTAssertEqual(
            MemoryPressureChartLayout.smoothingInterval(forWindowDuration: 72000),
            120
        )
        XCTAssertEqual(
            MemoryPressureChartLayout.smoothingInterval(forWindowDuration: .infinity),
            5
        )
        XCTAssertEqual(
            MemoryPressureChartLayout.smoothingInterval(forWindowDuration: 0),
            5
        )
        XCTAssertEqual(
            MemoryPressureChartLayout.smoothingInterval(forWindowDuration: -60),
            5
        )
    }

    func testMemoryPressureLayoutSmoothsCoarseHistoryOnLongWindows() throws {
        // Ten-second-cadence samples across a one-hour window: the adaptive
        // smoothing window is 60 seconds, so each plotted point averages the
        // samples within its trailing minute instead of rendering raw steps.
        let points = (0...360).map { index in
            trendPoint(
                id: index,
                secondsFromNow: -3600 + TimeInterval(index * 10),
                ratio: index.isMultiple(of: 2) ? 0.1 : 0.9
            )
        }
        let layout = MemoryPressureChartLayout.make(
            points: points,
            windowStart: fixedNow.addingTimeInterval(-3600),
            windowEnd: fixedNow
        )

        let marker = try XCTUnwrap(layout.markers.only)
        XCTAssertEqual(marker.timestamp, fixedNow)
        // Window at t=0 covers the samples from -60 s: four 0.1 and three 0.9.
        XCTAssertEqual(marker.y, 3.9 / 7.0, accuracy: 0.000_001)
    }

    func testMemoryPressureLayoutDoesNotDragPreGapSamplesIntoLongWindowSmoothing() throws {
        // A one-hour range uses a 60-second smoothing window, wider than the
        // 30-second continuity limit. The 40-second gap below is a real break:
        // the first post-gap sample must start a fresh smoothing window instead
        // of averaging with the pre-gap 0.9 samples still inside 60 seconds.
        var points = (0...10).map { index in
            trendPoint(
                id: index,
                secondsFromNow: -3600 + TimeInterval(index * 10),
                ratio: 0.9
            )
        }
        points.append(
            trendPoint(id: 11, secondsFromNow: -3460, ratio: 0.1)
        )
        let layout = MemoryPressureChartLayout.make(
            points: points,
            windowStart: fixedNow.addingTimeInterval(-3600),
            windowEnd: fixedNow
        )

        let marker = try XCTUnwrap(layout.markers.only)
        XCTAssertEqual(marker.timestamp, fixedNow.addingTimeInterval(-3460))
        XCTAssertEqual(marker.y, 0.9, accuracy: 0.000_001)
    }

    func testMemoryPressureLayoutResetsSmoothingAcrossInvalidSamples() throws {
        let layout = MemoryPressureChartLayout.make(
            points: [
                trendPoint(id: 0, secondsFromNow: -6, ratio: 0.9),
                trendPoint(id: 1, secondsFromNow: -5, ratio: nil),
                trendPoint(id: 2, secondsFromNow: -4, ratio: 0.1)
            ],
            windowStart: fixedNow.addingTimeInterval(-10),
            windowEnd: fixedNow
        )

        XCTAssertTrue(layout.traces.isEmpty)
        XCTAssertEqual(
            try XCTUnwrap(layout.markers.only).y,
            0.9,
            accuracy: 0.000_001
        )
    }

    func testMemoryPressureLayoutHandlesEmptyAndSinglePoint() throws {
        let windowStart = fixedNow.addingTimeInterval(-60)
        let empty = MemoryPressureChartLayout.make(
            points: [
                trendPoint(
                    id: 0,
                    secondsFromNow: -20,
                    ratio: nil,
                    pressure: .unknown
                )
            ],
            windowStart: windowStart,
            windowEnd: fixedNow
        )
        XCTAssertTrue(empty.traces.isEmpty)
        XCTAssertTrue(empty.markers.isEmpty)
        XCTAssertFalse(empty.hasKnownData)

        let single = MemoryPressureChartLayout.make(
            points: [
                trendPoint(
                    id: 0,
                    secondsFromNow: -10,
                    ratio: 0.75,
                    pressure: .warning
                )
            ],
            windowStart: windowStart,
            windowEnd: fixedNow
        )
        XCTAssertTrue(single.traces.isEmpty)
        let marker = try XCTUnwrap(single.markers.only)
        XCTAssertEqual(marker.x, 5.0 / 6.0, accuracy: 0.000_001)
        XCTAssertEqual(marker.y, 0.25, accuracy: 0.000_001)
        XCTAssertEqual(marker.pressure, .warning)
        XCTAssertTrue(single.hasKnownData)

        let drawingPlan = MemoryPressureChartDrawingPlan.make(layout: single)
        XCTAssertEqual(drawingPlan.commands.map(\.kind), [.marker])
        XCTAssertEqual(drawingPlan.commands.only?.points, [marker])
    }

    func testMemoryPressureDrawingPlanClosesEachTraceAndDrawsAllFillsBeforeStrokes() {
        let layout = MemoryPressureChartLayout.make(
            points: [
                trendPoint(id: 0, secondsFromNow: -55, ratio: 0.20),
                trendPoint(id: 1, secondsFromNow: -50, ratio: 0.25),
                trendPoint(id: 2, secondsFromNow: -40, ratio: nil),
                trendPoint(
                    id: 3,
                    secondsFromNow: -30,
                    ratio: 0.45,
                    pressure: .warning
                ),
                trendPoint(
                    id: 4,
                    secondsFromNow: -25,
                    ratio: 0.50,
                    pressure: .warning
                ),
                trendPoint(
                    id: 5,
                    secondsFromNow: -20,
                    ratio: 0.55,
                    pressure: .critical
                ),
                trendPoint(
                    id: 6,
                    secondsFromNow: -15,
                    ratio: 0.60,
                    pressure: .critical
                )
            ],
            windowStart: fixedNow.addingTimeInterval(-60),
            windowEnd: fixedNow
        )
        let plan = MemoryPressureChartDrawingPlan.make(layout: layout)

        XCTAssertEqual(layout.traces.map(\.pressure), [
            .normal, .warning, .critical
        ])
        XCTAssertEqual(plan.commands.map(\.kind), [
            .fill, .fill, .fill,
            .stroke, .stroke, .stroke,
            .marker
        ])
        XCTAssertEqual(
            plan.commands.filter { $0.kind == .fill }.map(\.pressure),
            [.normal, .warning, .critical]
        )
        XCTAssertTrue(
            plan.commands.filter { $0.kind == .fill }
                .allSatisfy(\.closesToBaseline)
        )
        XCTAssertTrue(
            plan.commands.filter { $0.kind == .fill }
                .allSatisfy { command in
                    command.points.count >= 4
                        && command.points.suffix(2).allSatisfy { $0.y == 1 }
                        && command.points[command.points.count - 2].x
                            == command.points[command.points.count - 3].x
                        && command.points.last?.x == command.points.first?.x
                }
        )
        XCTAssertTrue(
            plan.commands.filter { $0.kind != .fill }
                .allSatisfy { !$0.closesToBaseline }
        )
        XCTAssertFalse(
            plan.commands.contains { command in
                command.points.contains { $0.timestamp == fixedNow.addingTimeInterval(-40) }
            }
        )
    }

    func testMemoryPressureLayoutDoesNotDropContinuousRatioAcrossUnknownPressure() {
        let source = [
            trendPoint(
                id: 0,
                secondsFromNow: -50,
                ratio: 0.80,
                pressure: .warning
            ),
            trendPoint(
                id: 1,
                secondsFromNow: -40,
                ratio: 0.81,
                pressure: .warning
            ),
            trendPoint(
                id: 2,
                secondsFromNow: -30,
                ratio: 0.82,
                pressure: .unknown
            ),
            trendPoint(
                id: 3,
                secondsFromNow: -20,
                ratio: 0.83,
                pressure: .unknown
            ),
            trendPoint(
                id: 4,
                secondsFromNow: -10,
                ratio: 0.84,
                pressure: .warning
            )
        ]
        let layout = MemoryPressureChartLayout.make(
            points: source,
            windowStart: fixedNow.addingTimeInterval(-60),
            windowEnd: fixedNow
        )

        let renderedTimestamps = Set(layout.traces.flatMap(\.points).map(\.timestamp))
        XCTAssertEqual(renderedTimestamps, Set(source.map(\.timestamp)))
        XCTAssertEqual(layout.traces.map(\.pressure), [.warning, .unknown])
        XCTAssertEqual(layout.markers.only?.timestamp, fixedNow.addingTimeInterval(-10))
        XCTAssertEqual(layout.markers.only?.pressure, .warning)
    }

    func testMemoryPressureLayoutNeverFallsBackToUsedMemoryRatio() {
        let layout = MemoryPressureChartLayout.make(
            points: [
                MemoryTrendPoint(
                    id: 0,
                    timestamp: fixedNow.addingTimeInterval(-20),
                    loadRatio: 0.95,
                    pressureRatio: nil,
                    pressure: .warning
                ),
                MemoryTrendPoint(
                    id: 1,
                    timestamp: fixedNow.addingTimeInterval(-10),
                    loadRatio: 0.96,
                    pressureRatio: 0.25,
                    pressure: .warning
                )
            ],
            windowStart: fixedNow.addingTimeInterval(-30),
            windowEnd: fixedNow
        )

        XCTAssertTrue(layout.traces.isEmpty)
        XCTAssertEqual(layout.markers.only?.y, 0.75)
    }

    private func trendPoint(
        id: Int,
        secondsFromNow: TimeInterval,
        ratio: Double?,
        pressure: MemoryPressureState = .normal
    ) -> MemoryTrendPoint {
        MemoryTrendPoint(
            id: id,
            timestamp: fixedNow.addingTimeInterval(secondsFromNow),
            loadRatio: nil,
            pressureRatio: ratio,
            pressure: pressure
        )
    }

    private func quotaProvider(
        rowState: Stage3ProviderRowState,
        dataState: Stage3ProviderDataState,
        activity: Stage3ProviderActivity = .idle,
        partialDataState: Stage3PartialDataState? = nil,
        loginMethod: LoginMethod?,
        failureCode: FailureCode?,
        products: [Stage3QuotaProductProjection]
    ) -> Stage3ProviderProjection {
        Stage3ProviderProjection(
            id: .ark,
            rowState: rowState,
            dataState: dataState,
            activity: activity,
            partialDataState: partialDataState,
            failureCode: failureCode,
            loginMethod: loginMethod,
            products: products,
            capturedAt: fixedNow,
            origin: .runtime
        )
    }
}

private extension Array {
    var only: Element? { count == 1 ? self[0] : nil }
}
