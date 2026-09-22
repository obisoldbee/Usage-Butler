import Darwin
import Foundation
import UsageButlerDomain

/// Reads the public Darwin interface MIB's 64-bit counters.
/// NET_RT_IFLIST2 uses a UInt64 struct but XNU's non-platform byte rounding
/// casts to UInt32. IFDATA_GENERAL preserves the full counter; verify the
/// actual reader against system readings, not only synthetic parser inputs.
/// The type name is retained for source compatibility; no 32-bit fallback is
/// mixed into the same capture epoch. Failed reads are explicit failures, never an empty success.
public struct GetifaddrsInterfaceCountersReader: InterfaceCountersReading {
    public init() {}

    public func read() -> Result<[RawInterfaceCounters], InterfaceCountersReadFailure> {
        var mib: [Int32] = [CTL_NET, PF_LINK, NETLINK_GENERIC, IFMIB_IFALLDATA, 0, IFDATA_GENERAL]
        var count = 0
        guard sysctl(&mib, u_int(mib.count), nil, &count, nil, 0) == 0 else { return .failure(.unavailable) }
        guard count >= 0, count <= 4 * 1024 * 1024 else { return .failure(.oversized) }
        if count == 0 { return .success([]) }
        // Interfaces may appear between the size and data calls; retry this
        // bounded local read on the next sampling tick, never parse a prefix.
        var data = Data(count: count)
        let status = data.withUnsafeMutableBytes { bytes in
            sysctl(&mib, u_int(mib.count), bytes.baseAddress, &count, nil, 0)
        }
        guard status == 0, count >= 0, count <= data.count else { return .failure(.unavailable) }
        data.count = count
        return Self.decode(data).map { rows in
            rows.map { row in
                let index = if_nametoindex(row.name)
                return RawInterfaceCounters(name: row.name, kind: row.kind,
                    uploadBytes: row.uploadBytes, downloadBytes: row.downloadBytes,
                    systemIdentity: index == 0 ? nil : "ifindex:\(index)")
            }
        }
    }

    static func decode(_ data: Data) -> Result<[RawInterfaceCounters], InterfaceCountersReadFailure> {
        data.withUnsafeBytes { bytes in
            let stride = MemoryLayout<ifmibdata>.stride
            guard bytes.count.isMultiple(of: stride) else { return .failure(.malformed) }
            var result: [RawInterfaceCounters] = []
            for offset in Swift.stride(from: 0, to: bytes.count, by: stride) {
                var record = bytes.loadUnaligned(fromByteOffset: offset, as: ifmibdata.self)
                let name = withUnsafeBytes(of: &record.ifmd_name) { nameBytes -> String? in
                    guard let end = nameBytes.firstIndex(of: 0), end > 0 else { return nil }
                    return String(bytes: nameBytes[..<end], encoding: .utf8)
                }
                // Detached interfaces may have an all-zero record. A missing
                // name is not a measured zero-byte interface.
                guard let name else {
                    let detached = withUnsafeBytes(of: &record) { $0.allSatisfy { $0 == 0 } }
                    if detached { continue }
                    return .failure(.malformed)
                }
                guard !result.contains(where: { $0.name == name }) else { return .failure(.malformed) }
                result.append(.init(name: name, kind: classify(name: name),
                                    uploadBytes: record.ifmd_data.ifi_obytes,
                                    downloadBytes: record.ifmd_data.ifi_ibytes))
            }
            return .success(result.sorted { $0.name < $1.name })
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
