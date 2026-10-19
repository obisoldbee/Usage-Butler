import SwiftUI
import UsageButlerDomain

struct NetworkSettingsView: View {
    @ObservedObject var model: MenuPanelViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            BackgroundHistorySettingsView(model: model.backgroundNetwork)
            SettingsSection(title: String(localized: "网络采集")) {
                SettingsRow(
                    title: String(localized: "采集网络用量"),
                    subtitle: String(localized: "控制接口趋势和应用记录")
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

            SettingsSection(title: String(localized: "网络选择")) {
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
                    Text("自动跟随当前网络。")
                    Text("手动选择仅改变设备流量趋势视图，不影响应用统计，亦不会切换实际网络连接。")
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

            SettingsSection(title: String(localized: "统计说明")) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("接口与应用分别统计，不能相加。应用流量包含本机通信和代理转发，可能重复计数。")
                    Text("“本段累计”从最近一次有效读数开始；采样中断、计数重置或网卡变化后会重新起算。")
                    Text("设备流量展示本次运行的最近 2 小时趋势。应用最近 1 分钟展示实时采样，更早记录按分钟汇总并持续保留。")
                    Text("仅记录流量，不阻断连接，也不记录连接目标或传输内容；可能漏掉运行时间很短的进程。")
                }
                .font(.callout).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .accessibilityIdentifier("settings.network.capabilities")
            }

            DisclosureGroup("技术信息") {
                ProcessNetworkSourceStatus(model: model.processNetwork)
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
            Text("后台上限：2,048进程 / 256当前应用 / 15,360个最近原始点。客户端只接收已选应用的最近60秒原始历史。")
            if let snapshot = model.snapshot {
                Text("当前保留 \(snapshot.applications.count) 个应用 / \(snapshot.historyPointCount) 个历史点")
                if let issue = snapshot.issue { Text("来源诊断：\(issue)") }
                if snapshot.truncated { Text("已触发资源裁剪，保留历史可能不足所选范围。") }
            }
        }.font(.caption).foregroundStyle(.secondary).padding(12)
            .accessibilityIdentifier("settings.network.processSource")
    }
    private var title: String {
        model.observationTitle
    }
}
