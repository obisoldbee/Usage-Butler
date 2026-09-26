import Darwin
import Foundation
import XCTest
@testable import UsageButlerCore
import UsageButlerDomain
@testable import UsageButlerInfrastructure
@testable import UsageButlerUI

final class ProcessNetworkTests: XCTestCase {
    let session = CaptureSessionID(rawValue: "test-process-session")
    func row(_ pid: Int32 = 10, id: String? = "10:1", app: String = "app",
             up: UInt64? = 100, down: UInt64? = 200) -> ProcessNetworkCounter {
        .init(identity: .init(pid: pid, instanceID: id, name: "Synthetic process", executablePath: "/synthetic/tool",
            application: .init(key: app, name: app, evidence: .executable)), bytes: .init(upload: up, download: down))
    }
    func frame(_ sequence: UInt64, _ rows: [ProcessNetworkCounter], complete: Bool = true,
               time: UInt64? = nil, session: CaptureSessionID? = nil, cadence: TimeInterval = 1) -> ProcessNetworkFrame {
        let t = time ?? sequence * 1_000_000_000
        return .init(envelope: .init(sessionID: session ?? self.session, sequence: sequence,
            occurredAt: Date(timeIntervalSince1970: 1_700_000_000 + Double(t) / 1e9),
            monotonicOccurredAt: .init(nanoseconds: t)), processes: rows, complete: complete, samplingInterval: cadence)
    }
    func testParserEveryByteSplitUTF8QuotedNamesAndHeaderOrder() {
        let data = Data(",bytes_out,bytes_in,\r\n\"Synthetic,进程.12\",18446744073709551615,42,\r\n,bytes_out,bytes_in,\n".utf8)
        let expected: [NettopCSVRecord] = [.header, .process(pid: 12, name: "Synthetic,进程", download: 42, upload: UInt64.max), .header]
        for split in 0...data.count {
            var p = NettopCSVParser()
            XCTAssertEqual(p.feed(data.prefix(split)) + p.feed(data.suffix(data.count - split)), expected)
            XCTAssertTrue(p.finish())
        }
    }
    func testParserUnknownDirectionAndMalformedNumbers() {
        var p = NettopCSVParser()
        XCTAssertEqual(p.feed(Data(",bytes_in,bytes_out,\nx.1,,0,\n".utf8)),
                       [.header, .process(pid: 1, name: "x", download: nil, upload: 0)])
        for number in ["-1", "1.0", "1e5", "18446744073709551616", "NaN", " 1"] {
            XCTAssertEqual(p.feed(Data("x.1,\(number),2,\n".utf8)), [.invalid])
        }
    }
    func testParserOversizedLineRecoversAndEOFDoesNotComplete() {
        var p = NettopCSVParser()
        _ = p.feed(Data(repeating: 65, count: 50_000))
        XCTAssertLessThanOrEqual(p.bufferedBytes, NettopCSVParser.maximumLineBytes)
        XCTAssertEqual(p.feed(Data("\n,bytes_in,bytes_out,\n".utf8)), [.invalid, .header])
        _ = p.feed(Data("partial".utf8)); XCTAssertFalse(p.finish())
    }
    func testParserMissingHeaderDuplicateFieldsBadQuotesAndInvalidUTF8() {
        var p = NettopCSVParser()
        for line in ["x.1,1,2,", ",bytes_in,bytes_in,", "\"broken.1,1,2,", "x.noPID,1,2,"] {
            XCTAssertEqual(p.feed(Data((line + "\n").utf8)), [.invalid])
        }
        XCTAssertEqual(p.feed(Data([0xff, 10])), [.invalid])
    }
    func testRatesUseSourceTimeAndRepeatedSnapshotsDoNotSettle() {
        var a = ProcessNetworkAggregator(sessionID: session)
        a.apply(frame(1, [row()]))
        XCTAssertNil(a.snapshot().applications["app"]?.total.upload.bytes)
        a.apply(frame(2, [row(up: 300, down: 200)], time: 3_000_000_000))
        let value = a.snapshot()
        XCTAssertEqual(value.applications["app"]?.rate?.uploadBytesPerSecond, 100)
        XCTAssertEqual(value.applications["app"]?.rate?.downloadBytesPerSecond, 0)
        XCTAssertEqual(value.applications["app"]?.total.upload.bytes, 200)
        for _ in 0..<100 { XCTAssertEqual(a.snapshot(), value) }
    }
    func testReplayOutOfOrderAndForeignSessionRejected() {
        var a = ProcessNetworkAggregator(sessionID: session)
        XCTAssertTrue(a.apply(frame(2, [row()])))
        XCTAssertFalse(a.apply(frame(2, [row(up: 500)])))
        XCTAssertFalse(a.apply(frame(1, [row()])))
        XCTAssertFalse(a.apply(frame(3, [row()], time: 1)))
        XCTAssertFalse(a.apply(frame(3, [row()], session: .init(rawValue: "foreign"))))
        XCTAssertEqual(a.snapshot().historyPointCount, 1)
    }
    func testPIDReuseAndExecutableIdentityChangeRebaseline() {
        var a = ProcessNetworkAggregator(sessionID: session)
        a.apply(frame(1, [row()]))
        a.apply(frame(2, [row(id: "10:2", up: 1_000_000)]))
        XCTAssertNil(a.snapshot().applications["app"]?.rate?.uploadBytesPerSecond)
        a.apply(frame(3, [row(id: "10:2", up: 1_000_010)]))
        XCTAssertEqual(a.snapshot().applications["app"]?.total.upload.bytes, 10)
    }
    func testNewMemberAndMissingMemberCannotCreateSpike() {
        var a = ProcessNetworkAggregator(sessionID: session)
        a.apply(frame(1, [row()]))
        a.apply(frame(2, [row(up: 120), row(11, id: "11:1", up: 999_999)]))
        XCTAssertNil(a.snapshot().applications["app"]?.rate?.uploadBytesPerSecond)
        a.apply(frame(3, [row(up: 130), row(11, id: "11:1", up: 1_000_009)]))
        XCTAssertEqual(a.snapshot().applications["app"]?.rate?.uploadBytesPerSecond, 20)
        a.apply(frame(4, [row(up: 140)]))
        XCTAssertNil(a.snapshot().applications["app"]?.rate?.uploadBytesPerSecond)
    }
    func testUnknownStartIdentityNeverAccumulates() {
        var a = ProcessNetworkAggregator(sessionID: session)
        for i in 1...4 { a.apply(frame(UInt64(i), [row(id: nil, up: UInt64(i) * 100)])) }
        XCTAssertNil(a.snapshot().applications["app"]?.total.upload.bytes)
        XCTAssertNil(a.snapshot().applications["app"]?.rate?.uploadBytesPerSecond)
    }
    func testAbsentApplicationHistoryDoesNotRetainUnboundedProcessInventories() {
        var a = ProcessNetworkAggregator(sessionID: session, budget: .init(processes: 32, applications: 64))
        for tick in 1...64 {
            let rows = (0..<32).map { row(Int32($0 + 1), id: "\(tick):\($0)", app: "app-\(tick)") }
            a.apply(frame(UInt64(tick), rows))
            let snapshot = a.snapshot()
            XCTAssertLessThanOrEqual(snapshot.applications.values.reduce(0) { $0 + $1.processes.count }, 32)
            XCTAssertEqual(snapshot.applications.count, tick)
            XCTAssertEqual(snapshot.historyPointCount, tick)
        }
    }
    func testDirectionResetAndRecoveryAreIndependent() {
        var a = ProcessNetworkAggregator(sessionID: session)
        a.apply(frame(1, [row()]))
        a.apply(frame(2, [row(up: 150, down: 1)]))
        XCTAssertEqual(a.snapshot().applications["app"]?.total.upload.bytes, 50)
        XCTAssertNil(a.snapshot().applications["app"]?.total.download.bytes)
        a.apply(frame(3, [row(up: 200, down: 5)]))
        XCTAssertEqual(a.snapshot().applications["app"]?.total.upload.bytes, 100)
        XCTAssertEqual(a.snapshot().applications["app"]?.total.download.bytes, 4)
        a.apply(frame(4, [row(up: nil, down: 8)]))
        XCTAssertNil(a.snapshot().applications["app"]?.total.upload.bytes)
        XCTAssertEqual(a.snapshot().applications["app"]?.total.download.bytes, 7)
        a.apply(frame(5, [row(up: 10_000, down: 9)]))
        XCTAssertNil(a.snapshot().applications["app"]?.rate?.uploadBytesPerSecond)
        a.apply(frame(6, [row(up: 10_001, down: 10)]))
        XCTAssertEqual(a.snapshot().applications["app"]?.total.upload.bytes, 1)
    }
    func testIncompleteAndRecoveryDoNotBridgeGapOrAssertMissing() {
        var a = ProcessNetworkAggregator(sessionID: session)
        a.apply(frame(1, [row()]))
        a.apply(frame(2, [], complete: false))
        XCTAssertEqual(a.snapshot().applications["app"]?.presence, .unknown)
        a.apply(frame(3, [row(up: 10_000)]))
        XCTAssertNil(a.snapshot().applications["app"]?.rate?.uploadBytesPerSecond)
        a.apply(frame(4, []))
        XCTAssertEqual(a.snapshot().applications["app"]?.presence, .missing)
        a.mark(.stopped)
        XCTAssertEqual(a.snapshot().applications["app"]?.presence, .notObserved)
    }
    func testSequenceAndTimeGapsRebaseline() {
        var a = ProcessNetworkAggregator(sessionID: session)
        a.apply(frame(1, [row()]))
        a.apply(frame(3, [row(up: 900)]))
        XCTAssertNil(a.snapshot().applications["app"]?.rate?.uploadBytesPerSecond)
        XCTAssertEqual(a.snapshot().lostFrames, 1)
        a.apply(frame(4, [row(up: 999)], time: 30_000_000_000))
        XCTAssertNil(a.snapshot().applications["app"]?.total.upload.bytes)
    }
    func testCheckedLostFramesNearUInt64MaxDoesNotTrap() {
        var a = ProcessNetworkAggregator(sessionID: session)
        a.apply(frame(1, [row()], time: 1))
        a.apply(frame(UInt64.max - 1, [row()], time: 2))
        XCTAssertEqual(a.snapshot().lostFrames, UInt64.max - 3)
    }
    func testDirectionalSumOverflowRemainsUnknown() {
        var a = ProcessNetworkAggregator(sessionID: session)
        a.apply(frame(1, [row(up: 0), row(11, id: "11:1", up: 0)]))
        a.apply(frame(2, [row(up: UInt64.max), row(11, id: "11:1", up: 1)]))
        XCTAssertNil(a.snapshot().applications["app"]?.rate?.uploadBytesPerSecond)
        XCTAssertEqual(a.snapshot().applications["app"]?.rate?.downloadBytesPerSecond, 0)
    }
    func testDuplicatePIDInvalidatesCompleteFrame() {
        var a = ProcessNetworkAggregator(sessionID: session)
        a.apply(frame(1, [row(), row(id: "different")]))
        XCTAssertEqual(a.snapshot().state, .partial)
        XCTAssertEqual(a.snapshot().issue, "duplicate-process")
    }
    func testGlobalHistoryAndAppBudgetsWithChurn() {
        var a = ProcessNetworkAggregator(sessionID: session, budget: .init(processes: 16, applications: 8, historyPerApplication: 7_200, totalHistory: 64))
        for t in 1...1_000 {
            a.apply(frame(UInt64(t), (0..<12).map { i in row(Int32(i), id: "\(i):\(t / 50)", app: "a\((i + t / 50) % 24)", up: UInt64(t)) }))
            XCTAssertLessThanOrEqual(a.snapshot().applications.count, 8)
            XCTAssertLessThanOrEqual(a.snapshot().historyPointCount, 64)
        }
        XCTAssertTrue(a.snapshot().truncated)
    }
    func testTwoHourRetentionUsesSourceMonotonicTime() {
        var a = ProcessNetworkAggregator(sessionID: session)
        a.apply(frame(1, [row()], time: 1))
        a.apply(frame(2, [row()], time: 7_201_000_000_000))
        XCTAssertEqual(a.snapshot().historyPointCount, 1)
    }
    func testFreshnessIgnoresWallClockAndRejectsFutureMonotonic() throws {
        var a = ProcessNetworkAggregator(sessionID: session)
        a.apply(frame(1, [row()])); a.apply(frame(2, [row(up: 110)]))
        let app = try XCTUnwrap(a.snapshot().applications["app"])
        XCTAssertTrue(ProcessNetworkFreshness.isFresh(app, state: .active, now: .init(nanoseconds: 3_000_000_000)))
        XCTAssertFalse(ProcessNetworkFreshness.isFresh(app, state: .active, now: .init(nanoseconds: 1)))
        XCTAssertFalse(ProcessNetworkFreshness.isFresh(app, state: .active, now: .init(nanoseconds: 14_000_000_001)))
        XCTAssertFalse(ProcessNetworkFreshness.isFresh(app, state: .stopped, now: .init(nanoseconds: 3_000_000_000)))
        let data = try ProcessNetworkExport.encode(snapshot: a.snapshot(), keys: ["app"],
            now: Date(timeIntervalSince1970: 0), window: 60, includeHistory: false,
            monotonicNow: .init(nanoseconds: 3_000_000_000))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let apps = try XCTUnwrap(object["applications"] as? [[String: Any]])
        XCTAssertEqual(apps[0]["uploadBytesPerSecond"] as? Double, 10)
    }
    func testRestartRetainsHistoryButNeverSettlesAcrossSessions() throws {
        var old = ProcessNetworkAggregator(sessionID: session)
        old.apply(frame(1, [row()])); old.apply(frame(2, [row(up: 120)]))
        let next = CaptureSessionID(rawValue: "restarted")
        var fresh = ProcessNetworkAggregator(sessionID: next, retained: old.snapshot())
        XCTAssertEqual(fresh.snapshot().historyPointCount, 2)
        XCTAssertEqual(fresh.snapshot().applications["app"]?.presence, .unknown)
        fresh.apply(frame(1, [row(up: 900_000)], time: 3_000_000_000, session: next))
        XCTAssertNil(fresh.snapshot().applications["app"]?.rate?.uploadBytesPerSecond)
        fresh.apply(frame(2, [row(up: 900_005)], time: 4_000_000_000, session: next))
        XCTAssertEqual(fresh.snapshot().applications["app"]?.total.upload.bytes, 5)
        XCTAssertEqual(fresh.snapshot().historyPointCount, 4)
    }
    @MainActor func testUnknownPIDCannotCarryWatchOrHistoryToNextFrame() {
        var a = ProcessNetworkAggregator(sessionID: session)
        a.apply(frame(1, [row(id: nil)]))
        let first = a.snapshot().applications.keys.first!
        let model = ProcessNetworkViewModel(); model.apply(a.snapshot()); model.toggleWatch(first)
        XCTAssertTrue(model.watched.isEmpty)
        a.apply(frame(2, [row(id: nil, up: 999)]))
        XCTAssertNil(a.snapshot().applications[first])
        XCTAssertEqual(a.snapshot().applications.count, 1)
        XCTAssertEqual(a.snapshot().historyPointCount, 1)
    }
    func testIdentityCurrentProcessUsesVerifiedStartAndPath() {
        var resolver = SystemProcessNetworkIdentity()
        let identity = resolver.resolve(pid: getpid(), name: "test", frameStartedAt: Date())
        XCTAssertNotNil(identity.instanceID)
        XCTAssertNotNil(identity.executablePath)
        XCTAssertNil(identity.application.signingIdentity)
        XCTAssertNil(resolver.resolve(pid: Int32.max, name: "absent", frameStartedAt: Date()).instanceID)
    }
    func testBundleContainmentDifferentInstallationsAndBoundedCache() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var resolver = SystemProcessNetworkIdentity()
        var identities: [ProcessNetworkApplicationIdentity] = []
        for index in 0..<2 {
            let app = root.appendingPathComponent("copy\(index)/Synthetic.app")
            let mac = app.appendingPathComponent("Contents/MacOS")
            try FileManager.default.createDirectory(at: mac, withIntermediateDirectories: true)
            let exe = mac.appendingPathComponent("Synthetic")
            try Data("#!/bin/false".utf8).write(to: exe)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: exe.path)
            let info = ["CFBundleIdentifier": "test.synthetic", "CFBundleExecutable": "Synthetic", "CFBundleName": "Synthetic"]
            try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: app.appendingPathComponent("Contents/Info.plist"))
            let identity = resolver.application(for: exe.path, fallback: "Synthetic")
            identities.append(identity)
            XCTAssertEqual(identity.evidence, .executableBundle)
            let helper = resolver.application(for: app.path + "/Contents/Frameworks/Helper.app/Contents/MacOS/Helper", fallback: "Helper")
            XCTAssertEqual(helper.key, identity.key); XCTAssertEqual(helper.evidence, .nestedBundle)
        }
        XCTAssertNotEqual(identities[0].key, identities[1].key)
        XCTAssertEqual(resolver.application(for: "/System/Library/Frameworks/WebKit.framework/XPCServices/Synthetic", fallback: "Shared helper").evidence, .executable)
        for n in 0..<1_000 { _ = resolver.application(for: "/synthetic/\(n)", fallback: "tool") }
        XCTAssertLessThanOrEqual(resolver.cachedIdentityCount, SystemProcessNetworkIdentity.cacheLimit)
    }
    func testExportUsesWhitelistNullsExactIntegersAndFixedSnapshot() throws {
        var a = ProcessNetworkAggregator(sessionID: session)
        a.apply(frame(1, [row(up: 0)])); a.apply(frame(2, [row(up: UInt64.max)]))
        let snapshot = a.snapshot()
        let data = try ProcessNetworkExport.encode(snapshot: snapshot, keys: ["app"], now: snapshot.sampledAt!, window: 60, includeHistory: true)
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(text.contains(String(UInt64.max)))
        XCTAssertFalse(text.contains("/synthetic")); XCTAssertFalse(text.contains("Synthetic process"))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let apps = try XCTUnwrap(object["applications"] as? [[String: Any]])
        XCTAssertTrue(apps[0]["connectionCount"] is NSNull)
        XCTAssertEqual(object["version"] as? Int, 1)
        a.apply(frame(3, []))
        XCTAssertEqual(data, try ProcessNetworkExport.encode(snapshot: snapshot, keys: ["app"], now: snapshot.sampledAt!, window: 60, includeHistory: true))
    }
    func testExportRetainedSessionsNamespaceRepeatedContinuityAndPreserveCadence() throws {
        let privateKey = "synthetic-executable-path-hash"
        var old = ProcessNetworkAggregator(sessionID: session)
        old.apply(frame(1, [row(app: privateKey)]))
        old.apply(frame(2, [row(app: privateKey, up: 120)]))
        let next = CaptureSessionID(rawValue: "synthetic-restarted-session")
        var fresh = ProcessNetworkAggregator(sessionID: next, retained: old.snapshot())
        fresh.apply(frame(1, [row(app: privateKey, up: 900)], time: 4_000_000_000, session: next, cadence: 2))
        fresh.apply(frame(2, [row(app: privateKey, up: 940)], time: 6_000_000_000, session: next, cadence: 2))
        let snapshot = fresh.snapshot()
        let data = try ProcessNetworkExport.encode(snapshot: snapshot, keys: [privateKey], now: snapshot.sampledAt!, window: 60, includeHistory: true)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let apps = try XCTUnwrap(object["applications"] as? [[String: Any]])
        let points = try XCTUnwrap(apps.first?["history"] as? [[String: Any]])
        XCTAssertEqual(points.count, 4)
        XCTAssertEqual(points[1]["uploadContinuity"] as? String, points[3]["uploadContinuity"] as? String)
        let oldSession = try XCTUnwrap(points[1]["session"] as? String)
        let newSession = try XCTUnwrap(points[3]["session"] as? String)
        XCTAssertNotEqual(oldSession, newSession)
        XCTAssertEqual(newSession, object["session"] as? String)
        XCTAssertEqual(points[1]["samplingIntervalSeconds"] as? Double, 1)
        XCTAssertEqual(points[3]["samplingIntervalSeconds"] as? Double, 2)
        XCTAssertEqual(apps[0]["application"] as? String, "application-1")
        let text = String(decoding: data, as: UTF8.self)
        for excluded in [privateKey, session.rawValue, next.rawValue, "/synthetic", "Synthetic process", "10:1"] {
            XCTAssertFalse(text.contains(excluded), "export must not include \(excluded)")
        }
    }
    @MainActor func testUIStateSearchSortWatchAndBackRetainsIdentity() {
        var a = ProcessNetworkAggregator(sessionID: session)
        a.apply(frame(1, [row(app: "Z"), row(11, id: "11", app: "A")]))
        let model = ProcessNetworkViewModel()
        model.apply(a.snapshot()); model.search = "A"; model.sort = .name
        XCTAssertEqual(model.rows.map(\.identity.key), ["A"])
        model.open("A"); model.toggleWatch("A"); model.onlyWatched = true; model.back()
        XCTAssertNil(model.selected); XCTAssertEqual(model.returnAnchor, "A"); XCTAssertEqual(model.search, "A")
        XCTAssertEqual(model.rows.count, 1)
        model.toggleWatch("A"); XCTAssertEqual(model.rows.count, 0)
    }
}
