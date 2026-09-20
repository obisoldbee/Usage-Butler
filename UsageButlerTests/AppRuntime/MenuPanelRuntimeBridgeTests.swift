import Combine
import Foundation
import XCTest
@testable import UsageButlerCore
@testable import UsageButlerDomain
@testable import UsageButlerUI

@MainActor
final class MenuPanelRuntimeBridgeTests: XCTestCase {
    private let fixedNow = Date(timeIntervalSince1970: 1_786_400_000)

    func testMemoryDefaultsToOneMinuteComparableWindow() {
        let model = makeModel(projections: [])

        XCTAssertEqual(model.memoryRange, .oneMinute)
        XCTAssertEqual(MemoryRange.oneMinute.interval, 60)
        XCTAssertEqual(
            MemoryRange.allCases,
            [.oneMinute, .tenMinutes, .thirtyMinutes, .oneHour, .twoHours]
        )
    }

    func testControllerProjectionSeparatesSettingsPresenceFromQuotaVisibility() {
        let initial = makeProjection(providerID: .openAI, enabled: true)
        let model = makeModel(projections: [initial])

        XCTAssertEqual(model.snapshot.providers.map(\.id), [.openAI])
        XCTAssertEqual(model.settingsProviders.map(\.id), [.openAI])
        #if USAGE_BUTLER_FIXTURES
        XCTAssertFalse(model.isFixtureMode)
        #endif

        model.applyProviderProjection(
            ProviderProjection(
                revision: 1,
                isEnabled: false,
                phase: .running,
                state: initial.state
            ),
            now: fixedNow
        )

        XCTAssertTrue(model.snapshot.providers.isEmpty)
        XCTAssertEqual(model.settingsProviders.map(\.id), [.openAI])
        XCTAssertEqual(model.settingsProviders.first?.rowState, .detecting)
    }

    func testRuntimeBootstrapMemoryRendersSevenUnknownValuesWithoutFixtureOrigin() {
        let model = makeModel(projections: [])

        XCTAssertEqual(model.snapshot.memory.origin, .runtime)
        #if USAGE_BUTLER_FIXTURES
        XCTAssertFalse(model.isFixtureMode)
        #endif
        XCTAssertEqual(
            MemoryFieldPresentation.orderedFieldIDs,
            [
                .physical,
                .used,
                .cachedFiles,
                .swapUsed,
                .appMemory,
                .wired,
                .compressed
            ]
        )
        XCTAssertTrue(
            MemoryFieldPresentation.orderedFieldIDs.allSatisfy { _ in
                MemoryFieldPresentation.value(bytes: nil) == "—"
            }
        )
    }

    func testCyclePageRotatesThroughQuotaMemoryAndNetwork() {
        let model = makeModel(projections: [])
        var visibilityUpdates: [Bool] = []
        let cancellable = model.$selectedPage
            .dropFirst()
            .map { $0 == .memory }
            .sink { visibilityUpdates.append($0) }

        XCTAssertEqual(model.selectedPage, .quota)
        model.cyclePage()
        XCTAssertEqual(model.selectedPage, .memory)
        model.cyclePage()
        XCTAssertEqual(model.selectedPage, .network)
        model.cyclePage()
        XCTAssertEqual(model.selectedPage, .quota)
        XCTAssertEqual(visibilityUpdates, [true, false, false])
        _ = cancellable
    }

    func testGlobalShortcutPlumbingForwardsAndPublishesText() {
        let model = makeModel(projections: [])
        var forwarded: [String?] = []
        model.configureRuntimeActions(
            onPanelPresented: {},
            onManualRefresh: {},
            onSetProviderEnabled: { _, _ in },
            onSetGlobalRefreshFrequency: { _ in },
            onSetProviderRefreshOverride: { _, _ in },
            onRedetectProvider: { _ in },
            onLoginProvider: { _, _ in .failed },
            onSelectProviderExecutable: { _ in .failed },
            onClearQuotaCache: { .failed },
            onLoadSafeDiagnostics: { .failed(.actionUnavailable) },
            onMemoryPageVisibilityChanged: { _ in },
            onSetGlobalShortcut: { forwarded.append($0) }
        )

        XCTAssertNil(model.globalShortcutText)
        let shortcut = GlobalShortcut(keyCode: 32, modifiers: [.command, .option])
        model.setGlobalShortcut(shortcut.serialized)
        model.setGlobalShortcut(nil)
        XCTAssertEqual(forwarded, [shortcut.serialized, nil])
        model.updateGlobalShortcutText(shortcut.displayText)
        XCTAssertEqual(model.globalShortcutText, "⌥⌘U")
    }

