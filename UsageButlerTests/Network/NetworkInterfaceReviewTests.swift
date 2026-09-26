import Foundation
import XCTest
@testable import UsageButlerCore
import UsageButlerDomain
import UsageButlerInfrastructure

final class NetworkInterfaceReviewTests: XCTestCase {
    let session = CaptureSessionID(rawValue: "interface-review")
    func sample(_ t: UInt64, bytes: UInt64, cadence: Double, name: String = "en-test") -> InterfaceCounters {
        .init(name: name, kind: .physical, counters: .init(bytes: .init(upload: bytes, download: bytes),
            semantics: .cumulativeSinceEpoch, epoch: .init(rawValue: 1)),
            asOf: Date(timeIntervalSince1970: Double(t)), monotonicAsOf: .init(nanoseconds: t * 1_000_000_000),
            samplingInterval: cadence)
    }
    func event(_ seq: UInt64, _ sample: InterfaceCounters) -> NetworkSourceEvent {
        .init(envelope: .init(sessionID: session, sequence: seq, occurredAt: sample.asOf,
            monotonicOccurredAt: sample.monotonicAsOf), payload: .interfaceEnumeration(.complete([sample])))
    }
    func testCadenceTransitionMatchesChartAndLongGapBreaksRateAndTotals() {
        var a = NetworkAggregator(sessionID: session)
        a.apply(event(1, sample(1, bytes: 100, cadence: 5)))
        a.apply(event(2, sample(6, bytes: 600, cadence: 1)))
        var snapshot = a.snapshot(asOf: Date(), monotonicAsOf: .init(nanoseconds: 6_000_000_000), collectionState: .active)
        XCTAssertEqual(snapshot.interfaces["en-test"]?.sessionTotal?.upload.bytes, 500)
        XCTAssertEqual(snapshot.interfaceRates["en-test"]?.uploadBytesPerSecond, 100)
        let history = snapshot.rateHistory!["en-test"]!
        XCTAssertEqual(NetworkChartSamplingContract().threshold(between: history[0], and: history[1]), 12.5)
        a.apply(event(3, sample(20, bytes: 90_000, cadence: 1)))
        snapshot = a.snapshot(asOf: Date(), monotonicAsOf: .init(nanoseconds: 20_000_000_000), collectionState: .active)
        XCTAssertNil(snapshot.interfaces["en-test"]?.sessionTotal?.upload.bytes)
        XCTAssertNil(snapshot.interfaceRates["en-test"]?.uploadBytesPerSecond)
        XCTAssertEqual(snapshot.interfaces["en-test"]?.sessionTotal?.upload.breakReason, "sampling-gap")
    }
    func testDroppedEventSequenceIsVisibleAndNeverBridgesCounters() {
        var a = NetworkAggregator(sessionID: session)
        a.apply(event(1, sample(1, bytes: 100, cadence: 1)))
        a.apply(event(4, sample(2, bytes: 800_000, cadence: 1)))
        let snapshot = a.snapshot(asOf: Date(), monotonicAsOf: .init(nanoseconds: 2_000_000_000), collectionState: .active)
        XCTAssertEqual(snapshot.coverage.lostEventCount, 2)
        XCTAssertNil(snapshot.interfaces["en-test"]?.sessionTotal?.upload.bytes)
        XCTAssertNil(snapshot.interfaceRates["en-test"])
    }
    func testAllInterfacesOldSessionsAndIdleHistoryExpire() {
        var buffer = NetworkRateHistoryBuffer()
        buffer.record(source: sample(1, bytes: 10, cadence: 1, name: "old-missing"), rate: nil, session: session)
        buffer.record(source: sample(2, bytes: 10, cadence: 1, name: "current"), rate: nil, session: .init(rawValue: "second"))
        XCTAssertTrue(buffer.expire(at: .init(nanoseconds: 7_203_000_000_000)))
        XCTAssertEqual(buffer.count, 0)
        buffer.record(source: sample(8_000, bytes: 20, cadence: 1), rate: nil, session: session)
        XCTAssertFalse(buffer.expire(at: .init(nanoseconds: 1)), "rollback cannot expire an unknown monotonic domain")
        XCTAssertEqual(buffer.count, 1)
    }
    private struct Reader: InterfaceCountersReading {
        func read() -> Result<[RawInterfaceCounters], InterfaceCountersReadFailure> { .success([]) }
    }
    func testSlowSourceConsumerHasEightFramesAndVisibleSequenceLoss() async {
        let clock = TestClock(wallTime: Date(), monotonicNanoseconds: 0)
        let source = GetifaddrsNetworkSource(clock: clock, reader: Reader(), sessionID: session)
        let stream = source.events()
        for t in 1...20 {
            await clock.waitUntilSleepIsRegistered(until: .init(nanoseconds: UInt64(t) * 1_000_000_000))
            await clock.advance(to: UInt64(t) * 1_000_000_000)
        }
        await clock.waitUntilSleepIsRegistered(until: .init(nanoseconds: 21_000_000_000))
        var iterator = stream.makeAsyncIterator()
        let first = await iterator.next()
        XCTAssertEqual(first?.envelope.sequence, 15, "22 produced events retain only newest 8")
        var a = NetworkAggregator(sessionID: session)
        if let first { a.apply(first) }
        XCTAssertEqual(a.integrity.lost, 14)
        // Cancelling a consumer completes the stream and cancels the sampler.
        let drain = Task { for await _ in stream {} }
        drain.cancel(); await drain.value
    }
}
