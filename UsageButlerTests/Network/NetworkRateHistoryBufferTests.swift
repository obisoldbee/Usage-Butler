import Foundation
import XCTest
@testable import UsageButlerCore
import UsageButlerDomain

final class NetworkRateHistoryBufferTests: XCTestCase {
    private let baseWall = Date(timeIntervalSince1970: 1_700_000_000)
    private let session = CaptureSessionID(rawValue: "s-1")

    private func seconds(_ ns: UInt64) -> TimeInterval { Double(ns) / 1_000_000_000 }

    /// Builds a snapshot whose *publish* stamp is deliberately independent of
    /// the interface sample stamp, because conflating the two is the bug this
    /// buffer must not reintroduce.
    private func snapshot(
        publishNs: UInt64,
        session: CaptureSessionID? = nil,
        sampleNs: UInt64? = nil,
        epoch: UInt64 = 0,
        interfaces: [String] = ["en0"],
        rates: [String: NetworkRate] = [:]
    ) -> NetworkSnapshot {
        var interfaceEntries: [String: InterfaceCounters] = [:]
        for name in interfaces {
            let stamp = sampleNs ?? publishNs
            interfaceEntries[name] = InterfaceCounters(
                name: name,
                kind: .physical,
                counters: NetworkByteCounters(
                    bytes: DirectionalBytes(upload: 1_000, download: 2_000),
                    semantics: .cumulativeSinceEpoch,
                    epoch: CounterEpoch(rawValue: epoch)
                ),
                asOf: baseWall.addingTimeInterval(seconds(stamp)),
                monotonicAsOf: MonotonicInstant(nanoseconds: stamp)
            )
        }
        return NetworkSnapshot(
            sessionID: session ?? self.session,
            appliedSequence: publishNs,
            asOf: baseWall.addingTimeInterval(seconds(publishNs)),
            monotonicAsOf: MonotonicInstant(nanoseconds: publishNs),
            collectionState: .active,
            coverage: NetworkCoverage(
                identity: .full,
                bytes: .full,
                targets: .full,
                protocols: .full,
                lostEventCount: 0,
                counterResetCount: 0,
                truncatedCollections: [],
                hasLiveSample: true
            ),
            capabilities: .unavailable,
            interfaces: interfaceEntries,
            apps: [:],
            interfaceRates: rates
        )
    }

    private func rate(
        _ upload: Double?,
        _ download: Double?,
        sampleNs: UInt64
    ) -> NetworkRate {
        NetworkRate(
            uploadBytesPerSecond: upload,
            downloadBytesPerSecond: download,
            asOf: baseWall.addingTimeInterval(seconds(sampleNs)),
            window: .seconds(1)
        )
    }

    func testRecordsSamplesPerInterfaceInOrder() {
        var buffer = NetworkRateHistoryBuffer()
        buffer.record(snapshot(publishNs: 1_000_000_000, rates: ["en0": rate(10, 20, sampleNs: 1_000_000_000)]))
        buffer.record(snapshot(publishNs: 2_000_000_000, rates: ["en0": rate(30, 40, sampleNs: 2_000_000_000)]))

        let series = buffer.series(for: "en0")
        XCTAssertEqual(series.count, 2)
        XCTAssertEqual(series[0].uploadBytesPerSecond, 10)
        XCTAssertEqual(series[1].downloadBytesPerSecond, 40)
        XCTAssertEqual(series[1].sampledMonotonic, MonotonicInstant(nanoseconds: 2_000_000_000))
        XCTAssertEqual(buffer.series(for: "utun5"), [])
    }

    /// Republishing an unchanged rate on a later clock tick must not add a
    /// point, or a stalled source still looks like live traffic.
    func testRepublishedRateOnNewerSnapshotAddsNoPoint() {
        var buffer = NetworkRateHistoryBuffer()
        let sampleNs: UInt64 = 5_000_000_000
        buffer.record(snapshot(publishNs: sampleNs, sampleNs: sampleNs, rates: ["en0": rate(10, 10, sampleNs: sampleNs)]))
        buffer.record(snapshot(publishNs: sampleNs + 1_000_000_000, sampleNs: sampleNs, rates: ["en0": rate(10, 10, sampleNs: sampleNs)]))
        buffer.record(snapshot(publishNs: sampleNs + 2_000_000_000, sampleNs: sampleNs, rates: ["en0": rate(10, 10, sampleNs: sampleNs)]))

        let series = buffer.series(for: "en0")
        XCTAssertEqual(series.count, 1)
        XCTAssertEqual(series[0].sampledMonotonic, MonotonicInstant(nanoseconds: sampleNs))
    }

