import Foundation
import XCTest
@testable import UsageButlerCore
import UsageButlerDomain

final class MemorySampleHistoryTests: XCTestCase {
    func testHistoryKeepsExactTwoHourBoundaryAndTrimsByTimestamp() {
        let start = Date(timeIntervalSince1970: 10_000)
        var history = MemorySampleHistory()

        history.append(point(at: start, ratio: 0.1))
        history.append(point(at: start.addingTimeInterval(3_600), ratio: 0.2))
        history.append(point(at: start.addingTimeInterval(7_200), ratio: 0.3))

        XCTAssertEqual(history.points.map(\.timestamp), [
            start,
            start.addingTimeInterval(3_600),
            start.addingTimeInterval(7_200)
        ])

        history.append(point(at: start.addingTimeInterval(7_201), ratio: 0.4))

        XCTAssertEqual(history.points.map(\.timestamp), [
            start.addingTimeInterval(3_600),
            start.addingTimeInterval(7_200),
            start.addingTimeInterval(7_201)
        ])
    }

    func testOutOfOrderOldPointCannotExpandWindowBehindNewestTimestamp() {
        let start = Date(timeIntervalSince1970: 20_000)
        var history = MemorySampleHistory()
        let newest = start.addingTimeInterval(10_000)

        history.append(point(at: newest, ratio: 0.8))
        history.append(point(at: start, ratio: 0.2))

        XCTAssertEqual(history.points, [point(at: newest, ratio: 0.8)])
    }

    func testSameTimestampReplacesWholeMergedPoint() {
        let timestamp = Date(timeIntervalSince1970: 30_000)
        var history = MemorySampleHistory()

        history.append(point(at: timestamp, ratio: nil, pressure: .unknown))
        history.append(point(at: timestamp, ratio: 0.75, pressure: .critical))

        XCTAssertEqual(history.points, [
            point(at: timestamp, ratio: 0.75, pressure: .critical)
        ])
    }

    func testSnapshotCreatesClampedRatioAndKeepsUnavailableUsedAsGap() {
        let timestamp = Date(timeIntervalSince1970: 40_000)
        let clamped = MemorySamplingSnapshot(
            timestamp: timestamp,
            fields: memoryFields(physicalBytes: 100, usedBytes: 125),
            pressureRatio: 0.32,
            pressure: .normal
        )
        let gap = MemorySamplingSnapshot(
            timestamp: timestamp,
            fields: memoryFields(physicalBytes: 100, usedBytes: nil),
            pressureRatio: 0.18,
            pressure: .warning
        )

        XCTAssertEqual(clamped.estimatedUsedRatio, 1)
        XCTAssertEqual(clamped.pressureRatio, 0.32)
        XCTAssertNil(gap.estimatedUsedRatio)
        XCTAssertEqual(gap.pressureRatio, 0.18)
        XCTAssertTrue(gap.historyPoint.isLoadRatioUnavailable)
        XCTAssertFalse(gap.historyPoint.isPressureRatioUnavailable)
    }

    private func point(
        at timestamp: Date,
        ratio: Double?,
        pressure: MemoryPressureState = .normal
    ) -> MemoryHistoryPoint {
        MemoryHistoryPoint(
            timestamp: timestamp,
            estimatedUsedRatio: ratio,
            pressure: pressure
        )
    }
}
