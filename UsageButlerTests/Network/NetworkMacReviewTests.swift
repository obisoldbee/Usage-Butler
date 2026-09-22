import AppKit
import XCTest
@testable import UsageButlerCore
import UsageButlerDomain
@testable import UsageButlerUI

final class NetworkMacReviewTests: XCTestCase {
    private let base = Date(timeIntervalSince1970: 1_800_000_000)
    private let session = CaptureSessionID(rawValue: "presence-test")
    private func envelope(_ n: UInt64, mono: UInt64? = nil) -> NetworkEventEnvelope {
        .init(sessionID: session, sequence: n, occurredAt: base.addingTimeInterval(Double(n)),
              monotonicOccurredAt: .init(nanoseconds: (mono ?? n) * 1_000_000_000))
    }
    private func counters(_ name: String, _ n: UInt64, identity: String? = "ifindex:5") -> InterfaceCounters {
        .init(name: name, kind: .tunnel,
              counters: .init(bytes: .init(upload: n * 100, download: n * 200), semantics: .cumulativeSinceEpoch, epoch: .init(rawValue: 1)),
              asOf: base.addingTimeInterval(Double(n)), monotonicAsOf: envelope(n).monotonicOccurredAt,
              samplingInterval: 1, systemIdentity: identity)
    }
    private func apply(_ result: NetworkInterfaceEnumeration, _ n: UInt64, to aggregator: inout NetworkAggregator) {
        aggregator.apply(.init(envelope: envelope(n), payload: .interfaceEnumeration(result)))
    }
    private func snapshot(_ aggregator: inout NetworkAggregator, state: NetworkCollectionState = .active) -> NetworkSnapshot {
        aggregator.snapshot(asOf: base, monotonicAsOf: .init(nanoseconds: 100_000_000_000), collectionState: state)
    }

    func testCompleteDeletionFailureEmptyStopAndReappearance() {
        var a = NetworkAggregator(sessionID: session)
        apply(.complete([counters("utun5", 1), counters("en0", 1)]), 1, to: &a)
        apply(.complete([counters("utun5", 2), counters("en0", 2)]), 2, to: &a)
        XCTAssertEqual(snapshot(&a).presence(of: "utun5"), .present)
        apply(.complete([counters("en0", 3)]), 3, to: &a)
        var s = snapshot(&a)
        XCTAssertEqual(s.presence(of: "utun5"), .missing)
        XCTAssertNotNil(s.interfaces["utun5"], "historical counter is retained separately")
        XCTAssertNil(s.interfaceRates["utun5"])
        XCTAssertEqual(s.rateHistory?["utun5"]?.count, 2)
        apply(.failed, 4, to: &a)
        s = snapshot(&a)
        XCTAssertEqual(s.presence(of: "utun5"), .unknown)
        XCTAssertEqual(s.presence(of: "en0"), .unknown)
        XCTAssertTrue(s.interfaceRates.isEmpty)
        apply(.complete([]), 5, to: &a)
        XCTAssertEqual(snapshot(&a).presence(of: "en0"), .missing)
        XCTAssertEqual(snapshot(&a, state: .stopped).presence(of: "en0"), .notObserved)
        XCTAssertEqual(snapshot(&a, state: .disconnected(since: base)).presence(of: "en0"), .unknown)
        apply(.complete([counters("utun5", 6)]), 6, to: &a)
        s = snapshot(&a)
        XCTAssertEqual(s.presence(of: "utun5"), .present)
        XCTAssertNil(s.interfaces["utun5"]?.sessionTotal?.upload.bytes)
        XCTAssertNil(s.interfaceRates["utun5"]?.uploadBytesPerSecond)
        apply(.complete([counters("utun5", 7)]), 7, to: &a)
        s = snapshot(&a)
        XCTAssertEqual(s.interfaces["utun5"]?.sessionTotal?.upload.bytes, 100)
        let projected = NetworkChartProjector.project(s.rateHistory?["utun5"] ?? [], interface: "utun5",
            now: base.addingTimeInterval(8), window: 30, contract: .init())
        XCTAssertEqual(projected.segmentCount, 4, "both directions have separate pre/post disappearance segments")
    }

