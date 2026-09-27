import Combine
import Foundation
import ServiceManagement
import XCTest
import UsageButlerCore
import UsageButlerDomain
@testable import UsageButlerUI

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
    var registrationResult: SMAppService.Status = .enabled
    var registerCalls = 0
    var unregisterCalls = 0
    func register() throws { registerCalls += 1; status = registrationResult }
    func unregister() async throws {
        unregisterCalls += 1
        if failUnregister { throw ControllerTestError.failed }; status = .notRegistered
    }
}
private actor ControllerClient: BackgroundNetworkClient {
    let failStop: Bool
    let timeout: Bool
    let legacyQuery: Bool
    let wrongScope: Bool
    private(set) var lastQuery: BackgroundNetworkRequest?
    private(set) var requestCount = 0
    private(set) var lastRule: HistoryUploadRule?
    let stopEntered = ControllerGate(), stopRelease: ControllerGate?
    let pollEntered = ControllerGate(), pollRelease: ControllerGate?
    init(failStop: Bool = false, blockStop: Bool = false, blockPoll: Bool = false, timeout: Bool = false, legacyQuery: Bool = false, wrongScope: Bool = false) {
        self.timeout = timeout; self.legacyQuery = legacyQuery; self.wrongScope = wrongScope
        self.failStop = failStop; stopRelease = blockStop ? .init() : nil; pollRelease = blockPoll ? .init() : nil
    }
    func request(_ request: BackgroundNetworkRequest) async throws -> BackgroundNetworkResponse {
        requestCount += 1
        if request.operation == .updateRule { lastRule = request.rule }
        if timeout { throw BackgroundNetworkWire.Failure.timeout }
        if request.operation == .query, let range = request.range {
            lastQuery = request
            let typed = HistoryQueryRequest(range: range, applicationID: request.applicationID,
                applicationKey: request.selectedKey, page: request.page, eventKind: request.eventKind,
                search: wrongScope ? "ignored search" : request.search ?? "", context: request.queryContext)
            let history = HistoryQueryResult(range: range, applications: [], totalApplications: 0, page: request.page,
                curve: [], days: [], events: [], coverage: .init(), contract: legacyQuery ? nil : historyTestContract(typed))
            // Serialize/deserialize: optional new contract missing in an old v1
            // reply must not turn into a successful unfiltered query.
            return try JSONDecoder().decode(BackgroundNetworkResponse.self, from: JSONEncoder().encode(BackgroundNetworkResponse(history: history)))
        }
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
          applications: [:], sampledAt: Date(timeIntervalSince1970: 1_800_000_000), sampledMonotonic: .init(nanoseconds: 1_000_000_000), truncated: false, lostFrames: 0)
}
@MainActor
final class BackgroundNetworkControllerTests: XCTestCase {
    private func make(_ service: FakeHistoryRegistration, _ client: ControllerClient, seedSnapshot: Bool = true) -> (BackgroundNetworkController, BackgroundNetworkViewModel, ProcessNetworkViewModel) {
        let suite = "UsageButler.ControllerTest." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let model = BackgroundNetworkViewModel(), process = ProcessNetworkViewModel()
        if seedSnapshot { process.apply(controllerSnapshot()) }
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
                XCTAssertEqual(process.currentState, expected, "stopFail=\(stopFails), unregisterFail=\(unregisterFails)")
                if stopFails && unregisterFails {
                    XCTAssertNotNil(model.serviceIssue)
                    service.status = .requiresApproval
                    await controller.fetch()
                    XCTAssertEqual(process.currentState, .unavailable)
                }
                XCTAssertEqual(process.snapshot, controllerSnapshot(), "status must preserve original sample and timestamps")
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
        XCTAssertNotEqual(process.currentState, .stopped)
        XCTAssertEqual(model.status?.sourceState, .active)
        withExtendedLifetime(watch) {}; await controller.disconnect()
    }
    func testLatePollCannotOverwriteConfirmedStopOrDisconnectedController() async {
        for disconnect in [false, true] {
            let client = ControllerClient(blockPoll: true), service = FakeHistoryRegistration()
            let (controller, model, process) = make(service, client)
            let poll = Task { await controller.fetch() }; await client.pollEntered.wait()
            if disconnect { await controller.disconnect() } else { await controller.setEnabled(false) }
            let state = process.observationState, status = model.status
            await client.pollRelease?.release(); await poll.value
            XCTAssertEqual(process.observationState, state); XCTAssertEqual(model.status, status)
            await controller.disconnect()
        }
    }
}


