import SwiftUI
import UsageButlerCore
import UsageButlerDomain

public struct QuotaOverviewView: View {
    let providers: [Stage3ProviderProjection]
    let onLoginProvider: (
        ProviderID,
        ProviderLoginRequest
    ) async -> ProviderLoginFeedback

    public init(
        providers: [Stage3ProviderProjection],
        onLoginProvider: @escaping (
            ProviderID,
            ProviderLoginRequest
        ) async -> ProviderLoginFeedback
    ) {
        self.providers = providers
        self.onLoginProvider = onLoginProvider
    }

    public var body: some View {
        LazyVStack(spacing: 12) {
            if providers.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "gauge.with.dots.needle.0percent")
                        .font(.largeTitle)
                        .foregroundStyle(.secondary)
                    Text("没有启用额度来源")
                        .font(.headline)
                    Text("在设置中选择额度来源")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 300)
            } else {
                ForEach(providers) { provider in
                    ProviderQuotaCard(
                        provider: provider,
                        onLogin: { request in
                            await onLoginProvider(provider.id, request)
                        }
                    )
                }
            }
        }
        .frame(maxWidth: .infinity)
    }
}

private struct ProviderQuotaCard: View {
    let provider: Stage3ProviderProjection
    let onLogin: (ProviderLoginRequest) async -> ProviderLoginFeedback

    @State private var isLoginInFlight = false
    @State private var isLoginCancellationInFlight = false
    @State private var loginNotice: ProviderQuotaLoginNotice?
    @AppStorage(ProviderPreferenceKey.globalRefreshSeconds)
    private var globalRefreshSeconds = 300
    @AppStorage private var refreshOverrideSeconds: Int

    init(
        provider: Stage3ProviderProjection,
        onLogin: @escaping (ProviderLoginRequest) async -> ProviderLoginFeedback
    ) {
        self.provider = provider
        self.onLogin = onLogin
        self._refreshOverrideSeconds = AppStorage(
            wrappedValue: -1,
            ProviderPreferenceKey.refreshOverrideSecondsKey(for: provider.id)
        )
    }

    private var effectiveRefreshIntervalSeconds: Int {
        ProviderRefreshOverride
            .validated(storedSeconds: refreshOverrideSeconds)
            .resolving(
                globalFrequency: .validated(storedSeconds: globalRefreshSeconds)
            )
            .rawValue
    }

    private var accent: Color {
        ProviderPresentation.accentColor(for: provider.id)
    }

