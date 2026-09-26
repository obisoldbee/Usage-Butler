import XCTest
@testable import UsageButlerCore

final class BackgroundSourceRecoveryTests: XCTestCase {
    private func source(_ generation: UInt64, enabled: Bool = true, suspended: Bool = false,
                        exhausted: Bool = true, healthy: Bool = false, issue: String = "source-ended") -> BackgroundSourceRecovery.Source {
        .init(generation: generation, enabled: enabled, suspended: suspended, exhausted: exhausted, healthy: healthy, issue: issue)
    }
    func testMonotonicCooldownBacksOffAndStableWindowResets() {
        var policy = BackgroundSourceRecovery(), now: UInt64 = 10_000_000_000
        for (generation, minutes) in [(UInt64(1), 5), (2, 10), (3, 20), (4, 30), (5, 30)] {
            XCTAssertNil(policy.observe(source(generation), now: now, permitted: true))
            XCTAssertEqual(policy.secondsRemaining(at: now), minutes * 60)
            now += UInt64(minutes) * 60_000_000_000
            XCTAssertNil(policy.observe(source(generation), now: now - 1, permitted: true))
            XCTAssertEqual(policy.observe(source(generation), now: now, permitted: true), generation)
            XCTAssertNil(policy.observe(source(generation + 1, exhausted: false), now: now, permitted: true))
        }
        XCTAssertNil(policy.observe(source(6, exhausted: false, healthy: true), now: now, permitted: true))
        XCTAssertNil(policy.observe(source(6), now: now, permitted: true))
        XCTAssertEqual(policy.secondsRemaining(at: now), 300)
    }
    func testNewGenerationCannotInheritPendingDeadlineAndStopsCancelIt() {
        var policy = BackgroundSourceRecovery()
        XCTAssertNil(policy.observe(source(1), now: 0, permitted: true))
        XCTAssertNil(policy.observe(source(2), now: 300_000_000_000, permitted: true))
        XCTAssertEqual(policy.secondsRemaining(at: 300_000_000_000), 300)
        for source in [source(2, enabled: false), source(2, suspended: true)] {
            XCTAssertNil(policy.observe(source, now: 600_000_000_000, permitted: true))
            XCTAssertNil(policy.deadline)
        }
        XCTAssertNil(policy.observe(source(3), now: 0, permitted: true))
        XCTAssertNil(policy.observe(source(3), now: 300_000_000_000, permitted: false))
        XCTAssertNil(policy.deadline)
    }
    func testOnlyExhaustedConfirmedTransientFailureIsEligible() {
        for issue in ["history-storage-error", "launch-failed", "pty-unavailable", "pty-config-failed", "stderr-limit", "unknown", "system-sleep"] {
            var policy = BackgroundSourceRecovery()
            XCTAssertNil(policy.observe(source(1, issue: issue), now: 0, permitted: true))
            XCTAssertNil(policy.deadline)
        }
        for issue in ["source-ended", "source-eof", "source-exited", "source-timeout", "read-failed"] {
            var policy = BackgroundSourceRecovery()
            XCTAssertNil(policy.observe(source(1, exhausted: false, issue: issue), now: 0, permitted: true))
            XCTAssertNil(policy.deadline)
            XCTAssertNil(policy.observe(source(1, issue: issue), now: 0, permitted: true))
            XCTAssertNotNil(policy.deadline)
        }
    }
}
