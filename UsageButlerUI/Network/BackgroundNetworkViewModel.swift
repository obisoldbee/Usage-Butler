import Combine
import Foundation
import UsageButlerDomain

@MainActor
public final class BackgroundNetworkViewModel: ObservableObject {
    public enum Range: String, CaseIterable, Identifiable {
        case hour, day, week, fortnight
        public var id: String { rawValue }
        public var title: String { switch self { case .hour: "1小时"; case .day: "24小时"; case .week: "7天"; case .fortnight: "14天" } }
        public var days: Double { switch self { case .hour: 1 / 24; case .day: 1; case .week: 7; case .fortnight: 14 } }
    }
    public enum ReturnFocus: Hashable {
        case application(Int64)
        case event(Int64)
        case summary
    }
    @Published public var registration = "unknown"
    @Published public var status: BackgroundNetworkStatus?
    @Published public var desired = false
    @Published public var changing = false
    @Published public var serviceIssue: String?
    @Published public var configuredRule = HistoryUploadRule()
    @Published public var range: Range = .week { didSet { if range != oldValue { reload() } } }
    @Published public var selectedApplication: String? { didSet { selectionChanged(from: oldValue) } }
    @Published public var eventKind: String? {
        didSet {
            guard eventKind != oldValue, !restoringSummary else { return }
            resetScope()
        }
    }
    @Published public var search = "" {
        didSet { if search != oldValue, !restoringSummary { resetScope(debounce: true) } }
    }
    @Published public var page = 0
    @Published public private(set) var returnFocus: ReturnFocus?
    @Published public private(set) var navigationNotice: String?
    @Published public private(set) var result: HistoryQueryResult?
    @Published public private(set) var loading = false
    @Published public private(set) var queryIssue: String?
    public var onEnabled: ((Bool) async -> Void)?
    public var onOpenApproval: (() -> Void)?
    public var onOpenHistory: (() -> Void)?
    public var onRefreshService: (() async -> Void)?
    public var onRule: ((HistoryUploadRule) async throws -> Void)?
    public var onQuery: ((HistoryQueryRequest) async throws -> HistoryQueryResult)?
    private var revision: UInt64 = 0
    private var task: Task<Void, Never>?
    var currentQueryTask: Task<Void, Never>? { task }
    private var frozenRange: HistoryRange?
    private enum Origin {
        case application(String)
        case event(Int64)
    }
    private struct SummaryContext {
        let page: Int
        let range: HistoryRange
        let eventKind: String?
        let search: String
        let query: HistoryQueryContext?
        let origin: Origin
    }
    private var queryContext: HistoryQueryContext?
    private var openingOrigin: Origin?
    private var summaryContext: SummaryContext?
    private var pendingReturn: SummaryContext?
    private var restoringSummary = false
    private let now: () -> Date
    private let pause: @MainActor (Duration) async throws -> Void
    public init(now: @escaping () -> Date = { Date() },
                pause: @escaping @MainActor (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) {
        self.now = now; self.pause = pause
    }
    public var serviceTitle: String {
        if changing { return "正在更新后台状态…" }
        if registration == "requiresApproval" { return "等待系统允许后台运行" }
        if let issue = serviceIssue ?? status?.coverage.issue { return "后台暂不可用 · \(issue)" }
        if registration == "notFound" { return "后台组件不可用" }
        if registration == "notRegistered" { return "后台已停止 · 保留已提交历史" }
        guard let status else { return "正在连接后台采集服务…" }
        if let seconds = status.recoverySeconds { return "来源暂时中断 · 约\((seconds + 59) / 60)分钟后重试" }
        switch status.sourceState {
        case .active: return "后台正在采集 · 退出主程序后继续"
        case .partial: return "后台部分采样不可用"
        case .starting: return "后台正在建立基线"
        case .stopped: return "后台采集已停止"
        case .unavailable: return "后台来源暂不可用"
        }
    }
    public func setEnabled(_ value: Bool) { Task { await onEnabled?(value) } }
    public func refreshService() { Task { await onRefreshService?() } }
    private func resetScope(debounce: Bool = false) {
        page = 0; pendingReturn = nil; queryContext = nil; reload(freezeNewRange: false, debounce: debounce)
    }
    public func openApplication(_ app: HistoryApplicationSummary) {
        openingOrigin = .application(app.identity.key); selectedApplication = app.identity.key
    }
    public func openEvent(_ event: HistoryUploadEvent) {
        openingOrigin = .event(event.id); selectedApplication = event.applicationKey
    }
    public func reload(freezeNewRange: Bool = true) { reload(freezeNewRange: freezeNewRange, debounce: false) }
    private func reload(freezeNewRange: Bool, debounce: Bool) {
        revision &+= 1; let token = revision; task?.cancel()
        returnFocus = nil; navigationNotice = nil
        if freezeNewRange || frozenRange == nil {
            frozenRange = .recent(days: range.days, now: now())
            page = 0; summaryContext = nil; pendingReturn = nil; queryContext = nil
        }
        guard let onQuery, let requested = frozenRange else { return }
        let request = HistoryQueryRequest(range: requested, applicationKey: selectedApplication, page: page,
            eventKind: eventKind, search: search, context: queryContext)
        loading = false; queryIssue = nil; result = nil
        guard request.isValid else { queryIssue = "搜索文字过长，请缩短后重试。"; return }
        loading = true
        let pause = pause
        task = Task { [weak self] in
            do {
                if debounce { try await pause(.milliseconds(200)) }
                let delays: [Duration] = [.milliseconds(100), .milliseconds(200), .milliseconds(400), .milliseconds(800)]
                var attempt = 0
                let result: HistoryQueryResult
                while true {
                    guard self?.revision == token, !Task.isCancelled else { return }
                    do { result = try await onQuery(request); break }
                    catch {
                        guard self?.revision == token, !Task.isCancelled else { return }
                        guard ["history.query-busy", "history.request-busy"].contains(Self.code(error)), attempt < delays.count else { throw error }
                        try await pause(delays[attempt]); attempt += 1
                    }
                }
                guard let self, token == revision, !Task.isCancelled else { return }
                guard result.satisfies(request) else { throw HistoryQueryFailure.incompatible }
                self.result = result; queryContext = result.contract?.context; loading = false
                if let context = pendingReturn, selectedApplication == nil {
                    switch context.origin {
                    case let .application(key):
                        returnFocus = result.applications.first { $0.identity.key == key }.map { .application($0.id) } ?? .summary
                    case let .event(id):
                        returnFocus = result.events.contains { $0.id == id } ? .event(id) : .summary
                    }
                    if returnFocus == .summary { navigationNotice = "原条目当前不在此页，已保留原分页；可刷新查询。" }
                    pendingReturn = nil
                }
            } catch {
                guard let self, token == revision, !Task.isCancelled else { return }
                switch Self.code(error) {
                case HistoryQueryFailure.changed.code: queryIssue = "查询中的条目或顺序已变化，请刷新后重新浏览。"
                case HistoryQueryFailure.expired.code: queryIssue = "本次查询已过期或后台已重启，请刷新后重新浏览。"
                case HistoryQueryFailure.incompatible.code: queryIssue = "后台不支持当前历史查询，请更新后台组件或重新连接。"
                case "history.query-busy", "history.request-busy": queryIssue = "历史查询暂时繁忙，请点击刷新重试。"
                default: queryIssue = "历史暂不可读。记录可能尚未创建，或数据库正在使用、版本不兼容。\(Self.code(error))"
                }
                loading = false
                if pendingReturn != nil { returnFocus = .summary; pendingReturn = nil }
            }
        }
    }
    private func selectionChanged(from previous: String?) {
        defer { openingOrigin = nil }
        guard selectedApplication != previous else { return }
        pendingReturn = nil
        if previous == nil, let application = selectedApplication, let frozenRange {
            summaryContext = .init(page: page, range: frozenRange, eventKind: eventKind, search: search,
                query: queryContext, origin: openingOrigin ?? .application(application))
            page = 0; queryContext = nil
        } else if selectedApplication == nil, let context = summaryContext {
            page = context.page; frozenRange = context.range; queryContext = context.query
            restoringSummary = true; eventKind = context.eventKind; search = context.search; restoringSummary = false
            pendingReturn = context; summaryContext = nil
        } else { page = 0; queryContext = nil }
        reload(freezeNewRange: false)
    }
    public func nextPage() { page = min(1023, page + 1); pendingReturn = nil; reload(freezeNewRange: false) }
    public func previousPage() { page = max(0, page - 1); pendingReturn = nil; reload(freezeNewRange: false) }
    public func closeHistory() {
        revision &+= 1; task?.cancel(); task = nil; result = nil; loading = false; queryIssue = nil
        summaryContext = nil; pendingReturn = nil; queryContext = nil; frozenRange = nil; returnFocus = nil; navigationNotice = nil
    }
    public static func code(_ error: Error) -> String {
        if let failure = error as? HistoryQueryFailure { return failure.code }
        if case let BackgroundNetworkWire.Failure.remote(code) = error { return code }
        return "history.query-unavailable"
    }
}
