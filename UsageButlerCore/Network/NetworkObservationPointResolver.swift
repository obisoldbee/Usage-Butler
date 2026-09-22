import Foundation
import UsageButlerDomain

/// Chooses which network the page measures. Kept pure so the "never guess from
/// a name prefix" rule is assertable rather than a comment.
public enum NetworkObservationPointResolver {
    /// A manual selection wins even when the interface has vanished, because
    /// quietly substituting another one would redraw the same trend under a
    /// different measurement point and look like continuous history.
    ///
    /// Automatic mode trusts only a system-confirmed primary interface. An
    /// `en0` that merely sorts first, or a physical-looking name chosen by
    /// dictionary order, is not evidence of being the network in use.
    public static func resolve(
        path: NetworkSystemPath,
        manualSelection: String?,
        isObserving: Bool = true,
        presence: (String) -> NetworkInterfacePresence
    ) -> NetworkObservationResolution {
        guard isObserving else { return .notObserved(interfaceName: manualSelection ?? path.primaryInterfaceName) }
        if let manual = manualSelection {
            switch presence(manual) {
            case .missing: return .manualUnavailable(interfaceName: manual)
            case .unknown: return .presenceUnknown(interfaceName: manual)
            case .notObserved: return .notObserved(interfaceName: manual)
            case .present: break
            }
            return .resolved(NetworkObservationPoint(
                interfaceName: manual,
                displayName: path.friendlyNames[manual],
                resolution: .manuallySelected
            ))
        }
        guard path.isReadable else { return .systemStateUnreadable }
        guard let primary = path.primaryInterfaceName else { return .noActiveNetwork }
        switch presence(primary) {
        case .unknown: return .presenceUnknown(interfaceName: primary)
        case .notObserved: return .notObserved(interfaceName: primary)
        case .present: break
        case .missing:
            // The system says a network is connected but no counters for it
            // have arrived. Claiming another interface instead would be the
            // silent caliber switch this rule exists to prevent.
            return .notSampled(interfaceName: primary)
        }
        return .resolved(NetworkObservationPoint(
            interfaceName: primary,
            displayName: path.friendlyNames[primary],
            resolution: .systemConfirmed
        ))
    }

    /// The only interface a page may measure for this outcome. `nil` means
    /// every number must read 未知 — there is no "best available" fallback,
    /// because substituting one interface for another would silently change
    /// what the history on screen had been measuring.
    public static func measurableInterface(
        in resolution: NetworkObservationResolution
    ) -> String? {
        guard case let .resolved(point) = resolution else { return nil }
        return point.interfaceName
    }

    /// Interfaces offered in the advanced list, grouped by what the source
    /// could actually evidence. An unattributed `utun` stays "tunnel"; naming
    /// it after a proxy application would be an invention.
    public static func advancedGroups(
        interfaces: [String: InterfaceCounters]
    ) -> [NetworkInterfaceGroup] {
        let buckets = Dictionary(grouping: interfaces.values, by: \.kind)
        return NetworkInterfaceGroup.orderedCases.compactMap { kind in
            let members = (buckets[kind] ?? []).sorted { $0.name < $1.name }
            guard !members.isEmpty else { return nil }
            return NetworkInterfaceGroup(kind: kind, interfaces: members.map(\.name))
        }
    }
}

public struct NetworkInterfaceGroup: Identifiable, Equatable, Sendable {
    public let kind: NetworkInterfaceKind
    public let interfaces: [String]
    public var id: String { String(describing: kind) }

    public init(kind: NetworkInterfaceKind, interfaces: [String]) {
        self.kind = kind
        self.interfaces = interfaces
    }

    /// Display order: real networks first, then tunnels, then local-only and
    /// anything the source could not classify.
    public static let orderedCases: [NetworkInterfaceKind] = [
        .physical, .bridge, .tunnel, .loopback, .other
    ]
}
