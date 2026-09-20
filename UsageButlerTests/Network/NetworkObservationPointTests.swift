import XCTest
@testable import UsageButlerCore
import UsageButlerDomain

/// NET-02 / PRD §13.4.1: the page measures the network the system says is
/// carrying traffic, and says so when it cannot. Before this rule existed the
/// default came from sort order, which silently presented `en0` as "the
/// network" on machines where it is a Thunderbolt port or nothing at all.
final class NetworkObservationPointTests: XCTestCase {
    private let observed: Set<String> = ["en0", "en6", "utun5", "lo0", "bridge0"]

    private func path(primary: String?, names: [String: String] = [:]) -> NetworkSystemPath {
        NetworkSystemPath(primaryInterfaceName: primary, friendlyNames: names, isReadable: true)
    }

    private func resolve(
        path: NetworkSystemPath,
        manual: String? = nil,
        observed: Set<String>? = nil
    ) -> NetworkObservationResolution {
        NetworkObservationPointResolver.resolve(
            path: path,
            manualSelection: manual,
            observedInterfaces: observed ?? self.observed
        )
    }

    // MARK: - Automatic

    func testAutomaticFollowsSystemPrimaryNotFirstInterface() {
        XCTAssertEqual(
            resolve(path: path(primary: "en6")),
            .resolved(NetworkObservationPoint(
                interfaceName: "en6", displayName: nil, resolution: .systemConfirmed
            ))
        )
    }

    func testAutomaticNeverFallsBackToASortedInterfaceWhenPrimaryUnsampled() {
        // System says en0, counters only arrived for utun5. Measuring utun5
        // instead would redraw a tunnel's double-counted bytes as the network.
        XCTAssertEqual(
            resolve(path: path(primary: "en0"), observed: ["utun5"]),
            .notSampled(interfaceName: "en0")
        )
    }

    func testFriendlyNameComesOnlyFromTheSystem() {
        guard case let .resolved(point) = resolve(
            path: path(primary: "en0", names: ["en0": "Wi-Fi", "en6": "Thunderbolt 1 Ethernet"])
        ) else {
            return XCTFail("expected a resolved point")
        }
        XCTAssertEqual(point.displayName, "Wi-Fi")

        guard case let .resolved(unnamed) = resolve(path: path(primary: "en0")) else {
            return XCTFail("expected a resolved point")
        }
        XCTAssertNil(unnamed.displayName, "a BSD name must not be dressed up as a friendly label")
    }

    func testUnreadableStateIsNotReportedAsDisconnected() {
        XCTAssertEqual(resolve(path: .unreadable), .systemStateUnreadable)
    }

    func testNoActiveNetworkIsDistinctFromUnreadableState() {
        XCTAssertEqual(resolve(path: .notConnected), .noActiveNetwork)
    }

    // MARK: - Manual

    func testManualSelectionWinsOverSystemPrimary() {
        XCTAssertEqual(
            resolve(path: path(primary: "en0"), manual: "utun5"),
            .resolved(NetworkObservationPoint(
                interfaceName: "utun5", displayName: nil, resolution: .manuallySelected
            ))
        )
    }

    func testVanishedManualSelectionStaysSelectedAndUnavailable() {
        XCTAssertEqual(
            resolve(path: path(primary: "en0"), manual: "en3"),
            .manualUnavailable(interfaceName: "en3")
        )
    }

    func testUnresolvedOutcomeExposesNoInterfaceToMeasure() {
        for outcome in [
            NetworkObservationResolution.manualUnavailable(interfaceName: "en3"),
            .notSampled(interfaceName: "en0"),
            .noActiveNetwork,
            .systemStateUnreadable,
        ] {
            XCTAssertNil(NetworkObservationPointResolver.measurableInterface(in: outcome), "\(outcome)")
        }
        XCTAssertNotNil(
            NetworkObservationPointResolver.measurableInterface(
                in: .resolved(NetworkObservationPoint(
                    interfaceName: "en6", displayName: nil, resolution: .systemConfirmed
                ))
            )
        )
    }

    // MARK: - Advanced list

    func testAdvancedGroupsAreOrderedAndNeverAttributeTunnels() {
        let interfaces = [
            "utun5": counters("utun5", .tunnel),
            "en0": counters("en0", .physical),
            "lo0": counters("lo0", .loopback),
            "utun3": counters("utun3", .tunnel),
            "bridge0": counters("bridge0", .bridge),
            "ap1": counters("ap1", .other),
        ]
        let groups = NetworkObservationPointResolver.advancedGroups(interfaces: interfaces)
        XCTAssertEqual(groups.map(\.kind), [.physical, .bridge, .tunnel, .loopback, .other])
        XCTAssertEqual(groups[0].interfaces, ["en0"])
        XCTAssertEqual(groups[2].interfaces, ["utun3", "utun5"], "tunnels stay tunnels, not proxy apps")
    }

    func testAdvancedGroupsOmitEmptyKinds() {
        let groups = NetworkObservationPointResolver.advancedGroups(
            interfaces: ["en0": counters("en0", .physical)]
        )
        XCTAssertEqual(groups.count, 1)
    }

    private func counters(_ name: String, _ kind: NetworkInterfaceKind) -> InterfaceCounters {
        InterfaceCounters(
            name: name,
            kind: kind,
            counters: NetworkByteCounters(
                bytes: DirectionalBytes(upload: nil, download: nil),
                semantics: .cumulativeSinceEpoch,
                epoch: CounterEpoch(rawValue: 1)
            ),
            asOf: Date(timeIntervalSince1970: 1_800_000_000),
            monotonicAsOf: MonotonicInstant(nanoseconds: 1)
        )
    }
}
