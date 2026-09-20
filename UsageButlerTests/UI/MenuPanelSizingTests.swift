import XCTest
@testable import UsageButlerUI
@testable import UsageButlerCore
@testable import UsageButlerDomain

@MainActor
final class MenuPanelSizingTests: XCTestCase {
    func testShortPagesShrinkAndLongQuotaScrollsOnlyAtScreenLimit() {
        let sizing = MenuPanelSizing()
        sizing.setMaximumHeight(900)
        sizing.measure(contentHeight: 480, page: "quota")
        XCTAssertEqual(sizing.height, 537)
        sizing.measure(contentHeight: 496, page: "memory")
        sizing.select(page: "memory")
        XCTAssertEqual(sizing.height, 553)
        sizing.select(page: "quota")
        sizing.measure(contentHeight: 1100, page: "quota")
        XCTAssertEqual(sizing.height, 900)
        sizing.setMaximumHeight(650)
        XCTAssertEqual(sizing.height, 650)
        sizing.measure(contentHeight: 480, page: "quota")
        XCTAssertEqual(sizing.height, 537)
    }

    func testZeroAndInvalidMeasurementsDoNotCollapsePanel() {
        let sizing = MenuPanelSizing()
        sizing.measure(contentHeight: 496, page: "memory")
        sizing.select(page: "memory")
        sizing.measure(contentHeight: 0, page: "memory")
        sizing.measure(contentHeight: .nan, page: "memory")
        XCTAssertEqual(sizing.height, 553)
    }

    func testRetryUsesMonotonicDeadlineAndClampsElapsedGate() {
        let now = Date(timeIntervalSince1970: 1000)
        let reading = ClockReading(wallTime: now, monotonicTime: .init(nanoseconds: 100_000_000_000))
        XCTAssertEqual(ProviderRetryTiming.date(for: .backoff(until: .init(nanoseconds: 160_000_000_000), attempt: 2), reading: reading), now.addingTimeInterval(60))
        XCTAssertEqual(ProviderRetryTiming.date(for: .backoff(until: .init(nanoseconds: 99_000_000_000), attempt: 2), reading: reading), now)
        XCTAssertNil(ProviderRetryTiming.date(for: .open, reading: reading))
    }
}
