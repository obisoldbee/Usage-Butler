import Foundation

/// A process counter is not a connection. This contract deliberately cannot
/// manufacture flow counts, endpoints, protocols or rule execution.
public struct ProcessNetworkIdentity: Equatable, Sendable {
    public let pid: Int32
    /// Public proc_bsdinfo start seconds/microseconds + verified executable.
    /// nil means no continuity can be established across samples.
    public let instanceID: String?
    public let name: String
    public let executablePath: String?
    public let application: ProcessNetworkApplicationIdentity
    public init(pid: Int32, instanceID: String?, name: String, executablePath: String?,
                application: ProcessNetworkApplicationIdentity) {
        self.pid = pid; self.instanceID = instanceID; self.name = name
        self.executablePath = executablePath; self.application = application
    }
}

public struct ProcessNetworkApplicationIdentity: Equatable, Sendable {
    public enum Evidence: String, Sendable { case executableBundle, nestedBundle, executable, unknown }
    public let key: String
    public let name: String
    public let bundleID: String?
    public let installationPath: String?
    public let evidence: Evidence
    /// No signing claim is inferred from a bundle identifier.
    public var signingIdentity: String? { nil }
    public init(key: String, name: String, bundleID: String? = nil,
                installationPath: String? = nil, evidence: Evidence) {
        self.key = key; self.name = name; self.bundleID = bundleID
        self.installationPath = installationPath; self.evidence = evidence
    }
}

public struct ProcessNetworkCounter: Equatable, Sendable {
    public let identity: ProcessNetworkIdentity
    public let bytes: DirectionalBytes
    public init(identity: ProcessNetworkIdentity, bytes: DirectionalBytes) {
        self.identity = identity; self.bytes = bytes
    }
}

public struct ProcessNetworkFrame: Equatable, Sendable {
    public let envelope: NetworkEventEnvelope
    public let processes: [ProcessNetworkCounter]
    /// Complete *nettop frame*, not proof of all system processes/connections.
    public let complete: Bool
    public let issue: String?
    public let samplingInterval: TimeInterval
    public init(envelope: NetworkEventEnvelope, processes: [ProcessNetworkCounter],
                complete: Bool, issue: String? = nil, samplingInterval: TimeInterval = 1) {
        self.envelope = envelope; self.processes = processes
        self.complete = complete; self.issue = issue; self.samplingInterval = samplingInterval
    }
}

public enum ProcessNetworkState: String, Equatable, Sendable {
    case stopped, starting, active, partial, unavailable
}

public struct ProcessNetworkApplication: Equatable, Sendable {
    public let identity: ProcessNetworkApplicationIdentity
    public let processes: [ProcessNetworkCounter]
    public let presence: NetworkInterfacePresence
    public let rate: NetworkRate?
    public let total: SessionByteTotal
    public let history: [NetworkRateSample]
    public let sampledAt: Date
    public let sampledMonotonic: MonotonicInstant
    public let historyTruncated: Bool
    public init(identity: ProcessNetworkApplicationIdentity, processes: [ProcessNetworkCounter],
                presence: NetworkInterfacePresence, rate: NetworkRate?, total: SessionByteTotal,
                history: [NetworkRateSample], sampledAt: Date, sampledMonotonic: MonotonicInstant,
                historyTruncated: Bool) {
        self.identity = identity; self.processes = processes; self.presence = presence
        self.rate = rate; self.total = total; self.history = history
        self.sampledAt = sampledAt; self.sampledMonotonic = sampledMonotonic
        self.historyTruncated = historyTruncated
    }
}

public struct ProcessNetworkSnapshot: Equatable, Sendable {
    public static let sourceID = "system-nettop-process-v1"
    public let sessionID: CaptureSessionID
    public let sequence: UInt64
    public let state: ProcessNetworkState
    public let issue: String?
    public let applications: [String: ProcessNetworkApplication]
    public let sampledAt: Date?
    public let sampledMonotonic: MonotonicInstant?
    public let truncated: Bool
    public let lostFrames: UInt64
    public var historyPointCount: Int { applications.values.reduce(0) { $0 + $1.history.count } }
    public init(sessionID: CaptureSessionID, sequence: UInt64, state: ProcessNetworkState,
                issue: String?, applications: [String: ProcessNetworkApplication],
                sampledAt: Date?, sampledMonotonic: MonotonicInstant?, truncated: Bool, lostFrames: UInt64) {
        self.sessionID = sessionID; self.sequence = sequence; self.state = state
        self.issue = issue; self.applications = applications; self.sampledAt = sampledAt
        self.sampledMonotonic = sampledMonotonic; self.truncated = truncated; self.lostFrames = lostFrames
    }
}