    func testSameNameIdentityChangeRebasesButNoEvidenceDoesNotInventChange() {
        var a = NetworkAggregator(sessionID: session)
        apply(.complete([counters("utun5", 1)]), 1, to: &a)
        apply(.complete([counters("utun5", 2)]), 2, to: &a)
        apply(.complete([counters("utun5", 3, identity: "ifindex:9")]), 3, to: &a)
        var s = snapshot(&a)
        XCTAssertNil(s.interfaces["utun5"]?.sessionTotal?.download.bytes)
        XCTAssertEqual(s.interfaces["utun5"]?.sessionTotal?.download.breakReason, "interface-identity-changed")
        apply(.complete([counters("utun5", 4, identity: nil)]), 4, to: &a)
        s = snapshot(&a)
        XCTAssertEqual(s.interfaces["utun5"]?.sessionTotal?.download.bytes, 200)
    }

    func testAtomicInventoryRejectsLateForeignDuplicateAndIncompleteEvidence() {
        var a = NetworkAggregator(sessionID: session)
        apply(.complete([counters("utun5", 1)]), 1, to: &a)
        a.apply(.init(envelope: .init(sessionID: .init(rawValue: "retired"), sequence: 2,
            occurredAt: base, monotonicOccurredAt: .init(nanoseconds: 2_000_000_000)), payload: .interfaceEnumeration(.complete([]))))
        apply(.complete([]), 1, to: &a)
        a.apply(.init(envelope: envelope(2, mono: 0), payload: .interfaceEnumeration(.complete([]))))
        XCTAssertEqual(snapshot(&a).presence(of: "utun5"), .present)
        // An individual legacy counter is never a complete presence boundary.
        a.apply(.init(envelope: envelope(3), payload: .interfaceCounters(counters("en0", 3))))
        XCTAssertEqual(snapshot(&a).presence(of: "utun5"), .present)
        apply(.complete([counters("en0", 4), counters("en0", 4)]), 4, to: &a)
        XCTAssertEqual(snapshot(&a).presence(of: "utun5"), .unknown)
    }

    func testRetainedMissingInterfacesYieldBoundedSlotsToNewNames() {
        var a = NetworkAggregator(sessionID: session, bounds: .init(maxInterfaces: 2))
        for n in 1...20 { apply(.complete([counters("utun\(n)", UInt64(n))]), UInt64(n), to: &a) }
        let s = snapshot(&a)
        XCTAssertEqual(s.presence(of: "utun20"), .present)
        XCTAssertEqual(s.interfaces.count, 2)
        XCTAssertLessThanOrEqual(s.rateHistory?.count ?? 0, 2)
        XCTAssertTrue(s.coverage.truncatedCollections.contains("interface-history"))
    }

    func testCodecPresenceEvidenceAndLegacyUnknownAndDecimalSequence() throws {
        var a = NetworkAggregator(sessionID: session)
        apply(.complete([counters("utun5", 1)]), 1, to: &a)
        let original = snapshot(&a)
        let data = try NetworkSnapshotJSONCodec.encode(original)
        XCTAssertEqual(try NetworkSnapshotJSONCodec.decode(data), original)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        json.removeValue(forKey: "interfaceInventory")
        let legacy = try NetworkSnapshotJSONCodec.decode(JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(legacy.presence(of: "utun5"), .unknown, "historical key cannot upgrade old snapshots")
        var inventory = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])["interfaceInventory"] as! [String: Any]
        inventory["sequence"] = "18446744073709551615"
        json["appliedSequence"] = "18446744073709551615"
        json["interfaceInventory"] = inventory
        let high = try NetworkSnapshotJSONCodec.decode(JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(high.interfaceInventory?.envelope.sequence, UInt64.max)
        inventory["session"] = "foreign"; json["interfaceInventory"] = inventory
        XCTAssertThrowsError(try NetworkSnapshotJSONCodec.decode(JSONSerialization.data(withJSONObject: json)))
        XCTAssertThrowsError(try NetworkSnapshotJSONCodec.encode(original, sizeLimit: 1))
    }

