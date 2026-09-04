import Foundation
import UsageButlerCore
import UsageButlerDomain

public enum ParsedArkQuotaDirection: Equatable, Sendable {
    case used
}

public enum ParsedArkWindowIdentity: Equatable, Sendable {
    case session
    case rollingHours(Int)
    case weekly
    case monthly
    case providerDefined(String)
}

public enum ParsedArkTimeEventKind: Equatable, Sendable {
    case reset
    case refresh
}

public struct ParsedArkTimeEvent: Equatable, Sendable {
    public let kind: ParsedArkTimeEventKind
    public let occursAt: Date
    public let rawResetAt: String
}

public struct ParsedArkUsedQuotaValue: Equatable, Sendable {
    public let percent: Decimal
    public let used: Decimal?
    public let total: Decimal?
    public let direction: ParsedArkQuotaDirection
}

public enum ParsedArkProjectedValue: Equatable, Sendable {
    case used(ParsedArkUsedQuotaValue)
    case unavailableInvalidPercent
    case unavailable(ParsedArkPeriodContractIssue)
}

public struct ParsedArkMetricProjection: Equatable, Sendable {
    public let sourceLabel: String
    public let window: ParsedArkWindowIdentity
    public let value: ParsedArkProjectedValue
    public let sourceResetAt: ParsedArkResetAt
    public let event: ParsedArkTimeEvent?
}

public struct ParsedArkProductProjection: Equatable, Sendable {
    public let productID: ParsedArkProductID
    public let presence: ParsedArkPresence
    public let edition: String?
    public let tier: String?
    public let metrics: [ParsedArkMetricProjection]
}

public enum ArkUsageProjector {
    public static func project(_ snapshot: ParsedArkUsageSnapshot) -> [ParsedArkProductProjection] {
        [project(snapshot.agentPlan), project(snapshot.codingPlan)]
    }

    public static func project(_ resolution: ParsedArkProductResolution) -> ParsedArkProductProjection {
        guard let item = resolution.uniqueItem else {
            return ParsedArkProductProjection(
                productID: resolution.productID,
                presence: resolution.presence,
                edition: nil,
                tier: nil,
                metrics: []
            )
        }

        let isSuccessfulEntitlement: Bool
        if case .entitled = resolution.presence {
            isSuccessfulEntitlement = true
        } else {
            isSuccessfulEntitlement = false
        }

        return ParsedArkProductProjection(
            productID: resolution.productID,
            presence: resolution.presence,
            edition: isSuccessfulEntitlement ? item.edition : nil,
            tier: isSuccessfulEntitlement ? item.tier : nil,
            metrics: isSuccessfulEntitlement ? item.periods.map { metric($0, productID: item.productID) } : []
        )
    }

    private static func metric(
        _ period: ParsedArkPeriod,
        productID: ParsedArkProductID
    ) -> ParsedArkMetricProjection {
        let absoluteEnrichment: (used: Decimal?, total: Decimal?)
        switch (period.used, period.total) {
        case let (.some(used), .some(total)):
            absoluteEnrichment = (used, total)
        case (.some(_), .none), (.none, .some(_)), (.none, .none):
            absoluteEnrichment = (nil, nil)
        }

        let value: ParsedArkProjectedValue
        if let issue = period.contractIssue {
            if issue == .invalidSourceValue("percent") {
                value = .unavailableInvalidPercent
            } else {
                value = .unavailable(issue)
            }
        } else if let percent = period.percent {
            value = .used(
                ParsedArkUsedQuotaValue(
                    percent: percent,
                    used: absoluteEnrichment.used,
                    total: absoluteEnrichment.total,
                    direction: .used
                )
            )
        } else {
            value = .unavailable(.missingRequiredField("percent"))
        }

        return ParsedArkMetricProjection(
            sourceLabel: period.label,
            window: windowIdentity(for: period.label),
            value: value,
            sourceResetAt: period.resetAt,
            event: event(for: period.resetAt, productID: productID)
        )
    }

    private static func windowIdentity(for sourceLabel: String) -> ParsedArkWindowIdentity {
        switch sourceLabel {
        case "session": .session
        case "5h": .rollingHours(5)
        case "weekly": .weekly
        case "monthly": .monthly
        default: .providerDefined(sourceLabel)
        }
    }

    private static func event(
        for resetAt: ParsedArkResetAt,
        productID: ParsedArkProductID
    ) -> ParsedArkTimeEvent? {
        guard case let .parsed(rawValue, date) = resetAt else { return nil }

        let kind: ParsedArkTimeEventKind
        switch productID {
        case .agentPlan:
            kind = .reset
        case .codingPlan:
            kind = .refresh
        case .other:
            return nil
        }

        return ParsedArkTimeEvent(kind: kind, occursAt: date, rawResetAt: rawValue)
    }
}

public enum ArkDomainContract {
    public static let adapterID = "ark.usage-plan.one-shot"
    public static let executableIdentity = "arkcli"
    public static let schemaVersion = "ark-usage-plan-json-v1"
    public static let quotaContractVersion = "ark-quota-v1"
    public static let operationID = "ark.usage.plan"
}

public enum ArkDomainMapper {
    public static func map(
        _ snapshot: ParsedArkUsageSnapshot,
        source: ProviderSourceIdentity,
        planMetadata: [ParsedArkProductID: ParsedArkPlanTierObservation] = [:]
    ) throws -> ProviderQuotaData {
        guard source.providerID == .ark else {
            throw identityFailure
        }
        let products = [ParsedArkProductID.agentPlan, .codingPlan]
            .map {
                product(
                    snapshot.resolution(for: $0),
                    snapshot: snapshot,
                    source: source,
                    planMetadata: planMetadata
                )
            }
        return ProviderQuotaData(
            providerID: .ark,
            source: source,
            fetchedAt: snapshot.context.fetchedAt,
            products: products,
            balances: [],
            resetEntitlements: []
        )
    }

