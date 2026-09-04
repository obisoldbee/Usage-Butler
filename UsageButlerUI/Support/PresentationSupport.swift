import SwiftUI
import UsageButlerCore
import UsageButlerDomain

public enum ProviderPresentation {
    public static func displayName(for provider: ProviderID) -> String {
        switch provider {
        case .openAI: "OpenAI"
        case .miniMax: "MiniMax"
        case .ark: String(localized: "火山方舟")
        }
    }

    public static func cliName(for provider: ProviderID) -> String {
        switch provider {
        case .openAI: "codex"
        case .miniMax: "mmx"
        case .ark: "arkcli"
        }
    }

    public static func symbolName(for provider: ProviderID) -> String {
        switch provider {
        case .openAI: "circle.hexagongrid.fill"
        case .miniMax: "waveform"
        case .ark: "mountain.2.fill"
        }
    }

    public static func accentColor(for provider: ProviderID) -> Color {
        switch provider {
        case .openAI: .primary
        case .miniMax: Color(red: 0.96, green: 0.16, blue: 0.42)
        case .ark: Color(red: 0.10, green: 0.43, blue: 0.95)
        }
    }

    public static func failure(
        _ code: FailureCode
    ) -> (title: String, symbol: String, color: Color) {
        switch code {
        case .missingExecutable:
            (String(localized: "未找到 CLI"), "terminal", .orange)
        case .networkUnavailable:
            (String(localized: "网络不可用"), "wifi.exclamationmark", .orange)
        case .serviceUnavailable:
            (String(localized: "服务暂时不可用"), "exclamationmark.icloud", .orange)
        case .rateLimited:
            (String(localized: "请求过于频繁"), "clock.badge.exclamationmark", .orange)
        case .timedOut:
            (String(localized: "请求超时"), "clock.badge.exclamationmark", .orange)
        case .sessionEOF:
            (String(localized: "连接意外结束"), "bolt.horizontal.circle", .orange)
        case .schemaMismatch, .protocolViolation:
            (String(localized: "CLI 输出解析失败"), "doc.badge.gearshape", .orange)
        case .permissionDenied:
            (String(localized: "无法访问 CLI"), "lock.trianglebadge.exclamationmark", .red)
        case .cacheCorrupt, .cacheUnavailable:
            (String(localized: "本地缓存不可用"), "externaldrive.badge.exclamationmark", .orange)
        case .identityMismatch:
            (String(localized: "来源身份不匹配"), "person.crop.circle.badge.exclamationmark", .red)
        case .processFailed:
            (String(localized: "CLI 执行失败"), "terminal.fill", .orange)
        case .cancelled:
            (String(localized: "操作已取消"), "xmark.circle", .secondary)
        case .shutdown:
            (String(localized: "额度来源已停止"), "stop.circle", .secondary)
        case .authenticationRequired:
            (String(localized: "需要登录"), "key.fill", .orange)
        case .authenticationExpired:
            (String(localized: "登录已过期"), "exclamationmark.circle.fill", .red)
        case .unknown:
            (String(localized: "暂时无法获取额度"), "questionmark.circle", .secondary)
        }
    }

    public static func loginFeedbackMessage(
        _ result: ProviderLoginFeedback,
        for provider: ProviderID
    ) -> String {
        let name = displayName(for: provider)
        switch result {
        case .verifiedFresh:
            return String(localized: "\(name) 已重新登录并读取到最新额度")
        case .authorizationNotRenewed:
            return String(localized: "\(name) 登录流程已结束，但授权到期时间未更新")
        case let .verificationFailed(code):
            if let code {
                return String(localized: "\(name) 登录流程已结束，但额度验证失败：\(failure(code).title)")
            }
            return String(localized: "\(name) 登录流程已结束，但尚未读取到最新额度")
        case .rateLimited:
            return String(localized: "\(name) 登录请求过于频繁，请稍后再试")
        case .flowFailed:
            return String(localized: "\(name) 登录流程未完成，请重试")
        case .cancelled:
            return String(localized: "已取消 \(name) 登录")
        case .busy:
            return String(localized: "\(name) 正在执行其他操作，请稍后重试")
        case .disabled:
            return String(localized: "请先启用 \(name) 再登录")
        case .unsupported:
            return String(localized: "\(name) 当前不支持从此处启动登录")
        #if USAGE_BUTLER_FIXTURES
        case .offlineFixture:
            return String(localized: "本地 Fixture 不会启动真实登录")
        #endif
        case .failed:
            return String(localized: "\(name) 无法启动登录，请重试")
        }
    }
}

public enum ProviderActivityPresentation {
    public static func title(
        for activity: Stage3ProviderActivity
    ) -> String? {
        switch activity {
        case .idle: nil
        case .detecting: String(localized: "正在检测")
        case .refreshing: String(localized: "正在更新额度")
        case .loggingIn: String(localized: "正在登录")
        case .shuttingDown: String(localized: "正在退出")
        }
    }

