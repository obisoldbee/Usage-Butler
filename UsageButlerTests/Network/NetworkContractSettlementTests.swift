import Foundation
import XCTest
@testable import UsageButlerCore
import UsageButlerDomain

/// Guards the settlement, coverage-evidence and codec-closure rules that the
/// network contract had inverted. These are the cases where a snapshot could
/// look authoritative while describing something the collector never observed.
final class NetworkContractSettlementTests: XCTestCase {
    private let baseWall = Date(timeIntervalSince1970: 1_700_000_000)
    private let session = CaptureSessionID(rawValue: "s-settle")
    private let epoch0 = CounterEpoch(rawValue: 0)
    private let appKey = "b:com.example.app|s:sig|t:team"

    private func event(
        _ sequence: UInt64,
        _ monotonicNs: UInt64,
        _ payload: NetworkSourcePayload
    ) -> NetworkSourceEvent {
        NetworkSourceEvent(
            envelope: NetworkEventEnvelope(
                sessionID: session,
                sequence: sequence,
                occurredAt: baseWall.addingTimeInterval(Double(monotonicNs) / 1_000_000_000),
                monotonicOccurredAt: MonotonicInstant(nanoseconds: monotonicNs)
            ),
            payload: payload
        )
    }

    private func counters(
        _ upload: UInt64?,
        _ download: UInt64?,
        epoch: CounterEpoch? = nil,
        semantics: CounterSemantics = .cumulativeSinceEpoch
    ) -> NetworkByteCounters {
        NetworkByteCounters(
            bytes: DirectionalBytes(upload: upload, download: download),
            semantics: semantics,
            epoch: epoch ?? epoch0
        )
    }

    private func flow(_ id: String) -> FlowIdentity {
        FlowIdentity(
            flowID: FlowID(rawValue: id),
            sessionID: session,
            transport: .tcp,
            addressFamily: .ipv4,
            process: ProcessIdentity(pid: 42, startTime: baseWall),
            attribution: .confirmed,
            app: AppIdentity(bundleID: "com.example.app", signingIdentity: "sig", teamID: "team")
        )
    }

    private func interfaceSample(
        _ name: String,
        upload: UInt64?,
        download: UInt64?,
        monotonicNs: UInt64,
        epoch: CounterEpoch = CounterEpoch(rawValue: 0)
    ) -> InterfaceCounters {
        InterfaceCounters(
            name: name,
            kind: .physical,
            counters: NetworkByteCounters(
                bytes: DirectionalBytes(upload: upload, download: download),
                semantics: .cumulativeSinceEpoch,
                epoch: epoch
            ),
            asOf: baseWall.addingTimeInterval(Double(monotonicNs) / 1_000_000_000),
            monotonicAsOf: MonotonicInstant(nanoseconds: monotonicNs)
        )
    }

    @discardableResult
    private func snapshot(
        _ aggregator: inout NetworkAggregator,
        monotonicNs: UInt64 = 100_000_000_000
    ) -> NetworkSnapshot {
        aggregator.snapshot(
            asOf: baseWall.addingTimeInterval(Double(monotonicNs) / 1_000_000_000),
            monotonicAsOf: MonotonicInstant(nanoseconds: monotonicNs),
            collectionState: .active
        )
    }

    // MARK: - Session settlement

    /// The product question is "what has this app moved since collection
    /// started", so a flow discovered mid-life must contribute only what the
    /// collector watches it move from then on.
    func testAppTotalSettlesFromSessionBaselineNotSourceCounter() {
        var aggregator = NetworkAggregator(sessionID: session)
        aggregator.apply(event(1, 0, .flowStarted(flow("f1"))))
        aggregator.apply(event(2, 1_000_000_000, .flowCounters(
            flowID: FlowID(rawValue: "f1"), counters: counters(9_000_000, 8_000_000), isFinal: false
        )))

        let baseline = snapshot(&aggregator).apps[appKey]
        XCTAssertEqual(baseline?.counters.bytes.upload, 0, "first reading is a baseline, not traffic")
        XCTAssertEqual(baseline?.counters.bytes.download, 0)

        aggregator.apply(event(3, 2_000_000_000, .flowCounters(
            flowID: FlowID(rawValue: "f1"), counters: counters(9_004_000, 8_000_250), isFinal: false
        )))
        let moved = snapshot(&aggregator).apps[appKey]
        XCTAssertEqual(moved?.counters.bytes.upload, 4_000)
        XCTAssertEqual(moved?.counters.bytes.download, 250)
        XCTAssertEqual(moved?.counters.semantics, .cumulativeWithinSession)
        XCTAssertEqual(moved?.counters.epoch, aggregator.sessionSettlementEpoch)
    }

