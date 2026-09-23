import Accessibility
import Foundation
import XCTest
import UsageButlerCore
@testable import UsageButlerUI

final class NetworkChartAccessibilityTests: XCTestCase {
    func testDescriptorPreservesRealUnitsAndSeparateRuns() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let coordinates = NetworkChartCoordinates(now: now, window: 60, upperBound: 100_000)
        let points = [
            NetworkChartPoint(seriesKey: "first", direction: .download, at: now.addingTimeInterval(-30), value: 0, isIsolated: false, sampleID: "a"),
            NetworkChartPoint(seriesKey: "first", direction: .download, at: now.addingTimeInterval(-29), value: 50_000, isIsolated: false, sampleID: "b"),
            NetworkChartPoint(seriesKey: "after-gap", direction: .download, at: now, value: 100_000, isIsolated: true, sampleID: "c")
        ]
        let descriptor = NetworkChartAccessibility(points: points, direction: .download, coordinates: coordinates).makeChartDescriptor()
        let x = try XCTUnwrap(descriptor.xAxis as? AXNumericDataAxisDescriptor)
        let y = try XCTUnwrap(descriptor.yAxis)
        XCTAssertEqual(x.range, (now.timeIntervalSince1970 - 60)...now.timeIntervalSince1970)
        XCTAssertEqual(y.range, 0...100_000)
        XCTAssertEqual(y.gridlinePositions, [0, 50_000, 100_000])
        XCTAssertEqual(y.valueDescriptionProvider(50_000), "50.0 KB/s")
        XCTAssertEqual(descriptor.series.count, 2)
        XCTAssertEqual(descriptor.series.map(\.dataPoints.count), [2, 1])
        XCTAssertEqual(descriptor.series.map(\.isContinuous), [true, false])
        XCTAssertEqual(descriptor.series[0].dataPoints[1].yValue?.__number, 50_000)
    }
}
