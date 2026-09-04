import Foundation
import UsageButlerDomain

public struct ChildProcessLimits: Equatable, Sendable {
    public let timeout: Duration
    public let standardOutputByteLimit: Int
    public let standardErrorByteLimit: Int
    public let lineLimit: Int

    public init(
        timeout: Duration,
        standardOutputByteLimit: Int,
        standardErrorByteLimit: Int,
        lineLimit: Int
    ) {
        self.timeout = timeout
        self.standardOutputByteLimit = standardOutputByteLimit
        self.standardErrorByteLimit = standardErrorByteLimit
        self.lineLimit = lineLimit
    }
}

public struct ChildProcessRequest: Equatable, Sendable {
    public let executableURL: URL
    public let arguments: [String]
    public let environment: [String: String]
    public let standardInput: Data?
    public let limits: ChildProcessLimits
    public let nonZeroExitPolicy: ChildProcessNonZeroExitPolicy

    public init(
        executableURL: URL,
        arguments: [String],
        environment: [String: String],
        standardInput: Data?,
        limits: ChildProcessLimits,
        nonZeroExitPolicy: ChildProcessNonZeroExitPolicy = .typedFailure
    ) {
        self.executableURL = executableURL
        self.arguments = arguments
        self.environment = environment
        self.standardInput = standardInput
        self.limits = limits
        self.nonZeroExitPolicy = nonZeroExitPolicy
    }
}

public enum ChildProcessNonZeroExitPolicy: Equatable, Sendable {
    case typedFailure
    /// Returns bounded stdout and already-redacted stderr to the adapter so it
    /// can classify a documented provider error without logging raw output.
    case returnBoundedOutput
}

public enum ChildProcessTermination: Equatable, Sendable {
    case exited(code: Int32)
    case signalled(signal: Int32)
}

public struct ChildProcessOutput: Equatable, Sendable {
    public let termination: ChildProcessTermination
    public let standardOutput: Data
    /// Infrastructure must redact this stream before constructing the value.
    public let redactedStandardError: Data

    public init(
        termination: ChildProcessTermination,
        standardOutput: Data,
        redactedStandardError: Data
    ) {
        self.termination = termination
        self.standardOutput = standardOutput
        self.redactedStandardError = redactedStandardError
    }
}

public protocol ChildProcessClient: Actor {
    func run(_ request: ChildProcessRequest) async -> Result<ChildProcessOutput, ProviderFailure>
    func shutdown() async
}
