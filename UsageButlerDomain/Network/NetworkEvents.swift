import Foundation

/// Envelope every source event carries. `sequence` is strictly monotonic
/// within one session: gaps mean lost events, replays are duplicates, and
/// events from a foreign session are dropped on arrival.
public struct NetworkEventEnvelope: Equatable, Sendable {
    public let sessionID: CaptureSessionID
    public let sequence: UInt64
    /// Wall-clock event time (display only).
    public let occurredAt: Date
    /// Monotonic event time (all interval/rate math).
    public let monotonicOccurredAt: MonotonicInstant

    public init(
        sessionID: CaptureSessionID,
        sequence: UInt64,
        occurredAt: Date,
        monotonicOccurredAt: MonotonicInstant
    ) {
        self.sessionID = sessionID
        self.sequence = sequence
        self.occurredAt = occurredAt
        self.monotonicOccurredAt = monotonicOccurredAt
    }
}

/// Payload of one source event. Sources report what they actually observed;
/// aggregation, epoch changes and gap accounting happen in the core layer.
public enum NetworkSourcePayload: Equatable, Sendable {
    /// A flow was first observed. Endpoint fields may be absent at
    /// establishment and back-filled by later events.
    case flowStarted(FlowIdentity)
    /// A counter report for a flow. `counters.bytes` direction is `nil` when
    /// the source did not observe that direction; a final close report has
    /// `isFinal == true` and must be idempotent.
    case flowCounters(flowID: FlowID, counters: NetworkByteCounters, isFinal: Bool)
    /// Endpoint/hostname observed after establishment; never overwrites
    /// already-known fields.
    case flowTargetResolved(flowID: FlowID, remoteEndpoint: NetworkEndpoint?, remoteHostname: String?, targetSource: NetworkTargetSource)
    /// The flow closed. A duplicate or out-of-order close after the final
    /// counter report is ignored.
    case flowEnded(flowID: FlowID)
    /// Per-interface counters (boot-epoch cumulative from getifaddrs, or
    /// interval deltas from another source).
    case interfaceCounters(InterfaceCounters)
    /// One completed read, atomically carrying every interface or an explicit
    /// failure. Individual counter events never prove that another name left.
    case interfaceEnumeration(NetworkInterfaceEnumeration)
    /// A previously observed process exited. Its history stays readable and
    /// is marked exited; a later PID reuse creates a new process.
    case processExited(ProcessIdentity)
    /// Liveness marker; carries the source's current capabilities so UI
    /// never has to guess from toggles.
    case heartbeat(capabilities: NetworkCapabilities)
}

public struct NetworkSourceEvent: Equatable, Sendable {
    public let envelope: NetworkEventEnvelope
    public let payload: NetworkSourcePayload

    public init(envelope: NetworkEventEnvelope, payload: NetworkSourcePayload) {
        self.envelope = envelope
        self.payload = payload
    }
}

public enum NetworkInterfaceEnumeration: Equatable, Sendable {
    case complete([InterfaceCounters])
    case failed
}

public enum NetworkInterfacePresence: String, Codable, Equatable, Sendable {
    case present, missing, unknown, notObserved
}

/// Latest completed enumeration, with the same ordered session boundary as
/// counters. No inventory is legacy/unknown evidence, never an empty success.
public struct NetworkInterfaceInventory: Equatable, Sendable {
    public let envelope: NetworkEventEnvelope
    public let succeeded: Bool
    public let names: Set<String>
    public init(envelope: NetworkEventEnvelope, succeeded: Bool, names: Set<String>) {
        self.envelope = envelope
        self.succeeded = succeeded
        self.names = succeeded ? names : []
    }
}
