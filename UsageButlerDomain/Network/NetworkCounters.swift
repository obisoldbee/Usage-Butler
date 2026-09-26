import Foundation

/// Semantics of a byte counter reported by a source. The aggregator must not
/// mix counters of different semantics, sessions or epochs.
public enum CounterSemantics: String, Equatable, Hashable, Sendable {
    /// Monotonic count since the stated session+epoch started (e.g. nettop
    /// per-process totals, getifaddrs boot totals).
    case cumulativeSinceEpoch
    /// Bytes observed within the reporting interval only.
    case intervalDelta
    /// Bytes settled since this capture session started watching the subject.
    ///
    /// Distinct from `cumulativeSinceEpoch`: the first reading of a source
    /// counter is a baseline, not traffic, so a session total can be smaller
    /// than the underlying counter. Aggregating flows that each belong to a
    /// different source epoch is only legitimate under this label, because
    /// every contribution is a delta observed inside one session.
    case cumulativeWithinSession
}

/// Byte totals in both directions. Each direction is independently nullable:
/// a direction that was never observed is `nil`, never zero. Zero is only
/// reported when the source actually measured zero.
public struct DirectionalBytes: Codable, Equatable, Sendable {
    public let upload: UInt64?
    public let download: UInt64?

    public init(upload: UInt64?, download: UInt64?) {
        self.upload = upload
        self.download = download
    }

    /// `nil` when either direction is unknown; a total is never fabricated
    /// from one observed direction.
    public var total: UInt64? {
        guard let upload, let download else { return nil }
        let result = upload.addingReportingOverflow(download)
        return result.overflow ? nil : result.partialValue
    }
}

/// Byte counters bound to their counting semantics and epoch.
public struct NetworkByteCounters: Equatable, Sendable {
    public let bytes: DirectionalBytes
    public let semantics: CounterSemantics
    public let epoch: CounterEpoch

    public init(bytes: DirectionalBytes, semantics: CounterSemantics, epoch: CounterEpoch) {
        self.bytes = bytes
        self.semantics = semantics
        self.epoch = epoch
    }
}

/// A rate computed as byte delta divided by monotonic time delta. Wall-clock
/// time is never used for rates, so sleep and wall-clock jumps cannot
/// manufacture impossible rates.
public struct NetworkRate: Codable, Equatable, Sendable {
    public let uploadBytesPerSecond: Double?
    public let downloadBytesPerSecond: Double?
    /// Wall-clock time the rate window ended, for display and staleness.
    public let asOf: Date
    public let window: Duration

    public init(
        uploadBytesPerSecond: Double?,
        downloadBytesPerSecond: Double?,
        asOf: Date,
        window: Duration
    ) {
        self.uploadBytesPerSecond = uploadBytesPerSecond.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
        self.downloadBytesPerSecond = downloadBytesPerSecond.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
        self.asOf = asOf
        self.window = window
    }
}

public enum NetworkInterfaceKind: String, Equatable, Hashable, Sendable {
    case physical
    case tunnel
    case loopback
    case bridge
    case other
}

/// Bytes settled inside one capture session, starting from a baseline the
/// aggregator actually observed.
///
/// This exists because the raw interface counter answers a different question
/// than "how much has this session seen": a getifaddrs reading is a boot
/// total, its start point cannot be verified from the reading, and widening it
/// to 64 bits recovers nothing that already wrapped. Presenting it as a
/// since-boot or since-monitoring total without this settlement would be an
/// unproven claim (PRD §13.5).
public struct DirectionByteTotal: Codable, Equatable, Sendable {
    public let bytes: UInt64?
    public let since: Date?
    public let sinceMonotonic: MonotonicInstant?
    public let breakReason: String?
    public var isContinuous: Bool { breakReason == nil && since != nil }

    public init(bytes: UInt64?, since: Date?, sinceMonotonic: MonotonicInstant?, breakReason: String? = nil) {
        self.bytes = bytes
        self.since = since
        self.sinceMonotonic = sinceMonotonic
        self.breakReason = breakReason
    }
}