    public static func presentationRule(for productID: ProductID) -> QuotaPresentationRule {
        QuotaPresentationRule(
            contractVersion: ArkDomainContract.quotaContractVersion,
            displayDirection: .used,
            timeEventKind: productID.sourceProductID == ParsedArkProductID.codingPlan.sourceValue
                ? .refresh
                : .reset,
            timeStyle: .relativeCountdown,
            percentDerivation: nil
        )
    }

    static func authoritativeProducts(from data: ProviderQuotaData) -> [QuotaProductData] {
        data.products.filter { product in
            guard product.state.failure == nil else { return false }
            switch product.state.presence {
            case .entitled, .notEntitled:
                return true
            case .unknown:
                return false
            }
        }
    }

    static func partialProductMutations(from data: ProviderQuotaData) -> [QuotaProductMutation] {
        let authoritativeIDs = Set(authoritativeProducts(from: data).map(\.id))
        return data.products.map { product in
            if authoritativeIDs.contains(product.id) {
                return .replace(product)
            }

            let currentFailure = product.state.failure
                ?? schemaFailure("unresolved_product")
            return .mutate(
                id: product.id,
                mutation: QuotaProductNodeMutation(
                    state: QuotaNodeMutation(failure: .replace(currentFailure))
                )
            )
        }
    }

    static func isCompleteKnownProductRead(
        _ snapshot: ParsedArkUsageSnapshot,
        data: ProviderQuotaData
    ) -> Bool {
        snapshot.effectiveCompleteness == .completeSuccess
            && snapshot.context.authoritativeDiscovery
            && authoritativeProducts(from: data).count == 2
    }

    private static func product(
        _ resolution: ParsedArkProductResolution,
        snapshot: ParsedArkUsageSnapshot,
        source: ProviderSourceIdentity,
        planMetadata: [ParsedArkProductID: ParsedArkPlanTierObservation]
    ) -> QuotaProductData {
        let sourceProductID = resolution.productID.sourceValue
        let item = resolution.uniqueItem
        let failure = productFailure(
            resolution: resolution,
            item: item,
            snapshot: snapshot
        )
        let metrics: [QuotaMetric]
        if case .entitled = resolution.presence, let item {
            metrics = Dictionary(grouping: item.periods, by: \.label)
                .values
                .compactMap { periods -> (period: ParsedArkPeriod, isDuplicate: Bool)? in
                    guard let period = periods.first else { return nil }
                    return (period, periods.count > 1)
                }
                .sorted { periodComesBefore($0.period, $1.period) }
                .map {
                    metric(
                        $0.period,
                        duplicate: $0.isDuplicate,
                        productID: resolution.productID,
                        source: source,
                        fetchedAt: snapshot.context.fetchedAt
                    )
                }
        } else {
            metrics = []
        }

        let planLevel = planLevel(
            resolution: resolution,
            item: item,
            failure: failure,
            snapshot: snapshot,
            source: source,
            planMetadata: planMetadata
        )

        let successful = failure == nil && {
            switch resolution.presence {
            case .entitled, .notEntitled: true
            case .unknown: false
            }
        }()
        return QuotaProductData(
            id: ProductID(providerID: .ark, sourceProductID: sourceProductID),
            sourceProductID: sourceProductID,
            titleKey: titleKey(for: resolution.productID),
            canonicalOrder: canonicalOrder(for: resolution.productID),
            planLevel: planLevel,
            state: nodeState(
                presence: domainPresence(
                    resolution.presence,
                    productID: resolution.productID,
                    source: source,
                    observedAt: snapshot.context.fetchedAt
                ),
                fetchedAt: snapshot.context.fetchedAt,
                successful: successful,
                failure: failure
            ),
            metrics: metrics
        )
    }

    private static func planLevel(
        resolution: ParsedArkProductResolution,
        item: ParsedArkUsageItem?,
        failure: ProviderFailure?,
        snapshot: ParsedArkUsageSnapshot,
        source: ProviderSourceIdentity,
        planMetadata: [ParsedArkProductID: ParsedArkPlanTierObservation]
    ) -> PlanLevelObservation? {
        guard case .entitled = resolution.presence, failure == nil else {
            return nil
        }
        if let tier = normalized(item?.tier) {
            return PlanLevelObservation(
                value: tier,
                origin: .reported(sourceField: "items[].tier"),
                contractVersion: source.contractVersion,
                fetchedAt: snapshot.context.fetchedAt
            )
        }
        guard let metadata = planMetadata[resolution.productID],
              let tier = normalized(metadata.tier) else {
            return nil
        }
        return PlanLevelObservation(
            value: tier,
            origin: .reported(sourceField: "plans.get.plans[].tier"),
            contractVersion: source.contractVersion,
            fetchedAt: metadata.fetchedAt
        )
    }

    private static func metric(
        _ period: ParsedArkPeriod,
        duplicate: Bool,
        productID: ParsedArkProductID,
        source: ProviderSourceIdentity,
        fetchedAt: Date
    ) -> QuotaMetric {
        let failure = metricFailure(for: period, duplicate: duplicate)
        let sourceIdentity = MetricSourceIdentity(
            providerID: .ark,
            sourceProductID: productID.sourceValue,
            sourceBucketID: period.label,
            sourceMetricID: "usage"
        )
        return QuotaMetric(
            id: MetricID(sourceIdentity: sourceIdentity),
            sourceMetricID: "usage",
            sourceLabel: period.label,
            window: window(period, productID: productID),
            value: duplicate
                ? .unavailable(reason: .partialFailure(diagnosticCode: "ark.mapper.duplicate_period"))
                : value(period),
            sourceStatus: nil,
            provenance: MetricProvenance(
                sourceIdentity: sourceIdentity,
                providerSource: source,
                fetchedAt: fetchedAt
            ),
            state: nodeState(
                presence: .unknown,
                fetchedAt: fetchedAt,
                successful: failure == nil,
                failure: failure
            )
        )
    }

