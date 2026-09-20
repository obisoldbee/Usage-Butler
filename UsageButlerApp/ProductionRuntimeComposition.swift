import Foundation
import UsageButlerCore
import UsageButlerDomain
import UsageButlerInfrastructure
import UsageButlerProviders

struct ProductionRuntimeComposition {
    let diagnosticJournal: ProviderDiagnosticJournal
    let controllers: [ProviderID: ProviderController]
    let adapters: [any ProviderAdapter]
    let caches: [any ProviderQuotaCache]
    let schedulers: [RefreshScheduler]
    let initialProviderProjections: [ProviderProjection]
    let memoryController: MemorySamplingController
    let networkCollector: NetworkCollector
    /// Answers which network the system itself considers active, so the page
    /// never promotes an interface name into a claim about the connection.
    let networkPathReader: any NetworkPathProviding
    let memoryHistoryStore: (any MemoryHistoryStore)?
    let quotaAlertService: QuotaAlertService?
    let larkProcessClient: OneShotChildProcessClient?
    let larkQuotaAlertStatusReader: LarkCLIQuotaAlertStatusReader?
}

enum ProductionRuntimeCompositionError: Error {
    case controllerInitialization(ProviderID)
}

enum ProductionRuntimeFactory {
    private static let openAIContractVersion = "usage-butler-provider-contract-v0.8"

    static func make(
        defaults: UserDefaults,
        environment: [String: String]
    ) throws -> ProductionRuntimeComposition {
        let journalDirectory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Usage-Butler/diagnostics", isDirectory: true)
        let diagnosticJournal = ProviderDiagnosticJournal(directory: journalDirectory)
        let now = Date()
        let homeDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
        let pathEntries = runtimePathEntries(
            environment: environment,
            homeDirectoryURL: homeDirectoryURL
        )
        let allowlistedProxyEnvironment = OpenAIProxyEnvironmentResolver.resolve(
            environment: environment
        )
        let locator = CLIExecutableLocator()
        let childEnvironment = try? MinimalChildEnvironmentBuilder().build(
            pathEntries: pathEntries,
            homeDirectoryURL: homeDirectoryURL,
            locale: .utf8,
            explicitProxyEnvironment: allowlistedProxyEnvironment
        )

        let openAIAdapter = makeOpenAIAdapter(
            locator: locator,
            pathEntries: pathEntries,
            homeDirectoryURL: homeDirectoryURL,
            explicitProxyEnvironment: allowlistedProxyEnvironment,
            explicitExecutableURL: explicitExecutableURL(
                providerID: .openAI,
                defaults: defaults
            )
        )
        let miniMaxAdapter = makeMiniMaxAdapter(
            diagnostics: diagnosticJournal,
            locator: locator,
            pathEntries: pathEntries,
            childEnvironment: childEnvironment,
            explicitExecutableURL: explicitExecutableURL(
                providerID: .miniMax,
                defaults: defaults
            )
        )
        let arkAdapter = makeArkAdapter(
            locator: locator,
            pathEntries: pathEntries,
            childEnvironment: childEnvironment,
            explicitExecutableURL: explicitExecutableURL(
                providerID: .ark,
                defaults: defaults
            )
        )
        let adapters: [any ProviderAdapter] = [
            openAIAdapter,
            miniMaxAdapter,
            arkAdapter
        ]

        let clock = SystemClockPort()
        let cacheConfiguration = quotaCacheConfiguration()
        var controllers: [ProviderID: ProviderController] = [:]
        var caches: [any ProviderQuotaCache] = []
        var schedulers: [RefreshScheduler] = []
        var initialProviderProjections: [ProviderProjection] = []

        for adapter in adapters {
            let cache: any ProviderQuotaCache
            if let cacheConfiguration {
                cache = ProviderQuotaDiskCache(configuration: cacheConfiguration)
            } else {
                cache = RuntimeVolatileProviderQuotaCache()
            }
            let scheduler = RefreshScheduler(clock: clock)
            let enabled = defaults.bool(forKey: preferenceKey(for: adapter.id))
            let initialState = ProviderBootstrap.initialState(
                id: adapter.id,
                capabilities: adapter.capabilities,
                now: now
            )
            guard let controller = try? ProviderController(
                initialState: initialState,
                initiallyEnabled: enabled,
                adapter: adapter,
                cache: cache,
                clock: clock,
                scheduler: scheduler,
                policy: refreshPolicy(
                    providerID: adapter.id,
                    defaults: defaults
                )
            ) else {
                throw ProductionRuntimeCompositionError
                    .controllerInitialization(adapter.id)
            }

            controllers[adapter.id] = controller
            caches.append(cache)
            schedulers.append(scheduler)
            initialProviderProjections.append(
                ProviderProjection(
                    revision: 0,
                    isEnabled: enabled,
                    phase: .idle,
                    state: initialState
                )
            )
        }

        let memoryController = MemorySamplingController(
            clock: SystemMemorySamplingClock(),
            sleeper: TaskMemorySamplingSleeper(),
            pressureSource: DispatchMemoryPressureSource(),
            statsReader: SystemMemoryStatsReader(),
            initialPolicy: .other
        )

        let networkCollector = NetworkCollector(
            clock: clock,
            settingsStore: UserDefaultsNetworkSettingsStore(defaults: defaults),
            coverageProfile: .interfaceCountersOnly,
            idleCapabilities: GetifaddrsNetworkSource.interfaceOnlyCapabilities,
            makeSource: { sessionID in
                GetifaddrsNetworkSource(
                    clock: clock,
                    reader: GetifaddrsInterfaceCountersReader(),
                    sessionID: sessionID
                )
            }
        )

        let (
            quotaAlertService,
            larkProcessClient,
            larkQuotaAlertStatusReader
        ) = makeQuotaAlertService(
            locator: locator,
            pathEntries: pathEntries,
            childEnvironment: childEnvironment,
            defaults: defaults
        )

        return ProductionRuntimeComposition(
            diagnosticJournal: diagnosticJournal,
            controllers: controllers,
            adapters: adapters,
            caches: caches,
            schedulers: schedulers,
            initialProviderProjections: initialProviderProjections.sorted {
                $0.state.id.canonicalOrder < $1.state.id.canonicalOrder
            },
            memoryController: memoryController,
            networkCollector: networkCollector,
            networkPathReader: SystemConfigurationNetworkPathReader(),
            memoryHistoryStore: memoryHistoryStore(),
            quotaAlertService: quotaAlertService,
            larkProcessClient: larkProcessClient,
            larkQuotaAlertStatusReader: larkQuotaAlertStatusReader
        )
    }

