import XCTest
import UsageButlerCore
import UsageButlerDomain

final class OpenAIWeeklyResetTrackerTests: XCTestCase {
    private let date = QuotaAlertFixture.date
    private let week: TimeInterval = 7 * 24 * 60 * 60

    func testFirstFullSampleOnlyEstablishesBaseline() {
        var markers: [String: String] = [:]

        let resets = consume(
            remaining: 100,
            fetchedAt: date,
            resetAt: date.addingTimeInterval(week),
            markers: &markers
        )

        XCTAssertTrue(resets.isEmpty)
        XCTAssertEqual(markers.count, 1)
    }

    func testRollingFullResetTargetDoesNotSignalAcrossOriginalTargetDate() {
        var markers: [String: String] = [:]
        _ = consume(
            remaining: 100,
            fetchedAt: date,
            resetAt: date.addingTimeInterval(week),
            markers: &markers
        )

        let fiveMinutesLater = date.addingTimeInterval(5 * 60)
        let polled = consume(
            remaining: 100,
            fetchedAt: fiveMinutesLater,
            resetAt: fiveMinutesLater.addingTimeInterval(week),
            markers: &markers
        )
        let sixHoursLater = date.addingTimeInterval(6 * 60 * 60)
        let afterSleep = consume(
            remaining: 100,
            fetchedAt: sixHoursLater,
            resetAt: sixHoursLater.addingTimeInterval(week),
            markers: &markers
        )
        let afterOriginalTarget = date.addingTimeInterval(week + 60)
        let afterTarget = consume(
            remaining: 100,
            fetchedAt: afterOriginalTarget,
            resetAt: afterOriginalTarget.addingTimeInterval(week),
            markers: &markers
        )

        XCTAssertTrue(polled.isEmpty)
        XCTAssertTrue(afterSleep.isEmpty)
        XCTAssertTrue(afterTarget.isEmpty)
    }

    func testStableFullTargetAnchorsUsageRoundedToFull() {
        var markers: [String: String] = [:]
        let boundary = date.addingTimeInterval(60 * 60)
        _ = consume(
            remaining: 100,
            fetchedAt: date,
            resetAt: boundary,
            markers: &markers
        )
        _ = consume(
            remaining: 100,
            fetchedAt: date.addingTimeInterval(60),
            resetAt: boundary,
            markers: &markers
        )
        let anchorConfirmation = consume(
            remaining: 100,
            fetchedAt: date.addingTimeInterval(2 * 60),
            resetAt: boundary,
            markers: &markers
        )
        _ = consume(
            remaining: 100,
            fetchedAt: boundary.addingTimeInterval(-60),
            resetAt: boundary,
            markers: &markers
        )

        let reset = consume(
            remaining: 100,
            fetchedAt: boundary.addingTimeInterval(60),
            resetAt: boundary.addingTimeInterval(week),
            markers: &markers
        )

        XCTAssertTrue(anchorConfirmation.isEmpty)
        XCTAssertEqual(reset.map(\.usageSummary), ["剩余 100%"])
        XCTAssertEqual(reset.first?.cycleKey, "reset:\(boundary.timeIntervalSince1970)")
    }

    func testConsumedWindowBoundarySignalsOnceWhileNewTargetRolls() {
        var markers: [String: String] = [:]
        let boundary = date.addingTimeInterval(60 * 60)
        _ = consume(
            remaining: 90,
            fetchedAt: date,
            resetAt: boundary,
            markers: &markers
        )

        let reset = consume(
            remaining: 100,
            fetchedAt: boundary,
            resetAt: boundary.addingTimeInterval(week),
            markers: &markers
        )
        let later = boundary.addingTimeInterval(6 * 60 * 60)
        let rolling = consume(
            remaining: 100,
            fetchedAt: later,
            resetAt: later.addingTimeInterval(week),
            markers: &markers
        )

        XCTAssertEqual(reset.map(\.usageSummary), ["剩余 100%"])
        XCTAssertTrue(rolling.isEmpty)
    }

