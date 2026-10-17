import XCTest
import UsageButlerDomain
@testable import UsageButlerUI

final class HistoryRecordingCopyTests: XCTestCase {
    func testRoutineMinuteBoundariesAndRetentionAreNotDataLossWarnings() {
        XCTAssertTrue(HistoryRecordingCopy.notices([.baseline, .minuteBoundary, .conservativeAge]).isEmpty)
    }
    func testDirectionalGapDoesNotClaimLossInTheOtherDirection() {
        let notices = HistoryRecordingCopy.notices([.downloadGap, .minuteBoundary])
        XCTAssertEqual(notices.count, 1)
        XCTAssertTrue(notices[0].contains("下载"))
        XCTAssertFalse(notices[0].contains("上传"))
    }
    func testUnavailableOrResetCounterDoesNotAssertAResetAsFact() {
        let notice = HistoryRecordingCopy.notices(.counterReset).joined()
        XCTAssertTrue(notice.contains("无法读取或"))
    }
    func testUnknownEndReasonStaysUnknownAndCannotBecomeZeroTraffic() {
        XCTAssertEqual(HistoryRecordingCopy.endReason("new-source-reason"), "原因暂未确认")
        XCTAssertNotEqual(HistoryRecordingCopy.endReason("unobserved-interval"), HistoryRecordingCopy.endReason("observed-zero"))
    }
    func testUnspecifiedExportFailureDoesNotAssertThatItIsOversized() {
        let generic = HistoryRecordingCopy.exportFailure(HistoryQueryFailure.expired)
        XCTAssertFalse(generic.contains("过多"))
        XCTAssertTrue(HistoryRecordingCopy.exportFailure(BackgroundNetworkWire.Failure.responseTooLarge).contains("过多"))
    }
    @MainActor func testGenericReadFailureKeepsCodeButDoesNotGuessWhyHistoryIsMissing() async {
        let model = BackgroundNetworkViewModel(now: { Date(timeIntervalSince1970: 1_800_000_000) })
        model.onQuery = { _ in throw HistoryQueryFailure.expired }
        model.reload(); await model.currentQueryTask?.value
        XCTAssertEqual(model.queryDiagnosticCode, HistoryQueryFailure.expired.code)
        model.onQuery = { _ in throw NSError(domain: "unknown", code: 42) }
        model.reload(); await model.currentQueryTask?.value
        XCTAssertEqual(model.queryDiagnosticCode, "history.query-unavailable")
        XCTAssertFalse(model.queryIssue?.contains("数据库正在使用") ?? true)
        model.closeHistory(); XCTAssertNil(model.queryDiagnosticCode)
    }
    func testShortcutStatusIsStillAvailableWithoutItsRawNumericCodeInTheLabel() {
        let raw = "打开设置未注册，可能已被其它软件占用（OSStatus -9878）。"
        XCTAssertEqual(ShortcutErrorCopy.displayText(raw), "打开设置未注册，可能已被其它软件占用。")
        XCTAssertTrue(raw.contains("-9878"))
    }
}
