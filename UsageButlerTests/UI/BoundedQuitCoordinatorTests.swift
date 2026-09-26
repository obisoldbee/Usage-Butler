import XCTest
import UsageButlerUI

@MainActor final class BoundedQuitCoordinatorTests: XCTestCase {
    func testNeverFinishingDrainTimesOutOnceAndLateCompletionIsIgnored() {
        var timeout: (@MainActor () -> Void)?, completion: (@MainActor () -> Void)?
        var outcomes: [Bool] = [], drains = 0, cancels = 0
        let coordinator = BoundedQuitCoordinator(schedule: { timeout = $0; return { cancels += 1 } }, terminate: { outcomes.append($0) })
        coordinator.request { drains += 1; completion = $0 }
        coordinator.request { _ in drains += 1 }
        XCTAssertEqual(drains, 1); XCTAssertTrue(outcomes.isEmpty)
        timeout?(); timeout?(); completion?()
        XCTAssertEqual(outcomes, [false]); XCTAssertEqual(cancels, 1)
    }
    func testNormalDrainCancelsFallbackAndTerminatesOnlyOnce() {
        var timeout: (@MainActor () -> Void)?, completion: (@MainActor () -> Void)?
        var outcomes: [Bool] = [], cancels = 0
        let coordinator = BoundedQuitCoordinator(schedule: { timeout = $0; return { cancels += 1 } }, terminate: { outcomes.append($0) })
        coordinator.request { completion = $0 }
        completion?(); timeout?(); completion?()
        XCTAssertEqual(outcomes, [true]); XCTAssertEqual(cancels, 1)
    }
}