    public static func detail(
        for provider: Stage3ProviderProjection
    ) -> String? {
        guard provider.activity.isInFlight else { return nil }
        if case let .stale(asOf) = provider.dataState {
            return String(
                localized: "暂时显示 \(asOf.formatted(date: .abbreviated, time: .shortened)) 的结果"
            )
        }
        return provider.products.isEmpty ? String(localized: "尚无成功数据") : nil
    }

    public static func usesProgressIndicator(
        _ activity: Stage3ProviderActivity
    ) -> Bool {
        switch activity {
        case .detecting, .refreshing, .loggingIn:
            true
        case .idle, .shuttingDown:
            false
        }
    }
}

public enum QuotaUpdatePresentation {
    /// Truthful last-refresh label for a provider header. Uses the aggregate
    /// data-state `asOf` (the fetchedAt of the retained snapshot); unknown
    /// yields no label instead of a fabricated time.
    public static func headerLabel(dataState: Stage3ProviderDataState) -> String? {
        switch dataState {
        case .unknown:
            nil
        case let .fresh(asOf), let .stale(asOf):
            String(localized: "更新于 \(asOf.formatted(date: .omitted, time: .shortened))")
        }
    }
}

/// Availability-band coloring for quota progress bars. The bar length keeps
/// showing the reported direction (remaining for OpenAI, used elsewhere), but
/// the tint always reflects the *available* share: [0,30] red, (30,60] yellow,
/// (60,100] green. Data older than the configured refresh interval plus ten
/// minutes counts as lost and renders gray; a manual-only cadence carries no
/// freshness expectation and never turns gray from age alone.
public enum QuotaAvailabilityBand: Equatable, Sendable {
    case low
    case medium
    case high
    case lost

    public static let lostGraceSeconds: TimeInterval = 600

    /// Returns nil when the value has no progress bar at all.
    public static func band(
        value: Stage3QuotaValue,
        asOf: Date?,
        now: Date,
        refreshIntervalSeconds: Int
    ) -> QuotaAvailabilityBand? {
        guard case let .percent(raw, direction) = value, raw.isFinite else {
            return nil
        }
        if refreshIntervalSeconds > 0 {
            let limit = TimeInterval(refreshIntervalSeconds) + lostGraceSeconds
            guard let asOf, now.timeIntervalSince(asOf) <= limit else {
                return .lost
            }
        }
        // Classify in percent space: `100 - raw` keeps integer reports exact,
        // whereas scaling to 0...1 first makes 1 - 0.7 land above 0.3.
        let reported = min(max(raw, 0), 100)
        let available = direction == .remaining ? reported : 100 - reported
        if available <= 30 { return .low }
        if available <= 60 { return .medium }
        return .high
    }
}

public enum ProviderStatusPriority {
    public static func visibleFailure(
        for provider: Stage3ProviderProjection
    ) -> FailureCode? {
        guard !provider.activity.isInFlight,
              let failureCode = provider.failureCode else {
            return nil
        }
        if case .expired = provider.rowState,
           failureCode == .authenticationExpired {
            return nil
        }
        return failureCode
    }

    public static func visiblePartial(
        for provider: Stage3ProviderProjection
    ) -> Stage3PartialDataState? {
        guard !provider.activity.isInFlight,
              visibleFailure(for: provider) == nil else {
            return nil
        }
        return provider.partialDataState
    }
}

public enum MemoryFieldPresentation {
    public static let orderedFieldIDs: [MemoryFieldID] = [
        .physical,
        .used,
        .cachedFiles,
        .swapUsed,
        .appMemory,
        .wired,
        .compressed
    ]

    public static func title(for field: MemoryFieldID) -> String {
        switch field {
        case .physical: String(localized: "物理内存")
        case .used: String(localized: "已使用内存")
        case .cachedFiles: String(localized: "已缓存文件")
        case .swapUsed: String(localized: "已使用的交换")
        case .appMemory: String(localized: "App 内存")
        case .wired: String(localized: "联动内存")
        case .compressed: String(localized: "被压缩")
        }
    }

    public static func value(bytes: UInt64?) -> String {
        guard let bytes else { return "—" }
        let gibibytes = Double(bytes) / 1_073_741_824
        if gibibytes >= 1 {
            return String(format: String(localized: "%.2f GB"), gibibytes)
        }
        let mebibytes = Double(bytes) / 1_048_576
        return String(format: String(localized: "%.1f MB"), mebibytes)
    }
}

extension Stage3ProviderRowState {
    public var settingsTitle: String {
        switch self {
        case .detecting: String(localized: "正在检测")
        case .connected: String(localized: "已连接")
        case .authenticationWarning: String(localized: "登录即将到期")
        case .requiresLogin: String(localized: "需要登录")
        case .expired: String(localized: "登录已过期")
        case .unavailable: String(localized: "暂时无法判断状态")
        }
    }

    var authenticationWarningTitle: String? {
        self == .authenticationWarning ? settingsTitle : nil
    }
}
