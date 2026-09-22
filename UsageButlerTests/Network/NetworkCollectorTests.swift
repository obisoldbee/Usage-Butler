import Foundation
import XCTest
@testable import UsageButlerCore
import UsageButlerDomain

final class NetworkCollectorTests: XCTestCase {
    private let baseWall = Date(timeIntervalSince1970: 1_700_000_000)
    private let epoch = CounterEpoch(rawValue: 42)

    private let idleCapabilities = NetworkCapabilities(
        observe: true, blockNewConnections: false, terminateExistingConnections: false,
        ask: false, allowlist: false, history: false, export: false,
        blockers: [.signingOrProfileMissing, .notYetImplemented]
    )

    // MARK: - Doubles

    private final class SourceFactoryBox: @unchecked Sendable {
        private let lock = NSLock()
        private var _sources: [FakeSource] = []

        var sources: [FakeSource] {
            lock.lock()
            defer { lock.unlock() }
            return _sources
        }

        var count: Int { sources.count }

        func make(_ sessionID: CaptureSessionID) -> FakeSource {
            let source = FakeSource(sessionID: sessionID)
            lock.lock()
            _sources.append(source)
            lock.unlock()
            return source
        }
    }

    private final class FakeSource: NetworkObservationSource, @unchecked Sendable {
        let sessionID: CaptureSessionID
        private let lock = NSLock()
        private var continuation: AsyncStream<NetworkSourceEvent>.Continuation?
        private var eventsWaiters: [CheckedContinuation<Void, Never>] = []

        init(sessionID: CaptureSessionID) {
            self.sessionID = sessionID
        }

        func events() -> AsyncStream<NetworkSourceEvent> {
            AsyncStream { continuation in
                lock.lock()
                self.continuation = continuation
                let waiters = eventsWaiters
                eventsWaiters.removeAll()
                lock.unlock()
                for waiter in waiters { waiter.resume() }
            }
        }

        func capabilities() async -> NetworkCapabilities {
            NetworkCapabilities(
                observe: true, blockNewConnections: false, terminateExistingConnections: false,
                ask: false, allowlist: false, history: false, export: false,
                blockers: [.signingOrProfileMissing, .notYetImplemented]
            )
        }

        func currentSessionID() async -> CaptureSessionID { sessionID }

        func yield(_ event: NetworkSourceEvent) {
            lock.lock()
            let continuation = self.continuation
            lock.unlock()
            continuation?.yield(event)
        }

        func finish() {
            lock.lock()
            let continuation = self.continuation
            self.continuation = nil
            lock.unlock()
            continuation?.finish()
        }

        func waitUntilEventsStarted() async {
            if eventsStarted { return }
            await withCheckedContinuation { (waiter: CheckedContinuation<Void, Never>) in
                if registerOrResolve(waiter) {
                    waiter.resume()
                }
            }
        }

        private var eventsStarted: Bool {
            lock.lock()
            defer { lock.unlock() }
            return continuation != nil
        }

