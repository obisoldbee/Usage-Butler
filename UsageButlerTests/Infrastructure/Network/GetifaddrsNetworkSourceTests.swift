import Foundation
import XCTest
@testable import UsageButlerCore
@testable import UsageButlerDomain
@testable import UsageButlerInfrastructure

final class GetifaddrsNetworkSourceTests: XCTestCase {
    private let baseWall = Date(timeIntervalSince1970: 1_700_000_000)

    private final class FakeCountersReader: InterfaceCountersReading, @unchecked Sendable {
        private let lock = NSLock()
        private var batches: [[RawInterfaceCounters]]

        init(batches: [[RawInterfaceCounters]]) {
            self.batches = batches
        }

        func read() -> Result<[RawInterfaceCounters], InterfaceCountersReadFailure> {
            lock.lock()
            defer { lock.unlock() }
            if batches.count > 1 {
                return .success(batches.removeFirst())
            }
            return .success(batches.first ?? [])
        }
    }

    private actor EventLog {
        private var events: [NetworkSourceEvent] = []
        private var waiters: [UUID: (count: Int, continuation: CheckedContinuation<Void, Never>)] = [:]

        func append(_ event: NetworkSourceEvent) {
            events.append(event)
            let ready = waiters.filter { $0.value.count <= events.count }
            for (id, waiter) in ready {
                waiters.removeValue(forKey: id)
                waiter.continuation.resume()
            }
        }

        func waitForCount(_ count: Int) async {
            if events.count >= count { return }
            await withCheckedContinuation { continuation in
                waiters[UUID()] = (count, continuation)
            }
        }

        func all() -> [NetworkSourceEvent] { events }
    }

    func testStreamsHeartbeatThenAtomicCompleteEnumerationPerTick() async {
        let clock = TestClock(wallTime: baseWall, monotonicNanoseconds: 0)
        let reader = FakeCountersReader(batches: [
            [
                RawInterfaceCounters(name: "en0", kind: .physical, uploadBytes: 100, downloadBytes: 200),
                RawInterfaceCounters(name: "utun5", kind: .tunnel, uploadBytes: 50, downloadBytes: 60)
            ],
            [
                RawInterfaceCounters(name: "en0", kind: .physical, uploadBytes: 300, downloadBytes: 500)
            ]
        ])
        let sessionID = CaptureSessionID(rawValue: "test-session")
        let source = GetifaddrsNetworkSource(
            clock: clock,
            reader: reader,
            sessionID: sessionID,
            epoch: CounterEpoch(rawValue: 7)
        )

        let log = EventLog()
        let drain = Task {
            for await event in source.events() {
                await log.append(event)
            }
        }
        defer { drain.cancel() }

        await log.waitForCount(2)
        var events = await log.all()

        // First event is the heartbeat carrying the honest capabilities.
        guard case let .heartbeat(capabilities) = events[0].payload else {
            return XCTFail("expected a heartbeat first, got \(events[0].payload)")
        }
        XCTAssertTrue(capabilities.observe)
        XCTAssertFalse(capabilities.blockNewConnections)
        XCTAssertEqual(events[0].envelope.sequence, 1)
        XCTAssertEqual(events[0].envelope.sessionID, sessionID)

        guard case let .interfaceEnumeration(.complete(first)) = events[1].payload, let en0 = first.first else {
            return XCTFail("expected interface counters, got \(events[1].payload)")
        }
        XCTAssertEqual(en0.name, "en0")
        XCTAssertEqual(en0.kind, .physical)
        XCTAssertEqual(en0.counters.bytes.upload, 100)
        XCTAssertEqual(en0.counters.bytes.download, 200)
        XCTAssertEqual(en0.counters.semantics, .cumulativeSinceEpoch)
        XCTAssertEqual(en0.counters.epoch, CounterEpoch(rawValue: 7))
        XCTAssertEqual(events[1].envelope.sequence, 2)

        guard let utun5 = first.last else {
            return XCTFail("expected interface counters, got \(events[1].payload)")
        }
        XCTAssertEqual(utun5.name, "utun5")
        XCTAssertEqual(utun5.kind, .tunnel)
        XCTAssertEqual(first.count, 2)

        // The next tick reads the next batch; the sequence keeps climbing.
        await clock.waitUntilSleepIsRegistered(until: .init(nanoseconds: 1_000_000_000))
        await clock.advance(to: 1_000_000_000)
        await log.waitForCount(3)
        events = await log.all()
        guard case let .interfaceEnumeration(.complete(second)) = events[2].payload, let nextEn0 = second.first else {
            return XCTFail("expected interface counters, got \(events[2].payload)")
        }
        XCTAssertEqual(nextEn0.counters.bytes.upload, 300)
        XCTAssertEqual(events[2].envelope.sequence, 3)
        XCTAssertEqual(second.count, 1)
    }

