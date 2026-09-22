#if USAGE_BUTLER_FIXTURES
import Foundation
import UsageButlerDomain

/// Deterministic network snapshot for DEBUG fixture/preview runs. It mirrors
/// the production interface-only shape: physical + tunnel interfaces, honest
/// capability blockers and interface-scoped coverage — never invented per-app
/// numbers.
public enum NetworkFixtureCatalog {
    /// The network environment the fixture pretends to run in. Kept explicit
    /// rather than borrowed from the host, so "自动" resolution and the friendly
    /// name are deterministic in UI acceptance on any machine.
    public static let systemPath = NetworkSystemPath(
        primaryInterfaceName: "en0",
        friendlyNames: ["en0": "Wi-Fi"],
        isReadable: true
    )

    public static func snapshot(
        now: Date = Date(),
        collecting: Bool = true,
        zeroRates: Bool = false
    ) -> NetworkSnapshot {
        let monotonic = MonotonicInstant(nanoseconds: DispatchTime.now().uptimeNanoseconds)
        let epoch = CounterEpoch(rawValue: 1_700_000_000)

        func interface(
            _ name: String,
            _ kind: NetworkInterfaceKind,
            _ upload: UInt64,
            _ download: UInt64,
            sessionUpload: UInt64,
            sessionDownload: UInt64
        ) -> InterfaceCounters {
            InterfaceCounters(
                name: name,
                kind: kind,
                counters: NetworkByteCounters(
                    bytes: DirectionalBytes(upload: upload, download: download),
                    semantics: .cumulativeSinceEpoch,
                    epoch: epoch
                ),
                asOf: now,
                monotonicAsOf: monotonic,
                sessionTotal: SessionByteTotal(
                    bytes: DirectionalBytes(upload: zeroRates ? 0 : sessionUpload, download: zeroRates ? 0 : sessionDownload),
                    since: now.addingTimeInterval(-240),
                    sinceMonotonic: MonotonicInstant(
                        nanoseconds: max(0, monotonic.nanoseconds - 240_000_000_000)
                    )
                )
            )
        }

        let interfaces: [String: InterfaceCounters] = collecting
            ? [
                "en0": interface("en0", .physical, 8_200_000_000, 41_500_000_000,
                                 sessionUpload: 41_200_000, sessionDownload: 386_400_000),
                "utun5": interface("utun5", .tunnel, 1_260_000_000, 3_410_000_000,
                                   sessionUpload: 5_100_000, sessionDownload: 22_800_000)
            ]
            : [:]

        let rates: [String: NetworkRate] = collecting
            ? [
                "en0": NetworkRate(
                    uploadBytesPerSecond: zeroRates ? 0 : 29_000,
                    downloadBytesPerSecond: zeroRates ? 0 : 2_900_000,
                    asOf: now,
                    window: .seconds(1)
                )
            ]
            : [:]

        let history: [NetworkRateSample] = collecting ? (0..<240).map { i in
            let t = now.addingTimeInterval(Double(i - 239))
            let gap = !zeroRates && (95...108).contains(i)
            return NetworkRateSample(captureSessionID: .init(rawValue: "fixture-network"), counterEpoch: epoch,
                sampledAt: t, sampledMonotonic: .init(nanoseconds: monotonic.nanoseconds - UInt64(239 - i) * 1_000_000_000),
                uploadBytesPerSecond: gap ? nil : (zeroRates ? 0 : Double(10 + i % 20) * 1_000),
                downloadBytesPerSecond: gap ? nil : (zeroRates ? 0 : Double(10 + i % 20) * 100_000),
                interfaceName: "en0", samplingInterval: 1)
        } : []

        return NetworkSnapshot(
            sessionID: CaptureSessionID(rawValue: "fixture-network"),
            appliedSequence: collecting ? 2 : 0,
            asOf: now,
            monotonicAsOf: monotonic,
            collectionState: collecting ? .active : .stopped,
            coverage: NetworkCoverage(
                identity: .unavailable(reason: "per-app-observation-unavailable"),
                bytes: collecting
                    ? .partial(reason: "interfaces-only")
                    : .unavailable(reason: "collection-stopped"),
                targets: .unavailable(reason: "per-app-observation-unavailable"),
                protocols: .unavailable(reason: "per-app-observation-unavailable"),
                lostEventCount: 0,
                counterResetCount: 0,
                truncatedCollections: [],
                hasLiveSample: collecting
            ),
            capabilities: NetworkCapabilities(
                observe: true,
                blockNewConnections: false,
                terminateExistingConnections: false,
                ask: false,
                allowlist: false,
                history: false,
                export: false,
                blockers: [.signingOrProfileMissing, .notYetImplemented]
            ),
            interfaces: interfaces,
            apps: [:],
            interfaceRates: rates,
            rateHistory: ["en0": history],
            interfaceInventory: .init(envelope: .init(sessionID: .init(rawValue: "fixture-network"),
                sequence: collecting ? 2 : 0, occurredAt: now, monotonicOccurredAt: monotonic),
                succeeded: collecting, names: Set(interfaces.keys))
        )
    }
}
#endif
