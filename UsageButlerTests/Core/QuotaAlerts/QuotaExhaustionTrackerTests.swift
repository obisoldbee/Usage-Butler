import XCTest
import UsageButlerCore
import UsageButlerDomain

final class QuotaExhaustionTrackerTests: XCTestCase {
    private let arkKey = "metric|3:ark|6:prod-1|0:|3:m-1"

    private func status(
        providerID: ProviderID = .ark,
        metricKey: String,
        cycleKey: String = "reset:1000",
        isExhausted: Bool,
        usageSummary: String? = nil
    ) -> QuotaMetricStatus {
        QuotaMetricStatus(
            providerID: providerID,
            metricKey: metricKey,
            productLabel: "prod-1",
            windowLabel: nil,
            usageSummary: usageSummary ?? (isExhausted ? "已用 100%" : "已用 42%"),
            cycleKey: cycleKey,
            resetAt: nil,
            isExhausted: isExhausted
        )
    }

    // MARK: - exhaustion edges

    func testFirstExhaustionIsFreshAndArmsMarker() {
        var markers: [String: String] = [:]

        let outcome = QuotaExhaustionTracker.consume(
            statuses: [status(metricKey: arkKey, isExhausted: true)],
            into: &markers
        )

        XCTAssertEqual(outcome.freshExhaustions.map(\.metricKey), [arkKey])
        XCTAssertTrue(outcome.recoveries.isEmpty)
        XCTAssertEqual(markers[arkKey], "reset:1000")
    }

    func testSameCycleKeyRepeatIsSuppressed() {
        var markers = [arkKey: "reset:1000"]

        let outcome = QuotaExhaustionTracker.consume(
            statuses: [status(metricKey: arkKey, isExhausted: true)],
            into: &markers
        )

        XCTAssertTrue(outcome.freshExhaustions.isEmpty)
        XCTAssertTrue(outcome.recoveries.isEmpty)
        XCTAssertEqual(markers[arkKey], "reset:1000")
    }

    func testNewCycleKeyReArmsAfterReset() {
        var markers = [arkKey: "reset:1000"]

        let outcome = QuotaExhaustionTracker.consume(
            statuses: [
                status(metricKey: arkKey, cycleKey: "reset:2000", isExhausted: true)
            ],
            into: &markers
        )

        XCTAssertEqual(outcome.freshExhaustions.map(\.metricKey), [arkKey])
        XCTAssertEqual(markers[arkKey], "reset:2000")
    }

    // MARK: - reset-cycle jitter tolerance

    func testResetJitterWithinToleranceIsSuppressedAndKeepsPinnedMarker() {
        // Providers may report the same reset instant with second-level
        // jitter between reads; each jittered read must not re-notify.
        var markers = [arkKey: "reset:1787196926.0"]

        let outcome = QuotaExhaustionTracker.consume(
            statuses: [
                status(metricKey: arkKey, cycleKey: "reset:1787196986.0", isExhausted: true)
            ],
            into: &markers
        )

        XCTAssertTrue(outcome.freshExhaustions.isEmpty)
        XCTAssertTrue(outcome.recoveries.isEmpty)
        XCTAssertEqual(
            markers[arkKey],
            "reset:1787196926.0",
            "A tolerant match retains the pinned marker so drift cannot accumulate"
        )
    }

    func testResetJitterAtToleranceBoundaryIsSuppressed() {
        let pinned = 1_787_196_926.0
        let boundary = pinned + QuotaExhaustionTracker.resetCycleToleranceSeconds
        var markers = [arkKey: "reset:\(pinned)"]

        let outcome = QuotaExhaustionTracker.consume(
            statuses: [
                status(metricKey: arkKey, cycleKey: "reset:\(boundary)", isExhausted: true)
            ],
            into: &markers
        )

        XCTAssertTrue(outcome.freshExhaustions.isEmpty)
        XCTAssertEqual(markers[arkKey], "reset:\(pinned)")
    }

    func testResetShiftBeyondToleranceReArms() {
        let pinned = 1_787_196_926.0
        let shifted = pinned + QuotaExhaustionTracker.resetCycleToleranceSeconds + 1
        var markers = [arkKey: "reset:\(pinned)"]

        let outcome = QuotaExhaustionTracker.consume(
            statuses: [
                status(metricKey: arkKey, cycleKey: "reset:\(shifted)", isExhausted: true)
            ],
            into: &markers
        )

        XCTAssertEqual(outcome.freshExhaustions.map(\.metricKey), [arkKey])
        XCTAssertEqual(markers[arkKey], "reset:\(shifted)")
    }

