import Foundation
import UsageButlerDomain

public enum DiscoveryResult: Equatable, Sendable {
    case success(SuccessfulProviderDiscovery)
    case failure(ProviderFailure)
}

public enum ProviderReadResult: Equatable, Sendable {
    case success(ProviderQuotaData)
    /// The read succeeded for all authoritative fields that were returned, while
    /// an optional sibling was legally omitted and must retain prior last-good.
    case successPatch(ProviderQuotaPatch)
    case partial(ProviderQuotaPatch, ProviderFailure)
    case failure(ProviderFailure)
}

public enum LoginResult: Equatable, Sendable {
    case success
    case cancelled
    case failure(ProviderFailure)
}

public struct SafeProviderDiagnostic: Equatable, Sendable {
    public let providerID: ProviderID
    public let capturedAt: Date
    public let diagnosticCode: String
    public let safeFields: [String: String]
    public let events: [ProviderDiagnosticEvent]
    public let journalAvailable: Bool

    public init(
        providerID: ProviderID,
        capturedAt: Date,
        diagnosticCode: String,
        safeFields: [String: String],
        events: [ProviderDiagnosticEvent] = [],
        journalAvailable: Bool = true
    ) {
        self.providerID = providerID
        self.capturedAt = capturedAt
        self.diagnosticCode = diagnosticCode
        self.safeFields = safeFields
        self.events = events
        self.journalAvailable = journalAvailable
    }
}

public protocol ProviderAdapter: Actor {
    nonisolated var id: ProviderID { get }
    nonisolated var capabilities: ProviderCapabilities { get }

    func discover() async -> DiscoveryResult
    func read(scope: ProviderScope) async -> ProviderReadResult
    /// Invalidates any adapter-owned authentication observation cache before
    /// an explicit user or recovery probe. Automatic reads keep their cache.
    func invalidateAuthenticationCache() async
    /// Optional independent authentication evidence from the just-completed read.
    /// No additional provider request is performed by this accessor.
    func authenticationAfterRead() async -> AuthenticationState?
    func login(method: LoginMethod) async -> LoginResult
    func diagnosticSnapshot() async -> SafeProviderDiagnostic
    func shutdown() async
}

public extension ProviderAdapter {
    func invalidateAuthenticationCache() async {}
    func authenticationAfterRead() async -> AuthenticationState? { nil }
}
