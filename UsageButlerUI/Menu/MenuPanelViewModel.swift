import Combine
import Foundation
import UsageButlerCore
import UsageButlerDomain

public enum MenuPage: String, CaseIterable, Identifiable {
    case quota
    case memory
    case network

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .quota: String(localized: "额度")
        case .memory: String(localized: "内存")
        case .network: String(localized: "网络")
        }
    }
}

public enum SettingsPage: String, CaseIterable, Identifiable {
    case general
    case network

    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .general: String(localized: "通用与额度")
        case .network: String(localized: "网络")
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

/// Trend window for the network page. Same steps as the memory range but a
/// different default (1 h per PRD NET-02), so it is its own type.
public enum NetworkTrendRange: String, CaseIterable, Identifiable {
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

    public var duration: TimeInterval {
        switch self {
        case .oneMinute: 60
        case .tenMinutes: 600
        case .thirtyMinutes: 1_800
        case .oneHour: 3_600
        case .twoHours: 7_200
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
    public let events: [ProviderDiagnosticEvent]
    public let journalAvailable: Bool

    public var id: ProviderID { providerID }

    fileprivate init(snapshot: SafeProviderDiagnostic) {
        providerID = snapshot.providerID
        events = Array(snapshot.events.suffix(20).reversed())
        journalAvailable = snapshot.journalAvailable
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
            onNetworkPageVisibilityChanged?(selectedPage == .network)
        }
    }
    @Published public var memoryRange: MemoryRange = .oneMinute
    @Published public var settingsPage: SettingsPage = .general
    /// Trend window on the network page; defaults to 1 h per PRD NET-02.
    @Published public var networkTrendRange: NetworkTrendRange = .oneHour
    @Published public private(set) var networkSnapshot: NetworkSnapshot?
    @Published public private(set) var networkRateHistory = NetworkRateHistoryBuffer()
    public private(set) var networkHistoryRevision: UInt64 = 0
    private var networkChartCache = NetworkChartProjectionCache()
    public let processNetwork = ProcessNetworkViewModel()
    public func applyProcessNetworkSnapshot(_ value: ProcessNetworkSnapshot) { processNetwork.apply(value) }
    /// Sticky user interface choice. A vanished interface stays selected and
    /// renders unavailable; the caliber never switches silently (NET-02).
    @Published public var userSelectedNetworkInterface: String?
    /// The system's own answer about which network is connected. Supplied by
    /// the runtime so the view model stays free of SystemConfiguration.
    @Published public private(set) var networkSystemPath: NetworkSystemPath = .unreadable
    public private(set) var networkSystemPathUpdatedAt: Date?
    private var networkPathCache = NetworkPathCache()
    private let networkClock: () -> ClockReading
    @Published private var networkPathConfirmed = false
    @Published public private(set) var snapshot: Stage3AppProjection
    @Published public private(set) var settingsProviders: [Stage3ProviderProjection]
    @Published public private(set) var isManualRefreshInFlight = false
    @Published public private(set) var safeDiagnosticsState: SafeDiagnosticsLoadState = .idle
    @Published public private(set) var larkQuotaAlertChannelStatus:
        LarkQuotaAlertChannelStatus = .notChecked
    @Published public private(set) var globalShortcutText: String?

    /// Cycles the panel across 额度 → 内存 → 网络 (Tab key inside the panel).
    public func cyclePage() {
        let pages = MenuPage.allCases
        guard let index = pages.firstIndex(of: selectedPage) else { return }
        selectedPage = pages[(index + 1) % pages.count]
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
    private var onNetworkPageVisibilityChanged: ((Bool) -> Void)?
    private var onSetNetworkCollectionEnabled: ((Bool) async -> Void)?
    private var onSetGlobalShortcut: ((String?) -> Void)?
    private var onLoadLarkQuotaAlertChannelStatus:
        (@MainActor () async -> LarkQuotaAlertChannelStatus)?
    #if USAGE_BUTLER_FIXTURES
    private var fixtureEnabledProviderIDs: Set<ProviderID>?
    private var fixtureDisabledProductIDs: [ProviderID: Set<String>] = [:]
    private var fixtureNetworkCollecting = true
    #endif

    public init(
        snapshot: Stage3AppProjection,
        settingsProviders: [Stage3ProviderProjection]? = nil,
        networkClock: @escaping () -> ClockReading = {
            .init(wallTime: Date(), monotonicTime: .init(nanoseconds: DispatchTime.now().uptimeNanoseconds))
        }
    ) {
        self.networkClock = networkClock
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
        #if USAGE_BUTLER_FIXTURES
        if isFixtureMode {
            applyNetworkSnapshot(NetworkFixtureCatalog.snapshot(collecting: fixtureNetworkCollecting))
        }
        #endif
    }

    public var isFixtureMode: Bool {
        #if USAGE_BUTLER_FIXTURES
        snapshot.providers.contains { $0.origin.isFixture } || snapshot.memory.origin.isFixture
        #else
        false
        #endif
    }

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
            (@MainActor () async -> LarkQuotaAlertChannelStatus)? = nil,
        onNetworkPageVisibilityChanged: ((Bool) -> Void)? = nil,
        onSetNetworkCollectionEnabled: ((Bool) async -> Void)? = nil
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
        self.onNetworkPageVisibilityChanged = onNetworkPageVisibilityChanged
        self.onSetNetworkCollectionEnabled = onSetNetworkCollectionEnabled
        onMemoryPageVisibilityChanged(selectedPage == .memory)
        onNetworkPageVisibilityChanged?(selectedPage == .network)
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

    private var larkCheckRevision: UInt64 = 0

    public func invalidateLarkQuotaAlertChannelStatus() {
        larkCheckRevision &+= 1
        larkQuotaAlertChannelStatus = .notChecked
    }

    public func loadSettingsStatus(for page: SettingsPage) async {
        guard page == .general else { return }
        await loadLarkQuotaAlertChannelStatus()
    }

    public func loadLarkQuotaAlertChannelStatus() async {
        guard larkQuotaAlertChannelStatus != .checking else { return }
        guard let onLoadLarkQuotaAlertChannelStatus else {
            larkQuotaAlertChannelStatus = .unavailable
            return
        }

        let revision = larkCheckRevision
        larkQuotaAlertChannelStatus = .checking
        let result = await onLoadLarkQuotaAlertChannelStatus()
        guard revision == larkCheckRevision else { return }
        larkQuotaAlertChannelStatus = result
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
            now: now,
            monotonicNow: .init(nanoseconds: DispatchTime.now().uptimeNanoseconds),
            automaticRetry: projection.automaticRefresh
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
            },
            monotonicNow: .init(nanoseconds: DispatchTime.now().uptimeNanoseconds)
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

    // MARK: - Network page

    /// Whether collection is running, derived from the snapshot's state —
    /// never from the settings toggle alone.
    public var networkCollectionEnabled: Bool {
        guard let networkSnapshot else { return false }
        return networkSnapshot.collectionState != .stopped
    }

    /// See `NetworkStatusRules`: the clock is injected there so the rules are
    /// assertable without waiting.
    public var networkStatusIsHealthy: Bool { NetworkStatusRules.currentHealth(networkSnapshot, interface: resolvedNetworkInterfaceName, now: Date()).healthy }

    public var networkRatesAreStale: Bool { NetworkStatusRules.ratesAreStale(networkSnapshot, interface: resolvedNetworkInterfaceName, now: Date()) }

    public var networkCoverageNotice: String? { NetworkStatusRules.coverageNotice(networkSnapshot) }

    /// Where the numbers on this page come from, resolved from the system's own
    /// connected-network state rather than from an interface name or sort order.
    public var networkObservationResolution: NetworkObservationResolution {
        NetworkObservationPointResolver.resolve(
            path: networkPathCache.path(at: networkClock()),
            manualSelection: userSelectedNetworkInterface,
            isObserving: networkSnapshot.map { $0.collectionState != .stopped } ?? false,
            presence: { networkSnapshot?.presence(of: $0) ?? .notObserved }
        )
    }

    /// Nil in every unresolved case, so the page says "not identified" instead
    /// of quietly measuring a different network.
    public var resolvedNetworkInterfaceName: String? {
        NetworkObservationPointResolver.measurableInterface(in: networkObservationResolution)
    }

    /// True while the observation point follows the system's active network.
    public var networkObservationIsAutomatic: Bool { userSelectedNetworkInterface == nil }

    /// "Wi-Fi（en0）" when the system published a name, the bare BSD name when
    /// it did not, and never a friendly label that was inferred from a prefix.
    public var networkObservationLabel: String {
        guard case let .resolved(point) = networkObservationResolution else { return userSelectedNetworkInterface ?? "" }
        guard let display = point.displayName else { return point.interfaceName }
        return "\(display)（\(point.interfaceName)）"
    }

    /// Grouped interface list for the advanced picker; the default view never
    /// dumps every internal interface on the user.
    public var networkAdvancedInterfaceGroups: [NetworkInterfaceGroup] {
        NetworkObservationPointResolver.advancedGroups(
            interfaces: networkSnapshot?.interfaces ?? [:]
        )
    }

    public func networkInterfaceOptionTitle(_ name: String) -> String {
        switch networkSnapshot?.presence(of: name) ?? .notObserved {
        case .present: return name
        case .missing: return "\(name) · 已消失"
        case .unknown: return "\(name) · 存在状态未知"
        case .notObserved: return "\(name) · 未观察"
        }
    }

    /// Picker value: the empty string means "follow the system's active
    /// network", which is also what a fresh install does.
    public static let automaticNetworkObservationValue = ""

    public var networkObservationSelection: String {
        get { userSelectedNetworkInterface ?? Self.automaticNetworkObservationValue }
        set { userSelectedNetworkInterface = newValue.isEmpty ? nil : newValue }
    }

    /// Where the current observation point came from, stated plainly so the
    /// page never implies it measured something it did not.
    public var networkObservationSourceText: String {
        switch networkObservationResolution {
        case let .resolved(point):
            switch point.resolution {
            case .systemConfirmed:
                return String(localized: "自动 · 跟随系统当前连接的网络")
            case .manuallySelected:
                return String(localized: "手动选择 · 切换网络时不会跟随")
            }
        case let .presenceUnknown(name):
            return "\(networkObservationIsAutomatic ? "自动" : "手动选择") · \(name) 存在状态未知 · 数值显示为未知"
        case let .notObserved(name):
            return "\(name ?? "当前网络") · 未观察 · 启用采集后确认"
        case let .manualUnavailable(name):
            return String(localized: "手动选择的 \(name) 已消失 · 数值显示为未知")
        case let .notSampled(name):
            return String(localized: "自动 · 系统连接的是 \(name)，尚未采集到它的样本")
        case .noActiveNetwork:
            return String(localized: "自动 · 系统当前没有活动网络")
        case .systemStateUnreadable:
            return String(localized: "无法读取系统网络状态 · 不猜测接口")
        }
    }

    public func setNetworkObservationAutomatic() {
        userSelectedNetworkInterface = nil
    }

    public func setNetworkSystemPath(_ path: NetworkSystemPath, at date: Date? = nil) {
        let reading = networkClock()
        networkPathCache.record(path, at: .init(wallTime: date ?? reading.wallTime, monotonicTime: reading.monotonicTime))
        networkSystemPath = networkPathCache.retainedPath
        networkSystemPathUpdatedAt = networkPathCache.lastConfirmation?.wallTime
        tickNetworkPathFreshness()
    }

    public func refreshNetworkSystemPath(using reader: any NetworkPathProviding) {
        guard networkPathCache.shouldRead(at: networkClock()) else { return }
        setNetworkSystemPath(reader.currentPath())
    }

    public func invalidateNetworkSystemPath() {
        networkPathCache.invalidate()
        tickNetworkPathFreshness()
    }

    /// Independent settings/panel timers call this even with no source events.
    public func tickNetworkPathFreshness() {
        let fresh = networkPathCache.isFresh(at: networkClock())
        if networkPathConfirmed != fresh { networkPathConfirmed = fresh }
    }

    public var settingsSourceDisclosure: String {
        #if USAGE_BUTLER_FIXTURES
        if isFixtureMode { return "演示数据 · 非本机采集" }
        #endif
        return "本机运行时 · 只读"
    }

    /// The exact points the trend chart will draw for one window. Exposed so
    /// acceptance can compare what was rendered against what was sampled; the
    /// view must not keep this rule to itself.
    public func networkTrendProjection(
        now: Date,
        window: TimeInterval
    ) -> NetworkChartProjection {
        networkTrendFrame(now: now, window: window).projection
    }

    public func networkTrendFrame(now: Date, window: TimeInterval) -> NetworkTrendFrame {
        // A sticky manual selection may still inspect retained history while
        // current values and presence remain unavailable.
        let name = userSelectedNetworkInterface ?? resolvedNetworkInterfaceName ?? ""
        return networkChartCache.frame(samples: networkRateHistory.series(for: name),
            revision: networkHistoryRevision, interface: name, now: now, window: window)
    }

    /// Applies one complete replacement snapshot: the projection replaces the
    /// previous one wholesale, rate history accumulates per interface, and
    /// vanished interfaces are pruned from the trend buffer.
    public func applyNetworkSnapshot(_ snapshot: NetworkSnapshot) {
        networkSnapshot = snapshot
        #if USAGE_BUTLER_FIXTURES
        if isFixtureMode {
            setNetworkSystemPath(NetworkFixtureCatalog.systemPath)
        }
        #endif
        var history = networkRateHistory
        history.record(snapshot)
        history.prune(keeping: Set(snapshot.interfaces.keys))
        if history != networkRateHistory {
            networkHistoryRevision &+= 1
            networkRateHistory = history
        }
    }

    public func setNetworkCollectionEnabled(_ enabled: Bool) {
        #if USAGE_BUTLER_FIXTURES
        if isFixtureMode {
            fixtureNetworkCollecting = enabled
            applyNetworkSnapshot(NetworkFixtureCatalog.snapshot(collecting: enabled))
            return
        }
        #endif
        guard let onSetNetworkCollectionEnabled else { return }
        Task { await onSetNetworkCollectionEnabled(enabled) }
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
        applyNetworkSnapshot(NetworkFixtureCatalog.snapshot(now: now, collecting: fixtureNetworkCollecting))
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
