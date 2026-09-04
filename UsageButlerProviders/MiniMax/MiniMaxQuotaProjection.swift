import Foundation
import UsageButlerCore
import UsageButlerDomain

public enum ParsedMiniMaxQuotaDirection: Equatable, Sendable {
    case used
}

public enum ParsedMiniMaxPercentDerivation: Equatable, Sendable {
    case complementOfRemaining
}

public struct ParsedMiniMaxUsedPercent: Equatable, Sendable {
    public let value: Decimal
    public let direction: ParsedMiniMaxQuotaDirection
    public let rawRemainingPercent: Decimal
    public let derivation: ParsedMiniMaxPercentDerivation
}

public struct ParsedMiniMaxUsedCount: Equatable, Sendable {
    public let usageCount: Decimal
    public let totalCount: Decimal
    public let direction: ParsedMiniMaxQuotaDirection
}

public enum ParsedMiniMaxUnavailableReason: Equatable, Sendable {
    case unsupportedModelName(String)
    case unsupportedStatus(Int)
    case invalidRemainingPercent
}

public enum ParsedMiniMaxProjectedValue: Equatable, Sendable {
    case usedPercent(ParsedMiniMaxUsedPercent)
    case usedCount(ParsedMiniMaxUsedCount)
    case unlimited(sourceStatus: Int)
    case unavailable(ParsedMiniMaxUnavailableReason)
}

public enum ParsedMiniMaxWindowIdentity: Equatable, Sendable {
    /// The source does not name this interval. Consumers must not infer a `5h` label from timestamps.
    case providerDefinedCurrent
    case weekly
}

public enum ParsedMiniMaxMetricPlacement: Equatable, Sendable {
    case overview
    case detailOnly
}

public enum ParsedMiniMaxTimeEventKind: Equatable, Sendable {
    case reset
}

public struct ParsedMiniMaxTimeEvent: Equatable, Sendable {
    public let kind: ParsedMiniMaxTimeEventKind
    public let remainingMilliseconds: Int64
}

public struct ParsedMiniMaxMetricProjection: Equatable, Sendable {
    public let sourceModelName: String
    public let window: ParsedMiniMaxWindowIdentity
    public let value: ParsedMiniMaxProjectedValue
    public let event: ParsedMiniMaxTimeEvent?
    public let placement: ParsedMiniMaxMetricPlacement
}

public enum MiniMaxQuotaProjector {
    public static func project(_ snapshot: ParsedMiniMaxQuotaSnapshot) -> [ParsedMiniMaxMetricProjection] {
        let counts = Dictionary(grouping: snapshot.models, by: \.modelName).mapValues(\.count)
        return snapshot.models
            .filter { counts[$0.modelName] == 1 }
            .flatMap(project)
    }

    public static func project(_ model: ParsedMiniMaxModelQuota) -> [ParsedMiniMaxMetricProjection] {
        [
            metric(
                modelName: model.modelName,
                windowIdentity: .providerDefinedCurrent,
                raw: model.current,
                placement: .overview
            ),
            metric(
                modelName: model.modelName,
                windowIdentity: .weekly,
                raw: model.weekly,
                placement: model.modelName == "video" ? .detailOnly : .overview
            )
        ]
    }

    private static func metric(
        modelName: String,
        windowIdentity: ParsedMiniMaxWindowIdentity,
        raw: ParsedMiniMaxQuotaWindow,
        placement: ParsedMiniMaxMetricPlacement
    ) -> ParsedMiniMaxMetricProjection {
        ParsedMiniMaxMetricProjection(
            sourceModelName: modelName,
            window: windowIdentity,
            value: value(modelName: modelName, raw: raw),
            event: raw.remainsTimeMilliseconds >= 0
                ? ParsedMiniMaxTimeEvent(kind: .reset, remainingMilliseconds: raw.remainsTimeMilliseconds)
                : nil,
            placement: placement
        )
    }

