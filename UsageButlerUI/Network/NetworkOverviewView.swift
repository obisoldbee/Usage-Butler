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
    let onOpenSettingsFallback: () -> Void
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
                status(now: now, name: name, samples: samples)
                observationSummary
                trend(now: now, source: source, rate: rate, samples: samples, projection: projection, stale: stale)
                #if USAGE_BUTLER_FIXTURES
                if model.isFixtureMode { NetworkDemoApplicationsView() } else { unavailableApps }
                #else
                unavailableApps
                #endif
            }
            .onChange(of: model.networkTrendRange) { _ in resetAxes() }
            .onChange(of: name) { _ in resetAxes() }
        }
        .transaction { transaction in
            transaction.animation = nil
            transaction.disablesAnimations = true
        }
    }

    private func resetAxes() {
        uploadAxis = NetworkChartAxis(); downloadAxis = NetworkChartAxis()
        inspectedAt = nil; pinned = false
    }

    private func status(now: Date, name: String?, samples: [NetworkRateSample]) -> some View {
        let health = NetworkStatusRules.currentHealth(model.networkSnapshot, interface: name, now: now)
        return HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 4) {
                Label(health.title, systemImage: health.healthy ? "circle.fill" : "circle.dashed")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(health.healthy ? Color.green : Color.secondary)
                Text("仅监控 / 防护未开启").font(.caption).foregroundStyle(.secondary)
                if let notice = NetworkStatusRules.historyRestartNotice(
                    name.flatMap { model.networkSnapshot?.interfaces[$0]?.sessionTotal },
                    samples: samples, now: now, window: model.networkTrendRange.duration
                ) {
                    Text(notice).font(.caption2).foregroundStyle(.orange)
                        .accessibilityIdentifier("network.historyRestart")
                }
            }
            Spacer()
            Button(model.networkCollectionEnabled ? "停止采集" : "启用采集") {
                model.setNetworkCollectionEnabled(!model.networkCollectionEnabled)
            }.accessibilityIdentifier("network.toggleCollection")
        }.padding(.horizontal, 4)
    }

    private var observationSummary: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: "network").foregroundStyle(.secondary)
                Text(model.networkObservationLabel.isEmpty
                     ? String(localized: "当前统计网络待确认")
                     : model.networkObservationLabel)
                    .font(.subheadline).lineLimit(2)
                Spacer()
                NetworkSettingsButton(model: model, onOpenSettingsFallback: onOpenSettingsFallback)
                    .buttonStyle(.borderless)
                    .accessibilityIdentifier("network.openSettings")
                    .help("选择统计的网络，查看统计说明")
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
                        Text(range.title).font(.system(size: 11)).frame(maxWidth: .infinity, minHeight: 32)
                            .background(model.networkTrendRange == range ? Color.accentColor : Color.clear, in: RoundedRectangle(cornerRadius: 6))
                            .foregroundStyle(model.networkTrendRange == range ? Color.white : Color.primary)
                            // Plain buttons otherwise only hit-test the text in an unselected cell.
                            .contentShape(Rectangle())
                    }.buttonStyle(.plain).accessibilityIdentifier("network.range.\(range.rawValue)")
                        .accessibilityAddTraits(model.networkTrendRange == range ? .isSelected : [])
                }
            }.padding(3).background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
            direction(.upload, now: now, points: projection.points(.upload), current: stale ? nil : rate?.uploadBytesPerSecond,
                      total: source?.sessionTotal?.upload, peak: uploadPeak, bound: uploadAxis.upperBound, samples: samples)
            Divider()
            direction(.download, now: now, points: projection.points(.download), current: stale ? nil : rate?.downloadBytesPerSecond,
                      total: source?.sessionTotal?.download, peak: downloadPeak, bound: downloadAxis.upperBound, samples: samples)
            Text(inspectionText(samples: samples))
                .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                .lineLimit(1).frame(height: 16, alignment: .leading)
                .accessibilityIdentifier("network.inspection")
            Text("独立缩放：上下两图等高不代表等速").font(.caption2).foregroundStyle(.secondary)
        }
        .padding(12).background(.background, in: RoundedRectangle(cornerRadius: 12))
        .overlay { RoundedRectangle(cornerRadius: 12).stroke(.separator.opacity(0.55)).allowsHitTesting(false) }
        .background(NetworkChartKeyboard(focused: $chartFocused, onKey: { key in inspect(key: key, samples: samples) }))
        .onAppear { updateAxes(upload: uploadPeak, download: downloadPeak) }
        .onChange(of: now) { _ in updateAxes(upload: uploadPeak, download: downloadPeak) }
    }

    private func inspectionText(samples: [NetworkRateSample]) -> String {
        guard let inspectedAt else { return String(localized: "指向曲线查看速率，点击可固定读数") }
        let sample = NetworkChartInspection.sample(at: inspectedAt, in: samples)
        return "\(inspectedAt.formatted(date: .omitted, time: .standard)) · ↑ \(NetworkPresentation.rate(sample?.uploadBytesPerSecond)) · ↓ \(NetworkPresentation.rate(sample?.downloadBytesPerSecond))"
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