    func testPathMonotonicFiveAndFifteenSecondBoundariesIgnoreWallJumps() {
        func clock(_ mono: UInt64, wall: Double = 0) -> ClockReading {
            .init(wallTime: base.addingTimeInterval(wall), monotonicTime: .init(nanoseconds: mono))
        }
        var cache = NetworkPathCache()
        XCTAssertTrue(cache.shouldRead(at: clock(0)))
        cache.record(.init(primaryInterfaceName: "en0"), at: clock(1_000_000_000))
        XCTAssertFalse(cache.shouldRead(at: clock(5_999_999_999, wall: -3600)))
        XCTAssertTrue(cache.shouldRead(at: clock(6_000_000_000, wall: 3600)))
        XCTAssertTrue(cache.isFresh(at: clock(15_999_999_999, wall: -3600)))
        XCTAssertFalse(cache.isFresh(at: clock(16_000_000_000, wall: -3600)))
        XCTAssertFalse(cache.isFresh(at: clock(16_000_000_000, wall: 3600)))
        XCTAssertFalse(cache.isFresh(at: clock(0)))
        XCTAssertTrue(cache.shouldRead(at: clock(0)))
        cache.record(.unreadable, at: clock(17_000_000_000))
        XCTAssertFalse(cache.isFresh(at: clock(17_000_000_000)))
        cache.record(.notConnected, at: clock(18_000_000_000))
        XCTAssertEqual(cache.path(at: clock(18_000_000_000)), .notConnected)
        cache.invalidate()
        XCTAssertEqual(cache.path(at: clock(18_000_000_000)), .unreadable)
        XCTAssertTrue(cache.shouldRead(at: clock(18_000_000_000)))
    }

    private func sample(_ t: Int, up: Double? = 10, down: Double? = 20, epoch: UInt64 = 1) -> NetworkRateSample {
        .init(captureSessionID: session, counterEpoch: .init(rawValue: epoch), sampledAt: base.addingTimeInterval(Double(t)),
              sampledMonotonic: .init(nanoseconds: UInt64(t) * 1_000_000_000), uploadBytesPerSecond: up,
              downloadBytesPerSecond: down, interfaceName: "en0", samplingInterval: 1)
    }

    func testRetainedPointAndSegmentIdentitiesSurviveWindowAndHistoryTrim() {
        let history = NetworkRateHistoryBuffer.identifyingContinuity((0..<100).map { sample($0) })
        let a = NetworkChartProjector.project(history, interface: "en0", now: base.addingTimeInterval(90), window: 60, contract: .init())
        let b = NetworkChartProjector.project(history, interface: "en0", now: base.addingTimeInterval(91), window: 60, contract: .init())
        let c = NetworkChartProjector.project(Array(history.suffix(50)), interface: "en0", now: base.addingTimeInterval(91), window: 60, contract: .init())
        for later in [b, c] {
            let before = Dictionary(uniqueKeysWithValues: a.points.map { ($0.id, $0.seriesKey) })
            let common = later.points.filter { before[$0.id] != nil }
            XCTAssertGreaterThan(common.count, 50)
            XCTAssertTrue(common.allSatisfy { before[$0.id] == $0.seriesKey })
        }
        let gaps = NetworkRateHistoryBuffer.identifyingContinuity([sample(1), sample(2, up: nil), sample(3), sample(4, epoch: 2), sample(10)])
        let projected = NetworkChartProjector.project(gaps, interface: "en0", now: base.addingTimeInterval(11), window: 60, contract: .init())
        XCTAssertEqual(projected.segmentCount, 7)
        XCTAssertEqual(Set(projected.points.map(\.id)).count, projected.points.count)
    }

    func testProjectionCacheInvalidatesAllInputsAndCursorDoesNotRebuild() {
        var cache = NetworkChartProjectionCache()
        var history = [sample(1), sample(2), sample(3)]
        let now = base.addingTimeInterval(4)
        func frame(_ revision: UInt64 = 1, _ name: String = "en0", _ time: Date? = nil, _ window: Double = 60,
                   _ contract: NetworkChartSamplingContract = .init(), _ limit: Int = 140) -> NetworkTrendFrame {
            cache.frame(samples: history, revision: revision, interface: name, now: time ?? now,
                        window: window, contract: contract, maxPointsPerSegment: limit)
        }
        let initial = frame()
        for _ in 0..<100 { _ = frame().inspection.sample(at: base.addingTimeInterval(2)) }
        XCTAssertEqual(cache.buildCount, 1)
        _ = frame(2); _ = frame(2, "utun5"); _ = frame(2, "utun5", now.addingTimeInterval(1))
        _ = frame(2, "utun5", now.addingTimeInterval(1), 10)
        _ = frame(2, "utun5", now.addingTimeInterval(1), 10, .init(nominalSampleInterval: 5))
        _ = frame(2, "utun5", now.addingTimeInterval(1), 10, .init(nominalSampleInterval: 5), 2)
        XCTAssertEqual(cache.buildCount, 7)
        history[1] = sample(2, up: nil)
        let changed = frame(3)
        XCTAssertNotEqual(initial.projection, changed.projection)
        XCTAssertEqual(cache.buildCount, 8)
    }