    func testConsumedWindowBoundarySignalsAfterAppWasClosed() {
        var markers: [String: String] = [:]
        let boundary = date.addingTimeInterval(60 * 60)
        _ = consume(
            remaining: 99,
            fetchedAt: date,
            resetAt: boundary,
            markers: &markers
        )

        let returnedAt = boundary.addingTimeInterval(4 * 60 * 60)
        let reset = consume(
            remaining: 99,
            fetchedAt: returnedAt,
            resetAt: returnedAt.addingTimeInterval(week),
            markers: &markers
        )

        XCTAssertEqual(reset.map(\.usageSummary), ["剩余 99%"])
    }

    func testNearFullFallbackRequiresFivePointIncreaseWithinFiveMinutes() {
        var significantMarkers: [String: String] = [:]
        _ = consume(
            remaining: 80,
            fetchedAt: date,
            resetAt: nil,
            markers: &significantMarkers
        )
        let significant = consume(
            remaining: 99,
            fetchedAt: date.addingTimeInterval(5 * 60),
            resetAt: nil,
            markers: &significantMarkers
        )

        var jitterMarkers: [String: String] = [:]
        _ = consume(
            remaining: 98,
            fetchedAt: date,
            resetAt: nil,
            markers: &jitterMarkers
        )
        let jitter = consume(
            remaining: 99,
            fetchedAt: date.addingTimeInterval(5 * 60),
            resetAt: nil,
            markers: &jitterMarkers
        )

        XCTAssertEqual(significant.map(\.usageSummary), ["剩余 99%"])
        XCTAssertTrue(jitter.isEmpty)
    }

    func testNearFullNinetyNineFallbackRejectsAnOlderComparison() {
        var markers: [String: String] = [:]
        _ = consume(
            remaining: 60,
            fetchedAt: date,
            resetAt: nil,
            markers: &markers
        )

        let resets = consume(
            remaining: 99,
            fetchedAt: date.addingTimeInterval(
                OpenAIWeeklyResetTracker.comparisonWindow + 1
            ),
            resetAt: nil,
            markers: &markers
        )

        XCTAssertTrue(resets.isEmpty)
    }

    func testExactFullRecoveryDoesNotRequireFiveMinuteComparison() {
        var markers: [String: String] = [:]
        _ = consume(
            remaining: 65,
            fetchedAt: date,
            resetAt: nil,
            markers: &markers
        )

        let reset = consume(
            remaining: 100,
            fetchedAt: date.addingTimeInterval(30 * 60),
            resetAt: nil,
            markers: &markers
        )

        XCTAssertEqual(reset.map(\.usageSummary), ["剩余 100%"])
    }

    func testSignificantIncreaseBeforeBoundaryDoesNotSignalOrConsumeIt() {
        var markers: [String: String] = [:]
        let boundary = date.addingTimeInterval(60 * 60)
        _ = consume(
            remaining: 90,
            fetchedAt: date,
            resetAt: boundary,
            markers: &markers
        )

        let early = consume(
            remaining: 99,
            fetchedAt: date.addingTimeInterval(5 * 60),
            resetAt: boundary,
            markers: &markers
        )
        let atBoundary = consume(
            remaining: 99,
            fetchedAt: boundary,
            resetAt: boundary.addingTimeInterval(week),
            markers: &markers
        )

        XCTAssertTrue(early.isEmpty)
        XCTAssertEqual(atBoundary.map(\.usageSummary), ["剩余 99%"])
    }

    func testStartedReplacementWindowSignalsBeforeDriftedFutureBoundary() {
        var markers: [String: String] = [:]
        let staleBoundary = date.addingTimeInterval(2 * 24 * 60 * 60)
        _ = consume(
            remaining: 20,
            fetchedAt: date,
            resetAt: staleBoundary,
            markers: &markers
        )
        let replacementSample = date.addingTimeInterval(10 * 60)
        let replacementBoundary = replacementSample.addingTimeInterval(week)

        let reset = consume(
            remaining: 89,
            fetchedAt: replacementSample,
            resetAt: replacementBoundary,
            markers: &markers
        )

        XCTAssertEqual(reset.map(\.usageSummary), ["剩余 89%"])
        XCTAssertEqual(activeBoundary(in: markers), replacementBoundary)
    }

