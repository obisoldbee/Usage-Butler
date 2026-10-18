import XCTest
import UsageButlerCore
import UsageButlerDomain
import UsageButlerProviders
@testable import UsageButlerUI

@MainActor
final class QDMPrecisionPathTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_792_022_400)

    func testNearlyExhaustedDecimalRemains99UsedAndPositiveOneRemaining() throws {
        try check(used: "9999.9999999999999999", percent: "99.999999999999999999",
                  source: "已用 99%", usedText: "已用 99%", remaining: "剩余 1%", band: .low)
    }

    func testJustAboveThirtyAvailableRemainsYellow() throws {
        try check(used: "6999.9999999999999999", percent: "69.999999999999999999",
                  source: "已用 69%", usedText: "已用 69%", remaining: "剩余 30%", band: .medium)
    }

    func testJustAboveSixtyAvailableRemainsGreen() throws {
        try check(used: "3999.9999999999999999", percent: "39.999999999999999999",
                  source: "已用 39%", usedText: "已用 39%", remaining: "剩余 60%", band: .high)
    }

    func testExactColorThresholdsEndpointsAndPositiveSubOne() throws {
        for (used, percent, usedText, remaining, band): (String, String, String, String, QuotaAvailabilityBand) in [
            ("7000", "70", "已用 70%", "剩余 30%", .low),
            ("4000", "40", "已用 40%", "剩余 60%", .medium),
            ("10000", "100", "已用 100%", "剩余 0%", .low),
            ("0", "0", "已用 0%", "剩余 100%", .high),
            ("0.0000000000000001", "0.000000000000000001", "已用 1%", "剩余 99%", .high)
        ] {
            try check(used: used, percent: percent, source: usedText,
                      usedText: usedText, remaining: remaining, band: band)
        }
    }

    private func check(used: String, percent: String, source: String, usedText: String,
                       remaining: String, band: QuotaAvailabilityBand,
                       file: StaticString = #filePath, line: UInt = #line) throws {
        // Unquoted number tokens pass through the actual production JSON decoder.
        let bytes = Data("""
        {"availability":"available","weeklyIncludedStatus":{"status":"metered"},
         "weeklyIncludedUsage":{"usedCents":\(used),"budgetCents":10000},
         "monthlyUsage":{"usedCents":1234,"creditsUsedCents":999}}
        """.utf8)
        let data = try GrokSharedQuotaMapper.map(bytes, fetchedAt: now, sessionScope: "SYNTHETIC-QDM-01")
        let shared = try XCTUnwrap(data.grokBotUsage?.shared)
        XCTAssertEqual(shared.usedCents, Decimal(string: used), "JSON Decimal must be exact", file: file, line: line)
        XCTAssertEqual(shared.usagePercent, Decimal(string: percent), file: file, line: line)
        XCTAssertEqual(shared.weeklyValueState, .available, file: file, line: line)
        var state = ProviderBootstrap.initialState(id: .grokBot,
            capabilities: .init(contractVersion: GrokSharedQuotaMapper.contractVersion, loginMethod: nil,
                                hasOfficialDocumentation: true, allowsExecutableSelection: false), now: now)
        state = ProviderReducer.reduce(state: state, event: .refreshSucceeded(data), now: now)
        XCTAssertEqual(state.lastGood, data, "Reducer must accept and retain the exact source", file: file, line: line)
        let projected = LiveProviderProjectionMapper.map(state, now: now)
        let metric = try XCTUnwrap(projected.products.first?.metrics.first)
        let modes: [(QuotaDisplayMode, String)] = [(.source, source), (.used, usedText), (.remaining, remaining)]
        for (mode, expected) in modes {
            let result = QuotaMetricPresentation(metric: metric, mode: mode)
            print("QDM-01 used=\(used) decoded=\(shared.usedCents!) ratio=\(shared.usagePercent!) mode=\(mode.rawValue) actual=\(result.valueText) expected=\(expected)")
            XCTAssertEqual(result.valueText, expected, "usedCents=\(used), mode=\(mode)", file: file, line: line)
            XCTAssertNotNil(result.progressFraction, file: file, line: line)
            if used != "10000", mode == .remaining {
                XCTAssertGreaterThan(try XCTUnwrap(result.progressFraction), 0, file: file, line: line)
            }
            XCTAssertEqual(QuotaAvailabilityBand.band(value: metric.value, asOf: now, now: now,
                refreshIntervalSeconds: 300), band, "usedCents=\(used), mode=\(mode)", file: file, line: line)
        }
        XCTAssertEqual(state.lastGood, data, file: file, line: line)
    }
}
