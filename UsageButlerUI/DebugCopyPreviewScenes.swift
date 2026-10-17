#if DEBUG && USAGE_BUTLER_FIXTURES
import AppKit
import Combine
import SwiftUI
import UsageButlerCore
import UsageButlerDomain

/// Native product views, supplied with the same read-only or sample input for
/// both revisions. This helper has no providers, collectors, IPC or writes to
/// product preferences, and is absent from Release builds.
@MainActor public enum CopyPreviewScenes {
    public static var rangeProbe: ProcessNetworkViewModel?
    public static func scenes(history: BackgroundNetworkViewModel, detail: BackgroundNetworkViewModel,
                              notes: ApplicationNoteStore, now: Date) async -> [(String, AnyView, CGSize)] {
        let fixture = Stage3FixtureCatalog.projection(now: now)
        let providers = fixture.providers.map {
            Stage3ProviderProjection(id: $0.id, rowState: $0.rowState, dataState: .fresh(asOf: now),
                loginMethod: $0.loginMethod, planLevel: $0.planLevel, products: $0.products,
                capturedAt: now, origin: .runtime)
        }
        let f = fixture.memory
        let memory = Stage3MemoryProjection(pressure: f.pressure, fields: f.fields, history: f.history,
            capturedAt: now, origin: .runtime)
        func menu(_ values: [Stage3ProviderProjection] = []) -> MenuPanelViewModel {
            MenuPanelViewModel(snapshot: .init(providers: values.isEmpty ? providers : values, memory: memory),
                applicationNotes: notes,
                networkClock: { .init(wallTime: now, monotonicTime: .init(nanoseconds: 1_000_000_000_000)) })
        }
        func panel(_ model: MenuPanelViewModel, page: MenuPage) -> AnyView {
            model.selectedPage = page
            return AnyView(MenuPanelRootView(model: model, activityMonitorState: .idle,
                onOpenActivityMonitor: {}, onOpenSettingsFallback: {}))
        }
        let general = menu(); general.settingsPage = .general
        let network = menu(); network.settingsPage = .network
        network.backgroundNetwork.desired = true
        network.backgroundNetwork.registration = "enabled"
        network.backgroundNetwork.status = history.status
        network.backgroundNetwork.onEnabled = { _ in }
        network.backgroundNetwork.onRule = { _ in }
        network.applyNetworkSnapshot(NetworkFixtureCatalog.snapshot(now: now, collecting: false))
        let empty = providers.map {
            Stage3ProviderProjection(id: $0.id, rowState: .connected,
                products: [.init(id: "empty", title: "Coding Plan", metrics: [])], capturedAt: now, origin: .runtime)
        }
        let failed = providers.map {
            Stage3ProviderProjection(id: $0.id, rowState: .unavailable, failureCode: .identityMismatch,
                automaticRetry: false, products: [], capturedAt: now, origin: .runtime)
        }
        let countOnly = Stage3ProviderProjection(id: .openAI, rowState: .connected,
            products: [.init(id: "count-only", metrics: [.init(id: "reset-count-only", title: "重置权益",
                windowBadge: "重置权益", value: .entitlement(availableCount: 2))])], capturedAt: now, origin: .runtime)
        let process = ProcessNetworkViewModel(applicationNotes: notes)
        let monotonic = MonotonicInstant(nanoseconds: DispatchTime.now().uptimeNanoseconds)
        let identity = ProcessNetworkApplicationIdentity(key: "copy-preview-cli", name: "ChatGPT",
            installationPath: "/Example/codex", evidence: .executable)
        notes.save("codex.cli", for: identity)
        let epoch = CounterEpoch(rawValue: 1)
        var samples: [NetworkRateSample] = []
        for index in 0..<60 {
            let timestamp = now.addingTimeInterval(Double(index - 59))
            let instant = MonotonicInstant(nanoseconds: monotonic.nanoseconds - UInt64(59 - index) * 1_000_000_000)
            let upload = Double(20 + index % 10) * 1_024
            let download = Double(200 + index % 20) * 1_024
            let sample = NetworkRateSample(captureSessionID: CaptureSessionID(rawValue: "copy-preview"), counterEpoch: epoch,
                sampledAt: timestamp, sampledMonotonic: instant, uploadBytesPerSecond: upload,
                downloadBytesPerSecond: download, interfaceName: identity.key, samplingInterval: 1)
            samples.append(sample)
        }
        let counters = [ProcessNetworkCounter(identity: .init(pid: 123, instanceID: "copy-preview-instance", name: "codex",
            executablePath: "/Example/codex", application: identity), bytes: .init(upload: 2_048_000, download: 20_480_000))]
        let application = ProcessNetworkApplication(identity: identity, processes: counters, presence: .present,
            rate: .init(uploadBytesPerSecond: 30_720, downloadBytesPerSecond: 225_280, asOf: now, window: .seconds(1)),
            total: .init(bytes: .init(upload: 2_048_000, download: 20_480_000), since: now.addingTimeInterval(-60),
                         sinceMonotonic: .init(nanoseconds: monotonic.nanoseconds - 60_000_000_000)),
            history: samples, sampledAt: now, sampledMonotonic: monotonic, historyTruncated: false)
        let snapshot = ProcessNetworkSnapshot(sessionID: .init(rawValue: "copy-preview"), sequence: 60, state: .active,
            issue: nil, applications: [identity.key: application], sampledAt: now, sampledMonotonic: monotonic,
            truncated: false, lostFrames: 0)
        process.apply(snapshot); process.range = .oneMinute
        let processDetail = ProcessNetworkViewModel(applicationNotes: notes)
        processDetail.apply(snapshot); processDetail.range = .oneMinute; processDetail.selected = identity.key
        rangeProbe = processDetail
        let longDetail = ProcessNetworkViewModel(applicationNotes: notes)
        let longIdentity = detail.result?.applications.first?.identity ?? identity
        let longApplication = ProcessNetworkApplication(identity: longIdentity, processes: [], presence: .present,
            rate: application.rate, total: application.total, history: [], sampledAt: now, sampledMonotonic: monotonic, historyTruncated: false)
        longDetail.apply(ProcessNetworkSnapshot(sessionID: snapshot.sessionID, sequence: snapshot.sequence, state: .active,
            issue: nil, applications: [longIdentity.key: longApplication], sampledAt: now, sampledMonotonic: monotonic,
            truncated: false, lostFrames: 0))
        longDetail.selected = longIdentity.key
        longDetail.range = .oneHour
        longDetail.onLongHistory = { _, seconds in
            let span = HistoryRange.recent(days: seconds / 86_400, now: now)
            let curve = (detail.result?.curve ?? []).filter { $0.start >= span.start && $0.end <= span.end }
            return .init(range: span, applications: [], totalApplications: 0, page: 0,
                curve: curve, days: [], events: [], coverage: detail.result?.coverage ?? .init())
        }
        longDetail.setLongHistoryVisible(true)
        if longDetail.longHistoryLoading {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                var subscription: AnyCancellable?
                subscription = longDetail.$longHistoryLoading.filter { !$0 }.prefix(1).sink { _ in
                    continuation.resume(); subscription = nil
                }
            }
        }
        var pages: [(String, AnyView, CGSize)] = [
            ("history", AnyView(NetworkHistoryWindowRootView(model: history)), .init(width: 900, height: 760)),
            ("history-narrow", AnyView(NetworkHistoryWindowRootView(model: history)), .init(width: 560, height: 760)),
            ("history-detail", AnyView(NetworkHistoryWindowRootView(model: detail)), .init(width: 900, height: 960)),
            ("network-settings", AnyView(SettingsRootView(model: network, onQuit: {})), .init(width: 760, height: 1000)),
            ("general-settings", AnyView(SettingsRootView(model: general, onQuit: {})), .init(width: 760, height: 1180)),
            ("process-list", AnyView(ScrollView { ProcessNetworkApplicationsView(model: process, now: now).padding(16) }), .init(width: 540, height: 720)),
            ("process-long-history", AnyView(ScrollView { ProcessNetworkApplicationsView(model: longDetail, now: now).padding(16) }), .init(width: 540, height: 1000)),
            ("process-detail", AnyView(ScrollView { ProcessNetworkApplicationsView(model: processDetail, now: now).padding(16) }), .init(width: 540, height: 1000)),
            ("quota-count-only", panel(menu([countOnly]), page: .quota), .init(width: 540, height: 430)),
            ("quota", panel(menu(), page: .quota), .init(width: 540, height: 760)),
            ("quota-empty", panel(menu(empty), page: .quota), .init(width: 540, height: 760)),
            ("quota-error", panel(menu(failed), page: .quota), .init(width: 540, height: 760)),
            ("memory", panel(menu(), page: .memory), .init(width: 540, height: 760))
        ]
        if let identity = detail.result?.applications.first?.identity {
            pages.append(("application-note", AnyView(ApplicationNoteEditor(identity: identity, notes: notes)),
                          .init(width: 484, height: 330)))
        }
        return pages
    }
    public static func waitForHistory(_ model: BackgroundNetworkViewModel) async {
        await model.currentQueryTask?.value
    }
}
#endif
