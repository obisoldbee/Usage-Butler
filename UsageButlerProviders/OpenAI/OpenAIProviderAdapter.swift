import Foundation
import UsageButlerCore
import UsageButlerDomain

/// The production adapter depends only on this typed, injected boundary. The
/// production composition injects `OpenAIAppServerTransport`, which owns the
/// Codex app-server child process; the adapter itself never invokes login,
/// accesses credentials, or performs network I/O beyond this reader.
public protocol OpenAIAppServerReader: Actor {
    nonisolated var sourceIdentity: ProviderSourceIdentity { get }

    func readAccount() async -> Result<Data, ProviderFailure>
    func readRateLimits() async -> Result<Data, ProviderFailure>
    func shutdown() async
}

public actor OpenAIProviderAdapter: ProviderAdapter {
    public nonisolated let id: ProviderID = .openAI
    public nonisolated let capabilities: ProviderCapabilities

    private let reader: any OpenAIAppServerReader
    private nonisolated let sourceIdentity: ProviderSourceIdentity
    private let now: @Sendable () -> Date

    private var isShutdown = false
    private var diagnostic = DiagnosticState()

    public init(
        reader: any OpenAIAppServerReader,
        capabilities: ProviderCapabilities? = nil,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        let sourceIdentity = reader.sourceIdentity
        self.reader = reader
        self.sourceIdentity = sourceIdentity
        self.capabilities = capabilities ?? ProviderCapabilities(
            contractVersion: sourceIdentity.contractVersion,
            loginMethod: nil,
            hasOfficialDocumentation: true,
            allowsExecutableSelection: true
        )
        self.now = now
    }

    public func discover() async -> DiscoveryResult {
        guard !isShutdown else {
            let failure = Self.shutdownFailure(operation: "discover")
            recordFailure(operation: .discover, failure: failure)
            return .failure(failure)
        }
        guard sourceIdentity.providerID == .openAI else {
            let failure = Self.identityFailure(operation: "discover")
            recordFailure(operation: .discover, failure: failure)
            return .failure(failure)
        }

        let accountResult = await readAccount()
        switch accountResult {
        case let .failure(failure):
            recordFailure(operation: .discover, failure: failure)
            return .failure(failure)

        case let .success(account):
            let observedAt = now()
            let accountType = Self.nonEmpty(account.accountType)
            // `requiresOpenaiAuth` describes the active provider, not whether an
            // existing account is unauthenticated. Official app-server responses
            // report `true` for healthy ChatGPT and API-key accounts as well. Login
            // is required only when that provider needs OpenAI credentials and the
            // account payload itself is absent.
            let needsLogin = account.requiresOpenAIAuth && accountType == nil
            let evidence = AuthenticationEvidence(
                authority: .providerReport(
                    sourceField: "account/read.account+requiresOpenaiAuth",
                    contractVersion: sourceIdentity.contractVersion
                ),
                observedAt: observedAt
            )
            let connection: DiscoveredConnection = needsLogin
                ? .requiresLogin(evidence)
                : .connected
            let authentication: AuthenticationState = needsLogin
                ? .warning(evidence)
                : .healthy(evidence)

            // A successful authenticated account/read can prove provider presence.
            // Authentication-required and account-less responses deliberately make no
            // entitlement decision; no error path can construct notEntitled.
            let presence: DiscoveryPresenceDecision? = accountType == nil
                ? nil
                : .entitled
            let discovery = SuccessfulProviderDiscovery(
                providerID: .openAI,
                authority: DiscoveryAuthority(
                    source: sourceIdentity,
                    operationID: "account/read"
                ),
                observedAt: observedAt,
                connection: connection,
                authentication: authentication,
                presence: presence
            )
            diagnostic.record(
                operation: .discover,
                outcome: needsLogin ? .requiresLogin : .success,
                diagnosticCode: needsLogin
                    ? "openai.discover.requires_login"
                    : "openai.discover.success"
            )
            return .success(discovery)
        }
    }

    public func read(scope: ProviderScope) async -> ProviderReadResult {
        guard !isShutdown else {
            let failure = Self.shutdownFailure(operation: "read")
            recordFailure(operation: .read, failure: failure)
            return .failure(failure)
        }
        guard sourceIdentity.providerID == .openAI, Self.belongsToOpenAI(scope) else {
            let failure = Self.identityFailure(operation: "read")
            recordFailure(operation: .read, failure: failure)
            return .failure(failure)
        }

        // Keep the contract order deterministic, but do not let account metadata
        // failure prevent an independently successful quota read.
        let accountOutcome = await readAccount()
        let rateLimitPayload = await reader.readRateLimits()

        let rateLimitsDTO: OpenAIRateLimitsReadResponseDTO
        switch rateLimitPayload {
        case let .failure(failure):
            recordFailure(operation: .read, failure: failure)
            return .failure(failure)
        case let .success(data):
            do {
                rateLimitsDTO = try OpenAIAppServerDecoder.decodeRateLimitsRead(from: data)
            } catch {
                let failure = Self.schemaFailure(operation: "rate_limits_read")
                recordFailure(operation: .read, failure: failure)
                return .failure(failure)
            }
        }

        let parsedRateLimits: ParsedOpenAIRateLimits
        do {
            parsedRateLimits = try OpenAIQuotaProjector.projectRateLimits(rateLimitsDTO)
        } catch {
            let failure = Self.schemaFailure(operation: "rate_limits_surface")
            recordFailure(operation: .read, failure: failure)
            return .failure(failure)
        }

        let fetchedAt = now()
        let account: ParsedOpenAIAccount?
        let accountFailure: ProviderFailure?
        switch accountOutcome {
        case let .success(value):
            account = value
            accountFailure = nil
        case let .failure(failure):
            account = nil
            accountFailure = failure
        }

        let mapping: OpenAIQuotaDomainMapping
        do {
            mapping = try OpenAIQuotaDomainMapper.map(
                account: account,
                rateLimits: parsedRateLimits,
                source: sourceIdentity,
                fetchedAt: fetchedAt
            )
        } catch {
            let failure = Self.identityFailure(operation: "map")
            recordFailure(operation: .read, failure: failure)
            return .failure(failure)
        }

        diagnostic.record(mapping: mapping, source: parsedRateLimits.source)

        if accountFailure == nil,
           !mapping.diagnostics.hasPartialFailure,
           mapping.balancesAreAuthoritative {
            if !mapping.resetEntitlementsAreAuthoritative {
                let patch = ProviderQuotaPatch(
                    providerID: .openAI,
                    source: sourceIdentity,
                    fetchedAt: fetchedAt,
                    productCollectionMutation: .replaceAll(mapping.data.products),
                    balanceMutation: .replace(mapping.data.balances),
                    resetEntitlementMutation: .retain
                )
                diagnostic.record(
                    operation: .read,
                    outcome: .success,
                    diagnosticCode: "openai.read.success_reset_omitted"
                )
                return .successPatch(patch)
            }
            diagnostic.record(
                operation: .read,
                outcome: .success,
                diagnosticCode: "openai.read.success"
            )
            return .success(mapping.data)
        }

        let failure = accountFailure.map(Self.retryablePartialFailure)
            ?? Self.partialSchemaFailure()
        let productMutation: QuotaProductCollectionMutation
        if mapping.productsAreAuthoritative {
            productMutation = .replaceAll(mapping.data.products)
        } else {
            productMutation = .patch(
                mapping.data.products
                    .filter { mapping.authoritativeProductIDs.contains($0.id) }
                    .map(QuotaProductMutation.replace)
            )
        }
        let patch = ProviderQuotaPatch(
            providerID: .openAI,
            source: sourceIdentity,
            fetchedAt: fetchedAt,
            productCollectionMutation: productMutation,
            balanceMutation: mapping.balancesAreAuthoritative
                ? .replace(mapping.data.balances)
                : .retain,
            resetEntitlementMutation: mapping.resetEntitlementsAreAuthoritative
                ? .replace(mapping.data.resetEntitlements)
                : .retain
        )
        diagnostic.record(
            operation: .read,
            outcome: .partial,
            diagnosticCode: Self.safeDiagnosticCode(
                for: failure,
                fallback: "openai.read.partial"
            )
        )
        return .partial(patch, failure)
    }

    public func login(method: LoginMethod) async -> LoginResult {
        guard !isShutdown else {
            let failure = Self.shutdownFailure(operation: "login")
            recordFailure(operation: .login, failure: failure)
            return .failure(failure)
        }
        guard capabilities.loginMethod == method else {
            let failure = ProviderFailure(
                code: .protocolViolation,
                retryClass: .never,
                userMessageKey: "provider.failure.unsupported-login-method",
                diagnosticCode: "openai.login.unsupported_method",
                recovery: nil
            )
            recordFailure(operation: .login, failure: failure)
            return .failure(failure)
        }

        // Login intentionally has no transport hook in this stage. Even a declared
        // capability returns a clear failure until an independently reviewed official
        // invocation is wired.
        let failure = ProviderFailure(
            code: .unknown,
            retryClass: .never,
            userMessageKey: "provider.failure.login-not-wired",
            diagnosticCode: "openai.login.not_wired",
            recovery: capabilities.hasOfficialDocumentation
                ? .openOfficialDocumentation
                : nil
        )
        recordFailure(operation: .login, failure: failure)
        return .failure(failure)
    }

    public func diagnosticSnapshot() async -> SafeProviderDiagnostic {
        SafeProviderDiagnostic(
            providerID: .openAI,
            capturedAt: now(),
            diagnosticCode: diagnostic.diagnosticCode,
            safeFields: diagnostic.safeFields(
                sourceIdentityValid: sourceIdentity.providerID == .openAI,
                isShutdown: isShutdown
            )
        )
    }

    public func shutdown() async {
        guard !isShutdown else { return }
        isShutdown = true
        await reader.shutdown()
        diagnostic.record(
            operation: .shutdown,
            outcome: .success,
            diagnosticCode: "openai.shutdown.complete"
        )
    }

    private func readAccount() async -> Result<ParsedOpenAIAccount, ProviderFailure> {
        switch await reader.readAccount() {
        case let .failure(failure):
            return .failure(failure)
        case let .success(data):
            do {
                let response = try OpenAIAppServerDecoder.decodeAccountRead(from: data)
                return .success(OpenAIQuotaProjector.projectAccount(response))
            } catch {
                return .failure(Self.schemaFailure(operation: "account_read"))
            }
        }
    }

    private func recordFailure(operation: DiagnosticOperation, failure: ProviderFailure) {
        diagnostic.record(
            operation: operation,
            outcome: .failure(failure.code),
            diagnosticCode: Self.safeDiagnosticCode(
                for: failure,
                fallback: "openai.\(operation.rawValue).\(failure.code.rawValue)"
            )
        )
    }

    private static func safeDiagnosticCode(
        for failure: ProviderFailure,
        fallback: String
    ) -> String {
        let phaseTimeoutCodes: Set<String> = [
            "openai.transport.startup.timeout",
            "openai.transport.account.timeout",
            "openai.transport.rate_limits.timeout"
        ]
        guard failure.code == .timedOut,
              phaseTimeoutCodes.contains(failure.diagnosticCode) else {
            return fallback
        }
        return failure.diagnosticCode
    }

    private static func belongsToOpenAI(_ scope: ProviderScope) -> Bool {
        switch scope {
        case .provider:
            true
        case let .product(productID):
            productID.providerID == .openAI
        case let .metric(metricID):
            metricID.sourceIdentity.providerID == .openAI
        }
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value,
              !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return value
    }

    private static func schemaFailure(operation: String) -> ProviderFailure {
        ProviderFailure(
            code: .schemaMismatch,
            retryClass: .never,
            userMessageKey: "provider.failure.schema-mismatch",
            diagnosticCode: "openai.\(operation).schema_mismatch",
            recovery: nil
        )
    }

    private static func partialSchemaFailure() -> ProviderFailure {
        ProviderFailure(
            code: .schemaMismatch,
            retryClass: .backoff,
            userMessageKey: "provider.failure.partial-schema",
            diagnosticCode: "openai.rate_limits.partial_schema",
            recovery: .retry
        )
    }

    private static func retryablePartialFailure(
        _ failure: ProviderFailure
    ) -> ProviderFailure {
        guard failure.code == .schemaMismatch,
              failure.retryClass == .never else {
            return failure
        }
        return ProviderFailure(
            code: failure.code,
            retryClass: .backoff,
            userMessageKey: failure.userMessageKey,
            diagnosticCode: failure.diagnosticCode,
            recovery: .retry
        )
    }

    private static func identityFailure(operation: String) -> ProviderFailure {
        ProviderFailure(
            code: .identityMismatch,
            retryClass: .never,
            userMessageKey: "provider.failure.identity-mismatch",
            diagnosticCode: "openai.\(operation).identity_mismatch",
            recovery: nil
        )
    }

    private static func shutdownFailure(operation: String) -> ProviderFailure {
        ProviderFailure(
            code: .shutdown,
            retryClass: .never,
            userMessageKey: "provider.failure.shutdown",
            diagnosticCode: "openai.\(operation).shutdown",
            recovery: nil
        )
    }
}

