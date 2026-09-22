import Foundation
import UsageButlerDomain

/// Declares which coverage dimensions a source shape can honestly provide.
/// The aggregator only knows what it observed; a source that never emits flow
/// events would otherwise look "full" on identity/targets/protocols. The
/// profile overrides those dimensions while preserving the aggregator's
/// integrity counters (lost events, counter resets, truncation).
public struct NetworkCoverageProfile: Equatable, Sendable {
    public let identity: CoverageLevel
    public let bytes: CoverageLevel
    public let targets: CoverageLevel
    public let protocols: CoverageLevel

    public init(identity: CoverageLevel, bytes: CoverageLevel, targets: CoverageLevel, protocols: CoverageLevel) {
        self.identity = identity
        self.bytes = bytes
        self.targets = targets
        self.protocols = protocols
    }

    /// getifaddrs interface counters: bytes exist but are interface-scoped;
    /// nothing per-app, per-target or per-protocol is observed at all.
    public static let interfaceCountersOnly = NetworkCoverageProfile(
        identity: .unavailable(reason: "per-app-observation-unavailable"),
        bytes: .partial(reason: "interfaces-only"),
        targets: .unavailable(reason: "per-app-observation-unavailable"),
        protocols: .unavailable(reason: "per-app-observation-unavailable")
    )

    /// Nothing is being collected; every dimension is unavailable.
    public static let stopped = NetworkCoverageProfile(
        identity: .unavailable(reason: "collection-stopped"),
        bytes: .unavailable(reason: "collection-stopped"),
        targets: .unavailable(reason: "collection-stopped"),
        protocols: .unavailable(reason: "collection-stopped")
    )

    /// Merges the profile into an aggregator-built coverage. Byte coverage
    /// keeps the worse of the two levels: an aggregator-side integrity
    /// problem (counter reset, lost events) must survive the profile.
    public func applying(to coverage: NetworkCoverage) -> NetworkCoverage {
        NetworkCoverage(
            identity: identity,
            bytes: CoverageLevel.worse(of: coverage.bytes, bytes),
            targets: targets,
            protocols: protocols,
            lostEventCount: coverage.lostEventCount,
            counterResetCount: coverage.counterResetCount,
            truncatedCollections: coverage.truncatedCollections,
            hasLiveSample: coverage.hasLiveSample
        )
    }

    /// Builds a full idle coverage for a stopped snapshot.
    public func idleCoverage() -> NetworkCoverage {
        NetworkCoverage(
            identity: identity,
            bytes: bytes,
            targets: targets,
            protocols: protocols,
            lostEventCount: 0,
            counterResetCount: 0,
            truncatedCollections: [],
            hasLiveSample: false
        )
    }
}

extension CoverageLevel {
    /// Orders full < partial < unavailable and returns the worse level. When
    /// both are partial, the aggregator's reason is more specific and wins.
    static func worse(of lhs: CoverageLevel, _ rhs: CoverageLevel) -> CoverageLevel {
        func severity(_ level: CoverageLevel) -> Int {
            switch level {
            case .full: 0
            case .partial: 1
            case .unavailable: 2
            }
        }
        return severity(lhs) >= severity(rhs) ? lhs : rhs
    }
}

extension NetworkSnapshot {
    /// Returns a copy whose coverage levels are overridden by the profile.
    /// Integrity counters are never touched.
    public func applyingCoverageProfile(_ profile: NetworkCoverageProfile) -> NetworkSnapshot {
        NetworkSnapshot(
            sessionID: sessionID,
            appliedSequence: appliedSequence,
            asOf: asOf,
            monotonicAsOf: monotonicAsOf,
            collectionState: collectionState,
            coverage: profile.applying(to: coverage),
            capabilities: capabilities,
            interfaces: interfaces,
            apps: apps,
            interfaceRates: interfaceRates,
            rateHistory: rateHistory,
            interfaceInventory: interfaceInventory
        )
    }
}
