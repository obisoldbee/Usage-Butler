import Foundation
import XCTest
@testable import UsageButlerCore
import UsageButlerDomain
@testable import UsageButlerUI

final class NetworkV2ContractTests: XCTestCase {
    private func sample(_ t: Double, cadence: Double = 1, session: String = "s", epoch: UInt64 = 1, upload: Double? = 10, download: Double? = 1_000) -> NetworkRateSample {
        .init(captureSessionID: .init(rawValue: session), counterEpoch: .init(rawValue: epoch),
              sampledAt: Date(timeIntervalSince1970: t), sampledMonotonic: .init(nanoseconds: UInt64(t * 1e9)),
              uploadBytesPerSecond: upload, downloadBytesPerSecond: download, interfaceName: "en0", samplingInterval: cadence)
    }
    private func source(_ t: UInt64, upload: UInt64?, download: UInt64?, epoch: UInt64 = 1) -> InterfaceCounters {
        .init(name: "en0", kind: .physical,
              counters: .init(bytes: .init(upload: upload, download: download), semantics: .cumulativeSinceEpoch, epoch: .init(rawValue: epoch)),
              asOf: Date(timeIntervalSince1970: Double(t)), monotonicAsOf: .init(nanoseconds: t * 1_000_000_000), samplingInterval: 1)
    }
    private func snapshot(_ sources: [InterfaceCounters]) -> NetworkSnapshot {
        let session = CaptureSessionID(rawValue: "s")
        var aggregator = NetworkAggregator(sessionID: session)
        for (i, source) in sources.enumerated() {
            aggregator.apply(.init(envelope: .init(sessionID: session, sequence: UInt64(i + 1), occurredAt: source.asOf,
                monotonicOccurredAt: source.monotonicAsOf), payload: .interfaceCounters(source)))
        }
        return aggregator.snapshot(asOf: sources.last!.asOf, monotonicAsOf: sources.last!.monotonicAsOf, collectionState: .active)
    }
    func testAxesExpandImmediatelyAndShrinkOnlyAfterEightMonotonicSeconds() {
        var axis = NetworkChartAxis()
        axis.update(peak: 100, monotonicNow: 0)
        XCTAssertEqual(axis.upperBound, 200)
        axis.update(peak: 10, monotonicNow: 1)
        axis.update(peak: 10, monotonicNow: 8.9)
        XCTAssertEqual(axis.upperBound, 200)
        axis.update(peak: 10, monotonicNow: 9)
        XCTAssertEqual(axis.upperBound, 20)
        axis.update(peak: 900, monotonicNow: 9.1)
        XCTAssertGreaterThanOrEqual(axis.upperBound, 900 * 1.12)
    }
    func testSmallAndZeroAxesDoNotCollapse() {
        XCTAssertGreaterThan(NetworkChartAxis.ceiling(for: 0), 0)
        XCTAssertGreaterThan(NetworkChartAxis.ceiling(for: 0.0001), 0.0001)
        XCTAssertLessThan(NetworkChartAxis.ceiling(for: 10), NetworkChartAxis.ceiling(for: 1_000))
    }
    func testThreeSecondGapStillBreaksOneSecondSourceAndTwentySecondGapBreaksFiveSecondSource() {
        for (cadence, times) in [(1.0, [1.0, 2, 5, 6]), (5.0, [5.0, 10, 30, 35])] {
            let projection = NetworkChartProjector.project(times.map { sample($0, cadence: cadence) }, interface: "en0", now: Date(timeIntervalSince1970: 40), window: 100, contract: .init())
            XCTAssertEqual(projection.segmentCount, 4)
        }
    }
    func testCursorInsideGapIsUnknownAndKnownZeroIsPreserved() {
        let samples = [sample(1, upload: 0), sample(2), sample(20)]
        XCTAssertNil(NetworkChartInspection.sample(at: Date(timeIntervalSince1970: 10), in: samples))
        XCTAssertEqual(NetworkChartInspection.sample(at: Date(timeIntervalSince1970: 1), in: samples)?.uploadBytesPerSecond, 0)
    }
    func testSourceHistoryRetainsIntermediatePeakAcrossSparsePublication() throws {
        let sources = (1...6).map { source(UInt64($0), upload: $0 >= 3 ? 10_000 : 0, download: UInt64($0) * 50) }
        let result = snapshot(sources)
        XCTAssertEqual(result.rateHistory?["en0"]?.count, 6)
        XCTAssertEqual(result.rateHistory?["en0"]?.compactMap(\.uploadBytesPerSecond).max(), 10_000)
        var display = NetworkRateHistoryBuffer()
        for _ in 0..<5 { display.record(result) }
        XCTAssertEqual(display.series(for: "en0").count, 6)
        XCTAssertEqual(try NetworkSnapshotJSONCodec.decode(NetworkSnapshotJSONCodec.encode(result)), result)
    }
    func testDirectionResetKeepsSeparateStartsAndRequiresAnotherSample() {
        let result = snapshot([source(1, upload: 1_000, download: 1_000), source(2, upload: 6_000, download: 9_000), source(3, upload: 6_000, download: 100), source(4, upload: 6_500, download: 600)])
        let total = result.interfaces["en0"]!.sessionTotal!
        XCTAssertEqual(total.upload.bytes, 5_500)
        XCTAssertEqual(total.upload.since, Date(timeIntervalSince1970: 1))
        XCTAssertEqual(total.download.bytes, 500)
        XCTAssertEqual(total.download.since, Date(timeIntervalSince1970: 3))
        XCTAssertNil(total.since)
    }
    func testMissingCounterRecoveryDoesNotBridgeUnknownInterval() {
        let result = snapshot([source(1, upload: 100, download: 100), source(2, upload: nil, download: 200), source(3, upload: 1_000, download: 300), source(4, upload: 1_100, download: 400)])
        XCTAssertEqual(result.interfaces["en0"]?.sessionTotal?.upload.bytes, 100)
        XCTAssertEqual(result.interfaces["en0"]?.sessionTotal?.upload.since, Date(timeIntervalSince1970: 3))
        XCTAssertEqual(result.interfaces["en0"]?.sessionTotal?.download.bytes, 300)
    }
    func testNewSessionWithRewoundMonotonicTimeIsNotDropped() {
        var history = NetworkRateHistoryBuffer()
        history.record(source: source(100, upload: 1, download: 1), rate: .init(uploadBytesPerSecond: 10, downloadBytesPerSecond: 20, asOf: Date(timeIntervalSince1970: 100), window: .seconds(1)), session: .init(rawValue: "old"))
        history.record(source: source(1, upload: 1, download: 1), rate: .init(uploadBytesPerSecond: 10, downloadBytesPerSecond: 20, asOf: Date(timeIntervalSince1970: 1), window: .seconds(1)), session: .init(rawValue: "new"))
        XCTAssertEqual(history.series(for: "en0").count, 2)
    }
    func testDirectionalSumOverflowIsUnknown() {
        XCTAssertNil(DirectionalBytes(upload: .max, download: 1).total)
    }
    func testSmallerIntervalDeltaIsNotMistakenForCounterReset() {
        let inputs = [100, 10, 20].enumerated().map { index, bytes in
            InterfaceCounters(name: "en0", kind: .physical,
                counters: .init(bytes: .init(upload: UInt64(bytes), download: UInt64(bytes)), semantics: .intervalDelta, epoch: .init(rawValue: 1)),
                asOf: Date(timeIntervalSince1970: Double(index + 1)), monotonicAsOf: .init(nanoseconds: UInt64(index + 1) * 1_000_000_000), samplingInterval: 1)
        }
        XCTAssertEqual(snapshot(inputs).interfaces["en0"]?.sessionTotal?.upload.bytes, 30)
        XCTAssertNil(snapshot(inputs).interfaces["en0"]?.sessionTotal?.upload.breakReason)
    }
    func testOversizeEncodeFailsExplicitlyRatherThanCreatingUnreadableExport() {
        let value = snapshot([source(1, upload: 100, download: 100)])
        XCTAssertThrowsError(try NetworkSnapshotJSONCodec.encode(value, sizeLimit: 10))
    }
    func testVersionOneBrokenTotalDoesNotInventDirectionStart() throws {
        let current = snapshot([source(1, upload: 100, download: 100), source(2, upload: 200, download: 200)])
        var wire = try XCTUnwrap(JSONSerialization.jsonObject(with: NetworkSnapshotJSONCodec.encode(current)) as? [String: Any])
        wire["version"] = 1; wire.removeValue(forKey: "rateHistory")
        var interfaces = wire["interfaces"] as! [String: [String: Any]]
        interfaces["en0"]!["sessionTotal"] = ["upload": "9007199254740993", "download": "500", "since": "1970-01-01T00:00:02.000Z", "sinceMonotonicAsOf": "2000000000", "breakReason": "counter-reset"]
        wire["interfaces"] = interfaces
        let total = try NetworkSnapshotJSONCodec.decode(JSONSerialization.data(withJSONObject: wire)).interfaces["en0"]?.sessionTotal
        XCTAssertEqual(total?.upload.bytes, 9_007_199_254_740_993)
        XCTAssertNil(total?.upload.since); XCTAssertNil(total?.download.since)
        XCTAssertEqual(total?.upload.breakReason, "legacy-unverified")
    }
    func testSelectedStaleInterfaceCannotBorrowAnotherInterfacesFreshness() {
        let result = snapshot([source(1, upload: 100, download: 100), source(2, upload: 200, download: 200)])
        XCTAssertTrue(NetworkStatusRules.ratesAreStale(result, interface: "missing", now: Date(timeIntervalSince1970: 2)))
        XCTAssertTrue(NetworkStatusRules.ratesAreStale(result, interface: "en0", now: Date(timeIntervalSince1970: 30)))
        XCTAssertTrue(NetworkStatusRules.currentHealth(result.applyingCoverageProfile(.interfaceCountersOnly), interface: "en0", now: Date(timeIntervalSince1970: 2)).healthy)
    }
}
