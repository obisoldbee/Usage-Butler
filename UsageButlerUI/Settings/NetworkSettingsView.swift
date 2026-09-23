import SwiftUI
import UsageButlerDomain

struct NetworkSettingsView: View {
    @ObservedObject var model: MenuPanelViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            SettingsSection(title: String(localized: "网络采集")) {
                SettingsRow(
                    title: String(localized: "采集网络用量"),
                    subtitle: String(localized: "仅统计各网络接口字节数；不识别应用，关闭面板不停止采集")
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
                    Text("手动选择仅用于排查 VPN 隧道、网桥或本机回环流量。只改变显示的统计对象，不会切换网络连接。")
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
                VStack(alignment: .leading, spacing: 8) {
                    Text("当前版本统计所选网络接口的上传、下载流量。")
                    Text("按应用流量、连接目标和连接阻断尚未提供，不能通过设置开启。")
                }
                .font(.callout).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .accessibilityIdentifier("settings.network.capabilities")
            }

            SettingsSection(title: String(localized: "统计说明")) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("这里统计的是网络接口，不是应用。物理网络、VPN 隧道和本机回环可能包含同一份流量，不能相加。")
                    Text("“本段累计”从各方向最近一次有效起点计算；计数重置、缺失或接口变化后会重新开始。")
                    Text("趋势最多保留本次运行的最近 2 小时，退出后不恢复。启动前和未采集时段留空，属于正常情况。")
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
