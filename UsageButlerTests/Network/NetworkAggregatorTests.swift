import Foundation
import XCTest
@testable import UsageButlerCore
import UsageButlerDomain

final class NetworkAggregatorTests: XCTestCase {
    private let session = CaptureSessionID(rawValue: "s-1")
    private let epoch0 = CounterEpoch(rawValue: 0)
    private let baseWall = Date(timeIntervalSince1970: 1_700_000_000)

    // MARK: - Builders

    private func envelope(_ sequence: UInt64, wallOffset: TimeInterval, monotonicNs: UInt64, session: CaptureSessionID? = nil) -> NetworkEventEnvelope {
        NetworkEventEnvelope(
            sessionID: session ?? self.session,
            sequence: sequence,
            occurredAt: baseWall.addingTimeInterval(wallOffset),
            monotonicOccurredAt: MonotonicInstant(nanoseconds: monotonicNs)
        )
    }

    private func process(_ pid: Int32, startOffset: TimeInterval = 0) -> ProcessIdentity {
        ProcessIdentity(pid: pid, startTime: baseWall.addingTimeInterval(startOffset))
    }

    private func app(_ bundleID: String) -> AppIdentity {
        AppIdentity(bundleID: bundleID, signingIdentity: "sig", teamID: "team")
    }

    private func flow(_ id: String, pid: Int32 = 42, processStart: TimeInterval = 0, appBundleID: String? = "com.example.app") -> FlowIdentity {
        FlowIdentity(
            flowID: FlowID(rawValue: id),
            sessionID: session,
            transport: .tcp,
            addressFamily: .ipv4,
            process: process(pid, startOffset: processStart),
            attribution: appBundleID == nil ? .unknown : .confirmed,
            app: appBundleID.map { app($0) }
        )
    }

    private func counters(_ upload: UInt64?, _ download: UInt64?, epoch: CounterEpoch? = nil, semantics: CounterSemantics = .cumulativeSinceEpoch) -> NetworkByteCounters {
        NetworkByteCounters(
            bytes: DirectionalBytes(upload: upload, download: download),
            semantics: semantics,
            epoch: epoch ?? epoch0
        )
    }

    private func event(_ sequence: UInt64, _ wallOffset: TimeInterval, _ monotonicNs: UInt64, _ payload: NetworkSourcePayload, session: CaptureSessionID? = nil) -> NetworkSourceEvent {
        NetworkSourceEvent(envelope: envelope(sequence, wallOffset: wallOffset, monotonicNs: monotonicNs, session: session), payload: payload)
    }

    private func snapshot(_ aggregator: inout NetworkAggregator, wallOffset: TimeInterval = 100, monotonicNs: UInt64 = 100_000_000_000) -> NetworkSnapshot {
        aggregator.snapshot(
            asOf: baseWall.addingTimeInterval(wallOffset),
            monotonicAsOf: MonotonicInstant(nanoseconds: monotonicNs),
            collectionState: .active
        )
    }

    // MARK: - Sequence integrity

    func testDuplicateAndOutOfOrderEventsAreIdempotent() {
        var aggregator = NetworkAggregator(sessionID: session)
        XCTAssertTrue(aggregator.apply(event(1, 0, 0, .flowStarted(flow("f1")))))
        XCTAssertTrue(aggregator.apply(event(2, 1, 1_000_000_000, .flowCounters(flowID: FlowID(rawValue: "f1"), counters: counters(100, 200), isFinal: false))))
        // Exact replay and an out-of-order older sequence are both dropped.
        XCTAssertFalse(aggregator.apply(event(2, 1, 1_000_000_000, .flowCounters(flowID: FlowID(rawValue: "f1"), counters: counters(100, 200), isFinal: false))))
        // Sequence 1 is older than the applied 2: out of order, not a replay.
        XCTAssertFalse(aggregator.apply(event(1, 0, 0, .flowStarted(flow("f1")))))
        // A later reading settles only the movement it can actually see.
        XCTAssertTrue(aggregator.apply(event(3, 2, 2_000_000_000, .flowCounters(flowID: FlowID(rawValue: "f1"), counters: counters(150, 260), isFinal: false))))

        let app = snapshot(&aggregator).apps["b:com.example.app|s:sig|t:team"]
        XCTAssertEqual(app?.counters.bytes.upload, 50, "settled since the session baseline, not the source counter")
        XCTAssertEqual(app?.counters.bytes.download, 60)
        XCTAssertEqual(aggregator.integrity.duplicates, 1, "exact replay only")
        XCTAssertEqual(aggregator.integrity.outOfOrder, 1, "late events are not counted as replays")
        XCTAssertEqual(aggregator.integrity.lost, 0)
    }