private enum DiagnosticOperation: String, Sendable {
    case none
    case discover
    case read
    case login
    case shutdown
}

private enum DiagnosticOutcome: Sendable {
    case notStarted
    case success
    case partial
    case requiresLogin
    case failure(FailureCode)

    var safeValue: String {
        switch self {
        case .notStarted: "not_started"
        case .success: "success"
        case .partial: "partial"
        case .requiresLogin: "requires_login"
        case let .failure(code): "failure_\(code.rawValue)"
        }
    }
}

private struct DiagnosticState: Sendable {
    var operation: DiagnosticOperation = .none
    var outcome: DiagnosticOutcome = .notStarted
    var diagnosticCode = "openai.adapter.not_started"
    var rateLimitSource = "not_read"
    var validBucketCount = 0
    var invalidBucketCount = 0
    var invalidWindowCount = 0
    var invalidCreditCount = 0
    var invalidResetDetailCount = 0
    var invalidResetSummaryCount = 0
    var invalidProductIdentityCount = 0
    var invalidBalanceCount = 0

    mutating func record(
        operation: DiagnosticOperation,
        outcome: DiagnosticOutcome,
        diagnosticCode: String
    ) {
        self.operation = operation
        self.outcome = outcome
        self.diagnosticCode = diagnosticCode
    }