    private static func value(_ period: ParsedArkPeriod) -> QuotaMetricValue {
        if let issue = period.contractIssue {
            switch issue {
            case let .missingRequiredField(field):
                return .unavailable(reason: .missingRequiredField("periods[].\(field)"))
            case let .invalidFieldType(field), let .invalidSourceValue(field):
                return .unavailable(reason: .invalidSourceValue(field: "periods[].\(field)"))
            }
        }
        guard let percent = period.percent else {
            return .unavailable(reason: .missingRequiredField("periods[].percent"))
        }
        let sourcePercent = DirectedPercent(
            sourceValue: percent,
            sourceDirection: .used
        )
        switch (period.used, period.total) {
        case let (.some(used), .some(total)):
            return .usedTotal(
                UsedTotalAmount(
                    used: used,
                    total: total,
                    unit: "AFP",
                    sourcePercent: sourcePercent
                )
            )
        case (.some(_), .none), (.none, .some(_)), (.none, .none):
            // Absolute amounts are optional enrichment. A lone source value is
            // preserved by the parsed DTO, but the Domain must not derive its
            // missing counterpart or manufacture a used/total pair.
            return .percent(sourcePercent)
        }
    }

    private static func window(
        _ period: ParsedArkPeriod,
        productID: ParsedArkProductID
    ) -> QuotaWindow {
        let event: QuotaTimeEvent?
        if case let .parsed(_, date) = period.resetAt {
            switch productID {
            case .agentPlan:
                event = QuotaTimeEvent(kind: .reset, occursAt: date)
            case .codingPlan:
                event = QuotaTimeEvent(kind: .refresh, occursAt: date)
            case .other:
                event = nil
            }
        } else {
            event = nil
        }
        let kind: QuotaWindowKind
        let duration: TimeInterval?
        switch period.label {
        case "session":
            kind = .session
            duration = nil
        case "5h":
            kind = .shortCycle
            duration = 5 * 60 * 60
        case "weekly":
            kind = .weekly
            duration = 7 * 24 * 60 * 60
        case "monthly":
            kind = .monthly
            duration = nil
        default:
            kind = .providerDefined(period.label)
            duration = nil
        }
        return QuotaWindow(
            kind: kind,
            duration: duration,
            startsAt: nil,
            endsAt: nil,
            timeEvent: event
        )
    }

    private static func productFailure(
        resolution: ParsedArkProductResolution,
        item: ParsedArkUsageItem?,
        snapshot: ParsedArkUsageSnapshot
    ) -> ProviderFailure? {
        guard let item else {
            return schemaFailure("missing_or_duplicate_product")
        }
        if item.sourceErrorPresent {
            // `usage plan` exposes an opaque per-item error presence, not a typed
            // authentication contract. In particular, `subscribed:false + error`
            // cannot distinguish an expired SSO session from access, service, network,
            // seat, or product failures. Only a separate typed auth readback may
            // construct requiresLogin/expired.
            return ProviderFailure(
                code: .serviceUnavailable,
                retryClass: .backoff,
                userMessageKey: "provider.failure.service",
                diagnosticCode: "ark.mapper.item_error",
                recovery: .retry
            )
        }
        guard item.subscribed != nil else {
            return schemaFailure("missing_subscription_flag")
        }
        guard item.periodsFieldState == .array else {
            let errorClass: String
            switch item.periodsFieldState {
            case .array: errorClass = "periods_array"
            case .missing: errorClass = "periods_missing"
            case .null: errorClass = "periods_null"
            case .invalidType: errorClass = "periods_invalid_type"
            }
            return schemaFailure(errorClass)
        }
        if item.droppedPeriodCount > 0 {
            return schemaFailure("dropped_period")
        }
        if case .notEntitled = resolution.presence,
           snapshot.context.completeness != .completeSuccess {
            return schemaFailure("non_authoritative_absence")
        }
        return nil
    }

    private static func metricFailure(
        for period: ParsedArkPeriod,
        duplicate: Bool
    ) -> ProviderFailure? {
        if duplicate {
            return schemaFailure("duplicate_period")
        }
        guard let issue = period.contractIssue else { return nil }
        let errorClass: String
        switch issue {
        case .missingRequiredField:
            errorClass = "period_missing_field"
        case .invalidFieldType:
            errorClass = "period_invalid_field_type"
        case .invalidSourceValue:
            errorClass = "period_invalid_source_value"
        }
        return schemaFailure(errorClass)
    }

    private static func domainPresence(
        _ parsed: ParsedArkPresence,
        productID: ParsedArkProductID,
        source: ProviderSourceIdentity,
        observedAt: Date
    ) -> PresenceState {
        let decision: DiscoveryPresenceDecision
        switch parsed {
        case .entitled:
            decision = .entitled
        case .notEntitled:
            decision = .notEntitled
        case .unknown:
            return .unknown
        }
        let evidence = AuthenticationEvidence(
            authority: .providerReport(
                sourceField: "items[].subscribed",
                contractVersion: source.contractVersion
            ),
            observedAt: observedAt
        )
        let discovery = SuccessfulProviderDiscovery(
            providerID: .ark,
            authority: DiscoveryAuthority(
                source: source,
                operationID: "\(ArkDomainContract.operationID).\(productID.sourceValue)"
            ),
            observedAt: observedAt,
            connection: .connected,
            authentication: .healthy(evidence),
            presence: decision
        )
        return discovery.resolvedPresence ?? .unknown
    }

