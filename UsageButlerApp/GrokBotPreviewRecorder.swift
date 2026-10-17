#if DEBUG && USAGE_BUTLER_FIXTURES
import AppKit
import SwiftUI
import CryptoKit
import UsageButlerCore
import UsageButlerDomain
import UsageButlerProviders
import UsageButlerUI

/// Actual native views with synthetic input. This exact bundle is offline even without arguments.
@MainActor enum GrokBotPreviewRecorder {
    static func startIfRequested(runtime: AppRuntime) -> Bool {
        guard runtime.launchMode == .offlineFixture,
              Bundle.main.bundleIdentifier == "io.github.obisoldbee.UsageButler.Preview.Copy.GrokBot" else { return false }
        // An accidental reopen must not fall through to global shortcut setup.
        guard let argument = CommandLine.arguments.first(where: { $0.hasPrefix("--grokbot-output=") }) else {
            runtime.quit()
            return true
        }
        let output = URL(fileURLWithPath: String(argument.dropFirst("--grokbot-output=".count)))
        Task {
            do { try await record(output: output) }
            catch { try? String(describing: error).write(to: output.appendingPathComponent("failure.txt"), atomically: true, encoding: .utf8) }
            runtime.quit()
        }
        return true
    }
    private static func record(output: URL) async throws {
        let now = Date()
        let capability = ProviderCapabilities(contractVersion: GrokSharedQuotaMapper.contractVersion, loginMethod: nil,
            hasOfficialDocumentation: true, allowsExecutableSelection: false)
        let base = ProviderBootstrap.initialState(id: .grokBot, capabilities: capability, now: now)
        func project(_ data: ProviderQuotaData, stale: Bool = false, failureCode: FailureCode = .timedOut) -> Stage3ProviderProjection {
            var state = ProviderReducer.reduce(state: base, event: .refreshSucceeded(data), now: data.fetchedAt)
            state.connection = .connected(observedAt: data.fetchedAt)
            if stale {
                state = ProviderReducer.reduce(state: state, event: .refreshFailed(.init(code: failureCode, retryClass: .backoff,
                    userMessageKey: "fixture", diagnosticCode: "grokbot.\(failureCode.rawValue)", recovery: .retry)), now: now)
            }
            return LiveProviderProjectionMapper.map(state, now: now)
        }
        func provider(_ body: String, meter: GrokBotMeteringSystem = .unknown, stale: Bool = false) throws -> Stage3ProviderProjection {
            let data = try GrokBotQuotaMapper.map(Data(body.utf8), fetchedAt: now.addingTimeInterval(-120), sessionScope: "SYNTHETIC-FIXTURE", meteringSystem: meter)
            return project(data, stale: stale)
        }
        func sharedProvider(_ week: String, status: String = "metered", stale: Bool = false, failureCode: FailureCode = .timedOut) throws -> Stage3ProviderProjection {
            let body = "{\"availability\":\"available\",\"weeklyIncludedStatus\":{\"status\":\"\(status)\"},\"weeklyIncludedUsage\":\(week),\"monthlyUsage\":{\"usedCents\":125,\"limitCents\":null,\"creditsUsedCents\":0}}"
            return project(try GrokSharedQuotaMapper.map(Data(body.utf8), fetchedAt: now.addingTimeInterval(-120), sessionScope: "SYNTHETIC-FIXTURE"), stale: stale, failureCode: failureCode)
        }
        let paid = try provider(#"{"usagePercent":27.5,"includedLimitZero":false,"nextResetTimestampUtc":"2026-10-22T15:00:00Z"}"#)
        let trial = try provider(#"{"usagePercent":100,"hasAvailableUsage":false,"includedLimitZero":true,"sandTrialExpiresAt":"2026-10-20T15:00:00Z"}"#)
        let shared = try sharedProvider(#"{"usedCents":3780,"budgetCents":10000,"resetsAt":"2026-10-22T15:00:00Z"}"#)
        let zeroBudget = try sharedProvider(#"{"usedCents":0,"budgetCents":0}"#)
        let over = try sharedProvider(#"{"usedCents":101,"budgetCents":100}"#)
        let unavailable = try sharedProvider(#"{}"#, status: "unavailable")
        let notApplicable = try sharedProvider(#"{}"#, status: "not_applicable")
        let sharedStale = try sharedProvider(#"{"usedCents":3780,"budgetCents":10000,"resetsAt":"2026-10-22T15:00:00Z"}"#, stale: true)
        let sharedServiceUnavailable = try sharedProvider(#"{"usedCents":3780,"budgetCents":10000,"resetsAt":"2026-10-22T15:00:00Z"}"#, stale: true, failureCode: .serviceUnavailable)
        let unknown = try provider(#"{"hasAvailableUsage":false}"#)
        let stale = try provider(#"{"usagePercent":27.5,"includedLimitZero":false,"nextResetTimestampUtc":"2026-10-22T15:00:00Z"}"#, stale: true)
        let reset = Stage3ProviderProjection(id: .openAI, rowState: .connected, dataState: .fresh(asOf: now), products: [
            .init(id: "fixture.credits", metrics: [.init(id: "fixture.precision", title: "Credits", value: .balance(amount: Decimal(string: "123.4567890123456789"), unlimited: false)),
                .init(id: "fixture.reset", title: "重置权益", value: .entitlement(availableCount: 2))])], capturedAt: now, origin: .fixture(scenarioID: "grokbot-offline-v1", fixedNow: now))
        let defaults = UserDefaults(suiteName: "io.github.obisoldbee.UsageButler.Preview.Copy.GrokBot.fixture")!
        defaults.setVolatileDomain([ProviderPreferenceKey.grokBotEnabled: false], forName: "Fixture")
        defaults.addSuite(named: "Fixture")
        let catalog = Stage3FixtureCatalog.projection(now: now)
        let model = MenuPanelViewModel(snapshot: .init(providers: catalog.providers + [paid], memory: catalog.memory))
        let settings = AnyView(SettingsRootView(model: model, onQuit: {}).defaultAppStorage(defaults))
        func quota(_ items: [Stage3ProviderProjection], caption: String = "离线样例 · 合成数据") -> AnyView {
            AnyView(VStack(alignment: .leading, spacing: 12) {
                Text(caption).font(.caption).foregroundStyle(.secondary)
                QuotaOverviewView(providers: items, onLoginProvider: { _, _ in .cancelled })
            }.padding(16).defaultAppStorage(defaults))
        }
        var scenes: [(String, AnyView, CGSize)] = [
            ("grokbot-settings-default-off", settings, .init(width: 760, height: 1600)),
            ("grokbot-source-unknown", quota([paid, reset]), .init(width: 540, height: 445)),
            ("grokbot-trial-exhausted", quota([trial]), .init(width: 540, height: 270)),
            ("grokbot-shared-weekly", quota([shared]), .init(width: 540, height: 240)),
            ("grokbot-shared-expanded", quota([shared]), .init(width: 540, height: 410)),
            ("grokbot-shared-zero-budget", quota([zeroBudget]), .init(width: 540, height: 240)),
            ("grokbot-shared-over-budget", quota([over]), .init(width: 540, height: 240)),
            ("grokbot-shared-unavailable", quota([unavailable]), .init(width: 540, height: 240)),
            ("grokbot-shared-not-applicable", quota([notApplicable]), .init(width: 540, height: 240)),
            ("grokbot-shared-stale", quota([sharedStale]), .init(width: 540, height: 300)),
            ("grokbot-shared-service-unavailable", quota([sharedServiceUnavailable]), .init(width: 540, height: 300)),
            ("grokbot-value-unknown", quota([unknown]), .init(width: 540, height: 260)),
            ("grokbot-stale-timeout", quota([stale]), .init(width: 540, height: 310))
        ]
        var capturedAt: Date?
        if let argument = CommandLine.arguments.first(where: { $0.hasPrefix("--shared-capture=") }) {
            let file = URL(fileURLWithPath: String(argument.dropFirst("--shared-capture=".count)))
            let handle = try FileHandle(forReadingFrom: file); defer { try? handle.close() }
            let bytes = try handle.read(upToCount: 65_537) ?? Data()
            guard bytes.count <= 65_536 else { throw PreviewError.invalidCapture }
            let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .millisecondsSince1970
            let capture = try decoder.decode(Capture.self, from: bytes)
            capturedAt = capture.fetchedAt
            let live = project(GrokSharedQuotaMapper.map(capture.usage, fetchedAt: capture.fetchedAt, sessionScope: "SANITIZED-CAPTURE"))
            scenes.append(("grokbot-shared-captured", quota([live], caption: "只读采集结果 · " + capture.fetchedAt.formatted(date: .omitted, time: .standard)), .init(width: 540, height: 240)))
            scenes.append(("grokbot-shared-captured-expanded", quota([live], caption: "只读采集结果 · " + capture.fetchedAt.formatted(date: .omitted, time: .standard)), .init(width: 540, height: 440)))
        }
        var receipts: [[String: Any]] = []
        var interactions: [[String: Any]] = []
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        NSApp.appearance = NSAppearance(named: .aqua)
        for (name, view, size) in scenes {
            let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height, alignment: .topLeading)
                .background(Color(nsColor: .windowBackgroundColor)).environment(\.locale, Locale(identifier: "zh_CN")))
            let window = NSWindow(contentRect: .init(origin: .zero, size: size), styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.title = "额度管家 · 离线样例"; window.contentView = host
            window.center(); window.orderFront(nil)
            // Painting only. No asynchronous behavior is asserted using this delay.
            try await Task.sleep(for: .milliseconds(400))
            host.layoutSubtreeIfNeeded(); host.displayIfNeeded()
            if name.hasSuffix("expanded") {
                window.makeKeyAndOrderFront(nil)
                let target = elements(host).first { ($0.read("accessibilityIdentifier") as? String)?.hasPrefix("quota.details.") == true }
                let pressed = target?.press() ?? false
                if !pressed {
                    // The first captured native scene fixes this row at y=145.
                    // SwiftUI may not expose its AX children until a system AX client attaches.
                    let local = host.convert(NSPoint(x: 180, y: host.isFlipped ? 145 : size.height - 145), to: nil)
                    for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                        if let event = NSEvent.mouseEvent(with: type, location: local, modifierFlags: [],
                            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                            context: nil, eventNumber: 0, clickCount: 1, pressure: 1) { NSApp.sendEvent(event) }
                    }
                }
                try await Task.sleep(for: .milliseconds(300)) // disclosure animation and painting only
                host.layoutSubtreeIfNeeded(); host.displayIfNeeded()
                let text = elements(host).compactMap { $0.read("accessibilityLabel") as? String }
                interactions.append(["scene":name,"accessibilityPressed":pressed,
                    "targetSource":pressed ? "accessibility" : "observed native value row, AppKit mouse events at x180 y145",
                    "monthlyDetailObserved":text.contains { $0.contains("本月额外用量限额") }])
            }
            guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { throw PreviewError.noPixels }
            host.cacheDisplay(in: host.bounds, to: bitmap)
            guard let png = bitmap.representation(using: .png, properties: [:]) else { throw PreviewError.noPixels }
            try png.write(to: output.appendingPathComponent(name + ".png"), options: .withoutOverwriting)
            receipts.append(["name":name,"fixture":!name.contains("captured"),"width":bitmap.pixelsWide,"height":bitmap.pixelsHigh,
                "sha256":SHA256.hash(data:png).map { String(format:"%02x",$0) }.joined()])
            window.close()
        }
        let result: [String: Any] = ["fixture":capturedAt == nil,"runtimeMode":"offlineFixture","fixtureNow":ISO8601DateFormatter().string(from: now),"bundleID":Bundle.main.bundleIdentifier!,"executable":Bundle.main.executableURL!.path,
            "pid":ProcessInfo.processInfo.processIdentifier,"providersInvoked":false,"realCredentialsRead":false,"helperEmbedded":false,
            "shortcutsInstalled":false,"persistentPreferencesWritten":false,"scenes":receipts,"interactions":interactions,
            "capturedObservationAt":capturedAt.map { ISO8601DateFormatter().string(from: $0) } ?? "none"]
        try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted,.sortedKeys]).write(to: output.appendingPathComponent("receipt.json"),options:.withoutOverwriting)
    }
    private struct Capture: Decodable { let usage: GrokSharedUsageObservation; let fetchedAt: Date }
    private struct Element {
        let object: NSObject
        func read(_ name: String) -> Any? { object.responds(to: NSSelectorFromString(name)) ? object.value(forKey: name) : nil }
        func press() -> Bool {
            let selector = NSSelectorFromString("accessibilityPerformPress")
            guard object.responds(to: selector), let implementation = object.method(for: selector) else { return false }
            return unsafeBitCast(implementation, to: (@convention(c) (AnyObject, Selector) -> Bool).self)(object, selector)
        }
    }
    private static func elements(_ root: NSObject) -> [Element] {
        var result: [Element] = [], queue = [root], visited = Set<ObjectIdentifier>()
        while let object = queue.popLast(), result.count < 1000 {
            guard visited.insert(ObjectIdentifier(object)).inserted else { continue }
            let element = Element(object: object); result.append(element)
            queue += element.read("accessibilityChildren") as? [NSObject] ?? []
        }
        return result
    }
    private enum PreviewError: Error { case noPixels, invalidCapture }
}
#endif
