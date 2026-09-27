import Combine
import Foundation
import UsageButlerCore
import UsageButlerDomain

@MainActor
public final class ProcessNetworkViewModel: ObservableObject {
    public enum Sort: String, CaseIterable { case upload, download, name }
    public enum ObservationState: Equatable {
        case connecting, requiresApproval, notFound, unavailable, stopped
        case observing(ProcessNetworkState)
    }
    @Published public private(set) var observationState: ObservationState = .connecting
    public var currentState: ProcessNetworkState? {
        switch observationState {
        case let .observing(state): state
        case .stopped: .stopped
        case .unavailable, .requiresApproval, .notFound: .unavailable
        case .connecting: nil
        }
    }
    public var observationTitle: String {
        switch observationState {
        case .connecting: "正在连接后台来源 · 等待采样"
        case .requiresApproval: "等待系统允许后台运行 · 当前未观察"
        case .notFound: "后台组件不可用 · 尚未取得新采样"
        case .unavailable: "应用来源暂不可用 · 接口统计独立运行"
        case .stopped, .observing(.stopped): "应用采集已停止 · 可在设置 → 网络中开启"
        case .observing(.starting): "正在建立应用采样基线…"
        case .observing(.active): "正在采集系统可见进程"
        case .observing(.partial): "应用采样不完整 · 当前速率未知"
        case .observing(.unavailable): "应用来源暂不可用 · 接口统计独立运行"
        }
    }
    @Published public private(set) var snapshot: ProcessNetworkSnapshot?
    /// Export the current observation state with the original evidence. No
    /// first sample is invented, and old timestamps/sequence/history stay old.
    public var snapshotForExport: ProcessNetworkSnapshot? {
        guard let snapshot else { return nil }
        let state = currentState ?? .unavailable
        guard state != snapshot.state else { return snapshot }
        return .init(sessionID: snapshot.sessionID, sequence: snapshot.sequence, state: state,
            issue: state == .stopped ? nil : "background-service-unavailable", applications: snapshot.applications,
            sampledAt: snapshot.sampledAt, sampledMonotonic: snapshot.sampledMonotonic,
            truncated: snapshot.truncated, lostFrames: snapshot.lostFrames)
    }
    @Published public var search = "" { didSet { rebuildRows() } }
    @Published public var sort: Sort = .upload { didSet { rebuildRows() } }
    @Published public var onlyWatched = false { didSet { rebuildRows() } }
    @Published public private(set) var watched: Set<String> = []
    @Published public var selected: String? { didSet { reloadLongHistory() } }
    @Published public var range: NetworkTrendRange = .oneHour { didSet { reloadLongHistory() } }
    @Published public private(set) var longHistory: HistoryQueryResult?
    @Published public private(set) var longHistoryIssue: String?
    @Published public private(set) var longHistoryLoading = false
    public var onLongHistory: ((String, TimeInterval) async throws -> HistoryQueryResult)?
    private var longHistoryRevision: UInt64 = 0
    private var longHistoryTask: Task<Void, Never>?
    private var longHistoryVisible = false
    private var lastLongHistoryRead: UInt64 = 0
    @Published public private(set) var rows: [ProcessNetworkApplication] = []
    public var returnAnchor: String?
    private var revision: UInt64 = 0
    private var chartCache = NetworkChartProjectionCache()
    public init() {}
    public func apply(_ snapshot: ProcessNetworkSnapshot) {
        self.snapshot = snapshot; observationState = .observing(snapshot.state); revision &+= 1; rebuildRows()
        let now = DispatchTime.now().uptimeNanoseconds
        if longHistoryVisible, !longHistoryLoading, now - lastLongHistoryRead >= 5_000_000_000 { reloadLongHistory() }
    }
    public func setLongHistoryVisible(_ visible: Bool) {
        longHistoryVisible = visible
        if !visible { longHistoryRevision &+= 1; longHistoryTask?.cancel(); longHistoryTask = nil; longHistoryLoading = false }
        else { reloadLongHistory() }
    }
    private func reloadLongHistory() {
        longHistoryRevision &+= 1; let token = longHistoryRevision
        longHistoryTask?.cancel(); longHistoryLoading = false
        guard let selected, range != .oneMinute, let onLongHistory, longHistoryVisible else { longHistory = nil; return }
        let duration = range.duration
        if longHistory?.applications.first?.identity.key != selected
            || longHistory.map({ abs($0.range.end.timeIntervalSince($0.range.start) - duration) > 1 }) == true { longHistory = nil }
        longHistoryLoading = true; longHistoryIssue = nil; lastLongHistoryRead = DispatchTime.now().uptimeNanoseconds
        longHistoryTask = Task { [weak self] in
            do {
                let result = try await onLongHistory(selected, duration)
                guard let self, token == longHistoryRevision, !Task.isCancelled else { return }
                longHistory = result; longHistoryLoading = false
            } catch {
                guard let self, token == longHistoryRevision, !Task.isCancelled else { return }
                longHistory = nil; longHistoryIssue = "分钟历史暂不可读，请稍后刷新。"; longHistoryLoading = false
            }
        }
    }
    public func markBackgroundUnavailable(stopped: Bool) {
        setObservationState(stopped ? .stopped : .unavailable)
    }
    public func setObservationState(_ state: ObservationState) {
        observationState = state; rebuildRows()
    }
    public func toggleWatch(_ key: String) {
        guard snapshot?.applications[key]?.identity.evidence != .unknown else { return }
        if watched.contains(key) { watched.remove(key) }
        else if watched.count < 256 { watched.insert(key) }
        rebuildRows()
    }
    public func open(_ key: String) { returnAnchor = key; selected = key }
    public func back() { selected = nil }
    public func frame(for app: ProcessNetworkApplication, now: Date) -> NetworkTrendFrame {
        chartCache.frame(samples: app.history, revision: revision, interface: app.identity.key,
                         now: now, window: range.duration)
    }
    public func fresh(_ app: ProcessNetworkApplication, now: Date) -> Bool {
        ProcessNetworkFreshness.isFresh(app, state: currentState,
            now: .init(nanoseconds: DispatchTime.now().uptimeNanoseconds))
    }
    private func rebuildRows() {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        let candidates = (snapshot?.applications.values.map { $0 } ?? []).filter {
            (!onlyWatched || watched.contains($0.identity.key))
            && (query.isEmpty || $0.identity.name.localizedCaseInsensitiveContains(query)
                || $0.processes.contains { $0.identity.name.localizedCaseInsensitiveContains(query) })
        }
        rows = candidates.sorted { a, b in
            if sort == .name {
                let order = a.identity.name.localizedStandardCompare(b.identity.name)
                return order == .orderedSame ? a.identity.key < b.identity.key : order == .orderedAscending
            }
            let aValue = currentState == .active && a.presence == .present ? (sort == .upload ? a.rate?.uploadBytesPerSecond : a.rate?.downloadBytesPerSecond) : nil
            let bValue = currentState == .active && b.presence == .present ? (sort == .upload ? b.rate?.uploadBytesPerSecond : b.rate?.downloadBytesPerSecond) : nil
            if aValue != bValue {
                if let aValue, let bValue { return aValue > bValue }
                return aValue != nil
            }
            return a.identity.key < b.identity.key
        }
    }
}
