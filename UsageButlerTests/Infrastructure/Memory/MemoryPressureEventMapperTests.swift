import Dispatch
import XCTest
@testable import UsageButlerInfrastructure
import UsageButlerDomain

final class MemoryPressureEventMapperTests: XCTestCase {
    func testMapsPressureEventsWithoutReadingLiveSystemState() {
        XCTAssertEqual(
            MemoryPressureEventMapper.state(for: .normal),
            .normal
        )
        XCTAssertEqual(
            MemoryPressureEventMapper.state(for: .warning),
            .warning
        )
        XCTAssertEqual(
            MemoryPressureEventMapper.state(for: .critical),
            .critical
        )
        XCTAssertEqual(
            MemoryPressureEventMapper.state(for: []),
            .unknown
        )
        XCTAssertEqual(
            MemoryPressureEventMapper.state(for: [.warning, .critical]),
            .critical
        )
    }
}