    private static func nodeState(
        presence: PresenceState,
        fetchedAt: Date,
        successful: Bool,
        failure: ProviderFailure?
    ) -> QuotaNodeState {
        let refresh = RefreshState(
            activity: .idle,
            gate: .open,
            lastAttemptAt: fetchedAt,
            lastSuccessAt: successful ? fetchedAt : nil
        )
        return QuotaNodeState(
            presence: presence,
            freshness: successful ? .fresh(asOf: fetchedAt) : .unknown,
            refresh: refresh,
            lastAttemptAt: fetchedAt,
            lastSuccessAt: successful ? fetchedAt : nil,
            failure: failure
        )
    }

    private static func periodComesBefore(_ lhs: ParsedArkPeriod, _ rhs: ParsedArkPeriod) -> Bool {
        func order(_ label: String) -> Int {
            switch label {
            case "session", "5h": 0
            case "weekly": 1
            case "monthly": 2
            default: 3
            }
        }
        let lhsOrder = order(lhs.label)
        let rhsOrder = order(rhs.label)
        return lhsOrder == rhsOrder ? lhs.label < rhs.label : lhsOrder < rhsOrder
    }

    private static func canonicalOrder(for productID: ParsedArkProductID) -> Int {
        switch productID {
        case .agentPlan: 0
        case .codingPlan: 1
        case .other: 100
        }
    }

    private static func titleKey(for productID: ParsedArkProductID) -> String {
        switch productID {
        case .agentPlan: "provider.ark.product.agent-plan"
        case .codingPlan: "provider.ark.product.coding-plan"
        case .other: "provider.ark.product.other"
        }
    }

    private static func normalized(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else {
            return nil
        }
        return value
    }

    private static func schemaFailure(_ errorClass: String) -> ProviderFailure {
        ProviderFailure(
            code: .schemaMismatch,
            retryClass: .never,
            userMessageKey: "provider.failure.schema",
            diagnosticCode: "ark.mapper.\(errorClass)",
            recovery: nil
        )
    }

    private static let identityFailure = ProviderFailure(
        code: .identityMismatch,
        retryClass: .never,
        userMessageKey: "provider.failure.identity-mismatch",
        diagnosticCode: "ark.mapper.source_identity_mismatch",
        recovery: nil
    )
}

public protocol ArkPlanMetadataReading: Sendable {
    func readPlanMetadata() async -> Result<ParsedArkPlanMetadataSnapshot, ProviderFailure>
    func shutdown() async
}

public actor ArkPlanMetadataReader: ArkPlanMetadataReading {
    public static let defaultLimits = ChildProcessLimits(
        timeout: .seconds(15),
        standardOutputByteLimit: 1_048_576,
        standardErrorByteLimit: 65_536,
        lineLimit: 10_000
    )

    private let processClient: any ChildProcessClient
    private let executableURL: URL
    private let environment: [String: String]
    private let limits: ChildProcessLimits
    private let now: @Sendable () -> Date
    private var isShutdown = false

    public init(
        processClient: any ChildProcessClient,
        executableURL: URL,
        environment: [String: String] = [:],
        limits: ChildProcessLimits = ArkPlanMetadataReader.defaultLimits,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.processClient = processClient
        self.executableURL = executableURL
        self.environment = environment
        self.limits = limits
        self.now = now
    }

    public func readPlanMetadata() async -> Result<ParsedArkPlanMetadataSnapshot, ProviderFailure> {
        guard !isShutdown else { return .failure(Self.shutdownFailure) }
        guard executableURL.isFileURL, executableURL.path.hasPrefix("/") else {
            return .failure(Self.executableFailure)
        }

        let request = ChildProcessRequest(
            executableURL: executableURL,
            arguments: ["plans", "get", "--format", "json"],
            environment: environment,
            standardInput: nil,
            limits: limits
        )
        switch await processClient.run(request) {
        case let .failure(failure):
            return .failure(
                ProviderFailure(
                    code: failure.code,
                    retryClass: failure.retryClass,
                    userMessageKey: failure.userMessageKey,
                    diagnosticCode: "ark.plan_metadata.child.\(failure.code.rawValue)",
                    recovery: failure.recovery
                )
            )
        case let .success(output):
            guard case .exited(code: 0) = output.termination else {
                return .failure(Self.processFailure)
            }
            guard !output.standardOutput.isEmpty else {
                return .failure(Self.schemaFailure)
            }
            do {
                return .success(
                    try ArkPlanMetadataParser.parse(
                        output.standardOutput,
                        fetchedAt: now()
                    )
                )
            } catch {
                return .failure(Self.schemaFailure)
            }
        }
    }

    public func shutdown() async {
        guard !isShutdown else { return }
        isShutdown = true
        await processClient.shutdown()
    }

    private static let executableFailure = ProviderFailure(
        code: .missingExecutable,
        retryClass: .afterRecovery,
        userMessageKey: "provider.failure.missing-executable",
        diagnosticCode: "ark.plan_metadata.invalid_executable",
        recovery: .selectExecutable
    )

    private static let processFailure = ProviderFailure(
        code: .processFailed,
        retryClass: .backoff,
        userMessageKey: "provider.failure.process",
        diagnosticCode: "ark.plan_metadata.nonzero_exit",
        recovery: .retry
    )

    private static let schemaFailure = ProviderFailure(
        code: .schemaMismatch,
        retryClass: .never,
        userMessageKey: "provider.failure.schema",
        diagnosticCode: "ark.plan_metadata.schema_mismatch",
        recovery: nil
    )

    private static let shutdownFailure = ProviderFailure(
        code: .shutdown,
        retryClass: .never,
        userMessageKey: "provider.failure.shutdown",
        diagnosticCode: "ark.plan_metadata.shutdown",
        recovery: nil
    )
}

