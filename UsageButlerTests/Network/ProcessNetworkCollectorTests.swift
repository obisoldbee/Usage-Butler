import Foundation
import XCTest
@testable import UsageButlerCore
import UsageButlerDomain

private actor ProcessTestLatch {
    private var released = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async { if !released { await withCheckedContinuation { waiters.append($0) } } }
    func open() { released = true; let all = waiters; waiters.removeAll(); all.forEach { $0.resume() } }
}
private final class ControlledProcessSource: ProcessNetworkSource, @unchecked Sendable {
    let id: CaptureSessionID
    let started = ProcessTestLatch(), stopping = ProcessTestLatch(), drain = ProcessTestLatch()
    let pair = AsyncStream<ProcessNetworkFrame>.makeStream()
    init(_ id: CaptureSessionID) { self.id = id }
    func events() -> AsyncStream<ProcessNetworkFrame> { Task { await started.open() }; return pair.stream }
    func stop() async { await stopping.open(); await drain.wait(); pair.continuation.finish() }
    func emit(_ sequence: UInt64) {
        pair.continuation.yield(.init(envelope: .init(sessionID: id, sequence: sequence,
            occurredAt: Date(), monotonicOccurredAt: .init(nanoseconds: sequence * 1_000_000_000)),
            processes: [], complete: true))
    }
}
private final class ProcessTestFactory: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [ControlledProcessSource] = []
    var sources: [ControlledProcessSource] { lock.lock(); defer { lock.unlock() }; return values }
    func make(_ id: CaptureSessionID) -> ControlledProcessSource {
        lock.lock(); defer { lock.unlock() }
        let source = ControlledProcessSource(id); values.append(source); return source
    }
}

private final class PowerInterfaceFactory: @unchecked Sendable {
    private let lock = NSLock()
    private var countValue = 0
    var count: Int { lock.lock(); defer { lock.unlock() }; return countValue }
    func make(_ id: CaptureSessionID) -> PowerInterfaceSource {
        lock.lock(); countValue += 1; lock.unlock()
        return PowerInterfaceSource(id: id)
    }
}
private struct PowerInterfaceSource: NetworkObservationSource {
    let id: CaptureSessionID
    func currentSessionID() async -> CaptureSessionID { id }
    func capabilities() async -> NetworkCapabilities { .unavailable }
    func events() -> AsyncStream<NetworkSourceEvent> { AsyncStream { _ in } }
}
private actor PowerSettingsStore: NetworkSettingsStore {
    func load() async -> Result<NetworkSettings, NetworkStoreFailure> { .success(.init(collectionEnabled: true)) }
    func save(_ settings: NetworkSettings) async -> Result<Void, NetworkStoreFailure> { .success(()) }
}

@MainActor
final class ProcessNetworkCollectorTests: XCTestCase {
    func testPairedPowerIntentRejectsOldSleepAfterWakeWhileProcessDrainIsBlocked() async {
        let f = ProcessTestFactory(), interfaces = PowerInterfaceFactory()
        let process = ProcessNetworkCollector(makeSource: { f.make($0) })
        let interface = NetworkCollector(clock: TestClock(), settingsStore: PowerSettingsStore(),
            coverageProfile: .interfaceCountersOnly, idleCapabilities: .unavailable,
            makeSource: { interfaces.make($0) })
        await interface.start(); await process.setEnabled(true)
        let first = f.sources[0]; await first.started.wait()
        var updates = (await process.updates()).makeAsyncIterator()
        _ = await updates.next()
        let oldSleep = Task { await process.applyPowerIntent(suspended: true, revision: 1) }
        await first.stopping.wait()
        _ = await updates.next()
        await interface.applyPowerIntent(suspended: true, revision: 1)
        let wake = Task { await process.applyPowerIntent(suspended: false, revision: 2) }
        let waking = await updates.next() // Accepted wake, still awaiting the blocked drain.
        XCTAssertEqual(waking?.state, .starting)
        await interface.applyPowerIntent(suspended: false, revision: 2)
        // A delayed old callback and duplicate wake cannot override revision 2.
        await interface.applyPowerIntent(suspended: true, revision: 1)
        await process.applyPowerIntent(suspended: true, revision: 1)
        await interface.applyPowerIntent(suspended: false, revision: 2)
        await process.applyPowerIntent(suspended: false, revision: 2)
        await first.drain.open(); await oldSleep.value; await wake.value
        XCTAssertEqual(f.sources.count, 2)
        XCTAssertEqual(interfaces.count, 2)
        let second = f.sources[1]; await second.started.wait(); await second.drain.open()
        await process.applyPowerIntent(suspended: true, revision: 3)
        await interface.applyPowerIntent(suspended: true, revision: 3)
        let asleep = await process.currentSnapshot()
        XCTAssertEqual(asleep.state, .unavailable)
        let interfaceState = await interface.collectionStateNow()
        if case .disconnected = interfaceState {} else { XCTFail("latest sleep must stop the interface source") }
        await process.shutdown(); await interface.shutdown()
    }

