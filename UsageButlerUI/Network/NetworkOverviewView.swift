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
    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let now = context.date
            let name = model.resolvedNetworkInterfaceName
            let source = name.flatMap { model.networkSnapshot?.interfaces[$0] }
            let rate = name.flatMap { model.networkSnapshot?.interfaceRates[$0] }
            let frame = model.networkTrendFrame(now: now, window: model.networkTrendRange.duration)
            let stale = NetworkStatusRules.ratesAreStale(model.networkSnapshot, interface: name, now: now)
            VStack(alignment: .leading, spacing: 12) {
                notices(now: now, name: name, samples: frame.samples)
                NetworkTrendView(range: $model.networkTrendRange, frame: frame, source: source, rate: rate, stale: stale, interface: model.userSelectedNetworkInterface ?? name)
                #if USAGE_BUTLER_FIXTURES
                if model.isFixtureMode { NetworkDemoApplicationsView() }
                #endif
            }
            .onChange(of: now) { _ in model.tickNetworkPathFreshness() }
        }
        .transaction { transaction in
            transaction.animation = nil
            transaction.disablesAnimations = true
        }
    }

    @ViewBuilder
    private func notices(now: Date, name: String?, samples: [NetworkRateSample]) -> some View {
        let health = NetworkStatusRules.currentHealth(model.networkSnapshot, interface: name, now: now)
        if !health.healthy {
            VStack(alignment: .leading, spacing: 4) {
                Label(health.title, systemImage: "circle.dashed")
                    .font(.subheadline.weight(.semibold))
                if model.networkSnapshot?.collectionState == .stopped {
                    Text("可在设置 → 网络中开启采集。")
                        .font(.caption)
                }
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 4)
            .accessibilityIdentifier("network.collectionNotice")
        }
        if let notice = NetworkStatusRules.historyRestartNotice(
            name.flatMap { model.networkSnapshot?.interfaces[$0]?.sessionTotal },
            samples: samples, now: now, window: model.networkTrendRange.duration
        ) {
            Text(notice).font(.caption2).foregroundStyle(.orange)
                .padding(.horizontal, 4)
                .accessibilityIdentifier("network.historyRestart")
        }
    }
}

private struct NetworkTrendView: View {
    @Binding var range: NetworkTrendRange
    let frame: NetworkTrendFrame
    let source: InterfaceCounters?
    let rate: NetworkRate?
    let stale: Bool
    let interface: String?
    @StateObject private var inspection = NetworkInspectionState()
    @State private var uploadAxis = NetworkChartAxis()
    @State private var downloadAxis = NetworkChartAxis()


    var body: some View {
        trend(now: frame.now, source: source, rate: rate, samples: frame.samples, projection: frame.projection, stale: stale)
            .onChange(of: range) { _ in resetAxes() }
            .onChange(of: interface) { _ in resetAxes() }
    }

    private func resetAxes() {
        uploadAxis = NetworkChartAxis(); downloadAxis = NetworkChartAxis()
        inspection.inspectedAt = nil; inspection.pinned = false
    }

    private func trend(now: Date, source: InterfaceCounters?, rate: NetworkRate?, samples: [NetworkRateSample], projection: NetworkChartProjection, stale: Bool) -> some View {
        let uploadPeak = frame.uploadPeak
        let downloadPeak = frame.downloadPeak
        return VStack(alignment: .leading, spacing: 10) {
            Text("流量趋势").font(.subheadline.weight(.semibold))
            HStack(spacing: 3) {
                ForEach(NetworkTrendRange.allCases) { option in
                    Button { range = option } label: {
                        Text(option.title).font(.system(size: 11)).frame(maxWidth: .infinity, minHeight: 32)
                            .background(range == option ? Color.accentColor : Color.clear, in: RoundedRectangle(cornerRadius: 6))
                            .foregroundStyle(range == option ? Color.white : Color.primary)
                            // Plain buttons otherwise only hit-test the text in an unselected cell.
                            .contentShape(Rectangle())
                    }.buttonStyle(.plain).accessibilityIdentifier("network.range.\(option.rawValue)")
                        .accessibilityAddTraits(range == option ? .isSelected : [])
                }
            }.padding(3).background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
            direction(.upload, now: now, points: frame.uploadPoints, current: stale ? nil : rate?.uploadBytesPerSecond,
                      total: source?.sessionTotal?.upload, peak: uploadPeak, bound: uploadAxis.upperBound, samples: samples)
            Divider()
            direction(.download, now: now, points: frame.downloadPoints, current: stale ? nil : rate?.downloadBytesPerSecond,
                      total: source?.sessionTotal?.download, peak: downloadPeak, bound: downloadAxis.upperBound, samples: samples)
            Text(inspectionText(samples: samples))
                .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                .lineLimit(1).frame(height: 16, alignment: .leading)
                .accessibilityIdentifier("network.inspection")
            Text("独立缩放：上下两图等高不代表等速").font(.caption2).foregroundStyle(.secondary)
        }
        .padding(12).background(.background, in: RoundedRectangle(cornerRadius: 12))
        .overlay { RoundedRectangle(cornerRadius: 12).stroke(.separator.opacity(0.55)).allowsHitTesting(false) }
        .background(NetworkChartKeyboard(focused: $inspection.chartFocused, onKey: { key in inspect(key: key, samples: samples) }))
        .onAppear { updateAxes(upload: uploadPeak, download: downloadPeak) }
        .onChange(of: now) { _ in updateAxes(upload: uploadPeak, download: downloadPeak) }
    }

