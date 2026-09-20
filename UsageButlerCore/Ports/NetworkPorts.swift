import Foundation
import UsageButlerDomain

/// User preferences for network observation. `collectionEnabled` is a
/// preference only; it never implies the collector is actually active, which
/// is reported by the snapshot's `collectionState`.
public struct NetworkSettings: Equatable, Sendable {
    public var collectionEnabled: Bool
    public var retention: NetworkHistoryRetention
    public var uploadAlertThresholdBytes: UInt64
    public var notificationsEnabled: Bool

    public init(
        collectionEnabled: Bool = false,
        retention: NetworkHistoryRetention = .hours24,
        uploadAlertThresholdBytes: UInt64 = 10 * 1000 * 1000,
        notificationsEnabled: Bool = false
    ) {
        self.collectionEnabled = collectionEnabled
        self.retention = retention
        // 1–10000 MB integer range per PRD NET-10.
        let minBytes: UInt64 = 1_000_000
        let maxBytes: UInt64 = 10_000_000_000
        self.uploadAlertThresholdBytes = min(max(uploadAlertThresholdBytes, minBytes), maxBytes)
        self.notificationsEnabled = notificationsEnabled
    }

    /// New installs default to not collecting: the user enables capture from
    /// the network page explicitly.
    public static let `default` = NetworkSettings()
}

public enum NetworkHistoryRetention: String, CaseIterable, Equatable, Sendable {
    case hours1
    case hours24
    case days7

    public var duration: Duration {
        switch self {
        case .hours1: .seconds(3_600)
        case .hours24: .seconds(86_400)
        case .days7: .seconds(604_800)
        }
    }
}

/// Streams observation events and reports live capabilities. Implementations
/// own exactly one capture session at a time; closing the panel must not
/// stop a started stream.
public protocol NetworkObservationSource: Sendable {
    func events() -> AsyncStream<NetworkSourceEvent>
    func capabilities() async -> NetworkCapabilities
    func currentSessionID() async -> CaptureSessionID
}

public enum NetworkStoreFailure: Error, Equatable, Sendable {
    case corrupt
    case unsupportedVersion
    case io
    case shutdown
}

public protocol NetworkSettingsStore: Sendable {
    func load() async -> Result<NetworkSettings, NetworkStoreFailure>
    func save(_ settings: NetworkSettings) async -> Result<Void, NetworkStoreFailure>
}

/// Watched apps keyed by `AppIdentity.stableKey`, with per-app threshold
/// overrides. Watching is a local preference; it never grants notification
/// permission or enables interception.
public protocol NetworkWatchlistStore: Sendable {
    func load() async -> Result<[String: UInt64?], NetworkStoreFailure>
    func save(_ watchlist: [String: UInt64?]) async -> Result<Void, NetworkStoreFailure>
}

public struct NetworkHistoryQuery: Equatable, Sendable {
    public let range: ClosedRange<Date>
    public let appKey: String?

    public init(range: ClosedRange<Date>, appKey: String? = nil) {
        self.range = range
        self.appKey = appKey
    }
}

/// Read-back answers with the actual earliest sample and truncation, never a
/// fabricated complete history.
public struct NetworkHistoryReadback: Equatable, Sendable {
    public let snapshots: [NetworkSnapshot]
    public let earliestSampleAt: Date?
    public let truncated: Bool
    public let truncationReason: String?

    public init(snapshots: [NetworkSnapshot], earliestSampleAt: Date?, truncated: Bool, truncationReason: String?) {
        self.snapshots = snapshots
        self.earliestSampleAt = earliestSampleAt
        self.truncated = truncated
        self.truncationReason = truncationReason
    }
}

public protocol NetworkHistoryStore: Sendable {
    func query(_ query: NetworkHistoryQuery) async -> Result<NetworkHistoryReadback, NetworkStoreFailure>
    /// Clears network history only; watchlist and rules survive. A new
    /// statistics epoch begins after clearing.
    func clear() async -> Result<Void, NetworkStoreFailure>
}

public enum NetworkExportScope: Equatable, Sendable {
    /// Current filtered overview list.
    case overviewList(filterDescription: String)
    /// One app's detail.
    case appDetail(appKey: String)
}

/// Default export redacts hostnames/IPs/paths and the identifiable app list;
/// complete target metadata is included only when the user opts in for this
/// export. Payloads, headers, credentials and full command lines are never
/// part of any export.
public protocol NetworkExportService: Sendable {
    func export(scope: NetworkExportScope, includeFullTargets: Bool) async -> Result<Data, NetworkStoreFailure>
}

public protocol NetworkRuleService: Sendable {
    /// Saves a configuration. The result's revision is the accepted one or
    /// the conflicting current one; saving never claims enforcement.
    func save(_ draft: NetworkRuleDraft, expectedRevision: UInt64?, operationID: UUID) async -> RuleApplyResult
    /// Current executor-side state, including `unknown` after IPC loss.
    func executionState(appKey: String) async -> RuleExecutionState
    /// Attempts to close existing connections independently of the new-
    /// connection rule; per-flow results are counted, never assumed.
    func disconnectExisting(appKey: String, operationID: UUID) async -> DisconnectExistingResult
    /// Removes the enforced rule and confirms read-back.
    func restoreConnectivity(appKey: String, operationID: UUID) async -> RuleApplyResult
}


/// Reports which network the system considers active, so the page can say
/// "current connected network" from evidence instead of picking an interface
/// by name or sort order.
public protocol NetworkPathProviding: Sendable {
    func currentPath() -> NetworkSystemPath
}

