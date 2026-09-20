import Charts
import SwiftUI
import UsageButlerCore
import UsageButlerDomain

/// Decimal-unit presentation helpers and PRD colors for the network page.
/// Rates and totals use decimal B/KB/MB/GB (PRD §13), unlike the memory
/// page's binary units.
enum NetworkPresentation {
    static let uploadColor = Color(red: 0xfa / 255, green: 0x41 / 255, blue: 0x59 / 255)
    static let downloadColor = Color(red: 0x08 / 255, green: 0x7b / 255, blue: 0xff / 255)

    /// Unknown is rendered as 未知, never as zero (NET-08).
    static func bytes(_ value: UInt64?) -> String {
        guard let value else { return String(localized: "未知") }
        return scaled(Double(value), unit: "B")
    }

    static func rate(_ bytesPerSecond: Double?) -> String {
        guard let bytesPerSecond, bytesPerSecond.isFinite, bytesPerSecond >= 0 else {
            return String(localized: "未知")
        }
        return scaled(bytesPerSecond, unit: "B/s")
    }

    private static func scaled(_ value: Double, unit: String) -> String {
        let kilo = 1_000.0
        let mega = 1_000_000.0
        let giga = 1_000_000_000.0
        switch value {
        case giga...: return String(format: "%.2f G%@", value / giga, unit)
        case mega...: return String(format: "%.1f M%@", value / mega, unit)
        case kilo...: return String(format: "%.1f K%@", value / kilo, unit)
        default: return String(format: "%.0f %@", value, unit)
        }
    }

    static func interfaceKindTitle(_ kind: NetworkInterfaceKind) -> String {
        switch kind {
        case .physical: String(localized: "物理")
        case .tunnel: String(localized: "隧道")
        case .loopback: String(localized: "回环")
        case .bridge: String(localized: "网桥")
        case .other: String(localized: "其他")
        }
    }
}

