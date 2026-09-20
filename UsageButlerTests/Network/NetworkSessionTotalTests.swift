import Foundation
import XCTest
@testable import UsageButlerCore
import UsageButlerDomain

/// PRD §13.5: the interface summary leads with "本次监测累计" — bytes this
/// capture session can account for — and never with the source's boot total,
/// whose start point cannot be verified and whose 32-bit width can wrap.
final class NetworkSessionTotalTests: XCTestCase {
    private let session = CaptureSessionID(rawValue: "s-1")
    private let baseWall = Date(timeIntervalSince1970: 1_700_000_000)

    private func iface(
        _ upload: UInt64?,
        _ download: UInt64?,
        monotonicNs: UInt64,
        epoch: UInt64 = 1_700_000_000,
        wallOffset: TimeInterval = 0
    ) -> InterfaceCounters {
        InterfaceCounters(
            name: "en0",
            kind: .physical,
            counters: NetworkByteCounters(
                bytes: DirectionalBytes(upload: upload, download: download),
                semantics: .cumulativeSinceEpoch,
                epoch: CounterEpoch(rawValue: epoch)
            ),
            asOf: baseWall.addingTimeInterval(wallOffset),
            monotonicAsOf: MonotonicInstant(nanoseconds: monotonicNs)
        )
    }

    private func event(_ sequence: UInt64, _ payload: InterfaceCounters) -> NetworkSourceEvent {
        NetworkSourceEvent(
            envelope: NetworkEventEnvelope(
                sessionID: session,
                sequence: sequence,
                occurredAt: payload.asOf,
                monotonicOccurredAt: payload.monotonicAsOf
            ),
            payload: .interfaceCounters(payload)
        )
    }

    private func total(of input: NetworkAggregator) -> SessionByteTotal? {
        // Emitting a snapshot is mutating (it advances rate baselines), so it
        // runs against a copy: these assertions are about settled bytes only.
        var aggregator = input
        return aggregator.snapshot(
            asOf: baseWall.addingTimeInterval(10),
            monotonicAsOf: MonotonicInstant(nanoseconds: 10_000_000_000),
            collectionState: .active
        ).interfaces["en0"]?.sessionTotal
    }

    func testFirstReadingIsABaselineNotATrafficFigure() {
        var aggregator = NetworkAggregator(sessionID: session)
        aggregator.apply(event(1, iface(8_000_000_000, 40_000_000_000, monotonicNs: 1_000_000_000)))
        let observed = total(of: aggregator)
        XCTAssertNotNil(observed, "the interface has a span, it just has no bytes in it yet")
        XCTAssertNil(observed?.bytes.upload)
        XCTAssertNil(observed?.bytes.download)
    }

    func testTotalIsTheDeltaNotTheBootCounter() {
        var aggregator = NetworkAggregator(sessionID: session)
        aggregator.apply(event(1, iface(8_000_000_000, 40_000_000_000, monotonicNs: 1_000_000_000)))
        aggregator.apply(event(2, iface(8_000_005_000, 40_000_007_000, monotonicNs: 2_000_000_000)))
        let observed = total(of: aggregator)
        XCTAssertEqual(observed?.bytes.upload, 5_000)
        XCTAssertEqual(observed?.bytes.download, 7_000)
        XCTAssertEqual(observed?.since, baseWall, "the span is measured from the baseline")
        XCTAssertTrue(observed?.isContinuous ?? false)
    }

    func testZeroDeltaIsAKnownZero() {
        var aggregator = NetworkAggregator(sessionID: session)
        aggregator.apply(event(1, iface(1_000, 2_000, monotonicNs: 1_000_000_000)))
        aggregator.apply(event(2, iface(1_000, 2_000, monotonicNs: 2_000_000_000)))
        let observed = total(of: aggregator)
        XCTAssertEqual(observed?.bytes.upload, 0)
        XCTAssertEqual(observed?.bytes.download, 0)
    }

