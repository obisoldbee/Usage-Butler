import AppKit
import Charts
import SwiftUI
import UsageButlerCore
import UsageButlerDomain

enum NetworkPresentation {
    static let uploadColor = Color(red: 0.90, green: 0.24, blue: 0.35)
    static let downloadColor = Color(red: 0.03, green: 0.48, blue: 1)
    static func bytes(_ value: UInt64?) -> String {
        value.map { scaled(Double($0), unit: "B") } ?? "未知"
    }
    static func rate(_ value: Double?) -> String {
        guard let value, value.isFinite, value >= 0 else { return "未知" }
        return scaled(value, unit: "B/s")
    }
    private static func scaled(_ value: Double, unit: String) -> String {
        switch value {
        case 1e9...: return String(format: "%.2f G%@", value / 1e9, unit)
        case 1e6...: return String(format: "%.1f M%@", value / 1e6, unit)
        case 1e3...: return String(format: "%.1f K%@", value / 1e3, unit)
        case 0: return "0 \(unit)"
        case ..<1: return String(format: "%.3g %@", value, unit)
        default: return String(format: "%.0f %@", value, unit)
        }
    }
    static func interfaceKindTitle(_ kind: NetworkInterfaceKind) -> String {
        switch kind {
        case .physical: "物理"
        case .tunnel: "隧道"
        case .loopback: "回环"
        case .bridge: "网桥"
        case .other: "其他"
        }
    }
}