/// Network overview page (NET-01…NET-03). Everything renders from the latest
/// complete `NetworkSnapshot`; nothing accumulates across snapshots except
/// the VM-owned rate history buffer feeding the trend chart.
struct NetworkOverviewView: View {
    @ObservedObject var model: MenuPanelViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            statusCard
            interfaceCard
            rateCard
            trendCard
            appsCard
        }
        .accessibilityIdentifier("network.overview")
    }

    // MARK: - Status

    private var statusCard: some View {
        card {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 10) {
                    Image(systemName: stateSymbol)
                        .foregroundStyle(stateColor)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(stateTitle)
                            .font(.headline)
                        Text(stateDetail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(model.networkCollectionEnabled
                        ? String(localized: "停止采集")
                        : String(localized: "启用采集")
                    ) {
                        model.setNetworkCollectionEnabled(!model.networkCollectionEnabled)
                    }
                    .accessibilityIdentifier("network.toggleCollection")
                }
                // Coverage is disclosed wherever it degrades the reading, not
                // only when the state enum happens to say `partial`.
                if let notice = model.networkCoverageNotice {
                    Label(notice, systemImage: "exclamationmark.arrow.triangle.2.circlepath")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("network.coverage.notice")
                }
                // Scope, not a status: shown whether or not anything is wrong,
                // because "it can see my traffic" is not "it can stop it".
                Text(NetworkStatusRules.monitoringOnlyNotice)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("network.monitoringOnly")
            }
        }
    }

    private var stateSymbol: String {
        switch model.networkSnapshot?.collectionState {
        case .active: "dot.radiowaves.left.and.right"
        case .starting: "hourglass"
        case .partial: "exclamationmark.triangle"
        case .disconnected: "bolt.horizontal.circle"
        case .waitingAuthorization: "lock.shield"
        case .denied: "lock.slash"
        case .stopped, nil: "pause.circle"
        }
    }

    private var stateColor: Color {
        switch model.networkSnapshot?.collectionState {
        // Green means the data is good, not merely that collection is on:
        // degraded coverage or a stale reading has to cost the green light.
        case .active: model.networkStatusIsHealthy ? .green : .orange
        case .starting: .orange
        case .partial: .orange
        case .disconnected: .red
        case .waitingAuthorization, .denied: .orange
        case .stopped, nil: .secondary
        }
    }

    private var stateTitle: String {
        switch model.networkSnapshot?.collectionState {
        case .active: String(localized: "采集中")
        case .starting: String(localized: "正在启动采集")
        case .partial: String(localized: "采集中 · 覆盖不完整")
        case .disconnected: String(localized: "采集已断开")
        case .waitingAuthorization: String(localized: "等待系统授权")
        case .denied: String(localized: "系统权限被拒绝")
        case .stopped: String(localized: "未采集")
        case nil: String(localized: "尚未获取网络快照")
        }
    }

    private var stateDetail: String {
        switch model.networkSnapshot?.collectionState {
        case .active, .partial:
            String(localized: "仅统计各接口字节数；按应用统计见下方说明")
        case .starting:
            String(localized: "正在读取接口计数器…")
        case let .disconnected(since):
            String(localized: "显示 \(since.formatted(date: .omitted, time: .shortened)) 前最后已知数据")
        case .denied, .waitingAuthorization:
            String(localized: "接口统计不需要特殊权限；按应用与拦截功能不可用")
        case .stopped:
            String(localized: "启用后仅读取接口字节计数，不产生按应用数据")
        case nil:
            String(localized: "运行时尚未发布网络快照")
        }
    }

    // MARK: - 查看网络 (NET-02 / PRD §13.4.1)

    private var interfaceCard: some View {
        card {
            VStack(alignment: .leading, spacing: 8) {
                Text(String(localized: "查看网络"))
                    .font(.subheadline.weight(.semibold))

                Picker(String(localized: "查看网络"), selection: observationBinding) {
                    Text(automaticEntryTitle)
                        .tag(MenuPanelViewModel.automaticNetworkObservationValue)
                    ForEach(model.networkAdvancedInterfaceGroups) { group in
                        Section(NetworkPresentation.interfaceKindTitle(group.kind)) {
                            ForEach(group.interfaces, id: \.self) { name in
                                Text(interfaceEntryTitle(name)).tag(name)
                            }
                        }
                    }
                    if case let .manualUnavailable(name) = model.networkObservationResolution {
                        Text("\(name) · \(String(localized: "已消失"))").tag(name)
                    }
                }
                .labelsHidden()
                .accessibilityIdentifier("network.interfacePicker")

                Text(model.networkObservationSourceText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("network.observation.source")

                if model.networkObservationIsAutomatic == false {
                    Button(String(localized: "恢复自动")) {
                        model.setNetworkObservationAutomatic()
                    }
                    .accessibilityIdentifier("network.observation.automatic")
                }
            }
        }
    }

    private var observationBinding: Binding<String> {
        Binding(
            get: { model.networkObservationSelection },
            set: { model.networkObservationSelection = $0 }
        )
    }

    /// Automatic mode is labelled with what the system actually confirmed. When
    /// nothing was confirmed the entry says so rather than naming an interface
    /// chosen by sort order.
    private var automaticEntryTitle: String {
        let base = String(localized: "自动（系统当前网络）")
        guard case let .resolved(point) = model.networkObservationResolution,
              point.resolution == .systemConfirmed else { return base }
        return "\(base) · \(friendlyInterfaceName(point))"
    }

    private func interfaceEntryTitle(_ name: String) -> String {
        guard let counters = model.networkSnapshot?.interfaces[name] else { return name }
        return "\(name) · \(NetworkPresentation.interfaceKindTitle(counters.kind))"
    }

    private func friendlyInterfaceName(_ point: NetworkObservationPoint) -> String {
        guard let display = point.displayName else { return point.interfaceName }
        return "\(display)（\(point.interfaceName)）"
    }

    // MARK: - Current rates

    private var rateCard: some View {
        card {
            let selected = model.resolvedNetworkInterfaceName
            let rate = selected.flatMap { model.networkSnapshot?.interfaceRates[$0] }
            let counters = selected.flatMap { model.networkSnapshot?.interfaces[$0] }
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 16) {
                    rateColumn(
                        title: String(localized: "上传"),
                        systemImage: "arrow.up",
                        // A retained rate is history, not a current reading:
                        // it must not keep presenting itself as live.
                        value: NetworkPresentation.rate(model.networkRatesAreStale ? nil : rate?.uploadBytesPerSecond),
                        color: NetworkPresentation.uploadColor,
                        identifier: "network.rate.upload"
                    )
                    Divider()
                    rateColumn(
                        title: String(localized: "下载"),
                        systemImage: "arrow.down",
                        value: NetworkPresentation.rate(model.networkRatesAreStale ? nil : rate?.downloadBytesPerSecond),
                        color: NetworkPresentation.downloadColor,
                        identifier: "network.rate.download"
                    )
                }
                .frame(maxWidth: .infinity)
                if model.networkRatesAreStale {
                    Text(String(localized: "速率已过期，下方为最后已知数值与时间"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("network.rate.stale")
                }
                cumulativeDetail(counters)
            }
        }
    }

    private func rateColumn(title: String, systemImage: String, value: String, color: Color, identifier: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Label(title, systemImage: systemImage)
                .font(.caption)
                .foregroundStyle(color)
            Text(value)
                .font(.system(size: 20, weight: .semibold).monospacedDigit())
                .accessibilityIdentifier(identifier)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// PRD §13.5: the summary leads with what this monitoring span actually
    /// settled, from a start point the aggregator observed. The source's raw
    /// boot total is shown separately and labelled as what it is — its start
    /// cannot be verified from a reading, and widening a 32-bit counter
    /// recovers nothing that already wrapped.
    private func cumulativeDetail(_ counters: InterfaceCounters?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            if let counters {
                Text(sessionTotalDetail(counters.sessionTotal))
                    .accessibilityIdentifier("network.total.session")
                Text(sourceTotalDetail(counters))
                    .accessibilityIdentifier("network.total.source")
            } else {
                Text(model.networkObservationSourceText)
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    private func sessionTotalDetail(_ total: SessionByteTotal?) -> String {
        guard let total, total.bytes.upload != nil || total.bytes.download != nil else {
            // A baseline alone proves the interface exists, not how much
            // crossed it; 0 would be a claim, not a measurement.
            return String(localized: "本次监测累计：未知，需要至少两个样本")
        }
        let since = total.since.formatted(date: .omitted, time: .shortened)
        let upload = NetworkPresentation.bytes(total.bytes.upload)
        let download = NetworkPresentation.bytes(total.bytes.download)
        let span = total.isContinuous
            ? String(localized: "自 \(since)")
            : String(localized: "自 \(since)，\(NetworkStatusRules.sessionTotalReasonText(total.breakReason))")
        return String(localized: "本次监测累计（\(span)）上传 \(upload) · 下载 \(download)")
    }

    private func sourceTotalDetail(_ counters: InterfaceCounters) -> String {
        let upload = NetworkPresentation.bytes(counters.counters.bytes.upload)
        let download = NetworkPresentation.bytes(counters.counters.bytes.download)
        let asOf = counters.asOf.formatted(date: .omitted, time: .shortened)
        return String(localized: "接口计数（源原始累计值，起点未验证）上传 \(upload) · 下载 \(download)（采样于 \(asOf)）")
    }

    // MARK: - Trend

    private var trendCard: some View {
        card {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("速率趋势")
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                    Picker(String(localized: "范围"), selection: $model.networkTrendRange) {
                        ForEach(NetworkTrendRange.allCases) { range in
                            Text(range.title).tag(range)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(width: 260)
                    .accessibilityIdentifier("network.trendRange")
                }
                trendChart
                HStack(spacing: 16) {
                    ForEach(NetworkChartDirection.allCases, id: \.rawValue) { direction in
                        legendDot(
                            color: direction == .upload
                                ? NetworkPresentation.uploadColor
                                : NetworkPresentation.downloadColor,
                            title: TrendScale.title(direction)
                        )
                    }
                    Spacer()
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
    }

    /// One direction-to-color binding, shared by the marks, the legend and
    /// VoiceOver, so the three can never disagree about what red means.
    private enum TrendScale {
        static let domain = [
            NetworkChartDirection.upload.scaleKey,
            NetworkChartDirection.download.scaleKey
        ]
        static let range = [
            NetworkPresentation.uploadColor,
            NetworkPresentation.downloadColor
        ]

        static func title(_ direction: NetworkChartDirection) -> String {
            switch direction {
            case .upload: return String(localized: "上传")
            case .download: return String(localized: "下载")
            }
        }
    }

    @ViewBuilder
    private var trendChart: some View {
        // One clock reading bounds both ends of the window; two reads would let
        // the domain overlap itself and stitch the line's ends together.
        let now = Date()
        let window = model.networkTrendRange.duration
        let projection = model.networkTrendProjection(now: now, window: window)
        let totalSamples = model.resolvedNetworkInterfaceName
            .map { model.networkRateHistory.series(for: $0).count } ?? 0

        if projection.points.isEmpty {
            trendPlaceholder(totalSamples: totalSamples)
        } else {
            Chart { TrendChartContent(points: projection.points) }
            .chartForegroundStyleScale(domain: TrendScale.domain, range: TrendScale.range)
            // The scale keys are stable English identifiers so the colour
            // binding cannot depend on locale; the visible legend below is the
            // localized one. Showing both put "upload / download" next to
            // "上传 / 下载" in the same card.
            .chartLegend(.hidden)
            .chartXScale(domain: now.addingTimeInterval(-window) ... now)
            .chartYAxis {
                AxisMarks(position: .leading) { value in
                    AxisGridLine()
                    AxisValueLabel {
                        if let bytes = value.as(Double.self) {
                            Text(NetworkPresentation.rate(bytes))
                        }
                    }
                }
            }
            .frame(minHeight: 140)
            .accessibilityLabel(String(localized: "速率趋势"))
            .accessibilityValue(Text(
                "折线段 \(projection.segmentCount) 段，独立数据点 \(projection.isolatedPointCount) 个"
            ))
            .accessibilityIdentifier("network.trend.chart")
            if projection.thinnedSegmentCount > 0 {
                Text(String(localized: "区间内已按峰谷抽稀显示，原始样本未丢弃"))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("network.trend.thinned")
            }
        }
    }

    /// "No curve yet" has three honest causes and they need different answers,
    /// so they are not collapsed into one empty state.
    @ViewBuilder
    private func trendPlaceholder(totalSamples: Int) -> some View {
        Group {
            if model.resolvedNetworkInterfaceName == nil {
                Text(String(localized: "未选择网络或所选网络已消失"))
            } else if totalSamples < 2 {
                Text(String(localized: "样本不足，采集片刻后显示趋势"))
            } else {
                Text(String(localized: "所选区间内没有可用速率"))
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, minHeight: 140)
        .accessibilityIdentifier("network.trend.empty")
    }

    private func legendDot(color: Color, title: String) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(title)
        }
    }

    // MARK: - Per-app honesty card

    private var appsCard: some View {
        card {
            VStack(alignment: .leading, spacing: 6) {
                Text("按应用统计")
                    .font(.subheadline.weight(.semibold))
                Label(String(localized: "当前版本无法按应用统计"), systemImage: "info.circle")
                    .font(.callout)
                Text(appsDetail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityIdentifier("network.apps.unavailable")
    }

    private var appsDetail: String {
        let blockers = model.networkSnapshot?.capabilities.blockers ?? []
        if blockers.contains(.signingOrProfileMissing) {
            return String(localized: "按应用统计需要签名的系统扩展，当前构建未提供；接口级统计不受影响。此处不显示估计值。")
        }
        return String(localized: "按应用统计尚未实现；此处不显示估计值。")
    }

    // MARK: - Card container

    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.background, in: RoundedRectangle(cornerRadius: 11))
            .overlay {
                RoundedRectangle(cornerRadius: 11)
                    .stroke(.separator.opacity(0.55), lineWidth: 1)
            }
    }
}

/// Lines and dots for the trend. Split out because inlining it left the
/// compiler unable to resolve the `ChartContent` builder in reasonable time.
///
/// `series:` is what keeps the two directions apart: without it Charts joins
/// every mark in emission order, which drew the upload's last point straight
/// into the download's first one.
private struct TrendChartContent: ChartContent {
    let points: [NetworkChartPoint]

    var body: some ChartContent {
        ForEach(points) { point in
            LineMark(
                x: .value("时间", point.at),
                y: .value("速率", point.value),
                series: .value("连续段", point.seriesKey)
            )
            .foregroundStyle(by: .value("方向", point.direction.scaleKey))
            .interpolationMethod(.linear)
            if point.isIsolated {
                // PointMark takes no series: a dot cannot be joined to
                // anything, and passing one would imply grouping it has none.
                PointMark(
                    x: .value("时间", point.at),
                    y: .value("速率", point.value)
                )
                .foregroundStyle(by: .value("方向", point.direction.scaleKey))
                .symbolSize(30)
            }
        }
    }
}