    func testStartedReplacementWindowRepairsMarkerWithoutLateReplay() {
        var markers: [String: String] = [:]
        let staleBoundary = date.addingTimeInterval(2 * 24 * 60 * 60)
        _ = consume(
            remaining: 89,
            fetchedAt: date,
            resetAt: staleBoundary,
            markers: &markers
        )
        let replacementSample = date.addingTimeInterval(10 * 60)
        let replacementBoundary = replacementSample.addingTimeInterval(week)

        let reset = consume(
            remaining: 89,
            fetchedAt: replacementSample,
            resetAt: replacementBoundary,
            markers: &markers
        )

        XCTAssertTrue(reset.isEmpty)
        XCTAssertEqual(activeBoundary(in: markers), replacementBoundary)
    }

    func testKnownBoundarySignalsAtBoundaryWhenPercentRemainsNinetyNine() {
        var markers: [String: String] = [:]
        let boundary = date.addingTimeInterval(60 * 60)
        _ = consume(
            remaining: 99,
            fetchedAt: date,
            resetAt: boundary,
            markers: &markers
        )

        let reset = consume(
            remaining: 99,
            fetchedAt: boundary,
            resetAt: boundary,
            markers: &markers
        )

        XCTAssertEqual(reset.map(\.cycleKey), [
            "reset:\(boundary.timeIntervalSince1970)"
        ])
    }

    func testStrongBoundaryIsNotOverwrittenByEarlyNextWindowTarget() {
        var markers: [String: String] = [:]
        let boundary = date.addingTimeInterval(60 * 60)
        let nextBoundary = boundary.addingTimeInterval(week)
        _ = consume(
            remaining: 70,
            fetchedAt: date,
            resetAt: boundary,
            markers: &markers
        )
        let early = consume(
            remaining: 70,
            fetchedAt: boundary.addingTimeInterval(-1),
            resetAt: nextBoundary,
            markers: &markers
        )
        let reset = consume(
            remaining: 70,
            fetchedAt: boundary.addingTimeInterval(1),
            resetAt: nil,
            markers: &markers
        )

        XCTAssertTrue(early.isEmpty)
        XCTAssertEqual(reset.map(\.cycleKey), [
            "reset:\(boundary.timeIntervalSince1970)"
        ])
    }

    func testCarriedSuccessorWinsWhenCurrentTargetFallsBackToOldBoundary() {
        var markers: [String: String] = [:]
        let boundary = date.addingTimeInterval(60 * 60)
        let nextBoundary = boundary.addingTimeInterval(week)
        _ = consume(
            remaining: 70,
            fetchedAt: date,
            resetAt: boundary,
            markers: &markers
        )
        _ = consume(
            remaining: 70,
            fetchedAt: boundary.addingTimeInterval(-1),
            resetAt: nextBoundary,
            markers: &markers
        )

        let reset = consume(
            remaining: 70,
            fetchedAt: boundary.addingTimeInterval(1),
            resetAt: boundary,
            markers: &markers
        )

        XCTAssertEqual(reset.map(\.cycleKey), [
            "reset:\(boundary.timeIntervalSince1970)"
        ])
    }

    func testMissingRawTargetsDoNotAdvanceFullCandidateSampleCount() {
        var markers: [String: String] = [:]
        let candidate = date.addingTimeInterval(60 * 60)
        _ = consume(
            remaining: 100,
            fetchedAt: date,
            resetAt: candidate,
            markers: &markers
        )
        _ = consume(
            remaining: 100,
            fetchedAt: date.addingTimeInterval(60),
            resetAt: nil,
            markers: &markers
        )
        _ = consume(
            remaining: 100,
            fetchedAt: date.addingTimeInterval(2 * 60),
            resetAt: nil,
            markers: &markers
        )

        let atCandidate = consume(
            remaining: 100,
            fetchedAt: candidate,
            resetAt: candidate.addingTimeInterval(week),
            markers: &markers
        )

        XCTAssertTrue(atCandidate.isEmpty)
    }

    func testDistinctKnownBoundaryIsNotDedupedByLatePriorSignal() {
        var markers: [String: String] = [:]
        let firstBoundary = date.addingTimeInterval(60 * 60)
        let secondBoundary = firstBoundary.addingTimeInterval(week)
        _ = consume(
            remaining: 70,
            fetchedAt: date,
            resetAt: firstBoundary,
            markers: &markers
        )
        let lateFirst = consume(
            remaining: 70,
            fetchedAt: firstBoundary.addingTimeInterval(10 * 60),
            resetAt: secondBoundary,
            markers: &markers
        )

        let onTimeSecond = consume(
            remaining: 70,
            fetchedAt: secondBoundary,
            resetAt: secondBoundary.addingTimeInterval(week),
            markers: &markers
        )

        XCTAssertEqual(lateFirst.map(\.cycleKey), [
            "reset:\(firstBoundary.timeIntervalSince1970)"
        ])
        XCTAssertEqual(onTimeSecond.map(\.cycleKey), [
            "reset:\(secondBoundary.timeIntervalSince1970)"
        ])
    }