    func testSequenceGapMarksLostEventsAndMakesConnectionCountUnknown() {
        var aggregator = NetworkAggregator(sessionID: session)
        aggregator.apply(event(1, 0, 0, .flowStarted(flow("f1"))))
        aggregator.apply(event(2, 1, 1_000_000_000, .flowCounters(flowID: FlowID(rawValue: "f1"), counters: counters(50, 60), isFinal: false)))
        // Sequence 4 arrives without 3.
        aggregator.apply(event(4, 2, 2_000_000_000, .flowCounters(flowID: FlowID(rawValue: "f1"), counters: counters(80, 90), isFinal: false)))

        let snap = snapshot(&aggregator)
        XCTAssertEqual(snap.coverage.lostEventCount, 1)
        guard case .partial = snap.coverage.bytes else {
            return XCTFail("lost events must degrade byte coverage")
        }
        let app = snap.apps["b:com.example.app|s:sig|t:team"]
        XCTAssertNil(app?.activeConnectionCount, "lost events make the count untrustworthy, not zero")
        // Bytes already observed remain visible; only integrity is degraded.
        XCTAssertEqual(app?.counters.bytes.upload, 30, "80 - the 50 baseline")
    }

    func testForeignSessionEventIsDropped() {
        var aggregator = NetworkAggregator(sessionID: session)
        aggregator.apply(event(1, 0, 0, .flowStarted(flow("f1"))))
        let foreign = CaptureSessionID(rawValue: "s-old")
        XCTAssertFalse(aggregator.apply(event(99, 5, 5_000_000_000, .flowCounters(flowID: FlowID(rawValue: "f1"), counters: counters(9_999, 9_999), isFinal: false), session: foreign)))

        let app = snapshot(&aggregator).apps["b:com.example.app|s:sig|t:team"]
        XCTAssertEqual(app?.counters.bytes.upload, nil)
        XCTAssertEqual(aggregator.integrity.foreignSession, 1)
        XCTAssertEqual(snapshot(&aggregator).appliedSequence, 1)
    }

    // MARK: - Counter semantics

    func testSameEpochCounterDecreaseMarksDirectionUnknown() {
        var aggregator = NetworkAggregator(sessionID: session)
        aggregator.apply(event(1, 0, 0, .flowStarted(flow("f1"))))
        aggregator.apply(event(2, 1, 1_000_000_000, .flowCounters(flowID: FlowID(rawValue: "f1"), counters: counters(500, 700), isFinal: false)))
        // Same epoch, upload decreases: reset without epoch bump.
        aggregator.apply(event(3, 2, 2_000_000_000, .flowCounters(flowID: FlowID(rawValue: "f1"), counters: counters(300, 900), isFinal: false)))

        let snap = snapshot(&aggregator)
        let app = snap.apps["b:com.example.app|s:sig|t:team"]
        XCTAssertNil(app?.counters.bytes.upload, "reset direction is unknown, not a smaller number")
        XCTAssertEqual(app?.counters.bytes.download, 200, "900 - the 700 baseline")
        XCTAssertNil(app?.counters.bytes.total, "total is unknown when one direction is unknown")
        XCTAssertEqual(snap.coverage.counterResetCount, 1)
        guard case .partial(reason: "counter-reset") = snap.coverage.bytes else {
            return XCTFail("counter reset must degrade byte coverage")
        }
    }

    func testNewEpochAdoptsFreshBaseline() {
        var aggregator = NetworkAggregator(sessionID: session)
        aggregator.apply(event(1, 0, 0, .flowStarted(flow("f1"))))
        aggregator.apply(event(2, 1, 1_000_000_000, .flowCounters(flowID: FlowID(rawValue: "f1"), counters: counters(500, 700), isFinal: false)))
        aggregator.apply(event(3, 2, 2_000_000_000, .flowCounters(flowID: FlowID(rawValue: "f1"), counters: counters(10, 20, epoch: CounterEpoch(rawValue: 1)), isFinal: false)))
        // The new epoch starts its own baseline: 15/25 is 5/5 of movement,
        // not 10/20 and not 510/705.
        aggregator.apply(event(4, 3, 3_000_000_000, .flowCounters(flowID: FlowID(rawValue: "f1"), counters: counters(15, 25, epoch: CounterEpoch(rawValue: 1)), isFinal: false)))

        let app = snapshot(&aggregator).apps["b:com.example.app|s:sig|t:team"]
        XCTAssertEqual(app?.counters.bytes.upload, 5)
        XCTAssertEqual(app?.counters.bytes.download, 5)
        XCTAssertEqual(snapshot(&aggregator).coverage.counterResetCount, 0, "epoch bump is a clean baseline, not a reset")
    }

