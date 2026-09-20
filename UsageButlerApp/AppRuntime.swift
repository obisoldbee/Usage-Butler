import AppKit
import Combine
import OSLog
import UsageButlerCore
import UsageButlerDomain
import UsageButlerInfrastructure
import UsageButlerUI

@MainActor
final class AppRuntime: ObservableObject {
    nonisolated private static let providerRefreshLogger = Logger(
        subsystem: ProviderRefreshTelemetry.subsystem,
        category: ProviderRefreshTelemetry.category
    )

    @Published private(set) var activityMonitorState: ActivityMonitorActionState = .idle
    @Published private(set) var shutdownComplete = false

    let menuModel: MenuPanelViewModel
    let launchMode: RuntimeLaunchMode
    var panelController: PanelPresentationController?

    private let defaults: UserDefaults
    private let activityMonitorLauncher: any ActivityMonitorLaunching
    private let composition: ProductionRuntimeComposition?
    private var observationTasks: [Task<Void, Never>] = []
    private var startTask: Task<Void, Never>?
    private var shutdownTask: Task<Void, Never>?
    private var refreshPolicyUpdateTask: Task<Void, Never>?
    private var lifecycleRefreshTask: Task<Void, Never>?
    private var freshnessTickTask: Task<Void, Never>?
    private var terminationCallbacks: [() -> Void] = []
    private var persistedMemoryHistory: [MemoryHistoryPoint] = []
    private var latestMemoryState: MemorySamplingState?
    private var lastMemoryHistorySaveAt: Date?
    private var globalRefreshFrequency: ProviderRefreshFrequency
    private var providerRefreshOverrides: [ProviderID: ProviderRefreshOverride]
    private var loggedProviderStates: [ProviderID: ProviderRuntimeTelemetryState] = [:]
    private var isShuttingDown = false
    private var isPanelVisible = false
    private var networkPathLastRead: Date?

