import XCTest
import UsageButlerCore
import UsageButlerDomain
import UsageButlerInfrastructure
@testable import UsageButlerUI

private final class HistoryPresentationAge: @unchecked Sendable {
    private let lock = NSLock()
    private var seconds: UInt64 = 1
    func read() -> HistoryAgeSample {
        lock.lock(); defer { lock.unlock() }
        return .init(boot: "synthetic-retention", continuousNanoseconds: seconds * 1_000_000_000)
    }
    func set(_ value: UInt64) { lock.lock(); defer { lock.unlock() }; seconds = value }
}

/// These regressions use the actual isolated SQLite Store → Query → presentation
/// path. Wall times are fixture inputs, never changes to the machine's clock.
@MainActor
final class HistoryEvidencePresentationTests: XCTestCase {
    private let day: TimeInterval = 1_699_920_000
    private let key = "synthetic-history-evidence"

    private func directory() throws -> URL {
        let result = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".build/history-native-usability-round02-20260928/test-databases/" + UUID().uuidString)
        try FileManager.default.createDirectory(at: result, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        return result
    }

    private func frame(_ sequence: UInt64, at wall: TimeInterval, start: TimeInterval? = nil,
                       upload: UInt64?, download: UInt64?, attributed: Bool = true) -> ProcessNetworkSettlement {
        .init(session: "synthetic-wall-clock", sequence: sequence,
            start: .init(timeIntervalSince1970: start ?? wall - 1), end: .init(timeIntervalSince1970: wall),
            monotonicEnd: sequence * 1_000_000_000, durationNanoseconds: 1_000_000_000,
            complete: true, lostFrames: 0,
            applications: [.init(identity: .init(key: key, name: "Synthetic history", evidence: attributed ? .executable : .unknown),
                upload: upload, download: download, uploadIssue: nil, downloadIssue: nil)])
    }

    private func assertNeutralFirstWallTime(_ result: HistoryQueryResult,
                                            file: StaticString = #filePath, line: UInt = #line) throws {
        let notice = try XCTUnwrap(HistoryCurvePresentation.historyNotice(coverage: result.coverage, range: result.range),
                                  file: file, line: line)
        XCTAssertTrue(notice.contains("首次开始记录时的系统时间"), notice, file: file, line: line)
        XCTAssertFalse(notice.contains("尚未记录"), notice, file: file, line: line)
        XCTAssertFalse(notice.contains("采集历史始于"), notice, file: file, line: line)
        XCTAssertFalse(notice.contains("回拨"), "A minute bucket alone does not prove clock rollback", file: file, line: line)
    }

