import AppKit
import XCTest
@testable import UsageButlerUI
import UsageButlerDomain
import UsageButlerCore

/// Guards the "green means the data is good" rules and the Tab focus
/// exception, both of which were previously only reachable through the app
/// target.
final class NetworkStatusRulesTests: XCTestCase {
    private let base = Date(timeIntervalSince1970: 1_800_000_000)

    private func snapshot(
        state: NetworkCollectionState = .active,
        bytes: CoverageLevel = .full,
        hasLiveSample: Bool = true,
        lostEvents: UInt64 = 0,
        counterResets: UInt64 = 0,
        truncated: [String] = [],
        sampleAge: TimeInterval = 1
    ) -> NetworkSnapshot {
        NetworkSnapshot(
            sessionID: CaptureSessionID(rawValue: "s-1"),
            appliedSequence: 3,
            asOf: base.addingTimeInterval(sampleAge),
            monotonicAsOf: MonotonicInstant(nanoseconds: UInt64(sampleAge * 1_000_000_000)),
            collectionState: state,
            coverage: NetworkCoverage(
                identity: .full,
                bytes: bytes,
                targets: .full,
                protocols: .full,
                lostEventCount: lostEvents,
                counterResetCount: counterResets,
                truncatedCollections: truncated,
                hasLiveSample: hasLiveSample
            ),
            capabilities: .unavailable,
            interfaces: ["en0": InterfaceCounters(
                name: "en0",
                kind: .physical,
                counters: NetworkByteCounters(
                    bytes: DirectionalBytes(upload: 10, download: 20),
                    semantics: .cumulativeSinceEpoch,
                    epoch: CounterEpoch(rawValue: 0)
                ),
                asOf: base.addingTimeInterval(sampleAge),
                monotonicAsOf: MonotonicInstant(nanoseconds: UInt64(sampleAge * 1_000_000_000))
            )],
            apps: [:],
            interfaceRates: [:]
        )
    }

    // MARK: - Healthy

    func testActiveWithFullCoverageIsHealthy() {
        XCTAssertTrue(NetworkStatusRules.isHealthy(snapshot()))
    }

    /// Degraded byte coverage must cost the green light even though the state
    /// enum still says `active`.
    func testPartialByteCoverageIsNotHealthy() {
        XCTAssertFalse(NetworkStatusRules.isHealthy(snapshot(bytes: .partial(reason: "counter-reset"))))
        XCTAssertFalse(NetworkStatusRules.isHealthy(snapshot(bytes: .partial(reason: "out-of-order-events"))))
        XCTAssertFalse(NetworkStatusRules.isHealthy(snapshot(bytes: .unavailable(reason: "no-source"))))
    }

    func testActiveWithoutLiveSampleIsNotHealthy() {
        XCTAssertFalse(NetworkStatusRules.isHealthy(snapshot(hasLiveSample: false)))
    }

    func testNonActiveStatesAreNeverHealthy() {
        for state in [NetworkCollectionState.starting, .stopped] {
            XCTAssertFalse(NetworkStatusRules.isHealthy(snapshot(state: state)), "\(state)")
        }
        XCTAssertFalse(NetworkStatusRules.isHealthy(nil))
    }

    // MARK: - Staleness

    func testRatesAreCurrentWhileReadingsKeepArriving() {
        XCTAssertFalse(NetworkStatusRules.ratesAreStale(snapshot(sampleAge: 1), now: base.addingTimeInterval(1)))
    }

    func testRatesGoStalePastTheHorizon() {
        XCTAssertTrue(NetworkStatusRules.ratesAreStale(
            snapshot(sampleAge: 1), now: base.addingTimeInterval(1 + NetworkStatusRules.freshnessHorizon + 1)
        ))
    }

    /// Disconnect keeps last-good data on screen, which is exactly when the
    /// current-rate reading must stop claiming to be live.
    func testDisconnectedRatesAreStale() {
        let since = base.addingTimeInterval(5)
        XCTAssertTrue(NetworkStatusRules.ratesAreStale(
            snapshot(state: .disconnected(since: since)), now: since
        ))
    }

    func testMissingSnapshotIsStale() {
        XCTAssertTrue(NetworkStatusRules.ratesAreStale(nil, now: base))
    }

    // MARK: - Disclosure

    func testNothingIsDisclosedWhenCoverageIsClean() {
        XCTAssertNil(NetworkStatusRules.coverageNotice(snapshot()))
    }

    func testEveryIntegritySignalIsDisclosed() {
        let notice = NetworkStatusRules.coverageNotice(snapshot(
            bytes: .partial(reason: "lost-events"),
            lostEvents: 4,
            counterResets: 2,
            truncated: ["flows"]
        ))
        XCTAssertNotNil(notice)
        XCTAssertTrue(notice!.contains("丢失"))
        XCTAssertTrue(notice!.contains("重置 2"))
        XCTAssertTrue(notice!.contains("flows"))
    }