    private func inspectionText(samples: [NetworkRateSample]) -> String {
        guard let inspectedAt = inspection.inspectedAt else { return String(localized: "指向曲线查看速率，点击可固定读数") }
        let sample = frame.inspection.sample(at: inspectedAt)
        return "\(inspectedAt.formatted(date: .omitted, time: .standard)) · ↑ \(NetworkPresentation.rate(sample?.uploadBytesPerSecond)) · ↓ \(NetworkPresentation.rate(sample?.downloadBytesPerSecond))"
    }

    private func updateAxes(upload: Double?, download: Double?) {
        let uptime = ProcessInfo.processInfo.systemUptime
        uploadAxis.update(peak: upload ?? 0, monotonicNow: uptime)
        downloadAxis.update(peak: download ?? 0, monotonicNow: uptime)
    }

    private func direction(_ direction: NetworkChartDirection, now: Date, points: [NetworkChartPoint], current: Double?, total: DirectionByteTotal?, peak: Double?, bound: Double, samples: [NetworkRateSample]) -> some View {
        let color = direction == .upload ? NetworkPresentation.uploadColor : NetworkPresentation.downloadColor
        let title = direction == .upload ? "上传" : "下载"
        let safeBound = max(bound, NetworkChartAxis.ceiling(for: peak ?? 0))
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
                    Text(NetworkPresentation.rate(peak)).monospacedDigit()
                }.font(.caption)
            }
            Text(totalText(total)).font(.caption2).foregroundStyle(.secondary)
            NetworkPlotView(points: points, direction: direction, now: now, window: range.duration,
                safeBound: safeBound, inspection: inspection, lastSample: samples.last?.sampledAt)
                .equatable()
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
        if key == 53 {
            inspection.inspectedAt = nil; inspection.pinned = false; inspection.chartFocused = false
            return true
        }
        guard !samples.isEmpty else { return false }
        let times = samples.map(\.sampledAt)
        let index = inspection.inspectedAt.flatMap { at in times.enumerated().min(by: { abs($0.element.timeIntervalSince(at)) < abs($1.element.timeIntervalSince(at)) })?.offset } ?? times.count - 1
        switch key {
        case 123, 125: inspection.inspectedAt = times[max(0, index - 1)]
        case 124, 126: inspection.inspectedAt = times[min(times.count - 1, index + 1)]
        case 115: inspection.inspectedAt = times.first
        case 119: inspection.inspectedAt = times.last
        case 49: inspection.pinned.toggle(); return true
        default: return false
        }
        inspection.pinned = true
        return true
    }

}

@MainActor
private final class NetworkInspectionState: ObservableObject {
    @Published var inspectedAt: Date?
    @Published var pinned = false
    @Published var chartFocused = false
}