    private static func value(
        modelName: String,
        raw: ParsedMiniMaxQuotaWindow
    ) -> ParsedMiniMaxProjectedValue {
        if raw.status == 3 {
            return .unlimited(sourceStatus: raw.status)
        }
        guard raw.status == 1 else {
            return .unavailable(.unsupportedStatus(raw.status))
        }

        switch modelName {
        case "video":
            return .usedCount(
                ParsedMiniMaxUsedCount(
                    usageCount: raw.usageCount,
                    totalCount: raw.totalCount,
                    direction: .used
                )
            )
        case "general":
            guard raw.remainingPercent >= 0, raw.remainingPercent <= 100 else {
                return .unavailable(.invalidRemainingPercent)
            }
            return .usedPercent(
                ParsedMiniMaxUsedPercent(
                    value: Decimal(100) - raw.remainingPercent,
                    direction: .used,
                    rawRemainingPercent: raw.remainingPercent,
                    derivation: .complementOfRemaining
                )
            )
        default:
            return .unavailable(.unsupportedModelName(modelName))
        }
    }
}

public enum MiniMaxDomainContract {
    public static let adapterID = "minimax.quota-show.one-shot"
    public static let executableIdentity = "mmx"
    public static let schemaVersion = "mmx-quota-show-json-v1"
    public static let quotaContractVersion = "minimax-quota-v1"
    public static let sourceProductID = "token-plan"
    public static let operationID = "mmx.quota.show"
}

/// Maps the lossless parser model into the production quota algebra. In particular,
/// `remaining_percent` stays raw/remaining here; the used complement remains an
/// explicit presentation derivation and is never written over the source value.
public enum MiniMaxDomainMapper {
    public static func map(
        _ snapshot: ParsedMiniMaxQuotaSnapshot,
        source: ProviderSourceIdentity,
        planInferencePolicy: MiniMaxPlanInferencePolicy = .verifiedApprovedV1
    ) throws -> ProviderQuotaData {
        guard source.providerID == .miniMax else {
            throw identityFailure
        }

        let complete = snapshot.effectiveCompleteness == .completeSuccess
            && snapshot.baseStatusCode == 0
        let productPresence: PresenceState = complete && !snapshot.models.isEmpty
            ? entitledPresence(source: source, observedAt: snapshot.context.fetchedAt)
            : .unknown
        let counts = Dictionary(grouping: snapshot.models, by: \.modelName).mapValues(\.count)
        let uniqueModels = snapshot.models
            .filter { counts[$0.modelName] == 1 }
            .sorted(by: modelComesBefore)
        let metrics = uniqueModels.flatMap { model in
            [
                metric(
                    model: model,
                    raw: model.current,
                    slot: .current,
                    source: source,
                    fetchedAt: snapshot.context.fetchedAt
                ),
                metric(
                    model: model,
                    raw: model.weekly,
                    slot: .weekly,
                    source: source,
                    fetchedAt: snapshot.context.fetchedAt
                )
            ]
        }

        let inferredPlan = complete
            ? MiniMaxPlanInference.resolve(snapshot, policy: planInferencePolicy).observation.map {
                PlanLevelObservation(
                    value: $0.level.rawValue,
                    origin: .inferred(
                        ruleID: $0.ruleID,
                        catalogID: $0.catalogID,
                        sourceVersion: $0.sourceVersion,
                        evidenceFields: $0.evidenceFields
                    ),
                    contractVersion: $0.contractVersion,
                    fetchedAt: $0.fetchedAt
                )
            }
            : nil

        let product = QuotaProductData(
            id: ProductID(providerID: .miniMax, sourceProductID: MiniMaxDomainContract.sourceProductID),
            sourceProductID: MiniMaxDomainContract.sourceProductID,
            titleKey: "provider.minimax.product.token-plan",
            canonicalOrder: 0,
            planLevel: inferredPlan,
            state: nodeState(
                presence: productPresence,
                fetchedAt: snapshot.context.fetchedAt,
                successful: complete,
                failure: metrics.compactMap(\.state.failure).first
            ),
            metrics: metrics
        )

        return ProviderQuotaData(
            providerID: .miniMax,
            source: source,
            fetchedAt: snapshot.context.fetchedAt,
            products: [product],
            balances: [],
            resetEntitlements: []
        )
    }

