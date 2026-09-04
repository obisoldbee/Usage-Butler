import Foundation
import XCTest
@testable import UsageButlerCore
@testable import UsageButlerDomain

final class ProviderLifecycleRefreshPolicyTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_786_300_000)

    func testPanelPresentedRefreshesStaleOrRefreshDueDataWithoutTreatingAgeAsFailure() {
        XCTAssertFalse(
            ProviderLifecycleRefreshPolicy.shouldRequestRefresh(
                freshness: .unknown,
                reason: .panelPresented,
                now: now
            )
        )
        XCTAssertFalse(
            ProviderLifecycleRefreshPolicy.shouldRequestRefresh(
                freshness: .fresh(asOf: now.addingTimeInterval(-59)),
                reason: .panelPresented,
                now: now
            )
        )
        XCTAssertTrue(
            ProviderLifecycleRefreshPolicy.shouldRequestRefresh(
                freshness: .fresh(asOf: now.addingTimeInterval(-60)),
                reason: .panelPresented,
                now: now
            )
        )
        XCTAssertTrue(
            ProviderLifecycleRefreshPolicy.shouldRequestRefresh(
                freshness: .stale(asOf: now, evaluatedAt: now),
                reason: .panelPresented,
                now: now
            )
        )
    }

    func testSystemWakeRefreshesUnknownOrStaleButNotFreshData() {
        XCTAssertTrue(
            ProviderLifecycleRefreshPolicy.shouldRequestRefresh(
                freshness: .unknown,
                reason: .systemWake,
                now: now
            )
        )
        XCTAssertTrue(
            ProviderLifecycleRefreshPolicy.shouldRequestRefresh(
                freshness: .stale(asOf: now, evaluatedAt: now),
                reason: .systemWake,
                now: now
            )
        )
        XCTAssertFalse(
            ProviderLifecycleRefreshPolicy.shouldRequestRefresh(
                freshness: .fresh(asOf: now.addingTimeInterval(-59)),
                reason: .systemWake,
                now: now
            )
        )
        XCTAssertTrue(
            ProviderLifecycleRefreshPolicy.shouldRequestRefresh(
                freshness: .fresh(asOf: now.addingTimeInterval(-60)),
                reason: .systemWake,
                now: now
            )
        )
    }

    func testRefreshDueThresholdIsSixtySeconds() {
        XCTAssertEqual(ProviderLifecycleRefreshPolicy.refreshDueAfter, 60)
    }
}
