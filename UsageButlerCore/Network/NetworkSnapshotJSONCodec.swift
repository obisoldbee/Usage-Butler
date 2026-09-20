import Foundation
import UsageButlerDomain

public enum NetworkSnapshotCodecFailure: Error, Equatable, Sendable {
    case oversized(limit: Int)
    case corrupt
    case unsupportedSchema
    case unsupportedVersion(Int)
    /// An enum raw value, numeric encoding or field failed validation.
    case invalidValue(field: String)
}

/// Versioned JSON boundary for network snapshots. v1 rules:
/// - `UInt64` counters are decimal strings, so cross-language consumers never
///   hit floating-point truncation above 2^53.
/// - Dates are ISO-8601 UTC with milliseconds; monotonic times are decimal
///   nanosecond strings.
/// - Unknown keys are ignored (forward-compatible within v1); unknown enum
///   values, wrong schema/version and malformed numbers are hard failures.
public enum NetworkSnapshotJSONCodec {
    public static let schema = "usagebutler.network.snapshot"
    public static let version = NetworkSnapshot.contractVersion
    public static let defaultSizeLimit = 8 * 1024 * 1024

    // MARK: - Wire DTOs

    private struct Wire: Codable {
        var schema: String
        var version: Int
        var session: String
        var appliedSequence: String
        var asOf: String
        var monotonicAsOf: String
        var collectionState: Tagged
        var coverage: CoverageWire
        var capabilities: CapabilitiesWire
        var interfaces: [String: InterfaceWire]
        var apps: [String: AppWire]
        var interfaceRates: [String: RateWire]
    }

    private struct Tagged: Codable {
        var type: String
        var reason: String?
        var since: String?
    }

    private struct CoverageWire: Codable {
        var identity: Tagged
        var bytes: Tagged
        var targets: Tagged
        var protocols: Tagged
        var lostEventCount: String
        var counterResetCount: String
        var truncatedCollections: [String]
        var hasLiveSample: Bool
    }

    private struct CapabilitiesWire: Codable {
        var observe: Bool
        var blockNewConnections: Bool
        var terminateExistingConnections: Bool
        var ask: Bool
        var allowlist: Bool
        var history: Bool
        var export: Bool
        var blockers: [String]
    }

    private struct InterfaceWire: Codable {
        var name: String
        var kind: String
        var counters: CountersWire
        var asOf: String
        var monotonicAsOf: String
        var sessionTotal: SessionTotalWire?
    }

    /// Continuity is not stored: it is exactly "no break reason", and writing
    /// both would let a payload claim to be continuous and broken at once.
    private struct SessionTotalWire: Codable {
        var upload: String?
        var download: String?
        var since: String
        var sinceMonotonicAsOf: String
        var breakReason: String?
    }

    private struct CountersWire: Codable {
        var upload: String?
        var download: String?
        var semantics: String
        var epoch: String
    }

    private struct AppWire: Codable {
        var identity: AppIdentityWire
        var counters: CountersWire
        var activeConnectionCount: String?
        var rate: RateWire?
        var lastActivity: String?
    }

    private struct AppIdentityWire: Codable {
        var bundleID: String?
        var signingIdentity: String?
        var teamID: String?
        var version: String?
        var displayName: String?
    }

    private struct RateWire: Codable {
        var uploadBytesPerSecond: Double?
        var downloadBytesPerSecond: Double?
        var asOf: String
        var windowNanoseconds: String
    }

    // MARK: - Encode

