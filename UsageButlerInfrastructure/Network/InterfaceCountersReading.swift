import Foundation
import UsageButlerDomain

/// One raw per-interface byte reading from the system. Direction is from the
/// host's perspective: `uploadBytes` is transmitted by the interface,
/// `downloadBytes` is received by it.
public struct RawInterfaceCounters: Equatable, Sendable {
    public let name: String
    public let kind: NetworkInterfaceKind
    public let uploadBytes: UInt64
    public let downloadBytes: UInt64

    public init(
        name: String,
        kind: NetworkInterfaceKind,
        uploadBytes: UInt64,
        downloadBytes: UInt64
    ) {
        self.name = name
        self.kind = kind
        self.uploadBytes = uploadBytes
        self.downloadBytes = downloadBytes
    }
}

/// Synchronous point-in-time read of per-interface cumulative counters.
/// Implementations must be cheap enough for a 1 Hz poll; getifaddrs is a
/// pure userspace read of kernel-shared memory, so it qualifies.
public protocol InterfaceCountersReading: Sendable {
    func read() -> [RawInterfaceCounters]
}
