import Charts
import Accessibility
import SwiftUI
import UniformTypeIdentifiers
import UsageButlerCore
import UsageButlerDomain

public struct NetworkHistoryWindowRootView: View {
    @ObservedObject private var model: BackgroundNetworkViewModel
    public init(model: BackgroundNetworkViewModel) { self.model = model }
    public var body: some View {
        ScrollView { NetworkHistoryView(model: model).padding(22).frame(maxWidth: 1100) }
            .frame(minWidth: 560, minHeight: 420)
    }
}

struct NetworkHistoryView: View {
    @ObservedObject var model: BackgroundNetworkViewModel
    @State private var preview: ProcessJSONDocument?
    @State private var showingPreview = false
    @State private var saving = false
    @State private var exportError: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                if model.selectedApplication != nil {
                    Button("应用汇总") { model.selectedApplication = nil }
                }
                Text(model.result?.applications.first.flatMap { model.selectedApplication == nil ? nil : $0.identity.name } ?? "应用历史")
                    .font(.headline).lineLimit(1)
                Spacer()
                Button("刷新") { model.reload() }.disabled(model.loading)
                Button("导出预览") { prepareExport() }.disabled(model.result == nil)
                    .accessibilityIdentifier("network.history.export")
            }
            Picker("历史范围", selection: $model.range) {
                ForEach(BackgroundNetworkViewModel.Range.allCases) { Text($0.title).tag($0) }
            }.pickerStyle(.segmented).accessibilityIdentifier("network.history.range")
            Text(model.serviceTitle).font(.caption).foregroundStyle(.secondary)
            if model.loading { ProgressView("读取已提交历史…").controlSize(.small) }
            if let issue = model.queryIssue { Text(issue).font(.caption).foregroundStyle(.orange) }
            if let result = model.result {
                Text("\(result.range.start.formatted(date: .abbreviated, time: .shortened)) — \(result.range.end.formatted(date: .abbreviated, time: .shortened)) · 整分钟范围")
                    .font(.caption2).foregroundStyle(.secondary)
                coverage(result)
                if model.selectedApplication != nil {
                    HistoryCurveView(buckets: result.curve, range: result.range)
                    if let app = result.applications.first {
                        Text("已观察 ↑ \(NetworkPresentation.bytes(app.totals.upload)) · ↓ \(NetworkPresentation.bytes(app.totals.download))")
                            .font(.callout).monospacedDigit()
                        Text("所选范围含 \(app.identitySnapshotCount) 份身份快照；显示最近观察到的名称。")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                } else {
                    Text("按已观察上传排序").font(.caption).foregroundStyle(.secondary)
                    ForEach(result.applications) { app in
                        Button { model.selectedApplication = app.id } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(app.identity.name).lineLimit(1)
                                    if !app.totals.quality.isEmpty { Text("包含未完整观察时段").font(.caption2).foregroundStyle(.secondary) }
                                }.frame(maxWidth: .infinity, alignment: .leading)
                                Text("↑ \(NetworkPresentation.bytes(app.totals.upload))").foregroundStyle(NetworkPresentation.uploadColor)
                                Text("↓ \(NetworkPresentation.bytes(app.totals.download))").foregroundStyle(NetworkPresentation.downloadColor)
                            }.font(.caption).monospacedDigit().padding(.vertical, 5).contentShape(Rectangle())
                        }.buttonStyle(.plain)
                    }
                    if result.applications.isEmpty { Text(emptyText(result)).font(.callout).foregroundStyle(.secondary).padding(.vertical, 18) }
                }
                if !result.days.isEmpty {
                    DisclosureGroup("每天汇总（UTC 日期）") {
                        ForEach(result.days) { day in
                            HStack {
                                Text(Self.utcDay(day.day)); Spacer()
                                Text("↑ \(NetworkPresentation.bytes(day.totals.upload))  ↓ \(NetworkPresentation.bytes(day.totals.download))")
                            }.font(.caption).monospacedDigit()
                        }
                        Text("只加总实际观察字节；多个应用的观察时长不能当作设备覆盖率。")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }
                Divider()
                Text("上传活动").font(.subheadline.weight(.semibold))
                Picker("活动类型", selection: $model.eventKind) {
                    Text("全部").tag(String?.none)
                    Text("大量上传").tag(String?("large"))
                    Text("持续上传").tag(String?("sustained"))
                }.pickerStyle(.segmented).accessibilityIdentifier("network.history.eventsFilter")
                Text("本地筛选记录，不判断恶意、打包或前台状态。跨范围的活动显示整段字节，可能超过该范围内用量。")
                    .font(.caption2).foregroundStyle(.secondary)
                ForEach(result.events) { event in
                    VStack(alignment: .leading, spacing: 4) {
                        Text("\(event.name) · \(event.kind == "large" ? "大量上传" : "持续上传")").font(.caption.weight(.medium))
                        Text("\(event.start.formatted(date: .abbreviated, time: .standard)) — \(event.end.formatted(date: .abbreviated, time: .standard))")
                        Text("整段观察 ↑ \(NetworkPresentation.bytes(event.bytes)) · 峰值 \(NetworkPresentation.rate(event.peak)) · \(Int(event.observedSeconds)) 秒")
                        Text(event.kind == "large" ? "当时阈值：连续段 ≥ \(NetworkPresentation.bytes(event.rule.largeBytes))" :
                            "当时阈值：连续 ≥ \(Int(event.rule.sustainedSeconds)) 秒，每次读数 ≥ \(NetworkPresentation.rate(event.rule.sustainedBytesPerSecond))")
                        if let reason = event.endReason { Text("分段原因：\(reason)") }
                    }.font(.caption2).foregroundStyle(.secondary).padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading).background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 6))
                }
                if result.events.isEmpty { Text("此页没有符合采集时阈值的上传活动；不代表没有上传或未采时段没有流量。").font(.caption).foregroundStyle(.secondary) }
                HStack {
                    Button("上一页") { model.previousPage() }.disabled(model.page == 0 || model.loading)
                    Text("第 \(model.page + 1) 页 · 每页最多 64 条").font(.caption2)
                    Spacer()
                    Button("下一页") { model.nextPage() }
                        .disabled(model.loading || model.page >= 1023 || ((model.page + 1) * 64 >= result.totalApplications && result.events.count < 64))
                }
            }
        }
        .onAppear { if model.result == nil { model.reload() } }
        .sheet(isPresented: $showingPreview) {
            VStack(alignment: .leading, spacing: 12) {
                Text("历史 JSON 导出预览").font(.headline)
                Text("冻结当前范围与当前页，默认使用别名；不含名称、路径、PID 或目标。别名化不等于匿名。").font(.caption)
                ScrollView { Text(preview?.text ?? "").font(.system(.caption2, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                HStack {
                    Button("取消") { showingPreview = false; preview = nil }.keyboardShortcut(.cancelAction)
                        .accessibilityIdentifier("network.history.export.cancel")
                    Spacer()
                    Button("保存到文件…") { showingPreview = false; saving = true }.keyboardShortcut(.defaultAction)
                        .accessibilityIdentifier("network.history.export.save")
                }
            }.padding(20).frame(width: 480, height: 440)
        }
        .fileExporter(isPresented: $saving, document: preview, contentType: .json, defaultFilename: "application-network-history") { result in
            if case .failure = result { exportError = "文件未保存，请选择可写的位置。" }; preview = nil
        }
        .alert("历史导出", isPresented: Binding(get: { exportError != nil }, set: { if !$0 { exportError = nil } })) {
            Button("好") { exportError = nil }
        } message: { Text(exportError ?? "") }
    }
    @ViewBuilder private func coverage(_ result: HistoryQueryResult) -> some View {
        let c = result.coverage
        VStack(alignment: .leading, spacing: 4) {
            if let date = c.lastCommittedAt { Text("最近已保存：\(date.formatted(date: .abbreviated, time: .standard))") }
            if let date = c.firstCollectedAt { Text("开始记录：\(date.formatted(date: .abbreviated, time: .standard)) · 默认保留 14 天") }
            Text("范围内源样本 \(c.sourceSamples) 次 · 不完整 \(c.sourcePartialSamples) 次 · 无法归属 \(c.unattributedSamples) 条")
            Text("停止、休眠和来源缺口留空；分钟内只观察到部分时间时，不记作完整一分钟。")
            if c.retentionTrimmed { Text("较早记录已按保留期限清理；被清理时段不表示零流量。") }
            if c.eventsTruncated { Text("活动列表已触及容量限制；基础分钟记录仍独立保存。") }
            if c.recoveredUncleanSession { Text("上次服务未正常关闭：最后确认提交之后尚未保存的记录可能缺失。正常目标约每5秒提交，调度停顿可能延长；停机期间为未观察。") }
            if c.conservativeAge { Text("跨启动的离线时长无法核实，部分记录会保守多保留。") }
        }.font(.caption2).foregroundStyle(.secondary)
    }
    private func emptyText(_ result: HistoryQueryResult) -> String {
        if let first = result.coverage.firstCollectedAt, result.range.end <= first { return "此范围早于开始采集时间，无法补回过去流量。" }
        if result.coverage.retentionTrimmed, let oldest = result.coverage.oldestRetainedAt, result.range.end <= oldest { return "此范围的记录已超出保留期限。" }
        if result.coverage.unattributedSamples > 0 { return "此范围有源采样，但没有可归属应用的历史。" }
        return "此范围没有已保存的应用观察；未知时段不能当作零流量。"
    }
    private func prepareExport() {
        guard let result = model.result else { return }
        do { preview = .init(data: try NetworkHistoryExport.encode(result)); showingPreview = true }
        catch { exportError = "无法生成有界导出，请缩小范围或页数。" }
    }
    private static func utcDay(_ date: Date) -> String {
        let formatter = DateFormatter(); formatter.timeZone = TimeZone(secondsFromGMT: 0); formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
}

struct HistoryCurveView: View {
    let buckets: [HistoryCurveBucket]
    let range: HistoryRange
    @State private var inspected: Date?
    @State private var pinned = false
    @FocusState private var focused: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("分钟均速 · 多天范围按相邻分钟合并显示").font(.caption).foregroundStyle(.secondary)
            direction(upload: true); Divider(); direction(upload: false)
            if let inspected, let point = buckets.first(where: { inspected >= $0.start && inspected < $0.end }) {
                Text("\(point.start.formatted(date: .abbreviated, time: .shortened)) · ↑ \(NetworkPresentation.rate(average(point, upload: true))) · ↓ \(NetworkPresentation.rate(average(point, upload: false)))")
                    .font(.caption2).monospacedDigit()
                Text("实际观察 ↑ \(Double(point.totals.uploadObservedMicroseconds) / 1e6, specifier: "%.1f") 秒 · ↓ \(Double(point.totals.downloadObservedMicroseconds) / 1e6, specifier: "%.1f") 秒")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            Text("上下行独立缩放；等高不代表等速。空档不补零，柱形均速不能表示分钟内的连续性。")
                .font(.caption2).foregroundStyle(.secondary)
            Text("悬停查看，点击固定；聚焦后左右键移动，Escape释放。").font(.caption2).foregroundStyle(.secondary)
        }.padding(10).background(.quaternary.opacity(0.2), in: RoundedRectangle(cornerRadius: 8))
    }
    private func average(_ point: HistoryCurveBucket, upload: Bool) -> Double? {
        let bytes = upload ? point.totals.upload : point.totals.download
        let micros = upload ? point.totals.uploadObservedMicroseconds : point.totals.downloadObservedMicroseconds
        guard let bytes, micros > 0 else { return nil }; return Double(bytes) / (Double(micros) / 1e6)
    }
    private func direction(upload: Bool) -> some View {
        let color = upload ? NetworkPresentation.uploadColor : NetworkPresentation.downloadColor
        let peak = buckets.filter { (upload ? $0.totals.uploadSamples : $0.totals.downloadSamples) > 0 }
            .map { upload ? $0.totals.peakUpload : $0.totals.peakDownload }.max()
        let upper = max(1, buckets.compactMap { average($0, upload: upload) }.max() ?? 1)
        let coordinates = NetworkChartCoordinates(now: range.end, window: range.end.timeIntervalSince(range.start), upperBound: upper)
        return VStack(alignment: .leading, spacing: 3) {
            HStack { Text(upload ? "上传" : "下载").foregroundStyle(color); Spacer(); Text("真实采样峰值 \(NetworkPresentation.rate(peak))").foregroundStyle(.secondary) }.font(.caption)
            Chart {
                ForEach(buckets) { point in
                    if let rate = average(point, upload: upload) {
                        RectangleMark(xStart: .value("开始", coordinates.x(at: point.start)), xEnd: .value("结束", coordinates.x(at: point.end)),
                                      yStart: .value("零基线", 0.0), yEnd: .value("观察均速", coordinates.y(for: rate)))
                            .foregroundStyle(color.opacity(point.totals.quality.isEmpty ? 0.8 : 0.5))
                    }
                }
                if let inspected { RuleMark(x: .value("查看时间", coordinates.x(at: inspected))).foregroundStyle(.secondary).lineStyle(.init(lineWidth: 1, dash: [3])) }
            }
            .chartXScale(domain: 0.0...1.0).chartYScale(domain: 0.0...1.0)
            .chartYAxis { AxisMarks(position: .leading, values: NetworkChartCoordinates.ticks) { value in
                AxisGridLine(); AxisValueLabel { if let value = value.as(Double.self) { Text(NetworkPresentation.rate(coordinates.rate(atY: value))).font(.system(size: 9)) } }
            } }
            .chartXAxis { AxisMarks(values: NetworkChartCoordinates.ticks) { value in
                AxisGridLine(); AxisValueLabel { if let x = value.as(Double.self) {
                    Text(coordinates.date(atX: x), format: .dateTime.month().day().hour().minute()).font(.system(size: 9))
                } }
            } }
            .chartOverlay { proxy in
                GeometryReader { geometry in
                    Rectangle().fill(.clear).contentShape(Rectangle()).onContinuousHover { phase in
                        guard !pinned else { return }
                        switch phase {
                        case let .active(location):
                            if let x: Double = proxy.value(atX: location.x - geometry[proxy.plotAreaFrame].origin.x) {
                                inspected = coordinates.date(atX: min(1, max(0, x)))
                            }
                        case .ended: inspected = nil
                        }
                    }
                    .onTapGesture { pinned.toggle(); focused = true; if inspected == nil { inspected = buckets.last?.start } }
                }
            }.frame(height: 105).focusable().focused($focused)
            .onMoveCommand { direction in
                if direction == .left || direction == .right { step(direction == .right ? 1 : -1) }
            }
            .onExitCommand { pinned = false; inspected = nil; focused = false }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(upload ? "历史上传分钟均速" : "历史下载分钟均速")
            .accessibilityChildren {
                ForEach(buckets) { point in
                    Rectangle().accessibilityElement()
                        .accessibilityLabel(Text(point.start, format: .dateTime.month().day().hour().minute()))
                        .accessibilityValue(NetworkPresentation.rate(average(point, upload: upload)))
                }
            }
            .accessibilityChartDescriptor(HistoryChartAccessibility(buckets: buckets, upload: upload, range: range, upper: upper))
        }
    }
    private func step(_ offset: Int) {
        guard !buckets.isEmpty else { return }
        let index = inspected.flatMap { date in buckets.firstIndex { date >= $0.start && date < $0.end } } ?? (offset > 0 ? -1 : buckets.count)
        inspected = buckets[min(buckets.count - 1, max(0, index + offset))].start; pinned = true
    }
}

private struct HistoryChartAccessibility: AXChartDescriptorRepresentable {
    let buckets: [HistoryCurveBucket]
    let upload: Bool
    let range: HistoryRange
    let upper: Double
    func makeChartDescriptor() -> AXChartDescriptor {
        let x = AXNumericDataAxisDescriptor(title: "时间", range: range.start.timeIntervalSince1970...range.end.timeIntervalSince1970, gridlinePositions: []) {
            Date(timeIntervalSince1970: $0).formatted(date: .abbreviated, time: .shortened)
        }
        let y = AXNumericDataAxisDescriptor(title: "观察均速，字节每秒", range: 0...upper, gridlinePositions: []) { NetworkPresentation.rate($0) }
        let points = buckets.compactMap { point -> AXDataPoint? in
            let micros = upload ? point.totals.uploadObservedMicroseconds : point.totals.downloadObservedMicroseconds
            guard let bytes = upload ? point.totals.upload : point.totals.download, micros > 0 else { return nil }
            return AXDataPoint(x: point.start.timeIntervalSince1970, y: Double(bytes) / (Double(micros) / 1e6))
        }
        return AXChartDescriptor(title: upload ? "历史上传分钟均速" : "历史下载分钟均速", summary: "各桶独立，缺口不连接；不是分钟内连续性证据。",
            xAxis: x, yAxis: y, series: [AXDataSeriesDescriptor(name: "已观察分钟", isContinuous: false, dataPoints: points)])
    }
}
