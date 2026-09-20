import Foundation
import SystemConfiguration
import UsageButlerCore
import UsageButlerDomain

/// Reads which network the system itself considers active, plus the friendly
/// interface names it publishes.
///
/// The point of going through SystemConfiguration instead of classifying BSD
/// names is that a name is not evidence: `en0` may be Wi-Fi, may be a
/// Thunderbolt adapter, and `utun3` may belong to any of several tunnels. The
/// system's connected-network state is the only answer that can be shown as a
/// confirmed name.
///
/// The dynamic-store handle is long-lived rather than recreated per read: this
/// runs on every network publish, and a menu-bar app should not be opening a
/// new connection to the configuration daemon several times a minute.
public final class SystemConfigurationNetworkPathReader: NetworkPathProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var store: SCDynamicStore?
    private var cachedFriendlyNames: [String: String]?

    public init() {}

    public func currentPath() -> NetworkSystemPath {
        lock.lock()
        defer { lock.unlock() }
        let store = self.store ?? SCDynamicStoreCreate(nil, "UsageButler.network" as CFString, nil, nil)
        guard let store else { return .unreadable }
        self.store = store

        var sawState = false
        for key in ["State:/Network/Global/IPv4", "State:/Network/Global/IPv6"] {
            guard let value = SCDynamicStoreCopyValue(store, key as CFString) as? [String: Any] else { continue }
            sawState = true
            // A readable state without a primary interface means "nothing is
            // connected", which is a real answer rather than a failure.
            let primary = (value["PrimaryInterface"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let primary, !primary.isEmpty {
                return NetworkSystemPath(
                    primaryInterfaceName: primary,
                    friendlyNames: friendlyNamesLocked(),
                    isReadable: true
                )
            }
        }
        return sawState
            ? NetworkSystemPath(primaryInterfaceName: nil, friendlyNames: friendlyNamesLocked(), isReadable: true)
            : .unreadable
    }

    /// Interface hardware names rarely change within a session, so the mapping
    /// is read once and reused.
    private func friendlyNamesLocked() -> [String: String] {
        if let cachedFriendlyNames { return cachedFriendlyNames }
        let names = Self.readFriendlyNames()
        cachedFriendlyNames = names
        return names
    }

    private static func readFriendlyNames() -> [String: String] {
        guard let all = SCNetworkInterfaceCopyAll() as? [SCNetworkInterface] else { return [:] }
        var result: [String: String] = [:]
        for interface in all {
            guard let bsd = SCNetworkInterfaceGetBSDName(interface) as String?,
                  let display = SCNetworkInterfaceGetLocalizedDisplayName(interface) as String?,
                  !display.isEmpty
            else { continue }
            result[bsd] = display
        }
        return result
    }
}