extension BackgroundNetworkControllerTests {
    func testSettingsFieldsThroughActualSaveCallbackPreserveExactBytesInPreferencesAndRequest() async throws {
        let suite = "UsageButler.ExactRuleSave." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = BackgroundNetworkViewModel(), process = ProcessNetworkViewModel()
        let service = FakeHistoryRegistration(), client = ControllerClient()
        let controller = try XCTUnwrap(BackgroundNetworkController.constructForRuntime(model: model, process: process, defaults: defaults) { model, process, defaults in
            BackgroundNetworkController(model: model, process: process, defaults: defaults, service: service, client: client,
                databaseURL: URL(fileURLWithPath: "/nonexistent-rule-fixture/history.sqlite"),
                executable: URL(fileURLWithPath: "/nonexistent-rule-fixture/helper"), executableSHA256: "test", binding: "test")
        })
        let save = try XCTUnwrap(model.onRule)
        for bytes: UInt64 in [1_048_576, 1_048_577, 1_572_864, 104_857_600, 1_125_899_906_842_623, 1_125_899_906_842_624] {
            for edit in 0..<4 {
                var fields = HistoryUploadRuleFields(.init(largeBytes: bytes, sustainedSeconds: 5.5, sustainedBytesPerSecond: 1_536))
                if edit == 1 { fields.sustainedSeconds = "6.25" }
                if edit == 2 { fields.sustainedKiB = "2.5" }
                if edit == 3 { fields.largeMiB = "1.5" }
                let value = try XCTUnwrap(fields.parsedRule)
                try await save(value)
                let persisted = try JSONDecoder().decode(HistoryUploadRule.self, from: XCTUnwrap(defaults.data(forKey: "network.backgroundHistory.uploadRule")))
                let sent = await client.lastRule
                XCTAssertEqual(persisted, value); XCTAssertEqual(sent, value); XCTAssertEqual(model.configuredRule, value)
                XCTAssertEqual(value.largeBytes, edit == 3 ? 1_572_864 : bytes)
            }
        }
        XCTAssertEqual(service.registerCalls, 0); XCTAssertEqual(service.unregisterCalls, 0); XCTAssertNil(process.snapshot)
        await controller.disconnect()
    }

    func testRuntimeConstructionFailureSynchronizesBothPagesWithoutCreatingDataOrStartingAnything() async {
        let suite = "UsageButler.ConstructionFailure." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let service = FakeHistoryRegistration(), client = ControllerClient()
        let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent(".build/round02-construction-" + UUID().uuidString)
        for retained in [false, true] {
            let model = BackgroundNetworkViewModel(), process = ProcessNetworkViewModel()
            if retained { process.apply(controllerSnapshot()) }
            let prior = process.snapshot
            var attempts = 0
            let controller = BackgroundNetworkController.constructForRuntime(model: model, process: process, defaults: defaults) { _, _, _ in
                attempts += 1
                throw ControllerTestError.failed
            }
            XCTAssertNil(controller); XCTAssertEqual(attempts, 1)
            XCTAssertEqual(model.registration, "unavailable", "a generic construction error does not prove missing files")
            XCTAssertEqual(model.serviceIssue, "history.embedded-service-unavailable")
            XCTAssertEqual(process.observationState, .unavailable)
            XCTAssertEqual(process.snapshot, prior)
            if !retained { XCTAssertNil(process.snapshot); XCTAssertNil(process.snapshotForExport) }
            XCTAssertNil(model.status); XCTAssertNil(model.onEnabled); XCTAssertNil(model.onQuery)
            XCTAssertNil(defaults.persistentDomain(forName: suite))
            XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
        }
        XCTAssertEqual(service.registerCalls, 0); XCTAssertEqual(service.unregisterCalls, 0)
        let requests = await client.requestCount; XCTAssertEqual(requests, 0)
    }

    func testRuntimeConstructionSuccessRemainsColdThenApprovalOrFirstSnapshotWorks() async throws {
        for approval in [false, true] {
            let suite = "UsageButler.ConstructionSuccess." + UUID().uuidString
            let defaults = UserDefaults(suiteName: suite)!
            defer { defaults.removePersistentDomain(forName: suite) }
            let model = BackgroundNetworkViewModel(), process = ProcessNetworkViewModel()
            let service = FakeHistoryRegistration(), client = ControllerClient()
            if approval { service.status = .requiresApproval }
            let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent().appendingPathComponent(".build/round02-construction-" + UUID().uuidString)
            let controller = try XCTUnwrap(BackgroundNetworkController.constructForRuntime(model: model, process: process, defaults: defaults) { model, process, defaults in
                BackgroundNetworkController(model: model, process: process, defaults: defaults, service: service, client: client,
                    databaseURL: directory.appendingPathComponent("history.sqlite"), executable: directory.appendingPathComponent("helper"),
                    executableSHA256: "test", binding: "test", replyValidator: { _ in })
            })
            XCTAssertEqual(process.observationState, .connecting); XCTAssertNil(process.snapshot)
            XCTAssertNil(model.serviceIssue); XCTAssertEqual(service.registerCalls, 0)
            let initialRequests = await client.requestCount; XCTAssertEqual(initialRequests, 0)
            XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
            await controller.setEnabled(true); await controller.fetch()
            if approval {
                XCTAssertEqual(model.registration, "requiresApproval")
                XCTAssertEqual(process.observationState, .requiresApproval); XCTAssertNil(process.snapshot)
            } else {
                XCTAssertEqual(process.observationState, .observing(.active))
                XCTAssertEqual(process.snapshot, controllerSnapshot())
            }
            XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
            await controller.disconnect()
        }
    }

