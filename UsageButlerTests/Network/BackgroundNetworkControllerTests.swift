import Combine
import Foundation
import ServiceManagement
import XCTest
import UsageButlerCore
import UsageButlerDomain
import UsageButlerUI

private actor ControllerGate {
    private var open = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async { if !open { await withCheckedContinuation { waiters.append($0) } } }
    func release() { open = true; let all = waiters; waiters.removeAll(); all.forEach { $0.resume() } }
}
private enum ControllerTestError: Error { case failed }
@MainActor
private final class FakeHistoryRegistration: BackgroundNetworkRegistration {
    var status: SMAppService.Status = .enabled
    var failUnregister = false
    func register() throws { status = .enabled }
    func unregister() async throws {
        if failUnregister { throw ControllerTestError.failed }; status = .notRegistered
    }
}
private actor ControllerClient: BackgroundNetworkClient {
    let failStop: Bool
    let stopEntered = ControllerGate(), stopRelease: ControllerGate?
    let pollEntered = ControllerGate(), pollRelease: ControllerGate?
    init(failStop: Bool = false, blockStop: Bool = false, blockPoll: Bool = false) {
        self.failStop = failStop; stopRelease = blockStop ? .init() : nil; pollRelease = blockPoll ? .init() : nil
    }
    func request(_ request: BackgroundNetworkRequest) async throws -> BackgroundNetworkResponse {
        if request.operation == .stop {
            await stopEntered.release(); await stopRelease?.wait()
            if failStop { throw ControllerTestError.failed }
        }
        if request.operation == .snapshot { await pollEntered.release(); await pollRelease?.wait() }
        let state: ProcessNetworkState = request.operation == .stop ? .stopped : .active
        return .init(status: .init(version: BackgroundNetworkWire.version, pid: 1, executableSHA256: "test",
            sqliteVersion: "test", sqliteSourceID: "test", startedAt: Date(timeIntervalSince1970: 0),
            sourceState: state, sourceIssue: nil, coverage: .init(), rule: .init()),
            snapshot: request.operation == .snapshot ? controllerSnapshot() : nil)
    }
    func disconnect() async {}
}
private func controllerSnapshot() -> ProcessNetworkSnapshot {
    .init(sessionID: .init(rawValue: "controller-test"), sequence: 1, state: .active, issue: nil,
          applications: [:], sampledAt: nil, sampledMonotonic: nil, truncated: false, lostFrames: 0)
}
@MainActor
final class BackgroundNetworkControllerTests: XCTestCase {
    private func make(_ service: FakeHistoryRegistration, _ client: ControllerClient) -> (BackgroundNetworkController, BackgroundNetworkViewModel, ProcessNetworkViewModel) {
        let suite = "UsageButler.ControllerTest." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let model = BackgroundNetworkViewModel(), process = ProcessNetworkViewModel(); process.apply(controllerSnapshot())
        let controller = BackgroundNetworkController(model: model, process: process, defaults: defaults, service: service,
            client: client, databaseURL: URL(fileURLWithPath: "/nonexistent-controller-fixture/history.sqlite"),
            executable: URL(fileURLWithPath: "/nonexistent-controller-fixture/helper"), executableSHA256: "test", binding: "test",
            replyValidator: { status in guard status != nil else { throw ControllerTestError.failed } })
        return (controller, model, process)
    }
    func testStopConfirmationMatrixAndPollDoesNotInferStopFromIntent() async {
        for stopFails in [false, true] {
            for unregisterFails in [false, true] {
                let service = FakeHistoryRegistration(); service.failUnregister = unregisterFails
                let (controller, model, process) = make(service, ControllerClient(failStop: stopFails))
                await controller.setEnabled(false)
                XCTAssertFalse(model.desired); XCTAssertFalse(model.changing)
                let expected: ProcessNetworkState = stopFails && unregisterFails ? .unavailable : .stopped
                XCTAssertEqual(process.snapshot?.state, expected, "stopFail=\(stopFails), unregisterFail=\(unregisterFails)")
                if stopFails && unregisterFails {
                    XCTAssertNotNil(model.serviceIssue)
                    service.status = .requiresApproval
                    await controller.fetch()
                    XCTAssertEqual(process.snapshot?.state, .unavailable)
                }
                await controller.disconnect()
            }
        }
    }
    func testLateFailedStopCannotOverwriteNewEnableIntent() async {
        let service = FakeHistoryRegistration(); service.failUnregister = true
        let client = ControllerClient(failStop: true, blockStop: true)
        let (controller, model, process) = make(service, client)
        let old = Task { await controller.setEnabled(false) }
        await client.stopEntered.wait()
        let enabled = expectation(description: "new enable accepted")
        let watch = model.$desired.dropFirst().filter { $0 }.sink { _ in enabled.fulfill() }
        let new = Task { await controller.setEnabled(true) }
        await fulfillment(of: [enabled], timeout: 2)
        await client.stopRelease?.release(); await old.value; await new.value
        XCTAssertTrue(model.desired); XCTAssertNil(model.serviceIssue)
        XCTAssertNotEqual(process.snapshot?.state, .stopped)
        XCTAssertEqual(model.status?.sourceState, .active)
        withExtendedLifetime(watch) {}; await controller.disconnect()
    }
    func testLatePollCannotOverwriteConfirmedStopOrDisconnectedController() async {
        for disconnect in [false, true] {
            let client = ControllerClient(blockPoll: true), service = FakeHistoryRegistration()
            let (controller, model, process) = make(service, client)
            let poll = Task { await controller.fetch() }; await client.pollEntered.wait()
            if disconnect { await controller.disconnect() } else { await controller.setEnabled(false) }
            let state = process.snapshot?.state, status = model.status
            await client.pollRelease?.release(); await poll.value
            XCTAssertEqual(process.snapshot?.state, state); XCTAssertEqual(model.status, status)
            await controller.disconnect()
        }
    }
}
