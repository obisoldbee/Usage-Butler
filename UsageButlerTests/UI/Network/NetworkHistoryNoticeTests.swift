import XCTest
import UsageButlerDomain
@testable import UsageButlerUI

final class NetworkHistoryNoticeTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func total(_ reason: String?, age: TimeInterval = 30, upload: Bool = false) -> SessionByteTotal {
        let restarted = DirectionByteTotal(bytes: 100, since: now.addingTimeInterval(-age),
                                          sinceMonotonic: nil, breakReason: reason)
        let continuous = DirectionByteTotal(bytes: 200, since: now.addingTimeInterval(-7_200), sinceMonotonic: nil)
        return .init(upload: upload ? restarted : continuous, download: upload ? continuous : restarted)
    }

    private func sample(age: TimeInterval, upload: Double? = 0, download: Double? = 1) -> NetworkRateSample {
        .init(captureSessionID: .init(rawValue: "session"), counterEpoch: .init(rawValue: 1),
              sampledAt: now.addingTimeInterval(-age), sampledMonotonic: .init(nanoseconds: 1),
              uploadBytesPerSecond: upload, downloadBytesPerSecond: download, interfaceName: "en0")
    }

    func testStartupAndUnknownLegacyStartDoNotWarn() {
        for reason: String? in [nil, "legacy-unverified"] {
            XCTAssertNil(NetworkStatusRules.historyRestartNotice(total(reason), samples: [sample(age: 45)], now: now, window: 60))
        }
        XCTAssertNil(NetworkStatusRules.historyRestartNotice(nil, samples: [], now: now, window: 60))
        // A collector initially missing data has no earlier observed span to lose.
        XCTAssertNil(NetworkStatusRules.historyRestartNotice(total("missing-counter"), samples: [sample(age: 20)], now: now, window: 60))
    }

    func testOldRestartDisappearsFromOneMinuteButRemainsInOneHour() {
        let old = total("counter-reset", age: 120)
        let history = [sample(age: 150), sample(age: 30)]
        XCTAssertNil(NetworkStatusRules.historyRestartNotice(old, samples: history, now: now, window: 60))
        XCTAssertEqual(NetworkStatusRules.historyRestartNotice(old, samples: history, now: now, window: 3_600),
                       "所选范围内下载统计曾重新起算 · 详见网络设置")
        XCTAssertEqual(old.download.breakReason, "counter-reset", "diagnostic evidence is retained")
    }

    func testEachDirectionNeedsEarlierObservedDataInTheWindow() {
        XCTAssertNil(NetworkStatusRules.historyRestartNotice(total("counter-reset"),
                     samples: [sample(age: 45, download: nil)], now: now, window: 60))
        // A measured zero is valid earlier evidence, not an unknown direction.
        XCTAssertEqual(NetworkStatusRules.historyRestartNotice(total("sampling-gap", upload: true),
                       samples: [sample(age: 45)], now: now, window: 60),
                       "所选范围内上传统计曾重新起算 · 详见网络设置")
    }

    func testBothDirectionsRestartTogether() {
        let segment = total("epoch-changed").download
        let both = SessionByteTotal(upload: segment, download: segment)
        XCTAssertEqual(NetworkStatusRules.historyRestartNotice(both, samples: [sample(age: 45)], now: now, window: 60),
                       "所选范围内上传、下载统计曾重新起算 · 详见网络设置")
    }

    func testOutOfRangeEvidenceDoesNotCreateAWarning() {
        for age in [60.0, 61, -1] {
            XCTAssertNil(NetworkStatusRules.historyRestartNotice(total("counter-reset", age: age),
                         samples: [sample(age: 90)], now: now, window: 60))
        }
        XCTAssertNil(NetworkStatusRules.historyRestartNotice(total("counter-reset"),
                     samples: [sample(age: 90)], now: now, window: 60))
    }

    func testAllRecordedRestartReasonsHaveReadableDescriptions() {
        for reason in ["counter-reset", "sampling-gap", "missing-counter", "epoch-changed", "counter-overflow", "legacy-unverified"] {
            XCTAssertFalse(NetworkStatusRules.sessionTotalReasonText(reason).contains(reason))
        }
    }
}