        /// Returns true when events() already ran and the waiter was not
        /// enqueued. Keeps NSLock out of the async function body.
        private func registerOrResolve(_ waiter: CheckedContinuation<Void, Never>) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            if continuation != nil { return true }
            eventsWaiters.append(waiter)
            return false
        }
    }

    private actor FakeSettingsStore: NetworkSettingsStore {
        var loadResult: Result<NetworkSettings, NetworkStoreFailure>
        private(set) var saved: [NetworkSettings] = []

        init(loadResult: Result<NetworkSettings, NetworkStoreFailure> = .success(.default)) {
            self.loadResult = loadResult
        }

        func load() async -> Result<NetworkSettings, NetworkStoreFailure> { loadResult }

        func save(_ settings: NetworkSettings) async -> Result<Void, NetworkStoreFailure> {
            saved.append(settings)
            return .success(())
        }
    }

    private actor SnapshotLog {
        private var snapshots: [NetworkSnapshot] = []
        private var predicateWaiters: [
            UUID: (predicate: @Sendable (NetworkSnapshot) -> Bool, continuation: CheckedContinuation<NetworkSnapshot, Never>)
        ] = [:]
        private var indexWaiters: [UUID: (index: Int, continuation: CheckedContinuation<NetworkSnapshot, Never>)] = [:]

        func append(_ snapshot: NetworkSnapshot) {
            snapshots.append(snapshot)
            let readyPredicates = predicateWaiters.filter { $0.value.predicate(snapshot) }
            for (id, waiter) in readyPredicates {
                predicateWaiters.removeValue(forKey: id)
                waiter.continuation.resume(returning: snapshot)
            }
            let lastIndex = snapshots.count - 1
            let readyIndexes = indexWaiters.filter { $0.value.index <= lastIndex }
            for (id, waiter) in readyIndexes {
                indexWaiters.removeValue(forKey: id)
                waiter.continuation.resume(returning: snapshots[waiter.index])
            }
        }

        /// Waits for the first snapshot satisfying `predicate`; nil on a
        /// 5 s real-time timeout so a broken collector fails instead of
        /// hanging the suite.
        func first(matching predicate: @escaping @Sendable (NetworkSnapshot) -> Bool) async -> NetworkSnapshot? {
            await withTaskGroup(of: NetworkSnapshot?.self) { group in
                group.addTask { await self.matchingFirst(predicate) }
                group.addTask {
                    try? await Task.sleep(for: .seconds(5))
                    return nil
                }
                defer { group.cancelAll() }
                return await group.next() ?? nil
            }
        }

        func count() -> Int { snapshots.count }

        func snapshot(at index: Int) async -> NetworkSnapshot? {
            await withTaskGroup(of: NetworkSnapshot?.self) { group in
                group.addTask { await self.waitForIndex(index) }
                group.addTask {
                    try? await Task.sleep(for: .seconds(5))
                    return nil
                }
                defer { group.cancelAll() }
                return await group.next() ?? nil
            }
        }

        private func matchingFirst(_ predicate: @escaping @Sendable (NetworkSnapshot) -> Bool) async -> NetworkSnapshot {
            if let existing = snapshots.first(where: predicate) { return existing }
            return await withCheckedContinuation { continuation in
                predicateWaiters[UUID()] = (predicate, continuation)
            }
        }

        private func waitForIndex(_ index: Int) async -> NetworkSnapshot {
            if snapshots.count > index { return snapshots[index] }
            return await withCheckedContinuation { continuation in
                indexWaiters[UUID()] = (index, continuation)
            }
        }
    }

    // MARK: - Builders

    private func makeCollector(
        clock: TestClock,
        store: any NetworkSettingsStore,
        factory: SourceFactoryBox
    ) -> NetworkCollector {
        NetworkCollector(
            clock: clock,
            settingsStore: store,
            coverageProfile: .interfaceCountersOnly,
            idleCapabilities: idleCapabilities,
            makeSource: { sessionID in factory.make(sessionID) }
        )
    }

    private func heartbeatEvent(_ sequence: UInt64, session: CaptureSessionID) -> NetworkSourceEvent {
        NetworkSourceEvent(
            envelope: NetworkEventEnvelope(
                sessionID: session,
                sequence: sequence,
                occurredAt: baseWall,
                monotonicOccurredAt: MonotonicInstant(nanoseconds: sequence)
            ),
            payload: .heartbeat(capabilities: idleCapabilities)
        )
    }

    private func counterEvent(
        _ sequence: UInt64,
        session: CaptureSessionID,
        name: String = "en0",
        kind: NetworkInterfaceKind = .physical,
        upload: UInt64?,
        download: UInt64?
    ) -> NetworkSourceEvent {
        NetworkSourceEvent(
            envelope: NetworkEventEnvelope(
                sessionID: session,
                sequence: sequence,
                occurredAt: baseWall,
                monotonicOccurredAt: MonotonicInstant(nanoseconds: sequence)
            ),
            payload: .interfaceCounters(InterfaceCounters(
                name: name,
                kind: kind,
                counters: NetworkByteCounters(
                    bytes: DirectionalBytes(upload: upload, download: download),
                    semantics: .cumulativeSinceEpoch,
                    epoch: epoch
                ),
                asOf: baseWall,
                monotonicAsOf: MonotonicInstant(nanoseconds: sequence)
            ))
        )
    }

    private func waitForAppliedSequence(
        _ collector: NetworkCollector,
        minimum: UInt64,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        for _ in 0..<100_000 {
            if await collector.appliedSequence() >= minimum { return }
            await Task.yield()
        }
        XCTFail("timed out waiting for appliedSequence >= \(minimum)", file: file, line: line)
    }

    private func waitForDisconnected(
        _ collector: NetworkCollector,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        for _ in 0..<100_000 {
            if case .disconnected = await collector.collectionStateNow() { return }
            await Task.yield()
        }
        XCTFail("timed out waiting for disconnected state", file: file, line: line)
    }

    // MARK: - Tests

    func testStartPublishesStoppedSnapshotWhenCollectionDisabled() async {
        let clock = TestClock(wallTime: baseWall, monotonicNanoseconds: 0)
        let store = FakeSettingsStore()
        let factory = SourceFactoryBox()
        let collector = makeCollector(clock: clock, store: store, factory: factory)

        let log = SnapshotLog()
        let drain = Task {
            for await snapshot in await collector.updates() {
                await log.append(snapshot)
            }
        }
        defer { drain.cancel() }

        await collector.start()

        guard let first = await log.first(matching: { _ in true }) else {
            return XCTFail("expected an initial snapshot")
        }
        XCTAssertEqual(first.collectionState, .stopped)
        XCTAssertEqual(first.coverage.bytes, .unavailable(reason: "collection-stopped"))
        XCTAssertEqual(first.coverage.identity, .unavailable(reason: "collection-stopped"))
        XCTAssertEqual(first.coverage.targets, .unavailable(reason: "collection-stopped"))
        XCTAssertEqual(first.capabilities, idleCapabilities)
        XCTAssertTrue(first.interfaces.isEmpty)
        XCTAssertTrue(first.apps.isEmpty)
        XCTAssertEqual(first.sessionID.rawValue, "inactive")
        XCTAssertEqual(factory.count, 0)
    }

    func testStartWithEnabledPreferenceConsumesSourceAndPublishesActive() async {
        let clock = TestClock(wallTime: baseWall, monotonicNanoseconds: 0)
        let store = FakeSettingsStore(
            loadResult: .success(NetworkSettings(collectionEnabled: true))
        )
        let factory = SourceFactoryBox()
        let collector = makeCollector(clock: clock, store: store, factory: factory)

        let log = SnapshotLog()
        let drain = Task {
            for await snapshot in await collector.updates() {
                await log.append(snapshot)
            }
        }
        defer { drain.cancel() }

        await collector.start()
        XCTAssertEqual(factory.count, 1)
        let source = factory.sources[0]
        await source.waitUntilEventsStarted()

        // A heartbeat alone must not flip starting to active.
        source.yield(heartbeatEvent(1, session: source.sessionID))
        await waitForAppliedSequence(collector, minimum: 1)
        var current = await collector.currentSnapshot()
        XCTAssertEqual(current.collectionState, .starting)

        source.yield(counterEvent(2, session: source.sessionID, upload: 100, download: 200))
        await waitForAppliedSequence(collector, minimum: 2)
        current = await collector.currentSnapshot()
        XCTAssertEqual(current.collectionState, .active)
        XCTAssertEqual(current.interfaces["en0"]?.kind, .physical)
        XCTAssertEqual(current.interfaces["en0"]?.counters.bytes.upload, 100)
        // The interface-only profile overrides coverage even though the
        // aggregator observed bytes successfully.
        XCTAssertEqual(current.coverage.bytes, .partial(reason: "interfaces-only"))
        XCTAssertEqual(current.coverage.identity, .unavailable(reason: "per-app-observation-unavailable"))

        await clock.advance(to: 5_000_000_000)
        guard let published = await log.first(matching: { $0.collectionState == .active }) else {
            return XCTFail("expected a published active snapshot")
        }
        XCTAssertEqual(published.interfaces["en0"]?.counters.bytes.download, 200)
        XCTAssertNotEqual(published.sessionID.rawValue, "inactive")
        XCTAssertTrue(published.capabilities.observe)
    }

    /// A stop asked for while startup is still reading preferences must win.
    /// `start()` can load `collectionEnabled = true` before the toggle lands,
    /// and if it then opened a source the user would be watching traffic they
    /// explicitly switched off.
    func testExplicitStopBeatsAStartupThatLoadedTheOldPreference() async {
        var persisted = NetworkSettings.default
        persisted.collectionEnabled = true
        let clock = TestClock(wallTime: baseWall, monotonicNanoseconds: 0)
        let store = FakeSettingsStore(loadResult: .success(persisted))
        let factory = SourceFactoryBox()
        let collector = makeCollector(clock: clock, store: store, factory: factory)

        await collector.setCollectionEnabled(false)
        await collector.start()

        let state = await collector.collectionStateNow()
        XCTAssertEqual(state, .stopped)
        XCTAssertEqual(factory.count, 0, "a stopped intent must not open a source")
    }

    func testTogglingCollectionStartsNewSessionAndStopsCleanly() async {
        let clock = TestClock(wallTime: baseWall, monotonicNanoseconds: 0)
        let store = FakeSettingsStore()
        let factory = SourceFactoryBox()
        let collector = makeCollector(clock: clock, store: store, factory: factory)

        let log = SnapshotLog()
        let drain = Task {
            for await snapshot in await collector.updates() {
                await log.append(snapshot)
            }
        }
        defer { drain.cancel() }

        await collector.start()
        guard await log.snapshot(at: 0) != nil else {
            return XCTFail("expected the initial stopped snapshot")
        }

        await collector.setCollectionEnabled(true)
        var saved = await store.saved
        XCTAssertEqual(saved.last?.collectionEnabled, true)
        XCTAssertEqual(factory.count, 1)

        let source = factory.sources[0]
        await source.waitUntilEventsStarted()
        source.yield(counterEvent(1, session: source.sessionID, upload: 10, download: 20))
        await waitForAppliedSequence(collector, minimum: 1)
        guard let starting = await log.first(matching: { $0.collectionState == .starting }) else {
            return XCTFail("expected a starting snapshot after enabling")
        }
        XCTAssertEqual(starting.sessionID, source.sessionID)

        // The subscription seeding publishes one forced snapshot, so the exact
        // index of the disable publication is not fixed; it is simply the next
        // snapshot appended after the starting one.
        let publishedBeforeDisable = await log.count()
        await collector.setCollectionEnabled(false)
        saved = await store.saved
        XCTAssertEqual(saved.last?.collectionEnabled, false)

        guard let stopped = await log.snapshot(at: publishedBeforeDisable) else {
            return XCTFail("expected a stopped snapshot after disabling")
        }
        XCTAssertEqual(stopped.collectionState, .stopped)
        XCTAssertEqual(stopped.sessionID.rawValue, "inactive")
        // Stopping retains bounded history, but never asserts current presence.
        XCTAssertEqual(stopped.presence(of: "en0"), .notObserved)
        XCTAssertTrue(stopped.interfaceRates.isEmpty)
        XCTAssertTrue(stopped.apps.isEmpty)
        XCTAssertEqual(stopped.coverage.bytes, .unavailable(reason: "collection-stopped"))
    }

    func testFinishedStreamMarksDisconnectedAndRefreshNowStartsNewSession() async {
        let clock = TestClock(wallTime: baseWall, monotonicNanoseconds: 0)
        let store = FakeSettingsStore(
            loadResult: .success(NetworkSettings(collectionEnabled: true))
        )
        let factory = SourceFactoryBox()
        let collector = makeCollector(clock: clock, store: store, factory: factory)

        let log = SnapshotLog()
        let drain = Task {
            for await snapshot in await collector.updates() {
                await log.append(snapshot)
            }
        }
        defer { drain.cancel() }

        await collector.start()
        let source = factory.sources[0]
        await source.waitUntilEventsStarted()
        source.yield(counterEvent(1, session: source.sessionID, upload: 10, download: 20))
        await waitForAppliedSequence(collector, minimum: 1)

        source.finish()
        await waitForDisconnected(collector)

        await clock.advance(to: 5_000_000_000)
        guard let published = await log.first(matching: {
            if case .disconnected = $0.collectionState { return true }
            return false
        }) else {
            return XCTFail("expected a published disconnected snapshot")
        }
        // Disconnected retains the last-good counters; it never zeroes them.
        XCTAssertEqual(published.interfaces["en0"]?.counters.bytes.upload, 10)

        await collector.refreshNow()
        XCTAssertEqual(factory.count, 2)
        XCTAssertNotEqual(factory.sources[0].sessionID, factory.sources[1].sessionID)
        await factory.sources[1].waitUntilEventsStarted()
    }

    /// A second subscriber must keep receiving frames after the first one is
    /// torn down. The superseded stream terminates asynchronously, so a clear
    /// without an identity check drops the *new* continuation and starves it
    /// for the rest of the process.
    func testResubscribingStillReceivesFramesAfterFirstSubscriberEnds() async {
        let clock = TestClock(wallTime: baseWall, monotonicNanoseconds: 0)
        let store = FakeSettingsStore()
        let factory = SourceFactoryBox()
        let collector = makeCollector(clock: clock, store: store, factory: factory)
        await collector.start()

        let firstLog = SnapshotLog()
        let firstDrain = Task {
            for await snapshot in await collector.updates() {
                await firstLog.append(snapshot)
            }
        }
        guard await firstLog.first(matching: { _ in true }) != nil else {
            firstDrain.cancel()
            return XCTFail("first subscriber never received a frame")
        }
        firstDrain.cancel()

        let secondLog = SnapshotLog()
        let secondDrain = Task {
            for await snapshot in await collector.updates() {
                await secondLog.append(snapshot)
            }
        }
        defer { secondDrain.cancel() }

        // Let the first stream's termination callback run before anything
        // else can republish, which is the window the identity check closes.
        for _ in 0..<50 { await Task.yield() }

        guard let seeded = await secondLog.first(matching: { _ in true }) else {
            return XCTFail("second subscriber never received its seed snapshot")
        }
        XCTAssertEqual(seeded.collectionState, .stopped)

        await collector.setCollectionEnabled(true)
        guard await secondLog.first(matching: { $0.collectionState != .stopped }) != nil else {
            return XCTFail("second subscriber stopped receiving frames after resubscribing")
        }
    }
    /// Explicit continuation boundaries on the real collector's injected ports.
    private actor Gate {
        private var arrived = false
        private var opened = false
        private var pending: CheckedContinuation<Void, Never>?
        private var observers: [CheckedContinuation<Void, Never>] = []
        func enter() async {
            arrived = true
            observers.forEach { $0.resume() }; observers.removeAll()
            if !opened { await withCheckedContinuation { pending = $0 } }
        }
        func wait() async {
            if !arrived { await withCheckedContinuation { observers.append($0) } }
        }
        func open() { opened = true; pending?.resume(); pending = nil }
    }

    private actor PausedStore: NetworkSettingsStore {
        let loadGate: Gate?
        let saveGate: Gate?
        var persisted: NetworkSettings
        private(set) var writes: [Bool] = []
        let fails: Bool
        init(enabled: Bool = false, load: Gate? = nil, save: Gate? = nil, fails: Bool = false) {
            persisted = NetworkSettings(collectionEnabled: enabled)
            loadGate = load; saveGate = save; self.fails = fails
        }
        func load() async -> Result<NetworkSettings, NetworkStoreFailure> {
            let captured = persisted
            await loadGate?.enter()
            return .success(captured)
        }
        func save(_ settings: NetworkSettings) async -> Result<Void, NetworkStoreFailure> {
            await saveGate?.enter()
            if fails { return .failure(.io) }
            persisted = settings; writes.append(settings.collectionEnabled)
            return .success(())
        }
    }

    func testPausedStartupLoadCannotResurrectAfterStop() async {
        let gate = Gate()
        let store = PausedStore(enabled: true, load: gate)
        let factory = SourceFactoryBox()
        let collector = makeCollector(clock: TestClock(), store: store, factory: factory)
        let startup = Task { await collector.start() }
        await gate.wait()
        await collector.stop()
        await gate.open()
        await startup.value
        let state = await collector.collectionStateNow()
        XCTAssertEqual(state, .stopped)
        XCTAssertEqual(factory.count, 0)
        await collector.stop()
    }

    func testPausedEnableSaveCannotResurrectAfterStop() async {
        let gate = Gate()
        let store = PausedStore(save: gate)
        let factory = SourceFactoryBox()
        let collector = makeCollector(clock: TestClock(), store: store, factory: factory)
        await collector.start()
        let enable = Task { await collector.setCollectionEnabled(true) }
        await gate.wait()
        await collector.stop()
        let countAtStop = factory.count
        await gate.open()
        await enable.value
        let state = await collector.collectionStateNow()
        XCTAssertEqual(state, .stopped)
        XCTAssertEqual(factory.count, countAtStop)
        await collector.stop()
    }

    func testDisableStopsBeforeItsSaveCompletesEvenWhenSaveFails() async {
        let gate = Gate()
        let store = PausedStore(enabled: true, save: gate, fails: true)
        let factory = SourceFactoryBox()
        let collector = makeCollector(clock: TestClock(), store: store, factory: factory)
        await collector.start()
        let disable = Task { await collector.setCollectionEnabled(false) }
        await gate.wait()
        let whileSaving = await collector.collectionStateNow()
        XCTAssertEqual(whileSaving, .stopped)
        await gate.open()
        await disable.value
        let after = await collector.collectionStateNow()
        XCTAssertEqual(after, .stopped)
        await collector.stop()
    }

    func testNewDisableIsPersistedAfterPausedOldEnable() async {
        let gate = Gate(), clock = TestClock()
        let store = PausedStore(save: gate)
        let factory = SourceFactoryBox()
        let collector = makeCollector(clock: clock, store: store, factory: factory)
        await collector.start()
        await clock.waitUntilSleepIsRegistered(until: .init(nanoseconds: 5_000_000_000))
        let enable = Task { await collector.setCollectionEnabled(true) }
        await gate.wait()
        await clock.blockNextReading()
        let disable = Task { await collector.setCollectionEnabled(false) }
        await clock.waitUntilReadingIsBlocked()
        let state = await collector.collectionStateNow()
        XCTAssertEqual(state, .stopped, "accepted disable wins before either save can complete")
        await clock.resumeReading()
        await gate.open()
        await enable.value; await disable.value
        await collector.flushSettings()
        let writes = await store.writes
        let persisted = await store.persisted
        XCTAssertEqual(writes, [true, false])
        XCTAssertFalse(persisted.collectionEnabled)
        let final = await collector.collectionStateNow()
        XCTAssertEqual(final, .stopped)
        await collector.stop()
    }

    func testPrestartIntentAndRepeatedStartStopAndQueuedWork() async {
        let store = PausedStore()
        let factory = SourceFactoryBox()
        let collector = makeCollector(clock: TestClock(), store: store, factory: factory)
        await collector.setCollectionEnabled(true)
        XCTAssertEqual(factory.count, 0, "prestart writes intent without acquiring a source")
        await collector.start(); await collector.start()
        await collector.setCollectionEnabled(true)
        XCTAssertEqual(factory.count, 1, "repeating enable does not create another owner")
        await collector.stop(); await collector.stop()
        await collector.updatePolicy(.panelVisible)
        await collector.refreshNow()
        await collector.setCollectionEnabled(true)
        XCTAssertEqual(factory.count, 1, "late work after stop cannot start a source")
        await collector.start()
        XCTAssertEqual(factory.count, 2)
        await collector.setCollectionEnabled(false)
        await collector.setCollectionEnabled(false)
        await collector.stop()
        let saved = await store.persisted
        XCTAssertFalse(saved.collectionEnabled)
    }

    func testSuspendedRefreshClockCannotPublishIntoRestartedLifecycle() async {
        let clock = TestClock(), store = PausedStore()
        let factory = SourceFactoryBox()
        let collector = makeCollector(clock: clock, store: store, factory: factory)
        await collector.start()
        await clock.waitUntilSleepIsRegistered(until: .init(nanoseconds: 5_000_000_000))
        await clock.blockNextReading()
        let refresh = Task { await collector.refreshNow() }
        await clock.waitUntilReadingIsBlocked()
        await collector.stop()
        await collector.start()
        let stream = await collector.updates()
        var iterator = stream.makeAsyncIterator()
        _ = await iterator.next()
        let log = SnapshotLog()
        let drain = Task { for await snapshot in stream { await log.append(snapshot) } }
        await clock.resumeReading()
        await refresh.value
        await collector.stop()
        await drain.value
        let count = await log.count()
        XCTAssertEqual(count, 0, "old clock completion must not publish into the new subscription")
    }

    func testShutdownDrainsAcceptedSaveAndRejectsLateStartupAndIntent() async {
        let gate = Gate()
        let factory = SourceFactoryBox(), clock = TestClock()
        let activeStore = PausedStore(save: gate)
        let collector = makeCollector(clock: clock, store: activeStore, factory: factory)
        await collector.start()
        let stream = await collector.updates()
        let drained = Task { for await _ in stream {} }
        let enable = Task { await collector.setCollectionEnabled(true) }
        await gate.wait()
        let shutdown = Task { await collector.shutdown() }
        // Finishing the real output stream is the synchronous stop boundary.
        await drained.value
        let state = await collector.collectionStateNow()
        XCTAssertEqual(state, .stopped)
        await collector.start()
        await collector.setCollectionEnabled(false)
        await collector.refreshNow()
        await collector.updatePolicy(.panelVisible)
        let pending = await activeStore.writes
        XCTAssertTrue(pending.isEmpty, "shutdown is draining an accepted, paused save")
        await gate.open()
        await enable.value; await shutdown.value
        let writes = await activeStore.writes
        XCTAssertEqual(writes, [true], "late intent is rejected after the final shutdown boundary")
        let lateUpdates = await collector.updates()
        var lateIterator = lateUpdates.makeAsyncIterator()
        let ended = await lateIterator.next()
        XCTAssertNil(ended, "late subscribers finish at the final shutdown boundary")
        XCTAssertEqual(factory.count, 1)
    }

}
