import Foundation
import XCTest
@testable import UsageButlerCore
import UsageButlerDomain

final class MemoryHistoryDownsamplerTests: XCTestCase {
    func testDownsamplingKeepsGapBoundaryPairs() {
        let points = makePoints(
            ratios: [0.1, 0.2, 0.3, nil, nil, 0.6, 0.7, 0.8, 0.9],
            pressures: Array(repeating: .normal, count: 9)
        )

        let output = MemoryHistoryDownsampler.downsample(
            points,
            targetPointCount: 6
        )

        XCTAssertEqual(output.map(\.timestamp), [
            points[0].timestamp,
            points[2].timestamp,
            points[3].timestamp,
            points[4].timestamp,
            points[5].timestamp,
            points[8].timestamp
        ])
    }

    func testDownsamplingKeepsBothSidesOfPressureTransitions() {
        let pressures: [MemoryPressureState] = [
            .normal, .normal, .normal,
            .warning, .warning, .warning,
            .critical, .critical,
            .normal, .normal
        ]
        let points = makePoints(
            ratios: (0..<pressures.count).map { Double($0) / 10 },
            pressures: pressures
        )

        let output = MemoryHistoryDownsampler.downsample(
            points,
            targetPointCount: 8
        )

        let requiredIndices = [0, 2, 3, 5, 6, 7, 8, 9]
        XCTAssertEqual(
            Set(output.map(\.timestamp)),
            Set(requiredIndices.map { points[$0].timestamp })
        )
    }

    func testBoundaryPreservationCanExceedSoftTarget() {
        let points = makePoints(
            ratios: [0.1, 0.2, nil, 0.4, nil, 0.6],
            pressures: [.normal, .normal, .normal, .warning, .warning, .critical]
        )

        let output = MemoryHistoryDownsampler.downsample(
            points,
            targetPointCount: 2
        )

        XCTAssertEqual(output, points)
    }

    func testOrdinaryPointsRespectTargetAndKeepEndpoints() {
        let points = makePoints(
            ratios: (0..<20).map { Double($0) / 20 },
            pressures: Array(repeating: .normal, count: 20)
        )

        let output = MemoryHistoryDownsampler.downsample(
            points,
            targetPointCount: 5
        )

        XCTAssertEqual(output.count, 5)
        XCTAssertEqual(output.first, points.first)
        XCTAssertEqual(output.last, points.last)
    }

    func testMixedCadenceUsesTimeDistributionWithoutManufacturingChartGaps() {
        let start = Date(timeIntervalSince1970: 50_000)
        let continuity = MemoryHistoryDownsampler.maximumContinuousInterval
        let denseHistory = (0...6_600).map { offset in
            point(at: start, offset: TimeInterval(offset))
        }
        let recentSlowHistory = stride(from: 6_610, through: 7_200, by: 10)
            .map { offset in
                point(at: start, offset: TimeInterval(offset))
            }
        let points = denseHistory + recentSlowHistory

        let output = MemoryHistoryDownsampler.downsample(
            points,
            targetPointCount: 720
        )

        XCTAssertEqual(output.count, 720)
        XCTAssertEqual(output.first, points.first)
        XCTAssertEqual(output.last, points.last)

        XCTAssertTrue(
            zip(output, output.dropFirst()).allSatisfy {
                $1.timestamp.timeIntervalSince($0.timestamp) <= continuity
            }
        )

        let recentWindowStart = start.addingTimeInterval(6_600)
        let recentWindow = output.filter { $0.timestamp >= recentWindowStart }
        XCTAssertGreaterThan(recentWindow.count, 1)
        XCTAssertLessThanOrEqual(
            recentWindow.first!.timestamp.timeIntervalSince(recentWindowStart),
            continuity
        )
        XCTAssertTrue(
            zip(recentWindow, recentWindow.dropFirst()).allSatisfy {
                $1.timestamp.timeIntervalSince($0.timestamp) <= continuity
            }
        )
    }

    func testRecentMinutePreservesEveryOneSecondSample() {
        let start = Date(timeIntervalSince1970: 50_000)
        let points = (0...7_200).map { offset in
            point(at: start, offset: TimeInterval(offset))
        }

        let output = MemoryHistoryDownsampler.downsample(
            points,
            targetPointCount: 720,
            preserveRecentInterval: 60
        )

        let recentCutoff = start.addingTimeInterval(7_140)
        let expectedRecent = points.filter { $0.timestamp >= recentCutoff }
        let actualRecent = output.filter { $0.timestamp >= recentCutoff }

        XCTAssertEqual(actualRecent, expectedRecent)
        XCTAssertEqual(output.count, 720)
    }

    func testUniqueTimestampsProduceTheSameOutputWhenInputIsShuffled() {
        let start = Date(timeIntervalSince1970: 50_000)
        let points = (0..<120).map { offset in
            point(at: start, offset: TimeInterval(offset))
        }
        let shuffled = points.enumerated()
            .sorted { lhs, rhs in
                let lhsKey = (lhs.offset * 37) % points.count
                let rhsKey = (rhs.offset * 37) % points.count
                return lhsKey < rhsKey
            }
            .map(\.element)

        let chronologicalOutput = MemoryHistoryDownsampler.downsample(
            points,
            targetPointCount: 12
        )
        let shuffledOutput = MemoryHistoryDownsampler.downsample(
            shuffled,
            targetPointCount: 12
        )

        XCTAssertEqual(
            shuffledOutput.map(\.timestamp),
            chronologicalOutput.map(\.timestamp)
        )
    }

    func testRealTimeGapKeepsBothBoundariesAndIsNotBridged() {
        let start = Date(timeIntervalSince1970: 50_000)
        let points = [0, 10, 20, 100, 110, 120].map { offset in
            point(at: start, offset: TimeInterval(offset))
        }

        let targetOneOutput = MemoryHistoryDownsampler.downsample(
            points,
            targetPointCount: 1
        )
        let targetTwoOutput = MemoryHistoryDownsampler.downsample(
            points,
            targetPointCount: 2
        )

        let expected = [points[0], points[2], points[3], points[5]]
        XCTAssertEqual(targetOneOutput, expected)
        XCTAssertEqual(targetTwoOutput, expected)
        XCTAssertEqual(
            targetOneOutput[2].timestamp.timeIntervalSince(
                targetOneOutput[1].timestamp
            ),
            80
        )
    }

    private func makePoints(
        ratios: [Double?],
        pressures: [MemoryPressureState]
    ) -> [MemoryHistoryPoint] {
        let start = Date(timeIntervalSince1970: 50_000)
        return zip(ratios, pressures).enumerated().map { index, values in
            MemoryHistoryPoint(
                timestamp: start.addingTimeInterval(Double(index)),
                estimatedUsedRatio: values.0,
                pressureRatio: values.0,
                pressure: values.1
            )
        }
    }

    private func point(
        at start: Date,
        offset: TimeInterval
    ) -> MemoryHistoryPoint {
        MemoryHistoryPoint(
            timestamp: start.addingTimeInterval(offset),
            estimatedUsedRatio: 0.5,
            pressureRatio: 0.5,
            pressure: .warning
        )
    }
}
