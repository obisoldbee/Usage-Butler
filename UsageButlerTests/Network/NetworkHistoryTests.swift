import Darwin
import Foundation
import XCTest
@testable import UsageButlerCore
import UsageButlerDomain
@testable import UsageButlerInfrastructure

final class HistoryMinuteTests: XCTestCase {
    func testAllIntegerBoundariesRoundTripWithoutFloatingConversion() {
        for bytes: UInt64 in [0, 1, (1 << 53) - 1, (1 << 53) + 1, UInt64(Int64.max), UInt64(Int64.max) + 1, .max] {
            let value = HistoryMinute(upload: bytes, download: 0, durationNanoseconds: 1_000_000_000,
                firstMillisecond: -500, lastMillisecond: 500, quality: [.minuteBoundary])
            XCTAssertEqual(value.encoded.count, 56)
            XCTAssertEqual(HistoryMinute(encoded: value.encoded), value)
            XCTAssertEqual(value.totals.upload, bytes); XCTAssertEqual(value.totals.download, 0)
            XCTAssertEqual(value.totals.uploadObservedMicroseconds, 1_000_000)
        }
        XCTAssertNil(HistoryMinute(encoded: Data(repeating: 0, count: 55)))
    }
    func testDirectionOverflowDoesNotEraseOtherDirectionOrBecomeZero() {
        var a = HistoryMinute(upload: .max, download: 3, durationNanoseconds: 1_000_000_000, firstMillisecond: 0, lastMillisecond: 1000)
        a.merge(.init(upload: 1, download: 5, durationNanoseconds: 1_000_000_000, firstMillisecond: 1000, lastMillisecond: 2000))
        XCTAssertNil(a.totals.upload); XCTAssertEqual(a.totals.download, 8)
        XCTAssertTrue(a.quality.contains(.uploadOverflow)); XCTAssertFalse(a.quality.contains(.downloadOverflow))
        var total = HistoryTotals(); total.merge(a.totals)
        total.merge(HistoryMinute(upload: 10, download: 1, durationNanoseconds: 1_000_000_000,
            firstMillisecond: 2000, lastMillisecond: 3000).totals)
        XCTAssertNil(total.upload); XCTAssertEqual(total.download, 9)
    }
    func testUnknownPartialAndKnownZeroHaveDifferentCoverage() {
        var minute = HistoryMinute(upload: nil, download: 0, durationNanoseconds: 1_000_000_000, firstMillisecond: 0, lastMillisecond: 1000)
        XCTAssertNil(minute.totals.upload); XCTAssertEqual(minute.totals.download, 0)
        minute.merge(.init(upload: 0, download: 1, durationNanoseconds: 1_000_000_000, firstMillisecond: 1000, lastMillisecond: 2000))
        XCTAssertEqual(minute.totals.upload, 0); XCTAssertEqual(minute.uploadMicroseconds, 1_000_000)
        XCTAssertTrue(minute.quality.contains(.uploadGap)); XCTAssertEqual(minute.downloadMicroseconds, 2_000_000)
    }
    func testPeakIsNotAverageAndPartialMinuteIsNotFullCoverage() {
        var minute = HistoryMinute(upload: 100_000, download: 1, durationNanoseconds: 1_000_000_000, firstMillisecond: 0, lastMillisecond: 1000)
        for index in 1..<59 {
            minute.merge(.init(upload: 0, download: 1, durationNanoseconds: 1_000_000_000,
                firstMillisecond: Int32(index * 1000), lastMillisecond: Int32((index + 1) * 1000)))
        }
        XCTAssertEqual(minute.peakUpload, 100_000); XCTAssertEqual(minute.uploadMicroseconds, 59_000_000)
        XCTAssertNotEqual(minute.peakUpload, Double(minute.upload) / 59)
    }
    func testRetentionAgeDoesNotInventPowerOffTimeOrUseWallClock() {
        var clock = HistoryRetentionClock()
        clock.advance(.init(boot: "a", continuousNanoseconds: 1_000_000_000))
        clock.advance(.init(boot: "a", continuousNanoseconds: 101_000_000_000))
        XCTAssertEqual(clock.ageSeconds, 100)
        clock.advance(.init(boot: "b", continuousNanoseconds: 900_000_000_000))
        XCTAssertEqual(clock.ageSeconds, 100); XCTAssertTrue(clock.conservative)
        clock.advance(.init(boot: "b", continuousNanoseconds: 905_000_000_000))
        XCTAssertEqual(clock.ageSeconds, 105)
        clock.advance(.init(boot: "b", continuousNanoseconds: 1))
        XCTAssertEqual(clock.ageSeconds, 105)
    }
    func testActivityThresholdGapBelowRateAndRuleEvidence() {
        var activity = HistoryActivityAccumulator()
        let rule = HistoryUploadRule(largeBytes: 1_048_576, sustainedSeconds: 5, sustainedBytesPerSecond: 1024)
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        for second in 1...4 { activity.accept(app: 1, segment: 1, upload: 1024, end: start.addingTimeInterval(Double(second)), seconds: 1, rule: rule) }
        XCTAssertTrue(activity.drainChanges().isEmpty)
        activity.accept(app: 1, segment: 1, upload: nil, end: start.addingTimeInterval(5), seconds: 1, rule: rule)
        activity.accept(app: 1, segment: 1, upload: 1_048_576, end: start.addingTimeInterval(6), seconds: 1, rule: rule)
        let large = activity.drainChanges(); XCTAssertEqual(large.count, 1); XCTAssertEqual(large.first?.kind, "large")
        XCTAssertEqual(large.first?.start, start.addingTimeInterval(5)); XCTAssertEqual(large.first?.rule, rule)
        activity.assign(large[0].key, id: 12)
        activity.accept(app: 1, segment: 1, upload: 0, end: start.addingTimeInterval(7), seconds: 1, rule: rule)
        let closed = activity.drainChanges(); XCTAssertEqual(closed.first?.reason, "observed-zero")
        XCTAssertEqual(closed.first?.databaseID, 12)
    }
}