    func testResetRestartsTheSegmentAndSaysSo() {
        var aggregator = NetworkAggregator(sessionID: session)
        aggregator.apply(event(1, iface(1_000, 1_000, monotonicNs: 1_000_000_000)))
        aggregator.apply(event(2, iface(6_000, 1_000, monotonicNs: 2_000_000_000)))
        // A same-epoch drop: wrap or reset, and the reading alone cannot tell.
        aggregator.apply(event(3, iface(200, 1_000, monotonicNs: 3_000_000_000, wallOffset: 3)))
        var observed = total(of: aggregator)
        XCTAssertEqual(observed?.bytes.upload, 0, "the surviving segment has settled nothing yet")
        XCTAssertEqual(observed?.bytes.download, 0)
        XCTAssertFalse(observed?.isContinuous ?? true)
        XCTAssertEqual(observed?.breakReason, "counter-reset")
        XCTAssertEqual(observed?.since, baseWall.addingTimeInterval(3), "the new span starts at the reset")

        aggregator.apply(event(4, iface(700, 1_000, monotonicNs: 4_000_000_000)))
        observed = total(of: aggregator)
        XCTAssertEqual(observed?.bytes.upload, 500, "later deltas accumulate into the new segment")
        XCTAssertEqual(observed?.bytes.download, 0)
    }

    func testDirectionsBreakSeparately() {
        var aggregator = NetworkAggregator(sessionID: session)
        aggregator.apply(event(1, iface(1_000, 1_000, monotonicNs: 1_000_000_000)))
        aggregator.apply(event(2, iface(6_000, 9_000, monotonicNs: 2_000_000_000)))
        aggregator.apply(event(3, iface(6_000, 100, monotonicNs: 3_000_000_000)))
        let observed = total(of: aggregator)
        XCTAssertEqual(observed?.bytes.upload, 5_000, "upload never dropped; its bytes are still accounted for")
        XCTAssertEqual(observed?.bytes.download, 0)
    }

    func testNewEpochReBaselinesWithoutDiscardingSettledBytes() {
        var aggregator = NetworkAggregator(sessionID: session)
        aggregator.apply(event(1, iface(1_000, 1_000, monotonicNs: 1_000_000_000)))
        aggregator.apply(event(2, iface(4_000, 1_000, monotonicNs: 2_000_000_000)))
        aggregator.apply(event(3, iface(500, 500, monotonicNs: 3_000_000_000, epoch: 1_800_000_000)))
        let observed = total(of: aggregator)
        XCTAssertEqual(observed?.bytes.upload, 3_000, "settled bytes were earned inside this session")
        XCTAssertTrue(observed?.isContinuous ?? false, "an epoch bump is a new baseline, not a gap")
        aggregator.apply(event(4, iface(1_500, 500, monotonicNs: 4_000_000_000, epoch: 1_800_000_000)))
        XCTAssertEqual(total(of: aggregator)?.bytes.upload, 4_000)
    }

    func testMissingDirectionStaysUnknownRatherThanZero() {
        var aggregator = NetworkAggregator(sessionID: session)
        aggregator.apply(event(1, iface(1_000, nil, monotonicNs: 1_000_000_000)))
        aggregator.apply(event(2, iface(3_000, nil, monotonicNs: 2_000_000_000)))
        let observed = total(of: aggregator)
        XCTAssertEqual(observed?.bytes.upload, 2_000)
        XCTAssertNil(observed?.bytes.download)
    }

    func testSessionTotalSurvivesTheCodecRoundTrip() throws {
        var aggregator = NetworkAggregator(sessionID: session)
        aggregator.apply(event(1, iface(8_000_000_000, 40_000_000_000, monotonicNs: 1_000_000_000)))
        aggregator.apply(event(2, iface(8_000_123_456, 40_000_000_000, monotonicNs: 2_000_000_000)))
        let snapshot = aggregator.snapshot(
            asOf: baseWall.addingTimeInterval(2),
            monotonicAsOf: MonotonicInstant(nanoseconds: 2_000_000_000),
            collectionState: .active
        )
        let decoded = try NetworkSnapshotJSONCodec.decode(
            NetworkSnapshotJSONCodec.encode(snapshot)
        )
        XCTAssertEqual(decoded, snapshot)
        XCTAssertEqual(
            decoded.interfaces["en0"]?.sessionTotal?.bytes.upload,
            123_456
        )
    }
}