    public static func encode(_ snapshot: NetworkSnapshot) throws -> Data {
        let wire = Wire(
            schema: schema,
            version: version,
            session: snapshot.sessionID.rawValue,
            appliedSequence: String(snapshot.appliedSequence),
            asOf: format(snapshot.asOf),
            monotonicAsOf: String(snapshot.monotonicAsOf.nanoseconds),
            collectionState: tag(snapshot.collectionState),
            coverage: CoverageWire(
                identity: tag(snapshot.coverage.identity),
                bytes: tag(snapshot.coverage.bytes),
                targets: tag(snapshot.coverage.targets),
                protocols: tag(snapshot.coverage.protocols),
                lostEventCount: String(snapshot.coverage.lostEventCount),
                counterResetCount: String(snapshot.coverage.counterResetCount),
                truncatedCollections: snapshot.coverage.truncatedCollections,
                hasLiveSample: snapshot.coverage.hasLiveSample
            ),
            capabilities: CapabilitiesWire(
                observe: snapshot.capabilities.observe,
                blockNewConnections: snapshot.capabilities.blockNewConnections,
                terminateExistingConnections: snapshot.capabilities.terminateExistingConnections,
                ask: snapshot.capabilities.ask,
                allowlist: snapshot.capabilities.allowlist,
                history: snapshot.capabilities.history,
                export: snapshot.capabilities.export,
                blockers: snapshot.capabilities.blockers.map(\.rawValue)
            ),
            interfaces: snapshot.interfaces.mapValues { interface in
                InterfaceWire(
                    name: interface.name,
                    kind: interface.kind.rawValue,
                    counters: counters(interface.counters),
                    asOf: format(interface.asOf),
                    monotonicAsOf: String(interface.monotonicAsOf.nanoseconds),
                    sessionTotal: interface.sessionTotal.map(Self.sessionTotal)
                )
            },
            apps: snapshot.apps.mapValues { app in
                AppWire(
                    identity: AppIdentityWire(
                        bundleID: app.identity.bundleID,
                        signingIdentity: app.identity.signingIdentity,
                        teamID: app.identity.teamID,
                        version: app.identity.version,
                        displayName: app.identity.displayName
                    ),
                    counters: counters(app.counters),
                    activeConnectionCount: app.activeConnectionCount.map(String.init),
                    rate: app.rate.map(rate),
                    lastActivity: app.lastActivity.map(format)
                )
            },
            interfaceRates: snapshot.interfaceRates.mapValues(rate)
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(wire)
    }

    // MARK: - Decode

    public static func decode(_ data: Data, sizeLimit: Int = defaultSizeLimit) throws -> NetworkSnapshot {
        guard data.count <= sizeLimit else {
            throw NetworkSnapshotCodecFailure.oversized(limit: sizeLimit)
        }
        let wire: Wire
        do {
            wire = try JSONDecoder().decode(Wire.self, from: data)
        } catch {
            throw NetworkSnapshotCodecFailure.corrupt
        }
        guard wire.schema == schema else { throw NetworkSnapshotCodecFailure.unsupportedSchema }
        guard wire.version == version else { throw NetworkSnapshotCodecFailure.unsupportedVersion(wire.version) }

        let sessionID = CaptureSessionID(rawValue: wire.session)
        guard let appliedSequence = UInt64(wire.appliedSequence) else {
            throw NetworkSnapshotCodecFailure.invalidValue(field: "appliedSequence")
        }
        guard let asOf = parse(wire.asOf) else {
            throw NetworkSnapshotCodecFailure.invalidValue(field: "asOf")
        }
        guard let monotonic = UInt64(wire.monotonicAsOf) else {
            throw NetworkSnapshotCodecFailure.invalidValue(field: "monotonicAsOf")
        }

        return NetworkSnapshot(
            sessionID: sessionID,
            appliedSequence: appliedSequence,
            asOf: asOf,
            monotonicAsOf: MonotonicInstant(nanoseconds: monotonic),
            collectionState: try untagState(wire.collectionState),
            coverage: NetworkCoverage(
                identity: try untagLevel(wire.coverage.identity, field: "coverage.identity"),
                bytes: try untagLevel(wire.coverage.bytes, field: "coverage.bytes"),
                targets: try untagLevel(wire.coverage.targets, field: "coverage.targets"),
                protocols: try untagLevel(wire.coverage.protocols, field: "coverage.protocols"),
                lostEventCount: try uint64(wire.coverage.lostEventCount, field: "coverage.lostEventCount"),
                counterResetCount: try uint64(wire.coverage.counterResetCount, field: "coverage.counterResetCount"),
                truncatedCollections: wire.coverage.truncatedCollections,
                hasLiveSample: wire.coverage.hasLiveSample
            ),
            capabilities: NetworkCapabilities(
                observe: wire.capabilities.observe,
                blockNewConnections: wire.capabilities.blockNewConnections,
                terminateExistingConnections: wire.capabilities.terminateExistingConnections,
                ask: wire.capabilities.ask,
                allowlist: wire.capabilities.allowlist,
                history: wire.capabilities.history,
                export: wire.capabilities.export,
                blockers: try wire.capabilities.blockers.map { raw in
                    guard let blocker = NetworkCapabilityBlocker(rawValue: raw) else {
                        throw NetworkSnapshotCodecFailure.invalidValue(field: "capabilities.blockers")
                    }
                    return blocker
                }
            ),
            interfaces: try wire.interfaces.mapValues { interface in
                guard let kind = NetworkInterfaceKind(rawValue: interface.kind) else {
                    throw NetworkSnapshotCodecFailure.invalidValue(field: "interfaces.kind")
                }
                guard let asOf = parse(interface.asOf), let monotonic = UInt64(interface.monotonicAsOf) else {
                    throw NetworkSnapshotCodecFailure.invalidValue(field: "interfaces.time")
                }
                return InterfaceCounters(
                    name: interface.name,
                    kind: kind,
                    counters: try uncounters(interface.counters),
                    asOf: asOf,
                    monotonicAsOf: MonotonicInstant(nanoseconds: monotonic),
                    sessionTotal: try interface.sessionTotal.map(unsessionTotal)
                )
            },
            apps: try wire.apps.mapValues { app in
                AppNetworkCounters(
                    identity: AppIdentity(
                        bundleID: app.identity.bundleID,
                        signingIdentity: app.identity.signingIdentity,
                        teamID: app.identity.teamID,
                        version: app.identity.version,
                        displayName: app.identity.displayName
                    ),
                    counters: try uncounters(app.counters),
                    activeConnectionCount: try app.activeConnectionCount.map { try uint64($0, field: "apps.activeConnectionCount") },
                    rate: try app.rate.map(unrate),
                    lastActivity: try app.lastActivity.map { value in
                        guard let parsed = parse(value) else {
                            throw NetworkSnapshotCodecFailure.invalidValue(field: "apps.lastActivity")
                        }
                        return parsed
                    }
                )
            },
            interfaceRates: try wire.interfaceRates.mapValues(unrate)
        )
    }

    // MARK: - Scalar helpers

    private static func counters(_ counters: NetworkByteCounters) -> CountersWire {
        CountersWire(
            upload: counters.bytes.upload.map(String.init),
            download: counters.bytes.download.map(String.init),
            semantics: counters.semantics.rawValue,
            epoch: String(counters.epoch.rawValue)
        )
    }

    private static func sessionTotal(_ total: SessionByteTotal) -> SessionTotalWire {
        SessionTotalWire(
            upload: total.bytes.upload.map(String.init),
            download: total.bytes.download.map(String.init),
            since: format(total.since),
            sinceMonotonicAsOf: String(total.sinceMonotonic.nanoseconds),
            breakReason: total.breakReason
        )
    }

    private static func unsessionTotal(_ wire: SessionTotalWire) throws -> SessionByteTotal {
        guard let since = parse(wire.since),
              let sinceMonotonic = UInt64(wire.sinceMonotonicAsOf) else {
            throw NetworkSnapshotCodecFailure.invalidValue(field: "interfaces.sessionTotal.since")
        }
        return SessionByteTotal(
            bytes: DirectionalBytes(
                upload: try wire.upload.map { try uint64($0, field: "interfaces.sessionTotal.upload") },
                download: try wire.download.map { try uint64($0, field: "interfaces.sessionTotal.download") }
            ),
            since: since,
            sinceMonotonic: MonotonicInstant(nanoseconds: sinceMonotonic),
            breakReason: wire.breakReason
        )
    }

    private static func uncounters(_ wire: CountersWire) throws -> NetworkByteCounters {
        guard let semantics = CounterSemantics(rawValue: wire.semantics) else {
            throw NetworkSnapshotCodecFailure.invalidValue(field: "counters.semantics")
        }
        return NetworkByteCounters(
            bytes: DirectionalBytes(
                upload: try wire.upload.map { try uint64($0, field: "counters.upload") },
                download: try wire.download.map { try uint64($0, field: "counters.download") }
            ),
            semantics: semantics,
            epoch: CounterEpoch(rawValue: try uint64(wire.epoch, field: "counters.epoch"))
        )
    }

    private static func rate(_ rate: NetworkRate) -> RateWire {
        RateWire(
            uploadBytesPerSecond: rate.uploadBytesPerSecond,
            downloadBytesPerSecond: rate.downloadBytesPerSecond,
            asOf: format(rate.asOf),
            windowNanoseconds: String(rate.window.nanosecondsClamped)
        )
    }

    private static func unrate(_ wire: RateWire) throws -> NetworkRate {
        guard let asOf = parse(wire.asOf), let window = Int64(wire.windowNanoseconds) else {
            throw NetworkSnapshotCodecFailure.invalidValue(field: "rate")
        }
        // Strict on purpose: nothing in the aggregator may emit a rate without
        // elapsed time any more, so a zero window here means a regression
        // rather than an old payload, and it must fail loudly.
        guard window > 0 else {
            throw NetworkSnapshotCodecFailure.invalidValue(field: "rate.windowNanoseconds")
        }
        for value in [wire.uploadBytesPerSecond, wire.downloadBytesPerSecond] {
            if let value, !value.isFinite || value < 0 {
                throw NetworkSnapshotCodecFailure.invalidValue(field: "rate.bytesPerSecond")
            }
        }
        return NetworkRate(
            uploadBytesPerSecond: wire.uploadBytesPerSecond,
            downloadBytesPerSecond: wire.downloadBytesPerSecond,
            asOf: asOf,
            window: .nanoseconds(window)
        )
    }

    private static func tag(_ state: NetworkCollectionState) -> Tagged {
        switch state {
        case .stopped: return Tagged(type: "stopped", reason: nil, since: nil)
        case .starting: return Tagged(type: "starting", reason: nil, since: nil)
        case .waitingAuthorization: return Tagged(type: "waitingAuthorization", reason: nil, since: nil)
        case .denied: return Tagged(type: "denied", reason: nil, since: nil)
        case .active: return Tagged(type: "active", reason: nil, since: nil)
        case let .partial(reason): return Tagged(type: "partial", reason: reason, since: nil)
        case let .disconnected(since): return Tagged(type: "disconnected", reason: nil, since: format(since))
        }
    }

    private static func tag(_ level: CoverageLevel) -> Tagged {
        switch level {
        case .full: return Tagged(type: "full", reason: nil, since: nil)
        case let .partial(reason): return Tagged(type: "partial", reason: reason, since: nil)
        case let .unavailable(reason): return Tagged(type: "unavailable", reason: reason, since: nil)
        }
    }

    private static func untagState(_ tagged: Tagged) throws -> NetworkCollectionState {
        switch tagged.type {
        case "stopped": return .stopped
        case "starting": return .starting
        case "waitingAuthorization": return .waitingAuthorization
        case "denied": return .denied
        case "active": return .active
        case "partial":
            guard let reason = tagged.reason else {
                throw NetworkSnapshotCodecFailure.invalidValue(field: "collectionState.reason")
            }
            return .partial(reason: reason)
        case "disconnected":
            guard let since = tagged.since.flatMap(parse) else {
                throw NetworkSnapshotCodecFailure.invalidValue(field: "collectionState.since")
            }
            return .disconnected(since: since)
        default:
            throw NetworkSnapshotCodecFailure.invalidValue(field: "collectionState.type")
        }
    }

    private static func untagLevel(_ tagged: Tagged, field: String) throws -> CoverageLevel {
        switch tagged.type {
        case "full": return .full
        case "partial":
            guard let reason = tagged.reason else {
                throw NetworkSnapshotCodecFailure.invalidValue(field: field)
            }
            return .partial(reason: reason)
        case "unavailable":
            guard let reason = tagged.reason else {
                throw NetworkSnapshotCodecFailure.invalidValue(field: field)
            }
            return .unavailable(reason: reason)
        default:
            throw NetworkSnapshotCodecFailure.invalidValue(field: field)
        }
    }

    private static func uint64(_ raw: String, field: String) throws -> UInt64 {
        guard let value = UInt64(raw) else {
            throw NetworkSnapshotCodecFailure.invalidValue(field: field)
        }
        return value
    }

    // A fresh formatter per call: ISO8601DateFormatter is not Sendable, and
    // per-call creation is negligible at snapshot rates.
    private static var formatter: ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }

    private static func format(_ date: Date) -> String {
        formatter.string(from: date)
    }

    private static func parse(_ raw: String) -> Date? {
        formatter.date(from: raw)
    }
}

private extension Duration {
    /// Nanoseconds clamped to Int64 for wire transport; only used for display
    /// of rate windows, never for math.
    var nanosecondsClamped: Int64 {
        let components = components
        let seconds = components.seconds.multipliedReportingOverflow(by: 1_000_000_000)
        let attosToNanos = components.attoseconds / 1_000_000_000
        let sum = seconds.partialValue.addingReportingOverflow(attosToNanos)
        if seconds.overflow || sum.overflow { return .max }
        return sum.partialValue
    }
}