    /// The system channel always exists; the Feishu channel joins only when
    /// both a valid child environment and `lark-cli` are resolvable. The
    /// shared process client is returned so shutdown can reap it.
    private static func makeQuotaAlertService(
        locator: CLIExecutableLocator,
        pathEntries: [String],
        childEnvironment: MinimalChildEnvironment?,
        defaults: UserDefaults
    ) -> (
        QuotaAlertService?,
        OneShotChildProcessClient?,
        LarkCLIQuotaAlertStatusReader?
    ) {
        var channels: [QuotaAlertChannel] = [
            QuotaAlertChannel(id: "system", notifier: SystemQuotaAlertNotifier())
        ]
        var larkProcessClient: OneShotChildProcessClient?
        var larkStatusReader: LarkCLIQuotaAlertStatusReader?
        let defaultsBox = SendableUserDefaults(defaults: defaults)

        if let childEnvironment,
           let executable = try? locator.locate(
               executableName: "lark-cli",
               explicitUserFileURL: nil,
               pathEntries: pathEntries
           ) {
            let processClient = OneShotChildProcessClient()
            larkProcessClient = processClient
            larkStatusReader = LarkCLIQuotaAlertStatusReader(
                processClient: processClient,
                executableURL: executable.resolvedFileURL,
                baseEnvironment: childEnvironment.variables,
                isDestinationConfigured: {
                    LarkQuotaAlertConfiguration.validatedChatID(
                        defaultsBox.defaults.string(forKey: ProviderPreferenceKey.larkQuotaAlertChatID)
                    ) != nil
                }
            )
            let notifier = LarkCLIQuotaAlertNotifier(
                processClient: processClient,
                executableURL: executable.resolvedFileURL,
                baseEnvironment: childEnvironment.variables,
                chatIDProvider: {
                    defaultsBox.defaults.string(forKey: ProviderPreferenceKey.larkQuotaAlertChatID)
                }
            )
            channels.append(
                QuotaAlertChannel(
                    id: "lark",
                    notifier: notifier
                )
            )
        }

        let service = QuotaAlertService(
            channels: channels,
            markerStore: UserDefaultsQuotaAlertMarkerStore(boxed: defaultsBox),
            isAlertsEnabled: {
                defaultsBox.defaults.object(forKey: ProviderPreferenceKey.quotaAlertsEnabled) as? Bool
                    ?? true
            }
        )
        return (service, larkProcessClient, larkStatusReader)
    }

