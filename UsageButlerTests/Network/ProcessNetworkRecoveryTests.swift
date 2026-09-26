import Foundation
import XCTest
@testable import UsageButlerCore
import UsageButlerDomain

private actor RecoveryLatch {
    private var open = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async { if !open { await withCheckedContinuation { waiters.append($0) } } }
    func release() { open = true; let pending = waiters; waiters.removeAll(); pending.forEach { $0.resume() } }
}
private actor RecoveryDelay {
    nonisolated let requests = AsyncStream<Duration>.makeStream()
    private var pending: [CheckedContinuation<Void, Never>] = []
    func sleep(_ duration: Duration) async {
        await withCheckedContinuation { pending.append($0); requests.continuation.yield(duration) }
    }
    // Deliberately ignores cancellation until released: tests the generation
    // guard even when an injected dependency completes after stop/shutdown.
    func release() { pending.removeFirst().resume() }
    var count: Int { pending.count }
}
private final class RecoverySource: ProcessNetworkSource, @unchecked Sendable {
    let id: CaptureSessionID
    let started = RecoveryLatch()
    let pair = AsyncStream<ProcessNetworkFrame>.makeStream()
    init(_ id: CaptureSessionID) { self.id = id }
    func events() -> AsyncStream<ProcessNetworkFrame> { Task { await started.release() }; return pair.stream }
    func stop() async { pair.continuation.finish() }
    func finish() { pair.continuation.finish() }
    func emit(_ sequence: UInt64) { pair.continuation.yield(recoveryFrame(id, sequence: sequence, seconds: sequence)) }
}
private final class RecoveryFactory: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [RecoverySource] = []
    var sources: [RecoverySource] { lock.lock(); defer { lock.unlock() }; return values }
    func make(_ id: CaptureSessionID) -> RecoverySource {
        lock.lock(); defer { lock.unlock() }
        let source = RecoverySource(id); values.append(source); return source
    }
}
private final class RecoveryRecords: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [ProcessNetworkLifecycleEvent] = []
    private var cursor = 0
    private var waiter: (ProcessNetworkLifecycleEvent.Kind, CheckedContinuation<ProcessNetworkLifecycleEvent?, Never>)?
    var events: [ProcessNetworkLifecycleEvent] { lock.lock(); defer { lock.unlock() }; return values }
    func record(_ event: ProcessNetworkLifecycleEvent) {
        lock.lock(); values.append(event)
        var ready: CheckedContinuation<ProcessNetworkLifecycleEvent?, Never>?
        if let waiting = waiter, waiting.0 == event.kind {
            ready = waiting.1; waiter = nil; cursor = values.count
        }
        lock.unlock(); ready?.resume(returning: event)
    }
    func next(_ kind: ProcessNetworkLifecycleEvent.Kind) async -> ProcessNetworkLifecycleEvent? {
        await withCheckedContinuation { continuation in
            lock.lock()
            if let index = (cursor..<values.count).first(where: { values[$0].kind == kind }) {
                let value = values[index]; cursor = index + 1
                lock.unlock(); continuation.resume(returning: value)
            } else {
                precondition(waiter == nil)
                waiter = (kind, continuation); lock.unlock()
            }
        }
    }
}
private func recoveryFrame(_ id: CaptureSessionID, sequence: UInt64, seconds: UInt64,
                           complete: Bool = true, issue: String? = nil, cadence: Double = 1) -> ProcessNetworkFrame {
    .init(envelope: .init(sessionID: id, sequence: sequence, occurredAt: Date(timeIntervalSince1970: Double(seconds)),
        monotonicOccurredAt: .init(nanoseconds: seconds * 1_000_000_000)), processes: [],
        complete: complete, issue: issue, samplingInterval: cadence)
}
@MainActor final class ProcessNetworkRecoveryTests: XCTestCase {
    func testUnhealthyEndingsUseTwoFourSixSecondsThenExhaustAndManualRefreshResets() async {
        let f = RecoveryFactory(), delay = RecoveryDelay(), log = RecoveryRecords()
        let c = ProcessNetworkCollector(retrySleep: { await delay.sleep($0) }, record: log.record, makeSource: f.make)
        var sleeps = delay.requests.stream.makeAsyncIterator()
        await c.setEnabled(true)
        _ = await log.next(.collectorStarted)
        for attempt in 1...3 {
            let source = f.sources.last!; await source.started.wait(); source.finish()
            let scheduled = await log.next(.retryScheduled)
            XCTAssertEqual(scheduled?.attempt, attempt); XCTAssertEqual(scheduled?.reason, .sourceEnded)
            let requested = await sleeps.next(); XCTAssertEqual(requested, .seconds(attempt * 2))
            await delay.release()
            let started = await log.next(.collectorStarted)
            XCTAssertEqual(started?.reason, .automaticRetry)
        }
        let last = f.sources.last!; await last.started.wait(); last.finish()
        let exhausted = await log.next(.retryExhausted)
        XCTAssertEqual(exhausted?.attempt, 3); XCTAssertEqual(f.sources.count, 4)
        let pending = await delay.count; XCTAssertEqual(pending, 0)
        let stopped = await c.currentSnapshot(); XCTAssertEqual(stopped.state, .unavailable)
        await c.refresh()
        let manual = await log.next(.collectorStarted)
        XCTAssertEqual(manual?.reason, .manualRefresh); XCTAssertEqual(manual?.attempt, 0)
        XCTAssertEqual(f.sources.count, 5)
        await c.shutdown()
    }

