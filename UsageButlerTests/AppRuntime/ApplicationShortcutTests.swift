import XCTest
import Carbon.HIToolbox
import UsageButlerCore

@MainActor
private final class FakeApplicationHotkeys: ApplicationHotkeyRegistering {
    var handler: ((UInt32, UInt32) -> Bool)?
    var installStatus: OSStatus = noErr
    var registerFailures: [UInt32: OSStatus] = [:]
    var unregisterFailures: [UInt32: OSStatus] = [:]
    var registered: [UInt32: GlobalShortcut] = [:]
    var attempts: [UInt32] = []
    var installCount = 0
    var removeCount = 0
    func installHandler(_ route: @escaping (UInt32, UInt32) -> Bool) -> OSStatus {
        installCount += 1
        if installStatus == noErr { handler = route }
        return installStatus
    }
    func register(_ shortcut: GlobalShortcut, signature: UInt32, id: UInt32) -> OSStatus {
        XCTAssertEqual(signature, ApplicationShortcutController.signature)
        attempts.append(id)
        if let error = registerFailures[id] { return error }
        XCTAssertNil(registered[id], "No duplicate registration")
        registered[id] = shortcut; return noErr
    }
    func unregister(id: UInt32) -> OSStatus {
        if let error = unregisterFailures[id] { return error }
        registered[id] = nil; return noErr
    }
    func removeHandler() -> OSStatus { removeCount += 1; handler = nil; return noErr }
}

@MainActor
final class ApplicationShortcutTests: XCTestCase {
    private let panel = GlobalShortcut(keyCode: 35, modifiers: [.command, .option])

    func testSettingsRegistersAtStartupWithoutAnyPanelShortcutOrWindow() {
        let os = FakeApplicationHotkeys(); var panelCalls = 0, settingsCalls = 0
        let controller = ApplicationShortcutController(registrar: os, onPanel: { panelCalls += 1 },
            onSettings: { settingsCalls += 1 }, report: { _, _ in })
        controller.start(panelShortcut: nil)
        let shortcut = os.registered[ApplicationShortcutController.settingsID]
        XCTAssertEqual(shortcut?.keyCode, 43)
        XCTAssertEqual(shortcut?.keyCode, UInt32(kVK_ANSI_Comma))
        XCTAssertEqual(shortcut?.carbonModifiers, UInt32(cmdKey | shiftKey))
        XCTAssertEqual(shortcut?.modifiers, [.command, .shift])
        XCTAssertTrue(os.handler?(ApplicationShortcutController.signature, ApplicationShortcutController.settingsID) == true)
        XCTAssertEqual(settingsCalls, 1); XCTAssertEqual(panelCalls, 0)
        XCTAssertFalse(controller.route(signature: ApplicationShortcutController.signature, id: ApplicationShortcutController.panelID))
    }

