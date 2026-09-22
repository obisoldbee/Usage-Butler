#if DEBUG
import AppKit
import UsageButlerCore
import UsageButlerDomain
import UsageButlerUI

/// Debug-only acceptance harness for the network trend curve.
///
/// Screen recording of another process is not reliably available here, and a
/// static design mock says nothing about whether *this* window connects upload
/// to download. So the app drives its own real buffer, projection and Swift
/// Charts code with a scripted rate sequence and renders the live panel view to
/// disk. What comes back is the actual pixels of the actual window, bound to
/// this bundle, this PID and this clock.
///
/// The script is the one PRD §13.4.2 asks for: upload in alternating pulses,
/// download steady and non-zero, a publishing gap, a session change, a counter
/// epoch change, and a lone sample after a gap. Each phase has an expected
/// segment structure that the manifest records.
@MainActor
final class NetworkCurveValidation {
    static let argument = "--validate-network-curve"
    /// The run owns itself until it terminates: nothing else holds a reference
    /// to a harness that only exists to drive one scripted session.
    private static var active: NetworkCurveValidation?

    private let runtime: AppRuntime
    private let panel: PanelPresentationController
    private let outputDirectory: URL
    private let startedAt = Date()
    private let monotonicStart = DispatchTime.now().uptimeNanoseconds
    private var frames: [[String: Any]] = []
    private var quiesceState = "not-run"

    private init(runtime: AppRuntime, panel: PanelPresentationController, outputDirectory: URL) {
        self.runtime = runtime
        self.panel = panel
        self.outputDirectory = outputDirectory
    }

    static func startIfRequested(runtime: AppRuntime, panel: PanelPresentationController) {
        if CommandLine.arguments.contains("--validate-network-selection") {
            SelectionValidation.start(runtime: runtime)
            return
        }
        guard CommandLine.arguments.contains(argument) else { return }
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first?
            .appendingPathComponent("UsageButler/validation/network-curve-\(Int(Date().timeIntervalSince1970))")
        guard let directory, let output = ensureDirectory(directory) else { return }
        let harness = NetworkCurveValidation(runtime: runtime, panel: panel, outputDirectory: output)
        active = harness
        harness.run()
    }

    /// Reports what the page decided to measure *on this machine*, in automatic
    /// mode. The unit tests cover the rule; only a live run can show that the
    /// SystemConfiguration read and the collector's interface names actually
    /// agree here, rather than both being wrong in the same direction.
    private enum SelectionValidation {
        static func start(runtime: AppRuntime) {
            Task { @MainActor in
                let model = runtime.menuModel
                for _ in 0..<24 {
                    try? await Task.sleep(for: .milliseconds(500))
                    if model.networkSnapshot != nil, model.resolvedNetworkInterfaceName != nil { break }
                }
                NSLog(
                    "panel_validation selection automatic=%d label=%@ source=%@ observed=%@",
                    model.networkObservationIsAutomatic ? 1 : 0,
                    model.networkObservationLabel,
                    model.networkObservationSourceText,
                    model.networkSnapshot?.interfaces.keys.sorted().joined(separator: ",") ?? "none"
                )
                DispatchQueue.global().asyncAfter(deadline: .now() + 2) { exit(0) }
            }
        }
    }