    func testIntervalDeltaAccumulatesWithinEpoch() {
        var aggregator = NetworkAggregator(sessionID: session)
        aggregator.apply(event(1, 0, 0, .flowStarted(flow("f1"))))
        aggregator.apply(event(2, 1, 1_000_000_000, .flowCounters(flowID: FlowID(rawValue: "f1"), counters: counters(30, 40, semantics: .intervalDelta), isFinal: false)))
        aggregator.apply(event(3, 2, 2_000_000_000, .flowCounters(flowID: FlowID(rawValue: "f1"), counters: counters(5, 6, semantics: .intervalDelta), isFinal: false)))

        let app = snapshot(&aggregator).apps["b:com.example.app|s:sig|t:team"]
        XCTAssertEqual(app?.counters.bytes.upload, 35)
        XCTAssertEqual(app?.counters.bytes.download, 46)
    }

    func testRealZeroIsNotUnknown() {
        var aggregator = NetworkAggregator(sessionID: session)
        aggregator.apply(event(1, 0, 0, .flowStarted(flow("f1"))))
        aggregator.apply(event(2, 1, 1_000_000_000, .flowCounters(flowID: FlowID(rawValue: "f1"), counters: counters(0, 0), isFinal: false)))

        let app = snapshot(&aggregator).apps["b:com.example.app|s:sig|t:team"]
        XCTAssertEqual(app?.counters.bytes.upload, 0)
        XCTAssertEqual(app?.counters.bytes.download, 0)
        XCTAssertEqual(app?.counters.bytes.total, 0)
    }

    func testSingleDirectionMissingKeepsOtherDirection() {
        var aggregator = NetworkAggregator(sessionID: session)
        aggregator.apply(event(1, 0, 0, .flowStarted(flow("f1"))))
        aggregator.apply(event(2, 1, 1_000_000_000, .flowCounters(flowID: FlowID(rawValue: "f1"), counters: counters(120, nil), isFinal: false)))

        let app = snapshot(&aggregator).apps["b:com.example.app|s:sig|t:team"]
        XCTAssertEqual(app?.counters.bytes.upload, 0, "observed, nothing settled yet")
        XCTAssertNil(app?.counters.bytes.download)
        XCTAssertNil(app?.counters.bytes.total)
    }

    // MARK: - Flow lifecycle

    func testFinalReportIsIdempotentAndEndsFlow() {
        var aggregator = NetworkAggregator(sessionID: session)
        let f1 = FlowID(rawValue: "f1")
        aggregator.apply(event(1, 0, 0, .flowStarted(flow("f1"))))
        aggregator.apply(event(2, 1, 1_000_000_000, .flowCounters(flowID: f1, counters: counters(100, 100), isFinal: true)))
        // Duplicate final and a later live report are both ignored.
        aggregator.apply(event(3, 2, 2_000_000_000, .flowCounters(flowID: f1, counters: counters(100, 100), isFinal: true)))
        aggregator.apply(event(4, 3, 3_000_000_000, .flowCounters(flowID: f1, counters: counters(9_999, 9_999), isFinal: false)))

        let app = snapshot(&aggregator).apps["b:com.example.app|s:sig|t:team"]
        XCTAssertEqual(app?.counters.bytes.upload, 0, "a single final report is a baseline, not settled traffic")
        XCTAssertEqual(app?.activeConnectionCount, 0, "ended flow is not an active connection")
    }

    func testOrphanedCounterAndEndEventsAreCountedNotFabricated() {
        var aggregator = NetworkAggregator(sessionID: session)
        XCTAssertFalse(aggregator.apply(event(1, 0, 0, .flowCounters(flowID: FlowID(rawValue: "ghost"), counters: counters(1, 1), isFinal: false))))
        XCTAssertFalse(aggregator.apply(event(2, 1, 1_000_000_000, .flowEnded(flowID: FlowID(rawValue: "ghost")))))
        XCTAssertEqual(aggregator.integrity.orphaned, 2)
        XCTAssertTrue(snapshot(&aggregator).apps.isEmpty, "no flow is invented from orphaned events")
    }

