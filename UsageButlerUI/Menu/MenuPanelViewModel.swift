import Combine
import Foundation
import UsageButlerCore
import UsageButlerDomain

public enum MenuPage: String, CaseIterable, Identifiable {
    case quota
    case memory

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .quota: String(localized: "额度")
        case .memory: String(localized: "内存")
        }
    }
}

public enum MemoryRange: String, CaseIterable, Identifiable {
    case oneMinute = "1m"
    case tenMinutes = "10m"
    case thirtyMinutes = "30m"
    case oneHour = "1h"
    case twoHours = "2h"

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .oneMinute: String(localized: "1 分钟")
        case .tenMinutes: String(localized: "10 分钟")
        case .thirtyMinutes: String(localized: "30 分钟")
        case .oneHour: String(localized: "1 小时")
        case .twoHours: String(localized: "2 小时")
        }
    }
}

public struct SafeDiagnosticField: Equatable, Identifiable, Sendable {
    public let key: String
    public let value: String

    public var id: String { key }
}

public struct SafeProviderDiagnosticPresentation: Equatable, Identifiable, Sendable {
    public let providerID: ProviderID
    public let diagnosticCode: String
    public let safeFields: [SafeDiagnosticField]

    public var id: ProviderID { providerID }

    fileprivate init(snapshot: SafeProviderDiagnostic) {
        providerID = snapshot.providerID
        diagnosticCode = Self.safeDiagnosticCode(snapshot.diagnosticCode)
        let allowedKeys = Self.allowedSafeFieldKeys(for: snapshot.providerID)
        safeFields = snapshot.safeFields
            .compactMap { key, value in
                guard allowedKeys.contains(key),
                      Self.isSafeField(key: key, value: value) else {
                    return nil
                }
                return SafeDiagnosticField(key: key, value: value)
            }
            .sorted { $0.key < $1.key }
    }

    private static func safeDiagnosticCode(_ code: String) -> String {
        guard !code.isEmpty, code.count <= 160,
              code.unicodeScalars.allSatisfy({ scalar in
                  CharacterSet.alphanumerics.contains(scalar)
                      || "._-".unicodeScalars.contains(scalar)
              }) else {
            return "diagnostic.code.invalid"
        }
        return code
    }

    private static func isSafeField(key: String, value: String) -> Bool {
        guard !key.isEmpty, key.count <= 80, value.count <= 256,
              key.unicodeScalars.allSatisfy({ scalar in
                  CharacterSet.alphanumerics.contains(scalar)
                      || "._-".unicodeScalars.contains(scalar)
              }),
              !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
        else {
            return false
        }

        let normalizedKey = key.lowercased().filter {
            $0.isLetter || $0.isNumber
        }
        let permittedIdentityBoolean = normalizedKey == "sourceidentityvalid"
        let blockedKeyFragments = [
            "raw", "payload", "stdout", "stderr", "account", "email",
            "token", "apikey", "secret", "credential", "authorization",
            "proxy", "homepath", "executablepath", "localpath"
        ]
        guard !blockedKeyFragments.contains(where: normalizedKey.contains),
              permittedIdentityBoolean || !normalizedKey.contains("identity")
        else {
            return false
        }

        let lowercasedValue = value.lowercased()
        return !value.hasPrefix("/")
            && !value.hasPrefix("~/")
            && !lowercasedValue.hasPrefix("file://")
            && !lowercasedValue.hasPrefix("http://")
            && !lowercasedValue.hasPrefix("https://")
            && !value.contains("@")
    }

    private static func allowedSafeFieldKeys(for providerID: ProviderID) -> Set<String> {
        let unavailableAdapterKeys: Set<String> = ["state", "failure"]
        switch providerID {
        case .openAI:
            return unavailableAdapterKeys.union([
                "transport",
                "last_operation",
                "last_outcome",
                "rate_limit_source",
                "valid_bucket_count",
                "invalid_bucket_count",
                "invalid_window_count",
                "invalid_credit_count",
                "invalid_reset_detail_count",
                "invalid_reset_summary_count",
                "invalid_product_identity_count",
                "invalid_balance_count",
                "source_identity_valid",
                "shutdown"
            ])
        case .miniMax:
            return unavailableAdapterKeys.union([
                "adapter",
                "cliVersion",
                "errorClass",
                "schema"
            ])
        case .ark:
            return unavailableAdapterKeys.union([
                "adapter",
                "cliVersion",
                "errorClass",
                "schema",
                "parserCode",
                "parserPath",
                "supportedItems",
                "unsupportedItems",
                "droppedSupportedItems",
                "droppedUnsupportedItems",
                "droppedUnclassifiedItems"
            ])
        }
    }
}