    func testReconciledUnanchoredSignalDoesNotSuppressNextKnownBoundary() {
        var markers: [String: String] = [:]
        let firstBoundary = date.addingTimeInterval(60 * 60)
        let secondBoundary = firstBoundary.addingTimeInterval(week)
        _ = consume(
            remaining: 80,
            fetchedAt: firstBoundary.addingTimeInterval(5 * 60),
            resetAt: nil,
            markers: &markers
        )
        let unanchored = consume(
            remaining: 99,
            fetchedAt: firstBoundary.addingTimeInterval(10 * 60),
            resetAt: nil,
            markers: &markers
        )
        _ = consume(
            remaining: 80,
            fetchedAt: firstBoundary.addingTimeInterval(11 * 60),
            resetAt: firstBoundary,
            markers: &markers
        )
        let reconciled = consume(
            remaining: 99,
            fetchedAt: firstBoundary.addingTimeInterval(12 * 60),
            resetAt: secondBoundary,
            markers: &markers
        )

        let nextKnown = consume(
            remaining: 99,
            fetchedAt: secondBoundary,
            resetAt: secondBoundary.addingTimeInterval(week),
            markers: &markers
        )

        XCTAssertEqual(unanchored.count, 1)
        XCTAssertTrue(reconciled.isEmpty)
        XCTAssertEqual(nextKnown.map(\.cycleKey), [
            "reset:\(secondBoundary.timeIntervalSince1970)"
        ])
    }

    func testUnanchoredValueFallbackSignalsAtMostOncePerWeeklyWindow() {
        var markers: [String: String] = [:]
        _ = consume(
            remaining: 80,
            fetchedAt: date,
            resetAt: nil,
            markers: &markers
        )
        let first = consume(
            remaining: 99,
            fetchedAt: date.addingTimeInterval(5 * 60),
            resetAt: nil,
            markers: &markers
        )
        _ = consume(
            remaining: 80,
            fetchedAt: date.addingTimeInterval(6 * 60),
            resetAt: nil,
            markers: &markers
        )
        let repeated = consume(
            remaining: 99,
            fetchedAt: date.addingTimeInterval(11 * 60),
            resetAt: nil,
            markers: &markers
        )
        _ = consume(
            remaining: 80,
            fetchedAt: date.addingTimeInterval(week - 5 * 60),
            resetAt: nil,
            markers: &markers
        )
        let nextWindow = consume(
            remaining: 99,
            fetchedAt: date.addingTimeInterval(week),
            resetAt: nil,
            markers: &markers
        )

        XCTAssertEqual(first.count, 1)
        XCTAssertTrue(repeated.isEmpty)
        XCTAssertEqual(nextWindow.count, 1)
    }

    func testWeakFullAnchorIsRevokedWhenTargetResumesRolling() {
        var markers: [String: String] = [:]
        let cachedTarget = date.addingTimeInterval(week)
        _ = consume(
            remaining: 100,
            fetchedAt: date,
            resetAt: cachedTarget,
            markers: &markers
        )
        _ = consume(
            remaining: 100,
            fetchedAt: date.addingTimeInterval(60),
            resetAt: cachedTarget,
            markers: &markers
        )
        _ = consume(
            remaining: 100,
            fetchedAt: date.addingTimeInterval(2 * 60),
            resetAt: cachedTarget,
            markers: &markers
        )
        let rollingAt = date.addingTimeInterval(3 * 60)
        let resumed = consume(
            remaining: 100,
            fetchedAt: rollingAt,
            resetAt: rollingAt.addingTimeInterval(week),
            markers: &markers
        )
        let originalBoundary = consume(
            remaining: 100,
            fetchedAt: cachedTarget,
            resetAt: cachedTarget.addingTimeInterval(week),
            markers: &markers
        )

        XCTAssertTrue(resumed.isEmpty)
        XCTAssertTrue(originalBoundary.isEmpty)
    }