    @ViewBuilder
    private var providerIcon: some View {
        if let assetName = ProviderPresentation.imageAssetName(for: provider.id) {
            Image(assetName)
                .resizable()
                .scaledToFit()
                .accessibilityLabel(ProviderPresentation.displayName(for: provider.id))
        } else {
            Image(systemName: ProviderPresentation.symbolName(for: provider.id))
                .font(.title2)
                .foregroundStyle(accent)
                .accessibilityLabel(ProviderPresentation.displayName(for: provider.id))
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let recovery = headerRecovery {
                HStack(spacing: 10) {
                    providerIcon
                        .frame(width: 28, height: 28)

                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 8) {
                            Text(ProviderPresentation.displayName(for: provider.id))
                                .font(.headline)

                            if let planLevel = provider.planLevel {
                                PlanBadge(badge: planLevel)
                            }
                        }

                        ProviderQuotaHeaderRecoveryView(recovery: recovery)
                    }
                    .layoutPriority(1)

                    Spacer(minLength: 4)

                    if let actionTitle = recovery.actionTitle {
                        loginButton(title: actionTitle)
                            .buttonStyle(.borderedProminent)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
            } else {
                HStack(spacing: 10) {
                    providerIcon
                        .frame(width: 28, height: 28)

                    Text(ProviderPresentation.displayName(for: provider.id))
                        .font(.headline)

                    if let planLevel = provider.planLevel {
                        PlanBadge(badge: planLevel)
                    }

                    if let warningTitle = provider.rowState.authenticationWarningTitle {
                        if provider.loginMethod != nil {
                            loginButton(
                                title: warningTitle,
                                systemImage: "exclamationmark.triangle.fill"
                            )
                            .buttonStyle(.bordered)
                            .tint(.orange)
                            .font(.caption2)
                            .foregroundStyle(.orange)
                            .disabled(
                                provider.activity.isInFlight
                                    && provider.activity != .loggingIn
                            )
                            .help(reauthorizationHelp)
                        } else {
                            Label(warningTitle, systemImage: "exclamationmark.triangle.fill")
                                .font(.caption2)
                                .foregroundStyle(.orange)
                                .fixedSize()
                        }
                    }

                    if let updateLabel = QuotaUpdatePresentation.headerLabel(
                        dataState: provider.dataState
                    ) {
                        Text(updateLabel)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }

                    if provider.activity == .refreshing {
                        ProgressView()
                            .controlSize(.small)
                            .scaleEffect(0.7)
                            .frame(width: 14, height: 14)
                            .accessibilityLabel(
                                ProviderActivityPresentation.title(for: .refreshing)
                                    ?? String(localized: "正在更新额度")
                            )
                    }

                    Spacer()
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
            }

            if hasBodyContent {
                Divider()
                    .padding(.horizontal, 14)

                if shouldShowStatusRow {
                    ProviderQuotaStateRow(provider: provider)
                    if !provider.products.isEmpty {
                        Divider()
                            .padding(.horizontal, 14)
                    }
                }

                ForEach(Array(provider.products.enumerated()), id: \.element.id) { index, product in
                    if index > 0 {
                        Divider()
                            .padding(.horizontal, 10)
                    }

                    ProductQuotaSection(
                        product: product,
                        accent: accent,
                        refreshIntervalSeconds: effectiveRefreshIntervalSeconds
                    )
                }
            }
        }
        .frame(maxWidth: .infinity)
        .background(.background, in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .stroke(.separator.opacity(0.55), lineWidth: 1)
        }
        .accessibilityElement(children: .contain)
        .alert(item: $loginNotice) { notice in
            Alert(
                title: Text("重新登录"),
                message: Text(notice.message),
                dismissButton: .default(Text("好"))
            )
        }
    }

    private var headerRecovery: ProviderQuotaHeaderRecoveryPresentation? {
        ProviderQuotaHeaderRecoveryPresentation(provider: provider)
    }

    private var reauthorizationHelp: String {
        if provider.activity == .loggingIn { return "取消本次官方授权流程" }
        if let expiresAt = provider.authenticationExpiresAt {
            return "授权到期：\(expiresAt.formatted(date: .abbreviated, time: .standard))。点击提前重新授权。"
        }
        return "点击启动官方登录流程，提前重新授权并验证额度"
    }

    private var hasBodyContent: Bool {
        shouldShowStatusRow || !provider.products.isEmpty
    }

    private var shouldShowStatusRow: Bool {
        ProviderQuotaStatusPlacement.showsBodyStatusRow(for: provider)
    }

    private func loginButton(title: String, systemImage: String? = nil) -> some View {
        Button {
            if provider.activity == .loggingIn {
                guard !isLoginCancellationInFlight else { return }
                isLoginCancellationInFlight = true
                Task { @MainActor in
                    _ = await onLogin(.cancel)
                    isLoginCancellationInFlight = false
                }
                return
            }
            guard !isLoginInFlight else { return }
            isLoginInFlight = true
            Task { @MainActor in
                let result = await onLogin(.start)
                isLoginInFlight = false
                guard result != .verifiedFresh else { return }
                loginNotice = ProviderQuotaLoginNotice(
                    message: ProviderPresentation.loginFeedbackMessage(
                        result,
                        for: provider.id
                    )
                )
            }
        } label: {
            if provider.activity == .loggingIn {
                if isLoginCancellationInFlight {
                    ProgressView()
                        .controlSize(.small)
                    Text("正在取消…")
                } else {
                    Text("取消登录")
                }
            } else if isLoginInFlight {
                ProgressView()
                    .controlSize(.small)
                Text("登录中…")
            } else if let systemImage {
                Label(title, systemImage: systemImage)
            } else {
                Text(title)
            }
        }
        .controlSize(.small)
        .fixedSize()
        .disabled(
            isLoginCancellationInFlight
                || (isLoginInFlight && provider.activity != .loggingIn)
        )
        .accessibilityLabel(
            provider.activity == .loggingIn
                ? String(localized: "取消 \(ProviderPresentation.displayName(for: provider.id)) 登录")
                : isLoginInFlight
                ? String(localized: "正在重新登录 \(ProviderPresentation.displayName(for: provider.id))")
                : String(localized: "重新登录 \(ProviderPresentation.displayName(for: provider.id))")
        )
        .accessibilityValue(
            isLoginInFlight || isLoginCancellationInFlight
                ? String(localized: "进行中")
                : ""
        )
        .accessibilityHint(
            provider.activity == .loggingIn
                ? String(localized: "取消本次官方授权流程")
                : String(localized: "启动官方登录流程并重新验证额度")
        )
    }
}

enum ProviderQuotaStatusPlacement {
    static func showsBodyStatusRow(
        for provider: Stage3ProviderProjection
    ) -> Bool {
        if provider.partialDataState != nil { return true }
        if let failureCode = provider.failureCode {
            if case .expired = provider.rowState,
               failureCode == .authenticationExpired {
                return false
            }
            return true
        }
        if provider.activity.isInFlight {
            if case .expired = provider.rowState { return false }
            // A plain refresh is signaled by the header timestamp spinner;
            // a body row here would appear and vanish on every cycle.
            if provider.activity == .refreshing { return false }
            return true
        }
        if case .expired = provider.rowState { return false }
        if provider.products.isEmpty { return true }
        if provider.rowState != .connected,
           provider.rowState != .authenticationWarning { return true }
        if case .stale = provider.dataState { return true }
        return false
    }
}

struct ProviderQuotaHeaderRecoveryPresentation: Equatable {
    let title: String
    let detail: String?
    let actionTitle: String?