    func testObservedPeaksKeepEmptyBaselineUnknownZeroAndOutOfRangeDistinct() {
        let cases: [([NetworkRateSample], Double?, Double?)] = [
            ([], nil, nil), ([sample(1, up: nil, down: nil)], nil, nil),
            ([sample(1, up: nil, down: 2)], nil, 2),
            ([sample(1, up: 0, down: 0)], 0, 0),
            ([sample(1)], nil, nil)
        ]
        for (index, item) in cases.enumerated() {
            var cache = NetworkChartProjectionCache()
            let frame = cache.frame(samples: item.0, revision: 1, interface: "en0",
                now: base.addingTimeInterval(index == 4 ? 100 : 2), window: 60)
            XCTAssertEqual(frame.uploadPeak, item.1)
            XCTAssertEqual(frame.downloadPeak, item.2)
            XCTAssertEqual(NetworkPresentation.rate(frame.uploadPeak), item.1 == nil ? "未知" : "0 B/s")
        }
    }
    @MainActor
    func testSettingsAgeWithoutCollectorAndPageCheckIsolationAndSourceDisclosure() async {
        var reading = ClockReading(wallTime: base, monotonicTime: .init(nanoseconds: 1_000_000_000))
        let model = MenuPanelViewModel(snapshot: .init(providers: [], memory: .init(pressure: .unknown,
            fields: [], history: [], capturedAt: base, origin: .runtime)), networkClock: { reading })
        model.setNetworkSystemPath(.init(primaryInterfaceName: "en0"))
        var a = NetworkAggregator(sessionID: session)
        apply(.complete([counters("en0", 1)]), 1, to: &a)
        model.applyNetworkSnapshot(snapshot(&a))
        XCTAssertEqual(model.resolvedNetworkInterfaceName, "en0")
        reading = .init(wallTime: base.addingTimeInterval(-3600), monotonicTime: .init(nanoseconds: 16_000_000_000))
        model.tickNetworkPathFreshness()
        XCTAssertEqual(model.networkObservationResolution, .systemStateUnreadable)
        model.userSelectedNetworkInterface = "en0"
        model.applyNetworkSnapshot(snapshot(&a, state: .stopped))
        XCTAssertEqual(model.networkObservationResolution, .notObserved(interfaceName: "en0"))
        XCTAssertEqual(model.networkInterfaceOptionTitle("en0"), "en0 · 未观察")
        XCTAssertEqual(model.networkObservationSelection, "en0")
        model.userSelectedNetworkInterface = nil
        XCTAssertEqual(model.networkObservationResolution, .notObserved(interfaceName: nil),
                       "stopped automatic mode remains unobserved even after path expiry")
        await model.loadSettingsStatus(for: .network)
        XCTAssertEqual(model.larkQuotaAlertChannelStatus, .notChecked)
        await model.loadSettingsStatus(for: .general)
        XCTAssertEqual(model.larkQuotaAlertChannelStatus, .unavailable)
        XCTAssertEqual(model.settingsSourceDisclosure, "本机运行时 · 只读")
        #if USAGE_BUTLER_FIXTURES
        let fixture = MenuPanelViewModel(snapshot: Stage3FixtureCatalog.projection())
        for page in SettingsPage.allCases {
            fixture.settingsPage = page
            XCTAssertEqual(fixture.settingsSourceDisclosure, "演示数据 · 非本机采集")
        }
        #endif
    }

    @MainActor
    func testActualChartKeyViewReturnsNativeFocusOnEscape() throws {
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 300, height: 200), styleMask: [.titled], backing: .buffered, defer: false)
        let root = NSView(frame: .init(x: 0, y: 0, width: 300, height: 200))
        let keyView = NetworkChartKeyboard.KeyView(frame: root.bounds)
        root.addSubview(keyView); window.contentView = root
        keyView.onKey = { $0 == 53 }
        XCTAssertTrue(window.makeFirstResponder(keyView))
        XCTAssertTrue(PanelTabRouting.belongsToFocusedControl(in: window))
        let escape = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: "\u{1b}",
            charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53))
        keyView.keyDown(with: escape)
        XCTAssertFalse(PanelTabRouting.belongsToFocusedControl(in: window))
    }

}
