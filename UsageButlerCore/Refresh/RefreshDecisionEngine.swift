import Foundation
import UsageButlerDomain

public struct RefreshDuration: Equatable, Comparable, Hashable, Sendable {
    public let nanoseconds: UInt64

    public init(nanoseconds: UInt64) {
        self.nanoseconds = nanoseconds
    }

    public static func seconds(_ value: UInt64) -> RefreshDuration {
        let (nanoseconds, overflow) = value.multipliedReportingOverflow(by: 1_000_000_000)
        return RefreshDuration(nanoseconds: overflow ? .max : nanoseconds)
    }

    public static func < (lhs: RefreshDuration, rhs: RefreshDuration) -> Bool {
        lhs.nanoseconds < rhs.nanoseconds
    }
}

public enum RefreshCadence: Equatable, Sendable {
    case automatic(interval: RefreshDuration)
    case manualOnly
}

public struct RefreshPolicy: Equatable, Sendable {
    public let cadence: RefreshCadence
    public let manualCooldown: RefreshDuration
    public let retryBackoff: [RefreshDuration]
    public let shutdownGrace: RefreshDuration

    public init(
        cadence: RefreshCadence,
        manualCooldown: RefreshDuration,
        retryBackoff: [RefreshDuration],
        shutdownGrace: RefreshDuration
    ) {
        precondition(!retryBackoff.isEmpty, "retryBackoff must contain at least one delay")
        self.cadence = cadence
        self.manualCooldown = manualCooldown
        self.retryBackoff = retryBackoff
        self.shutdownGrace = shutdownGrace
    }

    public func retryDelay(attempt: Int) -> RefreshDuration {
        let index = min(max(attempt - 1, 0), retryBackoff.count - 1)
        return retryBackoff[index]
    }

    public static let standard = RefreshPolicy(
        cadence: .automatic(interval: .seconds(300)),
        manualCooldown: .seconds(20),
        retryBackoff: [
            .seconds(60),
            .seconds(120),
            .seconds(300),
            .seconds(900)
        ],
        shutdownGrace: .seconds(2)
    )
}

public enum RefreshInitiator: Equatable, Sendable {
    case startup
    case manual
    case scheduled
    case toggleOn
    case recovery
}

public enum RefreshTrigger: Equatable, Sendable {
    case startup(scope: ProviderScope)
    case manual(scope: ProviderScope)
    case scheduled(scope: ProviderScope)
    case toggleOn(scope: ProviderScope)
    case recovery(scope: ProviderScope)
    case retry(scope: ProviderScope, attempt: Int, initiatedBy: RefreshInitiator)

    public var scope: ProviderScope {
        switch self {
        case let .startup(scope),
             let .manual(scope),
             let .scheduled(scope),
             let .toggleOn(scope),
             let .recovery(scope),
             let .retry(scope, _, _):
            scope
        }
    }

    public var initiator: RefreshInitiator {
        switch self {
        case .startup:
            .startup
        case .manual:
            .manual
        case .scheduled:
            .scheduled
        case .toggleOn:
            .toggleOn
        case .recovery:
            .recovery
        case let .retry(_, _, initiatedBy):
            initiatedBy
        }
    }

    public var retryAttempt: Int? {
        guard case let .retry(_, attempt, _) = self else { return nil }
        return attempt
    }
}

public struct RefreshDecisionState: Equatable, Sendable {
    public let activity: RefreshActivity
    public let gate: RefreshGateState
    public let isEnabled: Bool
    public let acceptsIntents: Bool

    public init(
        activity: RefreshActivity,
        gate: RefreshGateState,
        isEnabled: Bool,
        acceptsIntents: Bool
    ) {
        self.activity = activity
        self.gate = gate
        self.isEnabled = isEnabled
        self.acceptsIntents = acceptsIntents
    }
}

public enum RefreshSuspensionReason: Equatable, Sendable {
    case disabled
    case manualOnly
    case diagnostic(code: String)
    case operationInProgress
    case shuttingDown
}

public enum RefreshDecision: Equatable, Sendable {
    case run
    case join(generation: UInt64)
    case cooldown(until: MonotonicInstant)
    case backoff(until: MonotonicInstant, attempt: Int)
    case suspend(RefreshSuspensionReason)
}

public enum RefreshDecisionEngine {
    public static func decide(
        state: RefreshDecisionState,
        trigger: RefreshTrigger,
        now: MonotonicInstant,
        policy: RefreshPolicy
    ) -> RefreshDecision {
        guard state.acceptsIntents else {
            return .suspend(.shuttingDown)
        }
        guard state.isEnabled else {
            return .suspend(.disabled)
        }

        switch state.activity {
        case let .refreshing(activeScope, generation, _):
            guard activeScope != trigger.scope else {
                return .join(generation: generation)
            }
            return .suspend(.operationInProgress)
        case .detecting, .loggingIn:
            return .suspend(.operationInProgress)
        case .shuttingDown:
            return .suspend(.shuttingDown)
        case .idle:
            break
        }

        if case .manualOnly = policy.cadence,
           isAutomatic(trigger) {
            return .suspend(.manualOnly)
        }

        switch state.gate {
        case .open:
            return .run
        case let .cooldown(until):
            return now < until ? .cooldown(until: until) : .run
        case let .backoff(until, attempt):
            return now < until ? .backoff(until: until, attempt: attempt) : .run
        case let .suspended(diagnosticCode):
            return .suspend(.diagnostic(code: diagnosticCode))
        }
    }

    public static func adding(
        _ duration: RefreshDuration,
        to instant: MonotonicInstant
    ) -> MonotonicInstant {
        let (nanoseconds, overflow) = instant.nanoseconds.addingReportingOverflow(
            duration.nanoseconds
        )
        return MonotonicInstant(nanoseconds: overflow ? .max : nanoseconds)
    }

    private static func isAutomatic(_ trigger: RefreshTrigger) -> Bool {
        switch trigger {
        case .startup, .scheduled, .toggleOn:
            true
        case .manual, .recovery:
            false
        case let .retry(_, _, initiatedBy):
            switch initiatedBy {
            case .startup, .scheduled, .toggleOn:
                true
            case .manual, .recovery:
                false
            }
        }
    }
}