    init?(provider: Stage3ProviderProjection) {
        guard case let .expired(lastSuccessAt) = provider.rowState else {
            return nil
        }

        title = ProviderActivityPresentation.title(for: provider.activity)
            ?? String(localized: "登录已过期")
        if provider.partialDataState != nil {
            if let lastSuccessAt {
                detail = String(
                    localized: "上次成功 \(lastSuccessAt.formatted(date: .abbreviated, time: .shortened))"
                )
            } else if provider.products.isEmpty {
                detail = String(localized: "尚无成功数据")
            } else {
                detail = nil
            }
        } else if case let .stale(asOf) = provider.dataState {
            detail = String(
                localized: "显示 \(asOf.formatted(date: .abbreviated, time: .shortened)) 的旧数据"
            )
        } else if let lastSuccessAt {
            detail = String(
                localized: "上次成功 \(lastSuccessAt.formatted(date: .abbreviated, time: .shortened))"
            )
        } else if provider.products.isEmpty {
            detail = String(localized: "尚无成功数据")
        } else {
            detail = nil
        }
        if provider.activity == .loggingIn {
            actionTitle = String(localized: "取消登录")
        } else {
            actionTitle = provider.activity.isInFlight || provider.loginMethod == nil
                ? nil
                : String(localized: "重新登录")
        }
    }
}

private struct ProviderQuotaHeaderRecoveryView: View {
    let recovery: ProviderQuotaHeaderRecoveryPresentation

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "exclamationmark.circle")
                .foregroundStyle(.red)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 1) {
                Text(recovery.title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.red)
                if let detail = recovery.detail {
                    Text(detail)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }
}