    private static func ensureDirectory(_ url: URL) -> URL? {
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            return url
        } catch {
            NSLog("panel_validation cannot_create_output error=\(error.localizedDescription)")
            return nil
        }
    }

    // MARK: - Script

    private func run() {
        Task { @MainActor [weak self] in
            await self?.execute()
        }
    }

    private func execute() async {
        let model = runtime.menuModel
        // Silence the real collector so it cannot interleave with the script,
        // and put the setting back on the way out — this is a shared preference
        // domain, and a validation run must not silently change it.
        let collectionWasEnabled = UserDefaults.standard
            .object(forKey: NetworkPreferenceKey.collectionEnabled) as? Bool ?? false
        let quiesced = await runtime.debugQuiesceNetworkCollection()
        quiesceState = quiesced
        NSLog("panel_validation quiesce=%@", quiesced)
        // Pin the observation point so the script is deterministic on a machine
        // whose active network is not the scripted interface.
        model.userSelectedNetworkInterface = "en0"
        model.selectedPage = .network
        model.networkTrendRange = .oneMinute

        // The status item's button is not always realized by the time the first
        // main-actor turn runs, so showing is retried instead of assumed.
        var shown = false
        for _ in 0..<20 {
            if !panel.validationIsShown { panel.togglePanel() }
            if panel.validationIsShown { shown = true; break }
            try? await Task.sleep(for: .milliseconds(250))
        }
        NSLog("panel_validation harness_begin pid=%d shown=%d out=%@",
              ProcessInfo.processInfo.processIdentifier, shown ? 1 : 0, outputDirectory.path)

        for t in 0...70 {
            if let snapshot = scriptSample(at: t) {
                model.applyNetworkSnapshot(snapshot)
            }
            if t == 17 || t == 33 || t == 47 || t == 64 || t == 70 {
                capture(at: t)
            }
            if t == 52 { tryTabKey() }
            try? await Task.sleep(for: .seconds(1))
        }

        writeManifest()
        model.setNetworkCollectionEnabled(collectionWasEnabled)
        try? await Task.sleep(for: .seconds(1))
        NSLog("panel_validation harness_end frames=%ld restored_collection=%d", frames.count, collectionWasEnabled ? 1 : 0)
        quitLikeAUserWould()
    }

    /// Terminates from a fresh main-queue block rather than from inside this
    /// task. Called directly here, the nested loop AppKit enters while waiting
    /// for the delegate's reply never resumes the main-actor work that sends
    /// that reply, and the process hangs; dispatched from the run loop this is
    /// the same context a Quit button action has. If the process is still alive
    /// afterwards the hang is real, and the harness says so instead of leaking
    /// an instance for the next run to trip over.
    private func quitLikeAUserWould() {
        DispatchQueue.main.async {
            NSLog("panel_validation terminate_begin")
            NSApp.terminate(nil)
            NSLog("panel_validation terminate_returned")
        }
        // Off the main thread on purpose: `terminate:` keeps the main thread
        // inside a nested AppKit loop that does not service main-queue work, so
        // a watchdog posted there would never run — which is exactly how this
        // run was observed to hang. See conversation/105 §5.
        DispatchQueue.global().asyncAfter(deadline: .now() + 6) {
            NSLog("panel_validation terminate_still_blocked exiting")
            exit(0)
        }
    }

    /// One scripted second. `nil` means nothing was published, which is a gap in
    /// the data and has to stay a gap on screen.
    private func scriptSample(at t: Int) -> NetworkSnapshot? {
        switch t {
        case 18..<30: return nil
        case 58..<62: return nil
        case 0..<18:
            return snapshot(
                session: "a", epoch: 1, sequence: UInt64(t + 1), at: t,
                upload: t.isMultiple(of: 2) ? 0 : 2_000_000,
                download: 200_000
            )
        case 30..<44:
            // New capture session, and the pulse phase is inverted so a line
            // stitched across the boundary would be obvious.
            return snapshot(
                session: "b", epoch: 1, sequence: UInt64(t - 29), at: t,
                upload: t.isMultiple(of: 2) ? 2_000_000 : 0,
                download: 100_000
            )
        case 44..<58:
            // Same session, new counter epoch: the accounting restarts and the
            // curve must break even though nothing else changed.
            return snapshot(
                session: "b", epoch: 2, sequence: UInt64(t - 13), at: t,
                upload: t.isMultiple(of: 2) ? 0 : 2_000_000,
                download: 200_000
            )
        default:
            return snapshot(
                session: "b", epoch: 2, sequence: UInt64(t - 13), at: t,
                upload: 50_000, download: 50_000
            )
        }
    }

    private func snapshot(
        session: String,
        epoch: UInt64,
        sequence: UInt64,
        at t: Int,
        upload: UInt64,
        download: UInt64
    ) -> NetworkSnapshot {
        let wall = startedAt.addingTimeInterval(Double(t))
        let monotonic = MonotonicInstant(nanoseconds: monotonicStart + UInt64(t) * 1_000_000_000)
        func counters(_ name: String, _ kind: NetworkInterfaceKind, _ up: UInt64, _ down: UInt64) -> InterfaceCounters {
            InterfaceCounters(
                name: name,
                kind: kind,
                counters: NetworkByteCounters(
                    bytes: DirectionalBytes(upload: up, download: down),
                    semantics: .cumulativeSinceEpoch,
                    epoch: CounterEpoch(rawValue: epoch)
                ),
                asOf: wall,
                monotonicAsOf: monotonic
            )
        }
        return NetworkSnapshot(
            sessionID: CaptureSessionID(rawValue: session),
            appliedSequence: sequence,
            asOf: wall,
            monotonicAsOf: monotonic,
            collectionState: .active,
            coverage: NetworkCoverage(
                identity: .full, bytes: .full, targets: .full, protocols: .full,
                lostEventCount: 0, counterResetCount: 0,
                truncatedCollections: [], hasLiveSample: true
            ),
            capabilities: .unavailable,
            interfaces: [
                "en0": counters("en0", .physical, 1_000_000 &+ upload, 4_000_000 &+ download),
                // A tunnel carrying its own double-counted traffic must never
                // end up on the same curve as the physical interface.
                "utun5": counters("utun5", .tunnel, 900_000, 1_900_000)
            ],
            apps: [:],
            interfaceRates: [
                "en0": NetworkRate(
                    uploadBytesPerSecond: Double(upload),
                    downloadBytesPerSecond: Double(download),
                    asOf: wall,
                    window: .seconds(1)
                ),
                "utun5": NetworkRate(
                    uploadBytesPerSecond: 7_000_000,
                    downloadBytesPerSecond: 7_000_000,
                    asOf: wall,
                    window: .seconds(1)
                )
            ],
            interfaceInventory: .init(envelope: .init(sessionID: .init(rawValue: session), sequence: sequence,
                occurredAt: wall, monotonicOccurredAt: monotonic), succeeded: true, names: ["en0", "utun5"])
        )
    }

    // MARK: - Evidence

    private func capture(at t: Int) {
        let model = runtime.menuModel
        let now = Date()
        let projection = model.networkTrendProjection(now: now, window: model.networkTrendRange.duration)
        var record: [String: Any] = [
            "scriptSecond": t,
            "capturedAt": ISO8601DateFormatter().string(from: now),
            "selectedInterface": model.resolvedNetworkInterfaceName ?? "nil",
            "observationSource": model.networkObservationSourceText,
            "segmentCount": projection.segmentCount,
            "isolatedPointCount": projection.isolatedPointCount,
            "thinnedSegmentCount": projection.thinnedSegmentCount,
            "gapThresholdSeconds": projection.gapThreshold,
            "pointCount": projection.points.count,
            "seriesKeys": Array(Set(projection.points.map(\.seriesKey))).sorted(),
            "directions": Dictionary(grouping: projection.points.map(\.direction.scaleKey), by: { $0 })
                .mapValues(\.count),
            "interfaceNamesInSeries": Array(Set(projection.points.map { $0.seriesKey.split(separator: "|").first.map(String.init) ?? "" })).sorted()
        ]
        // The buffer as the chart sees it. Without this, a segment count can be
        // read as a verdict when it is only a symptom of what got recorded.
        if let name = model.resolvedNetworkInterfaceName {
            let buffered = model.networkRateHistory.series(for: name)
            record["bufferedSampleCount"] = buffered.count
            record["foreignSessionSampleCount"] = buffered.filter {
                $0.captureSessionID.rawValue != "a" && $0.captureSessionID.rawValue != "b"
            }.count
            record["republishedSampleCount"] = model.networkRateHistory.republishedSampleCount
            record["bufferTail"] = buffered.suffix(24).map { sample in
                "\(sample.captureSessionID.rawValue)|\(sample.counterEpoch.rawValue)|"
                    + "t+\(String(format: "%.2f", sample.sampledAt.timeIntervalSince(startedAt)))|"
                    + "u=\(sample.uploadBytesPerSecond.map { String(format: "%.0f", $0) } ?? "-")|"
                    + "d=\(sample.downloadBytesPerSecond.map { String(format: "%.0f", $0) } ?? "-")"
            }
        }
        if let png = renderPanelPNG(tag: t) {
            record["png"] = png.lastPathComponent
        }
        frames.append(record)
        NSLog(
            "panel_validation frame t=%d segments=%d isolated=%d points=%d series=%d png=%@",
            t, projection.segmentCount, projection.isolatedPointCount,
            projection.points.count, Set(projection.points.map(\.seriesKey)).count,
            (record["png"] as? String).flatMap { $0 as NSString }?.lastPathComponent ?? "none"
        )
    }

    private func renderPanelPNG(tag: Int) -> URL? {
        guard let view = panel.validationContentView, view.window != nil else {
            NSLog("panel_validation render_skipped no_view=%d no_window=%d",
                  panel.validationContentView == nil ? 1 : 0,
                  panel.validationContentView?.window == nil ? 1 : 0)
            return nil
        }
        let bounds = view.bounds
        guard let rep = view.bitmapImageRepForCachingDisplay(in: bounds) else { return nil }
        view.cacheDisplay(in: bounds, to: rep)
        guard let data = rep.representation(using: .png, properties: [:]) else { return nil }
        let url = outputDirectory.appendingPathComponent("panel-t\(tag).png")
        do {
            try data.write(to: url)
            return url
        } catch {
            NSLog("panel_validation render_failed error=\(error.localizedDescription)")
            return nil
        }
    }

    /// Tab while the panel is key must move pages, not steal focus from a text
    /// field. Posted through the real event path so the local monitor runs.
    private func tryTabKey() {
        let model = runtime.menuModel
        guard let window = panel.validationContentView?.window else {
            NSLog("panel_validation tab_skipped no_window")
            return
        }
        window.makeKeyAndOrderFront(nil)
        let before = model.selectedPage
        guard let event = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            characters: "\t",
            charactersIgnoringModifiers: "\t",
            isARepeat: false,
            keyCode: 48
        ) else {
            NSLog("panel_validation tab_skipped no_event")
            return
        }
        NSApp.postEvent(event, atStart: false)
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1))
            NSLog(
                "panel_validation tab before=%@ after=%@ keyWindow=%d",
                before.rawValue, model.selectedPage.rawValue,
                NSApp.keyWindow === window ? 1 : 0
            )
            // The captures after this point are about the network page, so the
            // Tab probe has to leave it where it found it.
            model.selectedPage = before
        }
    }

    private func writeManifest() {
        let info = Bundle.main.infoDictionary
        let manifest: [String: Any] = [
            "harness": "network-curve",
            "startedAt": ISO8601DateFormatter().string(from: startedAt),
            "pid": ProcessInfo.processInfo.processIdentifier,
            "executable": CommandLine.arguments.first ?? "",
            "bundleIdentifier": info?["CFBundleIdentifier"] ?? "",
            "bundleVersion": info?["CFBundleVersion"] ?? "",
            "collectorQuiesced": quiesceState,
            "frames": frames
        ]
        guard JSONSerialization.isValidJSONObject(manifest),
              let data = try? JSONSerialization.data(
                withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys]
              ) else {
            NSLog("panel_validation manifest_failed")
            return
        }
        try? data.write(to: outputDirectory.appendingPathComponent("manifest.json"))
    }
}
#endif
