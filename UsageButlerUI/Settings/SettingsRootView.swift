import AppKit
import SwiftUI
import UsageButlerCore
import UsageButlerDomain

public struct SettingsRootView: View {
    @ObservedObject private var model: MenuPanelViewModel
    private let onQuit: () -> Void

    @AppStorage(ProviderPreferenceKey.globalRefreshSeconds)
    private var globalRefreshSeconds = 300
    @AppStorage(ProviderPreferenceKey.quotaAlertsEnabled)
    private var quotaAlertsEnabled = true
    @AppStorage(ProviderPreferenceKey.larkQuotaAlertChatID)
    private var larkChatID = ""
    @State private var feedback: String?
    @State private var showingDiagnostics = false

    public init(model: MenuPanelViewModel, onQuit: @escaping () -> Void) {
        self.model = model
        self.onQuit = onQuit
    }

    public var body: some View {
        VStack(spacing: 0) {
            Picker("设置分类", selection: $model.settingsPage) {
                ForEach(SettingsPage.allCases) { page in
                    Text(page.title).tag(page)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 260)
            .padding(16)
            .accessibilityIdentifier("settings.page")
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    switch model.settingsPage {
                    case .general:
                        appIdentity
                        generalSection
                        shortcutSection
                        providerSection
                        aboutSection
                    case .network:
                        NetworkSettingsView(model: model)
                    }
                }
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .id(model.settingsPage)
        }
        .frame(width: 760)
        .frame(minHeight: 700)
        .background(Color(nsColor: .windowBackgroundColor))
        .sheet(isPresented: $showingDiagnostics) {
            diagnosticsSheet
        }
        .task {
            await model.loadLarkQuotaAlertChannelStatus()
        }
    }

    private var appIdentity: some View {
        HStack(spacing: 14) {
            Image(systemName: "chart.bar.fill")
                .font(.system(size: 28, weight: .semibold))
                .foregroundStyle(.blue)
                .frame(width: 56, height: 56)
                .background(.blue.opacity(0.10), in: RoundedRectangle(cornerRadius: 13))

            VStack(alignment: .leading, spacing: 2) {
                Text("额度管家")
                    .font(.title2.weight(.semibold))
                Text("Usage-Butler")
                    .foregroundStyle(.secondary)
            }
            Spacer()

            #if USAGE_BUTLER_FIXTURES
            Label(
                model.isFixtureMode ? "本地 Fixture · 非实时" : "本机运行时 · 只读",
                systemImage: model.isFixtureMode ? "hammer.fill" : "lock.open.display"
            )
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityLabel(
                    model.isFixtureMode
                        ? "测试数据，本地 Fixture，非实时，不会连接额度来源"
                        : "本机只读额度运行时"
                )
            #else
            Label("本机运行时 · 只读", systemImage: "lock.open.display")
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityLabel("本机只读额度运行时")
            #endif
        }
        .padding(.bottom, 4)
    }

