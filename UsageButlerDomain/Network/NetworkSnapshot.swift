import Foundation

/// Capture lifecycle state. Collection enabled (a user preference), capture
/// active (a runtime fact) and coverage complete (an observation quality) are
/// independent dimensions and must not be conflated.
public enum NetworkCollectionState: Equatable, Sendable {
    case stopped
    case starting
    case waitingAuthorization
    case denied
    case active
    /// Capture is running but some dimension is missing; details live in
    /// `NetworkCoverage` and this reason.
    case partial(reason: String)
    /// Source disconnected; the last-good snapshot is retained with its
    /// timestamp and current rates become unknown.
    case disconnected(since: Date)
}

/// Coverage quality per dimension. `partial` carries a human-reviewable
/// reason, not a percentage the UI could over-trust.
public enum CoverageLevel: Equatable, Sendable {
    case full
    case partial(reason: String)
    case unavailable(reason: String)
}

/// Observation coverage and integrity. Lost events and truncation are always
/// explicit: a snapshot with lost events is not "complete but smaller".
public struct NetworkCoverage: Equatable, Sendable {
    public let identity: CoverageLevel
    public let bytes: CoverageLevel
    public let targets: CoverageLevel
    public let protocols: CoverageLevel
    /// Source events known to be lost (sequence gaps, queue overflow).
    public let lostEventCount: UInt64
    /// Same-epoch counter decreases observed; each invalidates one counter.
    public let counterResetCount: UInt64
    /// Truncation applied to bounded collections, by collection name.
    public let truncatedCollections: [String]
    /// True when the current session has captured at least one real sample.
    public let hasLiveSample: Bool

    public init(
        identity: CoverageLevel,
        bytes: CoverageLevel,
        targets: CoverageLevel,
        protocols: CoverageLevel,
        lostEventCount: UInt64,
        counterResetCount: UInt64,
        truncatedCollections: [String],
        hasLiveSample: Bool
    ) {
        self.identity = identity
        self.bytes = bytes
        self.targets = targets
        self.protocols = protocols
        self.lostEventCount = lostEventCount
        self.counterResetCount = counterResetCount
        self.truncatedCollections = truncatedCollections
        self.hasLiveSample = hasLiveSample
    }
}

/// Why a capability is unavailable, so the UI can show the real blocker
/// instead of a generic grey button.
public enum NetworkCapabilityBlocker: String, Equatable, Hashable, Sendable {
    case signingOrProfileMissing
    case systemPermissionDenied
    case systemPermissionNotRequested
    case unavailableOnThisOS
    case sourceUnsupported
    case notYetImplemented
}

/// What the current service can actually do, decided by service and system
/// receipts — never by UI toggles. `block == true` does not imply every
/// action is available; each action is gated separately.
public struct NetworkCapabilities: Equatable, Sendable {
    public let observe: Bool
    public let blockNewConnections: Bool
    public let terminateExistingConnections: Bool
    public let ask: Bool
    public let allowlist: Bool
    public let history: Bool
    public let export: Bool
    public let blockers: [NetworkCapabilityBlocker]

    public init(
        observe: Bool,
        blockNewConnections: Bool,
        terminateExistingConnections: Bool,
        ask: Bool,
        allowlist: Bool,
        history: Bool,
        export: Bool,
        blockers: [NetworkCapabilityBlocker]
    ) {
        self.observe = observe
        self.blockNewConnections = blockNewConnections
        self.terminateExistingConnections = terminateExistingConnections
        self.ask = ask
        self.allowlist = allowlist
        self.history = history
        self.export = export
        self.blockers = blockers
    }

    /// The honest default for the current build: nothing verified yet.
    public static let unavailable = NetworkCapabilities(
        observe: false,
        blockNewConnections: false,
        terminateExistingConnections: false,
        ask: false,
        allowlist: false,
        history: false,
        export: false,
        blockers: [.notYetImplemented]
    )
}

/// A complete, bounded projection of network observation at one point in
/// time. Consumers replace their previous snapshot wholesale; they never
/// accumulate across snapshots.
public struct NetworkSnapshot: Equatable, Sendable {
    /// Wire/schema contract version of this projection.
    public static let contractVersion = 2

    public let sessionID: CaptureSessionID
    /// Monotonic per-session sequence of the source event this projection
    /// reflects; equal to the highest applied sequence.
    public let appliedSequence: UInt64
    /// Wall-clock production time (display/export only, never rate math).
    public let asOf: Date
    /// Monotonic production time (rate math and staleness).
    public let monotonicAsOf: MonotonicInstant
    public let collectionState: NetworkCollectionState
    public let coverage: NetworkCoverage
    public let capabilities: NetworkCapabilities
    /// One entry per observed interface, keyed by interface name.
    public let interfaces: [String: InterfaceCounters]
    public let interfaceInventory: NetworkInterfaceInventory?
    /// One entry per stable app identity key (`AppIdentity.stableKey`).
    public let apps: [String: AppNetworkCounters]
    /// Current interface rates keyed by interface name; absent when the
    /// interface has fewer than two samples.
    /// nil for legacy projections without a source-owned history batch.
    public let rateHistory: [String: [NetworkRateSample]]?
    public let interfaceRates: [String: NetworkRate]

    public init(
        sessionID: CaptureSessionID,
        appliedSequence: UInt64,
        asOf: Date,
        monotonicAsOf: MonotonicInstant,
        collectionState: NetworkCollectionState,
        coverage: NetworkCoverage,
        capabilities: NetworkCapabilities,
        interfaces: [String: InterfaceCounters],
        apps: [String: AppNetworkCounters],
        interfaceRates: [String: NetworkRate],
        rateHistory: [String: [NetworkRateSample]]? = nil,
        interfaceInventory: NetworkInterfaceInventory? = nil
    ) {
        self.sessionID = sessionID
        self.appliedSequence = appliedSequence
        self.asOf = asOf
        self.monotonicAsOf = monotonicAsOf
        self.collectionState = collectionState
        self.coverage = coverage
        self.capabilities = capabilities
        self.interfaces = interfaces
        self.apps = apps
        self.interfaceRates = interfaceRates
        self.rateHistory = rateHistory
        self.interfaceInventory = interfaceInventory
    }
    public func presence(of name: String) -> NetworkInterfacePresence {
        if collectionState == .stopped { return .notObserved }
        if case .disconnected = collectionState { return .unknown }
        guard let inventory = interfaceInventory,
              inventory.envelope.sessionID == sessionID,
              inventory.envelope.sequence <= appliedSequence,
              inventory.succeeded else { return .unknown }
        return inventory.names.contains(name) ? .present : .missing
    }

}
