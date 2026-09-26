import Foundation

public enum LoginMethod: String, Equatable, Hashable, Sendable {
    case oauth
    case sso
}

public struct ProviderCapabilities: Equatable, Sendable {
    public let contractVersion: String
    public let loginMethod: LoginMethod?
    public let hasOfficialDocumentation: Bool
    public let allowsExecutableSelection: Bool

    public init(
        contractVersion: String,
        loginMethod: LoginMethod?,
        hasOfficialDocumentation: Bool,
        allowsExecutableSelection: Bool
    ) {
        self.contractVersion = contractVersion
        self.loginMethod = loginMethod
        self.hasOfficialDocumentation = hasOfficialDocumentation
        self.allowsExecutableSelection = allowsExecutableSelection
    }
}

public struct AuthenticationEvidence: Equatable, Sendable {
    public enum Authority: Equatable, Sendable {
        case initialDetection
        case providerReport(sourceField: String, contractVersion: String)
    }

    public let authority: Authority
    public let observedAt: Date
    public let expiresAt: Date?

    public init(authority: Authority, observedAt: Date, expiresAt: Date? = nil) {
        self.authority = authority
        self.observedAt = observedAt
        self.expiresAt = expiresAt
    }
}

public struct AuthenticationExpiryEvidence: Equatable, Sendable {
    public enum Authority: Equatable, Sendable {
        case explicitExpiration(sourceField: String, contractVersion: String)
        case healthyToInvalidTransition(previousHealthyAt: Date, diagnosticCode: String)
    }

    public let authority: Authority
    public let observedAt: Date

    public init(authority: Authority, observedAt: Date) {
        self.authority = authority
        self.observedAt = observedAt
    }
}

public enum AuthenticationState: Equatable, Sendable {
    case unknown(AuthenticationEvidence)
    case healthy(AuthenticationEvidence)
    case warning(AuthenticationEvidence)
    case expired(AuthenticationExpiryEvidence)

    public var observedAt: Date {
        switch self {
        case let .unknown(evidence),
             let .healthy(evidence),
             let .warning(evidence):
            evidence.observedAt
        case let .expired(evidence):
            evidence.observedAt
        }
    }
}

public enum ConnectionState: Equatable, Sendable {
    case disabled
    case detecting(startedAt: Date)
    case connected(observedAt: Date)
    case requiresLogin(AuthenticationEvidence)
    case unavailable(observedAt: Date?)
}

public struct DiscoveryAuthority: Equatable, Sendable {
    public let source: ProviderSourceIdentity
    public let operationID: String

    public init(source: ProviderSourceIdentity, operationID: String) {
        self.source = source
        self.operationID = operationID
    }
}

public struct PresenceEvidence: Equatable, Sendable {
    public let authority: DiscoveryAuthority
    public let observedAt: Date

    fileprivate init(authority: DiscoveryAuthority, observedAt: Date) {
        self.authority = authority
        self.observedAt = observedAt
    }

}

public enum PresenceState: Equatable, Sendable {
    case unknown
    case entitled(PresenceEvidence)
    case notEntitled(PresenceEvidence)
}

public enum DiscoveryPresenceDecision: Equatable, Sendable {
    case entitled
    case notEntitled
}

public enum DiscoveredConnection: Equatable, Sendable {
    case connected
    case requiresLogin(AuthenticationEvidence)
}

/// This type represents an error-free, authoritative discovery result.
public struct SuccessfulProviderDiscovery: Equatable, Sendable {
    public let providerID: ProviderID
    public let authority: DiscoveryAuthority
    public let observedAt: Date
    public let connection: DiscoveredConnection
    public let authentication: AuthenticationState
    public let presence: DiscoveryPresenceDecision?

    public init(
        providerID: ProviderID,
        authority: DiscoveryAuthority,
        observedAt: Date,
        connection: DiscoveredConnection,
        authentication: AuthenticationState,
        presence: DiscoveryPresenceDecision?
    ) {
        self.providerID = providerID
        self.authority = authority
        self.observedAt = observedAt
        self.connection = connection
        self.authentication = authentication
        self.presence = presence
    }

