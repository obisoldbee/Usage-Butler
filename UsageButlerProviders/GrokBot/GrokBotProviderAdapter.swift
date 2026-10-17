import CryptoKit
import Foundation
import UsageButlerCore
import UsageButlerDomain

public actor GrokBotProviderAdapter: ProviderAdapter {
    public nonisolated let id = ProviderID.grokBot
    public nonisolated let capabilities = ProviderCapabilities(contractVersion: GrokSharedQuotaMapper.contractVersion,
        loginMethod: nil, hasOfficialDocumentation: true, allowsExecutableSelection: false)
    public nonisolated let retainsDataWhenDisabled = false
    private let reader: any CursorSessionReading
    private let client: GrokBotHTTPClient
    private let now: @Sendable () -> Date
    private var consent = false
    private var stopped = false
    private var accessRevision: UInt64?
    private var generation: UInt64 = 0
    private var cacheSessionKey: SymmetricKey?
    private var subject: String?
    private var scope = UUID().uuidString
    private var prepared: CursorReadOnlySession?
    private var preparationFailure: ProviderFailure?
    private var authentication: AuthenticationState?
    private var retainAfterRead = true
    private var active: Task<ProviderReadResult, Never>?

    public init(reader: any CursorSessionReading = CursorSQLiteSessionReader(), client: GrokBotHTTPClient = .init(),
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.reader = reader; self.client = client; self.now = now
    }
    public func setAccessEnabled(_ enabled: Bool) async {
        guard !stopped else { return }
        applyAccess(enabled)
    }
    public func setAccessEnabled(_ enabled: Bool, generation: UInt64) async {
        guard !stopped, accessRevision.map({ generation >= $0 }) ?? true else { return }
        accessRevision = generation
        applyAccess(enabled)
    }
    private func applyAccess(_ enabled: Bool) {
        guard consent != enabled else { return }
        consent = enabled; generation &+= 1; active?.cancel(); active = nil; prepared = nil; preparationFailure = nil
        if !enabled { cacheSessionKey = nil; subject = nil; scope = UUID().uuidString; authentication = nil; retainAfterRead = false }
    }
    /// Uses only an explicitly authorized, currently valid exact session. This is
    /// association evidence for stale data, never a server authentication claim.
    public func quotaCacheAssociation() async -> GrokBotCacheAssociation? {
        guard consent else { return nil }
        let current = generation
        do {
            guard let session = try await reader.load(), session.expiresAt > now() else { return nil }
            guard consent, current == generation, !Task.isCancelled else { return nil }
            return bindCacheAssociation(to: session)
        } catch { return nil }
    }
    private func bindCacheAssociation(to session: CursorReadOnlySession) -> GrokBotCacheAssociation {
        let key = HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: Data(session.token.utf8)),
            salt: Data("usage-butler.grokbot.session-cache.v1".utf8),
            info: Data("grokBot.cursor-sand.normalized-last-good".utf8), outputByteCount: 32)
        if subject != session.subject || cacheSessionKey != key { scope = UUID().uuidString }
        subject = session.subject; cacheSessionKey = key
        return .init(key: key, sessionScope: scope, generation: generation, expiresAt: session.expiresAt)
    }
    public func discover() async -> DiscoveryResult {
        guard consent else { return .failure(Self.failure(.consentRequired)) }
        let evidence = AuthenticationEvidence(authority: .initialDetection, observedAt: now())
        return .success(.init(providerID: id, authority: .init(source: GrokSharedQuotaMapper.source(), operationID: "cursor-session-consent"),
            observedAt: now(), connection: .connected, authentication: .unknown(evidence), presence: nil))
    }
    public func prepareForRead(retaining source: ProviderSourceIdentity?) async -> Bool {
        prepared = nil; preparationFailure = nil; retainAfterRead = true
        guard consent else { preparationFailure = Self.failure(.consentRequired); return true }
        let current = generation
        do {
            guard let session = try await reader.load() else { throw GrokBotReadError.noSession }
            try Task.checkCancellation()
            guard consent, current == generation else { return true }
            _ = bindCacheAssociation(to: session)
            prepared = session
            return source != nil && (source?.sessionScope != scope || source?.adapterID != GrokSharedQuotaMapper.source().adapterID)
        } catch {
            guard consent, current == generation, !Task.isCancelled else { return true }
            preparationFailure = Self.failure(error)
            authentication = Self.authentication(for: error, at: now())
            // Without a provable current local identity old data cannot be safely attributed.
            retainAfterRead = false
            return true
        }
    }
    public func mayRetainLastGoodAfterRead() async -> Bool { retainAfterRead }
    public func read(scope requestedScope: ProviderScope) async -> ProviderReadResult {
        guard consent else { return .failure(Self.failure(.consentRequired)) }
        if let preparationFailure { return .failure(preparationFailure) }
        guard let session = prepared else { return .failure(Self.failure(.noSession)) }
        prepared = nil
        let current = generation
        let client = client, reader = reader, now = now, scope = scope
        let task = Task<ProviderReadResult, Never> {
            do {
                try await client.verify(session: session)
                let raw = try await client.fetch(.shared, session: session)
                // Detect account/session changes that happened while the requests were in flight.
                guard let final = try await reader.load(), final.subject == session.subject,
                      final.token == session.token else { throw GrokBotReadError.identityMismatch }
                try Task.checkCancellation()
                let data = try GrokSharedQuotaMapper.map(raw, fetchedAt: now(), sessionScope: scope)
                if let shared = data.grokBotUsage?.shared, shared.availability == .available, shared.weeklyStatus == .unavailable {
                    throw GrokBotReadError.quotaUnavailable
                }
                return .success(data)
            } catch { return .failure(Self.failure(error)) }
        }
        active = task
        let result = await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
        guard consent, current == generation, !Task.isCancelled else { return .failure(Self.failure(CancellationError())) }
        active = nil
        if case let .failure(failure) = result {
            if failure.code == .identityMismatch {
                retainAfterRead = false; cacheSessionKey = nil; subject = nil; self.scope = UUID().uuidString
            }
            authentication = failure.code == .authenticationRequired
                ? .unknown(.init(authority: .providerReport(sourceField: "cursor-auth-rejected", contractVersion: GrokSharedQuotaMapper.contractVersion), observedAt: now()))
                : authentication
        } else {
            authentication = .healthy(.init(authority: .providerReport(sourceField: "api.auth.me.sub", contractVersion: GrokSharedQuotaMapper.contractVersion),
                observedAt: now(), expiresAt: session.expiresAt))
        }
        return result
    }
    public func authenticationAfterRead() async -> AuthenticationState? { authentication }
    public func invalidateAuthenticationCache() async { prepared = nil }
    public func login(method: LoginMethod) async -> LoginResult { .failure(Self.failure(.noSession)) }
    public func diagnosticSnapshot() async -> SafeProviderDiagnostic {
        .init(providerID: id, capturedAt: now(), diagnosticCode: "grokbot.read-only.v1", safeFields: ["transport": "https", "state": consent ? "authorized" : "disabled"])
    }
    public func shutdown() async { stopped = true; consent = false; generation &+= 1; active?.cancel(); active = nil; prepared = nil; cacheSessionKey = nil; subject = nil; authentication = nil }

    private static func authentication(for error: Error, at date: Date) -> AuthenticationState? {
        if error as? GrokBotReadError == .expiredSession {
            return .expired(.init(authority: .explicitExpiration(sourceField: "cursor-session.jwt.exp", contractVersion: GrokBotQuotaMapper.contractVersion), observedAt: date))
        }
        return .unknown(.init(authority: .initialDetection, observedAt: date))
    }
    private static func failure(_ error: GrokBotReadError) -> ProviderFailure { failure(error as Error) }
    private static func failure(_ error: Error) -> ProviderFailure {
        let code: FailureCode
        switch error {
        case is CancellationError: code = .cancelled
        case let error as URLError: code = error.code == .timedOut ? .timedOut : (error.code == .cancelled ? .cancelled : .networkUnavailable)
        case let error as GrokBotReadError:
            switch error {
            case .consentRequired, .unsafeFile: code = .permissionDenied
            case .noSession, .invalidSession: code = .authenticationRequired
            case .expiredSession: code = .authenticationExpired
            case .identityMismatch: code = .identityMismatch
            case .databaseUnavailable: code = .serviceUnavailable
            case .http(401), .http(403): code = .authenticationRequired
            case .http(429): code = .rateLimited
            case .http, .quotaUnavailable: code = .serviceUnavailable
            case .redirect, .unsupportedEndpoint: code = .protocolViolation
            case .schema, .responseTooLarge: code = .schemaMismatch
            }
        default: code = .schemaMismatch
        }
        return ProviderFailure(code: code, retryClass: code == .permissionDenied ? .afterRecovery : .backoff,
            userMessageKey: "provider.grokbot.\(code.rawValue)", diagnosticCode: "grokbot.\(code.rawValue)",
            recovery: code == .authenticationRequired || code == .authenticationExpired ? .openOfficialDocumentation : .retry)
    }
}
