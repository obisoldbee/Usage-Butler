import XCTest
@testable import UsageButlerUI
import UsageButlerCore
import UsageButlerDomain

/// The view model is where "查看网络" either keeps its promise or quietly
/// breaks it: the resolved interface is what every number on the page reads
/// from, so an unresolved state must leave all of them unknown.
@MainActor
final class NetworkObservationSelectionTests: XCTestCase {
    private let base = Date(timeIntervalSince1970: 1_800_000_000)

    private func makeModel() -> MenuPanelViewModel {
        MenuPanelViewModel(
            snapshot: Stage3AppProjection(
                providers: [],
                memory: Stage3MemoryProjection(
                    pressure: .unknown,
                    fields: [],
                    history: [],
                    capturedAt: base,
                    origin: .runtime
                )
            ),
            settingsProviders: []
        )
    }

    private func snapshot(_ names: [String]) -> NetworkSnapshot {
        NetworkSnapshot(
            sessionID: CaptureSessionID(rawValue: "s-1"),
            appliedSequence: 1,
            asOf: base,
            monotonicAsOf: MonotonicInstant(nanoseconds: 1),
            collectionState: .active,
            coverage: NetworkCoverage(
                identity: .full, bytes: .full, targets: .full, protocols: .full,
                lostEventCount: 0, counterResetCount: 0,
                truncatedCollections: [], hasLiveSample: true
            ),
            capabilities: .unavailable,
            interfaces: Dictionary(uniqueKeysWithValues: names.map { name in
                (name, InterfaceCounters(
                    name: name,
                    kind: Self.kind(for: name),
                    counters: NetworkByteCounters(
                        bytes: DirectionalBytes(upload: 100, download: 200),
                        semantics: .cumulativeSinceEpoch,
                        epoch: CounterEpoch(rawValue: 7)
                    ),
                    asOf: base,
                    monotonicAsOf: MonotonicInstant(nanoseconds: 1)
                ))
            }),
            apps: [:],
            interfaceRates: [:],
            interfaceInventory: .init(envelope: .init(sessionID: .init(rawValue: "s-1"), sequence: 1,
                occurredAt: base, monotonicOccurredAt: .init(nanoseconds: 1)), succeeded: true, names: Set(names))
        )
    }

    private static func kind(for name: String) -> NetworkInterfaceKind {
        if name.hasPrefix("utun") { return .tunnel }
        if name.hasPrefix("lo") { return .loopback }
        return .physical
    }

    // MARK: - Honest unknowns

    func testFreshModelNamesNoInterfaceUntilTheSystemAnswers() {
        let model = makeModel()
        model.applyNetworkSnapshot(snapshot(["en0"]))
        XCTAssertNil(model.resolvedNetworkInterfaceName)
        XCTAssertEqual(model.networkObservationResolution, .systemStateUnreadable)
        XCTAssertTrue(model.networkObservationSourceText.contains("无法读取"))
    }

    func testUnreadableReadingDoesNotOverwriteAKnownPath() {
        let model = makeModel()
        model.setNetworkSystemPath(
            NetworkSystemPath(primaryInterfaceName: "en0", friendlyNames: ["en0": "Wi-Fi"]),
            at: base
        )
        model.setNetworkSystemPath(.unreadable, at: base.addingTimeInterval(1))
        model.applyNetworkSnapshot(snapshot(["en0"]))
        XCTAssertEqual(model.resolvedNetworkInterfaceName, "en0")
        XCTAssertEqual(model.networkObservationLabel, "Wi-Fi（en0）")
    }

    func testSystemConfirmedPrimaryWithoutSamplesLeavesNumbersUnknown() {
        let model = makeModel()
        model.setNetworkSystemPath(
            NetworkSystemPath(primaryInterfaceName: "en0", friendlyNames: [:]),
            at: base
        )
        // Only a tunnel is being sampled; the page must not measure it as the
        // network just because it is the only thing available.
        model.applyNetworkSnapshot(snapshot(["utun5"]))
        XCTAssertNil(model.resolvedNetworkInterfaceName)
        XCTAssertEqual(model.networkObservationResolution, .notSampled(interfaceName: "en0"))
    }

    // MARK: - Selection

    func testSelectionRoundTripsThroughTheAutomaticSentinel() {
        let model = makeModel()
        XCTAssertTrue(model.networkObservationIsAutomatic)
        XCTAssertEqual(model.networkObservationSelection, MenuPanelViewModel.automaticNetworkObservationValue)

        model.networkObservationSelection = "en6"
        XCTAssertEqual(model.userSelectedNetworkInterface, "en6")
        XCTAssertFalse(model.networkObservationIsAutomatic)

        model.networkObservationSelection = MenuPanelViewModel.automaticNetworkObservationValue
        XCTAssertNil(model.userSelectedNetworkInterface)
        XCTAssertTrue(model.networkObservationIsAutomatic)
    }

    func testManualSelectionWinsAndIsLabelledAsManual() {
        let model = makeModel()
        model.setNetworkSystemPath(
            NetworkSystemPath(primaryInterfaceName: "en0", friendlyNames: ["en0": "Wi-Fi", "utun5": "Tunnel 5"]),
            at: base
        )
        model.applyNetworkSnapshot(snapshot(["en0", "utun5"]))
        model.networkObservationSelection = "utun5"
        XCTAssertEqual(model.resolvedNetworkInterfaceName, "utun5")
        XCTAssertTrue(model.networkObservationSourceText.contains("手动"))
    }

    func testVanishedManualSelectionStaysSelectedAndMeasuresNothing() {
        let model = makeModel()
        model.setNetworkSystemPath(
            NetworkSystemPath(primaryInterfaceName: "en0", friendlyNames: [:]),
            at: base
        )
        model.userSelectedNetworkInterface = "en3"
        model.applyNetworkSnapshot(snapshot(["en0"]))
        XCTAssertEqual(model.networkObservationResolution, .manualUnavailable(interfaceName: "en3"))
        XCTAssertNil(model.resolvedNetworkInterfaceName)
        XCTAssertEqual(model.networkObservationSelection, "en3", "the choice must stay visible in the picker")
        model.setNetworkObservationAutomatic()
        XCTAssertEqual(model.resolvedNetworkInterfaceName, "en0")
    }

    func testAdvancedListKeepsEveryObservedInterfaceSeparate() {
        let model = makeModel()
        model.applyNetworkSnapshot(snapshot(["en0", "utun5", "lo0"]))
        let flattened = model.networkAdvancedInterfaceGroups.flatMap(\.interfaces)
        XCTAssertEqual(Set(flattened), ["en0", "utun5", "lo0"])
        // Physical and tunnel are listed apart and never summed into one view.
        XCTAssertEqual(model.networkAdvancedInterfaceGroups.map(\.kind), [.physical, .tunnel, .loopback])
    }
}