    /// Presence can only be materialized from this explicitly successful discovery result.
    public var resolvedPresence: PresenceState? {
        guard let presence else { return nil }
        let evidence = PresenceEvidence(authority: authority, observedAt: observedAt)
        switch presence {
        case .entitled:
            return .entitled(evidence)
        case .notEntitled:
            return .notEntitled(evidence)
        }
    }
}

public enum FreshnessState: Equatable, Sendable {
    case unknown
    case fresh(asOf: Date)
    case stale(asOf: Date, evaluatedAt: Date)
}

public struct MonotonicInstant: Codable, Equatable, Comparable, Hashable, Sendable {
    public let nanoseconds: UInt64

    public init(nanoseconds: UInt64) {
        self.nanoseconds = nanoseconds
    }

    public static func < (lhs: MonotonicInstant, rhs: MonotonicInstant) -> Bool {
        lhs.nanoseconds < rhs.nanoseconds
    }
}

public enum RefreshGateState: Equatable, Sendable {
    case open
    case cooldown(until: MonotonicInstant)
    case backoff(until: MonotonicInstant, attempt: Int)
    case suspended(diagnosticCode: String)
}

public enum ProviderScope: Equatable, Hashable, Sendable {
    case provider
    case product(ProductID)
    case metric(MetricID)
}

public enum RefreshActivity: Equatable, Sendable {
    case idle
    case detecting(generation: UInt64, startedAt: Date)
    case refreshing(scope: ProviderScope, generation: UInt64, startedAt: Date)
    case loggingIn(method: LoginMethod, generation: UInt64, startedAt: Date)
    case shuttingDown(startedAt: Date)
}

public struct RefreshState: Equatable, Sendable {
    public var activity: RefreshActivity
    public var gate: RefreshGateState
    public var lastAttemptAt: Date?
    public var lastSuccessAt: Date?

    public init(
        activity: RefreshActivity,
        gate: RefreshGateState,
        lastAttemptAt: Date?,
        lastSuccessAt: Date?
    ) {
        self.activity = activity
        self.gate = gate
        self.lastAttemptAt = lastAttemptAt
        self.lastSuccessAt = lastSuccessAt
    }
}

public enum DiscoveryState: Equatable, Sendable {
    case notStarted
    case detecting(startedAt: Date, generation: UInt64)
    case succeeded(authority: DiscoveryAuthority, observedAt: Date)
    case failed(at: Date, diagnosticCode: String)
}

public enum PersistenceHealth: Equatable, Sendable {
    case unknown
    case healthy(lastReadAt: Date?, lastWriteAt: Date?)
    case degraded(ProviderFailure)
}

public struct QuotaNodeState: Equatable, Sendable {
    public var presence: PresenceState
    public var freshness: FreshnessState
    public var refresh: RefreshState
    public var lastAttemptAt: Date?
    public var lastSuccessAt: Date?
    public var failure: ProviderFailure?

    public init(
        presence: PresenceState,
        freshness: FreshnessState,
        refresh: RefreshState,
        lastAttemptAt: Date?,
        lastSuccessAt: Date?,
        failure: ProviderFailure?
    ) {
        self.presence = presence
        self.freshness = freshness
        self.refresh = refresh
        self.lastAttemptAt = lastAttemptAt
        self.lastSuccessAt = lastSuccessAt
        self.failure = failure
    }

    public static func authoritativeData(asOf: Date) -> QuotaNodeState {
        QuotaNodeState(
            presence: .unknown,
            freshness: .fresh(asOf: asOf),
            refresh: RefreshState(
                activity: .idle,
                gate: .open,
                lastAttemptAt: asOf,
                lastSuccessAt: asOf
            ),
            lastAttemptAt: asOf,
            lastSuccessAt: asOf,
            failure: nil
        )
    }
}

public enum ProviderFailureScope: Equatable, Hashable, Sendable {
    /// Compatibility scope for callers that still assign `ProviderState.failure`.
    case provider
    case discovery
    case read(ProviderScope)
    case login
    case identityValidation
}

public struct ScopedProviderFailure: Equatable, Sendable {
    public let scope: ProviderFailureScope
    public let failure: ProviderFailure
    public let occurredAt: Date

