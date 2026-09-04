import XCTest
@testable import UsageButlerCore

final class ProviderFreshnessSLATests: XCTestCase {
    func testScheduledCadencesOweTwiceTheirIntervalWithAFloor() {
        XCTAssertEqual(ProviderFreshnessSLA.minimumScheduledStaleAfter, 600)
        XCTAssertEqual(ProviderFreshnessSLA.staleAfter(frequency: .oneMinute), 600)
        XCTAssertEqual(ProviderFreshnessSLA.staleAfter(frequency: .fiveMinutes), 600)
        XCTAssertEqual(ProviderFreshnessSLA.staleAfter(frequency: .fifteenMinutes), 1_800)
        XCTAssertEqual(ProviderFreshnessSLA.staleAfter(frequency: .thirtyMinutes), 3_600)
    }

    func testManualOnlyDataStillDecaysToStale() {
        XCTAssertEqual(ProviderFreshnessSLA.manualOnlyStaleAfter, 3_600)
        XCTAssertEqual(ProviderFreshnessSLA.staleAfter(frequency: .manualOnly), 3_600)
    }

    func testSLAStaysIndependentFromLifecycleRefreshDueThreshold() {
        XCTAssertEqual(ProviderLifecycleRefreshPolicy.refreshDueAfter, 60)
        for frequency in ProviderRefreshFrequency.allCases {
            XCTAssertGreaterThan(
                ProviderFreshnessSLA.staleAfter(frequency: frequency),
                ProviderLifecycleRefreshPolicy.refreshDueAfter,
                "The data-age SLA must never reuse the 60-second refresh-due threshold"
            )
        }
    }

    func testSLAIsMonotonicAcrossCadencesAndTicksAtABoundedInterval() {
        let scheduledLadder = ProviderRefreshFrequency.allCases
            .filter { $0 != .manualOnly }
            .map { ProviderFreshnessSLA.staleAfter(frequency: $0) }
        XCTAssertEqual(scheduledLadder, scheduledLadder.sorted())
        XCTAssertLessThanOrEqual(
            ProviderFreshnessSLA.staleAfter(frequency: .manualOnly),
            ProviderFreshnessSLA.staleAfter(frequency: .thirtyMinutes)
        )
        XCTAssertEqual(ProviderFreshnessSLA.tickInterval, 30)
    }
}
