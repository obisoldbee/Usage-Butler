import Foundation

/// Which network the interface numbers on screen actually describe, and how far
/// the system confirmed that choice.
public struct NetworkObservationPoint: Equatable, Sendable {
    /// How the interface was identified. Never inferred from a name prefix.
    public enum Resolution: String, Equatable, Sendable {
        /// The system's own connected-network state named this interface.
        case systemConfirmed
        /// The user picked the interface explicitly.
        case manuallySelected
    }

    public let interfaceName: String
    /// System-supplied friendly name, e.g. `Wi-Fi`. Nil when the system does
    /// not provide one; a BSD name is never dressed up as a friendly label.
    public let displayName: String?
    public let resolution: Resolution

    public init(interfaceName: String, displayName: String?, resolution: Resolution) {
        self.interfaceName = interfaceName
        self.displayName = displayName
        self.resolution = resolution
    }
}

/// The system's view of which network is carrying traffic, plus whatever
/// friendly names it publishes for interfaces.
public struct NetworkSystemPath: Equatable, Sendable {
    public let primaryInterfaceName: String?
    /// BSD name to system display name. Only ever filled from the system.
    public let friendlyNames: [String: String]
    /// False when the state could not be read at all. "Nothing is connected" is
    /// a different answer and must not be reported the same way.
    public let isReadable: Bool

    public init(primaryInterfaceName: String?, friendlyNames: [String: String] = [:], isReadable: Bool = true) {
        self.primaryInterfaceName = primaryInterfaceName
        self.friendlyNames = friendlyNames
        self.isReadable = isReadable
    }

    /// Nothing could be read. Distinct from "read successfully and the answer
    /// is that no network is connected".
    public static let unreadable = NetworkSystemPath(primaryInterfaceName: nil, friendlyNames: [:], isReadable: false)
    /// Readable state with no active network.
    public static let notConnected = NetworkSystemPath(primaryInterfaceName: nil, friendlyNames: [:], isReadable: true)
}

/// Outcome of choosing what to observe. Every case other than `.resolved`
/// leaves the page with no interface to measure, and each says why in its own
/// words — collapsing them would hide whether the user should connect to a
/// network, wait for samples, or change the selection back to automatic.
public enum NetworkObservationResolution: Equatable, Sendable {
    case resolved(NetworkObservationPoint)
    /// The user's sticky choice has vanished. The page keeps showing the
    /// choice as unavailable rather than silently switching measurement to a
    /// different interface.
    case manualUnavailable(interfaceName: String)
    case presenceUnknown(interfaceName: String)
    case notObserved(interfaceName: String?)
    /// The operating system's network state could not be read.
    case systemStateUnreadable
    /// The system reports no active network.
    case noActiveNetwork
    /// The system reports an active interface that no sample has arrived for.
    case notSampled(interfaceName: String)
}