    mutating func record(
        mapping: OpenAIQuotaDomainMapping,
        source: ParsedOpenAIRateLimitSource
    ) {
        rateLimitSource = switch source {
        case .multiBucket: "multi_bucket"
        case .legacyFallback: "legacy_fallback"
        }
        validBucketCount = mapping.data.products.count
        invalidBucketCount = mapping.diagnostics.invalidBucketSourceIDs.count
        invalidWindowCount = mapping.diagnostics.invalidWindowSourceIDs.count
        invalidCreditCount = mapping.diagnostics.invalidCreditSourceIDs.count
        invalidResetDetailCount = mapping.diagnostics.invalidResetCreditDetailCount
        invalidResetSummaryCount = mapping.diagnostics.invalidResetSummaryCount
        invalidProductIdentityCount = mapping.diagnostics.invalidProductIdentityCount
        invalidBalanceCount = mapping.diagnostics.invalidBalanceCount
    }

    func safeFields(sourceIdentityValid: Bool, isShutdown: Bool) -> [String: String] {
        [
            "transport": "injected_reader",
            "last_operation": operation.rawValue,
            "last_outcome": outcome.safeValue,
            "rate_limit_source": rateLimitSource,
            "valid_bucket_count": String(validBucketCount),
            "invalid_bucket_count": String(invalidBucketCount),
            "invalid_window_count": String(invalidWindowCount),
            "invalid_credit_count": String(invalidCreditCount),
            "invalid_reset_detail_count": String(invalidResetDetailCount),
            "invalid_reset_summary_count": String(invalidResetSummaryCount),
            "invalid_product_identity_count": String(invalidProductIdentityCount),
            "invalid_balance_count": String(invalidBalanceCount),
            "source_identity_valid": String(sourceIdentityValid),
            "shutdown": String(isShutdown)
        ]
    }
}
