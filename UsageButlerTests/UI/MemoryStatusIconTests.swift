import AppKit
import XCTest
import UsageButlerCore
import UsageButlerDomain
@testable import UsageButlerUI

final class MemoryStatusIconTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testPressureUsesSystemStateWithoutNumericMemoryFields() {
        for state: MemoryPressureState in [.normal, .warning, .critical, .unknown] {
            XCTAssertEqual(MemoryStatusIcon.pressure(for: snapshot(state), now: now), state)
        }
    }

    func testMissingUpdatesExpireAtThirtySecondsAndFreshSampleRecovers() {
        let sample = snapshot(.normal)
        XCTAssertEqual(MemoryStatusIcon.pressure(for: sample, now: now.addingTimeInterval(29)), .normal)
        XCTAssertEqual(MemoryStatusIcon.pressure(for: sample, now: now.addingTimeInterval(30)), .unknown)
        XCTAssertEqual(MemoryStatusIcon.pressure(for: sample, now: now.addingTimeInterval(300)), .unknown)
        XCTAssertEqual(MemoryStatusIcon.pressure(for: snapshot(.critical), now: now), .critical)
        XCTAssertEqual(MemoryStatusIcon.pressure(for: sample, now: now.addingTimeInterval(-1)), .unknown)
    }

    @MainActor
    func testAllStatesProduceDistinctNonTemplateGlyphsInBothAppearances() throws {
        var rendered = Set<Data>()
        for dark in [false, true] {
            for state: MemoryPressureState in [.normal, .warning, .critical, .unknown] {
                let image = MemoryStatusIcon.image(for: state, dark: dark)
                XCTAssertFalse(image.isTemplate, "Template tint would erase the pressure color")
                XCTAssertEqual(image.size, NSSize(width: 20, height: 18))
                rendered.insert(try XCTUnwrap(image.tiffRepresentation))
            }
        }
        XCTAssertEqual(rendered.count, 8)
    }

    private func snapshot(_ pressure: MemoryPressureState) -> Stage3MemoryProjection {
        Stage3MemoryProjection(
            pressure: pressure, fields: [], history: [], capturedAt: now, origin: .runtime
        )
    }
}