private final class HistoryTestAge: @unchecked Sendable {
    private let lock = NSLock()
    private var sample = HistoryAgeSample(boot: "history-test", continuousNanoseconds: 1_000_000_000)
    func read() -> HistoryAgeSample { lock.lock(); defer { lock.unlock() }; return sample }
    func set(_ seconds: UInt64, boot: String = "history-test") {
        lock.lock(); defer { lock.unlock() }; sample = .init(boot: boot, continuousNanoseconds: seconds * 1_000_000_000)
    }
}

@MainActor
final class NetworkHistoryStoreTests: XCTestCase {
    private let day: TimeInterval = 1_699_920_000 // UTC midnight, minute aligned.
    private func directory() throws -> URL {
        let result = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".build/background-history-0.5.0/test-databases/" + UUID().uuidString)
        try FileManager.default.createDirectory(at: result, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return result
    }
    #if DEBUG
    func testSystemTmpAliasRejectsOldFoundationPathAndOpensCanonicalHistory() async throws {
        let fm = FileManager.default
        let root = URL(fileURLWithPath: "/tmp", isDirectory: true)
            .appendingPathComponent("UsageButler-HistoryAliasTests-" + UUID().uuidString, isDirectory: true)
        let contents = root.appendingPathComponent("Validation.app/Contents", isDirectory: true)
        try fm.createDirectory(at: contents, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let info = ["CFBundleIdentifier": "io.github.obisoldbee.UsageButler.Validation.TmpAliasTest",
                    "CFBundlePackageType": "APPL", "CFBundleExecutable": "Validation"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: contents.appendingPathComponent("Info.plist"))
        let bundle = try XCTUnwrap(Bundle(url: contents.deletingLastPathComponent()))
        let oldDirectory = bundle.bundleURL.resolvingSymlinksInPath().deletingLastPathComponent()
            .appendingPathComponent("HistoryValidationData", isDirectory: true)
        let data = try BackgroundNetworkLocation.directory(bundle: bundle)
        XCTAssertTrue(oldDirectory.path.hasPrefix("/tmp/"))
        XCTAssertTrue(data.path.hasPrefix("/private/tmp/"))
        let store = try NetworkHistoryStore(directory: data)
        try await store.close()
        // Reproduce the rejected old route against the exact same SQLite file.
        XCTAssertThrowsError(try HistoryDatabase(path: oldDirectory.appendingPathComponent("history-v1.sqlite"), readOnly: true)) {
            XCTAssertEqual($0 as? NetworkHistoryError, .sqlite(14))
        }
    }
    func testValidationBundleAliasKeepsDataAtCanonicalParentAndRejectsDataSymlink() async throws {
        let root = try directory(), fm = FileManager.default
        let parent = root.appendingPathComponent("actual", isDirectory: true)
        let bundleURL = parent.appendingPathComponent("Validation.app", isDirectory: true)
        let contents = bundleURL.appendingPathComponent("Contents", isDirectory: true)
        try fm.createDirectory(at: contents, withIntermediateDirectories: true)
        let info = ["CFBundleIdentifier": "io.github.obisoldbee.UsageButler.Validation.AliasTest",
                    "CFBundlePackageType": "APPL", "CFBundleExecutable": "Validation"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: contents.appendingPathComponent("Info.plist"))
        let alias = root.appendingPathComponent("alias", isDirectory: true)
        try fm.createSymbolicLink(at: alias, withDestinationURL: parent)
        let bundle = try XCTUnwrap(Bundle(url: alias.appendingPathComponent("Validation.app")))
        let data = try BackgroundNetworkLocation.directory(bundle: bundle)
        XCTAssertEqual(data.path, parent.resolvingSymlinksInPath().appendingPathComponent("HistoryValidationData").path)
        let store = try NetworkHistoryStore(directory: data)
        try await store.close()
        try fm.removeItem(at: data)
        let otherData = root.appendingPathComponent("other-data", isDirectory: true)
        try fm.createDirectory(at: otherData, withIntermediateDirectories: false)
        try fm.createSymbolicLink(at: data, withDestinationURL: otherData)
        XCTAssertEqual(try BackgroundNetworkLocation.directory(bundle: bundle).path, data.path)
        XCTAssertThrowsError(try NetworkHistoryStore(directory: data)) {
            XCTAssertEqual($0 as? NetworkHistoryError, .unsafePath)
        }
    }
    #endif
    private func frame(_ sequence: UInt64, at: TimeInterval, upload: UInt64?, download: UInt64? = 0,
                       session: String = "source-a", name: String = "Synthetic", key: String = "synthetic",
                       duration: UInt64 = 1_000_000_000, start: TimeInterval? = nil) -> ProcessNetworkSettlement {
        .init(session: session, sequence: sequence,
            start: .init(timeIntervalSince1970: start ?? at - Double(duration) / 1e9), end: .init(timeIntervalSince1970: at),
            monotonicEnd: sequence * 1_000_000_000, durationNanoseconds: duration, complete: true, lostFrames: 0,
            applications: [.init(identity: .init(key: key, name: name, evidence: .executable),
                                 upload: upload, download: download, uploadIssue: nil, downloadIssue: nil)])
    }
    func testActualSQLiteFullRollsBackAndReaderPreservesCommittedPrefix() async throws {
        let store = try NetworkHistoryStore(directory: directory(), configuration: .init(pageLimit: 32))
        var rejected = false
        for sequence in 1...200 {
            do { try await store.accept(frame(UInt64(sequence), at: day + Double(sequence), upload: 3, key: String(repeating: "k", count: 1000) + "-\(sequence)")); try await store.flush() }
            catch { XCTAssertEqual(error as? NetworkHistoryError, .sqlite(13)); rejected = true; break }
        }
        XCTAssertTrue(rejected)
        let coverage = await store.coverage(); XCTAssertEqual(coverage.issue, "history.sqlite.13")
        let read = try HistoryDatabase(path: store.databaseURL, readOnly: true)
        let integrity = try read.statement("PRAGMA quick_check"); XCTAssertTrue(try integrity.next()); XCTAssertEqual(integrity.text(0), "ok")
        XCTAssertGreaterThan(try read.scalar("SELECT count(*) FROM buckets"), 0); read.close()
        do { try await store.close(); XCTFail("failed close must not claim flush") } catch {}
    }
    func testPinnedReaderCannotGrowWALPastPrecommitBudget() async throws {
        let store = try NetworkHistoryStore(directory: directory())
        let reader = try HistoryDatabase(path: store.databaseURL, readOnly: true)
        try reader.execute("BEGIN"); _ = try reader.scalar("SELECT count(*) FROM buckets")
        var failed = false, maximumWAL: Int64 = 0
        for sequence in 1...32 {
            let end = day + Double(sequence)
            let apps = (0..<256).map { id in
                ProcessNetworkSettlement.Application(identity: .init(key: "a-\(id)", name: String(repeating: "x", count: 900) + "-\(sequence)-\(id)", evidence: .executable), upload: 1, download: 0, uploadIssue: nil, downloadIssue: nil)
            }
            do {
                try await store.accept(.init(session: "wal-pressure", sequence: UInt64(sequence), start: .init(timeIntervalSince1970: end-1), end: .init(timeIntervalSince1970: end), monotonicEnd: UInt64(sequence)*1_000_000_000, durationNanoseconds: 1_000_000_000, complete: true, lostFrames: 0, applications: apps))
                try await store.flush()
            } catch { XCTAssertEqual(error as? NetworkHistoryError, .capacity); failed = true }
            maximumWAL = max(maximumWAL, (await store.coverage()).walBytes)
            if failed { break }
        }
        XCTAssertTrue(failed); XCTAssertGreaterThan(maximumWAL, 8*1_048_576); XCTAssertLessThanOrEqual(maximumWAL, 16*1_048_576)
        try reader.execute("ROLLBACK"); reader.close()
        do { try await store.close(); XCTFail("capacity failure remains visible") } catch {}
    }
    func testExpiredIdentityCatalogueIsReclaimedAcrossManySessions() async throws {
        let age = HistoryTestAge(), store = try NetworkHistoryStore(directory: directory(), configuration: .init(catalogueLimit: 3), clock: age.read)
        for i in 0..<8 {
            age.set(UInt64(i*15*86400 + 1))
            try await store.accept(frame(1, at: day + Double(i*15*86400+1), upload: 7, session: "source-\(i)", key: "application-\(i)"))
            try await store.flush()
        }
        let read = try HistoryDatabase(path: store.databaseURL, readOnly: true)
        XCTAssertEqual(try read.scalar("SELECT count(*) FROM applications"), 1)
        XCTAssertEqual(try read.scalar("SELECT count(*) FROM sessions"), 1)
        XCTAssertEqual(try read.scalar("SELECT count(*) FROM segments WHERE age<0"), 0)
        read.close(); try await store.close()
    }
    func testExactCommitReplayRestartAndSecondWriterRefusal() async throws {
        let directory = try directory(), age = HistoryTestAge()
        let store = try NetworkHistoryStore(directory: directory, clock: age.read)
        XCTAssertThrowsError(try NetworkHistoryStore(directory: directory)) { XCTAssertEqual($0 as? NetworkHistoryError, .alreadyRunning) }
        let first = frame(1, at: day + 1, upload: (1 << 53) + 1, download: 0)
        try await store.accept(first); try await store.accept(first)
        try await store.accept(frame(2, at: day + 2, upload: 2, download: nil)); try await store.flush()
        let query = NetworkHistoryQuery(databaseURL: store.databaseURL)
        let range = HistoryRange(start: .init(timeIntervalSince1970: day), end: .init(timeIntervalSince1970: day + 3600))
        let result = try await query.query(range: range)
        XCTAssertEqual(result.applications.first?.totals.upload, (1 << 53) + 3)
        XCTAssertEqual(result.applications.first?.totals.download, 0)
        XCTAssertEqual(result.applications.first?.totals.uploadSamples, 2)
        XCTAssertEqual(result.applications.first?.totals.downloadSamples, 1)
        try await store.close()
        let reopened = try NetworkHistoryStore(directory: directory, clock: age.read)
        try await reopened.accept(first); try await reopened.flush()
        let again = try await query.query(range: range)
        XCTAssertEqual(again.applications, result.applications)
        XCTAssertFalse(again.coverage.recoveredUncleanSession)
        try await reopened.close()
    }
    func testQueryUsesOnlyCommittedTransactionAndImmutableIdentity() async throws {
        let store = try NetworkHistoryStore(directory: directory())
        let query = NetworkHistoryQuery(databaseURL: store.databaseURL)
        let range = HistoryRange(start: .init(timeIntervalSince1970: day), end: .init(timeIntervalSince1970: day + 3600))
        try await store.accept(frame(1, at: day + 1, upload: 1))
        let before = try await query.query(range: range); XCTAssertTrue(before.applications.isEmpty)
        try await store.accept(frame(2, at: day + 2, upload: 2, name: "Renamed")); try await store.flush()
        let result = try await query.query(range: range)
        XCTAssertEqual(result.applications.first?.identity.name, "Renamed")
        XCTAssertEqual(result.applications.first?.identitySnapshotCount, 2)
        XCTAssertEqual(result.applications.first?.totals.upload, 3)
        XCTAssertEqual(result.applications.count, 1)
        let raw = try HistoryDatabase(path: store.databaseURL, readOnly: true)
        XCTAssertEqual(try raw.scalar("SELECT count(*) FROM applications"), 2); raw.close()
        try await store.close()
    }
    func testPartialHourEdgesAndCurveDoNotDoubleCount() async throws {
        let store = try NetworkHistoryStore(directory: directory())
        for sequence in 1...125 {
            try await store.accept(frame(UInt64(sequence), at: day + Double(sequence * 60), upload: UInt64(sequence)))
        }
        try await store.flush()
        let query = NetworkHistoryQuery(databaseURL: store.databaseURL)
        let range = HistoryRange(start: .init(timeIntervalSince1970: day + 3 * 60), end: .init(timeIntervalSince1970: day + 123 * 60))
        let result = try await query.query(range: range)
        XCTAssertEqual(result.applications.first?.totals.upload, UInt64((3..<123).reduce(0, +)))
        let detail = try await query.query(range: range, applicationID: result.applications[0].id)
        XCTAssertEqual(detail.curve.count, 120)
        XCTAssertEqual(detail.curve.compactMap { $0.totals.upload }.reduce(0, +), result.applications.first?.totals.upload)
        try await store.close()
    }
    func testWallJumpDoesNotChargeAnIntervalAndDoesNotDeleteNotExpiredData() async throws {
        let age = HistoryTestAge(), store = try NetworkHistoryStore(directory: directory(), clock: age.read)
        try await store.accept(frame(1, at: day + 1, upload: 10)); try await store.flush()
        age.set(2)
        try await store.accept(frame(2, at: day + 30 * 86_400, upload: 900, start: day + 1)); try await store.flush()
        let query = NetworkHistoryQuery(databaseURL: store.databaseURL)
        let old = try await query.query(range: .init(start: .init(timeIntervalSince1970: day), end: .init(timeIntervalSince1970: day + 60)))
        XCTAssertEqual(old.applications.first?.totals.upload, 10)
        let new = try await query.query(range: .init(start: .init(timeIntervalSince1970: day + 30 * 86_400), end: .init(timeIntervalSince1970: day + 30 * 86_400 + 60)))
        XCTAssertNil(new.applications.first?.totals.upload)
        XCTAssertTrue(new.applications.first?.totals.quality.contains(.clockChanged) == true)
        try await store.close()
    }
    func testRetentionUsesContinuousAgeAndReportsTrimmed() async throws {
        let age = HistoryTestAge(), store = try NetworkHistoryStore(directory: directory(), clock: age.read)
        try await store.accept(frame(1, at: day + 1, upload: 10)); try await store.flush()
        age.set(15 * 86_400)
        try await store.accept(frame(1, at: day + 15 * 86_400 + 1, upload: 20, session: "source-b")); try await store.flush()
        let query = NetworkHistoryQuery(databaseURL: store.databaseURL)
        let old = try await query.query(range: .init(start: .init(timeIntervalSince1970: day), end: .init(timeIntervalSince1970: day + 60)))
        XCTAssertTrue(old.applications.isEmpty); XCTAssertTrue(old.coverage.retentionTrimmed)
        try await store.close()
    }
    func testPrivateFilesAndSQLLookingIdentityAreData() async throws {
        let directory = try directory(), store = try NetworkHistoryStore(directory: directory)
        try await store.accept(frame(1, at: day + 1, upload: 1, key: "'; DROP TABLE buckets; --")); try await store.flush()
        for url in [directory, store.databaseURL] {
            let attr = try FileManager.default.attributesOfItem(atPath: url.path)
            XCTAssertEqual((attr[.posixPermissions] as? NSNumber)?.intValue, url == directory ? 0o700 : 0o600)
        }
        let query = NetworkHistoryQuery(databaseURL: store.databaseURL)
        let result = try await query.query(range: .init(start: .init(timeIntervalSince1970: day), end: .init(timeIntervalSince1970: day + 60)))
        XCTAssertEqual(result.applications.first?.identity.key, "'; DROP TABLE buckets; --")
        try await store.close()
    }
    func testCapacityRollsBackAndReportsErrorInsteadOfLosingOlderCommittedData() async throws {
        let store = try NetworkHistoryStore(directory: directory(), configuration: .init(catalogueLimit: 1))
        try await store.accept(frame(1, at: day + 1, upload: 7)); try await store.flush()
        do { try await store.accept(frame(2, at: day + 2, upload: 8, name: "Second")); XCTFail("expected capacity") }
        catch { XCTAssertEqual(error as? NetworkHistoryError, .capacity) }
        let coverage = await store.coverage(); XCTAssertEqual(coverage.issue, "history.capacity")
        let query = NetworkHistoryQuery(databaseURL: store.databaseURL)
        let result = try await query.query(range: .init(start: .init(timeIntervalSince1970: day), end: .init(timeIntervalSince1970: day + 60)))
        XCTAssertEqual(result.applications.first?.totals.upload, 7)
        do { try await store.close() } catch { XCTAssertEqual(error as? NetworkHistoryError, .capacity) }
    }
    func testRejectsSymlinkAndUnsupportedSchemaWithoutReplacingData() async throws {
        let directory = try directory(), target = directory.appendingPathComponent("target")
        try Data("untouched".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(at: directory.appendingPathComponent("history-v1.sqlite"), withDestinationURL: target)
        XCTAssertThrowsError(try NetworkHistoryStore(directory: directory))
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "untouched")
        let other = try self.directory(), path = other.appendingPathComponent("history-v1.sqlite")
        let db = try HistoryDatabase(path: path); try db.execute("PRAGMA user_version=99"); db.close()
        XCTAssertThrowsError(try NetworkHistoryStore(directory: other)) { XCTAssertEqual($0 as? NetworkHistoryError, .unsupportedSchema) }
    }
    func testMalformedCheckpointIsCorruptionAndNeverReplayedAsZero() async throws {
        let directory = try directory(), store = try NetworkHistoryStore(directory: directory)
        try await store.accept(frame(1, at: day + 1, upload: 7)); try await store.close()
        let db = try HistoryDatabase(path: store.databaseURL)
        try db.execute("UPDATE sessions SET sequence='not-an-integer'"); db.close()
        let reopened = try NetworkHistoryStore(directory: directory)
        do { try await reopened.accept(frame(1, at: day + 1, upload: 7)); XCTFail("corrupt checkpoint must fail") }
        catch { XCTAssertEqual(error as? NetworkHistoryError, .corrupt) }
        do { try await reopened.close() } catch {}
    }
    func testCheckpointBusyIsSoftPressureAndRecoversAfterRealReaderReleases() throws {
        let directory = try directory(), path = directory.appendingPathComponent("read-contention.sqlite")
        let writer = try HistoryDatabase(path: path)
        try writer.execute("CREATE TABLE synthetic(id INTEGER PRIMARY KEY, value BLOB); INSERT INTO synthetic VALUES(1,zeroblob(4096))")
        let reader = try HistoryDatabase(path: path, readOnly: true)
        try reader.execute("BEGIN"); XCTAssertEqual(try reader.scalar("SELECT count(*) FROM synthetic"), 1)
        try writer.execute("INSERT INTO synthetic VALUES(2,zeroblob(4096))")
        XCTAssertFalse(try writer.checkpoint(allowBusy: true))
        try writer.execute("INSERT INTO synthetic VALUES(3,zeroblob(4096))")
        try reader.execute("ROLLBACK"); reader.close()
        XCTAssertTrue(try writer.checkpoint(allowBusy: true))
        XCTAssertEqual(try writer.scalar("SELECT count(*) FROM synthetic"), 3); writer.close()
    }
    func testTenThousandUnknownFrameIdentitiesDoNotExhaustApplicationCatalogue() async throws {
        let store = try NetworkHistoryStore(directory: directory(), configuration: .init(catalogueLimit: 4))
        for sequence in 1...10_000 {
            let known = frame(UInt64(sequence), at: day + Double(sequence), upload: 7)
            let unknown = ProcessNetworkSettlement.Application(identity: .init(key: "unknown-session-\(sequence)-91",
                name: "Unknown", evidence: .unknown), upload: nil, download: nil,
                uploadIssue: "members-changed", downloadIssue: "members-changed")
            try await store.accept(.init(session: known.session, sequence: known.sequence, start: known.start,
                end: known.end, monotonicEnd: known.monotonicEnd, durationNanoseconds: known.durationNanoseconds,
                complete: true, lostFrames: 0, applications: known.applications + [unknown]))
        }
        try await store.flush()
        let query = NetworkHistoryQuery(databaseURL: store.databaseURL)
        let result = try await query.query(range: .init(start: .init(timeIntervalSince1970: day), end: .init(timeIntervalSince1970: day + 10_020)))
        XCTAssertEqual(result.applications.count, 1); XCTAssertEqual(result.applications.first?.totals.upload, 70_000)
        XCTAssertEqual(result.coverage.unattributedSamples, 10_000)
        let db = try HistoryDatabase(path: store.databaseURL, readOnly: true)
        XCTAssertEqual(try db.scalar("SELECT count(*) FROM applications"), 1); db.close()
        let status = await store.coverage(); XCTAssertNil(status.issue); try await store.close()
    }
    func testEventCapacityNeverStopsBaseMinuteHistory() async throws {
        let store = try NetworkHistoryStore(directory: directory(), configuration: .init(eventLimit: 1))
        try await store.setUploadRule(.init(largeBytes: 1_048_576, sustainedSeconds: 5, sustainedBytesPerSecond: 1024))
        try await store.accept(frame(1, at: day + 1, upload: 1_048_576))
        try await store.accept(frame(2, at: day + 2, upload: 0))
        try await store.accept(frame(3, at: day + 3, upload: 1_048_576)); try await store.flush()
        let query = NetworkHistoryQuery(databaseURL: store.databaseURL)
        let result = try await query.query(range: .init(start: .init(timeIntervalSince1970: day), end: .init(timeIntervalSince1970: day + 60)))
        XCTAssertTrue(result.coverage.eventsTruncated); XCTAssertEqual(result.events.count, 1)
        XCTAssertEqual(result.applications.first?.totals.upload, 2_097_152)
        let status = await store.coverage(); XCTAssertNil(status.issue); try await store.close()
    }
    func testMidnightActivityBoundaryPreservesNewEventAfterOldSegmentExpires() async throws {
        let age = HistoryTestAge(), store = try NetworkHistoryStore(directory: directory(), clock: age.read)
        try await store.setUploadRule(.init(largeBytes: 1_048_576, sustainedSeconds: 5, sustainedBytesPerSecond: 1024))
        try await store.accept(frame(1, at: day + 86_399, upload: 1_048_576))
        try await store.accept(frame(2, at: day + 86_400, upload: 1_048_576)); try await store.flush()
        let query = NetworkHistoryQuery(databaseURL: store.databaseURL)
        var result = try await query.query(range: .init(start: .init(timeIntervalSince1970: day + 86_340), end: .init(timeIntervalSince1970: day + 86_460)))
        XCTAssertEqual(result.events.count, 2)
        XCTAssertTrue(result.events.contains { $0.endReason == "utc-day-boundary" })
        age.set(14 * 86_400 + 10)
        try await store.accept(frame(1, at: day + 15 * 86_400 + 1, upload: 1_048_576, session: "new-source")); try await store.flush()
        result = try await query.query(range: .init(start: .init(timeIntervalSince1970: day + 15 * 86_400), end: .init(timeIntervalSince1970: day + 15 * 86_400 + 60)))
        XCTAssertEqual(result.events.count, 1); XCTAssertEqual(result.events.first?.bytes, 1_048_576)
        try await store.close()
    }
    func testStableIdentityChangesKeepOneActivityAndOneExportAliasAndPagedTotals() async throws {
        let store = try NetworkHistoryStore(directory: directory())
        try await store.setUploadRule(.init(largeBytes: 1_048_576, sustainedSeconds: 5, sustainedBytesPerSecond: 1024))
        try await store.accept(frame(1, at: day + 1, upload: 600_000, name: "Old name"))
        try await store.accept(frame(2, at: day + 2, upload: 600_000, name: "New name")); try await store.flush()
        let query = NetworkHistoryQuery(databaseURL: store.databaseURL)
        let range = HistoryRange(start: .init(timeIntervalSince1970: day), end: .init(timeIntervalSince1970: day + 60))
        let result = try await query.query(range: range)
        XCTAssertEqual(result.applications.count, 1); XCTAssertEqual(result.events.count, 1)
        XCTAssertEqual(result.events[0].bytes, 1_200_000)
        XCTAssertEqual(result.events[0].applicationKey, result.applications[0].identity.key)
        XCTAssertNotEqual(result.events[0].applicationID, result.applications[0].id)
        let export = try NetworkHistoryExport.encode(result)
        let decoded = try XCTUnwrap(JSONSerialization.jsonObject(with: export) as? [String: Any])
        let apps = try XCTUnwrap(decoded["applications"] as? [[String: Any]])
        let events = try XCTUnwrap(decoded["events"] as? [[String: Any]])
        XCTAssertEqual(apps[0]["alias"] as? String, events[0]["application"] as? String)
        XCTAssertFalse(String(decoding: export, as: UTF8.self).contains("Old name"))
        XCTAssertFalse(String(decoding: export, as: UTF8.self).contains("New name"))
        let secondPage = try await query.query(range: range, applicationID: result.applications[0].id, page: 1)
        XCTAssertEqual(secondPage.applications[0].totals.upload, 1_200_000)
        XCTAssertTrue(secondPage.events.isEmpty)
        try await store.close()
    }
}