    func testWeakFullAnchorDoesNotSurviveClosedAppGap() {
        var markers: [String: String] = [:]
        let weakBoundary = date.addingTimeInterval(60 * 60)
        _ = consume(
            remaining: 100,
            fetchedAt: date,
            resetAt: weakBoundary,
            markers: &markers
        )
        _ = consume(
            remaining: 100,
            fetchedAt: date.addingTimeInterval(60),
            resetAt: weakBoundary,
            markers: &markers
        )
        _ = consume(
            remaining: 100,
            fetchedAt: date.addingTimeInterval(2 * 60),
            resetAt: weakBoundary,
            markers: &markers
        )

        let returnedAt = weakBoundary.addingTimeInterval(60 * 60)
        let reset = consume(
            remaining: 100,
            fetchedAt: returnedAt,
            resetAt: nil,
            markers: &markers
        )
        let nextSample = consume(
            remaining: 100,
            fetchedAt: returnedAt.addingTimeInterval(60),
            resetAt: nil,
            markers: &markers
        )

        XCTAssertTrue(reset.isEmpty)
        XCTAssertTrue(nextSample.isEmpty)
    }

    func testWeakFullAnchorSupportsThirtyMinuteCadenceAtBoundary() {
        var markers: [String: String] = [:]
        let boundary = date.addingTimeInterval(60 * 60)
        _ = consume(
            remaining: 100,
            fetchedAt: date,
            resetAt: boundary,
            markers: &markers
        )
        _ = consume(
            remaining: 100,
            fetchedAt: date.addingTimeInterval(60),
            resetAt: boundary,
            markers: &markers
        )
        _ = consume(
            remaining: 100,
            fetchedAt: date.addingTimeInterval(2 * 60),
            resetAt: boundary,
            markers: &markers
        )
        _ = consume(
            remaining: 100,
            fetchedAt: boundary.addingTimeInterval(-30 * 60),
            resetAt: boundary,
            markers: &markers
        )

        let reset = consume(
            remaining: 100,
            fetchedAt: boundary,
            resetAt: boundary.addingTimeInterval(week),
            markers: &markers
        )

        XCTAssertEqual(reset.count, 1)
    }

    func testBoundarySignalSuppressesValueOnlyFallbackInSameWindow() {
        var markers: [String: String] = [:]
        let boundary = date.addingTimeInterval(60 * 60)
        _ = consume(
            remaining: 70,
            fetchedAt: date,
            resetAt: boundary,
            markers: &markers
        )
        let boundaryReset = consume(
            remaining: 99,
            fetchedAt: boundary,
            resetAt: nil,
            markers: &markers
        )
        _ = consume(
            remaining: 80,
            fetchedAt: boundary.addingTimeInterval(60),
            resetAt: nil,
            markers: &markers
        )
        let fallback = consume(
            remaining: 99,
            fetchedAt: boundary.addingTimeInterval(5 * 60),
            resetAt: nil,
            markers: &markers
        )

        XCTAssertEqual(boundaryReset.count, 1)
        XCTAssertTrue(fallback.isEmpty)
    }

    func testValueOnlyFallbackSuppressesLateBoundarySignalInSameWindow() {
        var markers: [String: String] = [:]
        _ = consume(
            remaining: 80,
            fetchedAt: date,
            resetAt: nil,
            markers: &markers
        )
        let fallback = consume(
            remaining: 99,
            fetchedAt: date.addingTimeInterval(5 * 60),
            resetAt: nil,
            markers: &markers
        )
        let boundary = date.addingTimeInterval(15 * 60)
        _ = consume(
            remaining: 80,
            fetchedAt: date.addingTimeInterval(10 * 60),
            resetAt: boundary,
            markers: &markers
        )
        let lateBoundary = consume(
            remaining: 99,
            fetchedAt: boundary,
            resetAt: boundary.addingTimeInterval(week),
            markers: &markers
        )

        XCTAssertEqual(fallback.count, 1)
        XCTAssertTrue(lateBoundary.isEmpty)
    }