    func testGenuineWeeklyResetReArms() {
        var markers = [arkKey: "reset:1787196926.0"]

        let outcome = QuotaExhaustionTracker.consume(
            statuses: [
                status(metricKey: arkKey, cycleKey: "reset:1787801726.0", isExhausted: true)
            ],
            into: &markers
        )

        XCTAssertEqual(outcome.freshExhaustions.map(\.metricKey), [arkKey])
        XCTAssertEqual(markers[arkKey], "reset:1787801726.0")
    }

    func testToleranceDoesNotBridgeMismatchedKeyKinds() {
        var markers = [arkKey: "unknown"]

        let outcome = QuotaExhaustionTracker.consume(
            statuses: [
                status(metricKey: arkKey, cycleKey: "reset:1787196926.0", isExhausted: true)
            ],
            into: &markers
        )

        XCTAssertEqual(outcome.freshExhaustions.map(\.metricKey), [arkKey])
        XCTAssertEqual(markers[arkKey], "reset:1787196926.0")
    }

    func testUnparseableResetMarkerDoesNotSuppress() {
        var markers = [arkKey: "reset:not-a-number"]

        let outcome = QuotaExhaustionTracker.consume(
            statuses: [
                status(metricKey: arkKey, cycleKey: "reset:1787196926.0", isExhausted: true)
            ],
            into: &markers
        )

        XCTAssertEqual(outcome.freshExhaustions.map(\.metricKey), [arkKey])
        XCTAssertEqual(markers[arkKey], "reset:1787196926.0")
    }

    func testHealthyMetricWithoutMarkerEmitsNothing() {
        var markers: [String: String] = [:]

        let outcome = QuotaExhaustionTracker.consume(
            statuses: [status(metricKey: arkKey, isExhausted: false)],
            into: &markers
        )

        XCTAssertTrue(outcome.freshExhaustions.isEmpty)
        XCTAssertTrue(outcome.recoveries.isEmpty)
        XCTAssertTrue(markers.isEmpty)
    }

    // MARK: - recovery edges

    func testRecoveryEmitsOnceAndDropsMarker() {
        var markers = [arkKey: "reset:1000"]

        let first = QuotaExhaustionTracker.consume(
            statuses: [
                status(metricKey: arkKey, cycleKey: "reset:2000", isExhausted: false)
            ],
            into: &markers
        )
        XCTAssertTrue(first.freshExhaustions.isEmpty)
        XCTAssertEqual(first.recoveries.map(\.metricKey), [arkKey])
        XCTAssertNil(markers[arkKey], "The recovery edge must consume the marker")

        // A second healthy snapshot has no marker left to recover from.
        let second = QuotaExhaustionTracker.consume(
            statuses: [
                status(metricKey: arkKey, cycleKey: "reset:2000", isExhausted: false)
            ],
            into: &markers
        )
        XCTAssertTrue(second.recoveries.isEmpty)
    }

    func testRecoveryThenReExhaustionIsFreshAgain() {
        var markers = [arkKey: "reset:1000"]

        let recovered = QuotaExhaustionTracker.consume(
            statuses: [
                status(metricKey: arkKey, cycleKey: "reset:2000", isExhausted: false)
            ],
            into: &markers
        )
        XCTAssertEqual(recovered.recoveries.map(\.metricKey), [arkKey])

        let reExhausted = QuotaExhaustionTracker.consume(
            statuses: [
                status(metricKey: arkKey, cycleKey: "reset:2000", isExhausted: true)
            ],
            into: &markers
        )
        XCTAssertEqual(reExhausted.freshExhaustions.map(\.metricKey), [arkKey])
    }

    func testUnavailableMetricRetainsMarkerSilently() {
        var markers = [arkKey: "reset:1000"]

        let outcome = QuotaExhaustionTracker.consume(
            statuses: [],
            into: &markers
        )

        XCTAssertTrue(outcome.freshExhaustions.isEmpty)
        XCTAssertTrue(
            outcome.recoveries.isEmpty,
            "A vanished or unavailable value is not proof of recovery"
        )
        XCTAssertEqual(
            markers[arkKey],
            "reset:1000",
            "Absence must not re-arm the cycle; a partial or unavailable read would otherwise re-notify the same exhaustion"
        )
    }