private struct ProviderQuotaLoginNotice: Identifiable {
    let id = UUID()
    let message: String
}

private struct ProviderQuotaStateRow: View {
    let provider: Stage3ProviderProjection

    var body: some View {
        HStack(spacing: 10) {
            stateIcon

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.medium))
                if let detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if provider.failureCode != nil {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        Text(retryText(now: context.date))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }

            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 13)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var stateIcon: some View {
        if ProviderActivityPresentation.usesProgressIndicator(provider.activity) {
            ProgressView()
                .controlSize(.small)
        } else if provider.activity == .shuttingDown {
            Image(systemName: "stop.circle")
                .foregroundStyle(.secondary)
        } else if let failureCode = ProviderStatusPriority.visibleFailure(
            for: provider
        ) {
            let presentation = ProviderPresentation.failure(failureCode)
            Image(systemName: presentation.symbol)
                .foregroundStyle(presentation.color)
        } else if ProviderStatusPriority.visiblePartial(for: provider) != nil {
            Image(systemName: "clock.badge.exclamationmark")
                .foregroundStyle(.orange)
        } else {
            switch provider.rowState {
            case .detecting:
                EmptyView()
            case .connected, .authenticationWarning:
                Image(systemName: "clock.badge.exclamationmark")
                    .foregroundStyle(.orange)
            case .requiresLogin:
                Image(systemName: "key.fill")
                    .foregroundStyle(.orange)
            case .expired:
                Image(systemName: "exclamationmark.circle")
                    .foregroundStyle(.red)
            case .unavailable:
                Image(systemName: "questionmark.circle")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var title: String {
        if let activityTitle = ProviderActivityPresentation.title(
            for: provider.activity
        ) {
            return activityTitle
        }
        if provider.rowState == .detecting { return String(localized: "正在检测") }
        if let failureCode = ProviderStatusPriority.visibleFailure(
            for: provider
        ) {
            return provider.isQuotaValidationFailure
                ? String(localized: "部分额度数据异常")
                : ProviderPresentation.failure(failureCode).title
        }
        if ProviderStatusPriority.visiblePartial(for: provider) != nil {
            return String(localized: "部分信息未更新")
        }
        switch provider.rowState {
        case .detecting:
            return String(localized: "正在检测")
        case .connected, .authenticationWarning:
            if case .stale = provider.dataState {
                return String(localized: "数据已过期")
            } else {
                return String(localized: "尚无可展示额度")
            }
        case .requiresLogin:
            return String(localized: "需要登录")
        case .expired:
            return String(localized: "登录已过期")
        case .unavailable:
            return String(localized: "暂时无法获取额度")
        }
    }

    private func retryText(now: Date) -> String {
        if provider.activity.isInFlight { return String(localized: "正在重试…") }
        if provider.automaticRetry == false { return String(localized: "仅手动刷新 · 详情见设置中的脱敏诊断") }
        if let retryAt = provider.retryAt, retryAt > now {
            return String(localized: "将于 \(retryAt.formatted(date: .omitted, time: .standard)) 自动重试")
        }
        return String(localized: "等待重新检测 · 详情见设置中的脱敏诊断")
    }

    private var detail: String? {
        if let activityDetail = ProviderActivityPresentation.detail(
            for: provider
        ) {
            return activityDetail
        }
        if let partial = provider.partialDataState {
            return String(
                localized: "部分项目显示 \(partial.retainedStaleAsOf.formatted(date: .abbreviated, time: .shortened)) 的结果"
            )
        }
        if case let .stale(asOf) = provider.dataState {
            return String(
                localized: "显示 \(asOf.formatted(date: .abbreviated, time: .shortened)) 的旧数据"
            )
        }
        switch provider.rowState {
        case .detecting, .requiresLogin:
            return provider.products.isEmpty ? String(localized: "尚无成功数据") : nil
        case let .expired(lastSuccessAt):
            guard let lastSuccessAt else {
                return provider.products.isEmpty ? String(localized: "尚无成功数据") : nil
            }
            return String(
                localized: "显示 \(lastSuccessAt.formatted(date: .abbreviated, time: .shortened)) 的结果"
            )
        case .connected, .authenticationWarning:
            return nil
        case .unavailable:
            return provider.products.isEmpty ? String(localized: "尚无成功数据") : nil
        }
    }
}

private struct ProductQuotaSection: View {
    let product: Stage3QuotaProductProjection
    let accent: Color
    let refreshIntervalSeconds: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let title = product.title {
                HStack(spacing: 8) {
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                    if let planLevel = product.planLevel {
                        PlanBadge(badge: planLevel)
                    } else if product.metrics.isEmpty {
                        Text("已到期")
                            .font(.caption2.weight(.medium))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.secondary.opacity(0.15))
                            .foregroundStyle(.secondary)
                            .clipShape(Capsule())
                    }
                    Spacer()
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .background(.quaternary.opacity(0.45))
            }

            if product.metrics.isEmpty {
                HStack {
                    Text("暂无可用额度（已到期或未订购）")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
            } else {
                ForEach(Array(product.metrics.enumerated()), id: \.element.id) { index, metric in
                    if index > 0 {
                        Divider()
                            .padding(.leading, 14)
                    }
                    QuotaMetricRow(
                        metric: metric,
                        accent: accent,
                        refreshIntervalSeconds: refreshIntervalSeconds
                    )
                }
            }
        }
        .frame(maxWidth: .infinity)
    }
}

private struct QuotaMetricRow: View {
    let metric: Stage3QuotaMetricProjection
    let accent: Color
    let refreshIntervalSeconds: Int

    @State private var isExpanded = false

    private let titleWidth: CGFloat = 116
    // Longest event copy ("23小时59分后重置", 3-digit-day countdowns) measures
    // ~89–95pt at .caption; 96pt keeps every row single-line while letting the
    // bar take the remaining width.
    private let eventTextWidth: CGFloat = 96

    private var expandableItems: [Stage3ResetEntitlementItem] {
        metric.resetEntitlements ?? []
    }

    var body: some View {
        if expandableItems.count < 2 {
            rowContent(showChevron: false)
        } else {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    isExpanded.toggle()
                }
            } label: {
                VStack(alignment: .leading, spacing: 6) {
                    rowContent(showChevron: true)
                    if isExpanded {
                        expandedDetails
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint(
                isExpanded
                    ? String(localized: "收起重置卡明细")
                    : String(localized: "展开重置卡明细")
            )
        }
    }

    private func rowContent(showChevron: Bool) -> some View {
        HStack(alignment: .center, spacing: 10) {
            HStack(spacing: 6) {
                Text(metric.title)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                if let badge = metric.windowBadge {
                    Text(badge)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 5))
                }
            }
            .frame(width: titleWidth, alignment: .leading)

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 4) {
                    Text(valueText)
                        .font(.subheadline)
                        .foregroundStyle(valueColor)
                        .lineLimit(1)
                    if showChevron {
                        Image(systemName: "chevron.right")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    }
                }

                if let progress = metric.value.progressFraction {
                    ProgressView(value: progress)
                        .progressViewStyle(.linear)
                        .tint(barTint)
                        .frame(maxWidth: .infinity)
                        .accessibilityValue(valueText)
                }

                if case let .stale(asOf)? = metric.dataState {
                    Text(String(localized: "显示 \(asOf.formatted(date: .abbreviated, time: .shortened)) 的结果"))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Text(eventText)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing)
                .frame(width: eventTextWidth, alignment: .trailing)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .accessibilityElement(children: .combine)
    }

    private var expandedDetails: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("重置卡到期时间")
                .font(.caption)
                .foregroundStyle(.secondary)

            VStack(spacing: 0) {
                ForEach(Array(expandableItems.enumerated()), id: \.element.id) { index, item in
                    if index > 0 {
                        Divider()
                            .padding(.leading, 12)
                    }
                    HStack(spacing: 8) {
                        Image(systemName: "clock")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(detailTitle(item))
                            .font(.caption)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                        Text(String(localized: "将于 \(absoluteDateTimeText(item.expiresAt)) 到期"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                }
            }
            .background(
                Color(nsColor: .textBackgroundColor),
                in: RoundedRectangle(cornerRadius: 8)
            )
        }
        .padding(10)
        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 10))
        .padding(.horizontal, 14)
        .padding(.bottom, 4)
    }

    private func detailTitle(_ item: Stage3ResetEntitlementItem) -> String {
        if let title = item.title?.trimmingCharacters(in: .whitespacesAndNewlines),
           !title.isEmpty {
            return title
        }
        return String(localized: "重置权益")
    }

    private var valueText: String {
        switch metric.value {
        case let .percent(value, direction):
            let prefix = direction == .remaining
                ? String(localized: "剩余")
                : String(localized: "已用")
            return "\(prefix) \(formatPercent(value))%"
        case .unlimited:
            return String(localized: "∞ 无限制")
        case let .usedCount(used, total, unit):
            return String(localized: "已用 \(used) / \(total) \(unit)")
        case let .entitlement(availableCount):
            return String(localized: "可用 \(availableCount) 次")
        }
    }

    private var valueColor: Color {
        if case .unlimited = metric.value { return .blue }
        if isStale { return .secondary }
        return .primary
    }

    private var isStale: Bool {
        if case .stale = metric.dataState { return true }
        return false
    }

    private var barTint: Color {
        switch QuotaAvailabilityBand.band(
            value: metric.value,
            asOf: metric.dataState?.asOf,
            now: Date(),
            refreshIntervalSeconds: refreshIntervalSeconds
        ) {
        case .low: .red
        case .medium: .yellow
        case .high: .green
        case .lost, .none: Color.secondary
        }
    }

    private var eventText: String {
        guard let event = metric.event else { return "—" }
        let suffix: String
        switch event.kind {
        case .reset: suffix = String(localized: "重置")
        case .refresh: suffix = String(localized: "刷新")
        case .entitlementExpiry: suffix = String(localized: "到期")
        }

        switch event.style {
        case .absoluteDateTime:
            return "\(absoluteDateTimeText(event.occursAt)) \(suffix)"
        case .relativeCountdown:
            let seconds = max(Int(event.occursAt.timeIntervalSinceNow), 0)
            let days = seconds / 86_400
            let hours = (seconds % 86_400) / 3_600
            let minutes = (seconds % 3_600) / 60
            if days > 0 {
                return String(localized: "\(days)天\(hours)小时后\(suffix)")
            }
            if hours > 0 {
                return String(localized: "\(hours)小时\(minutes)分后\(suffix)")
            }
            return String(localized: "\(minutes)分钟后\(suffix)")
        }
    }

    private func absoluteDateTimeText(_ date: Date) -> String {
        date.formatted(
            .dateTime
                .locale(Locale(identifier: "zh_CN"))
                .month(.defaultDigits)
                .day(.defaultDigits)
                .hour(.twoDigits(amPM: .omitted))
                .minute(.twoDigits)
        )
    }

    private func formatPercent(_ value: Double) -> String {
        if value.rounded() == value {
            return String(Int(value))
        }
        return String(format: "%.2f", value)
    }
}

enum PlanBadgePresentation {
    static func accessibilityLabel(for badge: Stage3PlanBadge) -> String {
        switch badge.origin {
        case .reported:
            return String(localized: "\(badge.value) 套餐")
        case .inferred:
            return String(localized: "\(badge.value)，根据视频权益推断")
        }
    }
}

private struct PlanBadge: View {
    let badge: Stage3PlanBadge

    var body: some View {
        Text(badge.value)
            .font(.caption.weight(.medium))
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 5))
            .accessibilityLabel(PlanBadgePresentation.accessibilityLabel(for: badge))
    }
}