    func testRuntimeActionsForwardManualRefreshToggleRedetectClearAndMemoryPolicy() async {
        let model = makeModel(projections: [
            makeProjection(providerID: .openAI, enabled: true)
        ])
        let refresh = expectation(description: "manual refresh")
        let panelPresented = expectation(description: "panel presented")
        let login = expectation(description: "provider login")
        let clear = expectation(description: "clear cache")
        let executableSelection = expectation(description: "select executable")
        var toggles: [(ProviderID, Bool)] = []
        var globalFrequencies: [ProviderRefreshFrequency] = []
        var providerOverrides: [(ProviderID, ProviderRefreshOverride)] = []
        var redetections: [ProviderID] = []
        var memoryVisibility: [Bool] = []

        model.configureRuntimeActions(
            onPanelPresented: {
                panelPresented.fulfill()
            },
            onManualRefresh: {
                refresh.fulfill()
            },
            onSetProviderEnabled: { providerID, enabled in
                toggles.append((providerID, enabled))
            },
            onSetGlobalRefreshFrequency: { frequency in
                globalFrequencies.append(frequency)
            },
            onSetProviderRefreshOverride: { providerID, override in
                providerOverrides.append((providerID, override))
            },
            onRedetectProvider: { providerID in
                redetections.append(providerID)
            },
            onLoginProvider: { providerID, request in
                XCTAssertEqual(providerID, .ark)
                XCTAssertEqual(request, .start)
                login.fulfill()
                return .verifiedFresh
            },
            onSelectProviderExecutable: { providerID in
                XCTAssertEqual(providerID, .miniMax)
                executableSelection.fulfill()
                return .savedRequiresRelaunch
            },
            onClearQuotaCache: {
                clear.fulfill()
                return .completed
            },
            onLoadSafeDiagnostics: {
                .loaded([])
            },
            onMemoryPageVisibilityChanged: { isVisible in
                memoryVisibility.append(isVisible)
            }
        )

        model.panelPresented()
        model.requestManualRefresh()
        model.setProviderEnabled(.miniMax, enabled: false)
        model.setGlobalRefreshFrequency(.fifteenMinutes)
        model.setProviderRefreshOverride(.ark, override: .frequency(.manualOnly))
        model.redetectProvider(.ark)
        model.selectedPage = .memory
        let loginResult = await model.loginProvider(.ark, request: .start)
        let executableSelectionResult = await model.selectProviderExecutable(.miniMax)
        let clearResult = await model.clearQuotaCache()

        await fulfillment(
            of: [panelPresented, refresh, login, executableSelection, clear],
            timeout: 1
        )
        await Task.yield()

        XCTAssertEqual(clearResult, .completed)
        XCTAssertEqual(loginResult, .verifiedFresh)
        XCTAssertEqual(executableSelectionResult, .savedRequiresRelaunch)
        XCTAssertEqual(toggles.count, 1)
        XCTAssertEqual(toggles.first?.0, .miniMax)
        XCTAssertEqual(toggles.first?.1, false)
        XCTAssertEqual(globalFrequencies, [.fifteenMinutes])
        XCTAssertEqual(providerOverrides.count, 1)
        XCTAssertEqual(providerOverrides.first?.0, .ark)
        XCTAssertEqual(providerOverrides.first?.1, .frequency(.manualOnly))
        XCTAssertEqual(redetections, [.ark])
        XCTAssertEqual(memoryVisibility, [false, true])
        XCTAssertFalse(model.isManualRefreshInFlight)
    }

