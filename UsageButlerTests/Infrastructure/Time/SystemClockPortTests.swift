import Foundation
import UsageButlerDomain
import XCTest
@testable import UsageButlerInfrastructure

final class SystemClockPortTests: XCTestCase {
    func testReadingPairsWallTimeWithMonotonicUptime() async {
        let wall = Date(timeIntervalSince1970: 1234)
        let clock = SystemClockPort(
            wallNow: { wall },
            monotonicNow: { 9_876 },
            sleepNanoseconds: { _ in }
        )

        let reading = await clock.reading()

        XCTAssertEqual(reading.wallTime, wall)
        XCTAssertEqual(reading.monotonicTime, MonotonicInstant(nanoseconds: 9_876))
    }

    func testSleepUsesOnlyRemainingMonotonicDuration() async throws {
        let recorder = NanosecondRecorder()
        let clock = SystemClockPort(
            wallNow: { .distantPast },
            monotonicNow: { 4_000 },
            sleepNanoseconds: { value in await recorder.record(value) }
        )

        try await clock.sleep(until: MonotonicInstant(nanoseconds: 9_500))

        let recorded = await recorder.values()
        XCTAssertEqual(recorded, [5_500])
    }

    func testPastOrEqualDeadlineReturnsWithoutSleeping() async throws {
        let recorder = NanosecondRecorder()
        let clock = SystemClockPort(
            wallNow: { .distantPast },
            monotonicNow: { 4_000 },
            sleepNanoseconds: { value in await recorder.record(value) }
        )

        try await clock.sleep(until: MonotonicInstant(nanoseconds: 4_000))
        try await clock.sleep(until: MonotonicInstant(nanoseconds: 3_999))

        let recorded = await recorder.values()
        XCTAssertTrue(recorded.isEmpty)
    }
}

private actor NanosecondRecorder {
    private var storage: [UInt64] = []

    func record(_ value: UInt64) {
        storage.append(value)
    }

    func values() -> [UInt64] {
        storage
    }
}