    /// A rate that cannot be traced back to an interface sample has no honest
    /// timestamp or epoch, so it is not buffered at all.
    func testIgnoresRateWithoutMatchingInterfaceSample() {
        var buffer = NetworkRateHistoryBuffer()
        buffer.record(snapshot(publishNs: 1_000_000_000, interfaces: [], rates: ["en0": rate(10, 10, sampleNs: 1_000_000_000)]))
        XCTAssertEqual(buffer.series(for: "en0"), [])
    }

    /// Both directions unknown is a hole in the observation, not "nothing
    /// happened": dropping it lets the chart bridge the gap with a line.
    func testKeepsBothUnknownSampleAsGapMarker() {
        var buffer = NetworkRateHistoryBuffer()
        buffer.record(snapshot(publishNs: 1_000_000_000, rates: ["en0": rate(10, 10, sampleNs: 1_000_000_000)]))
        buffer.record(snapshot(publishNs: 2_000_000_000, rates: ["en0": rate(nil, nil, sampleNs: 2_000_000_000)]))
        buffer.record(snapshot(publishNs: 3_000_000_000, rates: ["en0": rate(50, 50, sampleNs: 3_000_000_000)]))

        let series = buffer.series(for: "en0")
        XCTAssertEqual(series.count, 3)
        XCTAssertTrue(series[1].isGap)
        XCTAssertFalse(series[0].isGap)
        XCTAssertFalse(series[2].isGap)
    }

    func testKeepsNilDirectionDistinctFromZero() {
        var buffer = NetworkRateHistoryBuffer()
        buffer.record(snapshot(publishNs: 1_000_000_000, rates: ["en0": rate(nil, 0, sampleNs: 1_000_000_000)]))
        let series = buffer.series(for: "en0")
        XCTAssertEqual(series.count, 1)
        XCTAssertNil(series[0].uploadBytesPerSecond)
        XCTAssertEqual(series[0].downloadBytesPerSecond, 0)
        XCTAssertFalse(series[0].isGap)
    }

    func testRejectsNonAdvancingSourceStamps() {
        var buffer = NetworkRateHistoryBuffer()
        buffer.record(snapshot(publishNs: 9_000_000_000, sampleNs: 2_000_000_000, rates: ["en0": rate(10, 10, sampleNs: 2_000_000_000)]))
        buffer.record(snapshot(publishNs: 10_000_000_000, sampleNs: 2_000_000_000, rates: ["en0": rate(20, 20, sampleNs: 2_000_000_000)]))
        buffer.record(snapshot(publishNs: 11_000_000_000, sampleNs: 1_000_000_000, rates: ["en0": rate(30, 30, sampleNs: 1_000_000_000)]))

        let series = buffer.series(for: "en0")
        XCTAssertEqual(series.count, 1)
        XCTAssertEqual(series[0].uploadBytesPerSecond, 10)
    }

    /// A new capture session is a different observation run even when the
    /// interface name and clock are continuous.
    func testCarriesSessionAndEpochForSegmentation() {
        var buffer = NetworkRateHistoryBuffer()
        let other = CaptureSessionID(rawValue: "s-2")
        buffer.record(snapshot(publishNs: 1_000_000_000, rates: ["en0": rate(10, 10, sampleNs: 1_000_000_000)]))
        buffer.record(snapshot(publishNs: 2_000_000_000, session: other, epoch: 7, rates: ["en0": rate(20, 20, sampleNs: 2_000_000_000)]))

        let series = buffer.series(for: "en0")
        XCTAssertEqual(series.count, 2)
        XCTAssertEqual(series[0].captureSessionID, CaptureSessionID(rawValue: "s-1"))
        XCTAssertEqual(series[1].captureSessionID, other)
        XCTAssertEqual(series[1].counterEpoch, CounterEpoch(rawValue: 7))
    }

    func testDropsOldestSamplesPastCapacity() {
        var buffer = NetworkRateHistoryBuffer(capacity: 3)
        for index in 1...5 {
            let ns = UInt64(index) * 1_000_000_000
            buffer.record(snapshot(publishNs: ns, rates: ["en0": rate(Double(index), 0, sampleNs: ns)]))
        }
        let series = buffer.series(for: "en0")
        XCTAssertEqual(series.count, 3)
        XCTAssertEqual(series.map(\.uploadBytesPerSecond), [3, 4, 5])
        XCTAssertEqual(buffer.count, 3)
    }

    func testPruneRemovesInterfacesNoLongerObserved() {
        var buffer = NetworkRateHistoryBuffer()
        buffer.record(snapshot(publishNs: 1_000_000_000, interfaces: ["en0", "utun5"], rates: [
            "en0": rate(1, 1, sampleNs: 1_000_000_000),
            "utun5": rate(2, 2, sampleNs: 1_000_000_000)
        ]))
        buffer.prune(keeping: ["en0"])
        XCTAssertEqual(buffer.series(for: "en0").count, 1)
        XCTAssertEqual(buffer.series(for: "utun5"), [])
    }
}
