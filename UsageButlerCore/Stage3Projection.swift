import Foundation
import UsageButlerDomain

/// Presentation-only data used by the Stage 3 debug vertical slice.
/// It is intentionally separate from the authoritative quota Domain contract.
#if USAGE_BUTLER_FIXTURES
public enum Stage3FixtureScenario: String, CaseIterable, Sendable {
    case acceptedVisualFresh = "stage3.quota.v4.fresh.v1"
    case firstRunDetecting = "stage3.firstRun.detecting.v1"
    case arkWarningFresh = "stage3.quota.v4.ark-warning-fresh.v1"
    case arkExpiredStale = "stage3.quota.v4.ark-expired-stale.v1"
}
#endif

public enum Stage3DataOrigin: Equatable, Sendable {
    #if USAGE_BUTLER_FIXTURES
    case fixture(scenarioID: String, fixedNow: Date)
    #endif
    case runtime

    #if USAGE_BUTLER_FIXTURES
    public var isFixture: Bool {
        if case .fixture = self { return true }
        return false
    }
    #endif
}

public enum Stage3ProviderRowState: Equatable, Sendable {
    case detecting
    case connected
    case authenticationWarning
    case requiresLogin
    case expired(lastSuccessAt: Date?)
    case unavailable
}

public enum Stage3ProviderDataState: Equatable, Sendable {
    case unknown
    case fresh(asOf: Date)
    case stale(asOf: Date)
}

public enum Stage3ProviderActivity: Equatable, Sendable {
    case idle
    case detecting
    case refreshing
    case loggingIn
    case shuttingDown

    public var isInFlight: Bool {
        self != .idle
    }
}

public struct Stage3PartialDataState: Equatable, Sendable {
    public let freshAsOf: Date
    public let retainedStaleAsOf: Date

    public init(freshAsOf: Date, retainedStaleAsOf: Date) {
        self.freshAsOf = freshAsOf
        self.retainedStaleAsOf = retainedStaleAsOf
    }
}

public enum Stage3QuotaMetricDataState: Equatable, Sendable {
    case fresh(asOf: Date)
    case stale(asOf: Date)

    public var asOf: Date {
        switch self {
        case let .fresh(asOf), let .stale(asOf):
            asOf
        }
    }
}

public enum Stage3PlanOrigin: Equatable, Sendable {
    case reported(sourceField: String)
    case inferred(ruleID: String)
}

public struct Stage3PlanBadge: Equatable, Sendable {
    public let value: String
    public let origin: Stage3PlanOrigin

    public init(value: String, origin: Stage3PlanOrigin) {
        self.value = value
        self.origin = origin
    }
}

public enum Stage3QuotaDirection: Equatable, Sendable {
    case used
    case remaining
}

public enum Stage3QuotaValue: Equatable, Sendable {
    case percent(value: Double, direction: Stage3QuotaDirection)
    case unlimited
    case usedCount(used: Int, total: Int, unit: String)
    case entitlement(availableCount: Int)

    public var progressFraction: Double? {
        guard case let .percent(value, _) = self, value.isFinite else { return nil }
        return min(max(value / 100, 0), 1)
    }
}

public enum Stage3TimeEventKind: Equatable, Sendable {
    case reset
    case refresh
    case entitlementExpiry
}

public enum Stage3TimeStyle: Equatable, Sendable {
    case absoluteDateTime
    case relativeCountdown
}

public struct Stage3TimeEvent: Equatable, Sendable {
    public let kind: Stage3TimeEventKind
    public let occursAt: Date
    public let style: Stage3TimeStyle

    public init(kind: Stage3TimeEventKind, occursAt: Date, style: Stage3TimeStyle) {
        self.kind = kind
        self.occursAt = occursAt
        self.style = style
    }
}

public struct Stage3QuotaMetricProjection: Equatable, Identifiable, Sendable {
    public let id: String
    public let title: String
    public let windowBadge: String?
    public let value: Stage3QuotaValue
    public let event: Stage3TimeEvent?
    public let dataState: Stage3QuotaMetricDataState?