    func testSafeDiagnosticsLoadUsesCanonicalOrderSortedFieldsAndSafeDTO() async throws {
        let model = makeModel(projections: [])
        configureDiagnostics(model) {
            .loaded([
                SafeProviderDiagnostic(
                    providerID: .ark,
                    capturedAt: self.fixedNow,
                    diagnosticCode: "ark.adapter.safe_snapshot",
                    safeFields: ["schema": "ark-v1:valid"]
                ),
                SafeProviderDiagnostic(
                    providerID: .openAI,
                    capturedAt: self.fixedNow,
                    diagnosticCode: "openai.read.success",
                    safeFields: [
                        "valid_bucket_count": "2",
                        "last_outcome": "success",
                        "source_identity_valid": "true",
                        "raw_payload": "fixture-raw-placeholder",
                        "account_email": "person@example.invalid",
                        "proxy": "http://localhost:8080",
                        "executable_path": "/tmp/example-cli",
                        "viewer": "opaque-user-123",
                        "seat_id": "opaque-seat-456"
                    ]
                ),
                SafeProviderDiagnostic(
                    providerID: .miniMax,
                    capturedAt: self.fixedNow,
                    diagnosticCode: "minimax.adapter.safe_snapshot",
                    safeFields: ["adapter": "minimax.mmx.v1"]
                )
            ])
        }

        await model.loadSafeDiagnostics()

        guard case let .loaded(diagnostics) = model.safeDiagnosticsState else {
            return XCTFail("Expected loaded safe diagnostics")
        }
        XCTAssertEqual(diagnostics.map(\.providerID), [.openAI, .miniMax, .ark])
        XCTAssertEqual(
            diagnostics.map { ProviderPresentation.cliName(for: $0.providerID) },
            ["codex", "mmx", "arkcli"]
        )
        let openAI = try XCTUnwrap(diagnostics.first)
        XCTAssertEqual(openAI.diagnosticCode, "openai.read.success")
        XCTAssertEqual(
            openAI.safeFields.map(\.key),
            ["last_outcome", "source_identity_valid", "valid_bucket_count"]
        )
        XCTAssertEqual(openAI.safeFields.map(\.value), ["success", "true", "2"])
    }

    func testRepeatedSafeDiagnosticsLoadCoalescesWhileLoading() async {
        let model = makeModel(projections: [])
        let gate = SafeDiagnosticsLoadGate()
        configureDiagnostics(model) {
            await gate.load()
        }

        let first = Task { @MainActor in
            await model.loadSafeDiagnostics()
        }
        for _ in 0..<100 {
            if await gate.calls() > 0 { break }
            await Task.yield()
        }
        let callsAfterFirstRequest = await gate.calls()
        XCTAssertEqual(callsAfterFirstRequest, 1)
        XCTAssertEqual(model.safeDiagnosticsState, .loading)

        await model.loadSafeDiagnostics()
        let callsAfterRepeatedRequest = await gate.calls()
        XCTAssertEqual(callsAfterRepeatedRequest, 1)

        await gate.resume(with: .loaded([]))
        await first.value
        XCTAssertEqual(model.safeDiagnosticsState, .loaded([]))
    }

    func testSafeDiagnosticsUnavailableAndFailedRemainTypedStates() async {
        let model = makeModel(projections: [])
        configureDiagnostics(model) {
            .unavailable(.runtimeCompositionUnavailable)
        }
        await model.loadSafeDiagnostics()
        XCTAssertEqual(
            model.safeDiagnosticsState,
            .unavailable(.runtimeCompositionUnavailable)
        )

        configureDiagnostics(model) {
            .failed(.runtimeShuttingDown)
        }
        await model.loadSafeDiagnostics()
        XCTAssertEqual(
            model.safeDiagnosticsState,
            .failed(.runtimeShuttingDown)
        )
    }

