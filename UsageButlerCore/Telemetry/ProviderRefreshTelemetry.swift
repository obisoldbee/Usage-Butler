import Foundation
import UsageButlerDomain

/// The enum-only runtime log state extracted from a `ProviderProjection`.
///
/// Every field is a fixed enum mapping. It must never carry raw responses,
/// payloads, tokens, account/email identity, proxy values, executable or user
/// paths, or free-form diagnostic text; those categories are banned by
/// `ProviderRefreshTelemetryContract.forbiddenValueTokens` and locked by tests.
public struct ProviderRuntimeTelemetryState: Equatable, Sendable {
    public let provider: String
    public let phase: String
    public let connection: String
    public let activity: String
    public let freshness: String
    public let gate: String
    public let failure: String
    public let retry: String

    public init(projection: ProviderProjection) {
        provider = projection.state.id.rawValue
        phase = projection.phase.telemetryValue
        connection = projection.state.connection.telemetryValue
        activity = projection.state.refresh.activity.telemetryValue
        freshness = projection.state.freshness.telemetryValue
        gate = projection.state.refresh.gate.telemetryValue
        failure = projection.state.scopedFailures.current?.failure.code.rawValue ?? "none"
        retry = projection.state.scopedFailures.current?.failure.retryClass
            .telemetryValue ?? "none"
    }

    /// Explicit-field initializer for the privacy gate test. Every argument
    /// must already be a fixed enum mapping; the gate test rejects anything
    /// outside the declared value domains.
    public init(
        provider: String,
        phase: String,
        connection: String,
        activity: String,
        freshness: String,
        gate: String,
        failure: String,
        retry: String
    ) {
        self.provider = provider
        self.phase = phase
        self.connection = connection
        self.activity = activity
        self.freshness = freshness
        self.gate = gate
        self.failure = failure
        self.retry = retry
    }
}

/// Builds the two OSLog event messages declared by the privacy contract.
/// The runtime logs these strings verbatim with `privacy: .public`; they are
/// safe to publish only because every segment comes from the fixed mappings
/// below.
public enum ProviderRefreshTelemetry {
    public static let subsystem = "io.github.obisoldbee.UsageButler"
    public static let category = "ProviderRefresh"

    public static func providerStateMessage(_ state: ProviderRuntimeTelemetryState) -> String {
        "provider_state"
            + " provider=\(state.provider)"
            + " phase=\(state.phase)"
            + " connection=\(state.connection)"
            + " activity=\(state.activity)"
            + " freshness=\(state.freshness)"
            + " gate=\(state.gate)"
            + " failure=\(state.failure)"
            + " retry=\(state.retry)"
    }

    public static func lifecycleRefreshMessage(
        provider: ProviderID,
        reason: ProviderLifecycleRefreshReason,
        outcome: ProviderIntentOutcome
    ) -> String {
        "lifecycle_refresh"
            + " provider=\(provider.rawValue)"
            + " reason=\(reason.telemetryValue)"
            + " outcome=\(outcome.telemetryValue)"
    }
}

/// Static lock of the OSLog privacy contract: event field names, per-field
/// value domains, and the sensitive-token forbidden set. Any change to the
/// emitted log shape must update this contract and its gate test together.
public enum ProviderRefreshTelemetryContract {
    public static let providerStateEventName = "provider_state"
    public static let lifecycleRefreshEventName = "lifecycle_refresh"

    public static let providerStateFields = [
        "provider", "phase", "connection", "activity",
        "freshness", "gate", "failure", "retry"
    ]
    public static let lifecycleRefreshFields = ["provider", "reason", "outcome"]

    public static let providerStateValueDomains: [String: Set<String>] = [
        "provider": Set(ProviderID.allCases.map(\.rawValue)),
        "phase": Set(ProviderControllerPhase.allCases.map(\.telemetryValue)),
        "connection": [
            "disabled", "detecting", "connected", "requires_login", "unavailable"
        ],
        "activity": [
            "idle", "detecting", "refreshing", "logging_in", "shutting_down"
        ],
        "freshness": ["unknown", "fresh", "stale"],
        "gate": ["open", "cooldown", "backoff", "suspended"],
        "failure": Set(["none"] + FailureCode.allCases.map(\.rawValue)),
        "retry": Set(["none"] + RetryClass.allCases.map(\.telemetryValue))
    ]

    public static let lifecycleRefreshValueDomains: [String: Set<String>] = [
        "provider": Set(ProviderID.allCases.map(\.rawValue)),
        "reason": Set(ProviderLifecycleRefreshReason.allCases.map(\.telemetryValue)),
        "outcome": Set(ProviderIntentOutcome.allCases.map(\.telemetryValue))
    ]

    /// Substrings that must never appear in a field name. They enumerate the
    /// banned content categories: raw provider output, payloads, credentials,
    /// account identity, proxy configuration, and filesystem paths.
    public static let forbiddenFieldTokens: Set<String> = [
        "raw", "payload", "token", "account", "email", "proxy",
        "path", "diagnostic", "secret", "key", "url", "user", "home"
    ]
}

extension RetryClass {
    public var telemetryValue: String {
        switch self {
        case .never: "never"
        case .immediate: "immediate"
        case .backoff: "backoff"
        case .afterRecovery: "after_recovery"
        }
    }
}

extension ProviderControllerPhase {
    public var telemetryValue: String {
        switch self {
        case .idle: "idle"
        case .starting: "starting"
        case .running: "running"
        case .shuttingDown: "shutting_down"
        case .stopped: "stopped"
        }
    }
}

extension ProviderLifecycleRefreshReason {
    public var telemetryValue: String {
        switch self {
        case .panelPresented: "panel_presented"
        case .systemWake: "system_wake"
        }
    }
}

extension ProviderIntentOutcome {
    public var telemetryValue: String {
        switch self {
        case .completed: "completed"
        case .joined: "joined"
        case .deferred: "deferred"
        case .rejected: "rejected"
        case .cancelled: "cancelled"
        case .shutdown: "shutdown"
        }
    }
}

extension ConnectionState {
    public var telemetryValue: String {
        switch self {
        case .disabled: "disabled"
        case .detecting: "detecting"
        case .connected: "connected"
        case .requiresLogin: "requires_login"
        case .unavailable: "unavailable"
        }
    }
}

extension RefreshActivity {
    public var telemetryValue: String {
        switch self {
        case .idle: "idle"
        case .detecting: "detecting"
        case .refreshing: "refreshing"
        case .loggingIn: "logging_in"
        case .shuttingDown: "shutting_down"
        }
    }
}

extension FreshnessState {
    public var telemetryValue: String {
        switch self {
        case .unknown: "unknown"
        case .fresh: "fresh"
        case .stale: "stale"
        }
    }
}

extension RefreshGateState {
    public var telemetryValue: String {
        switch self {
        case .open: "open"
        case .cooldown: "cooldown"
        case .backoff: "backoff"
        case .suspended: "suspended"
        }
    }
}