    func testSixtySecondsOfTrustedFramesReplenishesOnceAndLaterFailureGetsFirstDelay() async {
        let f = RecoveryFactory(), delay = RecoveryDelay(), log = RecoveryRecords()
        let c = ProcessNetworkCollector(retrySleep: { await delay.sleep($0) }, record: log.record, makeSource: f.make)
        await c.updatePolicy(.init(minimumInterval: .zero))
        var snapshots = (await c.updates()).makeAsyncIterator()
        var sleeps = delay.requests.stream.makeAsyncIterator()
        await c.setEnabled(true); _ = await log.next(.collectorStarted)
        let first = f.sources[0]; await first.started.wait(); first.finish()
        _ = await log.next(.retryScheduled); _ = await sleeps.next(); await delay.release()
        _ = await log.next(.collectorStarted)
        let source = f.sources[1]; await source.started.wait()
        for i in 1...60 { source.emit(UInt64(i)) }
        while let value = await snapshots.next() { if value.sequence == 60 { break } }
        await c.refresh() // No source-time progress; 59 seconds is insufficient.
        XCTAssertFalse(log.events.contains { $0.kind == .budgetReplenished })
        source.emit(61)
        let replenished = await log.next(.budgetReplenished)
        XCTAssertEqual(replenished?.attempt, 1); XCTAssertEqual(replenished?.reason, .healthyWindow)
        for i in 62...122 { source.emit(UInt64(i)) }
        while let value = await snapshots.next() { if value.sequence == 122 { break } }
        XCTAssertEqual(log.events.filter { $0.kind == .budgetReplenished }.count, 1)
        source.finish()
        let scheduled = await log.next(.retryScheduled)
        XCTAssertEqual(scheduled?.attempt, 1)
        let requested = await sleeps.next(); XCTAssertEqual(requested, .seconds(2))
        await c.shutdown(); await delay.release()
        _ = await log.next(.retryCancelled)
    }

    func testBackoffCannotReviveAfterDisableSleepOrShutdown() async {
        for action in ["disable", "sleep", "shutdown"] {
            let f = RecoveryFactory(), delay = RecoveryDelay(), log = RecoveryRecords()
            let c = ProcessNetworkCollector(retrySleep: { await delay.sleep($0) }, record: log.record, makeSource: f.make)
            var sleeps = delay.requests.stream.makeAsyncIterator()
            await c.setEnabled(true); _ = await log.next(.collectorStarted)
            let source = f.sources[0]; await source.started.wait(); source.finish()
            _ = await log.next(.retryScheduled); _ = await sleeps.next()
            switch action {
            case "disable": await c.setEnabled(false)
            case "sleep": await c.suspend()
            default: await c.shutdown()
            }
            await delay.release()
            // This event is emitted only after the cancelled backoff resumes
            // and rejects the old generation: no scheduler timing assumption.
            _ = await log.next(.retryCancelled)
            let snapshot = await c.currentSnapshot()
            XCTAssertEqual(snapshot.state, action == "sleep" ? .unavailable : .stopped)
            XCTAssertEqual(f.sources.count, 1)
            if action == "sleep" {
                await c.resume()
                let resumed = await log.next(.collectorStarted)
                XCTAssertEqual(resumed?.reason, .resumed); XCTAssertEqual(resumed?.attempt, 0)
                XCTAssertEqual(f.sources.count, 2)
            }
            await c.shutdown()
        }
    }