    private static func makeOpenAIAdapter(
        locator: CLIExecutableLocator,
        pathEntries: [String],
        homeDirectoryURL: URL,
        explicitProxyEnvironment: [String: String],
        explicitExecutableURL: URL?
    ) -> any ProviderAdapter {
        let capabilities = ProviderCapabilities(
            contractVersion: openAIContractVersion,
            loginMethod: nil,
            hasOfficialDocumentation: true,
            allowsExecutableSelection: true
        )
        guard let executable = try? locator.locate(
            executableName: "codex",
            explicitUserFileURL: explicitExecutableURL,
            pathEntries: pathEntries
        ) else {
            return UnavailableRuntimeProviderAdapter(
                id: .openAI,
                capabilities: capabilities,
                failure: missingExecutableFailure(providerID: .openAI)
            )
        }

        let sourceIdentity = ProviderSourceIdentity(
            providerID: .openAI,
            adapterID: "openai.codex-app-server",
            executableIdentity: "selected-codex-v1",
            cliVersion: "runtime-unverified",
            schemaVersion: "account-rate-limits-v1",
            contractVersion: openAIContractVersion
        )
        let transport = OpenAIAppServerTransport(
            configuration: OpenAIAppServerTransportConfiguration(
                executableURL: executable.resolvedFileURL,
                homeDirectoryURL: homeDirectoryURL,
                sourceIdentity: sourceIdentity,
                explicitProxyEnvironment: explicitProxyEnvironment
            )
        )
        return OpenAIProviderAdapter(
            reader: transport,
            capabilities: capabilities
        )
    }

    private static func makeMiniMaxAdapter(
        diagnostics: any ProviderDiagnosticRecording,
        locator: CLIExecutableLocator,
        pathEntries: [String],
        childEnvironment: MinimalChildEnvironment?,
        explicitExecutableURL: URL?
    ) -> any ProviderAdapter {
        let capabilities = ProviderCapabilities(
            contractVersion: MiniMaxDomainContract.quotaContractVersion,
            loginMethod: .oauth,
            hasOfficialDocumentation: true,
            allowsExecutableSelection: true
        )
        guard let childEnvironment else {
            return UnavailableRuntimeProviderAdapter(
                id: .miniMax,
                capabilities: capabilities,
                failure: environmentFailure(providerID: .miniMax)
            )
        }
        guard let executable = try? locator.locate(
            executableName: "mmx",
            explicitUserFileURL: explicitExecutableURL,
            pathEntries: pathEntries
        ) else {
            return UnavailableRuntimeProviderAdapter(
                id: .miniMax,
                capabilities: capabilities,
                failure: missingExecutableFailure(providerID: .miniMax)
            )
        }
        return MiniMaxProviderAdapter(
            processClient: OneShotChildProcessClient(),
            executableURL: executable.resolvedFileURL,
            environment: childEnvironment.variables,
            cliVersion: .unverified,
            region: .unverified,
            catalogID: .unverified,
            diagnostics: diagnostics,
            diagnosticIdentity: { DiagnosticCLIIdentity.read(executable: executable.resolvedFileURL) }
        )
    }