public enum SafeDiagnosticsUnavailableReason: Equatable, Sendable {
    #if USAGE_BUTLER_FIXTURES
    case offlineFixture
    #endif
    case runtimeCompositionUnavailable
}

public enum SafeDiagnosticsFailureReason: Equatable, Sendable {
    case actionUnavailable
    case runtimeShuttingDown
}

public enum SafeDiagnosticsLoadResult: Equatable, Sendable {
    case loaded([SafeProviderDiagnostic])
    case unavailable(SafeDiagnosticsUnavailableReason)
    case failed(SafeDiagnosticsFailureReason)
}

public enum SafeDiagnosticsLoadState: Equatable, Sendable {
    case idle
    case loading
    case loaded([SafeProviderDiagnosticPresentation])
    case unavailable(SafeDiagnosticsUnavailableReason)
    case failed(SafeDiagnosticsFailureReason)
}

public enum LarkQuotaAlertChannelStatus: Equatable, Sendable {
    case notChecked
    case checking
    case ready
    case needsSetup
    case needsChatID
    case unavailable
}

@MainActor
public final class MenuPanelViewModel: ObservableObject {
    @Published public var selectedPage: MenuPage = .quota {
        didSet {
            guard selectedPage != oldValue else { return }
            onMemoryPageVisibilityChanged?(selectedPage == .memory)
        }
    }
    @Published public var memoryRange: MemoryRange = .oneMinute
    @Published public private(set) var snapshot: Stage3AppProjection
    @Published public private(set) var settingsProviders: [Stage3ProviderProjection]
    @Published public private(set) var isManualRefreshInFlight = false
    @Published public private(set) var safeDiagnosticsState: SafeDiagnosticsLoadState = .idle
    @Published public private(set) var larkQuotaAlertChannelStatus:
        LarkQuotaAlertChannelStatus = .notChecked
    @Published public private(set) var globalShortcutText: String?

    /// Cycles the panel between 额度 and 内存 (Tab key inside the panel).
    public func cyclePage() {
        selectedPage = selectedPage == .quota ? .memory : .quota
    }

    private var onPanelPresented: (() -> Void)?
    private var onManualRefresh: (() async -> Void)?
    private var onSetProviderEnabled: ((ProviderID, Bool) -> Void)?
    private var onSetGlobalRefreshFrequency: ((ProviderRefreshFrequency) -> Void)?
    private var onSetProviderRefreshOverride: ((
        ProviderID,
        ProviderRefreshOverride
    ) -> Void)?
    private var onRedetectProvider: ((ProviderID) -> Void)?
    private var onLoginProvider: ((
        ProviderID,
        ProviderLoginRequest
    ) async -> ProviderLoginFeedback)?
    private var onSelectProviderExecutable: ((ProviderID) async -> ProviderExecutableSelectionFeedback)?
    private var onClearQuotaCache: (() async -> CacheClearFeedback)?
    private var onLoadSafeDiagnostics: (@MainActor () async -> SafeDiagnosticsLoadResult)?
    private var onMemoryPageVisibilityChanged: ((Bool) -> Void)?
    private var onSetGlobalShortcut: ((String?) -> Void)?
    private var onLoadLarkQuotaAlertChannelStatus:
        (@MainActor () async -> LarkQuotaAlertChannelStatus)?
    #if USAGE_BUTLER_FIXTURES
    private var fixtureEnabledProviderIDs: Set<ProviderID>?
    private var fixtureDisabledProductIDs: [ProviderID: Set<String>] = [:]
    #endif