    func testAnomaliesRestartTheMonotonicHealthWindow() {
        let id = CaptureSessionID(rawValue: "health")
        let anomalies: [(String, ProcessNetworkFrame)] = [
            ("partial", recoveryFrame(id, sequence: 61, seconds: 61, complete: false)),
            ("gap", recoveryFrame(id, sequence: 63, seconds: 61)),
            ("replay", recoveryFrame(id, sequence: 60, seconds: 61)),
            ("old-sequence", recoveryFrame(id, sequence: 20, seconds: 61)),
            ("old-session", recoveryFrame(.init(rawValue: "old"), sequence: 61, seconds: 61)),
            ("clock-back", recoveryFrame(id, sequence: 61, seconds: 10)),
            ("long-interval", recoveryFrame(id, sequence: 61, seconds: 120)),
            ("unknown-cadence", recoveryFrame(id, sequence: 61, seconds: 61, cadence: .nan)),
            ("zero-cadence", recoveryFrame(id, sequence: 61, seconds: 61, cadence: 0)),
            ("issue", recoveryFrame(id, sequence: 61, seconds: 61, issue: "source-cadence-unverified"))]
        for (label, anomaly) in anomalies {
            var health = ProcessNetworkRecoveryHealth(), aggregator = ProcessNetworkAggregator(sessionID: id)
            func observe(_ frame: ProcessNetworkFrame) -> Bool {
                let accepted = aggregator.apply(frame)
                return health.observe(frame, accepted: accepted && aggregator.state == .active, session: id)
            }
            for i in 1...60 { XCTAssertFalse(observe(recoveryFrame(id, sequence: UInt64(i), seconds: UInt64(i))), label) }
            XCTAssertFalse(observe(anomaly), label)
            let firstTime = max(61, anomaly.envelope.monotonicOccurredAt.nanoseconds / 1_000_000_000) + 1
            let firstSequence = aggregator.sequence + 1
            for i in 0..<59 {
                XCTAssertFalse(observe(recoveryFrame(id, sequence: firstSequence + UInt64(i), seconds: firstTime + UInt64(i))), label)
            }
            // At most one fresh baseline second can be credited to a complete
            // gap frame itself; never the missing/rejected interval before it.
            _ = observe(recoveryFrame(id, sequence: firstSequence + 59, seconds: firstTime + 59))
            XCTAssertTrue(observe(recoveryFrame(id, sequence: firstSequence + 60, seconds: firstTime + 60)), label)
        }
    }

    func testHealthDoesNotBridgeSessionsOrBufferedBurst() {
        let id = CaptureSessionID(rawValue: "health")
        var health = ProcessNetworkRecoveryHealth()
        for i in 1...60 { XCTAssertFalse(health.observe(recoveryFrame(id, sequence: UInt64(i), seconds: UInt64(i)), accepted: true, session: id)) }
        health.reset()
        XCTAssertFalse(health.observe(recoveryFrame(id, sequence: 61, seconds: 1000), accepted: true, session: id))
        let burst = ProcessNetworkFrame(envelope: .init(sessionID: id, sequence: 62, occurredAt: Date(),
            monotonicOccurredAt: .init(nanoseconds: 1_000_100_000_000)), processes: [], complete: true)
        XCTAssertFalse(health.observe(burst, accepted: true, session: id))
    }

    func testLifecycleDiagnosticWhitelistRejectsRawReasonsAndBoundsNumbers() throws {
        let secret = "synthetic-credential /synthetic/private-path 127.0.0.1 SyntheticApp"
        let event = ProcessNetworkLifecycleEvent(kind: .sourceEnded, reason: .sourceIssue(secret),
            attempt: Int.max, delaySeconds: Int.max, exitStatus: .max, exitKind: .signal,
            cleanup: .kill, errorNumber: .max, lastHeaderAgeMilliseconds: .max)
        let data = event.encoded(), text = String(decoding: event.encoded(), as: UTF8.self)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(Set(object.keys), ["kind", "reason", "attempt", "delaySeconds", "exitStatus", "exitKind", "cleanup", "errorNumber", "lastHeaderAgeMilliseconds"])
        XCTAssertEqual(object["reason"] as? String, "unknown")
        XCTAssertEqual(object["attempt"] as? Int, 3); XCTAssertEqual(object["delaySeconds"] as? Int, 6)
        XCTAssertEqual(object["exitStatus"] as? Int, 255); XCTAssertEqual(object["errorNumber"] as? Int, 255)
        XCTAssertEqual(object["lastHeaderAgeMilliseconds"] as? Int, 600_000)
        XCTAssertLessThan(data.count, 512)
        for excluded in [secret, "127.0.0.1", "SyntheticApp", "environment", "path", "pid", "stderr", "csv"] {
            XCTAssertFalse(text.contains(excluded))
        }
    }
}
