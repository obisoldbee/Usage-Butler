import XCTest
@testable import UsageButlerUI
import UsageButlerDomain
import UsageButlerCore
@testable import UsageButlerInfrastructure

@MainActor final class NetworkHistoryViewModelTests: XCTestCase {
    private func result(_ range: HistoryRange, page: Int = 0) -> HistoryQueryResult {
        .init(range: range, applications: [], totalApplications: 0, page: page, curve: [], days: [], events: [], coverage: .init())
    }
    func testLateErrorCannotReplaceNewRangeAndCloseReleasesResult() async {
        let model = BackgroundNetworkViewModel()
        let started = expectation(description: "old query entered")
        var old: CheckedContinuation<HistoryQueryResult, Error>?
        var calls = 0
        model.onQuery = { range, _, page, _ in
            calls += 1
            if calls == 1 { return try await withCheckedThrowingContinuation { old = $0; started.fulfill() } }
            return self.result(range, page: page)
        }
        model.reload(); let first = model.currentQueryTask
        await fulfillment(of: [started], timeout: 2)
        model.range = .hour; await model.currentQueryTask?.value
        let expected = model.result
        XCTAssertEqual(expected?.range.end.timeIntervalSince(expected!.range.start), 3600)
        old?.resume(throwing: BackgroundNetworkWire.Failure.disconnected); await first?.value
        XCTAssertEqual(model.result, expected); XCTAssertNil(model.queryIssue)
        model.closeHistory(); XCTAssertNil(model.result); XCTAssertFalse(model.loading)
    }
    func testCloseRejectsUncancelledLateSuccess() async {
        let model = BackgroundNetworkViewModel(), started = expectation(description: "query entered")
        var pending: CheckedContinuation<HistoryQueryResult, Error>?
        var range: HistoryRange?
        model.onQuery = { r, _, _, _ in range = r; return try await withCheckedThrowingContinuation { pending = $0; started.fulfill() } }
        model.reload(); let task = model.currentQueryTask
        await fulfillment(of: [started], timeout: 2)
        model.closeHistory(); pending?.resume(returning: result(range!)); await task?.value
        XCTAssertNil(model.result); XCTAssertNil(model.queryIssue); XCTAssertFalse(model.loading)
    }
    func testFailureIsVisibleWhenUnregisteredAndApprovalIsPreserved() {
        let model = BackgroundNetworkViewModel(); model.serviceIssue = "history.signature-error"
        XCTAssertTrue(model.serviceTitle.contains("history.signature-error"))
        model.registration = "requiresApproval"; XCTAssertTrue(model.serviceTitle.contains("等待系统"))
        model.serviceIssue = nil; model.registration = "notRegistered"; XCTAssertTrue(model.serviceTitle.contains("保留"))
    }
    func testWireMeasuresActualBytesAndRejectsArbitraryPathShape() throws {
        XCTAssertThrowsError(try BackgroundNetworkWire.encode(.init(error: String(repeating: "界", count: 2_000_000))))
        var request = BackgroundNetworkRequest(.query); request.range = .recent(days: 7)
        request.selectedKey = String(repeating: "a", count: 8_193); XCTAssertFalse(request.isValid)
        request.selectedKey = "known"; request.applicationID = 1; XCTAssertFalse(request.isValid)
        request.applicationID = nil; request.page = 1024; XCTAssertFalse(request.isValid)
    }
    func testStoppedReadDoesNotCreateMissingDatabaseOrDirectory() async throws {
        let parent = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".build/background-history-0.5.0/test-databases/missing-" + UUID().uuidString)
        let reader = UsageButlerInfrastructure.NetworkHistoryQuery(databaseURL: parent.appendingPathComponent("history-v1.sqlite"))
        do { _ = try await reader.query(range: .recent(days: 7)); XCTFail("missing database must not be zero history") } catch {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: parent.path))
    }
}
