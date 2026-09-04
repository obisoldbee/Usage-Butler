import XCTest
@testable import UsageButlerCore
@testable import UsageButlerDomain

final class RefreshSchedulerTests: XCTestCase {
    func testScheduleUsesInjectedClockAndDeterministicRetryJitter() async throws {
        let clock = TestClock(monotonicNanoseconds: 100)
        let scheduler = RefreshScheduler(
            clock: clock,
            jitter: FixedRefreshJitter(offset: RefreshDuration(nanoseconds: 7))
        )
        let recorder = TokenRecorder()
        let key = RefreshScheduleKey(providerID: .ark, scope: .provider)

        let scheduled = await scheduler.schedule(
            key: key,
            after: RefreshDuration(nanoseconds: 50),
            reason: .refreshRetry(attempt: 1, initiatedBy: .manual)
        ) { token in
            await recorder.record(token)
        }
        let token = try XCTUnwrap(scheduled)

        XCTAssertEqual(token.deadline, MonotonicInstant(nanoseconds: 157))
        await clock.waitUntilSleepIsRegistered(until: token.deadline)
        await clock.advance(to: 156)
        let beforeDeadline = await recorder.tokens()
        XCTAssertTrue(beforeDeadline.isEmpty)

        await clock.advance(to: 157)
        await recorder.waitUntilRecorded(token)
        let fired = await recorder.tokens()
        let pending = await scheduler.scheduledToken(for: key)
        XCTAssertEqual(fired, [token])
        XCTAssertNil(pending)
    }

    func testReplacingSameScopeInvalidatesOldGenerationAndFiresOnlyNewestTask() async throws {
        let clock = TestClock()
        let scheduler = RefreshScheduler(clock: clock)
        let recorder = TokenRecorder()
        let key = RefreshScheduleKey(providerID: .ark, scope: .provider)

        let firstScheduled = await scheduler.schedule(
            key: key,
            after: RefreshDuration(nanoseconds: 10),
            reason: .automatic
        ) { token in
            await recorder.record(token)
        }
        let first = try XCTUnwrap(firstScheduled)
        let secondScheduled = await scheduler.schedule(
            key: key,
            after: RefreshDuration(nanoseconds: 20),
            reason: .automatic
        ) { token in
            await recorder.record(token)
        }
        let second = try XCTUnwrap(secondScheduled)

        XCTAssertGreaterThan(second.generation, first.generation)
        await clock.waitUntilSleepIsRegistered(until: second.deadline)
        await clock.advance(to: 20)
        await recorder.waitUntilRecorded(second)
        let fired = await recorder.tokens()
        XCTAssertEqual(fired, [second])
    }

    func testCancelledScheduleAtClockBoundaryCannotReplaceNewGeneration() async throws {
        let clock = TestClock()
        let scheduler = RefreshScheduler(clock: clock)
        let recorder = TokenRecorder()
        let key = RefreshScheduleKey(providerID: .ark, scope: .provider)
        await clock.blockNextReading()
        let oldSchedule = Task {
            await scheduler.schedule(key: key, after: .seconds(60), reason: .automatic) {
                await recorder.record($0)
            }
        }
        await clock.waitUntilReadingIsBlocked()
        await scheduler.cancel(providerID: .ark)
        let replacement = await scheduler.schedule(
            key: key, after: .seconds(120), reason: .automatic
        ) { await recorder.record($0) }
        let token = try XCTUnwrap(replacement)
        await clock.resumeReading()
        let cancelled = await oldSchedule.value
        XCTAssertNil(cancelled)
        let pending = await scheduler.scheduledToken(for: key)
        XCTAssertEqual(pending, token)
        guard pending == token else {
            await scheduler.shutdown()
            return
        }
        await clock.waitUntilSleepIsRegistered(until: token.deadline)
        await clock.advance(to: token.deadline.nanoseconds)
        await recorder.waitUntilRecorded(token)
        let fired = await recorder.tokens()
        XCTAssertEqual(fired, [token])
        await scheduler.shutdown()
    }

    func testCancellationAndShutdownPreventWakeAndRejectNewSchedules() async throws {
        let clock = TestClock()
        let scheduler = RefreshScheduler(clock: clock)
        let recorder = TokenRecorder()
        let key = RefreshScheduleKey(providerID: .ark, scope: .provider)

        let scheduled = await scheduler.schedule(
            key: key,
            after: RefreshDuration(nanoseconds: 10),
            reason: .automatic
        ) { token in
            await recorder.record(token)
        }
        let token = try XCTUnwrap(scheduled)
        await scheduler.cancel(token: token)
        await clock.advance(to: 10)
        let fired = await recorder.tokens()
        XCTAssertTrue(fired.isEmpty)

        await scheduler.shutdown()
        let rejected = await scheduler.schedule(
            key: key,
            after: RefreshDuration(nanoseconds: 1),
            reason: .automatic
        ) { token in
            await recorder.record(token)
        }
        XCTAssertNil(rejected)
    }

}

private actor TokenRecorder {
    private struct Waiter {
        let token: RefreshScheduleToken
        let continuation: CheckedContinuation<Void, Never>
    }

    private var recorded: [RefreshScheduleToken] = []
    private var waiters: [Waiter] = []

    func record(_ token: RefreshScheduleToken) {
        recorded.append(token)
        let tokenWaiters = waiters.filter { $0.token == token }
        waiters.removeAll { $0.token == token }
        for waiter in tokenWaiters {
            waiter.continuation.resume()
        }
    }

    func tokens() -> [RefreshScheduleToken] {
        recorded
    }

    func waitUntilRecorded(_ token: RefreshScheduleToken) async {
        if recorded.contains(token) {
            return
        }

        await withCheckedContinuation { continuation in
            waiters.append(Waiter(token: token, continuation: continuation))
        }
    }
}
