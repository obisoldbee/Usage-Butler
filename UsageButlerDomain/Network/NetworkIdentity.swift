import Foundation

/// Uniquely identifies one capture session. A new session starts whenever the
/// collector (re)starts; events from an old session must never contaminate a
/// newer session's aggregates.
public struct CaptureSessionID: RawRepresentable, Equatable, Hashable, Sendable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }
}

/// Monotonic counter epoch within a session. Counter resets, counter wrap and
/// source restarts require a new epoch; a same-epoch decrease is a contract
/// violation and is surfaced instead of being silently absorbed.
public struct CounterEpoch: RawRepresentable, Equatable, Hashable, Comparable, Sendable {
    public let rawValue: UInt64

    public init(rawValue: UInt64) {
        self.rawValue = rawValue
    }

    public static func < (lhs: CounterEpoch, rhs: CounterEpoch) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// Stable per-session flow identifier. Unique within a session; never reused
/// for a different flow in the same session.
public struct FlowID: RawRepresentable, Equatable, Hashable, Sendable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }
}

/// Identifies one directional observation record. Two directions of one flow
/// are two observations of the same `FlowID`, not two sockets.
public struct ObservationID: RawRepresentable, Equatable, Hashable, Sendable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }
}

public enum NetworkProtocolKind: String, Equatable, Hashable, Sendable {
    case tcp
    case udp
    case unknown
}

public enum NetworkAddressFamily: String, Equatable, Hashable, Sendable {
    case ipv4
    case ipv6
    case unknown
}

/// A network endpoint. Hostname and address are kept separate: a hostname is
/// only trustworthy when the source actually observed it, and an observed IP
/// must never be reverse-mapped to a fabricated domain name.
public struct NetworkEndpoint: Equatable, Hashable, Sendable {
    public enum Host: Equatable, Hashable, Sendable {
        case ipv4(String)
        case ipv6(String)
    }

    public let host: Host
    /// `nil` means the port was not observed; unknown is not zero.
    public let port: UInt16?

    public init(host: Host, port: UInt16?) {
        self.host = host
        self.port = port
    }
}

/// Where a flow's target identity came from. A DNS-resolved shared IP must
/// not be permanently equated with the domain that resolved to it.
public enum NetworkTargetSource: String, Equatable, Hashable, Sendable {
    case systemProvided
    case proxyReported
    case unknown
}

/// The actual operating-system process behind observed traffic. PID alone is
/// not an identity: PID reuse is separated by `startTime`.
public struct ProcessIdentity: Equatable, Hashable, Sendable {
    public let pid: Int32
    public let startTime: Date
    public let executablePath: String?
    /// Display name from the system; may be truncated by the source and must
    /// not be used as an identity key.
    public let displayName: String?

    public init(
        pid: Int32,
        startTime: Date,
        executablePath: String? = nil,
        displayName: String? = nil
    ) {
        self.pid = pid
        self.startTime = startTime
        self.executablePath = executablePath
        self.displayName = displayName
    }
}

/// Confidence of attributing traffic to an app. System-proxied or otherwise
/// unattributable traffic stays `unknown`; it is never force-matched by name.
public enum AppAttributionConfidence: String, Equatable, Hashable, Sendable {
    case confirmed
    case likely
    case unknown
    case systemProxy
}

/// Stable application identity, bound to signing/Bundle evidence rather than
/// PID or display name. All fields may be individually unavailable; the
/// `stableKey` only incorporates fields that are actually present.
public struct AppIdentity: Equatable, Hashable, Sendable {
    public let bundleID: String?
    public let signingIdentity: String?
    public let teamID: String?
    public let version: String?
    /// Human-readable name for display only; never part of `stableKey`.
    public let displayName: String?

    public init(
        bundleID: String? = nil,
        signingIdentity: String? = nil,
        teamID: String? = nil,
        version: String? = nil,
        displayName: String? = nil
    ) {
        self.bundleID = bundleID
        self.signingIdentity = signingIdentity
        self.teamID = teamID
        self.version = version
        self.displayName = displayName
    }

    /// Deterministic identity key used for grouping and watchlist/rule
    /// persistence. Distinct missing-field profiles produce distinct keys;
    /// an entirely unidentified app groups under `.unidentified`.
    public var stableKey: String {
        guard bundleID != nil || signingIdentity != nil || teamID != nil else {
            return "unidentified"
        }
        return [
            bundleID.map { "b:\($0)" },
            signingIdentity.map { "s:\($0)" },
            teamID.map { "t:\($0)" },
        ]
        .compactMap { $0 }
        .joined(separator: "|")
    }
}

/// Identity of one observed flow. Endpoints and hostname may be incomplete at
/// establishment time and back-filled later; later completion must not create
/// a second flow.
public struct FlowIdentity: Equatable, Hashable, Sendable {
    public let flowID: FlowID
    public let sessionID: CaptureSessionID
    public let transport: NetworkProtocolKind
    public let addressFamily: NetworkAddressFamily
    public let process: ProcessIdentity
    public let attribution: AppAttributionConfidence
    /// Resolved stable app identity when attribution is confirmed/likely;
    /// `nil` (with `attribution == .unknown`/`.systemProxy`) keeps the flow
    /// under the unidentified group instead of guessing by name.
    public let app: AppIdentity?
    /// `nil` until observed; absent is not `0.0.0.0:0`.
    public let localEndpoint: NetworkEndpoint?
    public let remoteEndpoint: NetworkEndpoint?
    /// Hostname only as reported by the source, with provenance.
    public let remoteHostname: String?
    public let targetSource: NetworkTargetSource

    public init(
        flowID: FlowID,
        sessionID: CaptureSessionID,
        transport: NetworkProtocolKind,
        addressFamily: NetworkAddressFamily,
        process: ProcessIdentity,
        attribution: AppAttributionConfidence,
        app: AppIdentity? = nil,
        localEndpoint: NetworkEndpoint? = nil,
        remoteEndpoint: NetworkEndpoint? = nil,
        remoteHostname: String? = nil,
        targetSource: NetworkTargetSource = .unknown
    ) {
        self.flowID = flowID
        self.sessionID = sessionID
        self.transport = transport
        self.addressFamily = addressFamily
        self.process = process
        self.attribution = attribution
        self.app = app
        self.localEndpoint = localEndpoint
        self.remoteEndpoint = remoteEndpoint
        self.remoteHostname = remoteHostname
        self.targetSource = targetSource
    }

    /// Returns a copy with newly observed endpoint/hostname fields filled in.
    /// Already-known fields are never overwritten by later events.
    public func backfilling(
        localEndpoint: NetworkEndpoint? = nil,
        remoteEndpoint: NetworkEndpoint? = nil,
        remoteHostname: String? = nil,
        targetSource: NetworkTargetSource? = nil
    ) -> FlowIdentity {
        FlowIdentity(
            flowID: flowID,
            sessionID: sessionID,
            transport: transport,
            addressFamily: addressFamily,
            process: process,
            attribution: attribution,
            app: app,
            localEndpoint: self.localEndpoint ?? localEndpoint,
            remoteEndpoint: self.remoteEndpoint ?? remoteEndpoint,
            remoteHostname: self.remoteHostname ?? remoteHostname,
            targetSource: self.targetSource == .unknown ? (targetSource ?? self.targetSource) : self.targetSource
        )
    }
}
