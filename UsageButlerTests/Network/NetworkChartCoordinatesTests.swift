import Foundation
import XCTest
@testable import UsageButlerCore

final class NetworkChartCoordinatesTests: XCTestCase {
    func testFiveWindowsKeepEndpointMidpointAndInspectionTimeInSync() {
        let now = Date(timeIntervalSince1970: 1_800_000_000.25)
        for window in [60.0, 600, 1_800, 3_600, 7_200] {
            let coordinates = NetworkChartCoordinates(now: now, window: window, upperBound: 1_000)
            XCTAssertEqual(coordinates.date(atX: 0), now.addingTimeInterval(-window))
            XCTAssertEqual(coordinates.date(atX: 0.5), now.addingTimeInterval(-window / 2))
            XCTAssertEqual(coordinates.date(atX: 1), now)
            let sample = now.addingTimeInterval(-window * 0.137)
            XCTAssertEqual(coordinates.date(atX: coordinates.x(at: sample)).timeIntervalSince(sample), 0, accuracy: 0.000001)
            XCTAssertLessThan(coordinates.x(at: now.addingTimeInterval(-window - 1)), 0)
            XCTAssertGreaterThan(coordinates.x(at: now.addingTimeInterval(1)), 1)
        }
    }

    func testIndependentScalesKeepRealUnitsAndKnownZero() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let upload = NetworkChartCoordinates(now: now, window: 60, upperBound: 1_000)
        let download = NetworkChartCoordinates(now: now, window: 60, upperBound: 100_000)
        XCTAssertEqual(upload.y(for: 500), download.y(for: 50_000))
        XCTAssertEqual(upload.rate(atY: 0.5), 500)
        XCTAssertEqual(download.rate(atY: 0.5), 50_000)
        XCTAssertEqual(upload.y(for: 0), 0)
        XCTAssertEqual(upload.rate(atY: 0), 0)
        XCTAssertGreaterThan(upload.y(for: 1_001), 1, "Do not silently clip a peak in the coordinate conversion")
    }

    func testMovingWindowMovesExistingSampleWithoutChangingTickIdentities() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let before = NetworkChartCoordinates(now: now, window: 60, upperBound: 1_000)
        let after = NetworkChartCoordinates(now: now.addingTimeInterval(1), window: 60, upperBound: 10_000)
        let sample = now.addingTimeInterval(-20)
        XCTAssertEqual(before.x(at: sample) - after.x(at: sample), 1.0 / 60, accuracy: 0.000001)
        XCTAssertEqual(NetworkChartCoordinates.ticks, [0, 0.5, 1])
        for tick in NetworkChartCoordinates.ticks {
            XCTAssertEqual(after.date(atX: tick).timeIntervalSince(before.date(atX: tick)), 1)
            XCTAssertEqual(after.rate(atY: tick), before.rate(atY: tick) * 10)
        }
    }
}