    public init(
        id: String,
        title: String,
        windowBadge: String? = nil,
        value: Stage3QuotaValue,
        event: Stage3TimeEvent? = nil,
        dataState: Stage3QuotaMetricDataState? = nil
    ) {
        self.id = id
        self.title = title
        self.windowBadge = windowBadge
        self.value = value
        self.event = event
        self.dataState = dataState
    }
}

public struct Stage3QuotaProductProjection: Equatable, Identifiable, Sendable {
    public let id: String
    public let title: String?
    public let planLevel: Stage3PlanBadge?
    public let metrics: [Stage3QuotaMetricProjection]

    public init(
        id: String,
        title: String? = nil,
        planLevel: Stage3PlanBadge? = nil,
        metrics: [Stage3QuotaMetricProjection]
    ) {
        self.id = id
        self.title = title
        self.planLevel = planLevel
        self.metrics = metrics
    }
}

public struct Stage3ProviderProjection: Equatable, Identifiable, Sendable {
    public let id: ProviderID
    public let rowState: Stage3ProviderRowState
    public let dataState: Stage3ProviderDataState
    public let activity: Stage3ProviderActivity
    public let partialDataState: Stage3PartialDataState?
    public let failureCode: FailureCode?
    public let loginMethod: LoginMethod?
    public let authenticationExpiresAt: Date?
    public let hasOfficialDocumentation: Bool
    public let allowsExecutableSelection: Bool
    public let planLevel: Stage3PlanBadge?
    public let products: [Stage3QuotaProductProjection]
    public let capturedAt: Date
    public let origin: Stage3DataOrigin

    public init(
        id: ProviderID,
        rowState: Stage3ProviderRowState,
        dataState: Stage3ProviderDataState = .unknown,
        activity: Stage3ProviderActivity = .idle,
        partialDataState: Stage3PartialDataState? = nil,
        failureCode: FailureCode? = nil,
        loginMethod: LoginMethod? = nil,
        authenticationExpiresAt: Date? = nil,
        hasOfficialDocumentation: Bool = false,
        allowsExecutableSelection: Bool = false,
        planLevel: Stage3PlanBadge? = nil,
        products: [Stage3QuotaProductProjection],
        capturedAt: Date,
        origin: Stage3DataOrigin
    ) {
        self.id = id
        self.rowState = rowState
        self.dataState = dataState
        self.activity = activity
        self.partialDataState = partialDataState
        self.failureCode = failureCode
        self.loginMethod = loginMethod
        self.authenticationExpiresAt = authenticationExpiresAt
        self.hasOfficialDocumentation = hasOfficialDocumentation
        self.allowsExecutableSelection = allowsExecutableSelection
        self.planLevel = planLevel
        self.products = products
        self.capturedAt = capturedAt
        self.origin = origin
    }
}

public struct Stage3MemoryProjection: Equatable, Sendable {
    public let pressure: MemoryPressureState
    public let fields: [MemorySummaryField]
    public let history: [MemoryTrendPoint]
    public let historyWindowEnd: Date
    public let capturedAt: Date
    public let origin: Stage3DataOrigin

    public init(
        pressure: MemoryPressureState,
        fields: [MemorySummaryField],
        history: [MemoryTrendPoint],
        historyWindowEnd: Date? = nil,
        capturedAt: Date,
        origin: Stage3DataOrigin
    ) {
        self.pressure = pressure
        self.fields = fields
        self.history = history
        self.historyWindowEnd = historyWindowEnd ?? capturedAt
        self.capturedAt = capturedAt
        self.origin = origin
    }
}

public struct Stage3AppProjection: Equatable, Sendable {
    #if USAGE_BUTLER_FIXTURES
    public let scenario: Stage3FixtureScenario
    #endif
    public let providers: [Stage3ProviderProjection]
    public let memory: Stage3MemoryProjection

    public init(
        providers: [Stage3ProviderProjection],
        memory: Stage3MemoryProjection
    ) {
        #if USAGE_BUTLER_FIXTURES
        self.scenario = .firstRunDetecting
        #endif
        self.providers = providers
        self.memory = memory
    }

    #if USAGE_BUTLER_FIXTURES
    public init(
        scenario: Stage3FixtureScenario,
        providers: [Stage3ProviderProjection],
        memory: Stage3MemoryProjection
    ) {
        self.scenario = scenario
        self.providers = providers
        self.memory = memory
    }
    #endif
}