public actor ArkProviderAdapter: ProviderAdapter {
    public nonisolated let id: ProviderID = .ark
    public nonisolated let capabilities: ProviderCapabilities

    public static let defaultLimits = ChildProcessLimits(
        timeout: .seconds(30),
        standardOutputByteLimit: 1_048_576,
        standardErrorByteLimit: 65_536,
        lineLimit: 10_000
    )

    public static let loginLimits = ChildProcessLimits(
        // arkcli owns a five-minute OAuth callback timeout. Keep the parent
        // deadline later so the CLI can report its typed result first.
        timeout: .seconds(330),
        standardOutputByteLimit: 65_536,
        standardErrorByteLimit: 65_536,
        lineLimit: 1_000
    )

    private let processClient: any ChildProcessClient
    private let authenticationStatusReader: (any ArkAuthenticationStatusReading)?
    private let planMetadataReader: (any ArkPlanMetadataReading)?
    private let executableURL: URL
    private let environment: [String: String]
    private let limits: ChildProcessLimits
    private let cliVersionObservation: RuntimeContractFieldObservation
    private let now: @Sendable () -> Date
    private var isShutdown = false
    private var lastErrorClass = "none"
    private var schemaState = "not-observed"
    private var parserFailureCode = "none"
    private var parserFailurePath = "none"
    private var envelopeDiagnostics = ParsedArkEnvelopeDiagnostics.empty
    private var cachedPlanMetadata: [ParsedArkProductID: ParsedArkPlanTierObservation] = [:]
    private var completedReadAuthentication: AuthenticationState?

    public init(
        processClient: any ChildProcessClient,
        authenticationStatusReader: (any ArkAuthenticationStatusReading)? = nil,
        planMetadataReader: (any ArkPlanMetadataReading)? = nil,
        executableURL: URL,
        environment: [String: String] = [:],
        limits: ChildProcessLimits = ArkProviderAdapter.defaultLimits,
        cliVersion: RuntimeContractFieldObservation = .unverified,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.processClient = processClient
        self.authenticationStatusReader = authenticationStatusReader
        self.planMetadataReader = planMetadataReader
        self.executableURL = executableURL
        self.environment = environment
        self.limits = limits
        cliVersionObservation = cliVersion
        self.now = now
        capabilities = ProviderCapabilities(
            contractVersion: ArkDomainContract.quotaContractVersion,
            loginMethod: .sso,
            hasOfficialDocumentation: true,
            allowsExecutableSelection: true
        )
    }

    public func discover() async -> DiscoveryResult {
        let authenticationObservation: ArkAuthenticationObservation?
        if let authenticationStatusReader {
            switch await authenticationStatusReader.readAuthenticationStatus() {
            case let .success(observation):
                authenticationObservation = observation
                if let loginEvidence = observation.requiresLoginEvidence {
                    return .success(
                        SuccessfulProviderDiscovery(
                            providerID: .ark,
                            authority: DiscoveryAuthority(
                                source: sourceIdentity,
                                operationID: "ark.auth.status"
                            ),
                            observedAt: observation.observedAt,
                            connection: .requiresLogin(loginEvidence),
                            authentication: observation.authentication,
                            presence: nil
                        )
                    )
                }
            case .failure:
                // Auth status is an independent health signal. If it cannot be read,
                // the authoritative quota discovery below still gets a chance to prove
                // that the control-plane credential currently works. Never classify the
                // auth read failure itself as expired/requiresLogin.
                authenticationObservation = nil
            }
        } else {
            authenticationObservation = nil
        }

        switch await loadSnapshot() {
        case let .failure(failure):
            return .failure(failure)
        case let .success(snapshot):
            let resolutions = [snapshot.agentPlan, snapshot.codingPlan]
            let hasEntitled = resolutions.contains { resolution in
                if case .entitled = resolution.presence { return true }
                return false
            }
            let allKnownProductsNotEntitled = resolutions.allSatisfy { resolution in
                if case .notEntitled = resolution.presence { return true }
                return false
            }
            let hasOpaqueItemFailure = resolutions.contains { resolution in
                resolution.uniqueItem?.sourceErrorPresent == true
            }
            let observedAt = snapshot.context.fetchedAt
            let usageEvidence = AuthenticationEvidence(
                authority: .providerReport(
                    sourceField: "items[].subscribed",
                    contractVersion: capabilities.contractVersion
                ),
                observedAt: observedAt
            )
            if hasEntitled || allKnownProductsNotEntitled {
                return .success(
                    SuccessfulProviderDiscovery(
                        providerID: .ark,
                        authority: DiscoveryAuthority(
                            source: sourceIdentity,
                            operationID: ArkDomainContract.operationID
                        ),
                        observedAt: observedAt,
                        connection: .connected,
                        authentication: resolvedAuthentication(
                            observation: authenticationObservation,
                            usageEvidence: usageEvidence
                        ),
                        presence: nil
                    )
                )
            }
            if hasOpaqueItemFailure {
                return .failure(record(opaqueItemFailure, errorClass: "item_error"))
            }
            return .failure(record(emptyOrUnknownFailure, errorClass: "empty_or_unknown"))
        }
    }

    public func read(scope: ProviderScope) async -> ProviderReadResult {
        completedReadAuthentication = nil
        guard scopeBelongsToAdapter(scope) else {
            return .failure(record(scopeFailure, errorClass: "scope_mismatch"))
        }
        switch await loadSnapshot() {
        case let .failure(failure):
            return .failure(failure)
        case let .success(snapshot):
            if let authenticationStatusReader {
                switch await authenticationStatusReader.readAuthenticationStatus() {
                case let .success(observation):
                    completedReadAuthentication = observation.authentication
                    if let failure = loginFailure(for: observation) {
                        return .failure(record(failure, errorClass: "auth_status"))
                    }
                case .failure:
                    completedReadAuthentication = .unknown(AuthenticationEvidence(
                        authority: .providerReport(
                            sourceField: "auth_status.unavailable",
                            contractVersion: capabilities.contractVersion
                        ),
                        observedAt: now()
                    ))
                }
            }
            let data: ProviderQuotaData
            do {
                data = try ArkDomainMapper.map(
                    snapshot,
                    source: sourceIdentity,
                    planMetadata: await effectivePlanMetadata()
                )
            } catch let failure as ProviderFailure {
                return .failure(record(failure, errorClass: "mapping"))
            } catch {
                return .failure(record(mappingFailure, errorClass: "mapping"))
            }
            if ArkDomainMapper.isCompleteKnownProductRead(snapshot, data: data) {
                lastErrorClass = "none"
                return .success(data)
            }
            let successfulProducts = ArkDomainMapper.authoritativeProducts(from: data)
            guard !successfulProducts.isEmpty else {
                return .failure(record(partialFailure(for: data), errorClass: "no_product_success"))
            }
            let patch = ProviderQuotaPatch(
                providerID: .ark,
                source: sourceIdentity,
                fetchedAt: snapshot.context.fetchedAt,
                productMutations: ArkDomainMapper.partialProductMutations(from: data),
                balanceMutation: .retain,
                resetEntitlementMutation: .retain
            )
            return .partial(
                patch,
                record(partialFailure(for: data), errorClass: "partial_product")
            )
        }
    }

    public func authenticationAfterRead() -> AuthenticationState? {
        completedReadAuthentication
    }

    public func invalidateAuthenticationCache() async {
        await authenticationStatusReader?.invalidateCache()
    }

    public func login(method: LoginMethod) async -> LoginResult {
        guard !isShutdown else {
            return .failure(record(shutdownFailure, errorClass: "shutdown"))
        }
        guard !Task.isCancelled else {
            lastErrorClass = "cancelled"
            return .cancelled
        }
        guard method == capabilities.loginMethod else {
            return .failure(
                record(unsupportedLoginMethodFailure, errorClass: "login_method_mismatch")
            )
        }
        guard executableURL.isFileURL, executableURL.path.hasPrefix("/") else {
            return .failure(record(executableFailure, errorClass: "invalid_executable_url"))
        }

        let request = ChildProcessRequest(
            executableURL: executableURL,
            arguments: ["auth", "login", "volc-sso"],
            environment: environment,
            standardInput: nil,
            limits: Self.loginLimits,
            nonZeroExitPolicy: .returnBoundedOutput
        )
        let childResult = await processClient.run(request)

        guard !Task.isCancelled, !isShutdown else {
            lastErrorClass = "cancelled"
            return .cancelled
        }
        // Login can replace the identity store even when the CLI later exits
        // nonzero. Never verify it against a pre-login cached observation.
        await authenticationStatusReader?.invalidateCache()

        switch childResult {
        case let .failure(failure) where failure.code == .cancelled:
            lastErrorClass = "cancelled"
            return .cancelled
        case let .failure(failure):
            if await authenticationRecoveredAfterFailedLogin() {
                lastErrorClass = "none"
                return .success
            }
            let safeFailure = sanitizedLoginChildFailure(failure)
            return .failure(
                record(safeFailure, errorClass: "login_\(failure.code.rawValue)")
            )
        case let .success(output):
            guard case .exited(code: 0) = output.termination else {
                if await authenticationRecoveredAfterFailedLogin() {
                    lastErrorClass = "none"
                    return .success
                }
                let failure = loginFailure(from: output)
                return .failure(
                    record(failure, errorClass: "login_\(failure.code.rawValue)")
                )
            }
            lastErrorClass = "none"
            return .success
        }
    }

    public func diagnosticSnapshot() async -> SafeProviderDiagnostic {
        SafeProviderDiagnostic(
            providerID: .ark,
            capturedAt: now(),
            diagnosticCode: "ark.adapter.safe_snapshot",
            safeFields: [
                "adapter": ArkDomainContract.adapterID,
                "cliVersion": cliVersionObservation.provenanceValue,
                "errorClass": lastErrorClass,
                "schema": "\(ArkDomainContract.schemaVersion):\(schemaState)",
                "parserCode": parserFailureCode,
                "parserPath": parserFailurePath,
                "supportedItems": String(envelopeDiagnostics.supportedItemCount),
                "unsupportedItems": String(envelopeDiagnostics.unsupportedItemCount),
                "droppedSupportedItems": String(envelopeDiagnostics.droppedSupportedItemCount),
                "droppedUnsupportedItems": String(
                    envelopeDiagnostics.droppedUnsupportedItemCount
                ),
                "droppedUnclassifiedItems": String(
                    envelopeDiagnostics.droppedUnclassifiedItemCount
                )
            ]
        )
    }

    public func shutdown() async {
        guard !isShutdown else { return }
        isShutdown = true
        if let authenticationStatusReader {
            await authenticationStatusReader.shutdown()
        }
        if let planMetadataReader {
            await planMetadataReader.shutdown()
        }
        await processClient.shutdown()
    }

    private func effectivePlanMetadata() async -> [
        ParsedArkProductID: ParsedArkPlanTierObservation
    ] {
        guard let planMetadataReader else { return cachedPlanMetadata }
        guard case let .success(snapshot) = await planMetadataReader.readPlanMetadata() else {
            return cachedPlanMetadata
        }
        // A successful read is the complete supported tier snapshot, including
        // authoritative absence. Only a read failure retains the previous snapshot.
        cachedPlanMetadata = snapshot.tiers
        return cachedPlanMetadata
    }

    private func resolvedAuthentication(
        observation: ArkAuthenticationObservation?,
        usageEvidence: AuthenticationEvidence
    ) -> AuthenticationState {
        guard let observation else { return .healthy(usageEvidence) }
        switch observation.authentication {
        case .healthy, .warning:
            return observation.authentication
        case .unknown:
            // Quota success proves current access, not a known session deadline.
            return observation.authentication
        case .expired:
            // Expired observations always returned early through requiresLogin.
            // Keep this defensive branch source-faithful if a future reader violates it.
            return observation.authentication
        }
    }

    private var sourceIdentity: ProviderSourceIdentity {
        ProviderSourceIdentity(
            providerID: .ark,
            adapterID: ArkDomainContract.adapterID,
            executableIdentity: ArkDomainContract.executableIdentity,
            cliVersion: cliVersionObservation.provenanceValue,
            schemaVersion: ArkDomainContract.schemaVersion,
            contractVersion: ArkDomainContract.quotaContractVersion
        )
    }

    private func loadSnapshot() async -> Result<ParsedArkUsageSnapshot, ProviderFailure> {
        guard !isShutdown else {
            return .failure(record(shutdownFailure, errorClass: "shutdown"))
        }
        guard executableURL.isFileURL, executableURL.path.hasPrefix("/") else {
            return .failure(record(executableFailure, errorClass: "invalid_executable_url"))
        }
        let request = ChildProcessRequest(
            executableURL: executableURL,
            arguments: ["usage", "plan", "--format", "json"],
            environment: environment,
            standardInput: nil,
            limits: limits
        )
        switch await processClient.run(request) {
        case let .failure(failure):
            if Self.isNonzeroExitFailure(failure),
               let loginFailure = await processExitLoginFailure() {
                return .failure(
                    record(loginFailure, errorClass: "nonzero_exit_login_required")
                )
            }
            let safeFailure = ProviderFailure(
                code: failure.code,
                retryClass: failure.retryClass,
                userMessageKey: failure.userMessageKey,
                diagnosticCode: "ark.adapter.child.\(failure.code.rawValue)",
                recovery: failure.recovery
            )
            return .failure(record(safeFailure, errorClass: failure.code.rawValue))
        case let .success(output):
            guard case .exited(code: 0) = output.termination else {
                if let loginFailure = await processExitLoginFailure() {
                    return .failure(record(loginFailure, errorClass: "nonzero_exit_login_required"))
                }
                return .failure(record(processFailure, errorClass: "nonzero_exit"))
            }
            guard !output.standardOutput.isEmpty else {
                schemaState = "empty"
                parserFailureCode = ParsedArkParsingFailureCode.emptyInput.rawValue
                parserFailurePath = "$"
                envelopeDiagnostics = .empty
                return .failure(record(emptyOutputFailure, errorClass: "empty_output"))
            }
            do {
                let snapshot = try ArkUsagePlanParser.parse(
                    output.standardOutput,
                    context: ParsedArkParsingContext(
                        completeness: .completeSuccess,
                        authoritativeDiscovery: true,
                        sourceVersion: cliVersionObservation.provenanceValue,
                        fetchedAt: now()
                    )
                )
                parserFailureCode = "none"
                parserFailurePath = "none"
                envelopeDiagnostics = snapshot.envelopeDiagnostics
                schemaState = snapshot.effectiveCompleteness == .completeSuccess ? "valid" : "partial"
                return .success(snapshot)
            } catch let failure as ParsedArkParsingFailure {
                schemaState = "invalid"
                parserFailureCode = failure.code.rawValue
                parserFailurePath = failure.codingPath
                envelopeDiagnostics = .empty
                return .failure(record(schemaFailure, errorClass: "schema_mismatch"))
            } catch {
                schemaState = "invalid"
                parserFailureCode = "invalidJSON"
                parserFailurePath = "$"
                envelopeDiagnostics = .empty
                return .failure(record(schemaFailure, errorClass: "schema_mismatch"))
            }
        }
    }

    /// The production process client reports a nonzero child exit as a typed
    /// failure instead of a successful output with a nonzero termination.
    /// Recognize only that exact internal diagnostic contract; timeouts,
    /// launch failures, I/O failures, and output-limit failures keep their
    /// original classification and recovery behavior.
    private static func isNonzeroExitFailure(_ failure: ProviderFailure) -> Bool {
        let prefix = "process.exit."
        guard failure.code == .processFailed,
              failure.diagnosticCode.hasPrefix(prefix),
              let exitCode = Int32(String(failure.diagnosticCode.dropFirst(prefix.count)))
        else {
            return false
        }
        return exitCode != 0
    }

    private func scopeBelongsToAdapter(_ scope: ProviderScope) -> Bool {
        switch scope {
        case .provider:
            return true
        case let .product(productID):
            return productID.providerID == .ark
                && [
                    ParsedArkProductID.agentPlan.sourceValue,
                    ParsedArkProductID.codingPlan.sourceValue
                ].contains(productID.sourceProductID)
        case let .metric(metricID):
            return metricID.sourceIdentity.providerID == .ark
        }
    }

    /// A nonzero usage-plan exit exposes no typed authentication contract (its
    /// stderr is opaque), so before surfacing the generic process failure the
    /// read consults the typed auth readback once. Only that readback may
    /// reclassify the failure as login-required; a healthy or unreadable auth
    /// status keeps the generic process failure.
    private func processExitLoginFailure() async -> ProviderFailure? {
        guard let authenticationStatusReader else { return nil }
        let observation: ArkAuthenticationObservation
        switch await authenticationStatusReader.readAuthenticationStatus() {
        case let .success(observed):
            observation = observed
        case .failure:
            return nil
        }
        completedReadAuthentication = observation.authentication
        return loginFailure(for: observation)
    }

    private func loginFailure(for observation: ArkAuthenticationObservation) -> ProviderFailure? {
        guard observation.requiresLoginEvidence != nil else { return nil }
        if case .expired = observation.authentication {
            return ProviderFailure(
                code: .authenticationExpired,
                retryClass: .afterRecovery,
                userMessageKey: "provider.failure.authentication-expired",
                diagnosticCode: "ark.adapter.process.auth_expired",
                recovery: .login(.sso)
            )
        }
        return ProviderFailure(
            code: .authenticationRequired,
            retryClass: .afterRecovery,
            userMessageKey: "provider.failure.authentication-required",
            diagnosticCode: "ark.adapter.process.auth_required",
            recovery: .login(.sso)
        )
    }

    private func partialFailure(for data: ProviderQuotaData) -> ProviderFailure {
        if data.products.contains(where: { $0.state.failure?.code == .serviceUnavailable }) {
            return ProviderFailure(
                code: .serviceUnavailable,
                retryClass: .backoff,
                userMessageKey: "provider.failure.service",
                diagnosticCode: "ark.adapter.partial.service",
                recovery: .retry
            )
        }
        return schemaFailure
    }

    private func sanitizedLoginChildFailure(_ failure: ProviderFailure) -> ProviderFailure {
        ProviderFailure(
            code: failure.code,
            retryClass: failure.retryClass,
            userMessageKey: failure.userMessageKey,
            diagnosticCode: "ark.adapter.login.child.\(failure.code.rawValue)",
            recovery: failure.recovery
        )
    }

    /// The callback page can be rendered before the CLI finishes token
    /// exchange/profile activation. If the CLI then exits nonzero, only a
    /// typed auth-status readback may prove that credentials nevertheless
    /// became usable; browser copy and process output are not success proof.
    private func authenticationRecoveredAfterFailedLogin() async -> Bool {
        guard let authenticationStatusReader else { return false }
        guard case let .success(observation) =
            await authenticationStatusReader.readAuthenticationStatus(),
            observation.requiresLoginEvidence == nil else {
            return false
        }
        if case .healthy = observation.authentication { return true }
        return false
    }

    private func loginFailure(from output: ChildProcessOutput) -> ProviderFailure {
        let stdout = String(decoding: output.standardOutput, as: UTF8.self)
        let stderr = String(decoding: output.redactedStandardError, as: UTF8.self)
        let combined = stdout + "\n" + stderr
        if combined.range(
            of: "too many requests, rate limit exceeded",
            options: [.caseInsensitive, .diacriticInsensitive]
        ) != nil {
            return ProviderFailure(
                code: .rateLimited,
                retryClass: .backoff,
                userMessageKey: "provider.failure.login-rate-limited",
                diagnosticCode: "ark.adapter.login.rate_limited",
                recovery: .retry
            )
        }
        return loginProcessFailure
    }

    @discardableResult
    private func record(_ failure: ProviderFailure, errorClass: String) -> ProviderFailure {
        lastErrorClass = errorClass
        return failure
    }

    private var executableFailure: ProviderFailure {
        ProviderFailure(
            code: .missingExecutable,
            retryClass: .never,
            userMessageKey: "provider.failure.missing-executable",
            diagnosticCode: "ark.adapter.invalid_executable_url",
            recovery: .selectExecutable
        )
    }

    private var processFailure: ProviderFailure {
        ProviderFailure(
            code: .processFailed,
            retryClass: .backoff,
            userMessageKey: "provider.failure.process",
            diagnosticCode: "ark.adapter.process.nonzero_exit",
            recovery: .retry
        )
    }

    private var emptyOutputFailure: ProviderFailure {
        ProviderFailure(
            code: .sessionEOF,
            retryClass: .backoff,
            userMessageKey: "provider.failure.session-eof",
            diagnosticCode: "ark.adapter.response.empty",
            recovery: .retry
        )
    }

    private var emptyOrUnknownFailure: ProviderFailure {
        ProviderFailure(
            code: .schemaMismatch,
            retryClass: .never,
            userMessageKey: "provider.failure.schema",
            diagnosticCode: "ark.adapter.response.empty_or_unknown",
            recovery: nil
        )
    }

    private var opaqueItemFailure: ProviderFailure {
        ProviderFailure(
            code: .serviceUnavailable,
            retryClass: .backoff,
            userMessageKey: "provider.failure.service",
            diagnosticCode: "ark.adapter.response.item_error",
            recovery: .retry
        )
    }

    private var schemaFailure: ProviderFailure {
        ProviderFailure(
            code: .schemaMismatch,
            retryClass: .never,
            userMessageKey: "provider.failure.schema",
            diagnosticCode: "ark.adapter.response.schema_mismatch",
            recovery: nil
        )
    }

    private var scopeFailure: ProviderFailure {
        ProviderFailure(
            code: .identityMismatch,
            retryClass: .never,
            userMessageKey: "provider.failure.identity-mismatch",
            diagnosticCode: "ark.adapter.scope_mismatch",
            recovery: nil
        )
    }

    private var mappingFailure: ProviderFailure {
        ProviderFailure(
            code: .schemaMismatch,
            retryClass: .never,
            userMessageKey: "provider.failure.schema",
            diagnosticCode: "ark.adapter.mapping_failed",
            recovery: nil
        )
    }

    private var unsupportedLoginMethodFailure: ProviderFailure {
        ProviderFailure(
            code: .protocolViolation,
            retryClass: .never,
            userMessageKey: "provider.failure.unsupported-login-method",
            diagnosticCode: "ark.adapter.login.unsupported_method",
            recovery: nil
        )
    }

    private var loginProcessFailure: ProviderFailure {
        ProviderFailure(
            code: .processFailed,
            retryClass: .backoff,
            userMessageKey: "provider.failure.process",
            diagnosticCode: "ark.adapter.login.process.nonzero_exit",
            recovery: .retry
        )
    }

    private var shutdownFailure: ProviderFailure {
        ProviderFailure(
            code: .shutdown,
            retryClass: .never,
            userMessageKey: "provider.failure.shutdown",
            diagnosticCode: "ark.adapter.shutdown",
            recovery: nil
        )
    }
}