struct NetworkOverviewView: View {
    @ObservedObject var model: MenuPanelViewModel
    @State private var advanced = false
    @State private var details = false
    @State private var inspectedAt: Date?
    @State private var pinned = false
    @State private var chartFocused = false
    @State private var uploadAxis = NetworkChartAxis()
    @State private var downloadAxis = NetworkChartAxis()

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let now = context.date
            let name = model.resolvedNetworkInterfaceName
            let source = name.flatMap { model.networkSnapshot?.interfaces[$0] }
            let rate = name.flatMap { model.networkSnapshot?.interfaceRates[$0] }
            let samples = (name.map { model.networkRateHistory.series(for: $0) } ?? []).filter {
                $0.sampledAt > now.addingTimeInterval(-model.networkTrendRange.duration) && $0.sampledAt <= now
            }
            let projection = model.networkTrendProjection(now: now, window: model.networkTrendRange.duration)
            let stale = NetworkStatusRules.ratesAreStale(model.networkSnapshot, interface: name, now: now)
            VStack(alignment: .leading, spacing: 12) {
                status(now: now, name: name)
                observationSelector
                trend(now: now, source: source, rate: rate, samples: samples, projection: projection, stale: stale)
                #if USAGE_BUTLER_FIXTURES
                if model.isFixtureMode { NetworkDemoApplicationsView() } else { unavailableApps }
                #else
                unavailableApps
                #endif
                DisclosureGroup("统计说明", isExpanded: $details) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("接口与应用是不同口径；物理接口、隧道与回环不相加。")
                        if let source {
                            Text("原始接口计数（起点未验证） 上传 \(NetworkPresentation.bytes(source.counters.bytes.upload)) · 下载 \(NetworkPresentation.bytes(source.counters.bytes.download))")
                            Text("源采样时间 \(source.asOf.formatted(date: .omitted, time: .standard))")
                        }
                        if let notice = model.networkCoverageNotice { Text("全接口诊断：\(notice)") }
                        Text("本段累计只包括各方向当前可验证段；重置、缺失或 epoch 变化会重新建立对应基线。")
                        Text("历史最多保留本进程最近 2 小时；退出后不恢复。")
                    }.font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                }.accessibilityIdentifier("network.diagnostics")
            }
            .onChange(of: model.networkTrendRange) { _ in resetAxes() }
            .onChange(of: name) { _ in resetAxes() }
        }
    }

    private func resetAxes() {
        uploadAxis = NetworkChartAxis(); downloadAxis = NetworkChartAxis()
        inspectedAt = nil; pinned = false
    }

    private func status(now: Date, name: String?) -> some View {
        let health = NetworkStatusRules.currentHealth(model.networkSnapshot, interface: name, now: now)
        return HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 4) {
                Label(health.title, systemImage: health.healthy ? "circle.fill" : "circle.dashed")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(health.healthy ? Color.green : Color.secondary)
                Text("仅监控 / 防护未开启").font(.caption).foregroundStyle(.secondary)
                if let total = name.flatMap({ model.networkSnapshot?.interfaces[$0]?.sessionTotal }), !total.isContinuous {
                    Text("当前接口历史不完整 · 详见统计说明").font(.caption2).foregroundStyle(.orange)
                }
            }
            Spacer()
            Button(model.networkCollectionEnabled ? "停止采集" : "启用采集") {
                model.setNetworkCollectionEnabled(!model.networkCollectionEnabled)
            }.accessibilityIdentifier("network.toggleCollection")
        }.padding(.horizontal, 4)
    }

    private var observationSelector: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: "network").foregroundStyle(.secondary)
                Text(model.networkObservationIsAutomatic ? "自动 · \(model.networkObservationLabel)" : model.networkObservationLabel)
                    .font(.subheadline).lineLimit(2)
                Spacer()
                Button(advanced ? "收起" : "高级") { advanced.toggle() }
                    .buttonStyle(.borderless).accessibilityIdentifier("network.advanced")
            }
            if advanced {
                Picker("查看网络", selection: Binding(get: { model.networkObservationSelection }, set: { model.networkObservationSelection = $0 })) {
                    Text("自动（系统当前网络）").tag("")
                    ForEach(model.networkAdvancedInterfaceGroups) { group in
                        Section(NetworkPresentation.interfaceKindTitle(group.kind)) {
                            ForEach(group.interfaces, id: \.self) { Text($0).tag($0) }
                        }
                    }
                    if case let .manualUnavailable(name) = model.networkObservationResolution {
                        Text("\(name) · 已消失").tag(name)
                    }
                }.accessibilityIdentifier("network.interfacePicker")
            }
            Text(model.networkObservationSourceText).font(.caption2).foregroundStyle(.secondary)
        }.padding(10).background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 9))
    }

    private func trend(now: Date, source: InterfaceCounters?, rate: NetworkRate?, samples: [NetworkRateSample], projection: NetworkChartProjection, stale: Bool) -> some View {
        let uploadPeak = samples.compactMap(\.uploadBytesPerSecond).max() ?? 0
        let downloadPeak = samples.compactMap(\.downloadBytesPerSecond).max() ?? 0
        return VStack(alignment: .leading, spacing: 10) {
            Text("流量趋势").font(.subheadline.weight(.semibold))
            HStack(spacing: 3) {
                ForEach(NetworkTrendRange.allCases) { range in
                    Button { model.networkTrendRange = range } label: {
                        Text(range.title).font(.system(size: 11)).frame(maxWidth: .infinity).padding(.vertical, 6)
                            .background(model.networkTrendRange == range ? Color.accentColor : Color.clear, in: RoundedRectangle(cornerRadius: 6))
                            .foregroundStyle(model.networkTrendRange == range ? Color.white : Color.primary)
                    }.buttonStyle(.plain).accessibilityIdentifier("network.range.\(range.rawValue)")
                        .accessibilityAddTraits(model.networkTrendRange == range ? .isSelected : [])
                }
            }.padding(3).background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
            direction(.upload, now: now, points: projection.points(.upload), current: stale ? nil : rate?.uploadBytesPerSecond,
                      total: source?.sessionTotal?.upload, peak: uploadPeak, bound: uploadAxis.upperBound, samples: samples)
            Divider()
            direction(.download, now: now, points: projection.points(.download), current: stale ? nil : rate?.downloadBytesPerSecond,
                      total: source?.sessionTotal?.download, peak: downloadPeak, bound: downloadAxis.upperBound, samples: samples)
            if let inspectedAt {
                let sample = NetworkChartInspection.sample(at: inspectedAt, in: samples)
                Text("\(inspectedAt.formatted(date: .omitted, time: .standard)) · ↑ \(NetworkPresentation.rate(sample?.uploadBytesPerSecond)) · ↓ \(NetworkPresentation.rate(sample?.downloadBytesPerSecond))")
                    .font(.caption).monospacedDigit().accessibilityIdentifier("network.inspection")
            }
            Text("独立缩放：上下两图等高不代表等速").font(.caption2).foregroundStyle(.secondary)
            if projection.thinnedSegmentCount > 0 {
                Text("按峰谷抽稀显示，原始样本保留").font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(12).background(.background, in: RoundedRectangle(cornerRadius: 12))
        .overlay { RoundedRectangle(cornerRadius: 12).stroke(.separator.opacity(0.55)) }
        .background(NetworkChartKeyboard(focused: $chartFocused, onKey: { key in inspect(key: key, samples: samples) }))
        .onAppear { updateAxes(upload: uploadPeak, download: downloadPeak) }
        .onChange(of: now) { _ in updateAxes(upload: uploadPeak, download: downloadPeak) }
    }

    private func updateAxes(upload: Double, download: Double) {
        let uptime = ProcessInfo.processInfo.systemUptime
        uploadAxis.update(peak: upload, monotonicNow: uptime)
        downloadAxis.update(peak: download, monotonicNow: uptime)
    }

    private func direction(_ direction: NetworkChartDirection, now: Date, points: [NetworkChartPoint], current: Double?, total: DirectionByteTotal?, peak: Double, bound: Double, samples: [NetworkRateSample]) -> some View {
        let color = direction == .upload ? NetworkPresentation.uploadColor : NetworkPresentation.downloadColor
        let title = direction == .upload ? "上传" : "下载"
        let safeBound = max(bound, NetworkChartAxis.ceiling(for: peak))
        return VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .bottom) {
                VStack(alignment: .leading, spacing: 3) {
                    Label(title, systemImage: direction == .upload ? "arrow.up" : "arrow.down").foregroundStyle(color).font(.subheadline.weight(.semibold))
                    Text(NetworkPresentation.rate(current)).font(.system(size: 23, weight: .semibold).monospacedDigit())
                        .accessibilityIdentifier("network.rate.\(direction.rawValue)")
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 3) {
                    Text("所选范围峰值").foregroundStyle(.secondary)
                    Text(NetworkPresentation.rate(points.isEmpty ? nil : peak)).monospacedDigit()
                }.font(.caption)
            }
            Text(totalText(total)).font(.caption2).foregroundStyle(.secondary)
            Chart {
                ForEach(points) { point in
                    AreaMark(x: .value("时间", point.at), yStart: .value("零", 0), yEnd: .value("速率", point.value), series: .value("段", point.seriesKey))
                        .foregroundStyle(color.opacity(0.09)).interpolationMethod(.linear)
                    LineMark(x: .value("时间", point.at), y: .value("速率", point.value), series: .value("段", point.seriesKey))
                        .foregroundStyle(color).interpolationMethod(.linear).lineStyle(.init(lineWidth: 1.5))
                    if point.isIsolated {
                        PointMark(x: .value("时间", point.at), y: .value("速率", point.value)).foregroundStyle(color).symbolSize(20)
                    }
                }
                if let inspectedAt { RuleMark(x: .value("查看时间", inspectedAt)).foregroundStyle(.secondary.opacity(0.5)) }
            }
            .chartLegend(.hidden)
            .chartXScale(domain: now.addingTimeInterval(-model.networkTrendRange.duration)...now)
            .chartYScale(domain: 0...safeBound)
            .chartYAxis {
                AxisMarks(position: .leading, values: [0, safeBound / 2, safeBound]) { value in
                    AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [3, 3]))
                    AxisValueLabel { if let rate = value.as(Double.self) { Text(NetworkPresentation.rate(rate)).font(.system(size: 9)).frame(width: 74, alignment: .trailing) } }
                }
            }
            .chartXAxis {
                AxisMarks(values: [now.addingTimeInterval(-model.networkTrendRange.duration), now.addingTimeInterval(-model.networkTrendRange.duration / 2), now]) {
                    AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [3, 3]))
                    AxisValueLabel(format: .dateTime.hour().minute(), centered: false)
                }
            }
            .chartOverlay { proxy in
                GeometryReader { geometry in
                    Rectangle().fill(Color.clear).contentShape(Rectangle())
                        .onContinuousHover { phase in
                            guard !pinned else { return }
                            switch phase {
                            case let .active(point): inspectedAt = proxy.value(atX: point.x - geometry[proxy.plotAreaFrame].minX)
                            case .ended: inspectedAt = nil
                            }
                        }
                        .onTapGesture { pinned.toggle(); chartFocused = true; if inspectedAt == nil { inspectedAt = samples.last?.sampledAt } }
                }
            }
            .frame(height: 112)
            .overlay { if points.isEmpty { Text("暂无已知速率 · 未采样区间留空").font(.caption2).foregroundStyle(.secondary) } }
            .accessibilityLabel("\(title)趋势，单位字节每秒，独立纵轴")
            .accessibilityValue("当前 \(NetworkPresentation.rate(current))，峰值 \(NetworkPresentation.rate(peak))")
            .accessibilityIdentifier("network.chart.\(direction.rawValue)")
        }
    }

    private func totalText(_ total: DirectionByteTotal?) -> String {
        guard let total else { return "本段累计：未知，等待基线" }
        let since = total.since.map { "自 \($0.formatted(date: .omitted, time: .standard))" } ?? "起点未校验"
        return "本段累计 \(NetworkPresentation.bytes(total.bytes)) · \(since)"
    }

    private func inspect(key: UInt16, samples: [NetworkRateSample]) -> Bool {
        guard !samples.isEmpty else { return false }
        let times = samples.map(\.sampledAt)
        let index = inspectedAt.flatMap { at in times.enumerated().min(by: { abs($0.element.timeIntervalSince(at)) < abs($1.element.timeIntervalSince(at)) })?.offset } ?? times.count - 1
        switch key {
        case 123, 125: inspectedAt = times[max(0, index - 1)]
        case 124, 126: inspectedAt = times[min(times.count - 1, index + 1)]
        case 115: inspectedAt = times.first
        case 119: inspectedAt = times.last
        case 53: inspectedAt = nil; pinned = false; chartFocused = false; return true
        case 49: pinned.toggle(); return true
        default: return false
        }
        pinned = true
        return true
    }

    private var unavailableApps: some View {
        VStack(alignment: .leading, spacing: 5) {
            Label("按应用统计尚未接入", systemImage: "shield.lefthalf.filled").font(.subheadline.weight(.semibold))
            Text("当前只能观察单个接口；应用、目标与连接阻断不可用。").font(.caption).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity, alignment: .leading).padding(12)
            .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 12))
    }
}

private struct NetworkChartKeyboard: NSViewRepresentable {
    @Binding var focused: Bool
    var onKey: (UInt16) -> Bool
    func makeNSView(context: Context) -> KeyView { KeyView() }
    func updateNSView(_ view: KeyView, context: Context) {
        view.onKey = onKey
        view.onResign = { focused = false }
        if focused, view.window?.firstResponder !== view { view.window?.makeFirstResponder(view) }
    }
    final class KeyView: NSView {
        var onKey: ((UInt16) -> Bool)?
        var onResign: (() -> Void)?
        override func resignFirstResponder() -> Bool {
            onResign?()
            return super.resignFirstResponder()
        }
        override var acceptsFirstResponder: Bool { true }
        override func keyDown(with event: NSEvent) {
            if onKey?(event.keyCode) != true { super.keyDown(with: event) }
        }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}