    func testCarbonEventPayloadRoutesTheTwoIDsIndependentlyAndRejectsForeignEvents() throws {
        let os = FakeApplicationHotkeys(); var calls: [String] = []
        let controller = ApplicationShortcutController(registrar: os, onPanel: { calls.append("panel") },
            onSettings: { calls.append("settings") }, report: { _, _ in })
        controller.start(panelShortcut: panel)
        let cases: [(UInt32, UInt32, OSStatus)] = [
            (ApplicationShortcutController.signature, 2, noErr),
            (ApplicationShortcutController.signature, 1, noErr),
            (ApplicationShortcutController.signature, 3, OSStatus(eventNotHandledErr)),
            (0x1111_1111, 1, OSStatus(eventNotHandledErr))
        ]
        for (signature, id, expected) in cases {
            var value: EventRef?
            XCTAssertEqual(CreateEvent(nil, OSType(kEventClassKeyboard), UInt32(kEventHotKeyPressed), 0, 0, &value), noErr)
            let event = try XCTUnwrap(value); defer { ReleaseEvent(event) }
            var payload = EventHotKeyID(signature: signature, id: id)
            XCTAssertEqual(SetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                MemoryLayout<EventHotKeyID>.size, &payload), noErr)
            XCTAssertEqual(CarbonApplicationHotkeys.dispatch(event, route: controller.route), expected)
        }
        XCTAssertEqual(calls, ["settings", "panel"])
        var missing: EventRef?
        XCTAssertEqual(CreateEvent(nil, OSType(kEventClassKeyboard), UInt32(kEventHotKeyPressed), 0, 0, &missing), noErr)
        let event = try XCTUnwrap(missing); defer { ReleaseEvent(event) }
        XCTAssertNotEqual(CarbonApplicationHotkeys.dispatch(event, route: controller.route), noErr)
        XCTAssertEqual(calls, ["settings", "panel"])
    }

    func testChangingAndClearingPanelDoesNotReregisterOrRouteToSettings() {
        let os = FakeApplicationHotkeys()
        let controller = ApplicationShortcutController(registrar: os, onPanel: {}, onSettings: {}, report: { _, _ in })
        controller.start(panelShortcut: panel)
        controller.start(panelShortcut: panel)
        controller.applyPanelShortcut(.init(keyCode: 12, modifiers: [.control]))
        controller.applyPanelShortcut(nil)
        XCTAssertEqual(os.installCount, 1)
        XCTAssertEqual(os.attempts.filter { $0 == ApplicationShortcutController.settingsID }.count, 1)
        XCTAssertEqual(os.registered.count, 1)
        XCTAssertNotNil(os.registered[ApplicationShortcutController.settingsID])
    }

    func testStoredPanelCollisionKeepsItsExactConfigurationAndRecoversWhenCleared() {
        for extras: UInt in [0, 1 << 16] {
            let os = FakeApplicationHotkeys(); var panelCalls = 0, settingsCalls = 0
            let stored = GlobalShortcut(keyCode: 43, modifiers: .init(rawValue:
                ShortcutModifiers([.command, .shift]).rawValue | extras))
            let serialized = stored.serialized
            let controller = ApplicationShortcutController(registrar: os, onPanel: { panelCalls += 1 },
                onSettings: { settingsCalls += 1 }, report: { _, _ in })
            controller.start(panelShortcut: stored)
            XCTAssertEqual(os.registered[ApplicationShortcutController.panelID]?.serialized, serialized)
            XCTAssertNil(os.registered[ApplicationShortcutController.settingsID])
            XCTAssertTrue(controller.settingsIssue?.contains("冲突") == true)
            XCTAssertTrue(controller.route(signature: ApplicationShortcutController.signature, id: 1))
            XCTAssertFalse(controller.route(signature: ApplicationShortcutController.signature, id: 2))
            XCTAssertEqual(panelCalls, 1); XCTAssertEqual(settingsCalls, 0)
            controller.applyPanelShortcut(nil)
            XCTAssertNil(controller.settingsIssue)
            XCTAssertNotNil(os.registered[ApplicationShortcutController.settingsID])
        }
    }

    func testSettingsRegistrationFailureIsVisibleAndDoesNotDisablePanel() {
        let os = FakeApplicationHotkeys(); os.registerFailures[2] = -9878
        var report: String?
        let controller = ApplicationShortcutController(registrar: os, onPanel: {}, onSettings: { XCTFail("unregistered route") },
            report: { _, settings in report = settings })
        controller.start(panelShortcut: panel)
        XCTAssertTrue(report?.contains("-9878") == true)
        XCTAssertNotNil(os.registered[1]); XCTAssertNil(os.registered[2])
        XCTAssertFalse(controller.route(signature: ApplicationShortcutController.signature, id: 2))
        os.registerFailures[2] = nil
        controller.applyPanelShortcut(panel)
        XCTAssertNil(report); XCTAssertNotNil(os.registered[2])
    }

    func testFailedEventHandlerNeverClaimsOrRegistersEitherShortcut() {
        let os = FakeApplicationHotkeys(); os.installStatus = -50
        let controller = ApplicationShortcutController(registrar: os, onPanel: {}, onSettings: {}, report: { _, _ in })
        controller.start(panelShortcut: panel)
        XCTAssertTrue(os.attempts.isEmpty)
        XCTAssertTrue(controller.panelIssue?.contains("-50") == true)
        XCTAssertTrue(controller.settingsIssue?.contains("-50") == true)
        XCTAssertFalse(controller.route(signature: ApplicationShortcutController.signature, id: 2))
    }

    func testPanelFailureDoesNotConsumeSettingsAndFailedUnregisterKeepsOldRoute() {
        let os = FakeApplicationHotkeys(); os.registerFailures[1] = -50
        let controller = ApplicationShortcutController(registrar: os, onPanel: {}, onSettings: {}, report: { _, _ in })
        controller.start(panelShortcut: panel)
        XCTAssertTrue(controller.panelIssue?.contains("-50") == true)
        XCTAssertNotNil(os.registered[2])
        os.registerFailures[1] = nil
        controller.applyPanelShortcut(panel)
        os.unregisterFailures[1] = -50
        controller.applyPanelShortcut(nil)
        XCTAssertEqual(os.registered[1], panel)
        XCTAssertTrue(controller.panelIssue?.contains("旧注册仍保留") == true)
        XCTAssertTrue(controller.route(signature: ApplicationShortcutController.signature, id: 1))
    }

    func testTransitionToConflictingPanelAndTerminationReleaseTheOwnedRegistrations() {
        let os = FakeApplicationHotkeys()
        let controller = ApplicationShortcutController(registrar: os, onPanel: {}, onSettings: {}, report: { _, _ in })
        controller.start(panelShortcut: panel)
        controller.applyPanelShortcut(ApplicationShortcutController.settingsShortcut)
        XCTAssertEqual(os.registered[1], ApplicationShortcutController.settingsShortcut)
        XCTAssertNil(os.registered[2]); XCTAssertNotNil(controller.settingsIssue)
        controller.stop(); controller.stop()
        XCTAssertTrue(os.registered.isEmpty); XCTAssertEqual(os.removeCount, 1)
        XCTAssertFalse(controller.route(signature: ApplicationShortcutController.signature, id: 1))
        XCTAssertFalse(controller.route(signature: ApplicationShortcutController.signature, id: 2))
    }
}