    private var generalSection: some View {
        SettingsSection(title: "通用") {
            SettingsRow(title: String(localized: "默认刷新频率"), subtitle: String(localized: "可选 1、5、15、30 分钟或仅手动")) {
                Picker("默认刷新频率", selection: $globalRefreshSeconds) {
                    Text("1 分钟").tag(60)
                    Text("5 分钟").tag(300)
                    Text("15 分钟").tag(900)
                    Text("30 分钟").tag(1800)
                    Text("仅手动").tag(0)
                }
                .labelsHidden()
                .frame(width: 130)
                .onChange(of: globalRefreshSeconds) { newValue in
                    model.setGlobalRefreshFrequency(
                        .validated(storedSeconds: newValue)
                    )
                }
            }

            Divider()

            SettingsRow(title: String(localized: "额度刷新行为"), subtitle: String(localized: "只读取额度状态，不发起模型调用")) {
                Text("仅读取额度状态")
                    .foregroundStyle(.secondary)
            }

            Divider()

            SettingsRow(title: String(localized: "清除额度缓存"), subtitle: String(localized: "不影响登录和设置")) {
                Button("清除额度缓存") {
                    feedback = String(localized: "正在清除额度缓存…")
                    Task { @MainActor in
                        switch await model.clearQuotaCache() {
                        case .completed:
                            feedback = String(localized: "额度缓存清除请求已完成")
                        #if USAGE_BUTLER_FIXTURES
                        case .offlineFixture:
                            feedback = String(localized: "本地 Fixture 没有用户额度缓存")
                        #endif
                        case .failed:
                            feedback = String(localized: "无法清除额度缓存，已保留当前数据")
                        }
                    }
                }
            }

            Divider()

            SettingsRow(title: String(localized: "额度提醒"), subtitle: String(localized: "额度用尽与重置恢复时，发送系统通知与飞书推送")) {
                Toggle("额度提醒", isOn: $quotaAlertsEnabled)
                    .toggleStyle(.switch)
                    .labelsHidden()
            }

            Divider()

            SettingsRow(
                title: String(localized: "飞书推送"),
                subtitle: larkQuotaAlertStatusDetail
            ) {
                HStack(spacing: 10) {
                    larkQuotaAlertStatusLabel
                    Button(
                        model.larkQuotaAlertChannelStatus == .notChecked
                            ? String(localized: "检查")
                            : String(localized: "重新检查")
                    ) {
                        Task { @MainActor in
                            await model.loadLarkQuotaAlertChannelStatus()
                        }
                    }
                    .disabled(model.larkQuotaAlertChannelStatus == .checking)
                }
            }

            Divider()

            SettingsRow(
                title: String(localized: "飞书会话 ID"),
                subtitle: String(localized: "接收额度提醒推送的飞书会话 ID（以 oc_ 开头）")
            ) {
                TextField("oc_...", text: $larkChatID)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 280)
                    .onChange(of: larkChatID) { _ in
                        model.invalidateLarkQuotaAlertChannelStatus()
                    }
            }

            Divider()

            SettingsRow(title: String(localized: "查看脱敏诊断…")) {
                Button("查看脱敏诊断…") {
                    showingDiagnostics = true
                    Task { @MainActor in
                        await model.loadSafeDiagnostics()
                    }
                }
            }

            if let feedback {
                Divider()
                Text(feedback)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
            }
        }
    }

    @ViewBuilder
    private var larkQuotaAlertStatusLabel: some View {
        switch model.larkQuotaAlertChannelStatus {
        case .notChecked:
            Label("尚未检查", systemImage: "questionmark.circle")
                .foregroundStyle(.secondary)
        case .checking:
            HStack(spacing: 6) {
                ProgressView()
                    .controlSize(.small)
                Text("检查中")
            }
            .foregroundStyle(.secondary)
        case .ready:
            Label("已就绪", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .needsChatID:
            Label("未配会话", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        case .needsSetup:
            Label("需要配置", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        case .unavailable:
            Label("不可用", systemImage: "xmark.circle.fill")
                .foregroundStyle(.red)
        }
    }

    private var larkQuotaAlertStatusDetail: String {
        switch model.larkQuotaAlertChannelStatus {
        case .notChecked, .checking:
            return String(localized: "检测本地 lark-cli 状态与接收会话配置")
        case .ready:
            return quotaAlertsEnabled
                ? String(localized: "飞书 Bot 已就绪；额度提醒会同时尝试系统通知与飞书推送")
                : String(localized: "飞书 Bot 已就绪；额度提醒当前已关闭")
        case .needsChatID:
            return quotaAlertsEnabled
                ? String(localized: "飞书 Bot 已就绪，但未配置接收会话 ID（请填写下方飞书会话 ID）")
                : String(localized: "飞书 Bot 已就绪；额度提醒当前已关闭")
        case .needsSetup:
            return quotaAlertsEnabled
                ? String(localized: "飞书 Bot 未就绪：请在终端检查 lark-cli 登录与 Bot 授权")
                : String(localized: "飞书 Bot 未就绪；额度提醒当前已关闭")
        case .unavailable:
            return quotaAlertsEnabled
                ? String(localized: "未能使用 lark-cli；请检查是否已安装 lark-cli 并加入 PATH")
                : String(localized: "未能使用 lark-cli；额度提醒当前已关闭")
        }
    }

    private var shortcutSection: some View {
        SettingsSection(title: String(localized: "快捷键")) {
            GlobalShortcutSettingsRow(model: model)
                .padding(12)
        }
    }

    private var providerSection: some View {
        SettingsSection(title: "额度来源") {
            ForEach(Array(model.settingsProviders.enumerated()), id: \.element.id) { index, provider in
                if index > 0 { Divider() }
                ProviderSettingsRow(
                    provider: provider,
                    onSetEnabled: { enabled in
                        model.setProviderEnabled(provider.id, enabled: enabled)
                    },
                    onSetRefreshOverride: { override in
                        model.setProviderRefreshOverride(
                            provider.id,
                            override: override
                        )
                    },
                    onRedetect: {
                        model.redetectProvider(provider.id)
                    },
                    onLogin: { request in
                        await model.loginProvider(
                            provider.id,
                            request: request
                        )
                    },
                    onSelectExecutable: {
                        await model.selectProviderExecutable(provider.id)
                    },
                    onSetProductEnabled: { productID, enabled in
                        model.setProductEnabled(
                            provider.id,
                            productID: productID,
                            enabled: enabled
                        )
                    },
                    reportAction: { message in
                        feedback = message
                    }
                )
            }

            Divider()
            Text("关闭后从额度面板隐藏；不会退出登录或删除缓存")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
        }
    }

    private var aboutSection: some View {
        SettingsSection(title: "关于") {
            HStack(spacing: 12) {
                Image(systemName: "chart.bar.fill")
                    .foregroundStyle(.blue)
                    .frame(width: 32, height: 32)
                    .background(.blue.opacity(0.10), in: RoundedRectangle(cornerRadius: 7))
                VStack(alignment: .leading) {
                    Text("额度管家")
                        .font(.headline)
                    Text("菜单栏中的额度、内存与网络概览")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text("\(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—") (\(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"))")
                    .foregroundStyle(.secondary)
            }
            .padding(12)

            Divider()

            HStack {
                Text("键盘快捷键")
                Spacer()
                Text(String(localized: "⌘, 设置    ⇧⌘P 面板    ⌘R 刷新    ⌘Q 退出"))
                    .foregroundStyle(.secondary)
            }
            .padding(12)

            Divider()

            HStack {
                Button("退出额度管家", action: onQuit)
                Spacer()
            }
            .padding(12)
        }
    }

    private var diagnosticsSheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("脱敏诊断")
                .font(.title2.weight(.semibold))
            Text(diagnosticsSummary)
                .fixedSize(horizontal: false, vertical: true)
            ScrollView {
                diagnosticsContent
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack {
                Button("在访达中显示诊断记录") {
                    let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                        .appendingPathComponent("Usage-Butler/diagnostics", isDirectory: true)
                    let file = directory.appendingPathComponent("provider-events-v1.json")
                    NSWorkspace.shared.activateFileViewerSelecting([FileManager.default.fileExists(atPath: file.path) ? file : directory])
                }
                Spacer()
                Button("完成") { showingDiagnostics = false }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 620)
        .frame(minHeight: 360, maxHeight: 680)
    }

    @ViewBuilder
    private var diagnosticsContent: some View {
        switch model.safeDiagnosticsState {
        case .idle:
            Text("尚未读取实时脱敏诊断。")
                .foregroundStyle(.secondary)
        case .loading:
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text("正在读取脱敏诊断…")
            }
            .foregroundStyle(.secondary)
        case let .loaded(diagnostics):
            if diagnostics.isEmpty {
                Text("当前运行时没有返回实时脱敏诊断。")
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(Array(diagnostics.enumerated()), id: \.element.id) { index, diagnostic in
                        if index > 0 { Divider() }
                        diagnosticSection(diagnostic)
                    }
                }
            }
        case let .unavailable(reason):
            Text(unavailableDiagnosticsMessage(reason))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        case let .failed(reason):
            VStack(alignment: .leading, spacing: 10) {
                Text(failedDiagnosticsMessage(reason))
                    .foregroundStyle(.red)
                Button("重试") {
                    Task { @MainActor in
                        await model.loadSafeDiagnostics()
                    }
                }
            }
        }
    }

    private func diagnosticSection(
        _ diagnostic: SafeProviderDiagnosticPresentation
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(ProviderPresentation.cliName(for: diagnostic.providerID))
                .font(.headline.monospaced())

            LabeledContent("diagnosticCode") {
                Text(diagnostic.diagnosticCode)
                    .monospaced()
                    .textSelection(.enabled)
            }

            ForEach(diagnostic.safeFields) { field in
                LabeledContent(field.key) {
                    Text(field.value)
                        .monospaced()
                        .textSelection(.enabled)
                }
            }
            if !diagnostic.journalAvailable {
                Text("诊断记录暂时无法保存，请检查本地文件权限或可用空间。")
                    .foregroundStyle(.orange)
            }
            if diagnostic.events.isEmpty {
                Text("暂无已记录的失败或恢复事件。")
                    .foregroundStyle(.secondary)
            } else {
                Text("最近失败与恢复（保留 7 天，最多 200 条）").font(.subheadline.weight(.medium))
                ForEach(diagnostic.events) { event in DiagnosticEventView(event: event) }
            }

        }
    }

    private func unavailableDiagnosticsMessage(
        _ reason: SafeDiagnosticsUnavailableReason
    ) -> String {
        switch reason {
        #if USAGE_BUTLER_FIXTURES
        case .offlineFixture:
            return String(localized: "当前为本地 Fixture；没有实时 Provider 诊断，也不会调用 codex、mmx 或 arkcli。")
        #endif
        case .runtimeCompositionUnavailable:
            return String(localized: "当前运行时组合不可用，因此没有实时 Provider 诊断可显示。")
        }
    }

    private func failedDiagnosticsMessage(
        _ reason: SafeDiagnosticsFailureReason
    ) -> String {
        switch reason {
        case .actionUnavailable:
            return String(localized: "脱敏诊断动作尚未连接。")
        case .runtimeShuttingDown:
            return String(localized: "额度管家正在退出，无法读取脱敏诊断。")
        }
    }

    private var diagnosticsSummary: String {
        #if USAGE_BUTLER_FIXTURES
        if model.isFixtureMode {
            return String(localized: "当前为本地 Fixture；未调用 codex、mmx 或 arkcli，也没有读取账号身份、token、API Key 或原始响应。")
        }
        #endif
        return String(localized: "当前运行时自动执行 Provider 发现与额度读取；只有你明确点击登录时，才会启动 MiniMax 或火山方舟的官方登录流程。此页不显示账号身份、token、API Key、本机路径或原始响应。")
    }
}

private struct ProviderSettingsRow: View {
    let provider: Stage3ProviderProjection
    let onSetEnabled: (Bool) -> Void
    let onSetRefreshOverride: (ProviderRefreshOverride) -> Void
    let onRedetect: () -> Void
    let onLogin: (ProviderLoginRequest) async -> ProviderLoginFeedback
    let onSelectExecutable: () async -> ProviderExecutableSelectionFeedback
    let onSetProductEnabled: ((String, Bool) -> Void)?
    let reportAction: (String) -> Void

    @AppStorage private var isEnabled: Bool
    @AppStorage private var refreshOverrideSeconds: Int
    @AppStorage(ProviderPreferenceKey.arkAgentPlanEnabled)
    private var arkAgentPlanEnabled = true
    @AppStorage(ProviderPreferenceKey.arkCodingPlanEnabled)
    private var arkCodingPlanEnabled = true
    @State private var isLoginInFlight = false
    @State private var isLoginCancellationInFlight = false
    @State private var isExecutableSelectionInFlight = false

    init(
        provider: Stage3ProviderProjection,
        onSetEnabled: @escaping (Bool) -> Void,
        onSetRefreshOverride: @escaping (ProviderRefreshOverride) -> Void,
        onRedetect: @escaping () -> Void,
        onLogin: @escaping (
            ProviderLoginRequest
        ) async -> ProviderLoginFeedback,
        onSelectExecutable: @escaping () async -> ProviderExecutableSelectionFeedback,
        onSetProductEnabled: ((String, Bool) -> Void)? = nil,
        reportAction: @escaping (String) -> Void
    ) {
        self.provider = provider
        self.onSetEnabled = onSetEnabled
        self.onSetRefreshOverride = onSetRefreshOverride
        self.onRedetect = onRedetect
        self.onLogin = onLogin
        self.onSelectExecutable = onSelectExecutable
        self.onSetProductEnabled = onSetProductEnabled
        self.reportAction = reportAction
        self._isEnabled = AppStorage(wrappedValue: true, provider.preferenceKey)
        self._refreshOverrideSeconds = AppStorage(wrappedValue: -1, provider.refreshOverrideKey)
    }

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            providerIcon
                .frame(width: 34)

            VStack(alignment: .leading, spacing: 5) {
                Text(ProviderPresentation.displayName(for: provider.id))
                    .font(.headline)
                statusLine
                if let statusDetail {
                    Text(statusDetail)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            .frame(width: 150, alignment: .leading)

            Divider()
                .frame(height: 54)

            VStack(alignment: .leading, spacing: 8) {
                Text("\(ProviderPresentation.cliName(for: provider.id)) · 自动检测")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                HStack(spacing: 8) {
                    Text("刷新频率")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Picker("刷新频率", selection: $refreshOverrideSeconds) {
                        Text("跟随默认").tag(-1)
                        Text("1 分钟").tag(60)
                        Text("5 分钟").tag(300)
                        Text("15 分钟").tag(900)
                        Text("30 分钟").tag(1800)
                        Text("仅手动").tag(0)
                    }
                    .labelsHidden()
                    .frame(width: 116)
                    .onChange(of: refreshOverrideSeconds) { newValue in
                        onSetRefreshOverride(
                            .validated(storedSeconds: newValue)
                        )
                    }

                    actionControls
                }

                if isEnabled && provider.id == .ark {
                    HStack(spacing: 12) {
                        Text("展示套餐")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        Toggle("Agent Plan", isOn: $arkAgentPlanEnabled)
                            .toggleStyle(.checkbox)
                            .font(.caption)
                            .onChange(of: arkAgentPlanEnabled) { newValue in
                                onSetProductEnabled?("agent-plan", newValue)
                            }

                        Toggle("Coding Plan", isOn: $arkCodingPlanEnabled)
                            .toggleStyle(.checkbox)
                            .font(.caption)
                            .onChange(of: arkCodingPlanEnabled) { newValue in
                                onSetProductEnabled?("coding-plan", newValue)
                            }
                    }
                }
            }

            Spacer(minLength: 8)

            Toggle("启用 \(ProviderPresentation.displayName(for: provider.id))", isOn: $isEnabled)
                .labelsHidden()
                .toggleStyle(.switch)
                .onChange(of: isEnabled) { newValue in
                    onSetEnabled(newValue)
                }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 12)
        .frame(minHeight: 104)
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
                .foregroundStyle(ProviderPresentation.accentColor(for: provider.id))
                .accessibilityLabel(ProviderPresentation.displayName(for: provider.id))
        }
    }

    @ViewBuilder
    private var statusLine: some View {
        if !isEnabled {
            Label("已关闭", systemImage: "pause.circle.fill")
                .foregroundStyle(.secondary)
        } else if let activityTitle = ProviderActivityPresentation.title(
            for: provider.activity
        ) {
            HStack(spacing: 6) {
                if ProviderActivityPresentation.usesProgressIndicator(
                    provider.activity
                ) {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image(systemName: "stop.circle")
                }
                Text(activityTitle)
            }
            .foregroundStyle(.secondary)
        } else {
            switch provider.rowState {
        case .detecting:
            HStack(spacing: 6) {
                ProgressView()
                    .controlSize(.small)
                Text("正在检测")
            }
            .foregroundStyle(.secondary)
        case .connected, .authenticationWarning:
            if let warningTitle = provider.rowState.authenticationWarningTitle {
                Label(warningTitle, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }
            if let failureCode = ProviderStatusPriority.visibleFailure(
                for: provider
            ) {
                failureLabel(failureCode)
            } else if ProviderStatusPriority.visiblePartial(
                for: provider
            ) != nil {
                Label("部分信息未更新", systemImage: "clock.badge.exclamationmark")
                    .foregroundStyle(.orange)
            } else if case .stale = provider.dataState {
                Label("数据已过期", systemImage: "clock.badge.exclamationmark")
                    .foregroundStyle(.orange)
            } else if provider.rowState == .connected {
                Label("已连接", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            }
        case .requiresLogin:
            Label("需要登录", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        case let .expired(lastSuccessAt):
            VStack(alignment: .leading, spacing: 2) {
                Label("登录已过期", systemImage: "exclamationmark.circle.fill")
                    .foregroundStyle(.red)
                if let failureCode = ProviderStatusPriority.visibleFailure(
                    for: provider
                ) {
                    failureLabel(failureCode)
                }
                if let lastSuccessAt {
                    Text(String(localized: "上次成功：\(lastSuccessAt.formatted(date: .omitted, time: .shortened))"))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        case .unavailable:
            if let failureCode = provider.failureCode {
                failureLabel(failureCode)
            } else {
                Label("暂时无法判断状态", systemImage: "questionmark.circle")
                    .foregroundStyle(.secondary)
            }
            }
        }
    }

    @ViewBuilder
    private func failureLabel(_ code: FailureCode) -> some View {
        let presentation = ProviderPresentation.failure(code)
        Label(presentation.title, systemImage: presentation.symbol)
            .foregroundStyle(presentation.color)
    }

    private var statusDetail: String? {
        if !isEnabled {
            return String(localized: "不会退出登录或删除缓存")
        }
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
        switch provider.dataState {
        case .unknown:
            return provider.products.isEmpty ? String(localized: "尚无成功数据") : nil
        case .fresh:
            return nil
        case let .stale(asOf):
            return String(
                localized: "显示 \(asOf.formatted(date: .abbreviated, time: .shortened)) 的旧数据"
            )
        }
    }

    @ViewBuilder
    private var actionControls: some View {
        if !isEnabled {
            EmptyView()
        } else if provider.activity == .loggingIn {
            loginButton(title: "取消登录")
        } else if provider.activity.isInFlight {
            EmptyView()
        } else if provider.failureCode == .missingExecutable,
           provider.allowsExecutableSelection {
            executableSelectionButton
        } else {
            switch provider.rowState {
            case .detecting:
                EmptyView()
            case .requiresLogin:
                if provider.loginMethod != nil {
                    loginButton(title: "登录")
                } else {
                    Button("查看登录指引") {
                        reportAction(
                            String(localized: "请在 Codex CLI 中完成官方登录，然后返回额度管家刷新或重新检测")
                        )
                    }
                    .buttonStyle(.borderedProminent)
                }
            case .expired:
                if provider.loginMethod != nil {
                    loginButton(title: "重新登录")
                } else {
                    Button("查看登录指引") {
                        reportAction(
                            String(localized: "请在 Codex CLI 中重新完成官方登录，然后返回额度管家刷新或重新检测")
                        )
                    }
                    .buttonStyle(.borderedProminent)
                }
            case .connected, .authenticationWarning, .unavailable:
                Button(provider.failureCode == nil ? "重新检测" : "重试") {
                    onRedetect()
                }
            }
        }
    }

    private var executableSelectionButton: some View {
        Button {
            guard !isExecutableSelectionInFlight else { return }
            isExecutableSelectionInFlight = true
            Task { @MainActor in
                let result = await onSelectExecutable()
                isExecutableSelectionInFlight = false
                reportAction(executableSelectionFeedbackMessage(result))
            }
        } label: {
            if isExecutableSelectionInFlight {
                ProgressView()
                    .controlSize(.small)
                Text("选择中…")
            } else {
                Text("选择 CLI 位置…")
            }
        }
        .buttonStyle(.borderedProminent)
        .disabled(isExecutableSelectionInFlight)
    }

    private func loginButton(title: String) -> some View {
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
                reportAction(
                    ProviderPresentation.loginFeedbackMessage(
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
            } else {
                Text(title)
            }
        }
        .buttonStyle(.borderedProminent)
        .disabled(
            isLoginCancellationInFlight
                || (isLoginInFlight && provider.activity != .loggingIn)
        )
    }

    private func executableSelectionFeedbackMessage(
        _ result: ProviderExecutableSelectionFeedback
    ) -> String {
        let name = ProviderPresentation.displayName(for: provider.id)
        switch result {
        case .savedRequiresRelaunch:
            return String(localized: "已保存 \(name) CLI 位置；重新打开额度管家后生效")
        case .cancelled:
            return String(localized: "已取消选择 \(name) CLI")
        case .invalidSelection:
            return String(localized: "所选项目不是可执行的 \(ProviderPresentation.cliName(for: provider.id)) 文件")
        #if USAGE_BUTLER_FIXTURES
        case .offlineFixture:
            return String(localized: "本地 Fixture 不保存 CLI 位置")
        #endif
        case .failed:
            return String(localized: "无法保存 \(name) CLI 位置")
        }
    }

}

private extension Stage3ProviderProjection {
    var preferenceKey: String {
        switch id {
        case .openAI: ProviderPreferenceKey.openAIEnabled
        case .miniMax: ProviderPreferenceKey.miniMaxEnabled
        case .ark: ProviderPreferenceKey.arkEnabled
        }
    }

    var refreshOverrideKey: String {
        switch id {
        case .openAI: ProviderPreferenceKey.openAIRefreshOverrideSeconds
        case .miniMax: ProviderPreferenceKey.miniMaxRefreshOverrideSeconds
        case .ark: ProviderPreferenceKey.arkRefreshOverrideSeconds
        }
    }
}

@MainActor
private final class ShortcutRecorderController: ObservableObject {
    @Published var isRecording = false
    private var monitor: Any?
    var onCapture: ((String?) -> Void)?

    func start() {
        guard monitor == nil else { return }
        isRecording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) {
            [weak self] event in
            let keyCode = event.keyCode
            let rawFlags = event.modifierFlags.rawValue
            let consumed = MainActor.assumeIsolated {
                self?.handle(keyCode: keyCode, rawModifierFlags: rawFlags) ?? false
            }
            return consumed ? nil : event
        }
    }

    func stop() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
        monitor = nil
        isRecording = false
    }

    /// Returns whether the event was consumed by recording.
    private func handle(keyCode: UInt16, rawModifierFlags: UInt) -> Bool {
        if keyCode == 53 {
            stop()
            return true
        }

        let flags = NSEvent.ModifierFlags(rawValue: rawModifierFlags)
            .intersection(.deviceIndependentFlagsMask)
            .subtracting(.capsLock)
        var modifiers = ShortcutModifiers()
        if flags.contains(.command) { modifiers.insert(.command) }
        if flags.contains(.control) { modifiers.insert(.control) }
        if flags.contains(.option) { modifiers.insert(.option) }
        if flags.contains(.shift) { modifiers.insert(.shift) }

        let modifierKeyCodes: Set<UInt16> = [54, 55, 56, 57, 58, 59, 60, 61, 62, 63]
        guard modifiers.hasHotkeyModifier,
              !modifierKeyCodes.contains(keyCode) else {
            return false
        }

        let shortcut = GlobalShortcut(
            keyCode: UInt32(keyCode),
            modifiers: modifiers
        )
        stop()
        onCapture?(shortcut.serialized)
        return true
    }
}

private struct GlobalShortcutSettingsRow: View {
    @ObservedObject var model: MenuPanelViewModel
    @StateObject private var recorder = ShortcutRecorderController()

    var body: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 3) {
                Text(model.globalShortcutText ?? String(localized: "未设置"))
                    .font(.system(.body, design: .monospaced))
                    .frame(minWidth: 96, alignment: .leading)
                Text(String(localized: "设置后按快捷键直接打开或关闭面板；面板内按 Tab 键在额度、内存、网络三个页面之间切换。"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            if model.globalShortcutText != nil {
                Button(String(localized: "清除")) {
                    model.setGlobalShortcut(nil)
                }
            }
            Button(recorder.isRecording ? String(localized: "取消") : String(localized: "录制快捷键…")) {
                if recorder.isRecording {
                    recorder.stop()
                } else {
                    recorder.start()
                }
            }
            .buttonStyle(.bordered)
            .tint(recorder.isRecording ? .accentColor : nil)
        }
        .onAppear {
            recorder.onCapture = { serialized in
                model.setGlobalShortcut(serialized)
            }
        }
    }
}

struct SettingsSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    init(title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.headline)
            VStack(spacing: 0) {
                content
            }
            .background(.background, in: RoundedRectangle(cornerRadius: 11))
            .overlay {
                RoundedRectangle(cornerRadius: 11)
                    .stroke(.separator.opacity(0.55), lineWidth: 1)
            }
        }
    }
}

struct SettingsRow<Trailing: View>: View {
    let title: String
    let subtitle: String?
    @ViewBuilder let trailing: Trailing

    init(
        title: String,
        subtitle: String? = nil,
        @ViewBuilder trailing: () -> Trailing
    ) {
        self.title = title
        self.subtitle = subtitle
        self.trailing = trailing()
    }

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                if let subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            trailing
        }
        .padding(12)
    }
}