/// Cursor changes invalidate only the overlay and readout. Swift Charts keeps
/// its mark tree until the data, moving window, direction or axis changes.
private struct NetworkPlotView: View, Equatable {
    let points: [NetworkChartPoint]
    let direction: NetworkChartDirection
    let now: Date
    let window: TimeInterval
    let safeBound: Double
    let inspection: NetworkInspectionState
    let lastSample: Date?
    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.now == rhs.now && lhs.window == rhs.window && lhs.safeBound == rhs.safeBound
            && lhs.direction == rhs.direction && lhs.points == rhs.points
            && lhs.inspection === rhs.inspection && lhs.lastSample == rhs.lastSample
    }
    var body: some View {
        let color = direction == .upload ? NetworkPresentation.uploadColor : NetworkPresentation.downloadColor
        let coordinates = NetworkChartCoordinates(now: now, window: window, upperBound: safeBound)
            Chart {
                ForEach(points) { point in
                    AreaMark(x: .value("时间", coordinates.x(at: point.at)), yStart: .value("零", 0), yEnd: .value("速率", coordinates.y(for: point.value)), series: .value("段", point.seriesKey))
                        .foregroundStyle(color.opacity(0.09)).interpolationMethod(.linear)
                        .accessibilityLabel(Text(point.at, format: .dateTime.hour().minute().second()))
                        .accessibilityValue(Text(NetworkPresentation.rate(point.value)))
                    LineMark(x: .value("时间", coordinates.x(at: point.at)), y: .value("速率", coordinates.y(for: point.value)), series: .value("段", point.seriesKey))
                        .foregroundStyle(color).interpolationMethod(.linear).lineStyle(.init(lineWidth: 1.5))
                        .accessibilityLabel(Text(point.at, format: .dateTime.hour().minute().second()))
                        .accessibilityValue(Text(NetworkPresentation.rate(point.value)))
                    if point.isIsolated {
                        PointMark(x: .value("时间", coordinates.x(at: point.at)), y: .value("速率", coordinates.y(for: point.value))).foregroundStyle(color).symbolSize(20)
                            .accessibilityLabel(Text(point.at, format: .dateTime.hour().minute().second()))
                            .accessibilityValue(Text(NetworkPresentation.rate(point.value)))
                    }
                }
            }
            .chartLegend(.hidden)
            .chartXScale(domain: 0.0...1.0)
            .chartYScale(domain: 0.0...1.0)
            .chartYAxis {
                AxisMarks(position: .leading, values: NetworkChartCoordinates.ticks) { value in
                    AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [3, 3]))
                    AxisValueLabel { if let y = value.as(Double.self) { Text(NetworkPresentation.rate(coordinates.rate(atY: y))).font(.system(size: 9)).frame(width: 74, alignment: .trailing) } }
                }
            }
            .chartXAxis {
                AxisMarks(values: NetworkChartCoordinates.ticks) { value in
                    AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [3, 3]))
                    AxisValueLabel(centered: false) {
                        if let x = value.as(Double.self) {
                            Text(coordinates.date(atX: x), format: .dateTime.hour().minute())
                        }
                    }
                }
            }
            .chartOverlay { proxy in
                NetworkInspectionOverlay(proxy: proxy, coordinates: coordinates, inspection: inspection, lastSample: lastSample)
            }
            // Charts' automatic AX buckets describe the drawing coordinates.
            // Replace those children with source samples as well as providing
            // the original-unit Audio Graph descriptor below.
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(direction == .upload ? "上传趋势" : "下载趋势")
            .accessibilityChildren {
                ForEach(points) { point in
                    Rectangle()
                        .accessibilityElement()
                        .accessibilityLabel(Text(point.at, format: .dateTime.hour().minute().second()))
                        .accessibilityValue(NetworkPresentation.rate(point.value))
                }
            }
            .accessibilityChartDescriptor(NetworkChartAccessibility(points: points, direction: direction, coordinates: coordinates))
    }
}

private struct NetworkInspectionOverlay: View {
    let proxy: ChartProxy
    let coordinates: NetworkChartCoordinates
    @ObservedObject var inspection: NetworkInspectionState
    let lastSample: Date?
    var body: some View {
        GeometryReader { geometry in
            let plot = geometry[proxy.plotAreaFrame]
            ZStack(alignment: .topLeading) {
                if let at = inspection.inspectedAt, let x = proxy.position(forX: coordinates.x(at: at)), x >= 0, x <= plot.width {
                    Rectangle().fill(.secondary.opacity(0.5)).frame(width: 1, height: plot.height)
                        .offset(x: plot.minX + x, y: plot.minY).allowsHitTesting(false)
                }
                Rectangle().fill(Color.clear).contentShape(Rectangle())
                    .onContinuousHover { phase in
                        guard !inspection.pinned else { return }
                        switch phase {
                        case let .active(point):
                            let x: Double? = proxy.value(atX: point.x - plot.minX)
                            inspection.inspectedAt = x.map { coordinates.date(atX: $0) }
                        case .ended: inspection.inspectedAt = nil
                        }
                    }
                    .onTapGesture {
                        inspection.pinned.toggle(); inspection.chartFocused = true
                        if inspection.inspectedAt == nil { inspection.inspectedAt = lastSample }
                    }
            }
        }
    }
}

struct NetworkChartKeyboard: NSViewRepresentable {
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
            guard event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty,
                  onKey?(event.keyCode) == true else { super.keyDown(with: event); return }
            // Clearing the SwiftUI flag alone leaves this native view as first
            // responder. Release it at the Escape event boundary so bare Tab
            // can return to the panel's page routing.
            if event.keyCode == 53 { window?.makeFirstResponder(nil) }
        }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}

#if DEBUG
/// Exercises the shipping plot implementation without a collector or timer
/// inside the view. The Debug app harness supplies an accelerated clock.
public struct NetworkPlotMemoryProbeView: View {
    public let now: Date
    public let window: TimeInterval
    public let points: [NetworkChartPoint]
    public let upperBound: Double
    public let onRender: () -> Void
    @StateObject private var inspection = NetworkInspectionState()

    public init(now: Date, window: TimeInterval, points: [NetworkChartPoint], upperBound: Double, onRender: @escaping () -> Void) {
        self.now = now; self.window = window; self.points = points
        self.upperBound = upperBound; self.onRender = onRender
    }

    public var body: some View {
        let _ = onRender()
        VStack(spacing: 16) {
            ForEach(NetworkChartDirection.allCases, id: \.self) { direction in
                NetworkPlotView(points: points.filter { $0.direction == direction }, direction: direction,
                    now: now, window: window, safeBound: direction == .upload ? upperBound : upperBound * 100,
                    inspection: inspection, lastSample: now)
                    .frame(height: 140)
            }
        }.transaction { $0.animation = nil; $0.disablesAnimations = true }
    }
}
#endif
