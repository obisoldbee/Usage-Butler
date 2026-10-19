import XCTest
import UsageButlerCore
import UsageButlerDomain
import UsageButlerProviders
@testable import UsageButlerUI

@MainActor
final class QuotaDisplayModeTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_792_022_400)

    private func metric(_ raw: Decimal, _ direction: Stage3QuotaDirection,
                        text: String? = nil, detail: String? = nil,
                        state: Stage3QuotaMetricDataState? = nil,
                        id: String = "sample", window: String? = nil) -> Stage3QuotaMetricProjection {
        .init(id: id, title: "每周", windowBadge: window, value: .percent(value: raw, direction: direction),
              dataState: state, displayValueText: text, detailText: detail)
    }

    private func check(_ metric: Stage3QuotaMetricProjection, mode: QuotaDisplayMode,
                       text: String, fraction: Double, band: QuotaAvailabilityBand,
                       file: StaticString = #filePath, line: UInt = #line) throws {
        let presentation = QuotaMetricPresentation(metric: metric, mode: mode)
        XCTAssertEqual(presentation.valueText, text, file: file, line: line)
        XCTAssertEqual(try XCTUnwrap(presentation.progressFraction), fraction, accuracy: 1e-12, file: file, line: line)
        XCTAssertEqual(QuotaAvailabilityBand.band(value: metric.value, asOf: now, now: now,
                                                  refreshIntervalSeconds: 300), band, file: file, line: line)
    }

    func testDefaultAndCorruptPreferencesResolveToSource() {
        XCTAssertEqual(QuotaDisplayMode.allCases.map(\.title), ["跟随来源", "统一已用", "统一剩余"])
        for raw in ["", "unknown", "USED", "remaining%", "source\0"] {
            XCTAssertEqual(QuotaDisplayMode.validated(storedValue: raw), .source)
        }
        for mode in QuotaDisplayMode.allCases {
            XCTAssertEqual(QuotaDisplayMode.validated(storedValue: mode.rawValue), mode)
        }
    }

    func testPreferencePersistsAcrossSeparateDefaultsInstancesAndInvalidTypes() throws {
        let suite = "io.github.obisoldbee.UsageButler.Tests.QuotaDisplay." + UUID().uuidString
        let first = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { first.removePersistentDomain(forName: suite) }
        XCTAssertNil(first.object(forKey: QuotaDisplayMode.preferenceKey))
        XCTAssertEqual(QuotaDisplayMode.validated(storedValue: first.string(forKey: QuotaDisplayMode.preferenceKey) ?? ""), .source)
        for mode in QuotaDisplayMode.allCases {
            first.set(mode.rawValue, forKey: QuotaDisplayMode.preferenceKey)
            first.synchronize()
            let reopened = try XCTUnwrap(UserDefaults(suiteName: suite))
            XCTAssertEqual(QuotaDisplayMode.validated(storedValue: reopened.string(forKey: QuotaDisplayMode.preferenceKey) ?? ""), mode)
        }
        for invalid: Any in [42, ["remaining"], ["mode": "used"]] {
            first.set(invalid, forKey: QuotaDisplayMode.preferenceKey)
            XCTAssertEqual(QuotaDisplayMode.validated(storedValue: first.string(forKey: QuotaDisplayMode.preferenceKey) ?? ""), .source)
        }
    }

    func testOpenAI21RemainingBecomes79UsedAndStaysRed() throws {
        let source = metric(21, .remaining)
        try check(source, mode: .source, text: "剩余 21%", fraction: 0.21, band: .low)
        try check(source, mode: .used, text: "已用 79%", fraction: 0.79, band: .low)
        try check(source, mode: .remaining, text: "剩余 21%", fraction: 0.21, band: .low)
    }

    func testMiniMax21UsedBecomes79RemainingAndStaysGreen() throws {
        let source = metric(21, .used)
        try check(source, mode: .source, text: "已用 21%", fraction: 0.21, band: .high)
        try check(source, mode: .used, text: "已用 21%", fraction: 0.21, band: .high)
        try check(source, mode: .remaining, text: "剩余 79%", fraction: 0.79, band: .high)
    }

    func testGrokExactInteger67Becomes33Remaining() throws {
        let source = metric(67, .used, text: "已用 67%")
        try check(source, mode: .source, text: "已用 67%", fraction: 0.67, band: .medium)
        try check(source, mode: .used, text: "已用 67%", fraction: 0.67, band: .medium)
        try check(source, mode: .remaining, text: "剩余 33%", fraction: 0.33, band: .medium)
    }

    func testGrokFractionUsesUnroundedComplementAndOverridesCustomText() throws {
        let source = metric(67.89, .used, text: "已用 67%", detail: "本月额外用量 US$12.34")
        try check(source, mode: .source, text: "已用 67%", fraction: 0.6789, band: .medium)
        try check(source, mode: .used, text: "已用 67%", fraction: 0.6789, band: .medium)
        try check(source, mode: .remaining, text: "剩余 32%", fraction: 0.3211, band: .medium)
        let transformed = QuotaMetricPresentation(metric: source, mode: .remaining)
        XCTAssertEqual(transformed.detailText, "本月额外用量 US$12.34")
        XCTAssertEqual(source.displayValueText, "已用 67%")
        XCTAssertEqual(source.value, .percent(value: 67.89, direction: .used))
    }

    func testNativeGrokMapperFeedsExactRatioAndKeepsMonthlyDetailUnchanged() throws {
        for (used, remaining) in [(6700, "剩余 33%"), (6789, "剩余 32%")] {
            let bytes = Data("{\"availability\":\"available\",\"weeklyIncludedStatus\":{\"status\":\"metered\"},\"weeklyIncludedUsage\":{\"usedCents\":\(used),\"budgetCents\":10000},\"monthlyUsage\":{\"usedCents\":1234,\"creditsUsedCents\":999}}".utf8)
            let data = try GrokSharedQuotaMapper.map(bytes, fetchedAt: now, sessionScope: "SYNTHETIC-DISPLAY")
            var state = ProviderBootstrap.initialState(id: .grokBot, capabilities: .init(contractVersion: "test", loginMethod: nil,
                hasOfficialDocumentation: true, allowsExecutableSelection: false), now: now)
            state = ProviderReducer.reduce(state: state, event: .refreshSucceeded(data), now: now)
            let row = try XCTUnwrap(LiveProviderProjectionMapper.map(state, now: now).products.first?.metrics.first)
            XCTAssertEqual(QuotaMetricPresentation(metric: row, mode: .remaining).valueText, remaining)
            XCTAssertTrue(QuotaMetricPresentation(metric: row, mode: .remaining).detailText!.contains(row.detailText!))
            XCTAssertTrue(row.detailText!.contains("本月额外用量 US$12.34"))
            XCTAssertEqual(state.lastGood, data)
        }
    }

    func testUnifiedSameDirectionUsesConsistentFloorAndMinimumOne() throws {
        for (raw, expected) in [(0.0, "0"), (0.001, "1"), (0.9999, "1"), (1, "1"),
                                (1.9999, "1"), (21.9999, "21"), (99.9999, "99"), (100, "100")] {
            for direction: Stage3QuotaDirection in [.used, .remaining] {
                let mode: QuotaDisplayMode = direction == .used ? .used : .remaining
                let prefix = direction == .used ? "已用" : "剩余"
                XCTAssertEqual(QuotaMetricPresentation(metric: metric(Decimal(raw), direction), mode: mode).valueText, "\(prefix) \(expected)%")
            }
        }
        try check(metric(99.999, .used), mode: .remaining, text: "剩余 1%", fraction: 0.00001, band: .low)
        try check(metric(99.999, .remaining), mode: .used, text: "已用 1%", fraction: 0.00001, band: .high)
    }

    func testSourceModePreservesExistingDecimalAndOfficialCopy() {
        XCTAssertEqual(QuotaMetricPresentation(metric: metric(21.9876, .remaining), mode: .source).valueText, "剩余 21.99%")
        XCTAssertEqual(QuotaMetricPresentation(metric: metric(0.1, .used, text: "已用 1%"), mode: .source).valueText, "已用 1%")
        XCTAssertEqual(QuotaMetricPresentation(metric: metric(21.9876, .remaining), mode: .used).valueText, "已用 78%")
        for mode in QuotaDisplayMode.allCases {
            XCTAssertNil(QuotaMetricPresentation(metric: metric(21.9876, .remaining), mode: mode).detailText)
        }
    }

    func testZeroAndHundredEndpointsInBothDirections() throws {
        for direction: Stage3QuotaDirection in [.used, .remaining] {
            for raw in [0.0, 100] {
                let source = metric(Decimal(raw), direction)
                for mode in QuotaDisplayMode.allCases {
                    let same = mode == .source || (mode == .used && direction == .used) || (mode == .remaining && direction == .remaining)
                    let value = same ? raw : 100 - raw
                    let presentation = QuotaMetricPresentation(metric: source, mode: mode)
                    XCTAssertEqual(try XCTUnwrap(presentation.progressFraction), value / 100)
                    XCTAssertTrue(presentation.valueText.hasSuffix(" \(Int(value))%"))
                }
            }
        }
    }

    func testAvailabilityColorBoundariesStayBoundToSourceInEveryMode() throws {
        for (remaining, band): (Double, QuotaAvailabilityBand) in [(0, .low), (30, .low), (30.01, .medium), (60, .medium), (60.01, .high), (100, .high)] {
            for source in [metric(Decimal(remaining), .remaining), metric(100 - Decimal(remaining), .used)] {
                for mode in QuotaDisplayMode.allCases {
                    XCTAssertNotNil(QuotaMetricPresentation(metric: source, mode: mode).progressFraction)
                    XCTAssertEqual(QuotaAvailabilityBand.band(value: source.value, asOf: now, now: now, refreshIntervalSeconds: 300), band)
                }
            }
        }
    }

    func testStaleLostThresholdManualOnlyAndOriginalTimestampAreUnchanged() {
        let source = metric(21, .remaining, state: .stale(asOf: now.addingTimeInterval(-901)))
        for mode in QuotaDisplayMode.allCases {
            XCTAssertNotNil(QuotaMetricPresentation(metric: source, mode: mode).progressFraction)
            XCTAssertEqual(source.dataState?.asOf, now.addingTimeInterval(-901))
            XCTAssertEqual(QuotaAvailabilityBand.band(value: source.value, asOf: source.dataState?.asOf, now: now, refreshIntervalSeconds: 300), .lost)
            XCTAssertEqual(QuotaAvailabilityBand.band(value: source.value, asOf: source.dataState?.asOf, now: now, refreshIntervalSeconds: 0), .low)
            XCTAssertEqual(QuotaAvailabilityBand.band(value: source.value, asOf: now.addingTimeInterval(-900), now: now, refreshIntervalSeconds: 300), .low)
            XCTAssertEqual(QuotaAvailabilityBand.band(value: source.value, asOf: nil, now: now, refreshIntervalSeconds: 300), .lost)
        }
    }

    func testInvalidPercentNeverClampsIntoAValidBar() {
        for raw: Decimal in [-1, 100.01, .nan] {
            for mode in QuotaDisplayMode.allCases {
                let source = metric(raw, .used, text: "已用 67%")
                let presentation = QuotaMetricPresentation(metric: source, mode: mode)
                XCTAssertEqual(presentation.valueText, "额度数值无效")
                XCTAssertNil(presentation.progressFraction)
                XCTAssertNil(QuotaAvailabilityBand.band(value: source.value, asOf: now, now: now, refreshIntervalSeconds: 300))
            }
        }
    }

    func testNonPercentAndExplicitAbnormalStatesRemainVerbatim() {
        let values: [Stage3QuotaValue] = [.unlimited, .usedCount(used: 3, total: 9, unit: "次"), .entitlement(availableCount: 2),
            .balance(amount: Decimal(string: "12.34"), unlimited: false), .balance(amount: nil, unlimited: false),
            .balance(amount: nil, unlimited: true), .unavailable]
        for value in values {
            let row = Stage3QuotaMetricProjection(id: "non-percent", title: "权益", value: value, detailText: "原始权益详情")
            let baseline = QuotaMetricPresentation(metric: row, mode: .source)
            for mode in QuotaDisplayMode.allCases {
                let result = QuotaMetricPresentation(metric: row, mode: mode)
                XCTAssertEqual(result.valueText, baseline.valueText)
                XCTAssertEqual(result.detailText, "原始权益详情")
                XCTAssertNil(result.progressFraction)
            }
        }
        for text in ["周用量未提供", "周额度为零", "已超出周额度", "周额度暂不可用", "共享周额度不适用"] {
            let row = Stage3QuotaMetricProjection(id: "invalid", title: "每周", value: .unavailable, displayValueText: text)
            for mode in QuotaDisplayMode.allCases {
                XCTAssertEqual(QuotaMetricPresentation(metric: row, mode: mode).valueText, text)
                XCTAssertNil(QuotaMetricPresentation(metric: row, mode: mode).progressFraction)
            }
        }
    }

    func testMultipleProductsAndWindowsConvertIndependentlyWithoutChangingProjection() {
        let products = [Stage3QuotaProductProjection(id: "agent", metrics: [metric(21, .used, id: "agent-session", window: "会话"), metric(67.89, .used, id: "agent-week", window: "每周")]),
                        Stage3QuotaProductProjection(id: "coding", metrics: [metric(0, .used, id: "coding-hour", window: "1小时"), metric(100, .used, id: "coding-week", window: "每周")])]
        let provider = Stage3ProviderProjection(id: .ark, rowState: .connected, products: products, capturedAt: now, origin: .runtime)
        let before = provider
        let results = provider.products.map { $0.metrics.map { QuotaMetricPresentation(metric: $0, mode: .remaining).valueText } }
        XCTAssertEqual(results, [["剩余 79%", "剩余 32%"], ["剩余 100%", "剩余 0%"]])
        XCTAssertEqual(provider, before)
    }
}