    func testBackwardWallClockKeepsEarlierValidBucketsAndNeutralNotice() async throws {
        let store = try NetworkHistoryStore(directory: directory(), clock: {
            .init(boot: "synthetic-evidence", continuousNanoseconds: 1_000_000_000)
        })
        let firstWall = day + 10 * 3_600 + 17, earlier = day + 8 * 3_600
        try await store.accept(frame(1, at: firstWall, upload: 77, download: 88))
        // The jump itself has a mismatched wall interval and must remain unknown.
        try await store.accept(frame(2, at: earlier - 1, start: firstWall, upload: 999_999, download: 999_999))
        for second in 0..<60 {
            try await store.accept(frame(UInt64(second + 3), at: earlier + Double(second), upload: 100, download: 0))
        }
        for second in 60..<120 {
            try await store.accept(frame(UInt64(second + 3), at: earlier + Double(second), upload: nil, download: 200))
        }
        try await store.close()
        let databaseBefore = try Data(contentsOf: store.databaseURL)
        let query = UsageButlerInfrastructure.NetworkHistoryQuery(databaseURL: store.databaseURL)
        let transition = try await query.query(range: .init(start: .init(timeIntervalSince1970: earlier - 60),
            end: .init(timeIntervalSince1970: earlier)), applicationKey: key)
        let unknown = try XCTUnwrap(transition.curve.first)
        XCTAssertTrue(unknown.totals.quality.contains(.clockChanged))
        XCTAssertNil(HistoryCurvePresentation.average(unknown, upload: true))
        XCTAssertNil(HistoryCurvePresentation.average(unknown, upload: false))
        XCTAssertEqual(unknown.totals.uploadObservedMicroseconds, 0)
        XCTAssertEqual(unknown.totals.downloadObservedMicroseconds, 0)

        let range = HistoryRange(start: .init(timeIntervalSince1970: earlier), end: .init(timeIntervalSince1970: earlier + 3_600))
        let result = try await query.query(range: range, applicationKey: key)
        XCTAssertEqual(result.coverage.firstCollectedAt, Date(timeIntervalSince1970: firstWall))
        XCTAssertLessThan(range.end, try XCTUnwrap(result.coverage.firstCollectedAt))
        XCTAssertEqual(result.curve.count, 2)
        let valid = try XCTUnwrap(result.curve.first), asymmetric = try XCTUnwrap(result.curve.last)
        XCTAssertEqual(valid.totals.upload, 6_000); XCTAssertEqual(valid.totals.download, 0)
        XCTAssertEqual(valid.totals.uploadObservedMicroseconds, 60_000_000)
        XCTAssertEqual(valid.totals.downloadObservedMicroseconds, 60_000_000)
        XCTAssertFalse(valid.totals.quality.contains(.clockChanged))
        XCTAssertEqual(HistoryCurvePresentation.average(valid, upload: true), 100)
        XCTAssertEqual(HistoryCurvePresentation.observation(valid, upload: false), "已观察为零 · 已记录")
        XCTAssertNil(HistoryCurvePresentation.average(asymmetric, upload: true))
        XCTAssertEqual(HistoryCurvePresentation.observation(asymmetric, upload: true), "无可用记录")
        XCTAssertEqual(asymmetric.totals.download, 12_000)
        XCTAssertEqual(HistoryCurvePresentation.average(asymmetric, upload: false), 200)
        try assertNeutralFirstWallTime(result)

        let reread = try await query.query(range: range, applicationKey: key)
        XCTAssertEqual(reread.curve, result.curve)
        XCTAssertEqual(reread.applications.first?.totals, result.applications.first?.totals)
        XCTAssertEqual(reread.coverage.firstCollectedAt, result.coverage.firstCollectedAt)
        XCTAssertEqual(try Data(contentsOf: store.databaseURL), databaseBefore)
        print("HIST-F005 Store→Query: jump unknown; earlier 2 buckets; upload 6000 B/60 s, download 12000 B/120 s; metadata.first unchanged")
    }

    func testNormalFirstMinuteBeginningBeforeFirstFrameIsNotClockRollback() async throws {
        // Both an ordinary first second and a frame crossing the minute are
        // assigned whole to the ending minute, without inventing clock changes.
        for offset in [0.5, 17.0] {
            let store = try NetworkHistoryStore(directory: directory())
            let wall = day + 8 * 3_600 + offset
            try await store.accept(frame(1, at: wall, upload: 100, download: 0))
            try await store.close()
            let result = try await UsageButlerInfrastructure.NetworkHistoryQuery(databaseURL: store.databaseURL).query(
                range: .init(start: .init(timeIntervalSince1970: day + 8 * 3_600),
                             end: .init(timeIntervalSince1970: day + 9 * 3_600)), applicationKey: key)
            let point = try XCTUnwrap(result.curve.first)
            XCTAssertLessThan(point.start, try XCTUnwrap(result.coverage.firstCollectedAt))
            XCTAssertFalse(point.totals.quality.contains(.clockChanged))
            XCTAssertEqual(point.totals.quality.contains(.minuteBoundary), offset < 1)
            XCTAssertEqual(point.totals.upload, 100); XCTAssertEqual(point.totals.uploadObservedMicroseconds, 1_000_000)
            try assertNeutralFirstWallTime(result)
        }
    }

