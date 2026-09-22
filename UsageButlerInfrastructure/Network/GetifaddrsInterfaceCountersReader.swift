import Darwin
import Foundation
import UsageButlerDomain

/// Reads the public Darwin routing sysctl's 64-bit interface counters.
/// The type name is retained for source compatibility; no 32-bit fallback is
/// mixed into the same capture epoch. Failed reads are empty, never zero.
public struct GetifaddrsInterfaceCountersReader: InterfaceCountersReading {
    public init() {}

    public func read() -> [RawInterfaceCounters] {
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0]
        var count = 0
        guard sysctl(&mib, u_int(mib.count), nil, &count, nil, 0) == 0,
              count > 0, count <= 4 * 1024 * 1024 else { return [] }
        // Interfaces may appear between the size and data calls; retry this
        // bounded local read on the next sampling tick, never parse a prefix.
        var data = Data(count: count)
        let status = data.withUnsafeMutableBytes { bytes in
            sysctl(&mib, u_int(mib.count), bytes.baseAddress, &count, nil, 0)
        }
        guard status == 0, count <= data.count else { return [] }
        data.count = count
        return Self.decode(data)
    }

    static func decode(_ data: Data) -> [RawInterfaceCounters] {
        data.withUnsafeBytes { bytes in
            var offset = 0
            var result: [RawInterfaceCounters] = []
            while offset < bytes.count {
                guard bytes.count - offset >= 4 else { return [] }
                let length = Int(bytes.loadUnaligned(fromByteOffset: offset, as: UInt16.self))
                guard length >= 4, length <= bytes.count - offset else { return [] }
                let type = bytes[offset + 3]
                if type == RTM_IFINFO2 {
                    guard length >= MemoryLayout<if_msghdr2>.size else { return [] }
                    let header = bytes.loadUnaligned(fromByteOffset: offset, as: if_msghdr2.self)
                    var nameBuffer = [CChar](repeating: 0, count: Int(IFNAMSIZ))
                    if if_indextoname(UInt32(header.ifm_index), &nameBuffer) != nil {
                        let name = String(cString: nameBuffer)
                        result.append(.init(name: name, kind: classify(name: name),
                                            uploadBytes: header.ifm_data.ifi_obytes,
                                            downloadBytes: header.ifm_data.ifi_ibytes))
                    }
                }
                offset += length
            }
            return result.sorted { $0.name < $1.name }
        }
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
