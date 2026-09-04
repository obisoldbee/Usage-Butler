import Foundation
import XCTest
@testable import UsageButlerCore
@testable import UsageButlerDomain

final class LiveMemoryProjectionMapperTests: XCTestCase {
    private let fixedNow = Date(timeIntervalSince1970: 1_786_400_000)

    func testStateOrdersSevenRowsAndKeepsOneUnavailableWithoutClearingSiblingsOrHistory() throws {
        let capturedAt = fixedNow.addingTimeInterval(-5)
        let fields = makeFieldsWithUnavailableSwap().reversed()
        let snapshot = MemorySamplingSnapshot(
            timestamp: capturedAt,
            fields: Array(fields),
            pressure: .warning
        )
        let state = MemorySamplingState(
            latest: snapshot,
            history: [
                MemoryHistoryPoint(
                    timestamp: capturedAt,
                    estimatedUsedRatio: 0.75,
                    pressureRatio: 0.25,
                    pressure: .warning
                )
            ],
            policy: .memoryPageVisible,
            isRunning: true
        )

        let projection = try XCTUnwrap(
            LiveMemoryProjectionMapper.map(state, now: fixedNow)
        )

        XCTAssertEqual(projection.fields.map(\.id), [
            .physical,
            .used,
            .cachedFiles,
            .swapUsed,
            .appMemory,
            .wired,
            .compressed
        ])
        XCTAssertEqual(
            projection.fields.map(\.bytes),
            [16_000, 12_000, 2_000, nil, 4_000, 3_000, 1_000]
        )
        XCTAssertEqual(projection.fields[3].provenance, .directSystemValue)
        XCTAssertEqual(
            projection.fields[3].availability,
            .unavailable(.sourceReadFailed(.swapUsage))
        )
        XCTAssertEqual(projection.pressure, .warning)
        XCTAssertEqual(projection.capturedAt, capturedAt)
        XCTAssertEqual(projection.historyWindowEnd, fixedNow)
        XCTAssertEqual(projection.origin, .runtime)
        XCTAssertFalse(projection.origin.isFixture)
        XCTAssertEqual(projection.history.map(\.loadRatio), [0.75])
        XCTAssertEqual(projection.history.map(\.pressureRatio), [0.25])
        XCTAssertEqual(projection.history.map(\.pressure), [.warning])
    }

    func testHistoryUsesInjectedTwoHourWindowAndPreservesPointPressure() {
        let snapshot = MemorySamplingSnapshot(
            timestamp: fixedNow,
            fields: makeFieldsWithUnavailableSwap(),
            pressure: .critical
        )
        let history = [
            historyPoint(secondsFromNow: 1, ratio: 0.9, pressure: .critical),
            historyPoint(secondsFromNow: 0, ratio: 0.7, pressure: .warning),
            historyPoint(secondsFromNow: -1, ratio: nil, pressure: .critical),
            historyPoint(secondsFromNow: -7_200, ratio: 0.2, pressure: .normal),
            historyPoint(secondsFromNow: -7_201, ratio: 0.1, pressure: .unknown)
        ]

        let projection = LiveMemoryProjectionMapper.map(
            snapshot,
            history: history,
            now: fixedNow
        )

        XCTAssertEqual(projection.history.map(\.id), [0, 1, 2])
        XCTAssertEqual(projection.history.map(\.timestamp), [
            fixedNow.addingTimeInterval(-7_200),
            fixedNow.addingTimeInterval(-1),
            fixedNow
        ])
        XCTAssertEqual(projection.history.map(\.loadRatio), [0.2, nil, 0.7])
        XCTAssertEqual(
            projection.history.map(\.pressureRatio),
            [0.2, nil, 0.7]
        )
        XCTAssertEqual(
            projection.history.map(\.pressure),
            [.normal, .critical, .warning]
        )
        XCTAssertTrue(projection.history[1].isLoadRatioUnavailable)
        XCTAssertEqual(projection.historyWindowEnd, fixedNow)
        XCTAssertEqual(projection.pressure, .critical)
    }

    func testMissingLatestDoesNotManufactureAProjection() {
        let state = MemorySamplingState(
            latest: nil,
            history: [
                historyPoint(
                    secondsFromNow: 0,
                    ratio: 0.5,
                    pressure: .normal
                )
            ],
            policy: .other,
            isRunning: false
        )

        XCTAssertNil(LiveMemoryProjectionMapper.map(state, now: fixedNow))
    }

    private func makeFieldsWithUnavailableSwap() -> [MemorySummaryField] {
        [
            field(.physical, bytes: 16_000, provenance: .directSystemValue),
            field(
                .used,
                bytes: 12_000,
                provenance: .derivedSystemEstimate(formulaID: "test.used")
            ),
            field(
                .cachedFiles,
                bytes: 2_000,
                provenance: .derivedSystemEstimate(formulaID: "test.cached")
            ),
            MemorySummaryField(
                id: .swapUsed,
                availability: .unavailable(.sourceReadFailed(.swapUsage)),
                provenance: .directSystemValue
            ),
            field(
                .appMemory,
                bytes: 4_000,
                provenance: .derivedSystemEstimate(formulaID: "test.app")
            ),
            field(.wired, bytes: 3_000, provenance: .directSystemValue),
            field(.compressed, bytes: 1_000, provenance: .directSystemValue)
        ]
    }

    private func field(
        _ id: MemoryFieldID,
        bytes: UInt64,
        provenance: MemoryValueProvenance
    ) -> MemorySummaryField {
        MemorySummaryField(
            id: id,
            availability: .available(bytes: bytes),
            provenance: provenance
        )
    }

    private func historyPoint(
        secondsFromNow: TimeInterval,
        ratio: Double?,
        pressure: MemoryPressureState
    ) -> MemoryHistoryPoint {
        MemoryHistoryPoint(
            timestamp: fixedNow.addingTimeInterval(secondsFromNow),
            estimatedUsedRatio: ratio,
            pressureRatio: ratio,
            pressure: pressure
        )
    }
}
