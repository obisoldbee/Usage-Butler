import SwiftUI
import UsageButlerDomain

struct NetworkSettingsView: View {
    @ObservedObject var model: MenuPanelViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            SettingsSection(title: String(localized: "网络采集")) {
                SettingsRow(
                    title: String(localized: "采集网络用量"),
                    subtitle: String(localized: "统计接口及系统可见应用进程；关闭面板不停止采集")
                ) {
                    // Show the collector's acknowledged state, not an optimistic preference.
                    Toggle("采集网络用量", isOn: Binding(
                        get: { model.networkCollectionEnabled },
                        set: { model.setNetworkCollectionEnabled($0) }
                    ))
                    .labelsHidden()
                    .accessibilityIdentifier("settings.network.collectionEnabled")
                }
                Divider()
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    let health = NetworkStatusRules.currentHealth(
                        model.networkSnapshot, interface: model.resolvedNetworkInterfaceName, now: context.date
                    )
                    SettingsRow(title: String(localized: "采集状态"), subtitle: nil) {
                        Label(health.title, systemImage: health.healthy ? "circle.fill" : "circle.dashed")
                            .foregroundStyle(health.healthy ? Color.green : Color.secondary)
                            .accessibilityIdentifier("settings.network.collectionStatus")
                    }
                }
            }

            SettingsSection(title: String(localized: "统计哪个网络")) {
                VStack(alignment: .leading, spacing: 10) {
                    Picker("统计对象", selection: Binding(
                        get: { model.networkObservationSelection },
                        set: { model.networkObservationSelection = $0 }
                    )) {
                        Text("自动（推荐）").tag("")
                        ForEach(model.networkAdvancedInterfaceGroups) { group in
                            Section(NetworkPresentation.interfaceKindTitle(group.kind)) {
                                ForEach(group.interfaces, id: \.self) { Text(model.networkInterfaceOptionTitle($0)).tag($0) }
                            }
                        }
                        if let name = model.userSelectedNetworkInterface, model.networkSnapshot?.interfaces[name] == nil {
                            Text(model.networkInterfaceOptionTitle(name)).tag(name)
                        }
                    }
                    .accessibilityIdentifier("settings.network.interfacePicker")
                    Text("自动会跟随系统当前连接的网络，通常无需修改。")
                    Text("手动选择仅用于排查 VPN 隧道、网桥或本机回环流量。只改变接口趋势，不影响应用统计，也不会切换网络连接。")
                        .foregroundStyle(.secondary)
                    Divider()
                    if !model.networkObservationLabel.isEmpty {
                        Text("当前统计：\(model.networkObservationLabel)")
                    }
                    Text(model.networkObservationSourceText).foregroundStyle(.secondary)
                }
                .font(.callout)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
            }

            SettingsSection(title: String(localized: "功能范围")) {
                ProcessNetworkSourceStatus(model: model.processNetwork)
                VStack(alignment: .leading, spacing: 8) {
                    Text("接口趋势统计所选网络；应用活动独立统计系统可见进程。")
                    Text("应用来源为系统 nettop。连接目标、协议、连接数及连接阻断尚未提供。")
                }
                .font(.callout).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .accessibilityIdentifier("settings.network.capabilities")
            }

            SettingsSection(title: String(localized: "统计说明")) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("接口与应用是不同统计口径，不能相加。应用统计包含来源计入的回环和代理腿，不是外网账单；无法看到所有短命进程。")
                    Text("“本段累计”从各方向最近一次有效起点计算；计数重置、缺失或接口变化后会重新开始。")
                    Text("趋势最多保留本次运行的最近 2 小时；应用共用 65,536 点预算，可能更短。退出后不恢复。启动前和未采集时段留空，属于正常情况。")
                    Text("上传、下载独立缩放，两张图同样高不代表速率相同。长时间范围会保留峰谷简化绘图，原始样本仍保留。")
                }
                .font(.callout).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
            }

            SettingsSection(title: String(localized: "当前采样信息")) {
                VStack(alignment: .leading, spacing: 6) {
                    if let name = model.resolvedNetworkInterfaceName,
                       let source = model.networkSnapshot?.interfaces[name] {
                        Text("原始接口计数（起点未验证） 上传 \(NetworkPresentation.bytes(source.counters.bytes.upload)) · 下载 \(NetworkPresentation.bytes(source.counters.bytes.download))")
                        Text("源采样时间 \(source.asOf.formatted(date: .omitted, time: .standard))")
                        if let total = source.sessionTotal {
                            segmentDiagnostic("上传", total.upload)
                            segmentDiagnostic("下载", total.download)
                        }
                    } else {
                        Text("当前没有可用的接口采样。")
                    }
                    if let notice = model.networkCoverageNotice { Text("全接口诊断：\(notice)") }
                }
                .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
            }
        }
    }

    @ViewBuilder
    private func segmentDiagnostic(_ title: String, _ segment: DirectionByteTotal) -> some View {
        if let reason = segment.breakReason {
            let time = segment.since.map { $0.formatted(date: .omitted, time: .standard) } ?? String(localized: "时点未知")
            Text("\(title) · \(time) · \(NetworkStatusRules.sessionTotalReasonText(reason))")
        }
    }
}

private struct ProcessNetworkSourceStatus: View {
    @ObservedObject var model: ProcessNetworkViewModel
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("应用来源：\(title)").font(.callout)
            Text("nettop 进程 socket 计数 · PTY 分帧约 1 秒延迟 · 目标采样 1 Hz")
            Text("上限：2,048 进程 / 256 应用 / 65,536 历史点；单应用最多 2 小时。")
            if let snapshot = model.snapshot {
                Text("当前保留 \(snapshot.applications.count) 个应用 / \(snapshot.historyPointCount) 个历史点")
                if let issue = snapshot.issue { Text("来源诊断：\(issue)") }
                if snapshot.truncated { Text("已触发资源裁剪，保留历史可能不足所选范围。") }
            }
        }.font(.caption).foregroundStyle(.secondary).padding(12)
            .accessibilityIdentifier("settings.network.processSource")
    }
    private var title: String {
        switch model.snapshot?.state ?? .stopped {
        case .stopped: "已停止"
        case .starting: "正在建立基线"
        case .active: "正在采集系统可见进程"
        case .partial: "部分读数不可用"
        case .unavailable: "暂不可用（接口来源独立）"
        }
    }
}