    func testNewerDisableRejectsLateEnableAndShutdownIsTerminal() async {
        let f = ProcessTestFactory()
        let c = ProcessNetworkCollector(makeSource: { f.make($0) })
        await c.applyCollectionIntent(false, revision: 2)
        await c.applyCollectionIntent(true, revision: 1)
        XCTAssertEqual(f.sources.count, 0)
        await c.shutdown()
        await c.setEnabled(true); await c.resume(); await c.refresh()
        XCTAssertEqual(f.sources.count, 0)
        let snapshot = await c.currentSnapshot()
        XCTAssertEqual(snapshot.state, .stopped)
    }
    func testStopDrainsBeforeRestartAndLatestDisableWins() async {
        let f = ProcessTestFactory()
        let c = ProcessNetworkCollector(makeSource: { f.make($0) })
        await c.setEnabled(true)
        let source = f.sources[0]; await source.started.wait()
        var iterator = (await c.updates()).makeAsyncIterator()
        _ = await iterator.next()
        let stop = Task { await c.applyCollectionIntent(false, revision: 1) }
        await source.stopping.wait()
        _ = await iterator.next()
        let restart = Task { await c.applyCollectionIntent(true, revision: 2) }
        _ = await iterator.next()
        // Revision 3 is admitted while the owned source's stop is suspended.
        let finalStop = Task { await c.applyCollectionIntent(false, revision: 3) }
        _ = await iterator.next()
        await source.drain.open()
        await stop.value; await restart.value; await finalStop.value
        let value = await c.currentSnapshot()
        XCTAssertEqual(value.state, .stopped)
        XCTAssertEqual(f.sources.count, 1)
        await c.shutdown()
    }
    func testSleepPreservesPreferenceAndWakeCreatesFreshSession() async {
        let f = ProcessTestFactory()
        let c = ProcessNetworkCollector(makeSource: { f.make($0) })
        await c.setEnabled(true)
        let first = f.sources[0]; await first.started.wait(); await first.drain.open()
        let oldID = (await c.currentSnapshot()).sessionID
        await c.resume()
        XCTAssertEqual(f.sources.count, 1, "resume while already active is a no-op")
        await c.suspend()
        let sleeping = await c.currentSnapshot()
        XCTAssertEqual(sleeping.state, .unavailable)
        await c.resume()
        let second = f.sources[1]; await second.started.wait(); await second.drain.open()
        let current = await c.currentSnapshot()
        await c.resume()
        XCTAssertEqual(f.sources.count, 2, "duplicate wake cannot orphan a source")
        XCTAssertNotEqual(current.sessionID, oldID)
        first.emit(99) // Retired source cannot contaminate the new generation.
        await c.shutdown()
        let stopped = await c.currentSnapshot()
        XCTAssertEqual(stopped.sequence, 0)
        XCTAssertEqual(stopped.state, .stopped)
    }
    func testDisableDuringSleepDoesNotResume() async {
        let f = ProcessTestFactory()
        let c = ProcessNetworkCollector(makeSource: { f.make($0) })
        await c.setEnabled(true)
        let source = f.sources[0]; await source.started.wait(); await source.drain.open()
        await c.suspend(); await c.setEnabled(false); await c.resume()
        XCTAssertEqual(f.sources.count, 1)
        let stopped = await c.currentSnapshot()
        XCTAssertEqual(stopped.state, .stopped)
        await c.shutdown()
    }
    func testPublicationDoesNotLoseUnpublishedSourceFrames() async {
        let f = ProcessTestFactory()
        let c = ProcessNetworkCollector(makeSource: { f.make($0) })
        await c.updatePolicy(.init(minimumInterval: .zero))
        let stream = await c.updates()
        let observed = Task { () -> ProcessNetworkSnapshot? in
            for await value in stream { if value.sequence == 3 { return value } }
            return nil
        }
        await c.setEnabled(true)
        let source = f.sources[0]; await source.started.wait(); await source.drain.open()
        source.emit(1); source.emit(2); source.emit(3)
        let result = await observed.value
        XCTAssertEqual(result?.sequence, 3)
        await c.shutdown()
    }
}