    public init(
        snapshot: Stage3AppProjection,
        settingsProviders: [Stage3ProviderProjection]? = nil
    ) {
        let fullSettings = (settingsProviders ?? snapshot.providers)
            .sorted { $0.id.canonicalOrder < $1.id.canonicalOrder }
        self.settingsProviders = fullSettings
        #if USAGE_BUTLER_FIXTURES
        if snapshot.providers.contains(where: { $0.origin.isFixture })
            || snapshot.memory.origin.isFixture {
            fixtureEnabledProviderIDs = Set(snapshot.providers.map(\.id))
        }
        #endif
        let filteredProviders = snapshot.providers.map { provider in
            guard let full = fullSettings.first(where: { $0.id == provider.id }) else {
                return provider
            }
            let filtered = full.products.filter { product in
                guard let sourceID = product.sourceProductID else { return true }
                return ProviderPreferenceKey.isProductEnabled(providerID: provider.id, sourceProductID: sourceID)
            }
            return provider.withProducts(filtered)
        }
        #if USAGE_BUTLER_FIXTURES
        if snapshot.providers.contains(where: { $0.origin.isFixture })
            || snapshot.memory.origin.isFixture {
            self.snapshot = Stage3AppProjection(
                scenario: snapshot.scenario,
                providers: filteredProviders.sorted { $0.id.canonicalOrder < $1.id.canonicalOrder },
                memory: snapshot.memory
            )
        } else {
            self.snapshot = Stage3AppProjection(
                providers: filteredProviders.sorted { $0.id.canonicalOrder < $1.id.canonicalOrder },
                memory: snapshot.memory
            )
        }
        #else
        self.snapshot = Stage3AppProjection(
            providers: filteredProviders.sorted { $0.id.canonicalOrder < $1.id.canonicalOrder },
            memory: snapshot.memory
        )
        #endif
    }

    #if USAGE_BUTLER_FIXTURES
    public var isFixtureMode: Bool {
        snapshot.providers.contains { $0.origin.isFixture } || snapshot.memory.origin.isFixture
    }
    #endif

    public func configureRuntimeActions(
        onPanelPresented: @escaping () -> Void,
        onManualRefresh: @escaping () async -> Void,
        onSetProviderEnabled: @escaping (ProviderID, Bool) -> Void,
        onSetGlobalRefreshFrequency: @escaping (ProviderRefreshFrequency) -> Void,
        onSetProviderRefreshOverride: @escaping (
            ProviderID,
            ProviderRefreshOverride
        ) -> Void,
        onRedetectProvider: @escaping (ProviderID) -> Void,
        onLoginProvider: @escaping (
            ProviderID,
            ProviderLoginRequest
        ) async -> ProviderLoginFeedback,
        onSelectProviderExecutable: @escaping (
            ProviderID
        ) async -> ProviderExecutableSelectionFeedback,
        onClearQuotaCache: @escaping () async -> CacheClearFeedback,
        onLoadSafeDiagnostics: @escaping @MainActor () async -> SafeDiagnosticsLoadResult,
        onMemoryPageVisibilityChanged: @escaping (Bool) -> Void,
        onSetGlobalShortcut: ((String?) -> Void)? = nil,
        onLoadLarkQuotaAlertChannelStatus:
            (@MainActor () async -> LarkQuotaAlertChannelStatus)? = nil
    ) {
        self.onPanelPresented = onPanelPresented
        self.onManualRefresh = onManualRefresh
        self.onSetProviderEnabled = onSetProviderEnabled
        self.onSetGlobalRefreshFrequency = onSetGlobalRefreshFrequency
        self.onSetProviderRefreshOverride = onSetProviderRefreshOverride
        self.onRedetectProvider = onRedetectProvider
        self.onLoginProvider = onLoginProvider
        self.onSelectProviderExecutable = onSelectProviderExecutable
        self.onClearQuotaCache = onClearQuotaCache
        self.onLoadSafeDiagnostics = onLoadSafeDiagnostics
        self.onMemoryPageVisibilityChanged = onMemoryPageVisibilityChanged
        self.onSetGlobalShortcut = onSetGlobalShortcut
        self.onLoadLarkQuotaAlertChannelStatus =
            onLoadLarkQuotaAlertChannelStatus
        onMemoryPageVisibilityChanged(selectedPage == .memory)
    }

    /// Persists (nil clears) the global panel shortcut.
    public func setGlobalShortcut(_ serialized: String?) {
        onSetGlobalShortcut?(serialized)
    }

    public func updateGlobalShortcutText(_ text: String?) {
        globalShortcutText = text
    }

    public func panelPresented() {
        onPanelPresented?()
    }

    public func requestManualRefresh() {
        guard !isManualRefreshInFlight else { return }
        guard let onManualRefresh else {
            #if USAGE_BUTLER_FIXTURES
            refreshPreview()
            #endif
            return
        }

        isManualRefreshInFlight = true
        Task { @MainActor [weak self] in
            await onManualRefresh()
            self?.isManualRefreshInFlight = false
        }
    }