/// Each direction covers its current verifiable segment. No shared start is
/// asserted when only one counter reset; old v1 starts may be unverified.
public struct SessionByteTotal: Codable, Equatable, Sendable {
    public let upload: DirectionByteTotal
    public let download: DirectionByteTotal
    public var bytes: DirectionalBytes { .init(upload: upload.bytes, download: download.bytes) }
    public var since: Date? { upload.since == download.since ? upload.since : nil }
    public var sinceMonotonic: MonotonicInstant? {
        upload.sinceMonotonic == download.sinceMonotonic ? upload.sinceMonotonic : nil
    }
    public var isContinuous: Bool { upload.isContinuous && download.isContinuous }
    public var breakReason: String? { upload.breakReason ?? download.breakReason }

    public init(upload: DirectionByteTotal, download: DirectionByteTotal) {
        self.upload = upload
        self.download = download
    }

    /// For fixtures with a proven common baseline; v1 migration is handled by
    /// the codec, never by silently copying a broken shared start.
    public init(bytes: DirectionalBytes, since: Date, sinceMonotonic: MonotonicInstant, breakReason: String? = nil) {
        upload = .init(bytes: bytes.upload, since: since, sinceMonotonic: sinceMonotonic, breakReason: breakReason)
        download = .init(bytes: bytes.download, since: since, sinceMonotonic: sinceMonotonic, breakReason: breakReason)
    }
}

/// Per-interface counters. Interface counters answer "what crossed this
/// interface" only; they are never summed with per-app counters, and a proxy
/// TUN interface double-counts the physical one by design.
public struct InterfaceCounters: Equatable, Sendable {
    /// System interface index, when independently read. Same name alone is
    /// not proof of identity, and index reuse between polls is not detectable.
    public let systemIdentity: String?
    public let name: String
    public let kind: NetworkInterfaceKind
    public let counters: NetworkByteCounters
    /// Wall-clock reading time of this sample.
    public let asOf: Date
    public let monotonicAsOf: MonotonicInstant
    /// Derived by the aggregator, never by a source: what this capture session
    /// has settled for this interface since its own baseline.
    public let sessionTotal: SessionByteTotal?
    /// Expected source cadence, declared at sampling, not inferred by the chart.
    public let samplingInterval: TimeInterval?

    public init(
        name: String,
        kind: NetworkInterfaceKind,
        counters: NetworkByteCounters,
        asOf: Date,
        monotonicAsOf: MonotonicInstant,
        sessionTotal: SessionByteTotal? = nil,
        samplingInterval: TimeInterval? = nil,
        systemIdentity: String? = nil
    ) {
        self.name = name
        self.systemIdentity = systemIdentity
        self.kind = kind
        self.counters = counters
        self.asOf = asOf
        self.monotonicAsOf = monotonicAsOf
        self.sessionTotal = sessionTotal
        self.samplingInterval = samplingInterval.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
    }

    /// Same reading with different byte values, for an aggregator that has to
    /// invalidate an untrustworthy direction.
    public func replacing(bytes: DirectionalBytes) -> InterfaceCounters {
        InterfaceCounters(
            name: name,
            kind: kind,
            counters: NetworkByteCounters(
                bytes: bytes,
                semantics: counters.semantics,
                epoch: counters.epoch
            ),
            asOf: asOf,
            monotonicAsOf: monotonicAsOf,
            sessionTotal: sessionTotal,
            samplingInterval: samplingInterval,
            systemIdentity: systemIdentity
        )
    }

    public func replacing(sessionTotal: SessionByteTotal?) -> InterfaceCounters {
        InterfaceCounters(
            name: name,
            kind: kind,
            counters: counters,
            asOf: asOf,
            monotonicAsOf: monotonicAsOf,
            sessionTotal: sessionTotal,
            samplingInterval: samplingInterval,
            systemIdentity: systemIdentity
        )
    }
}

/// Per-app counters aggregated by the collector. Same nullability rules as
/// `DirectionalBytes`; `connectionCount` is `nil` whenever flow events were
/// lost and the count could be wrong — unknown is never displayed as zero.
public struct AppNetworkCounters: Equatable, Sendable {
    public let identity: AppIdentity
    public let counters: NetworkByteCounters
    public let activeConnectionCount: UInt64?
    public let rate: NetworkRate?
    public let lastActivity: Date?

    public init(
        identity: AppIdentity,
        counters: NetworkByteCounters,
        activeConnectionCount: UInt64?,
        rate: NetworkRate?,
        lastActivity: Date?
    ) {
        self.identity = identity
        self.counters = counters
        self.activeConnectionCount = activeConnectionCount
        self.rate = rate
        self.lastActivity = lastActivity
    }
}
