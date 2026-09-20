import Darwin
import Foundation
import UsageButlerDomain

/// Reads cumulative per-interface byte counters from getifaddrs(3) AF_LINK
/// entries (`if_data`). On macOS these byte counters are 32-bit and wrap on
/// busy interfaces; a wrap appears as a same-epoch decrease and is surfaced
/// by the aggregator as a counter reset, never as negative traffic.
public struct GetifaddrsInterfaceCountersReader: InterfaceCountersReading {
    public init() {}

    public func read() -> [RawInterfaceCounters] {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return [] }
        defer { freeifaddrs(first) }

        var latest: [String: RawInterfaceCounters] = [:]
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let entry = cursor {
            defer { cursor = entry.pointee.ifa_next }
            guard let address = entry.pointee.ifa_addr,
                  Int32(address.pointee.sa_family) == AF_LINK,
                  let data = entry.pointee.ifa_data
            else { continue }
            let counters = data.assumingMemoryBound(to: if_data.self).pointee
            let name = String(cString: entry.pointee.ifa_name)
            latest[name] = RawInterfaceCounters(
                name: name,
                kind: Self.classify(name: name),
                uploadBytes: UInt64(counters.ifi_obytes),
                downloadBytes: UInt64(counters.ifi_ibytes)
            )
        }
        return latest.sorted { $0.key < $1.key }.map(\.value)
    }

    /// Name-prefix classification. macOS exposes no portable "is physical"
    /// flag on if_data, so kind is a best-effort label and never feeds byte
    /// math; `other` is the honest bucket for unrecognized names.
    static func classify(name: String) -> NetworkInterfaceKind {
        if name.hasPrefix("lo") { return .loopback }
        if name.hasPrefix("utun") || name.hasPrefix("ipsec") || name.hasPrefix("gif")
            || name.hasPrefix("stf") || name.hasPrefix("ppp") {
            return .tunnel
        }
        if name.hasPrefix("bridge") { return .bridge }
        if name.hasPrefix("en") { return .physical }
        return .other
    }
}