    func testExhaustedNewWindowWaitsForAvailabilityBeforeResetSignal() {
        var markers: [String: String] = [:]
        let boundary = date.addingTimeInterval(60 * 60)
        let nextBoundary = boundary.addingTimeInterval(week)
        _ = consume(
            remaining: 0,
            fetchedAt: date,
            resetAt: boundary,
            markers: &markers
        )
        let stillExhausted = consume(
            remaining: 0,
            fetchedAt: boundary,
            resetAt: nextBoundary,
            markers: &markers
        )
        let available = consume(
            remaining: 50,
            fetchedAt: boundary.addingTimeInterval(5 * 60),
            resetAt: nextBoundary,
            markers: &markers
        )

        XCTAssertTrue(stillExhausted.isEmpty)
        XCTAssertEqual(available.map(\.usageSummary), ["剩余 50%"])
    }

    func testV1RawCycleMismatchMigratesWithoutHistoricalReplay() throws {
        var markers: [String: String] = [:]
        _ = consume(
            remaining: 65,
            fetchedAt: date,
            resetAt: date.addingTimeInterval(60 * 60),
            markers: &markers
        )
        let markerKey = try XCTUnwrap(markers.keys.first)
        let oldReset = date.addingTimeInterval(60 * 60)
        markers[markerKey] = [
            "v1",
            date.timeIntervalSince1970.description,
            "65",
            "reset:\(oldReset.timeIntervalSince1970)",
            date.addingTimeInterval(-24 * 60 * 60).timeIntervalSince1970.description,
            "reset:\(oldReset.addingTimeInterval(-week).timeIntervalSince1970)"
        ].joined(separator: "|")

        let resets = consume(
            remaining: 65,
            fetchedAt: date.addingTimeInterval(60 * 60),
            resetAt: oldReset.addingTimeInterval(week),
            markers: &markers
        )

        XCTAssertTrue(resets.isEmpty)
        XCTAssertTrue(try XCTUnwrap(markers[markerKey]).hasPrefix("v4|"))
    }

    func testV1UnknownSignalMigratesAsUnanchored() throws {
        var markers: [String: String] = [:]
        _ = consume(
            remaining: 99,
            fetchedAt: date,
            resetAt: nil,
            markers: &markers
        )
        let markerKey = try XCTUnwrap(markers.keys.first)
        markers[markerKey] = [
            "v1",
            date.timeIntervalSince1970.description,
            "99",
            "unknown",
            date.timeIntervalSince1970.description,
            "unknown"
        ].joined(separator: "|")
        let boundary = date.addingTimeInterval(-5 * 60)
        _ = consume(
            remaining: 80,
            fetchedAt: date.addingTimeInterval(60),
            resetAt: boundary,
            markers: &markers
        )

        let reconciled = consume(
            remaining: 99,
            fetchedAt: date.addingTimeInterval(2 * 60),
            resetAt: boundary.addingTimeInterval(week),
            markers: &markers
        )

        XCTAssertTrue(reconciled.isEmpty)
        XCTAssertTrue(try XCTUnwrap(markers[markerKey]).hasPrefix("v4|"))
    }

    func testV1KnownAlertTargetRemainsTheUpcomingBoundary() throws {
        var markers: [String: String] = [:]
        _ = consume(
            remaining: 70,
            fetchedAt: date,
            resetAt: nil,
            markers: &markers
        )
        let markerKey = try XCTUnwrap(markers.keys.first)
        let upcomingBoundary = date.addingTimeInterval(60 * 60)
        let oldSignalAt = date.addingTimeInterval(-week + 60 * 60)
        markers[markerKey] = [
            "v1",
            date.timeIntervalSince1970.description,
            "70",
            "reset:\(upcomingBoundary.timeIntervalSince1970)",
            oldSignalAt.timeIntervalSince1970.description,
            "reset:\(upcomingBoundary.timeIntervalSince1970)"
        ].joined(separator: "|")
        _ = consume(
            remaining: 70,
            fetchedAt: date.addingTimeInterval(60),
            resetAt: upcomingBoundary,
            markers: &markers
        )

        let reset = consume(
            remaining: 70,
            fetchedAt: upcomingBoundary,
            resetAt: upcomingBoundary.addingTimeInterval(week),
            markers: &markers
        )

        XCTAssertEqual(reset.map(\.cycleKey), [
            "reset:\(upcomingBoundary.timeIntervalSince1970)"
        ])
    }

