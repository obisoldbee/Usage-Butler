import XCTest
import UsageButlerDomain
@testable import UsageButlerUI

@MainActor final class ProcessNetworkHistoryViewModelTests: XCTestCase {
    func testRangeSelectionCancelsOldReplyAndRepeatedSelectedRangeDoesNotReload() async {
        let model = ProcessNetworkViewModel()
        let oldStarted = expectation(description: "old range started")
        let newStarted = expectation(description: "new range started")
        var old: CheckedContinuation<HistoryQueryResult, Error>?
        var new: CheckedContinuation<HistoryQueryResult, Error>?
        var calls = 0
        model.onLongHistory = { _, seconds in
            calls += 1
            return try await withCheckedThrowingContinuation { continuation in
                if seconds == 3_600 { old = continuation; oldStarted.fulfill() }
                else { new = continuation; newStarted.fulfill() }
            }
        }
        model.selected = "app"
        model.setLongHistoryVisible(true)
        await fulfillment(of: [oldStarted], timeout: 2)
        let oldTask = model.currentLongHistoryTask
        model.range = .tenMinutes
        await fulfillment(of: [newStarted], timeout: 2)
        XCTAssertTrue(model.longHistoryLoading)
        model.range = .tenMinutes
        XCTAssertEqual(calls, 2)
        let end = Date(timeIntervalSince1970: 1_786_400_040)
        func result(_ seconds: Double) -> HistoryQueryResult {
            .init(range: .init(start: end.addingTimeInterval(-seconds), end: end), applications: [], totalApplications: 0,
                page: 0, curve: [], days: [], events: [], coverage: .init())
        }
        new?.resume(returning: result(600))
        await model.currentLongHistoryTask?.value
        XCTAssertEqual(model.longHistory?.range.start, end.addingTimeInterval(-600))
        old?.resume(returning: result(3_600))
        // The replaced task has its own revision and cannot publish its reply.
        await oldTask?.value
        XCTAssertEqual(model.longHistory?.range.start, end.addingTimeInterval(-600))
        XCTAssertFalse(model.longHistoryLoading)
        model.setLongHistoryVisible(false)
    }
}