    public init(
        scope: ProviderFailureScope,
        failure: ProviderFailure,
        occurredAt: Date
    ) {
        self.scope = scope
        self.failure = failure
        self.occurredAt = occurredAt
    }
}

/// Orthogonal operation failures retained by scope. The display failure is derived
/// from the newest entry; resolving one operation never erases sibling failures.
public struct ScopedProviderFailures: Equatable, Sendable {
    public private(set) var entries: [ScopedProviderFailure]

    public init() {
        entries = []
    }

    public var current: ScopedProviderFailure? {
        entries.enumerated().max { lhs, rhs in
            if lhs.element.occurredAt != rhs.element.occurredAt {
                return lhs.element.occurredAt < rhs.element.occurredAt
            }
            return lhs.offset < rhs.offset
        }?.element
    }

    public func failure(for scope: ProviderFailureScope) -> ProviderFailure? {
        entries.first { $0.scope == scope }?.failure
    }

    public mutating func record(
        _ failure: ProviderFailure,
        scope: ProviderFailureScope,
        at occurredAt: Date
    ) {
        entries.removeAll { $0.scope == scope }
        entries.append(
            ScopedProviderFailure(
                scope: scope,
                failure: failure,
                occurredAt: occurredAt
            )
        )
    }

    public mutating func clear(_ scope: ProviderFailureScope) {
        entries.removeAll { $0.scope == scope }
    }

    public mutating func clearReadFailures(resolvedBy resolvedScope: ProviderScope) {
        entries.removeAll { entry in
            guard case let .read(recordedScope) = entry.scope else { return false }
            return resolvedScope.covers(recordedScope)
        }
    }

    public mutating func removeAll() {
        entries.removeAll()
    }
}

private extension ProviderScope {
    func covers(_ other: ProviderScope) -> Bool {
        switch (self, other) {
        case (.provider, _):
            true
        case let (.product(expected), .product(actual)):
            expected == actual
        case let (.product(expected), .metric(actual)):
            expected.providerID == actual.sourceIdentity.providerID
                && expected.sourceProductID == actual.sourceIdentity.sourceProductID
        case let (.metric(expected), .metric(actual)):
            expected == actual
        default:
            false
        }
    }
}

public struct ProviderState: Equatable, Sendable {
    public let id: ProviderID
    public var capabilities: ProviderCapabilities
    public var connection: ConnectionState
    public var presence: PresenceState
    public var authentication: AuthenticationState
    public var refresh: RefreshState
    public var lastGood: ProviderQuotaData?
    public var freshness: FreshnessState
    public var discovery: DiscoveryState
    public var persistence: PersistenceHealth
    public var scopedFailures: ScopedProviderFailures

    /// Compatibility presentation API. Reducer logic records and clears failures by
    /// `ProviderFailureScope`; callers that only display one failure can keep reading this.
    public var failure: ProviderFailure? {
        get { scopedFailures.current?.failure }
        set {
            scopedFailures.removeAll()
            if let newValue {
                scopedFailures.record(
                    newValue,
                    scope: .provider,
                    at: .distantPast
                )
            }
        }
    }

    public init(
        id: ProviderID,
        capabilities: ProviderCapabilities,
        connection: ConnectionState,
        presence: PresenceState,
        authentication: AuthenticationState,
        refresh: RefreshState,
        lastGood: ProviderQuotaData?,
        freshness: FreshnessState,
        discovery: DiscoveryState,
        persistence: PersistenceHealth,
        failure: ProviderFailure?,
        scopedFailures: ScopedProviderFailures? = nil
    ) {
        self.id = id
        self.capabilities = capabilities
        self.connection = connection
        self.presence = presence
        self.authentication = authentication
        self.refresh = refresh
        self.lastGood = lastGood
        self.freshness = freshness
        self.discovery = discovery
        self.persistence = persistence
        if let scopedFailures {
            self.scopedFailures = scopedFailures
        } else {
            var initialFailures = ScopedProviderFailures()
            if let failure {
                initialFailures.record(
                    failure,
                    scope: .provider,
                    at: refresh.lastAttemptAt ?? authentication.observedAt
                )
            }
            self.scopedFailures = initialFailures
        }
    }
}
