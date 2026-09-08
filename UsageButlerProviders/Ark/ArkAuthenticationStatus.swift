import Foundation
import UsageButlerCore
import UsageButlerDomain

public protocol ArkAuthenticationStatusReading: Actor {
    func readAuthenticationStatus() async -> Result<ArkAuthenticationObservation, ProviderFailure>
    func invalidateCache() async
    func shutdown() async
}

public extension ArkAuthenticationStatusReading {
    func invalidateCache() async {}
}

public struct ArkAuthenticationObservation: Equatable, Sendable {
    public let authentication: AuthenticationState
    public let requiresLoginEvidence: AuthenticationEvidence?
    public let observedAt: Date

    public init(
        authentication: AuthenticationState,
        requiresLoginEvidence: AuthenticationEvidence?,
        observedAt: Date
    ) {
        self.authentication = authentication
        self.requiresLoginEvidence = requiresLoginEvidence
        self.observedAt = observedAt
    }
}

struct ParsedArkAuthenticationStatus: Equatable, Sendable {
    struct ControlPlane: Equatable, Sendable {
        let status: String?
    }

    let controlPlane: ControlPlane?
    let accountID: String?
    let ownerTRN: String?
}

enum ArkAuthenticationStatusParser {
    private struct DTO: Decodable {
        struct ControlPlane: Decodable {
            let status: String?
        }

        struct ActiveProfile: Decodable {
            let owner_trn: String?
        }

        struct VolcSSO: Decodable {
            struct Identity: Decodable {
                let account_id: String?
                let trn: String?
            }
            let identity: Identity?
        }

        let controlPlane: ControlPlane?
        let activeProfile: ActiveProfile?
        let volcSSO: VolcSSO?

        enum CodingKeys: String, CodingKey {
            case controlPlane = "control_plane_auth"
            case activeProfile = "active_profile"
            case volcSSO = "volc_sso"
        }
    }

    static func parse(_ data: Data) throws -> ParsedArkAuthenticationStatus {
        let sanitized = ArkJSONSanitizer.extractJSONData(from: data)
        let dto = try JSONDecoder().decode(DTO.self, from: sanitized)
        return ParsedArkAuthenticationStatus(
            controlPlane: dto.controlPlane.map { .init(status: normalized($0.status)) },
            accountID: dto.volcSSO?.identity?.trn == dto.activeProfile?.owner_trn
                ? dto.volcSSO?.identity?.account_id : nil,
            ownerTRN: dto.activeProfile?.owner_trn
        )
    }

    private static func normalized(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else {
            return nil
        }
        return value.lowercased()
    }
}

enum ArkAuthenticationStatusClassifier {
    static let warningThreshold = AuthenticationExpiryPolicy.warningThreshold

    static func classify(
        _ status: ParsedArkAuthenticationStatus,
        now: Date,
        contractVersion: String,
        sessionExpiresAt: Date? = nil,
        sessionExpiryUnavailable: Bool = false
    ) -> ArkAuthenticationObservation {
        let controlPlaneStatus = status.controlPlane?.status
        // volc_sso describes the renewable short-lived ID token, not the
        // authorization session. Only the CLI knows whether it can renew it.
        // Do not infer session expiry or a warning from that token's deadline.
        let evidence = AuthenticationEvidence(
            authority: .providerReport(
                sourceField: sessionExpiresAt == nil
                    ? "control_plane_auth.status" : "identity_store.refresh_token.exp",
                contractVersion: contractVersion
            ),
            observedAt: now,
            expiresAt: sessionExpiresAt
        )

        if let sessionExpiresAt, sessionExpiresAt <= now {
            return ArkAuthenticationObservation(
                authentication: .expired(AuthenticationExpiryEvidence(
                    authority: .explicitExpiration(
                        sourceField: "identity_store.refresh_token.exp",
                        contractVersion: contractVersion
                    ),
                    observedAt: now
                )),
                requiresLoginEvidence: evidence,
                observedAt: now
            )
        }

        if controlPlaneStatus == "needs_login" {
            return ArkAuthenticationObservation(
                authentication: .unknown(evidence), requiresLoginEvidence: evidence, observedAt: now
            )
        }

        if let sessionExpiresAt,
           sessionExpiresAt.timeIntervalSince(now) <= warningThreshold {
            return ArkAuthenticationObservation(
                authentication: .warning(evidence), requiresLoginEvidence: nil, observedAt: now
            )
        }

        if controlPlaneStatus == "ok", !sessionExpiryUnavailable {
            return ArkAuthenticationObservation(
                authentication: .healthy(evidence),
                requiresLoginEvidence: nil,
                observedAt: now
            )
        }

        return ArkAuthenticationObservation(
            authentication: .unknown(evidence),
            requiresLoginEvidence: controlPlaneStatus == "needs_login" ? evidence : nil,
            observedAt: now
        )
    }
}