    /// The Domain metric retains the raw direction; this rule records the only
    /// approved used-complement presentation for a finite MiniMax percentage.
    public static func presentationRule(for metric: QuotaMetric) -> QuotaPresentationRule {
        let derivation: DerivationKind?
        let direction: QuotaDirection
        switch metric.value {
        case let .percent(percent) where percent.sourceDirection == .remaining:
            direction = .used
            derivation = .complementOfRemaining
        case let .count(count):
            direction = count.sourceDirection
            derivation = nil
        case .unlimited:
            direction = .neutral
            derivation = nil
        default:
            direction = .used
            derivation = nil
        }
        return QuotaPresentationRule(
            contractVersion: MiniMaxDomainContract.quotaContractVersion,
            displayDirection: direction,
            timeEventKind: .reset,
            timeStyle: .relativeCountdown,
            percentDerivation: derivation
        )
    }

    private enum WindowSlot: String {
        case current = "current_interval"
        case weekly
    }

    private static func metric(
        model: ParsedMiniMaxModelQuota,
        raw: ParsedMiniMaxQuotaWindow,
        slot: WindowSlot,
        source: ProviderSourceIdentity,
        fetchedAt: Date
    ) -> QuotaMetric {
        let bucketID = "\(model.modelName).\(slot.rawValue)"
        let sourceMetricID: String
        switch model.modelName {
        case "general": sourceMetricID = "remaining_percent"
        case "video": sourceMetricID = "usage_count"
        default: sourceMetricID = "quota"
        }
        let sourceIdentity = MetricSourceIdentity(
            providerID: .miniMax,
            sourceProductID: MiniMaxDomainContract.sourceProductID,
            sourceBucketID: bucketID,
            sourceMetricID: sourceMetricID
        )
        let issue = model.contractIssue(for: raw, isWeekly: slot == .weekly)
        let failure = issue.map { issue in
            let diagnostic: String
            switch issue {
            case let .invalidSourceValue(field): diagnostic = "invalid.\(field)"
            case let .unsupportedSemantics(kind): diagnostic = "unsupported.\(kind)"
            }
            return ProviderFailure(
                code: .schemaMismatch,
                retryClass: .backoff,
                userMessageKey: "provider.failure.partial-schema",
                diagnosticCode: "minimax.mapper.\(diagnostic)",
                recovery: .retry
            )
        }
        return QuotaMetric(
            id: MetricID(sourceIdentity: sourceIdentity),
            sourceMetricID: sourceMetricID,
            sourceLabel: model.modelName,
            window: window(raw, slot: slot, fetchedAt: fetchedAt),
            value: issue.map { issue in
                switch issue {
                case let .invalidSourceValue(field):
                    .unavailable(reason: .invalidSourceValue(field: field))
                case let .unsupportedSemantics(kind):
                    .unavailable(reason: .unsupportedSemantics(sourceKind: kind))
                }
            } ?? value(modelName: model.modelName, raw: raw),
            sourceStatus: SourceStatus(code: String(raw.status), message: nil),
            provenance: MetricProvenance(
                sourceIdentity: sourceIdentity,
                providerSource: source,
                fetchedAt: fetchedAt
            ),
            state: nodeState(
                presence: .unknown, fetchedAt: fetchedAt,
                successful: failure == nil, failure: failure
            )
        )
    }

    private static func value(
        modelName: String,
        raw: ParsedMiniMaxQuotaWindow
    ) -> QuotaMetricValue {
        if raw.status == 3 {
            return .unlimited
        }
        switch modelName {
        case "general":
            return .percent(
                DirectedPercent(
                    sourceValue: raw.remainingPercent,
                    sourceDirection: .remaining
                )
            )
        case "video":
            return .count(
                DirectedCount(
                    sourceValue: raw.usageCount,
                    total: raw.totalCount,
                    sourceDirection: .used,
                    unit: "count"
                )
            )
        default:
            return .unavailable(reason: .unsupportedSemantics(sourceKind: "minimax.model"))
        }
    }