    func testNoReturnedBucketsBeforeFirstFrameDoNotProveNeverRecorded() async throws {
        let store = try NetworkHistoryStore(directory: directory())
        try await store.accept(frame(1, at: day + 8 * 3_600 + 17, upload: 100, download: 0))
        try await store.close()
        let result = try await UsageButlerInfrastructure.NetworkHistoryQuery(databaseURL: store.databaseURL).query(
            range: .init(start: .init(timeIntervalSince1970: day + 7 * 3_600),
                         end: .init(timeIntervalSince1970: day + 8 * 3_600)), applicationKey: key)
        XCTAssertTrue(result.curve.isEmpty); XCTAssertTrue(result.applications.isEmpty)
        XCTAssertFalse(result.coverage.retentionTrimmed)
        try assertNeutralFirstWallTime(result)
        XCTAssertEqual(HistoryCurvePresentation.emptyText(result), "此范围没有已保存的应用观察；未知时段不能当作零流量。")
    }

    func testRetentionEvidenceStillExplainsEmptyRangeBeforeFirstWallTime() async throws {
        let age = HistoryPresentationAge()
        let store = try NetworkHistoryStore(directory: directory(), clock: age.read)
        let firstWall = day + 8 * 3_600 + 17
        try await store.accept(frame(1, at: firstWall, upload: 100, download: 0))
        try await store.flush()
        age.set(15 * 86_400)
        let retainedWall = firstWall + 15 * 86_400
        try await store.accept(frame(2, at: retainedWall, upload: 200, download: 0))
        try await store.close()
        let query = UsageButlerInfrastructure.NetworkHistoryQuery(databaseURL: store.databaseURL)
        let result = try await query.query(range: .init(start: .init(timeIntervalSince1970: day + 7 * 3_600),
            end: .init(timeIntervalSince1970: day + 8 * 3_600)), applicationKey: key)
        XCTAssertTrue(result.curve.isEmpty); XCTAssertTrue(result.applications.isEmpty)
        XCTAssertTrue(result.coverage.retentionTrimmed)
        XCTAssertEqual(result.coverage.firstCollectedAt, Date(timeIntervalSince1970: firstWall))
        XCTAssertEqual(result.coverage.oldestRetainedAt, Date(timeIntervalSince1970: retainedWall))
        try assertNeutralFirstWallTime(result)
        XCTAssertEqual(HistoryCurvePresentation.emptyText(result), "此范围的记录已超出保留期限。")

        let retained = try await query.query(range: .init(start: .init(timeIntervalSince1970: retainedWall - 17),
            end: .init(timeIntervalSince1970: retainedWall - 17 + 60)), applicationKey: key)
        XCTAssertEqual(retained.curve.first?.totals.upload, 200)
        XCTAssertEqual(retained.curve.first?.totals.uploadObservedMicroseconds, 1_000_000)
        let laterEmpty = try await query.query(range: .init(start: .init(timeIntervalSince1970: retainedWall - 17 + 60),
            end: .init(timeIntervalSince1970: retainedWall - 17 + 120)), applicationKey: key)
        XCTAssertTrue(laterEmpty.applications.isEmpty)
        XCTAssertEqual(HistoryCurvePresentation.emptyText(laterEmpty), "此范围没有已保存的应用观察；未知时段不能当作零流量。")
    }

    func testUnattributedSourceBeforeFirstWallTimeIsNotDeniedAsPrehistory() async throws {
        let store = try NetworkHistoryStore(directory: directory())
        let firstWall = day + 10 * 3_600, earlier = day + 8 * 3_600
        try await store.accept(frame(1, at: firstWall, upload: 100, download: 0))
        try await store.accept(frame(2, at: earlier - 1, start: firstWall, upload: 999, download: 999, attributed: false))
        try await store.accept(frame(3, at: earlier, upload: 200, download: 0, attributed: false))
        try await store.close()
        let result = try await UsageButlerInfrastructure.NetworkHistoryQuery(databaseURL: store.databaseURL).query(
            range: .init(start: .init(timeIntervalSince1970: earlier), end: .init(timeIntervalSince1970: earlier + 3_600)))
        XCTAssertTrue(result.applications.isEmpty); XCTAssertTrue(result.curve.isEmpty)
        XCTAssertEqual(result.coverage.unattributedSamples, 1)
        XCTAssertEqual(result.coverage.sourceSamples, 1)
        try assertNeutralFirstWallTime(result)
        XCTAssertEqual(HistoryCurvePresentation.emptyText(result), "此范围有源采样，但没有可归属应用的历史。")
    }
}