public actor ArkAuthenticationStatusReader: ArkAuthenticationStatusReading {
    private struct InFlightProbe {
        let id: UUID
        let generation: Int
        let task: Task<Result<ArkAuthenticationObservation, ProviderFailure>, Never>
    }

    public static let defaultMinimumProbeInterval: TimeInterval = 15 * 60

    public static let defaultLimits = ChildProcessLimits(
        timeout: .seconds(15),
        standardOutputByteLimit: 262_144,
        standardErrorByteLimit: 16_384,
        lineLimit: 2_000
    )

    private let processClient: any ChildProcessClient
    private let executableURL: URL
    private let environment: [String: String]
    private let limits: ChildProcessLimits
    private let contractVersion: String
    private let minimumProbeInterval: TimeInterval
    private let now: @Sendable () -> Date
    private let sessionExpiryReader: ArkSessionExpiryReader?
    private var cachedResult: (
        result: Result<ArkAuthenticationObservation, ProviderFailure>,
        probedAt: Date
    )?
    private var inFlightProbe: InFlightProbe?
    private var cacheGeneration = 0
    private var isShutdown = false

    public init(
        processClient: any ChildProcessClient,
        executableURL: URL,
        environment: [String: String] = [:],
        limits: ChildProcessLimits = ArkAuthenticationStatusReader.defaultLimits,
        contractVersion: String = ArkDomainContract.quotaContractVersion,
        sessionExpiryReader: ArkSessionExpiryReader? = nil,
        minimumProbeInterval: TimeInterval = ArkAuthenticationStatusReader.defaultMinimumProbeInterval,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.processClient = processClient
        self.executableURL = executableURL
        self.environment = environment
        self.limits = limits
        self.contractVersion = contractVersion
        self.sessionExpiryReader = sessionExpiryReader
        self.minimumProbeInterval = minimumProbeInterval
        self.now = now
    }

    public func readAuthenticationStatus() async -> Result<ArkAuthenticationObservation, ProviderFailure> {
        guard !isShutdown else { return .failure(shutdownFailure) }
        let requestedAt = now()
        if let cachedResult {
            let elapsed = requestedAt.timeIntervalSince(cachedResult.probedAt)
            if elapsed >= 0, elapsed < minimumProbeInterval {
                return Self.reevaluateCached(cachedResult.result, now: requestedAt)
            }
        }

        if let inFlightProbe {
            let result = await inFlightProbe.task.value
            guard !isShutdown else { return .failure(shutdownFailure) }
            if inFlightProbe.generation == cacheGeneration {
                return result
            }
            // The probe completed after an explicit invalidation. Its caller
            // may consume that result, but a later caller must obtain fresh evidence.
            if self.inFlightProbe?.id == inFlightProbe.id {
                self.inFlightProbe = nil
            }
            return await readAuthenticationStatus()
        }

        let generation = cacheGeneration
        let probeID = UUID()
        let task = Task { await self.probeAuthenticationStatus() }
        inFlightProbe = InFlightProbe(id: probeID, generation: generation, task: task)
        let result = await task.value
        if inFlightProbe?.id == probeID {
            inFlightProbe = nil
        }
        guard !isShutdown else { return .failure(shutdownFailure) }
        if !isShutdown, generation == cacheGeneration {
            cachedResult = (result, now())
        }
        return result
    }

    static func reevaluateCached(
        _ result: Result<ArkAuthenticationObservation, ProviderFailure>,
        now: Date
    ) -> Result<ArkAuthenticationObservation, ProviderFailure> {
        guard case let .success(observation) = result else { return result }
        let authentication = AuthenticationExpiryPolicy.evaluate(
            observation.authentication,
            now: now
        )
        let requiresLoginEvidence: AuthenticationEvidence?
        if case .expired = authentication {
            requiresLoginEvidence = observation.requiresLoginEvidence
                ?? authenticationEvidence(from: observation.authentication)
        } else {
            requiresLoginEvidence = observation.requiresLoginEvidence
        }
        return .success(
            ArkAuthenticationObservation(
                authentication: authentication,
                requiresLoginEvidence: requiresLoginEvidence,
                observedAt: observation.observedAt
            )
        )
    }

    private static func authenticationEvidence(
        from authentication: AuthenticationState
    ) -> AuthenticationEvidence? {
        switch authentication {
        case let .unknown(evidence), let .healthy(evidence), let .warning(evidence):
            evidence
        case .expired:
            nil
        }
    }

    public func invalidateCache() async {
        clearCache()
    }

    public func shutdown() async {
        clearCache()
        guard !isShutdown else { return }
        isShutdown = true
        await processClient.shutdown()
    }

    private func probeAuthenticationStatus() async
        -> Result<ArkAuthenticationObservation, ProviderFailure> {
        guard executableURL.isFileURL, executableURL.path.hasPrefix("/") else {
            return .failure(executableFailure)
        }

        let request = ChildProcessRequest(
            executableURL: executableURL,
            arguments: ["auth", "status", "--format", "json"],
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
                    diagnosticCode: "ark.auth-status.child.\(failure.code.rawValue)",
                    recovery: failure.recovery
                )
            )
        case let .success(output):
            guard case .exited(code: 0) = output.termination else {
                return .failure(processFailure)
            }
            guard !output.standardOutput.isEmpty else {
                return .failure(emptyOutputFailure)
            }
            do {
                let parsed = try ArkAuthenticationStatusParser.parse(output.standardOutput)
                let sessionExpiresAt: Date?
                if let sessionExpiryReader, let accountID = parsed.accountID,
                   let ownerTRN = parsed.ownerTRN {
                    // Boundary failures leave expiry unknown; never expose file,
                    // JSON, identity or token contents in diagnostics.
                    sessionExpiresAt = try? sessionExpiryReader.read(accountID: accountID, ownerTRN: ownerTRN)
                } else {
                    sessionExpiresAt = nil
                }
                return .success(
                    ArkAuthenticationStatusClassifier.classify(
                        parsed,
                        now: now(),
                        contractVersion: contractVersion,
                        sessionExpiresAt: sessionExpiresAt,
                        sessionExpiryUnavailable: sessionExpiryReader != nil && sessionExpiresAt == nil
                    )
                )
            } catch {
                return .failure(schemaFailure)
            }
        }
    }

    private func clearCache() {
        cachedResult = nil
        cacheGeneration += 1
    }

    private var executableFailure: ProviderFailure {
        ProviderFailure(
            code: .missingExecutable,
            retryClass: .never,
            userMessageKey: "provider.failure.missing-executable",
            diagnosticCode: "ark.auth-status.invalid_executable_url",
            recovery: .selectExecutable
        )
    }

    private var processFailure: ProviderFailure {
        ProviderFailure(
            code: .processFailed,
            retryClass: .backoff,
            userMessageKey: "provider.failure.process",
            diagnosticCode: "ark.auth-status.process.nonzero_exit",
            recovery: .retry
        )
    }

    private var emptyOutputFailure: ProviderFailure {
        ProviderFailure(
            code: .sessionEOF,
            retryClass: .backoff,
            userMessageKey: "provider.failure.session-eof",
            diagnosticCode: "ark.auth-status.response.empty",
            recovery: .retry
        )
    }

    private var schemaFailure: ProviderFailure {
        ProviderFailure(
            code: .schemaMismatch,
            retryClass: .never,
            userMessageKey: "provider.failure.schema",
            diagnosticCode: "ark.auth-status.response.schema_mismatch",
            recovery: nil
        )
    }

    private var shutdownFailure: ProviderFailure {
        ProviderFailure(
            code: .shutdown,
            retryClass: .never,
            userMessageKey: "provider.failure.shutdown",
            diagnosticCode: "ark.auth-status.shutdown",
            recovery: nil
        )
    }
}
