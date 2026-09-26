import Foundation

/// Only fixed codes and bounded numbers may cross the lifecycle log boundary.
/// No source strings, process identities, paths or raw output are accepted.
public struct ProcessNetworkLifecycleEvent: Equatable, Sendable, Encodable {
    public enum Kind: String, Sendable, Encodable {
        case collectorStarted, collectorStopped, sourceStarted, sourceEnded
        case retryScheduled, retryCancelled, retryExhausted, budgetReplenished
    }
    public enum Reason: String, Sendable, Encodable {
        case enabled, disabled, manualRefresh, resumed, suspended, shutdown
        case automaticRetry, healthyWindow, launched, cancelled, unknown
        case sourceEnded = "source-ended", ptyUnavailable = "pty-unavailable"
        case ptyConfigurationFailed = "pty-config-failed"
        case launchFailed = "launch-failed", readFailed = "read-failed"
        case stderrLimit = "stderr-limit", stdoutFrameLimit = "stdout-frame-limit"
        case sourceEOF = "source-eof", sourceExited = "source-exited", sourceTimeout = "source-timeout"
        public static func sourceIssue(_ issue: String?) -> Self {
            switch issue {
            case "pty-unavailable": .ptyUnavailable
            case "pty-config-failed": .ptyConfigurationFailed
            case "launch-failed": .launchFailed
            case "read-failed": .readFailed
            case "stderr-limit": .stderrLimit
            case "stdout-frame-limit": .stdoutFrameLimit
            case "source-eof": .sourceEOF
            case "source-exited": .sourceExited
            case "source-timeout": .sourceTimeout
            case nil, "source-ended": .sourceEnded
            default: .unknown
            }
        }
    }
    public enum ExitKind: String, Sendable, Encodable { case exited, signal, notStarted }
    public enum Cleanup: String, Sendable, Encodable { case none, terminate, kill }
    public let kind: Kind
    public let reason: Reason
    public let attempt: Int?
    public let delaySeconds: Int?
    public let exitStatus: Int32?
    public let exitKind: ExitKind?
    public let cleanup: Cleanup?
    public let errorNumber: Int32?
    public let lastHeaderAgeMilliseconds: UInt32?
    public init(kind: Kind, reason: Reason, attempt: Int? = nil, delaySeconds: Int? = nil,
                exitStatus: Int32? = nil, exitKind: ExitKind? = nil, cleanup: Cleanup? = nil,
                errorNumber: Int32? = nil, lastHeaderAgeMilliseconds: UInt32? = nil) {
        self.kind = kind; self.reason = reason
        self.attempt = attempt.map { min(3, max(0, $0)) }
        self.delaySeconds = delaySeconds.map { min(6, max(0, $0)) }
        self.exitStatus = exitStatus.map { min(255, max(0, $0)) }
        self.exitKind = exitKind; self.cleanup = cleanup
        self.errorNumber = errorNumber.map { min(255, max(0, $0)) }
        self.lastHeaderAgeMilliseconds = lastHeaderAgeMilliseconds.map { min(600_000, $0) }
    }
    public func encoded() -> Data { (try? JSONEncoder().encode(self)) ?? Data() }
}