    func testCancellingTheConsumerStopsTheStream() async {
        let clock = TestClock(wallTime: baseWall, monotonicNanoseconds: 0)
        let reader = FakeCountersReader(batches: [
            [RawInterfaceCounters(name: "en0", kind: .physical, uploadBytes: 1, downloadBytes: 2)]
        ])
        let source = GetifaddrsNetworkSource(
            clock: clock,
            reader: reader,
            sessionID: CaptureSessionID(rawValue: "cancel-session"),
            epoch: CounterEpoch(rawValue: 1)
        )

        let log = EventLog()
        let drain = Task {
            for await event in source.events() {
                await log.append(event)
            }
        }
        await log.waitForCount(2) // heartbeat + first counter batch
        drain.cancel()
        _ = await drain.value

        await clock.advance(to: 5_000_000_000)
        // No further events after cancellation: the inner sampling task was
        // cancelled via the stream's termination handler.
        try? await Task.sleep(for: .milliseconds(50))
        let events = await log.all()
        XCTAssertEqual(events.count, 2)
    }

    private struct OutcomeReader: InterfaceCountersReading {
        let outcome: Result<[RawInterfaceCounters], InterfaceCountersReadFailure>
        func read() -> Result<[RawInterfaceCounters], InterfaceCountersReadFailure> { outcome }
    }

    func testReaderFailureAndSuccessfulEmptyRemainDifferentSourceEvents() async {
        for outcome in [Result<[RawInterfaceCounters], InterfaceCountersReadFailure>.success([]), .failure(.unavailable)] {
            let source = GetifaddrsNetworkSource(clock: TestClock(), reader: OutcomeReader(outcome: outcome),
                sessionID: .init(rawValue: "empty-vs-failure"), epoch: .init(rawValue: 1))
            var iterator = source.events().makeAsyncIterator()
            _ = await iterator.next()
            let event = await iterator.next()
            switch outcome {
            case .success: XCTAssertEqual(event?.payload, .interfaceEnumeration(.complete([])))
            case .failure: XCTAssertEqual(event?.payload, .interfaceEnumeration(.failed))
            }
            XCTAssertEqual(event?.envelope.sequence, 2)
        }
    }

    func testBootEpochReadsSystemBootTime() {
        // Smoke: on any booted macOS system kern.boottime is a positive epoch.
        XCTAssertGreaterThan(GetifaddrsNetworkSource.bootEpoch(), 0)
    }
}

final class GetifaddrsInterfaceCountersReaderTests: XCTestCase {
    func testClassifyMapsNamePrefixesToKinds() {
        XCTAssertEqual(GetifaddrsInterfaceCountersReader.classify(name: "lo0"), .loopback)
        XCTAssertEqual(GetifaddrsInterfaceCountersReader.classify(name: "en0"), .physical)
        XCTAssertEqual(GetifaddrsInterfaceCountersReader.classify(name: "en1"), .physical)
        XCTAssertEqual(GetifaddrsInterfaceCountersReader.classify(name: "utun5"), .tunnel)
        XCTAssertEqual(GetifaddrsInterfaceCountersReader.classify(name: "ipsec0"), .tunnel)
        XCTAssertEqual(GetifaddrsInterfaceCountersReader.classify(name: "gif0"), .tunnel)
        XCTAssertEqual(GetifaddrsInterfaceCountersReader.classify(name: "stf0"), .tunnel)
        XCTAssertEqual(GetifaddrsInterfaceCountersReader.classify(name: "ppp0"), .tunnel)
        XCTAssertEqual(GetifaddrsInterfaceCountersReader.classify(name: "bridge0"), .bridge)
        XCTAssertEqual(GetifaddrsInterfaceCountersReader.classify(name: "awdl0"), .other)
        XCTAssertEqual(GetifaddrsInterfaceCountersReader.classify(name: "llw0"), .other)
        XCTAssertEqual(GetifaddrsInterfaceCountersReader.classify(name: ""), .other)
    }

    func testLiveReadReturnsSortedNonEmptyInterfaces() throws {
        // Smoke against the real interface MIB: every booted Mac has loopback.
        let interfaces = try GetifaddrsInterfaceCountersReader().read().get()
        XCTAssertFalse(interfaces.isEmpty)
        XCTAssertEqual(interfaces.map(\.name), interfaces.map(\.name).sorted())
        XCTAssertTrue(interfaces.allSatisfy { !$0.name.isEmpty })
        XCTAssertEqual(
            interfaces.first { $0.name == "lo0" }?.kind,
            .loopback
        )
    }
}
