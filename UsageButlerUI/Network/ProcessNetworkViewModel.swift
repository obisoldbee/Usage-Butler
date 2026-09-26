import Combine
import Foundation
import UsageButlerCore
import UsageButlerDomain

@MainActor
public final class ProcessNetworkViewModel: ObservableObject {
    public enum Sort: String, CaseIterable { case upload, download, name }
    @Published public private(set) var snapshot: ProcessNetworkSnapshot?
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
        self.snapshot = snapshot; revision &+= 1; rebuildRows()
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
        guard let prior = snapshot else { return }
        apply(.init(sessionID: prior.sessionID, sequence: prior.sequence, state: stopped ? .stopped : .unavailable,
            issue: stopped ? nil : "background-service-unavailable", applications: prior.applications,
            sampledAt: prior.sampledAt, sampledMonotonic: prior.sampledMonotonic,
            truncated: prior.truncated, lostFrames: prior.lostFrames))
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
        ProcessNetworkFreshness.isFresh(app, state: snapshot?.state,
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
            let aValue = snapshot?.state == .active && a.presence == .present ? (sort == .upload ? a.rate?.uploadBytesPerSecond : a.rate?.downloadBytesPerSecond) : nil
            let bValue = snapshot?.state == .active && b.presence == .present ? (sort == .upload ? b.rate?.uploadBytesPerSecond : b.rate?.downloadBytesPerSecond) : nil
            if aValue != bValue {
                if let aValue, let bValue { return aValue > bValue }
                return aValue != nil
            }
            return a.identity.key < b.identity.key
        }
    }
}