    /// Summing flows that each belong to a different source epoch is legitimate
    /// only because every contribution is a delta settled inside this session.
    func testDifferingFlowEpochsSettleWithoutForcingUnknown() {
        var aggregator = NetworkAggregator(sessionID: session)
        aggregator.apply(event(1, 0, .flowStarted(flow("f1"))))
        aggregator.apply(event(2, 1_000_000_000, .flowCounters(
            flowID: FlowID(rawValue: "f1"), counters: counters(100, 100, epoch: CounterEpoch(rawValue: 3)), isFinal: false
        )))
        aggregator.apply(event(3, 2_000_000_000, .flowCounters(
            flowID: FlowID(rawValue: "f1"), counters: counters(160, 100, epoch: CounterEpoch(rawValue: 3)), isFinal: false
        )))
        aggregator.apply(event(4, 3_000_000_000, .flowStarted(flow("f2"))))
        aggregator.apply(event(5, 4_000_000_000, .flowCounters(
            flowID: FlowID(rawValue: "f2"), counters: counters(500, 500, epoch: CounterEpoch(rawValue: 9)), isFinal: false
        )))
        aggregator.apply(event(6, 5_000_000_000, .flowCounters(
            flowID: FlowID(rawValue: "f2"), counters: counters(505, 520, epoch: CounterEpoch(rawValue: 9)), isFinal: false
        )))

        let app = snapshot(&aggregator).apps[appKey]
        XCTAssertEqual(app?.counters.bytes.upload, 65, "60 from one epoch plus 5 from another, both session-settled")
        XCTAssertEqual(app?.counters.bytes.download, 20)
        XCTAssertEqual(app?.counters.semantics, .cumulativeWithinSession)
    }

    func testIntervalDeltaSourceSettlesEveryReading() {
        var aggregator = NetworkAggregator(sessionID: session)
        aggregator.apply(event(1, 0, .flowStarted(flow("f1"))))
        aggregator.apply(event(2, 1_000_000_000, .flowCounters(
            flowID: FlowID(rawValue: "f1"), counters: counters(30, 40, semantics: .intervalDelta), isFinal: false
        )))
        aggregator.apply(event(3, 2_000_000_000, .flowCounters(
            flowID: FlowID(rawValue: "f1"), counters: counters(5, 0, semantics: .intervalDelta), isFinal: false
        )))

        let app = snapshot(&aggregator).apps[appKey]
        XCTAssertEqual(app?.counters.bytes.upload, 35, "interval deltas are already movement")
        XCTAssertEqual(app?.counters.bytes.download, 40)
    }

    // MARK: - Coverage must follow evidence

    /// No flow events means no per-app, per-target or per-protocol knowledge.
    /// Claiming `.full` there is what let an unwired caller look online.
    func testCoverageDimensionsRequireFlowEvidence() {
        var interfacesOnly = NetworkAggregator(sessionID: session)
        interfacesOnly.apply(event(1, 1_000_000_000, .interfaceCounters(
            interfaceSample("en0", upload: 10, download: 20, monotonicNs: 1_000_000_000)
        )))
        let quiet = snapshot(&interfacesOnly, monotonicNs: 2_000_000_000)
        for level in [quiet.coverage.identity, quiet.coverage.targets, quiet.coverage.protocols] {
            guard case .unavailable = level else {
                return XCTFail("dimensions need evidence, got \(level)")
            }
        }
        XCTAssertTrue(quiet.coverage.hasLiveSample, "an interface sample is a live sample")

        var withFlows = NetworkAggregator(sessionID: session)
        withFlows.apply(event(1, 0, .flowStarted(flow("f1"))))
        let loud = snapshot(&withFlows)
        XCTAssertEqual(loud.coverage.identity, .full)
    }