    /// The counter itself, not only the enum case, has to reach the user:
    /// "some samples were lost" is worthless without how many.
    func testResetReasonIsNamedInHumanTerms() {
        let notice = NetworkStatusRules.coverageNotice(snapshot(bytes: .partial(reason: "counter-reset")))
        XCTAssertEqual(notice, "接口计数器发生重置，历史已不完整")
    }

    func testUnavailableBytesAreDisclosedWithReason() {
        let notice = NetworkStatusRules.coverageNotice(snapshot(bytes: .unavailable(reason: "collection-stopped")))
        XCTAssertNotNil(notice)
        XCTAssertTrue(notice!.contains("collection-stopped"))
    }
}

/// PRD 0.20 §13.3: Tab inside a field belongs to focus, not to page cycling.
@MainActor
final class PanelTabRoutingTests: XCTestCase {
    private func event(in window: NSWindow, modifiers: NSEvent.ModifierFlags = [], keyCode: UInt16 = 48) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers,
                        timestamp: 0, windowNumber: window.windowNumber, context: nil,
                        characters: "\t", charactersIgnoringModifiers: "\t", isARepeat: false, keyCode: keyCode)!
    }

    func testBareTabCyclesAllThreePagesTwiceIncludingNetworkToQuota() {
        let window = makeWindow()
        window.makeFirstResponder(window)
        let model = MenuPanelViewModel(snapshot: .init(providers: [], memory: .init(
            pressure: .unknown, fields: [], history: [], capturedAt: .distantPast, origin: .runtime
        )), settingsProviders: [])
        for _ in 0..<2 {
            for page in MenuPage.allCases {
                XCTAssertEqual(model.selectedPage, page)
                XCTAssertTrue(PanelTabRouting.shouldCyclePage(for: event(in: window), panelWindow: window))
                model.cyclePage()
            }
        }
        XCTAssertEqual(model.selectedPage, MenuPage.allCases.first)
    }

    func testTabPolicyLeavesFieldsModifiersOtherWindowsAndKeysAlone() {
        let window = makeWindow(), other = makeWindow()
        window.makeFirstResponder(window)
        XCTAssertFalse(PanelTabRouting.shouldCyclePage(for: event(in: other), panelWindow: window))
        XCTAssertFalse(PanelTabRouting.shouldCyclePage(for: event(in: window), panelWindow: nil))
        XCTAssertFalse(PanelTabRouting.shouldCyclePage(for: event(in: window, keyCode: 49), panelWindow: window))
        for modifier in [NSEvent.ModifierFlags.shift, .control, .option, .command] {
            XCTAssertFalse(PanelTabRouting.shouldCyclePage(for: event(in: window, modifiers: modifier), panelWindow: window))
        }
        XCTAssertTrue(PanelTabRouting.shouldCyclePage(for: event(in: window, modifiers: .capsLock), panelWindow: window))
        let field = NSTextField()
        window.contentView?.addSubview(field)
        window.makeFirstResponder(field)
        XCTAssertFalse(PanelTabRouting.shouldCyclePage(for: event(in: window), panelWindow: window))
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 540, height: 420),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        return window
    }

    func testNoWindowAndUnfocusedWindowDoNotClaimTab() {
        XCTAssertFalse(PanelTabRouting.belongsToFocusedControl(in: nil))
        let window = makeWindow()
        window.makeFirstResponder(window)
        XCTAssertFalse(PanelTabRouting.belongsToFocusedControl(in: window), "the window itself is not a control")
    }

    func testContentViewDoesNotClaimTab() {
        let window = makeWindow()
        window.makeFirstResponder(window.contentView)
        XCTAssertFalse(PanelTabRouting.belongsToFocusedControl(in: window))
    }

    func testControlsAndFieldEditorClaimTab() {
        let window = makeWindow()
        let button = NSButton(title: "x", target: nil, action: nil)
        window.contentView?.addSubview(button)
        window.makeFirstResponder(button)
        XCTAssertTrue(PanelTabRouting.belongsToFocusedControl(in: window), "Tab must reach the next control")

        // An actual field editor, which is what a focused text field installs.
        let field = NSTextField()
        window.contentView?.addSubview(field)
        window.makeFirstResponder(field)
        XCTAssertTrue(PanelTabRouting.belongsToFocusedControl(in: window), "Tab inside text editing must not cycle pages")
    }

    /// The SwiftUI host view holds focus for the whole panel; treating it as a
    /// control would switch page cycling off permanently.
    func testHostingViewDoesNotClaimTab() {
        final class FakeHostingView: NSView {
            override var acceptsFirstResponder: Bool { true }
        }
        let window = makeWindow()
        let host = FakeHostingView()
        window.contentView?.addSubview(host)
        window.makeFirstResponder(host)
        XCTAssertFalse(PanelTabRouting.belongsToFocusedControl(in: window))
    }

    func testOrdinaryResponsiveViewClaimsTab() {
        final class FocusableView: NSView {
            override var acceptsFirstResponder: Bool { true }
        }
        let window = makeWindow()
        let view = FocusableView()
        window.contentView?.addSubview(view)
        window.makeFirstResponder(view)
        XCTAssertTrue(PanelTabRouting.belongsToFocusedControl(in: window))
    }
}