    init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        defaults: UserDefaults = .standard,
        activityMonitorLauncher: any ActivityMonitorLaunching = ActivityMonitorLauncher()
    ) {
        Self.registerPreferenceDefaults(in: defaults)
        launchMode = RuntimeLaunchMode.resolve(environment: environment)
        self.defaults = defaults
        self.activityMonitorLauncher = activityMonitorLauncher
        globalRefreshFrequency = ProviderRefreshFrequency.validated(
            storedSeconds: defaults.integer(
                forKey: ProviderPreferenceKey.globalRefreshSeconds
            )
        )
        providerRefreshOverrides = Dictionary(
            uniqueKeysWithValues: ProviderID.allCases.map { providerID in
                (
                    providerID,
                    ProviderRefreshOverride.validated(
                        storedSeconds: defaults.integer(
                            forKey: Self.refreshOverrideKey(for: providerID)
                        )
                    )
                )
            }
        )

        switch launchMode {
        #if USAGE_BUTLER_FIXTURES
        case .offlineFixture:
            composition = nil
            menuModel = MenuPanelViewModel(
                snapshot: Stage3FixtureCatalog.projection()
            )
        #endif

        case .production:
            var compositionDiagnosticCode = "runtime.composition.unavailable"
            let productionComposition: ProductionRuntimeComposition?
            do {
                productionComposition = try ProductionRuntimeFactory.make(
                    defaults: defaults,
                    environment: environment
                )
            } catch let error as ProductionRuntimeCompositionError {
                compositionDiagnosticCode = Self.compositionFailureDiagnosticCode(
                    for: error
                )
                productionComposition = nil
            } catch {
                productionComposition = nil
            }
            composition = productionComposition

            let now = Date()
            let allProviderProjections = productionComposition?
                .initialProviderProjections ?? Self.fallbackProviderProjections(
                    now: now,
                    defaults: defaults,
                    diagnosticCode: compositionDiagnosticCode
                )
            let visibleProviders = LiveProviderProjectionMapper.map(
                allProviderProjections,
                now: now
            )
            let settingsProviders = allProviderProjections.map {
                LiveProviderProjectionMapper.map($0.state, now: now)
            }
            menuModel = MenuPanelViewModel(
                snapshot: Stage3AppProjection(
                    providers: visibleProviders,
                    memory: Stage3MemoryProjection(
                        pressure: .unknown,
                        fields: [],
                        history: [],
                        capturedAt: now,
                        origin: .runtime
                    )
                ),
                settingsProviders: settingsProviders
            )
        }

        configureMenuActions()
        menuModel.updateGlobalShortcutText(
            defaults.string(forKey: ProviderPreferenceKey.globalShortcut)
                .flatMap(GlobalShortcut.init(serialized:))?
                .displayText
        )
        if composition != nil {
            startTask = Task { @MainActor [weak self] in
                await self?.startProductionRuntime()
            }
        }
    }

    func openActivityMonitor() {
        guard activityMonitorState != .opening else { return }
        activityMonitorState = .opening

        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await activityMonitorLauncher.openActivityMonitor()
                activityMonitorState = .idle
            } catch ActivityMonitorLaunchError.applicationNotFound {
                activityMonitorState = .notFound
            } catch {
                activityMonitorState = .launchFailed
            }
        }
    }

    func openSettingsFallback() {
        let settingsSelector = Selector(("showSettingsWindow:"))
        let preferencesSelector = Selector(("showPreferencesWindow:"))
        let opened = NSApp.sendAction(settingsSelector, to: nil, from: nil)
        if !opened {
            NSApp.sendAction(preferencesSelector, to: nil, from: nil)
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    func quit() {
        NSApp.terminate(nil)
    }

    func prepareForTermination(completion: @escaping () -> Void) {
        if shutdownComplete {
            completion()
            return
        }

        terminationCallbacks.append(completion)
        guard shutdownTask == nil else { return }
        shutdownTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await shutdownRuntime()
            let callbacks = terminationCallbacks
            terminationCallbacks.removeAll()
            for callback in callbacks {
                callback()
            }
        }
    }

    private func configureMenuActions() {
        menuModel.configureRuntimeActions(
            onPanelPresented: { [weak self] in
                self?.requestLifecycleRefresh(reason: .panelPresented)
            },
            onManualRefresh: { [weak self] in
                await self?.manualRefresh()
            },
            onSetProviderEnabled: { [weak self] providerID, enabled in
                self?.setProviderEnabled(providerID, enabled: enabled)
            },
            onSetGlobalRefreshFrequency: { [weak self] frequency in
                self?.setGlobalRefreshFrequency(frequency)
            },
            onSetProviderRefreshOverride: { [weak self] providerID, override in
                self?.setProviderRefreshOverride(providerID, override: override)
            },
            onRedetectProvider: { [weak self] providerID in
                self?.redetectProvider(providerID)
            },
            onLoginProvider: { [weak self] providerID, request in
                guard let self else { return .failed }
                return await self.loginProvider(providerID, request: request)
            },
            onSelectProviderExecutable: { [weak self] providerID in
                guard let self else { return .failed }
                return await self.selectProviderExecutable(providerID)
            },
            onClearQuotaCache: { [weak self] in
                guard let self else { return .failed }
                return await self.clearQuotaCache()
            },
            onLoadSafeDiagnostics: { [weak self] in
                guard let self else { return .failed(.actionUnavailable) }
                return await self.loadSafeDiagnostics()
            },
            onMemoryPageVisibilityChanged: { [weak self] _ in
                self?.refreshMemorySamplingPolicy()
            },
            onSetGlobalShortcut: { [weak self] serialized in
                self?.setGlobalShortcut(serialized)
            },
            onLoadLarkQuotaAlertChannelStatus: { [weak self] in
                guard let self else { return .unavailable }
                return await self.loadLarkQuotaAlertChannelStatus()
            },
            onNetworkPageVisibilityChanged: { [weak self] _ in
                self?.refreshNetworkPublishPolicy()
            },
            onSetNetworkCollectionEnabled: { [weak self] enabled in
                await self?.setNetworkCollectionEnabled(enabled)
            }
        )
    }

    private func startProductionRuntime() async {
        guard let composition, !isShuttingDown else { return }

        for controller in composition.controllers.values {
            let task = Task { @MainActor [weak self, controller] in
                let projections = await controller.projections()
                for await projection in projections {
                    guard !Task.isCancelled else { return }
                    self?.receiveProviderProjection(projection)
                }
            }
            observationTasks.append(task)
        }

        // Quota-exhaustion alerts observe the same projection fan-out as the
        // UI; the service deduplicates snapshots by `lastGood.fetchedAt`.
        if let quotaAlertService = composition.quotaAlertService {
            observationTasks.append(
                Task { await quotaAlertService.prepare() }
            )
            for controller in composition.controllers.values {
                observationTasks.append(
                    Task {
                        let projections = await controller.projections()
                        for await projection in projections {
                            guard !Task.isCancelled else { return }
                            await quotaAlertService.receive(projection)
                        }
                    }
                )
            }
        }

        let memoryController = composition.memoryController
        let memoryTask = Task { @MainActor [weak self, memoryController] in
            let updates = await memoryController.updates()
            for await state in updates {
                guard !Task.isCancelled else { return }
                await self?.receiveMemoryState(state)
            }
        }
        observationTasks.append(memoryTask)

        let networkCollector = composition.networkCollector
        let networkPathReader = composition.networkPathReader
        observationTasks.append(Task { @MainActor [weak self] in
            let updates = await networkCollector.updates()
            for await snapshot in updates {
                guard !Task.isCancelled else { return }
                self?.refreshNetworkSystemPath(reader: networkPathReader)
                self?.menuModel.applyNetworkSnapshot(snapshot)
            }
        })

        let wakeNotifications = NSWorkspace.shared.notificationCenter.notifications(
            named: NSWorkspace.didWakeNotification
        )
        let wakeTask = Task { @MainActor [weak self] in
            for await _ in wakeNotifications {
                guard !Task.isCancelled else { return }
                self?.requestLifecycleRefresh(reason: .systemWake)
            }
        }
        observationTasks.append(wakeTask)

        await loadMemoryHistory()
        guard !Task.isCancelled, !isShuttingDown else { return }

        await memoryController.start()
        await networkCollector.start()
        refreshNetworkPublishPolicy()
        let controllers = Array(composition.controllers.values)
        await withTaskGroup(of: Void.self) { group in
            for controller in controllers {
                group.addTask {
                    _ = await controller.send(.start)
                }
            }
        }

        freshnessTickTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(
                    for: .seconds(ProviderFreshnessSLA.tickInterval)
                )
                guard let self, !self.isShuttingDown else { return }
                await self.tickProviderFreshness()
            }
        }
    }

    /// Drives the independent data-age SLA. Unlike the lifecycle refresh-due
    /// threshold, this may age a retained fresh snapshot to stale; the reducer
    /// owns the actual transition and keeps every retained value intact.
    private func tickProviderFreshness() async {
        guard let composition, !isShuttingDown else { return }
        for providerID in ProviderID.allCases {
            guard let controller = composition.controllers[providerID] else {
                continue
            }
            let frequency = providerRefreshOverrides[providerID]?
                .resolving(globalFrequency: globalRefreshFrequency)
                ?? globalRefreshFrequency
            _ = await controller.send(
                .ageTick(
                    staleAfter: ProviderFreshnessSLA.staleAfter(frequency: frequency)
                )
            )
        }
    }

    private func manualRefresh() async {
        guard let composition else {
            #if USAGE_BUTLER_FIXTURES
            if launchMode == .offlineFixture {
                menuModel.refreshPreview()
            }
            #endif
            return
        }
        guard !isShuttingDown else { return }

        if menuModel.selectedPage == .network {
            await composition.networkCollector.refreshNow()
            return
        }

        let controllers = Array(composition.controllers.values)
        await withTaskGroup(of: Void.self) { group in
            for controller in controllers {
                group.addTask {
                    _ = await controller.send(
                        .refresh(.manual(scope: .provider))
                    )
                }
            }
        }
    }

    private func requestLifecycleRefresh(
        reason: ProviderLifecycleRefreshReason
    ) {
        guard composition != nil, !isShuttingDown,
              lifecycleRefreshTask == nil else {
            return
        }

        lifecycleRefreshTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await refreshProvidersForLifecycleSignal(reason: reason)
            lifecycleRefreshTask = nil
        }
    }

    private func refreshProvidersForLifecycleSignal(
        reason: ProviderLifecycleRefreshReason
    ) async {
        guard let composition, !isShuttingDown else { return }
        let controllers = Array(composition.controllers.values)

        await withTaskGroup(of: Void.self) { group in
            for controller in controllers {
                group.addTask {
                    let projection = await controller.projection()
                    let evaluatedAt = Date()
                    guard projection.isEnabled,
                          ProviderLifecycleRefreshPolicy.shouldRequestRefresh(
                              freshness: projection.state.freshness,
                              reason: reason,
                              now: evaluatedAt
                          ) else {
                        return
                    }
                    let outcome = await controller.send(
                        .refresh(.scheduled(scope: .provider))
                    )
                    let message = ProviderRefreshTelemetry.lifecycleRefreshMessage(
                        provider: projection.state.id,
                        reason: reason,
                        outcome: outcome
                    )
                    Self.providerRefreshLogger.info(
                        "\(message, privacy: .public)"
                    )
                }
            }
        }
    }

    private func setProviderEnabled(_ providerID: ProviderID, enabled: Bool) {
        guard let controller = composition?.controllers[providerID] else {
            #if USAGE_BUTLER_FIXTURES
            if launchMode == .offlineFixture {
                menuModel.applyFixtureProviderVisibility(
                    providerID,
                    enabled: enabled
                )
            }
            #endif
            return
        }
        Task {
            _ = await controller.send(.setEnabled(enabled))
        }
    }

    private func setGlobalRefreshFrequency(_ frequency: ProviderRefreshFrequency) {
        guard !isShuttingDown else { return }
        globalRefreshFrequency = frequency
        defaults.set(
            frequency.rawValue,
            forKey: ProviderPreferenceKey.globalRefreshSeconds
        )
        enqueueRefreshPolicyUpdate(for: ProviderID.allCases)
    }

    private func setProviderRefreshOverride(
        _ providerID: ProviderID,
        override: ProviderRefreshOverride
    ) {
        guard !isShuttingDown else { return }
        providerRefreshOverrides[providerID] = override
        defaults.set(
            override.storedSeconds,
            forKey: Self.refreshOverrideKey(for: providerID)
        )
        enqueueRefreshPolicyUpdate(for: [providerID])
    }

    private func enqueueRefreshPolicyUpdate(for providerIDs: [ProviderID]) {
        guard composition != nil else { return }
        let previousTask = refreshPolicyUpdateTask
        refreshPolicyUpdateTask = Task { @MainActor [weak self] in
            _ = await previousTask?.value
            guard let self, !Task.isCancelled, !isShuttingDown,
                  let composition else {
                return
            }

            for providerID in providerIDs {
                guard !Task.isCancelled, !isShuttingDown,
                      let controller = composition.controllers[providerID] else {
                    return
                }
                let policy = ProviderRefreshPolicyResolver.policy(
                    providerID: providerID,
                    globalFrequency: globalRefreshFrequency,
                    override: providerRefreshOverrides[providerID] ?? .followGlobal
                )
                _ = await controller.send(.setRefreshPolicy(policy))
            }
        }
    }

    private func redetectProvider(_ providerID: ProviderID) {
        guard let controller = composition?.controllers[providerID],
              !isShuttingDown else {
            return
        }
        Task {
            _ = await controller.send(.redetect)
        }
    }

    private func loginProvider(
        _ providerID: ProviderID,
        request: ProviderLoginRequest
    ) async -> ProviderLoginFeedback {
        guard let controller = composition?.controllers[providerID] else {
            #if USAGE_BUTLER_FIXTURES
            return launchMode == .offlineFixture ? .offlineFixture : .failed
            #else
            return .failed
            #endif
        }
        guard !isShuttingDown else { return .failed }

        let outcome: ProviderIntentOutcome
        switch request {
        case .start:
            outcome = await controller.send(.login)
        case .cancel:
            outcome = await controller.send(.cancelLogin)
        }
        if request == .cancel {
            switch outcome {
            case .completed, .cancelled:
                return .cancelled
            case .joined, .deferred:
                return .busy
            case .shutdown, .rejected:
                return .failed
            }
        }

        switch outcome {
        case .completed:
            let projection = await controller.projection()
            if projection.state.scopedFailures.failure(for: .login)?.code == .rateLimited {
                return .rateLimited
            }
            if projection.state.scopedFailures.failure(for: .login) != nil {
                return .flowFailed
            }
            switch LoginRecoveryVerifier.classify(projection.state) {
            case .verifiedFresh:
                return .verifiedFresh
            case .authorizationNotRenewed:
                return .authorizationNotRenewed
            case let .verificationFailed(code):
                return .verificationFailed(code)
            }
        case .joined, .deferred:
            return .busy
        case .cancelled:
            return .cancelled
        case .shutdown:
            return .failed
        case let .rejected(rejection):
            switch rejection {
            case .disabled:
                return .disabled
            case .unsupportedLogin:
                return .unsupported
            case .alreadyStarted, .notStarted, .shuttingDown, .stopped:
                return .failed
            }
        }
    }

    private func selectProviderExecutable(
        _ providerID: ProviderID
    ) async -> ProviderExecutableSelectionFeedback {
        #if USAGE_BUTLER_FIXTURES
        guard launchMode == .production, !isShuttingDown else {
            return launchMode == .offlineFixture ? .offlineFixture : .failed
        }
        #else
        guard !isShuttingDown else { return .failed }
        #endif

        let panel = NSOpenPanel()
        panel.title = String(localized: "选择 \(Self.cliDisplayName(for: providerID))")
        panel.message = String(localized: "选择现有的 CLI 可执行文件；额度管家不会运行安装命令。")
        panel.prompt = String(localized: "选择")
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.resolvesAliases = true

        guard await panel.begin() == .OK, let selectedURL = panel.url else {
            return .cancelled
        }

        do {
            let executable = try CLIExecutableLocator().locate(
                executableName: Self.cliExecutableName(for: providerID),
                explicitUserFileURL: selectedURL,
                pathEntries: []
            )
            defaults.set(
                executable.resolvedFileURL.path,
                forKey: Self.executablePathKey(for: providerID)
            )
            return .savedRequiresRelaunch
        } catch {
            return .invalidSelection
        }
    }

    private func clearQuotaCache() async -> CacheClearFeedback {
        guard let composition else {
            #if USAGE_BUTLER_FIXTURES
            return launchMode == .offlineFixture ? .offlineFixture : .failed
            #else
            return .failed
            #endif
        }
        guard !isShuttingDown else { return .failed }

        let controllers = Array(composition.controllers.values)
        let accepted = await withTaskGroup(of: Bool.self) { group in
            for controller in controllers {
                group.addTask {
                    switch await controller.send(.clearCache) {
                    case .completed, .joined, .deferred:
                        return true
                    case .cancelled, .rejected, .shutdown:
                        return false
                    }
                }
            }
            var allAccepted = true
            for await result in group {
                allAccepted = allAccepted && result
            }
            return allAccepted
        }
        return accepted ? .completed : .failed
    }

    private func loadSafeDiagnostics() async -> SafeDiagnosticsLoadResult {
        guard !isShuttingDown else { return .failed(.runtimeShuttingDown) }
        guard let composition else {
            #if USAGE_BUTLER_FIXTURES
            if launchMode == .offlineFixture {
                return .unavailable(.offlineFixture)
            }
            #endif
            return .unavailable(.runtimeCompositionUnavailable)
        }

        let adapters = composition.adapters.sorted {
            $0.id.canonicalOrder < $1.id.canonicalOrder
        }
        guard !adapters.isEmpty else {
            return .unavailable(.runtimeCompositionUnavailable)
        }

        let journal = await composition.diagnosticJournal.snapshot()
        var snapshots: [SafeProviderDiagnostic] = []
        snapshots.reserveCapacity(adapters.count)
        for adapter in adapters {
            guard !Task.isCancelled, !isShuttingDown else {
                return .failed(.runtimeShuttingDown)
            }
            let current = await adapter.diagnosticSnapshot()
            snapshots.append(SafeProviderDiagnostic(providerID: current.providerID, capturedAt: current.capturedAt,
                diagnosticCode: current.diagnosticCode, safeFields: current.safeFields,
                events: journal.events.filter { $0.provider == adapter.id.rawValue }, journalAvailable: journal.state == .ready))
        }
        return .loaded(snapshots)
    }

    private func loadLarkQuotaAlertChannelStatus() async
        -> LarkQuotaAlertChannelStatus {
        guard !isShuttingDown,
              let reader = composition?.larkQuotaAlertStatusReader else {
            return .unavailable
        }
        switch await reader.read() {
        case .ready:
            return .ready
        case .needsChatID:
            return .needsChatID
        case .needsSetup:
            return .needsSetup
        case .unavailable:
            return .unavailable
        }
    }

    /// The one-second memory cadence applies only while the panel is actually
    /// visible on the memory page; a closed panel always falls back to the
    /// ten-second cadence even if the memory page stays selected.
    func setPanelVisible(_ visible: Bool) {
        guard visible != isPanelVisible else { return }
        isPanelVisible = visible
        refreshMemorySamplingPolicy()
        refreshNetworkPublishPolicy()
    }

    private func refreshMemorySamplingPolicy() {
        guard let memoryController = composition?.memoryController,
              !isShuttingDown else {
            return
        }
        let isMemoryPageActive = isPanelVisible && menuModel.selectedPage == .memory
        Task {
            await memoryController.updatePolicy(
                isMemoryPageActive ? .memoryPageVisible : .other
            )
        }
    }

    /// The 1 Hz publish cadence applies only while the panel is visible on the
    /// network page; anything else drops to the background cadence. Source
    /// sampling itself never depends on panel visibility.
    private func refreshNetworkPublishPolicy() {
        guard let collector = composition?.networkCollector,
              !isShuttingDown else {
            return
        }
        let isNetworkPageActive = isPanelVisible && menuModel.selectedPage == .network
        Task {
            await collector.updatePolicy(
                isNetworkPageActive ? .panelVisible : .background
            )
        }
    }

    /// Cached so the page still shows what it measured for a moment after the
    /// system stops answering, instead of flickering to "not identified".
    private static let networkPathReuseInterval: TimeInterval = 5

    private func refreshNetworkSystemPath(reader: any NetworkPathProviding, now: Date = Date()) {
        if let lastRead = networkPathLastRead,
           now.timeIntervalSince(lastRead) < Self.networkPathReuseInterval {
            return
        }
        networkPathLastRead = now
        menuModel.setNetworkSystemPath(reader.currentPath(), at: now)
    }

    /// Debug acceptance hook: silences the real collector so a scripted run is
    /// the only thing feeding the page, and reports what it observed. Toggling
    /// the setting alone is not enough — `start()` may still be in flight and
    /// would begin a session from the settings it loaded earlier.
    #if DEBUG
    func debugQuiesceNetworkCollection() async -> String {
        guard let collector = composition?.networkCollector else { return "no-collector" }
        await collector.setCollectionEnabled(false)
        await collector.stop()
        for _ in 0..<20 {
            let state = await collector.collectionStateNow()
            if state == .stopped { return "stopped" }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return "not-stopped"
    }
    #endif

    private func setNetworkCollectionEnabled(_ enabled: Bool) async {
        guard let collector = composition?.networkCollector,
              !isShuttingDown else {
            return
        }
        await collector.setCollectionEnabled(enabled)
    }

    /// Persists the global panel shortcut and re-registers the hotkey.
    /// `nil` clears both the storage and the registration.
    func setGlobalShortcut(_ serialized: String?) {
        if let serialized {
            defaults.set(serialized, forKey: ProviderPreferenceKey.globalShortcut)
        } else {
            defaults.removeObject(forKey: ProviderPreferenceKey.globalShortcut)
        }
        let shortcut = serialized.flatMap(GlobalShortcut.init(serialized:))
        panelController?.applyShortcut(shortcut)
        menuModel.updateGlobalShortcutText(shortcut?.displayText)
    }

    private func receiveProviderProjection(_ projection: ProviderProjection) {
        let telemetryState = ProviderRuntimeTelemetryState(projection: projection)
        if loggedProviderStates[projection.state.id] != telemetryState {
            let previous = loggedProviderStates[projection.state.id]
            loggedProviderStates[projection.state.id] = telemetryState
            if let journal = composition?.diagnosticJournal {
                let failed = telemetryState.failure != "none" && telemetryState.activity == "idle"
                let recovered = telemetryState.failure == "none" && previous?.failure != nil
                    && previous?.failure != "none" && telemetryState.freshness == "fresh"
                if failed || recovered {
                    let reading = ClockReading(wallTime: Date(), monotonicTime: .init(nanoseconds: DispatchTime.now().uptimeNanoseconds))
                    let event = ProviderDiagnosticEvent(providerID: projection.state.id,
                        stage: recovered ? .recovery : .runtime, reason: recovered ? .recovered : .providerFailure,
                        timestamp: reading.wallTime,
                        failureCode: projection.state.scopedFailures.current?.failure.code,
                        retryAt: projection.automaticRefresh ? ProviderRetryTiming.date(for: projection.state.refresh.gate, reading: reading) : nil,
                        retryGate: .init(projection.state.refresh.gate), automaticRetry: projection.automaticRefresh)
                    Task { await journal.record(event) }
                }
            }
            Self.providerRefreshLogger.info(
                "\(ProviderRefreshTelemetry.providerStateMessage(telemetryState), privacy: .public)"
            )
        }
        menuModel.applyProviderProjection(projection, now: Date())
    }

    private func receiveMemoryState(_ state: MemorySamplingState) async {
        latestMemoryState = state
        let now = state.latest?.timestamp ?? Date()
        publishMemory(state: state, now: now)

        guard let store = composition?.memoryHistoryStore,
              let latest = state.latest else {
            return
        }
        if let lastMemoryHistorySaveAt,
           latest.timestamp.timeIntervalSince(lastMemoryHistorySaveAt) < 30 {
            return
        }
        lastMemoryHistorySaveAt = latest.timestamp
        let points = mergedMemoryHistory(
            livePoints: state.history,
            referenceTimestamp: latest.timestamp
        )
        _ = await store.save(points, referenceTimestamp: latest.timestamp)
    }

    private func publishMemory(state: MemorySamplingState, now: Date) {
        guard let latest = state.latest else { return }
        let history = mergedMemoryHistory(
            livePoints: state.history,
            referenceTimestamp: now
        )
        let visibleHistory = MemoryHistoryDownsampler.downsample(
            history,
            targetPointCount: 720,
            preserveRecentInterval: 60
        )
        menuModel.applyMemoryProjection(
            LiveMemoryProjectionMapper.map(
                latest,
                history: visibleHistory,
                now: now
            )
        )
    }

    private func loadMemoryHistory() async {
        guard let store = composition?.memoryHistoryStore else { return }
        let now = Date()
        switch await store.load(referenceTimestamp: now) {
        case let .hit(points):
            persistedMemoryHistory = points
        case .miss, .failure:
            persistedMemoryHistory = []
        }
        if let latestMemoryState {
            publishMemory(state: latestMemoryState, now: now)
        }
    }

    private func mergedMemoryHistory(
        livePoints: [MemoryHistoryPoint],
        referenceTimestamp: Date
    ) -> [MemoryHistoryPoint] {
        let cutoff = referenceTimestamp.addingTimeInterval(
            -MemorySampleHistory.twoHourRetention
        )
        var byTimestamp: [Date: MemoryHistoryPoint] = [:]
        for point in persistedMemoryHistory + livePoints
        where point.timestamp >= cutoff && point.timestamp <= referenceTimestamp {
            byTimestamp[point.timestamp] = point
        }
        return byTimestamp.values.sorted { $0.timestamp < $1.timestamp }
    }

    private func shutdownRuntime() async {
        guard !shutdownComplete, !isShuttingDown else { return }
        isShuttingDown = true
        startTask?.cancel()
        refreshPolicyUpdateTask?.cancel()
        lifecycleRefreshTask?.cancel()
        freshnessTickTask?.cancel()

        guard let composition else {
            shutdownComplete = true
            return
        }

        await composition.memoryController.stop()
        await composition.networkCollector.stop()
        if let store = composition.memoryHistoryStore {
            let referenceTimestamp = latestMemoryState?.latest?.timestamp ?? Date()
            let points = mergedMemoryHistory(
                livePoints: latestMemoryState?.history ?? [],
                referenceTimestamp: referenceTimestamp
            )
            _ = await store.save(points, referenceTimestamp: referenceTimestamp)
            await store.shutdown()
        }

        let controllers = Array(composition.controllers.values)
        await withTaskGroup(of: Void.self) { group in
            for controller in controllers {
                group.addTask {
                    _ = await controller.send(.shutdown)
                }
            }
        }
        for scheduler in composition.schedulers {
            await scheduler.shutdown()
        }

        for task in observationTasks {
            task.cancel()
        }
        observationTasks.removeAll()

        await composition.quotaAlertService?.shutdown()
        await composition.larkProcessClient?.shutdown()
        shutdownComplete = true
    }

    private static func registerPreferenceDefaults(in defaults: UserDefaults) {
        defaults.register(defaults: [
            ProviderPreferenceKey.openAIEnabled: true,
            ProviderPreferenceKey.miniMaxEnabled: true,
            ProviderPreferenceKey.arkEnabled: true,
            ProviderPreferenceKey.globalRefreshSeconds: 300,
            ProviderPreferenceKey.openAIRefreshOverrideSeconds: -1,
            ProviderPreferenceKey.miniMaxRefreshOverrideSeconds: -1,
            ProviderPreferenceKey.arkRefreshOverrideSeconds: -1,
            ProviderPreferenceKey.quotaAlertsEnabled: true,
            NetworkPreferenceKey.collectionEnabled: false
        ])
    }

    private static func fallbackProviderProjections(
        now: Date,
        defaults: UserDefaults,
        diagnosticCode: String
    ) -> [ProviderProjection] {
        ProviderID.allCases.map { providerID in
            let loginMethod: LoginMethod?
            switch providerID {
            case .openAI: loginMethod = nil
            case .miniMax: loginMethod = .oauth
            case .ark: loginMethod = .sso
            }
            let capabilities = ProviderCapabilities(
                contractVersion: "runtime-composition-unavailable",
                loginMethod: loginMethod,
                hasOfficialDocumentation: true,
                allowsExecutableSelection: true
            )
            let initialState = ProviderBootstrap.initialState(
                id: providerID,
                capabilities: capabilities,
                now: now
            )
            let unavailableState = ProviderReducer.reduce(
                state: initialState,
                event: .discovery(
                    .failed(
                        ProviderFailure(
                            code: .processFailed,
                            retryClass: .never,
                            userMessageKey: "provider.failure.runtime-composition",
                            diagnosticCode: diagnosticCode,
                            recovery: nil
                        )
                    )
                ),
                now: now
            )
            return ProviderProjection(
                revision: 0,
                isEnabled: defaults.bool(forKey: preferenceKey(for: providerID)),
                phase: .idle,
                state: unavailableState
            )
        }
    }

    private static func compositionFailureDiagnosticCode(
        for error: ProductionRuntimeCompositionError
    ) -> String {
        switch error {
        case let .controllerInitialization(providerID):
            "runtime.composition.controller_initialization.\(providerID.rawValue)"
        }
    }

    private static func preferenceKey(for providerID: ProviderID) -> String {
        switch providerID {
        case .openAI: ProviderPreferenceKey.openAIEnabled
        case .miniMax: ProviderPreferenceKey.miniMaxEnabled
        case .ark: ProviderPreferenceKey.arkEnabled
        }
    }

    private static func refreshOverrideKey(for providerID: ProviderID) -> String {
        switch providerID {
        case .openAI: ProviderPreferenceKey.openAIRefreshOverrideSeconds
        case .miniMax: ProviderPreferenceKey.miniMaxRefreshOverrideSeconds
        case .ark: ProviderPreferenceKey.arkRefreshOverrideSeconds
        }
    }

    private static func executablePathKey(for providerID: ProviderID) -> String {
        switch providerID {
        case .openAI: ProviderPreferenceKey.openAIExecutablePath
        case .miniMax: ProviderPreferenceKey.miniMaxExecutablePath
        case .ark: ProviderPreferenceKey.arkExecutablePath
        }
    }

    private static func cliExecutableName(for providerID: ProviderID) -> String {
        switch providerID {
        case .openAI: "codex"
        case .miniMax: "mmx"
        case .ark: "arkcli"
        }
    }

    private static func cliDisplayName(for providerID: ProviderID) -> String {
        switch providerID {
        case .openAI: "Codex CLI"
        case .miniMax: "MiniMax CLI"
        case .ark: "Ark CLI"
        }
    }
}
