#if DEBUG && USAGE_BUTLER_FIXTURES
import AppKit
import CryptoKit
import Combine
import SwiftUI
import UsageButlerCore
import UsageButlerDomain
import UsageButlerInfrastructure
import UsageButlerUI

/// Opt-in native screenshot harness. Exact isolated IDs select offline mode
/// before AppRuntime construction; a production App cannot invoke this path.
@MainActor enum CopyPreviewRecorder {
    static func startIfRequested(runtime: AppRuntime) -> Bool {
        let allowed = ["io.github.obisoldbee.UsageButler.Preview.Copy.Before", "io.github.obisoldbee.UsageButler.Preview.Copy.After"]
        guard runtime.launchMode == .offlineFixture, allowed.contains(Bundle.main.bundleIdentifier ?? ""),
              let output = argument("--copy-output") else { return false }
        let input = argument("--copy-input")
        let path = argument("--copy-database")
        guard input != nil || path != nil else { return false }
        Task {
            do { try await record(runtime: runtime, output: URL(fileURLWithPath: output), database: path.map { URL(fileURLWithPath: $0) }, input: input.map { URL(fileURLWithPath: $0) }) }
            catch {
                let result: [String: String] = ["error": String(describing: error)]
                if let data = try? JSONSerialization.data(withJSONObject: result) {
                    try? data.write(to: URL(fileURLWithPath: output).appendingPathComponent("failure.json"), options: .withoutOverwriting)
                }
            }
            runtime.quit()
        }
        return true
    }
    private static func argument(_ key: String) -> String? {
        CommandLine.arguments.first { $0.hasPrefix(key + "=") }.map { String($0.dropFirst(key.count + 1)) }
    }
    private static func record(runtime: AppRuntime, output: URL, database: URL?, input: URL?) async throws {
        let now = ISO8601DateFormatter().date(from: "2026-10-10T02:42:00Z")!
        let query = database.map { NetworkHistoryQuery(databaseURL: $0) }
        let frozenSummary = try input.map { try JSONDecoder().decode(HistoryQueryResult.self, from: Data(contentsOf: $0.appendingPathComponent("summary.json"))) }
        let frozenDetail = try input.map { try JSONDecoder().decode(HistoryQueryResult.self, from: Data(contentsOf: $0.appendingPathComponent("detail.json"))) }
        let notes = ApplicationNoteStore()
        // Read only this presentation preference; never copy other settings or credentials.
        let saved = UserDefaults(suiteName: "io.github.obisoldbee.UsageButler")?.dictionary(forKey: ApplicationNoteStore.preferenceKey) as? [String: String] ?? [:]
        func history() -> BackgroundNetworkViewModel {
            let model = BackgroundNetworkViewModel(applicationNotes: notes, now: { now })
            model.onQuery = { request in
                if let frozenSummary, let frozenDetail {
                    let frozen = request.scope.applicationKey == nil ? frozenSummary : frozenDetail
                    guard frozen.satisfies(request) else { throw HistoryQueryFailure.incompatible }
                    return frozen
                }
                guard let query else { throw PreviewFailure.historyIssue("no input") }
                do { return try await query.query(request) }
                catch { throw BackgroundNetworkWire.Failure.remote((error as? NetworkHistoryError)?.code ?? "history.query-unavailable") }
            }
            model.range = .day
            model.registration = "enabled"; model.desired = true
            return model
        }
        let summary = history(); summary.reload()
        await CopyPreviewScenes.waitForHistory(summary)
        guard let data = summary.result else { throw PreviewFailure.historyIssue(summary.queryIssue ?? "no result") }
        for app in data.applications { if let note = saved[app.identity.key] { notes.save(note, for: app.identity) } }
        let detail = history()
        let selected = data.applications.first { saved[$0.identity.key] == "codex.app" }
            ?? data.applications.first { $0.identity.name == "ChatGPT" } ?? data.applications.first
        guard let selected else { throw PreviewFailure.noApplications }
        detail.openApplication(selected)
        await CopyPreviewScenes.waitForHistory(detail)
        guard detail.result != nil else { throw PreviewFailure.historyIssue(detail.queryIssue ?? "no result") }
        let status = BackgroundNetworkStatus(version: "0.5.9", pid: 0, startedAt: now, sourceState: .active,
            sourceIssue: nil, coverage: data.coverage, rule: .init())
        summary.status = status; detail.status = status
        let outputData = try JSONEncoder().encode(data)
        let detailData = try JSONEncoder().encode(detail.result)
        try outputData.write(to: output.appendingPathComponent("history-result.json"), options: .withoutOverwriting)
        try detailData.write(to: output.appendingPathComponent("history-detail-result.json"), options: .withoutOverwriting)
        NSApp.setActivationPolicy(.regular)
        NSApp.appearance = NSAppearance(named: .aqua)
        var receipts: [[String: Any]] = []
        var interactions: [[String: Any]] = []
        for (id, view, size) in await CopyPreviewScenes.scenes(history: summary, detail: detail, notes: notes, now: now) {
            let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height, alignment: .topLeading)
                .background(Color(nsColor: .windowBackgroundColor))
                .environment(\.locale, Locale(identifier: "zh_CN")))
            let window = NSWindow(contentRect: .init(origin: .zero, size: size),
                styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.title = "额度管家 · 文案对照 " + id
            window.contentView = host; window.center(); window.orderFront(nil)
            try await Task.sleep(for: .milliseconds(350))
            host.layoutSubtreeIfNeeded(); host.displayIfNeeded()
            guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { throw PreviewFailure.noPixels }
            host.cacheDisplay(in: host.bounds, to: rep)
            guard let png = rep.representation(using: .png, properties: [:]) else { throw PreviewFailure.noPixels }
            try png.write(to: output.appendingPathComponent(id + ".png"), options: .withoutOverwriting)
            receipts.append(["id": id, "width": rep.pixelsWide, "height": rep.pixelsHigh,
                             "sha256": SHA256.hash(data: png).map { String(format: "%02x", $0) }.joined()])
            if id == "process-detail", let model = CopyPreviewScenes.rangeProbe {
                window.makeKeyAndOrderFront(nil)
                for option in [NetworkTrendRange.tenMinutes, .thirtyMinutes, .oneHour, .twoHours, .oneMinute] {
                    // Near an edge of the visible button, not just the text.
                    let identifier = "network.range." + option.rawValue
                    let button = elements(host).first(where: { $0.accessibilityIdentifier() == identifier })
                    let screen = button?.accessibilityFrame() ?? .zero
                    // These fixed-size native scenes have also been inspected as
                    // pixels. SwiftUI may expose no AX children until an external
                    // client attaches; use the observed selector bounds in that
                    // case, and still dispatch actual AppKit mouse events.
                    let index = NetworkTrendRange.allCases.firstIndex(of: option)!
                    let local = screen.isEmpty
                        ? windowPoint(host: host, x: 35 + Double(index) * 96.6, yFromTop: 218)
                        : window.convertPoint(fromScreen: .init(x: screen.minX + 5, y: screen.midY))
                    let started = DispatchTime.now().uptimeNanoseconds
                    for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                        if let event = NSEvent.mouseEvent(with: type, location: local, modifierFlags: [],
                            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                            context: nil, eventNumber: 0, clickCount: 1, pressure: 1) { NSApp.sendEvent(event) }
                    }
                    try await Task.sleep(for: .milliseconds(60)) // allow native painting
                    interactions.append(["type": "range-click", "option": option.rawValue,
                        "actual": model.range.rawValue, "passed": model.range == option,
                        "dispatchAndPaintMilliseconds": Double(DispatchTime.now().uptimeNanoseconds - started) / 1e6,
                        "target": [local.x, local.y],
                        "targetSource": screen.isEmpty ? "observed fixed native scene, five points inside left edge" : "native accessibility frame"])
                }
            }
            if id == "quota-count-only" {
                window.makeKeyAndOrderFront(nil)
                let candidate = elements(host).first { $0.accessibilityIdentifier() == "quota.entitlement.reset-count-only" }
                let accessibilityPressed = candidate?.accessibilityPerformPress() ?? false
                if !accessibilityPressed {
                    let local = windowPoint(host: host, x: 190, yFromTop: 144)
                    for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                        if let event = NSEvent.mouseEvent(with: type, location: local, modifierFlags: [],
                            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                            context: nil, eventNumber: 0, clickCount: 1, pressure: 1) { NSApp.sendEvent(event) }
                    }
                }
                try await Task.sleep(for: .milliseconds(350)) // finish the 200ms disclosure animation
                host.layoutSubtreeIfNeeded(); host.displayIfNeeded()
                let labels = elements(host).compactMap { $0.accessibilityLabel() }
                interactions.append(["type": "count-only-expand", "eventDispatched": true,
                    "targetSource": accessibilityPressed ? "native accessibility press" : "observed fixed native scene, available-count text",
                    "accessibilityReportedUnknownExpiry": labels.contains { $0.contains("服务只返回") },
                    "visualEvidence": "quota-count-expanded.png; compare the rendered content rather than infer expansion from event dispatch"])
                if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                    host.cacheDisplay(in: host.bounds, to: rep)
                    if let png = rep.representation(using: .png, properties: [:]) {
                        try png.write(to: output.appendingPathComponent("quota-count-expanded.png"), options: .withoutOverwriting)
                        receipts.append(["id": "quota-count-expanded", "width": rep.pixelsWide, "height": rep.pixelsHigh,
                            "sha256": SHA256.hash(data: png).map { String(format: "%02x", $0) }.joined()])
                    }
                }
            }
            if id == "process-list" {
                interactions.append(["type": "column-layout", "elements": elements(host).compactMap { element -> [String: Any]? in
                    guard let key = element.accessibilityIdentifier(), key.hasPrefix("network.apps.column.") || key.hasPrefix("network.apps.upload.") || key.hasPrefix("network.apps.download.") else { return nil }
                    let frame = element.accessibilityFrame()
                    return ["id": key, "frame": [frame.minX, frame.minY, frame.width, frame.height]]
                }])
            }
            window.close()
        }
        #if UB_COPY_AFTER
        let controller = PanelPresentationController(runtime: runtime, installShortcuts: false)
        let anchor = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 80, height: 24), styleMask: [.titled], backing: .buffered, defer: false)
        anchor.isReleasedWhenClosed = false; anchor.contentView = NSView(frame: NSRect(x: 0, y: 0, width: 80, height: 24))
        anchor.orderFront(nil)
        controller.validationShow(relativeTo: anchor.contentView!)
        try await Task.sleep(for: .milliseconds(100))
        let shown = controller.validationIsShown
        NotificationCenter.default.post(name: NSApplication.didResignActiveNotification, object: NSApp)
        try await Task.sleep(for: .milliseconds(100))
        interactions.append(["type": "native-popover-resign", "shownBefore": shown, "shownAfter": controller.validationIsShown,
            "passed": shown && !controller.validationIsShown, "event": "application resignation notification in isolated native process"])
        controller.validationShow(relativeTo: anchor.contentView!)
        try await Task.sleep(for: .milliseconds(100))
        let other = NSWindow(contentRect: NSRect(x: 800, y: 100, width: 100, height: 100), styleMask: [.titled], backing: .buffered, defer: false)
        other.isReleasedWhenClosed = false; other.orderFront(nil)
        let beforeOutside = controller.validationIsShown
        if let event = NSEvent.mouseEvent(with: .leftMouseDown, location: .init(x: 10, y: 10), modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: other.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) { NSApp.sendEvent(event) }
        try await Task.sleep(for: .milliseconds(100))
        interactions.append(["type": "native-popover-outside-click", "shownBefore": beforeOutside, "shownAfter": controller.validationIsShown,
            "passed": beforeOutside && !controller.validationIsShown, "event": "native mouse event in another owned window"])
        other.close(); anchor.close(); controller.stopShortcuts()
        #endif
        let receipt: [String: Any] = ["bundleID": Bundle.main.bundleIdentifier!, "executable": Bundle.main.executableURL!.path,
            "pid": ProcessInfo.processInfo.processIdentifier, "launchMode": "offlineFixture", "databaseMode": input == nil ? "read-only clone" : "frozen results of read-only clone queries",
            "historyNow": "2026-10-10T02:42:00Z", "otherPages": "identical sample data",
            "historyStatus": "active state supplied for copy comparison; not live service proof", "screenshots": receipts, "interactions": interactions]
        try JSONSerialization.data(withJSONObject: receipt, options: [.prettyPrinted, .sortedKeys])
            .write(to: output.appendingPathComponent("receipt.json"), options: .withoutOverwriting)
    }
    private static func windowPoint(host: NSView, x: Double, yFromTop: Double) -> NSPoint {
        host.convert(.init(x: x, y: host.isFlipped ? yFromTop : host.bounds.height - yFromTop), to: nil)
    }
    private struct NativeElement {
        let object: NSObject
        private func read(_ name: String) -> Any? {
            guard object.responds(to: NSSelectorFromString(name)) else { return nil }
            return object.value(forKey: name)
        }
        func accessibilityIdentifier() -> String? { read("accessibilityIdentifier") as? String }
        func accessibilityLabel() -> String? { read("accessibilityLabel") as? String }
        func accessibilityFrame() -> NSRect { (read("accessibilityFrame") as? NSValue)?.rectValue ?? .zero }
        func accessibilityPerformPress() -> Bool {
            let action = NSSelectorFromString("accessibilityPerformPress")
            guard object.responds(to: action), let implementation = object.method(for: action) else { return false }
            let press = unsafeBitCast(implementation, to: (@convention(c) (AnyObject, Selector) -> Bool).self)
            return press(object, action)
        }
        var children: [NSObject] { read("accessibilityChildren") as? [NSObject] ?? [] }
    }
    private static func elements(_ root: NSObject) -> [NativeElement] {
        var result: [NativeElement] = [], queue: [NSObject] = [root]
        var visited: Set<ObjectIdentifier> = []
        while let item = queue.popLast(), result.count < 10_000 {
            guard visited.insert(ObjectIdentifier(item)).inserted else { continue }
            let element = NativeElement(object: item)
            result.append(element); queue += element.children
        }
        return result
    }
    private enum PreviewFailure: Error { case historyIssue(String), noApplications, noPixels }
}
#endif