    func testEndpointBackfillNeverDuplicatesFlow() {
        var aggregator = NetworkAggregator(sessionID: session)
        aggregator.apply(event(1, 0, 0, .flowStarted(flow("f1"))))
        let endpoint = NetworkEndpoint(host: .ipv4("203.0.113.9"), port: 443)
        aggregator.apply(event(2, 1, 1_000_000_000, .flowTargetResolved(flowID: FlowID(rawValue: "f1"), remoteEndpoint: endpoint, remoteHostname: "example.com", targetSource: .systemProvided)))
        // A second resolution must not overwrite known fields.
        aggregator.apply(event(3, 2, 2_000_000_000, .flowTargetResolved(flowID: FlowID(rawValue: "f1"), remoteEndpoint: NetworkEndpoint(host: .ipv4("198.51.100.7"), port: 443), remoteHostname: "other.example", targetSource: .proxyReported)))
        aggregator.apply(event(4, 3, 3_000_000_000, .flowCounters(flowID: FlowID(rawValue: "f1"), counters: counters(10, 10), isFinal: false)))

        let snap = snapshot(&aggregator)
        let app = snap.apps["b:com.example.app|s:sig|t:team"]
        XCTAssertEqual(app?.activeConnectionCount, 1, "backfill must not create a second flow")
        XCTAssertEqual(app?.counters.bytes.total, 0, "one reading is a baseline")
    }

    // MARK: - Identity

    func testPIDReuseNeverMergesProcesses() {
        var aggregator = NetworkAggregator(sessionID: session)
        let oldFlow = flow("f-old", pid: 42, processStart: 0, appBundleID: nil)
        let newFlow = flow("f-new", pid: 42, processStart: 3_600, appBundleID: nil)
        aggregator.apply(event(1, 0, 0, .flowStarted(oldFlow)))
        aggregator.apply(event(2, 5, 5_000_000_000, .flowCounters(flowID: FlowID(rawValue: "f-old"), counters: counters(100, 100), isFinal: false)))
        aggregator.apply(event(3, 6, 6_000_000_000, .flowCounters(flowID: FlowID(rawValue: "f-old"), counters: counters(107, 108), isFinal: false)))
        aggregator.apply(event(4, 10, 10_000_000_000, .processExited(process(42, startOffset: 0))))
        aggregator.apply(event(5, 11, 11_000_000_000, .flowStarted(newFlow)))
        aggregator.apply(event(6, 12, 12_000_000_000, .flowCounters(flowID: FlowID(rawValue: "f-new"), counters: counters(7, 8), isFinal: false)))
        aggregator.apply(event(7, 13, 13_000_000_000, .flowCounters(flowID: FlowID(rawValue: "f-new"), counters: counters(9, 11), isFinal: false)))

        // Both flows group under `unidentified`. The exit matched by
        // (pid, startTime) ends only the old flow; the 7/8 bytes it settled
        // stay in the app total, and the restarted process contributes only
        // its own 2/3. Dropping the old history would read 2/3, and rebasing
        // the new flow onto the old counter would read something else again.
        let app = snapshot(&aggregator).apps["unidentified"]
        XCTAssertEqual(app?.activeConnectionCount, 1, "exit must not end the restarted process's flow")
        XCTAssertEqual(app?.counters.bytes.upload, 9)
        XCTAssertEqual(app?.counters.bytes.download, 11)
        XCTAssertEqual(app?.counters.semantics, .cumulativeWithinSession)
    }

    func testUnattributableFlowGroupsUnderUnidentified() {
        var aggregator = NetworkAggregator(sessionID: session)
        aggregator.apply(event(1, 0, 0, .flowStarted(flow("f-sys", appBundleID: nil))))
        aggregator.apply(event(2, 1, 1_000_000_000, .flowCounters(flowID: FlowID(rawValue: "f-sys"), counters: counters(3, 4), isFinal: false)))

        let snap = snapshot(&aggregator)
        XCTAssertNotNil(snap.apps["unidentified"])
        XCTAssertNil(snap.apps["b:com.example.app|s:sig|t:team"])
    }

    // MARK: - Rates and clocks