    func testV3MigrationRestoresCarriedSuccessor() throws {
        var markers: [String: String] = [:]
        _ = consume(
            remaining: 70,
            fetchedAt: date,
            resetAt: nil,
            markers: &markers
        )
        let markerKey = try XCTUnwrap(markers.keys.first)
        let boundary = date.addingTimeInterval(60 * 60)
        let successor = boundary.addingTimeInterval(week)
        markers[markerKey] = [
            "v3",
            boundary.addingTimeInterval(-60).timeIntervalSince1970.description,
            "70",
            successor.timeIntervalSince1970.description,
            "",
            "",
            "0",
            boundary.timeIntervalSince1970.description,
            "0",
            "",
            "",
            ""
        ].joined(separator: "|")

        let reset = consume(
            remaining: 70,
            fetchedAt: boundary.addingTimeInterval(1),
            resetAt: nil,
            markers: &markers
        )

        XCTAssertEqual(reset.map(\.cycleKey), [
            "reset:\(boundary.timeIntervalSince1970)"
        ])
    }

    func testV2SignalWithoutHandledBoundaryMigratesAsUnanchored() throws {
        var markers: [String: String] = [:]
        _ = consume(
            remaining: 99,
            fetchedAt: date,
            resetAt: nil,
            markers: &markers
        )
        let markerKey = try XCTUnwrap(markers.keys.first)
        markers[markerKey] = [
            "v2",
            date.timeIntervalSince1970.description,
            "99",
            "",
            "",
            "",
            "",
            "",
            date.timeIntervalSince1970.description
        ].joined(separator: "|")
        let boundary = date.addingTimeInterval(-5 * 60)
        _ = consume(
            remaining: 80,
            fetchedAt: date.addingTimeInterval(60),
            resetAt: boundary,
            markers: &markers
        )

        let reconciled = consume(
            remaining: 99,
            fetchedAt: date.addingTimeInterval(2 * 60),
            resetAt: boundary.addingTimeInterval(week),
            markers: &markers
        )

        XCTAssertTrue(reconciled.isEmpty)
    }

    func testSparkShortCycleAndStaleRowsAreIgnored() {
        var markers: [String: String] = [:]
        let resetAt = date.addingTimeInterval(60 * 60)

        let spark = OpenAIWeeklyResetTracker.consume(
            data: QuotaAlertFixture.openAIWeeklyQuotaData(
                remainingPercent: 99,
                fetchedAt: date,
                resetAt: resetAt,
                productID: "codex_bengalfox"
            ),
            into: &markers
        )
        let shortCycle = OpenAIWeeklyResetTracker.consume(
            data: QuotaAlertFixture.openAIWeeklyQuotaData(
                remainingPercent: 99,
                fetchedAt: date,
                resetAt: resetAt,
                windowKind: .shortCycle
            ),
            into: &markers
        )
        let stale = OpenAIWeeklyResetTracker.consume(
            data: QuotaAlertFixture.openAIWeeklyQuotaData(
                remainingPercent: 99,
                fetchedAt: date,
                resetAt: resetAt,
                isFresh: false
            ),
            into: &markers
        )

        XCTAssertTrue(spark.isEmpty)
        XCTAssertTrue(shortCycle.isEmpty)
        XCTAssertTrue(stale.isEmpty)
        XCTAssertTrue(markers.isEmpty)
    }

    private func consume(
        remaining: Decimal,
        fetchedAt: Date,
        resetAt: Date?,
        markers: inout [String: String]
    ) -> [QuotaMetricStatus] {
        OpenAIWeeklyResetTracker.consume(
            data: QuotaAlertFixture.openAIWeeklyQuotaData(
                remainingPercent: remaining,
                fetchedAt: fetchedAt,
                resetAt: resetAt
            ),
            into: &markers
        )
    }

    private func activeBoundary(in markers: [String: String]) -> Date? {
        guard let encoded = markers.first(where: {
            $0.key.hasPrefix("openai-weekly-reset-observation|")
        })?.value else {
            return nil
        }
        let fields = encoded.split(
            separator: "|",
            omittingEmptySubsequences: false
        )
        guard fields.count == 14,
              let seconds = Double(fields[7]) else {
            return nil
        }
        return Date(timeIntervalSince1970: seconds)
    }
}