    func testLarkQuotaAlertChannelStatusLoadsThroughRuntimeBridge() async {
        let model = makeModel(projections: [])
        configureDiagnostics(
            model,
            larkStatusLoader: { .ready }
        ) {
            .loaded([])
        }

        XCTAssertEqual(model.larkQuotaAlertChannelStatus, .notChecked)
        await model.loadLarkQuotaAlertChannelStatus()
        XCTAssertEqual(model.larkQuotaAlertChannelStatus, .ready)

        configureDiagnostics(
            model,
            larkStatusLoader: { .needsSetup }
        ) {
            .loaded([])
        }
        await model.loadLarkQuotaAlertChannelStatus()
        XCTAssertEqual(model.larkQuotaAlertChannelStatus, .needsSetup)

        configureDiagnostics(
            model,
            larkStatusLoader: { .needsChatID }
        ) {
            .loaded([])
        }
        await model.loadLarkQuotaAlertChannelStatus()
        XCTAssertEqual(model.larkQuotaAlertChannelStatus, .needsChatID)
    }

    #if USAGE_BUTLER_FIXTURES
    func testFixtureVisibilityToggleDoesNotRemoveSettingsProvider() {
        let model = MenuPanelViewModel(
            snapshot: Stage3FixtureCatalog.projection(
                scenario: .firstRunDetecting,
                now: fixedNow
            )
        )

        model.applyFixtureProviderVisibility(.miniMax, enabled: false)

        XCTAssertFalse(model.snapshot.providers.contains { $0.id == .miniMax })
        XCTAssertTrue(model.settingsProviders.contains { $0.id == .miniMax })
        XCTAssertTrue(model.isFixtureMode)

        model.refreshPreview(now: fixedNow.addingTimeInterval(60))

        XCTAssertFalse(model.snapshot.providers.contains { $0.id == .miniMax })
        XCTAssertTrue(model.settingsProviders.contains { $0.id == .miniMax })
    }
    #endif

    private func makeModel(
        projections: [ProviderProjection]
    ) -> MenuPanelViewModel {
        let visible = LiveProviderProjectionMapper.map(
            projections,
            now: fixedNow
        )
        let settings = projections.map {
            LiveProviderProjectionMapper.map($0.state, now: fixedNow)
        }
        return MenuPanelViewModel(
            snapshot: Stage3AppProjection(
                providers: visible,
                memory: Stage3MemoryProjection(
                    pressure: .unknown,
                    fields: [],
                    history: [],
                    capturedAt: fixedNow,
                    origin: .runtime
                )
            ),
            settingsProviders: settings
        )
    }

    private func configureDiagnostics(
        _ model: MenuPanelViewModel,
        larkStatusLoader:
            (@MainActor () async -> LarkQuotaAlertChannelStatus)? = nil,
        loader: @escaping @MainActor () async -> SafeDiagnosticsLoadResult
    ) {
        model.configureRuntimeActions(
            onPanelPresented: {},
            onManualRefresh: {},
            onSetProviderEnabled: { _, _ in },
            onSetGlobalRefreshFrequency: { _ in },
            onSetProviderRefreshOverride: { _, _ in },
            onRedetectProvider: { _ in },
            onLoginProvider: { _, _ in .failed },
            onSelectProviderExecutable: { _ in .failed },
            onClearQuotaCache: { .failed },
            onLoadSafeDiagnostics: loader,
            onMemoryPageVisibilityChanged: { _ in },
            onLoadLarkQuotaAlertChannelStatus: larkStatusLoader
        )
    }

    private func makeProjection(
        providerID: ProviderID,
        enabled: Bool
    ) -> ProviderProjection {
        let capabilities = ProviderCapabilities(
            contractVersion: "runtime-bridge-test-v1",
            loginMethod: nil,
            hasOfficialDocumentation: true,
            allowsExecutableSelection: true
        )
        return ProviderProjection(
            revision: 0,
            isEnabled: enabled,
            phase: .idle,
            state: ProviderBootstrap.initialState(
                id: providerID,
                capabilities: capabilities,
                now: fixedNow
            )
        )
    }
}

private actor SafeDiagnosticsLoadGate {
    private var callCount = 0
    private var continuation: CheckedContinuation<SafeDiagnosticsLoadResult, Never>?

    func load() async -> SafeDiagnosticsLoadResult {
        callCount += 1
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func resume(with result: SafeDiagnosticsLoadResult) {
        continuation?.resume(returning: result)
        continuation = nil
    }

    func calls() -> Int {
        callCount
    }
}
