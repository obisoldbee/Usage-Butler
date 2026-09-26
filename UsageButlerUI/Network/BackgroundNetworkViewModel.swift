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
    @Published public var registration = "notRegistered"
    @Published public var status: BackgroundNetworkStatus?
    @Published public var desired = false
    @Published public var changing = false
    @Published public var serviceIssue: String?
    @Published public var configuredRule = HistoryUploadRule()
    @Published public var range: Range = .week { didSet { page = 0; reload() } }
    @Published public var selectedApplication: Int64? { didSet { page = 0; reload() } }
    @Published public var eventKind: String? { didSet { page = 0; reload() } }
    @Published public var page = 0
    @Published public private(set) var result: HistoryQueryResult?
    @Published public private(set) var loading = false
    @Published public private(set) var queryIssue: String?
    public var onEnabled: ((Bool) async -> Void)?
    public var onOpenApproval: (() -> Void)?
    public var onOpenHistory: (() -> Void)?
    public var onRefreshService: (() async -> Void)?
    public var onRule: ((HistoryUploadRule) async throws -> Void)?
    public var onQuery: ((HistoryRange, Int64?, Int, String?) async throws -> HistoryQueryResult)?
    private var revision: UInt64 = 0
    private var task: Task<Void, Never>?
    var currentQueryTask: Task<Void, Never>? { task }
    private var frozenRange: HistoryRange?
    public init() {}
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
    public func reload(freezeNewRange: Bool = true) {
        revision &+= 1; let token = revision; task?.cancel()
        guard let onQuery else { return }
        if freezeNewRange || frozenRange == nil { frozenRange = .recent(days: range.days) }
        guard let requested = frozenRange else { return }
        let application = selectedApplication, page = page, kind = eventKind
        loading = true; queryIssue = nil; result = nil
        task = Task { [weak self] in
            do {
                let result = try await onQuery(requested, application, page, kind)
                guard let self, token == revision, !Task.isCancelled else { return }
                self.result = result; loading = false
            } catch {
                guard let self, token == revision, !Task.isCancelled else { return }
                queryIssue = "历史暂不可读。记录可能尚未创建，或数据库正在使用、版本不兼容。\(Self.code(error))"
                loading = false
            }
        }
    }
    public func nextPage() { page += 1; reload(freezeNewRange: false) }
    public func previousPage() { page = max(0, page - 1); reload(freezeNewRange: false) }
    public func closeHistory() {
        revision &+= 1; task?.cancel(); task = nil; result = nil; loading = false; queryIssue = nil
    }
    public static func code(_ error: Error) -> String {
        if case let BackgroundNetworkWire.Failure.remote(code) = error { return code }
        return "history.query-unavailable"
    }
}
