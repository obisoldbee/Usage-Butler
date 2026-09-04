public enum FailureCode: String, Equatable, Hashable, Sendable, CaseIterable {
    case missingExecutable
    case authenticationRequired
    case authenticationExpired
    case networkUnavailable
    case serviceUnavailable
    case rateLimited
    case timedOut
    case sessionEOF
    case schemaMismatch
    case protocolViolation
    case permissionDenied
    case cancelled
    case processFailed
    case cacheCorrupt
    case cacheUnavailable
    case identityMismatch
    case shutdown
    case unknown
}

public enum RetryClass: Equatable, Sendable, CaseIterable {
    case never
    case immediate
    case backoff
    case afterRecovery
}

public enum RecoveryAction: Equatable, Sendable {
    case retry
    case login(LoginMethod)
    case install
    case selectExecutable
    case openOfficialDocumentation
}

public struct ProviderFailure: Error, Equatable, Sendable {
    public let code: FailureCode
    public let retryClass: RetryClass
    public let userMessageKey: String
    public let diagnosticCode: String
    public let recovery: RecoveryAction?

    public init(
        code: FailureCode,
        retryClass: RetryClass,
        userMessageKey: String,
        diagnosticCode: String,
        recovery: RecoveryAction?
    ) {
        self.code = code
        self.retryClass = retryClass
        self.userMessageKey = userMessageKey
        self.diagnosticCode = diagnosticCode
        self.recovery = recovery
    }
}
