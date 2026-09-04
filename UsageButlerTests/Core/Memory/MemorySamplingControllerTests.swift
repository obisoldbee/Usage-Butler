import Foundation
import XCTest
@testable import UsageButlerCore
import UsageButlerDomain

final class MemorySamplingControllerTests: XCTestCase {
    func testPolicyUpdateCancelsTenSecondSleepAndImmediatelyUsesOneSecondPolicy() async {
        let firstTimestamp = Date(timeIntervalSince1970: 100_000)
        let secondTimestamp = firstTimestamp.addingTimeInterval(0.25)
        let clock = TestMemorySamplingClock(
            timestamps: [firstTimestamp, secondTimestamp]
        )
        let sleeper = ControlledMemorySamplingSleeper()
        let pressureSource = TestMemoryPressureSource()
        let reader = ControlledMemoryStatsReader()
        let controller = MemorySamplingController(
            clock: clock,
            sleeper: sleeper,
            pressureSource: pressureSource,
            statsReader: reader
        )

        await controller.start()
        let firstReadArrived = await eventually {
            await reader.pendingRequests().count == 1
        }
        XCTAssertTrue(firstReadArrived)
        guard let firstRead = await reader.pendingRequests().first else {
            XCTFail("missing initial read")
            await controller.stop()
            return
        }
        XCTAssertEqual(firstRead.capturedAt, firstTimestamp)
        let firstReadCompleted = await reader.complete(
            id: firstRead.id,
            fields: memoryFields(usedBytes: 40),
            pressureState: .normal
        )
        XCTAssertTrue(firstReadCompleted)

        let tenSecondSleepArrived = await eventually {
            await sleeper.requests().count == 1
        }
        XCTAssertTrue(tenSecondSleepArrived)
        let firstSleepInterval = await sleeper.requests().first?.interval
        XCTAssertEqual(firstSleepInterval, .seconds(10))

        await controller.updatePolicy(.memoryPageVisible)

        let rescheduledReadArrived = await eventually {
            await reader.pendingRequests().count == 1
        }
        XCTAssertTrue(rescheduledReadArrived)
        guard let secondRead = await reader.pendingRequests().first else {
            XCTFail("missing policy-rescheduled read")
            await controller.stop()
            return
        }
        XCTAssertEqual(secondRead.capturedAt, secondTimestamp)
        let secondReadCompleted = await reader.complete(
            id: secondRead.id,
            fields: memoryFields(usedBytes: 60),
            pressureRatio: 0.24
        )
        XCTAssertTrue(secondReadCompleted)

        let oneSecondSleepArrived = await eventually {
            await sleeper.requests().count == 2
        }
        let oldSleepCancelled = await eventually {
            await sleeper.cancelledRequests().contains(where: {
                $0.interval == .seconds(10)
            })
        }
        XCTAssertTrue(oneSecondSleepArrived)
        XCTAssertTrue(oldSleepCancelled)
        let latestSleepInterval = await sleeper.requests().last?.interval
        XCTAssertEqual(latestSleepInterval, .seconds(1))

        let state = await controller.currentState()
        XCTAssertEqual(state.policy, .memoryPageVisible)
        XCTAssertEqual(state.history.map(\.timestamp), [
            firstTimestamp,
            secondTimestamp
        ])
        XCTAssertEqual(state.latest?.estimatedUsedRatio, 0.6)
        XCTAssertEqual(state.latest?.pressureRatio, 0.24)
        XCTAssertEqual(state.history.last?.pressureRatio, 0.24)
        XCTAssertEqual(state.history.map(\.pressure), [.normal, .normal])

        await controller.stop()
        await pressureSource.finish()
    }