    func testAbsentThenExhaustedSameCycleIsStillSuppressed() {
        // Regression: a flapping read (metric absent from one snapshot, back
        // and exhausted in the next) must not re-notify within one cycle.
        var markers = [arkKey: "reset:1000"]

        let afterAbsentRead = QuotaExhaustionTracker.consume(
            statuses: [],
            into: &markers
        )
        XCTAssertTrue(afterAbsentRead.freshExhaustions.isEmpty)
        XCTAssertTrue(afterAbsentRead.recoveries.isEmpty)

        let afterCompleteRead = QuotaExhaustionTracker.consume(
            statuses: [status(metricKey: arkKey, cycleKey: "reset:1000", isExhausted: true)],
            into: &markers
        )
        XCTAssertTrue(
            afterCompleteRead.freshExhaustions.isEmpty,
            "The metric never recovered, so its return is the same cycle edge, not a fresh one"
        )
        XCTAssertTrue(afterCompleteRead.recoveries.isEmpty)
        XCTAssertEqual(markers[arkKey], "reset:1000")
    }

    // MARK: - provider scoping

    func testMarkerOwnershipIsScopedToTheRefreshingProvider() {
        // Stable keys embed the provider, so a refresh only ever touches the
        // markers for metric keys its own snapshot reports.
        let openAIKey = "metric|6:openAI|6:prod-1|0:|3:m-1"
        var markers = [
            arkKey: "reset:1000",
            openAIKey: "reset:700"
        ]

        let afterOpenAIRefresh = QuotaExhaustionTracker.consume(
            statuses: [
                status(providerID: .openAI, metricKey: openAIKey, cycleKey: "reset:700", isExhausted: true)
            ],
            into: &markers
        )
        XCTAssertTrue(afterOpenAIRefresh.freshExhaustions.isEmpty)
        XCTAssertTrue(afterOpenAIRefresh.recoveries.isEmpty)
        XCTAssertEqual(markers[arkKey], "reset:1000")
        XCTAssertEqual(markers[openAIKey], "reset:700")

        // An ark recovery drops only the ark marker; the openAI marker that
        // this refresh does not own stays armed.
        let afterArkRecovery = QuotaExhaustionTracker.consume(
            statuses: [status(metricKey: arkKey, isExhausted: false)],
            into: &markers
        )
        XCTAssertEqual(afterArkRecovery.recoveries.map(\.metricKey), [arkKey])
        XCTAssertNil(markers[arkKey])
        XCTAssertEqual(markers[openAIKey], "reset:700")
    }

    func testDistinctMetricKeysTrackIndependently() {
        let secondKey = "metric|3:ark|6:prod-1|0:|3:m-2"
        var markers = [arkKey: "reset:1000"]

        // The snapshot reports both metrics exhausted; only m-2 is a new edge.
        let outcome = QuotaExhaustionTracker.consume(
            statuses: [
                status(metricKey: arkKey, isExhausted: true),
                status(metricKey: secondKey, isExhausted: true)
            ],
            into: &markers
        )

        XCTAssertEqual(outcome.freshExhaustions.map(\.metricKey), [secondKey])
        XCTAssertEqual(markers[arkKey], "reset:1000")
        XCTAssertEqual(markers[secondKey], "reset:1000")
    }

    func testMixedSnapshotEmitsExhaustionAndRecoveryTogether() {
        let secondKey = "metric|3:ark|6:prod-1|0:|3:m-2"
        var markers = [arkKey: "reset:1000"]

        let outcome = QuotaExhaustionTracker.consume(
            statuses: [
                status(metricKey: arkKey, cycleKey: "reset:2000", isExhausted: false),
                status(metricKey: secondKey, isExhausted: true)
            ],
            into: &markers
        )

        XCTAssertEqual(outcome.freshExhaustions.map(\.metricKey), [secondKey])
        XCTAssertEqual(outcome.recoveries.map(\.metricKey), [arkKey])
        XCTAssertNil(markers[arkKey])
        XCTAssertEqual(markers[secondKey], "reset:1000")
    }
}
