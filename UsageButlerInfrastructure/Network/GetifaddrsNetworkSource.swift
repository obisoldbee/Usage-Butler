import Darwin
import Foundation
import UsageButlerCore
import UsageButlerDomain

/// Live observation source built on getifaddrs interface counters only.
/// Honest capability profile: interface byte observation works without
/// special entitlements, but per-app attribution and every enforcement
/// action need the signed system extension this build does not ship (G-N0),
/// and history/export are not implemented yet — so those capabilities report
/// their real blockers instead of pretending.
public struct GetifaddrsNetworkSource: NetworkObservationSource {
    public static let defaultPollInterval: Duration = .seconds(1)

    /// What this build can honestly claim.
    public static let interfaceOnlyCapabilities = NetworkCapabilities(
        observe: true,
        blockNewConnections: false,
        terminateExistingConnections: false,
        ask: false,
        allowlist: false,
        history: false,
        export: false,
        blockers: [.signingOrProfileMissing, .notYetImplemented]
    )

    private let clock: any ClockPort
    private let reader: any InterfaceCountersReading
    private let sessionID: CaptureSessionID
    private let pollInterval: Duration
    private let epoch: CounterEpoch

    public init(
        clock: any ClockPort,
        reader: any InterfaceCountersReading,
        sessionID: CaptureSessionID,
        pollInterval: Duration = GetifaddrsNetworkSource.defaultPollInterval,
        epoch: CounterEpoch = CounterEpoch(rawValue: GetifaddrsNetworkSource.bootEpoch())
    ) {
        self.clock = clock
        self.reader = reader
        self.sessionID = sessionID
        self.pollInterval = pollInterval
        self.epoch = epoch
    }

    public func currentSessionID() async -> CaptureSessionID { sessionID }

    public func capabilities() async -> NetworkCapabilities {
        Self.interfaceOnlyCapabilities
    }

    public func events() -> AsyncStream<NetworkSourceEvent> {
        let clock = self.clock
        let reader = self.reader
        let sessionID = self.sessionID
        let intervalNanos = Self.nanoseconds(for: pollInterval)
        let epoch = self.epoch
        return AsyncStream { continuation in
            let task = Task {
                var sequence: UInt64 = 0
                func emit(_ payload: NetworkSourcePayload, at reading: ClockReading) {
                    sequence &+= 1
                    continuation.yield(NetworkSourceEvent(
                        envelope: NetworkEventEnvelope(
                            sessionID: sessionID,
                            sequence: sequence,
                            occurredAt: reading.wallTime,
                            monotonicOccurredAt: reading.monotonicTime
                        ),
                        payload: payload
                    ))
                }

                emit(.heartbeat(capabilities: Self.interfaceOnlyCapabilities), at: await clock.reading())
                while !Task.isCancelled {
                    let reading = await clock.reading()
                    for sample in reader.read() {
                        emit(
                            .interfaceCounters(InterfaceCounters(
                                name: sample.name,
                                kind: sample.kind,
                                counters: NetworkByteCounters(
                                    bytes: DirectionalBytes(
                                        upload: sample.uploadBytes,
                                        download: sample.downloadBytes
                                    ),
                                    semantics: .cumulativeSinceEpoch,
                                    epoch: epoch
                                ),
                                asOf: reading.wallTime,
                                monotonicAsOf: reading.monotonicTime,
                                samplingInterval: Double(intervalNanos) / 1e9
                            )),
                            at: reading
                        )
                    }
                    let deadline = MonotonicInstant(
                        nanoseconds: reading.monotonicTime.nanoseconds &+ intervalNanos
                    )
                    do {
                        try await clock.sleep(until: deadline)
                    } catch {
                        break
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Boot time in epoch seconds doubles as the counter epoch: getifaddrs
    /// counters are cumulative since boot, so a reboot (new boot time) starts
    /// a fresh epoch and is never merged with pre-reboot values. A failed
    /// sysctl falls back to epoch 0 for the whole session — counters still
    /// aggregate correctly within it, only reboot detection is lost.
    public static func bootEpoch() -> UInt64 {
        var bootTime = timeval()
        var size = MemoryLayout<timeval>.size
        guard sysctlbyname("kern.boottime", &bootTime, &size, nil, 0) == 0,
              bootTime.tv_sec > 0
        else { return 0 }
        return UInt64(bootTime.tv_sec)
    }

    static func nanoseconds(for duration: Duration) -> UInt64 {
        let components = duration.components
        let seconds = UInt64(clamping: components.seconds)
        let attoseconds = UInt64(clamping: components.attoseconds)
        return seconds &* 1_000_000_000 &+ attoseconds / 1_000_000_000
    }
}
