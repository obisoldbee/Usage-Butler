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
        rates: [String: NetworkRate] = [:],
        history: [String: [NetworkRateSample]]? = nil
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
            interfaceRates: rates,
            rateHistory: history
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

    private func storageAddress(_ series: [NetworkRateSample]) -> UInt {
        series.withUnsafeBufferPointer { UInt(bitPattern: $0.baseAddress) }
    }

    @inline(never) private func expiryBuffer() -> NetworkRateHistoryBuffer {
        .init(series: Dictionary(uniqueKeysWithValues: ["en0", "utun5", "lo0"].map { name in
            (name, (1...128).map { tick in
                NetworkRateSample(captureSessionID: session, counterEpoch: .init(rawValue: 7),
                    sampledAt: baseWall.addingTimeInterval(Double(tick)),
                    sampledMonotonic: .init(nanoseconds: UInt64(tick) * 1_000_000_000),
                    uploadBytesPerSecond: 0, downloadBytesPerSecond: nil, interfaceName: name,
                    samplingInterval: 1, uploadContinuityID: "anchor-\(name)")
            })
        }))
    }

    /// Only integer addresses escape; inspection must not create an Array owner
    /// that changes the allocation behavior being tested.
    @inline(never) private func storageAddresses(_ buffer: inout NetworkRateHistoryBuffer) -> [String: UInt] {
        buffer.allSeries.mapValues { storageAddress($0) }
    }

    func testUniqueOwnerTimeExpiryReusesEveryInterfaceStorage() {
        var buffer = expiryBuffer()
        let original = storageAddresses(&buffer)
        for step in 1...8 {
            XCTAssertTrue(buffer.expire(at: .init(nanoseconds: UInt64(7200 + step) * 1_000_000_000 + 250_000_000)))
            XCTAssertEqual(storageAddresses(&buffer), original,
                           "expiring values must not keep a hidden dictionary owner")
            XCTAssertEqual(buffer.count, 3 * (128 - step))
            XCTAssertTrue(buffer.allSeries.values.allSatisfy {
                $0.first?.sampledMonotonic.nanoseconds == UInt64(step + 1) * 1_000_000_000
                    && $0.last?.sampledMonotonic.nanoseconds == 128_000_000_000
            })
        }
    }

    func testTimeExpiryCopiesPublishedStorageOnceThenReusesTheNewStorage() {
        var buffer = expiryBuffer()
        let published = snapshot(publishNs: 128_000_000_000,
            interfaces: ["en0", "utun5", "lo0"], history: buffer.allSeries)
        let shared = storageAddresses(&buffer)
        XCTAssertTrue(buffer.expire(at: .init(nanoseconds: 7201_250_000_000)))
        let detached = storageAddresses(&buffer)
        XCTAssertTrue(shared.keys.allSatisfy { shared[$0] != detached[$0] })
        for step in 2...8 {
            XCTAssertTrue(buffer.expire(at: .init(nanoseconds: UInt64(7200 + step) * 1_000_000_000 + 250_000_000)))
            XCTAssertEqual(storageAddresses(&buffer), detached,
                           "the old immutable snapshot does not own the new source storage")
        }
        XCTAssertEqual(buffer.count, 3 * 120)
        XCTAssertTrue(published.rateHistory!.values.allSatisfy {
            $0.count == 128 && $0.first?.sampledMonotonic.nanoseconds == 1_000_000_000
                && $0.last?.sampledMonotonic.nanoseconds == 128_000_000_000
        })
        withExtendedLifetime(published) {}
    }

    func testExpiryKeepsInclusiveCutoffAndRejectsClockRollbackAtCustomCapacity() {
        let points: [NetworkRateSample] = (7199...7202).map { tick -> NetworkRateSample in
            let upload: Double? = tick == 7201 ? nil : 0
            let anchor: String? = tick == 7201 ? nil : "anchor-\(tick)"
            return NetworkRateSample(captureSessionID: .init(rawValue: "session-\(tick % 2)"),
                counterEpoch: .init(rawValue: UInt64(tick)),
                sampledAt: baseWall.addingTimeInterval(Double(7202 - tick)),
                sampledMonotonic: .init(nanoseconds: UInt64(tick) * 1_000_000_000),
                uploadBytesPerSecond: upload, downloadBytesPerSecond: nil,
                interfaceName: "en0", samplingInterval: 1,
                uploadContinuityID: anchor)
        }
        var buffer = NetworkRateHistoryBuffer(capacity: 3, series: ["en0": points])
        XCTAssertFalse(buffer.expire(at: .init(nanoseconds: 14400_000_000_000)))
        XCTAssertEqual(buffer.series(for: "en0"), Array(points.suffix(3)))
        XCTAssertFalse(buffer.expire(at: .init(nanoseconds: 14399_000_000_000)))
        XCTAssertTrue(buffer.expire(at: .init(nanoseconds: 14401_000_000_000)))
        XCTAssertEqual(buffer.series(for: "en0"), Array(points.suffix(2)),
                       "unknown direction, gap, session, epoch and wall rollback survive trimming")
        XCTAssertEqual(points.count, 4)
    }

    func testSourceOwnedBatchSharesStorageAndLaterWritesKeepSnapshotImmutable() {
        var source = NetworkRateHistoryBuffer()
        for tick in 1...50 {
            let ns = UInt64(tick) * 1_000_000_000
            source.record(snapshot(publishNs: ns, rates: ["en0": rate(10, 1000, sampleNs: ns)]))
        }
        let published = snapshot(publishNs: 50_000_000_000, history: source.allSeries)
        let frozen = published.rateHistory!["en0"]!
        var display = NetworkRateHistoryBuffer()
        display.record(published)
        XCTAssertEqual(storageAddress(display.series(for: "en0")), storageAddress(frozen),
                       "a canonical complete batch must not allocate another full history")
        let restored = NetworkRateHistoryBuffer(series: published.rateHistory!)
        XCTAssertEqual(storageAddress(restored.series(for: "en0")), storageAddress(frozen))

        source.record(snapshot(publishNs: 51_000_000_000, rates: ["en0": rate(20, 2000, sampleNs: 51_000_000_000)]))
        XCTAssertEqual(source.count, 51)
        XCTAssertEqual(frozen.count, 50)
        XCTAssertEqual(published.rateHistory!["en0"], frozen)
        XCTAssertEqual(display.series(for: "en0"), frozen)
        XCTAssertNotEqual(storageAddress(source.series(for: "en0")), storageAddress(frozen))
        display.record(snapshot(publishNs: 51_000_000_000, history: source.allSeries))
        XCTAssertEqual(storageAddress(display.series(for: "en0")), storageAddress(source.series(for: "en0")))
    }

    func testLegacyContinuityRepairKeepsSuppliedAnchorsAndDirectionalGaps() {
        func point(_ tick: Int, upload: Double?, download: Double?, uploadID: String? = nil, downloadID: String? = nil) -> NetworkRateSample {
            .init(captureSessionID: session, counterEpoch: .init(rawValue: 0),
                  sampledAt: baseWall.addingTimeInterval(Double(tick)),
                  sampledMonotonic: .init(nanoseconds: UInt64(tick) * 1_000_000_000),
                  uploadBytesPerSecond: upload, downloadBytesPerSecond: download,
                  interfaceName: "en0", samplingInterval: 1,
                  uploadContinuityID: uploadID, downloadContinuityID: downloadID)
        }
        let legacy = [point(1, upload: 10, download: 0, uploadID: "source-anchor"),
                      point(2, upload: nil, download: 0, uploadID: "invalid-for-unknown"),
                      point(3, upload: 10, download: nil), point(4, upload: 10, download: 20)]
        let repaired = NetworkRateHistoryBuffer.identifyingContinuity(legacy)
        XCTAssertEqual(repaired.map(\.sampleID), legacy.map(\.sampleID))
        XCTAssertEqual(repaired[0].uploadContinuityID, "source-anchor")
        XCTAssertNil(repaired[1].uploadContinuityID)
        XCTAssertEqual(repaired[2].uploadContinuityID, legacy[2].sampleID)
        XCTAssertEqual(repaired[3].uploadContinuityID, repaired[2].uploadContinuityID)
        XCTAssertEqual(repaired[1].downloadContinuityID, legacy[0].sampleID)
        XCTAssertNil(repaired[2].downloadContinuityID)
        XCTAssertEqual(repaired[3].downloadContinuityID, legacy[3].sampleID)
        XCTAssertEqual(legacy[1].uploadContinuityID, "invalid-for-unknown", "repair must not mutate its input")
        let repeated = NetworkRateHistoryBuffer.identifyingContinuity(repaired)
        XCTAssertEqual(storageAddress(repeated), storageAddress(repaired), "a repaired batch must be reusable")
    }

    func testSharedBatchStillEnforcesCapacityAndTimeWithoutMutatingInput() {
        let points = [1, 2, 3, 7199, 7200, 7201].map { tick in
            NetworkRateSample(captureSessionID: session, counterEpoch: .init(rawValue: 0),
                sampledAt: baseWall.addingTimeInterval(Double(tick)),
                sampledMonotonic: .init(nanoseconds: UInt64(tick) * 1_000_000_000),
                uploadBytesPerSecond: 0, downloadBytesPerSecond: nil,
                interfaceName: "en0", samplingInterval: 1, uploadContinuityID: "retained-anchor")
        }
        let published = snapshot(publishNs: 7203_000_000_000, history: ["en0": points])
        var timeBounded = NetworkRateHistoryBuffer()
        timeBounded.record(published)
        XCTAssertEqual(timeBounded.series(for: "en0"), Array(points.suffix(4)), "2 h cutoff remains inclusive")
        var countBounded = NetworkRateHistoryBuffer(capacity: 3)
        countBounded.record(published)
        XCTAssertEqual(countBounded.series(for: "en0"), Array(points.suffix(3)))
        XCTAssertEqual(published.rateHistory!["en0"], points)
        XCTAssertTrue(countBounded.expire(at: .init(nanoseconds: 14402_000_000_000)))
        XCTAssertEqual(countBounded.count, 0)
        XCTAssertEqual(published.rateHistory!["en0"]?.count, 6)
    }
}