    func testColdApprovalNotFoundTimeoutAndConfirmedUnregisteredStatesWithoutInventedSnapshot() async {
        for (registration, timeout, expected) in [
            (SMAppService.Status.requiresApproval, false, ProcessNetworkViewModel.ObservationState.requiresApproval),
            (.notFound, false, .notFound), (.enabled, true, .unavailable), (.notRegistered, false, .stopped)
        ] {
            let service = FakeHistoryRegistration(); service.status = registration; service.registrationResult = registration
            let (controller, model, process) = make(service, ControllerClient(timeout: timeout), seedSnapshot: false)
            XCTAssertNil(process.snapshot); XCTAssertEqual(process.observationState, .connecting)
            await controller.setEnabled(registration != .notRegistered)
            XCTAssertNil(process.snapshot); XCTAssertEqual(process.observationState, expected)
            await controller.fetch()
            XCTAssertNil(process.snapshot); XCTAssertEqual(process.observationState, expected)
            if registration != .notRegistered { XCTAssertFalse(process.observationTitle.contains("已停止")) }
            if timeout { XCTAssertNotNil(model.serviceIssue) }
            await controller.disconnect()
        }
    }
    func testColdFirstSuccessfulSnapshotAndUnconfirmedStop() async {
        let service = FakeHistoryRegistration()
        let (controller, _, process) = make(service, ControllerClient(), seedSnapshot: false)
        await controller.setEnabled(true)
        XCTAssertNil(process.snapshot); XCTAssertEqual(process.observationState, .connecting)
        await controller.fetch()
        XCTAssertEqual(process.snapshot, controllerSnapshot()); XCTAssertEqual(process.observationState, .observing(.active))
        await controller.disconnect()
        let failedService = FakeHistoryRegistration(); failedService.failUnregister = true
        let client = ControllerClient(failStop: true, blockStop: true)
        let (failed, _, cold) = make(failedService, client, seedSnapshot: false)
        let stopping = Task { await failed.setEnabled(false) }; await client.stopEntered.wait()
        XCTAssertNil(cold.snapshot); XCTAssertNotEqual(cold.observationState, .stopped)
        await client.stopRelease?.release(); await stopping.value
        XCTAssertNil(cold.snapshot); XCTAssertEqual(cold.observationState, .unavailable)
        await failed.disconnect()
    }
    func testQueryRejectsOldOrDifferentScopeResponseAndForwardsProtectedRequest() async throws {
        let range = HistoryRange.recent(days: 7)
        for (legacy, wrong) in [(true, false), (false, true), (false, false)] {
            let client = ControllerClient(legacyQuery: legacy, wrongScope: wrong)
            let (controller, model, _) = make(FakeHistoryRegistration(), client, seedSnapshot: false)
            let request = HistoryQueryRequest(range: range, applicationKey: "synthetic-key", eventKind: "large", search: "needle")
            let call = try XCTUnwrap(model.onQuery)
            do {
                let first = try await call(request)
                XCTAssertFalse(legacy || wrong); XCTAssertTrue(first.satisfies(request))
                let secondRequest = HistoryQueryRequest(range: range, applicationKey: "synthetic-key", page: 1,
                    eventKind: "large", search: "needle", context: first.contract?.context)
                let second = try await call(secondRequest)
                XCTAssertTrue(second.satisfies(secondRequest))
                let sent = await client.lastQuery
                XCTAssertEqual(sent?.selectedKey, "synthetic-key"); XCTAssertEqual(sent?.search, "needle")
                XCTAssertEqual(sent?.eventKind, "large"); XCTAssertEqual(sent?.queryContext, first.contract?.context)
            } catch {
                XCTAssertTrue(legacy || wrong); XCTAssertEqual(error as? HistoryQueryFailure, .incompatible)
            }
            await controller.disconnect()
        }
    }
}
