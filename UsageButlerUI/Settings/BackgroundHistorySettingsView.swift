import SwiftUI
import UsageButlerDomain

struct BackgroundHistorySettingsView: View {
    @ObservedObject var model: BackgroundNetworkViewModel
    @State private var largeMiB = "100"
    @State private var sustainedSeconds = "60"
    @State private var sustainedKiB = "100"
    @State private var ruleMessage: String?
    @State private var savingRule = false
    var body: some View {
        SettingsSection(title: "后台采集与历史记录") {
            VStack(alignment: .leading, spacing: 12) {
                Toggle("主程序退出后继续记录应用流量", isOn: Binding(
                    get: { model.desired }, set: { model.setEnabled($0) }))
                    .disabled(model.changing || model.onEnabled == nil)
                    .accessibilityIdentifier("settings.history.enabled")
                Text(model.serviceTitle).font(.callout).accessibilityIdentifier("settings.history.status")
                Text("默认保存14天实际观察的应用分钟记录。停止后台会保留历史；不会补回未采集、休眠、注销或关机期间的流量。")
                    .font(.caption).foregroundStyle(.secondary)
                if let committed = model.status?.coverage.lastCommittedAt {
                    Text("最近已保存：\(committed.formatted(date: .abbreviated, time: .standard))").font(.caption)
                }
                HStack {
                    Button("查看历史") { model.onOpenHistory?() }.accessibilityIdentifier("settings.history.open")
                    if model.registration == "requiresApproval" {
                        Button("打开系统后台项目设置") { model.onOpenApproval?() }
                            .accessibilityIdentifier("settings.history.approval")
                    } else {
                        Button("刷新后台状态") { model.refreshService() }.disabled(model.changing)
                    }
                }
                Divider()
                Text("本地上传活动筛选").font(.subheadline.weight(.semibold))
                HStack { Text("连续上传段 ≥"); TextField("MiB", text: $largeMiB).frame(width: 100); Text("MiB") }
                HStack {
                    Text("持续 ≥"); TextField("秒", text: $sustainedSeconds).frame(width: 70); Text("秒，每次采样 ≥")
                    TextField("KiB/s", text: $sustainedKiB).frame(width: 80); Text("KiB/s")
                }
                Text("零流量或未知读数会结束连续段；持续上传还会在低于速率阈值时结束。来源重启、时间跳变和 UTC 日期边界会分段。")
                    .font(.caption2).foregroundStyle(.secondary)
                Text("新阈值用于后续采样；旧活动保留当时规则。这里只筛选本地记录，不发送消息或阻断连接。")
                    .font(.caption2).foregroundStyle(.secondary)
                HStack {
                    Button("保存筛选阈值") { saveRule() }.disabled(savingRule || model.onRule == nil)
                        .accessibilityIdentifier("settings.history.saveRule")
                    if let ruleMessage { Text(ruleMessage).font(.caption).foregroundStyle(.secondary) }
                }
                DisclosureGroup("后台与存储诊断") {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("系统注册：\(model.registration)")
                        if let status = model.status {
                            Text("helper \(status.version) · PID \(status.pid) · 来源 \(status.sourceState.rawValue)")
                            Text("数据库 \(status.coverage.databaseBytes / 1_048_576) MiB · WAL \(status.coverage.walBytes / 1_048_576) MiB")
                            Text("SQLite \(status.sqliteVersion)")
                            if let issue = status.coverage.issue ?? status.sourceIssue { Text(issue) }
                        }
                        if let issue = model.serviceIssue { Text(issue) }
                        Text("本地代码签名与当前用户边界；同用户可修改本地文件，不是防篡改审计记录。")
                        Text("来源为系统 nettop，可能包含回环和代理腿；未采集目标、文件内容或前台状态。")
                    }.font(.caption2).foregroundStyle(.secondary).textSelection(.enabled)
                }
            }.padding(12)
        }.onAppear { loadRule() }
            .onChange(of: model.configuredRule) { _ in loadRule() }
    }
    private func loadRule() {
        largeMiB = String(model.configuredRule.largeBytes / 1_048_576)
        sustainedSeconds = String(Int(model.configuredRule.sustainedSeconds))
        sustainedKiB = String(Int(model.configuredRule.sustainedBytesPerSecond / 1_024))
    }
    private func saveRule() {
        guard let mib = UInt64(largeMiB), (1...1_073_741_824).contains(mib),
              let seconds = Double(sustainedSeconds), let kib = Double(sustainedKiB) else {
            ruleMessage = "请输入范围内的数字。"; return
        }
        let rule = HistoryUploadRule(largeBytes: mib * 1_048_576, sustainedSeconds: seconds, sustainedBytesPerSecond: kib * 1_024)
        guard rule.isValid, let onRule = model.onRule else { ruleMessage = "持续时间需5–86400秒，速率至少1 KiB/s。"; return }
        savingRule = true; ruleMessage = nil
        Task {
            do { try await onRule(rule); ruleMessage = model.desired ? "已保存，后续采样生效。" : "已保存，下次开启后台生效。" }
            catch { ruleMessage = "已保留设置，但后台确认失败，请刷新状态后重试。" }
            savingRule = false
        }
    }
}