    public func setProviderEnabled(_ providerID: ProviderID, enabled: Bool) {
        onSetProviderEnabled?(providerID, enabled)
    }

    public func setGlobalRefreshFrequency(_ frequency: ProviderRefreshFrequency) {
        onSetGlobalRefreshFrequency?(frequency)
    }

    public func setProviderRefreshOverride(
        _ providerID: ProviderID,
        override: ProviderRefreshOverride
    ) {
        onSetProviderRefreshOverride?(providerID, override)
    }

    public func redetectProvider(_ providerID: ProviderID) {
        onRedetectProvider?(providerID)
    }

    public func loginProvider(
        _ providerID: ProviderID,
        request: ProviderLoginRequest
    ) async -> ProviderLoginFeedback {
        guard let onLoginProvider else {
            #if USAGE_BUTLER_FIXTURES
            return isFixtureMode ? .offlineFixture : .failed
            #else
            return .failed
            #endif
        }
        return await onLoginProvider(providerID, request)
    }

    public func selectProviderExecutable(
        _ providerID: ProviderID
    ) async -> ProviderExecutableSelectionFeedback {
        guard let onSelectProviderExecutable else {
            #if USAGE_BUTLER_FIXTURES
            return isFixtureMode ? .offlineFixture : .failed
            #else
            return .failed
            #endif
        }
        return await onSelectProviderExecutable(providerID)
    }

    #if USAGE_BUTLER_FIXTURES
    public func applyFixtureProviderVisibility(
        _ providerID: ProviderID,
        enabled: Bool
    ) {
        guard isFixtureMode else { return }
        if enabled {
            fixtureEnabledProviderIDs?.insert(providerID)
        } else {
            fixtureEnabledProviderIDs?.remove(providerID)
        }
        let visibleProviders = settingsProviders.filter {
            fixtureEnabledProviderIDs?.contains($0.id) ?? true
        }
        replaceSnapshot(providers: visibleProviders)
    }
    #endif

    public func clearQuotaCache() async -> CacheClearFeedback {
        guard let onClearQuotaCache else {
            #if USAGE_BUTLER_FIXTURES
            return isFixtureMode ? .offlineFixture : .failed
            #else
            return .failed
            #endif
        }
        return await onClearQuotaCache()
    }

    public func loadSafeDiagnostics() async {
        guard safeDiagnosticsState != .loading else { return }
        guard let onLoadSafeDiagnostics else {
            safeDiagnosticsState = .failed(.actionUnavailable)
            return
        }

        safeDiagnosticsState = .loading
        switch await onLoadSafeDiagnostics() {
        case let .loaded(snapshots):
            safeDiagnosticsState = .loaded(
                snapshots
                    .map(SafeProviderDiagnosticPresentation.init(snapshot:))
                    .sorted { $0.providerID.canonicalOrder < $1.providerID.canonicalOrder }
            )
        case let .unavailable(reason):
            safeDiagnosticsState = .unavailable(reason)
        case let .failed(reason):
            safeDiagnosticsState = .failed(reason)
        }
    }

    public func loadLarkQuotaAlertChannelStatus() async {
        guard larkQuotaAlertChannelStatus != .checking else { return }
        guard let onLoadLarkQuotaAlertChannelStatus else {
            larkQuotaAlertChannelStatus = .unavailable
            return
        }

        larkQuotaAlertChannelStatus = .checking
        larkQuotaAlertChannelStatus = await onLoadLarkQuotaAlertChannelStatus()
    }

    public func isProductEnabled(providerID: ProviderID, productID: String) -> Bool {
        #if USAGE_BUTLER_FIXTURES
        if isFixtureMode, let disabled = fixtureDisabledProductIDs[providerID] {
            return !disabled.contains(productID)
        }
        #endif
        return ProviderPreferenceKey.isProductEnabled(providerID: providerID, sourceProductID: productID)
    }

    public func setProductEnabled(
        _ providerID: ProviderID,
        productID: String,
        enabled: Bool
    ) {
        #if USAGE_BUTLER_FIXTURES
        if isFixtureMode {
            if enabled {
                fixtureDisabledProductIDs[providerID]?.remove(productID)
            } else {
                if fixtureDisabledProductIDs[providerID] == nil {
                    fixtureDisabledProductIDs[providerID] = []
                }
                fixtureDisabledProductIDs[providerID]?.insert(productID)
            }
        } else {
            let key = ProviderPreferenceKey.productEnabledKey(for: providerID, sourceProductID: productID)
            UserDefaults.standard.set(enabled, forKey: key)
        }
        #else
        let key = ProviderPreferenceKey.productEnabledKey(for: providerID, sourceProductID: productID)
        UserDefaults.standard.set(enabled, forKey: key)
        #endif

        reapplyProductFilters()
    }