    /// A late event is dropped, but calling it a replay hides that bytes were
    /// never settled, so it must degrade byte coverage under its own reason.
    func testOutOfOrderDropsDegradeByteCoverage() {
        var aggregator = NetworkAggregator(sessionID: session)
        aggregator.apply(event(1, 0, .flowStarted(flow("f1"))))
        aggregator.apply(event(5, 5_000_000_000, .flowCounters(
            flowID: FlowID(rawValue: "f1"), counters: counters(10, 10), isFinal: false
        )))
        XCTAssertFalse(aggregator.apply(event(3, 3_000_000_000, .flowCounters(
            flowID: FlowID(rawValue: "f1"), counters: counters(999, 999), isFinal: false
        ))))

        XCTAssertEqual(aggregator.integrity.outOfOrder, 1)
        XCTAssertEqual(aggregator.integrity.duplicates, 0)
        guard case .partial(reason: "out-of-order-events") = snapshot(&aggregator).coverage.bytes else {
            return XCTFail("out-of-order drops must be visible in coverage")
        }
    }

    func testExactReplayDoesNotDegradeCoverage() {
        var aggregator = NetworkAggregator(sessionID: session)
        let payload = NetworkSourcePayload.flowCounters(
            flowID: FlowID(rawValue: "f1"), counters: counters(10, 10), isFinal: false
        )
        aggregator.apply(event(1, 0, .flowStarted(flow("f1"))))
        aggregator.apply(event(2, 1_000_000_000, payload))
        XCTAssertFalse(aggregator.apply(event(2, 1_000_000_000, payload)))

        let coverage = snapshot(&aggregator).coverage
        XCTAssertEqual(aggregator.integrity.duplicates, 1)
        XCTAssertEqual(aggregator.integrity.outOfOrder, 0)
        guard case .full = coverage.bytes else {
            return XCTFail("a pure replay settles nothing new and must not look like loss")
        }
    }

    // MARK: - Codec closure

    /// The aggregator and the codec must not disagree: every snapshot shape the
    /// aggregator can emit has to survive encode → decode. A republished
    /// snapshot on the same monotonic tick used to produce a zero-window rate
    /// that the decoder then refused.
    func testEveryAggregatorSnapshotRoundTripsThroughCodec() throws {
        var aggregator = NetworkAggregator(sessionID: session)
        aggregator.apply(event(1, 0, .flowStarted(flow("f1"))))
        aggregator.apply(event(2, 1_000_000_000, .interfaceCounters(
            interfaceSample("en0", upload: 1_000, download: 2_000, monotonicNs: 1_000_000_000)
        )))
        aggregator.apply(event(3, 2_000_000_000, .flowCounters(
            flowID: FlowID(rawValue: "f1"), counters: counters(10, 20), isFinal: false
        )))

        // Same tick twice, then advancing ticks: the shapes that used to break.
        for monotonicNs: UInt64 in [2_000_000_000, 2_000_000_000, 3_000_000_000, 3_000_000_000, 4_000_000_000] {
            let snapshot = self.snapshot(&aggregator, monotonicNs: monotonicNs)
            let data = try NetworkSnapshotJSONCodec.encode(snapshot)
            let decoded = try NetworkSnapshotJSONCodec.decode(data)
            XCTAssertEqual(decoded.sessionID, snapshot.sessionID)
            XCTAssertEqual(decoded.interfaceRates.keys, snapshot.interfaceRates.keys,
                           "rates must not appear or vanish across the wire")
            for (name, rate) in decoded.interfaceRates {
                XCTAssertNotEqual(rate.window, .zero, "\(name) carried a zero window")
            }
        }
    }

    /// Counters above the JavaScript safe-integer range must keep exact
    /// integer value across the wire, because rule decisions read them.
    func testLargeSessionSettledTotalsSurviveTheCodec() throws {
        var aggregator = NetworkAggregator(sessionID: session)
        aggregator.apply(event(1, 0, .flowStarted(flow("f1"))))
        let start: UInt64 = 9_007_199_254_740_993   // 2^53 + 1
        aggregator.apply(event(2, 1_000_000_000, .flowCounters(
            flowID: FlowID(rawValue: "f1"), counters: counters(start, start), isFinal: false
        )))
        aggregator.apply(event(3, 2_000_000_000, .flowCounters(
            flowID: FlowID(rawValue: "f1"), counters: counters(start &+ 5_000, start), isFinal: false
        )))

        let snapshot = self.snapshot(&aggregator)
        XCTAssertEqual(snapshot.apps[appKey]?.counters.bytes.upload, 5_000)
        let decoded = try NetworkSnapshotJSONCodec.decode(NetworkSnapshotJSONCodec.encode(snapshot))
        XCTAssertEqual(decoded.apps[appKey]?.counters.bytes.upload, 5_000)
        XCTAssertEqual(decoded.apps[appKey]?.counters.semantics, .cumulativeWithinSession)
    }
}