@MainActor
private final class FakeSettingsWindow: SettingsWindowPresenting {
    var hasSettingsContent = true
    var frontCount = 0
    func bringSettingsForward() { frontCount += 1 }
}

@MainActor
final class SettingsPresentationBridgeTests: XCTestCase {
    func testFirstRequestBeforeSceneInstallIsRetainedAndRepeatedRequestsCoalesce() {
        var queue: [@MainActor () -> Void] = []; var opens = 0, activations = 0; var issue: String?
        let bridge = SettingsPresentationBridge(activate: { activations += 1 }, enqueue: { queue.append($0) }, report: { issue = $0 })
        XCTAssertEqual(bridge.requestOpen(), .waitingForScene)
        XCTAssertEqual(bridge.requestOpen(), .waitingForScene)
        XCTAssertNotNil(issue); XCTAssertTrue(queue.isEmpty)
        bridge.install { opens += 1; return true }
        bridge.install { opens += 1; return true }
        XCTAssertEqual(bridge.requestOpen(), .coalesced)
        XCTAssertEqual(queue.count, 1)
        queue.removeFirst()()
        XCTAssertEqual(opens, 1); XCTAssertEqual(activations, 1); XCTAssertNil(issue)
    }

    func testExistingSettingsWindowIsBroughtForwardWithoutCreatingOrTogglingIt() {
        var queue: [@MainActor () -> Void] = []; var opens = 0, activations = 0
        let bridge = SettingsPresentationBridge(activate: { activations += 1 }, enqueue: { queue.append($0) }, report: { _ in })
        let window = FakeSettingsWindow()
        bridge.install { opens += 1; return true }
        bridge.track(window)
        for _ in 0..<3 { bridge.requestOpen(); queue.removeFirst()() }
        XCTAssertEqual(window.frontCount, 3); XCTAssertEqual(opens, 0); XCTAssertEqual(activations, 3)
        window.hasSettingsContent = false
        bridge.requestOpen(); queue.removeFirst()()
        XCTAssertEqual(opens, 1)
    }

    func testUnavailableOpeningActionIsReportedAndNextRequestCanRetry() {
        var queue: [@MainActor () -> Void] = []; var issue: String?
        let bridge = SettingsPresentationBridge(activate: {}, enqueue: { queue.append($0) }, report: { issue = $0 })
        bridge.install { false }
        bridge.requestOpen(); queue.removeFirst()()
        XCTAssertTrue(issue?.contains("不可用") == true)
        bridge.install { true }
        bridge.requestOpen(); queue.removeFirst()()
        XCTAssertNil(issue)
    }

    func testTerminationInvalidatesAnAlreadyEnqueuedOpen() {
        var queue: [@MainActor () -> Void] = []; var opens = 0, activations = 0
        let bridge = SettingsPresentationBridge(activate: { activations += 1 }, enqueue: { queue.append($0) }, report: { _ in })
        bridge.install { opens += 1; return true }
        bridge.requestOpen(); bridge.invalidate(); queue.removeFirst()()
        XCTAssertEqual(opens, 0); XCTAssertEqual(activations, 0)
    }
}
