import Foundation
import UsageButlerDomain

public enum ProviderControllerPhase: Equatable, Sendable, CaseIterable {
    case idle
    case starting
    case running
    case shuttingDown
    case stopped
}

public struct ProviderProjection: Equatable, Sendable {
    public let revision: UInt64
    public let isEnabled: Bool
    public let phase: ProviderControllerPhase
    public let state: ProviderState

    public init(
        revision: UInt64,
        isEnabled: Bool,
        phase: ProviderControllerPhase,
        state: ProviderState
    ) {
        self.revision = revision
        self.isEnabled = isEnabled
        self.phase = phase
        self.state = state
    }
}

public enum ProviderRefreshIntent: Equatable, Sendable {
    case manual(scope: ProviderScope)
    case scheduled(scope: ProviderScope)

    public var trigger: RefreshTrigger {
        switch self {
        case let .manual(scope):
            .manual(scope: scope)
        case let .scheduled(scope):
            .scheduled(scope: scope)
        }
    }
}

public enum ProviderRefreshFrequency: Int, CaseIterable, Equatable, Sendable {
    case manualOnly = 0
    case oneMinute = 60
    case fiveMinutes = 300
    case fifteenMinutes = 900
    case thirtyMinutes = 1_800

    public static let defaultFrequency = ProviderRefreshFrequency.fiveMinutes

    public static func validated(storedSeconds: Int) -> ProviderRefreshFrequency {
        ProviderRefreshFrequency(rawValue: storedSeconds) ?? .defaultFrequency
    }

    public var cadence: RefreshCadence {
        switch self {
        case .manualOnly:
            .manualOnly
        case .oneMinute, .fiveMinutes, .fifteenMinutes, .thirtyMinutes:
            .automatic(interval: .seconds(UInt64(rawValue)))
        }
    }
}

public enum ProviderRefreshOverride: Equatable, Sendable {
    case followGlobal
    case frequency(ProviderRefreshFrequency)

    public static func validated(storedSeconds: Int) -> ProviderRefreshOverride {
        guard storedSeconds != -1,
              let frequency = ProviderRefreshFrequency(rawValue: storedSeconds) else {
            return .followGlobal
        }
        return .frequency(frequency)
    }

    public var storedSeconds: Int {
        switch self {
        case .followGlobal:
            -1
        case let .frequency(frequency):
            frequency.rawValue
        }
    }

    public func resolving(
        globalFrequency: ProviderRefreshFrequency
    ) -> ProviderRefreshFrequency {
        switch self {
        case .followGlobal:
            globalFrequency
        case let .frequency(frequency):
            frequency
        }
    }
}

public enum ProviderRefreshPolicyResolver {
    public static func policy(
        providerID: ProviderID,
        globalFrequency: ProviderRefreshFrequency,
        override: ProviderRefreshOverride
    ) -> RefreshPolicy {
        RefreshPolicy(
            cadence: override.resolving(globalFrequency: globalFrequency).cadence,
            manualCooldown: providerID == .ark ? .seconds(30) : .seconds(20),
            retryBackoff: RefreshPolicy.standard.retryBackoff,
            shutdownGrace: .seconds(1)
        )
    }
}

public enum ProviderIntent: Equatable, Sendable {
    case start
    case refresh(ProviderRefreshIntent)
    case setRefreshPolicy(RefreshPolicy)
    case redetect
    case login
    case cancelLogin
    case setEnabled(Bool)
    case clearCache
    case ageTick(staleAfter: TimeInterval)
    case shutdown
}

public enum ProviderIntentRejection: Equatable, Sendable {
    case alreadyStarted
    case notStarted
    case disabled
    case unsupportedLogin
    case shuttingDown
    case stopped
}

public enum ProviderIntentOutcome: Equatable, Sendable, CaseIterable {
    /// Associated-value outcomes need one representative payload per case; the
    /// telemetry mapping is payload-independent, so the concrete values are
    /// irrelevant for contract iteration.
    public static var allCases: [ProviderIntentOutcome] {
        [
            .completed,
            .joined(generation: 0),
            .deferred(.suspend(.operationInProgress)),
            .cancelled,
            .rejected(.disabled),
            .shutdown(completedWithinGrace: false)
        ]
    }

    case completed
    case joined(generation: UInt64)
    case deferred(RefreshDecision)
    case cancelled
    case rejected(ProviderIntentRejection)
    case shutdown(completedWithinGrace: Bool)
}

public enum ProviderControllerInitializationError: Error, Equatable, Sendable {
    case adapterIdentityMismatch(expected: ProviderID, actual: ProviderID)
    case adapterCapabilitiesMismatch
}