    private static func makeArkAdapter(
        locator: CLIExecutableLocator,
        pathEntries: [String],
        childEnvironment: MinimalChildEnvironment?,
        explicitExecutableURL: URL?
    ) -> any ProviderAdapter {
        let capabilities = ProviderCapabilities(
            contractVersion: ArkDomainContract.quotaContractVersion,
            loginMethod: .sso,
            hasOfficialDocumentation: true,
            allowsExecutableSelection: true
        )
        guard let childEnvironment else {
            return UnavailableRuntimeProviderAdapter(
                id: .ark,
                capabilities: capabilities,
                failure: environmentFailure(providerID: .ark)
            )
        }
        guard let executable = try? locator.locate(
            executableName: "arkcli",
            explicitUserFileURL: explicitExecutableURL,
            pathEntries: pathEntries
        ) else {
            return UnavailableRuntimeProviderAdapter(
                id: .ark,
                capabilities: capabilities,
                failure: missingExecutableFailure(providerID: .ark)
            )
        }

        let authReader = ArkAuthenticationStatusReader(
            processClient: OneShotChildProcessClient(),
            executableURL: executable.resolvedFileURL,
            environment: childEnvironment.variables,
            sessionExpiryReader: ArkSessionExpiryReader(
                homeDirectory: URL(
                    fileURLWithPath: childEnvironment.variables["HOME"]
                        ?? NSHomeDirectory(),
                    isDirectory: true
                )
            )
        )
        let planMetadataReader = ArkPlanMetadataReader(
            processClient: OneShotChildProcessClient(),
            executableURL: executable.resolvedFileURL,
            environment: childEnvironment.variables
        )
        return ArkProviderAdapter(
            processClient: OneShotChildProcessClient(),
            authenticationStatusReader: authReader,
            planMetadataReader: planMetadataReader,
            executableURL: executable.resolvedFileURL,
            environment: childEnvironment.variables,
            cliVersion: .unverified
        )
    }

    private static func runtimePathEntries(
        environment: [String: String],
        homeDirectoryURL: URL
    ) -> [String] {
        let inherited = environment["PATH"]?
            .split(separator: ":", omittingEmptySubsequences: false)
            .map(String.init) ?? []
        return inherited + [
            "/opt/homebrew/bin",
            "/usr/local/bin",
            homeDirectoryURL.appendingPathComponent(".local/bin", isDirectory: true).path,
            homeDirectoryURL.appendingPathComponent(".npm-global/bin", isDirectory: true).path
        ]
    }

    private static func explicitExecutableURL(
        providerID: ProviderID,
        defaults: UserDefaults
    ) -> URL? {
        guard let path = defaults.string(
            forKey: executablePathKey(for: providerID)
        )?.trimmingCharacters(in: .whitespacesAndNewlines),
        !path.isEmpty else {
            return nil
        }
        return URL(fileURLWithPath: path, isDirectory: false)
    }

    private static func refreshPolicy(
        providerID: ProviderID,
        defaults: UserDefaults
    ) -> RefreshPolicy {
        let globalFrequency = ProviderRefreshFrequency.validated(
            storedSeconds: defaults.integer(
                forKey: ProviderPreferenceKey.globalRefreshSeconds
            )
        )
        let override = ProviderRefreshOverride.validated(
            storedSeconds: defaults.integer(
                forKey: refreshOverrideKey(for: providerID)
            )
        )
        return ProviderRefreshPolicyResolver.policy(
            providerID: providerID,
            globalFrequency: globalFrequency,
            override: override
        )
    }