    func testInterfaceRateUsesMonotonicTimeDespiteWallJump() {
        var aggregator = NetworkAggregator(sessionID: session)
        let iface = { (upload: UInt64, download: UInt64, wall: TimeInterval, mono: UInt64) in
            InterfaceCounters(
                name: "en0",
                kind: .physical,
                counters: NetworkByteCounters(
                    bytes: DirectionalBytes(upload: upload, download: download),
                    semantics: .cumulativeSinceEpoch,
                    epoch: self.epoch0
                ),
                asOf: self.baseWall.addingTimeInterval(wall),
                monotonicAsOf: MonotonicInstant(nanoseconds: mono)
            )
        }
        aggregator.apply(event(1, 0, 1_000_000_000, .interfaceCounters(iface(1_000, 2_000, 0, 1_000_000_000))))
        // Wall clock jumps backwards (NTP/sleep) while monotonic advances 2s.
        aggregator.apply(event(2, -3_600, 3_000_000_000, .interfaceCounters(iface(3_000, 6_000, -3_600, 3_000_000_000))))

        let rate = snapshot(&aggregator).interfaceRates["en0"]
        XCTAssertEqual(rate?.uploadBytesPerSecond, 1_000)   // 2000 B / 2 s
        XCTAssertEqual(rate?.downloadBytesPerSecond, 2_000) // 4000 B / 2 s
    }

    func testInterfaceSameEpochDecreaseSanitizesDirection() {
        var aggregator = NetworkAggregator(sessionID: session)
        let iface = { (upload: UInt64?, download: UInt64?, mono: UInt64) in
            InterfaceCounters(
                name: "utun5",
                kind: .tunnel,
                counters: NetworkByteCounters(
                    bytes: DirectionalBytes(upload: upload, download: download),
                    semantics: .cumulativeSinceEpoch,
                    epoch: self.epoch0
                ),
                asOf: self.baseWall,
                monotonicAsOf: MonotonicInstant(nanoseconds: mono)
            )
        }
        aggregator.apply(event(1, 0, 1_000_000_000, .interfaceCounters(iface(500, 500, 1_000_000_000))))
        aggregator.apply(event(2, 1, 2_000_000_000, .interfaceCounters(iface(100, 600, 2_000_000_000))))

        let snap = snapshot(&aggregator)
        let latest = snap.interfaces["utun5"]
        XCTAssertNil(latest?.counters.bytes.upload, "decreased direction becomes unknown")
        XCTAssertEqual(latest?.counters.bytes.download, 600)
        XCTAssertEqual(snap.coverage.counterResetCount, 1)
        XCTAssertNil(snap.interfaceRates["utun5"]?.uploadBytesPerSecond)
    }

    func testAppRateComputedAcrossSnapshots() {
        var aggregator = NetworkAggregator(sessionID: session)
        aggregator.apply(event(1, 0, 0, .flowStarted(flow("f1"))))
        aggregator.apply(event(2, 1, 1_000_000_000, .flowCounters(flowID: FlowID(rawValue: "f1"), counters: counters(1_000, 2_000), isFinal: false)))
        XCTAssertNil(snapshot(&aggregator, wallOffset: 1, monotonicNs: 1_000_000_000).apps["b:com.example.app|s:sig|t:team"]?.rate)

        aggregator.apply(event(3, 2, 2_000_000_000, .flowCounters(flowID: FlowID(rawValue: "f1"), counters: counters(4_000, 8_000), isFinal: false)))
        let rate = snapshot(&aggregator, wallOffset: 2, monotonicNs: 2_000_000_000).apps["b:com.example.app|s:sig|t:team"]?.rate
        XCTAssertEqual(rate?.uploadBytesPerSecond, 3_000)
        XCTAssertEqual(rate?.downloadBytesPerSecond, 6_000)
    }

    // MARK: - Bounds

    func testFlowBoundTruncatesAndSurfacesFlag() {
        var aggregator = NetworkAggregator(sessionID: session, bounds: NetworkAggregationBounds(maxApps: 10, maxFlowsPerApp: 1, maxInterfaces: 10))
        aggregator.apply(event(1, 0, 0, .flowStarted(flow("f1"))))
        aggregator.apply(event(2, 1, 1_000_000_000, .flowStarted(flow("f2"))))

        let snap = snapshot(&aggregator)
        XCTAssertEqual(snap.coverage.truncatedCollections, ["flows.b:com.example.app|s:sig|t:team"])
        XCTAssertEqual(snap.apps["b:com.example.app|s:sig|t:team"]?.activeConnectionCount, 1)
    }
}