    public func reapplyProductFilters() {
        let visible = snapshot.providers.map { provider in
            guard let full = settingsProviders.first(where: { $0.id == provider.id }) else {
                return provider
            }
            let filtered = full.products.filter { product in
                guard let sourceID = product.sourceProductID else { return true }
                return isProductEnabled(providerID: provider.id, productID: sourceID)
            }
            return provider.withProducts(filtered)
        }
        replaceSnapshot(providers: visible)
    }

    public func applyProviderProjection(
        _ projection: ProviderProjection,
        now: Date
    ) {
        let settingsProjection = LiveProviderProjectionMapper.map(
            projection.state,
            now: now
        )
        settingsProviders = replacing(
            provider: settingsProjection,
            in: settingsProviders
        )

        var visibleProviders = snapshot.providers
        if let visibleProjection = LiveProviderProjectionMapper.map(
            projection,
            now: now,
            isProductEnabled: { [weak self] providerID, productID in
                self?.isProductEnabled(providerID: providerID, productID: productID) ?? true
            }
        ) {
            visibleProviders = replacing(
                provider: visibleProjection,
                in: visibleProviders
            )
        } else {
            visibleProviders.removeAll { $0.id == projection.state.id }
        }
        replaceSnapshot(providers: visibleProviders)
    }

    public func applyMemoryProjection(_ memory: Stage3MemoryProjection) {
        replaceSnapshot(memory: memory)
    }

    #if USAGE_BUTLER_FIXTURES
    public func refreshPreview(now: Date = Date()) {
        let refreshed = Stage3FixtureCatalog.projection(
            scenario: snapshot.scenario,
            now: now
        )
        settingsProviders = refreshed.providers
            .sorted { $0.id.canonicalOrder < $1.id.canonicalOrder }
        snapshot = Stage3AppProjection(
            scenario: refreshed.scenario,
            providers: refreshed.providers.filter {
                fixtureEnabledProviderIDs?.contains($0.id) ?? true
            },
            memory: refreshed.memory
        )
    }
    #endif

    private func replaceSnapshot(
        providers: [Stage3ProviderProjection]? = nil,
        memory: Stage3MemoryProjection? = nil
    ) {
        #if USAGE_BUTLER_FIXTURES
        if isFixtureMode {
            snapshot = Stage3AppProjection(
                scenario: snapshot.scenario,
                providers: (providers ?? snapshot.providers)
                    .sorted { $0.id.canonicalOrder < $1.id.canonicalOrder },
                memory: memory ?? snapshot.memory
            )
            return
        }
        #endif
        snapshot = Stage3AppProjection(
            providers: (providers ?? snapshot.providers)
                .sorted { $0.id.canonicalOrder < $1.id.canonicalOrder },
            memory: memory ?? snapshot.memory
        )
    }

    private func replacing(
        provider: Stage3ProviderProjection,
        in providers: [Stage3ProviderProjection]
    ) -> [Stage3ProviderProjection] {
        var updated = providers.filter { $0.id != provider.id }
        updated.append(provider)
        return updated.sorted { $0.id.canonicalOrder < $1.id.canonicalOrder }
    }
}

public enum CacheClearFeedback: Equatable, Sendable {
    case completed
    #if USAGE_BUTLER_FIXTURES
    case offlineFixture
    #endif
    case failed
}

public enum ProviderLoginFeedback: Equatable, Sendable {
    case verifiedFresh
    case authorizationNotRenewed
    case verificationFailed(FailureCode?)
    case rateLimited
    case flowFailed
    case cancelled
    case busy
    case disabled
    case unsupported
    #if USAGE_BUTLER_FIXTURES
    case offlineFixture
    #endif
    case failed
}

public enum ProviderLoginRequest: Equatable, Sendable {
    case start
    case cancel
}

public enum ProviderExecutableSelectionFeedback: Equatable, Sendable {
    case savedRequiresRelaunch
    case cancelled
    case invalidSelection
    #if USAGE_BUTLER_FIXTURES
    case offlineFixture
    #endif
    case failed
}