    private static func quotaCacheConfiguration()
        -> ProviderQuotaDiskCacheConfiguration? {
        guard let applicationSupportDirectory = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            return nil
        }
        return try? ProviderQuotaDiskCacheConfiguration(
            applicationSupportDirectory: applicationSupportDirectory,
            versionedRelativeDirectory: ["Usage-Butler", "quota-cache", "v1"]
        )
    }

    private static func memoryHistoryStore() -> (any MemoryHistoryStore)? {
        guard let applicationSupportDirectory = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first,
        let configuration = try? MemoryHistoryDiskStoreConfiguration(
            applicationSupportDirectory: applicationSupportDirectory,
            versionedRelativeDirectory: ["Usage-Butler", "memory-history", "v1"]
        ) else {
            return nil
        }
        return MemoryHistoryDiskStore(configuration: configuration)
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

    private static func missingExecutableFailure(
        providerID: ProviderID
    ) -> ProviderFailure {
        ProviderFailure(
            code: .missingExecutable,
            retryClass: .afterRecovery,
            userMessageKey: "provider.failure.missing-executable",
            diagnosticCode: "runtime.\(providerID.rawValue).executable.missing",
            recovery: .selectExecutable
        )
    }

    private static func environmentFailure(
        providerID: ProviderID
    ) -> ProviderFailure {
        ProviderFailure(
            code: .processFailed,
            retryClass: .never,
            userMessageKey: "provider.failure.invalid-process-environment",
            diagnosticCode: "runtime.\(providerID.rawValue).environment.invalid",
            recovery: nil
        )
    }
}

private actor UnavailableRuntimeProviderAdapter: ProviderAdapter {
    nonisolated let id: ProviderID
    nonisolated let capabilities: ProviderCapabilities

    private let failure: ProviderFailure
    private var isShutdown = false

    init(
        id: ProviderID,
        capabilities: ProviderCapabilities,
        failure: ProviderFailure
    ) {
        self.id = id
        self.capabilities = capabilities
        self.failure = failure
    }

    func discover() async -> DiscoveryResult {
        .failure(currentFailure())
    }

    func read(scope: ProviderScope) async -> ProviderReadResult {
        .failure(currentFailure())
    }

    func login(method: LoginMethod) async -> LoginResult {
        .failure(currentFailure())
    }

    func diagnosticSnapshot() async -> SafeProviderDiagnostic {
        SafeProviderDiagnostic(
            providerID: id,
            capturedAt: Date(),
            diagnosticCode: failure.diagnosticCode,
            safeFields: [
                "state": isShutdown ? "shutdown" : "unavailable",
                "failure": failure.code.rawValue
            ]
        )
    }

    func shutdown() async {
        isShutdown = true
    }

    private func currentFailure() -> ProviderFailure {
        guard isShutdown else { return failure }
        return ProviderFailure(
            code: .shutdown,
            retryClass: .never,
            userMessageKey: "provider.failure.shutdown",
            diagnosticCode: "runtime.\(id.rawValue).shutdown",
            recovery: nil
        )
    }
}

private actor RuntimeVolatileProviderQuotaCache: ProviderQuotaCache {
    private var dataByProvider: [ProviderID: ProviderQuotaData] = [:]
    private var acceptsOperations = true

    func load(providerID: ProviderID) async -> ProviderQuotaCacheLoadResult {
        guard acceptsOperations else { return .failure(shutdownFailure) }
        if let data = dataByProvider[providerID] {
            return .hit(data)
        }
        return .miss
    }

    func save(_ data: ProviderQuotaData) async -> ProviderQuotaCacheWriteResult {
        guard acceptsOperations else { return .failure(shutdownFailure) }
        dataByProvider[data.providerID] = data
        return .success(writtenAt: Date())
    }

    func clear(providerID: ProviderID) async -> ProviderQuotaCacheClearResult {
        guard acceptsOperations else { return .failure(shutdownFailure) }
        let removed = dataByProvider.removeValue(forKey: providerID) != nil
        return .success(clearedAt: Date(), removedEntry: removed)
    }

    func shutdown() async {
        acceptsOperations = false
        dataByProvider.removeAll()
    }

    private var shutdownFailure: ProviderFailure {
        ProviderFailure(
            code: .shutdown,
            retryClass: .never,
            userMessageKey: "provider.failure.shutdown",
            diagnosticCode: "runtime.cache.shutdown",
            recovery: nil
        )
    }
}