    private static func window(
        _ raw: ParsedMiniMaxQuotaWindow,
        slot: WindowSlot,
        fetchedAt: Date
    ) -> QuotaWindow {
        let startsAt = date(millisecondsSince1970: raw.startTimeMilliseconds)
        let endsAt = date(millisecondsSince1970: raw.endTimeMilliseconds)
        let duration: TimeInterval?
        if raw.endTimeMilliseconds >= raw.startTimeMilliseconds,
           raw.startTimeMilliseconds > 0 {
            duration = TimeInterval(raw.endTimeMilliseconds - raw.startTimeMilliseconds) / 1_000
        } else {
            duration = nil
        }
        let event: QuotaTimeEvent?
        if raw.remainsTimeMilliseconds >= 0 {
            event = QuotaTimeEvent(
                kind: .reset,
                occursAt: fetchedAt.addingTimeInterval(
                    TimeInterval(raw.remainsTimeMilliseconds) / 1_000
                )
            )
        } else {
            event = nil
        }
        return QuotaWindow(
            kind: slot == .weekly ? .weekly : .providerDefined("current_interval"),
            duration: duration,
            startsAt: startsAt,
            endsAt: endsAt,
            timeEvent: event
        )
    }

    private static func date(millisecondsSince1970 value: Int64) -> Date? {
        guard value > 0 else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(value) / 1_000)
    }

    private static func modelComesBefore(
        _ lhs: ParsedMiniMaxModelQuota,
        _ rhs: ParsedMiniMaxModelQuota
    ) -> Bool {
        func order(_ name: String) -> Int {
            switch name {
            case "general": 0
            case "video": 1
            default: 2
            }
        }
        let lhsOrder = order(lhs.modelName)
        let rhsOrder = order(rhs.modelName)
        return lhsOrder == rhsOrder ? lhs.modelName < rhs.modelName : lhsOrder < rhsOrder
    }

    private static func entitledPresence(
        source: ProviderSourceIdentity,
        observedAt: Date
    ) -> PresenceState {
        let evidence = AuthenticationEvidence(
            authority: .providerReport(
                sourceField: "base_resp.status_code",
                contractVersion: source.contractVersion
            ),
            observedAt: observedAt
        )
        let discovery = SuccessfulProviderDiscovery(
            providerID: .miniMax,
            authority: DiscoveryAuthority(
                source: source,
                operationID: MiniMaxDomainContract.operationID
            ),
            observedAt: observedAt,
            connection: .connected,
            authentication: .healthy(evidence),
            presence: .entitled
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

    private static let identityFailure = ProviderFailure(
        code: .identityMismatch,
        retryClass: .never,
        userMessageKey: "provider.failure.identity-mismatch",
        diagnosticCode: "minimax.mapper.source_identity_mismatch",
        recovery: nil
    )
}

public actor MiniMaxProviderAdapter: ProviderAdapter {
    public nonisolated let id: ProviderID = .miniMax
    public nonisolated let capabilities: ProviderCapabilities

    public static let defaultLimits = ChildProcessLimits(
        timeout: .seconds(30),
        standardOutputByteLimit: 1_048_576,
        standardErrorByteLimit: 65_536,
        lineLimit: 10_000
    )

    public static let loginLimits = ChildProcessLimits(
        timeout: .seconds(300),
        standardOutputByteLimit: 65_536,
        standardErrorByteLimit: 65_536,
        lineLimit: 1_000
    )

    private let processClient: any ChildProcessClient
    private let executableURL: URL
    private let environment: [String: String]
    private let limits: ChildProcessLimits
    private let cliVersionObservation: RuntimeContractFieldObservation
    private let regionObservation: RuntimeContractFieldObservation
    private let catalogObservation: RuntimeContractFieldObservation
    private let now: @Sendable () -> Date
    private var isShutdown = false
    private var lastErrorClass = "none"
    private var schemaState = "not-observed"

    public init(
        processClient: any ChildProcessClient,
        executableURL: URL,
        environment: [String: String] = [:],
        limits: ChildProcessLimits = MiniMaxProviderAdapter.defaultLimits,
        cliVersion: RuntimeContractFieldObservation = .unverified,
        region: RuntimeContractFieldObservation = .unverified,
        catalogID: RuntimeContractFieldObservation = .unverified,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.processClient = processClient
        self.executableURL = executableURL
        self.environment = environment
        self.limits = limits
        cliVersionObservation = cliVersion
        regionObservation = region
        catalogObservation = catalogID
        self.now = now
        capabilities = ProviderCapabilities(
            contractVersion: MiniMaxDomainContract.quotaContractVersion,
            loginMethod: .oauth,
            hasOfficialDocumentation: true,
            allowsExecutableSelection: true
        )
    }

    public func discover() async -> DiscoveryResult {
        switch await loadSnapshot() {
        case let .failure(failure):
            return .failure(failure)
        case let .success(snapshot):
            guard snapshot.baseStatusCode == 0 else {
                return .failure(record(baseStatusFailure, errorClass: "base_status"))
            }
            guard snapshot.effectiveCompleteness == .completeSuccess else {
                return .failure(record(partialFailure, errorClass: "partial_schema"))
            }
            let observedAt = snapshot.context.fetchedAt
            let evidence = AuthenticationEvidence(
                authority: .providerReport(
                    sourceField: "base_resp.status_code",
                    contractVersion: capabilities.contractVersion
                ),
                observedAt: observedAt
            )
            return .success(
                SuccessfulProviderDiscovery(
                    providerID: .miniMax,
                    authority: DiscoveryAuthority(
                        source: sourceIdentity,
                        operationID: MiniMaxDomainContract.operationID
                    ),
                    observedAt: observedAt,
                    connection: .connected,
                    authentication: .healthy(evidence),
                    presence: snapshot.models.isEmpty ? nil : .entitled
                )
            )
        }
    }

    public func read(scope: ProviderScope) async -> ProviderReadResult {
        guard scopeBelongsToAdapter(scope) else {
            return .failure(record(scopeFailure, errorClass: "scope_mismatch"))
        }
        switch await loadSnapshot() {
        case let .failure(failure):
            return .failure(failure)
        case let .success(snapshot):
            guard snapshot.baseStatusCode == 0 else {
                return .failure(record(baseStatusFailure, errorClass: "base_status"))
            }
            let data: ProviderQuotaData
            do {
                data = try MiniMaxDomainMapper.map(
                    snapshot,
                    source: sourceIdentity,
                    planInferencePolicy: planInferencePolicy
                )
            } catch let failure as ProviderFailure {
                return .failure(record(failure, errorClass: "mapping"))
            } catch {
                return .failure(record(mappingFailure, errorClass: "mapping"))
            }
            guard snapshot.context.completeness == .completeSuccess,
                  snapshot.droppedRowCount == 0, snapshot.duplicateRowCount == 0 else {
                // A lossy row cannot replace the sole Token Plan payload. Retain its
                // last-good data, clear only a current inference, and expose the
                // current Product failure. With no retained Product, the mutation is
                // a deterministic no-op.
                let failure = record(partialFailure, errorClass: "partial_schema")
                let patch = ProviderQuotaPatch(
                    providerID: .miniMax,
                    source: sourceIdentity,
                    fetchedAt: snapshot.context.fetchedAt,
                    productMutations: [
                        .mutate(
                            id: ProductID(
                                providerID: .miniMax,
                                sourceProductID: MiniMaxDomainContract.sourceProductID
                            ),
                            mutation: QuotaProductNodeMutation(
                                planLevel: .clearCurrentInferred,
                                state: QuotaNodeMutation(failure: .replace(failure))
                            )
                        )
                    ],
                    balanceMutation: .retain,
                    resetEntitlementMutation: .retain
                )
                return .partial(patch, failure)
            }
            if snapshot.effectiveCompleteness != .completeSuccess {
                let failure = record(partialFailure, errorClass: "invalid_value")
                return .partial(
                    ProviderQuotaPatch(
                        providerID: .miniMax,
                        source: sourceIdentity,
                        fetchedAt: snapshot.context.fetchedAt,
                        productMutations: data.products.map(QuotaProductMutation.replaceRetainingFailedMetrics),
                        balanceMutation: .retain,
                        resetEntitlementMutation: .retain
                    ),
                    failure
                )
            }
            lastErrorClass = "none"
            return .success(data)
        }
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
            arguments: ["auth", "login", "--recommend"],
            environment: environment,
            standardInput: nil,
            limits: Self.loginLimits
        )
        let childResult = await processClient.run(request)

        guard !Task.isCancelled, !isShutdown else {
            lastErrorClass = "cancelled"
            return .cancelled
        }

        switch childResult {
        case let .failure(failure) where failure.code == .cancelled:
            lastErrorClass = "cancelled"
            return .cancelled
        case let .failure(failure):
            let safeFailure = sanitizedLoginChildFailure(failure)
            return .failure(
                record(safeFailure, errorClass: "login_\(failure.code.rawValue)")
            )
        case let .success(output):
            guard case .exited(code: 0) = output.termination else {
                return .failure(
                    record(loginProcessFailure, errorClass: "login_nonzero_exit")
                )
            }
            lastErrorClass = "none"
            return .success
        }
    }

    public func diagnosticSnapshot() async -> SafeProviderDiagnostic {
        SafeProviderDiagnostic(
            providerID: .miniMax,
            capturedAt: now(),
            diagnosticCode: "minimax.adapter.safe_snapshot",
            safeFields: [
                "adapter": MiniMaxDomainContract.adapterID,
                "cliVersion": cliVersionObservation.provenanceValue,
                "errorClass": lastErrorClass,
                "schema": "\(MiniMaxDomainContract.schemaVersion):\(schemaState)"
            ]
        )
    }

    public func shutdown() async {
        guard !isShutdown else { return }
        isShutdown = true
        await processClient.shutdown()
    }

    private var sourceIdentity: ProviderSourceIdentity {
        ProviderSourceIdentity(
            providerID: .miniMax,
            adapterID: MiniMaxDomainContract.adapterID,
            executableIdentity: MiniMaxDomainContract.executableIdentity,
            cliVersion: cliVersionObservation.provenanceValue,
            schemaVersion: MiniMaxDomainContract.schemaVersion,
            contractVersion: MiniMaxDomainContract.quotaContractVersion
        )
    }

    private func loadSnapshot() async -> Result<ParsedMiniMaxQuotaSnapshot, ProviderFailure> {
        guard !isShutdown else {
            return .failure(record(shutdownFailure, errorClass: "shutdown"))
        }
        guard executableURL.isFileURL, executableURL.path.hasPrefix("/") else {
            return .failure(record(executableFailure, errorClass: "invalid_executable_url"))
        }
        let request = ChildProcessRequest(
            executableURL: executableURL,
            arguments: ["quota", "show", "--output", "json"],
            environment: environment,
            standardInput: nil,
            limits: limits
        )
        switch await processClient.run(request) {
        case let .failure(failure):
            let safeFailure = ProviderFailure(
                code: failure.code,
                retryClass: failure.retryClass,
                userMessageKey: failure.userMessageKey,
                diagnosticCode: "minimax.adapter.child.\(failure.code.rawValue)",
                recovery: failure.recovery
            )
            return .failure(record(safeFailure, errorClass: failure.code.rawValue))
        case let .success(output):
            guard case .exited(code: 0) = output.termination else {
                return .failure(record(processFailure, errorClass: "nonzero_exit"))
            }
            guard !output.standardOutput.isEmpty else {
                schemaState = "empty"
                return .failure(record(emptyOutputFailure, errorClass: "empty_output"))
            }
            do {
                let snapshot = try MiniMaxQuotaParser.parse(
                    output.standardOutput,
                    context: ParsedMiniMaxParsingContext(
                        completeness: .completeSuccess,
                        sourceVersion: cliVersionObservation.provenanceValue,
                        region: regionObservation.provenanceValue,
                        catalogID: catalogObservation.provenanceValue,
                        contractVersion: hasVerifiedInferenceProvenance
                            ? ParsedMiniMaxPlanInferenceContract.approvedV1.contractVersion
                            : RuntimeContractFieldObservation.unverifiedValue,
                        fetchedAt: now()
                    )
                )
                schemaState = snapshot.effectiveCompleteness == .completeSuccess ? "valid" : "partial"
                return .success(snapshot)
            } catch {
                schemaState = "invalid"
                return .failure(record(schemaFailure, errorClass: "schema_mismatch"))
            }
        }
    }

    private func scopeBelongsToAdapter(_ scope: ProviderScope) -> Bool {
        switch scope {
        case .provider:
            return true
        case let .product(productID):
            return productID.providerID == .miniMax
                && productID.sourceProductID == MiniMaxDomainContract.sourceProductID
        case let .metric(metricID):
            return metricID.sourceIdentity.providerID == .miniMax
        }
    }

    private var hasVerifiedInferenceProvenance: Bool {
        cliVersionObservation.verifiedValue != nil
            && regionObservation.verifiedValue != nil
            && catalogObservation.verifiedValue != nil
    }

    private var hasOnlyUnverifiedInferenceProvenance: Bool {
        [
            cliVersionObservation.provenance,
            regionObservation.provenance,
            catalogObservation.provenance
        ].allSatisfy { provenance in
            if case .unverified = provenance { return true }
            return false
        }
    }

    private var planInferencePolicy: MiniMaxPlanInferencePolicy {
        if hasOnlyUnverifiedInferenceProvenance {
            return .approvedEntitlementRule(.approvedV1)
        }
        return hasVerifiedInferenceProvenance
            ? .requireVerifiedSource(.approvedV1)
            : .disabled
    }

    private func sanitizedLoginChildFailure(_ failure: ProviderFailure) -> ProviderFailure {
        ProviderFailure(
            code: failure.code,
            retryClass: failure.retryClass,
            userMessageKey: failure.userMessageKey,
            diagnosticCode: "minimax.adapter.login.child.\(failure.code.rawValue)",
            recovery: failure.recovery
        )
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
            diagnosticCode: "minimax.adapter.invalid_executable_url",
            recovery: .selectExecutable
        )
    }

    private var processFailure: ProviderFailure {
        ProviderFailure(
            code: .processFailed,
            retryClass: .backoff,
            userMessageKey: "provider.failure.process",
            diagnosticCode: "minimax.adapter.process.nonzero_exit",
            recovery: .retry
        )
    }

    private var emptyOutputFailure: ProviderFailure {
        ProviderFailure(
            code: .sessionEOF,
            retryClass: .backoff,
            userMessageKey: "provider.failure.session-eof",
            diagnosticCode: "minimax.adapter.response.empty",
            recovery: .retry
        )
    }

    private var schemaFailure: ProviderFailure {
        ProviderFailure(
            code: .schemaMismatch,
            retryClass: .never,
            userMessageKey: "provider.failure.schema",
            diagnosticCode: "minimax.adapter.response.schema_mismatch",
            recovery: nil
        )
    }

    private var partialFailure: ProviderFailure {
        ProviderFailure(
            code: .schemaMismatch,
            retryClass: .backoff,
            userMessageKey: "provider.failure.partial-schema",
            diagnosticCode: "minimax.adapter.response.partial_schema",
            recovery: nil
        )
    }

    private var baseStatusFailure: ProviderFailure {
        ProviderFailure(
            code: .serviceUnavailable,
            retryClass: .backoff,
            userMessageKey: "provider.failure.service",
            diagnosticCode: "minimax.adapter.response.base_status",
            recovery: .retry
        )
    }

    private var scopeFailure: ProviderFailure {
        ProviderFailure(
            code: .identityMismatch,
            retryClass: .never,
            userMessageKey: "provider.failure.identity-mismatch",
            diagnosticCode: "minimax.adapter.scope_mismatch",
            recovery: nil
        )
    }

    private var mappingFailure: ProviderFailure {
        ProviderFailure(
            code: .schemaMismatch,
            retryClass: .never,
            userMessageKey: "provider.failure.schema",
            diagnosticCode: "minimax.adapter.mapping_failed",
            recovery: nil
        )
    }

    private var unsupportedLoginMethodFailure: ProviderFailure {
        ProviderFailure(
            code: .protocolViolation,
            retryClass: .never,
            userMessageKey: "provider.failure.unsupported-login-method",
            diagnosticCode: "minimax.adapter.login.unsupported_method",
            recovery: nil
        )
    }

    private var loginProcessFailure: ProviderFailure {
        ProviderFailure(
            code: .processFailed,
            retryClass: .backoff,
            userMessageKey: "provider.failure.process",
            diagnosticCode: "minimax.adapter.login.process.nonzero_exit",
            recovery: .retry
        )
    }

    private var shutdownFailure: ProviderFailure {
        ProviderFailure(
            code: .shutdown,
            retryClass: .never,
            userMessageKey: "provider.failure.shutdown",
            diagnosticCode: "minimax.adapter.shutdown",
            recovery: nil
        )
    }
}