    func testPolicyUpdateCancelsInFlightReadAndRejectsItsLateResult() async {
        let firstTimestamp = Date(timeIntervalSince1970: 200_000)
        let secondTimestamp = firstTimestamp.addingTimeInterval(1)
        let clock = TestMemorySamplingClock(
            timestamps: [firstTimestamp, secondTimestamp]
        )
        let sleeper = ControlledMemorySamplingSleeper()
        let pressureSource = TestMemoryPressureSource()
        let reader = ControlledMemoryStatsReader()
        let controller = MemorySamplingController(
            clock: clock,
            sleeper: sleeper,
            pressureSource: pressureSource,
            statsReader: reader
        )

        await controller.start()
        let firstReadArrived = await eventually {
            await reader.pendingRequests().count == 1
        }
        XCTAssertTrue(firstReadArrived)
        guard let firstRead = await reader.pendingRequests().first else {
            XCTFail("missing initial read")
            await controller.stop()
            return
        }

        await controller.updatePolicy(.memoryPageVisible)
        let twoReadsPending = await eventually {
            await reader.pendingRequests().count == 2
        }
        XCTAssertTrue(twoReadsPending)
        guard let secondRead = await reader.pendingRequests().last else {
            XCTFail("missing replacement read")
            await controller.stop()
            return
        }

        let cancelledReadCompleted = await reader.complete(
            id: firstRead.id,
            fields: memoryFields(usedBytes: 10)
        )
        XCTAssertTrue(cancelledReadCompleted)
        let cancellationObserved = await eventually {
            await reader.observedCancellation(id: firstRead.id) == true
        }
        XCTAssertTrue(cancellationObserved)

        let replacementReadCompleted = await reader.complete(
            id: secondRead.id,
            fields: memoryFields(usedBytes: 90),
            pressureRatio: 0.31,
            returnedTimestamp: secondTimestamp.addingTimeInterval(999)
        )
        XCTAssertTrue(replacementReadCompleted)
        let replacementCommitted = await eventually {
            await sleeper.requests().count == 1
        }
        XCTAssertTrue(replacementCommitted)

        let state = await controller.currentState()
        XCTAssertEqual(state.history.count, 1)
        XCTAssertEqual(state.latest?.timestamp, secondTimestamp)
        XCTAssertEqual(state.latest?.estimatedUsedRatio, 0.9)
        XCTAssertEqual(state.latest?.pressureRatio, 0.31)

        await controller.stop()
        await pressureSource.finish()
    }

    func testPressureEventResamplesAndMergesPressureWithNumericTimestamp() async {
        let firstTimestamp = Date(timeIntervalSince1970: 300_000)
        let pressureTimestamp = firstTimestamp.addingTimeInterval(2)
        let clock = TestMemorySamplingClock(
            timestamps: [firstTimestamp, pressureTimestamp]
        )
        let sleeper = ControlledMemorySamplingSleeper()
        let pressureSource = TestMemoryPressureSource()
        let reader = ControlledMemoryStatsReader()
        let controller = MemorySamplingController(
            clock: clock,
            sleeper: sleeper,
            pressureSource: pressureSource,
            statsReader: reader
        )

        await controller.start()
        let initialReadArrived = await eventually {
            await reader.pendingRequests().count == 1
        }
        XCTAssertTrue(initialReadArrived)
        guard let initialRead = await reader.pendingRequests().first else {
            XCTFail("missing initial read")
            await controller.stop()
            return
        }
        let initialReadCompleted = await reader.complete(
            id: initialRead.id,
            fields: memoryFields(usedBytes: 35)
        )
        XCTAssertTrue(initialReadCompleted)
        let initialSleepArrived = await eventually {
            await sleeper.requests().count == 1
        }
        XCTAssertTrue(initialSleepArrived)

        await pressureSource.send(.warning)

        let pressureReadArrived = await eventually {
            await reader.pendingRequests().count == 1
        }
        XCTAssertTrue(pressureReadArrived)
        guard let pressureRead = await reader.pendingRequests().first else {
            XCTFail("missing pressure-rescheduled read")
            await controller.stop()
            return
        }
        XCTAssertEqual(pressureRead.capturedAt, pressureTimestamp)
        let pressureReadCompleted = await reader.complete(
            id: pressureRead.id,
            fields: memoryFields(usedBytes: 70),
            pressureRatio: 0.42,
            returnedTimestamp: pressureTimestamp.addingTimeInterval(500)
        )
        XCTAssertTrue(pressureReadCompleted)
        let pressureSampleCommitted = await eventually {
            await sleeper.requests().count == 2
        }
        XCTAssertTrue(pressureSampleCommitted)

        let state = await controller.currentState()
        XCTAssertEqual(state.latest?.timestamp, pressureTimestamp)
        XCTAssertEqual(state.latest?.pressure, .warning)
        XCTAssertEqual(state.latest?.estimatedUsedRatio, 0.7)
        XCTAssertEqual(state.latest?.pressureRatio, 0.42)
        XCTAssertEqual(state.history.map(\.pressure), [.unknown, .warning])

        await controller.stop()
        await pressureSource.finish()
    }
}
