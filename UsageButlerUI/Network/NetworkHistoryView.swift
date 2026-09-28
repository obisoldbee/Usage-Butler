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
        ScrollViewReader { proxy in
            ScrollView { NetworkHistoryView(model: model).padding(22).frame(maxWidth: 1100) }
                .frame(minWidth: 560, minHeight: 420)
                .onChange(of: model.returnFocus) { target in
                    if let target { proxy.scrollTo(target, anchor: target == .summary ? .top : .center) }
                }
        }
    }
}

struct NetworkHistoryView: View {
    @ObservedObject var model: BackgroundNetworkViewModel
    @State private var preview: ProcessJSONDocument?
    @State private var showingPreview = false
    @State private var saving = false
    @State private var exportError: String?
    @FocusState private var focused: BackgroundNetworkViewModel.ReturnFocus?
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                if model.selectedApplication != nil {
                    Button("应用汇总") { model.selectedApplication = nil }
                        .accessibilityIdentifier("network.history.back")
                }
                Text(model.result?.applications.first.flatMap { model.selectedApplication == nil ? nil : $0.identity.name } ?? "应用历史")
                    .font(.headline).lineLimit(1)
                Spacer()
                Button("刷新") { model.reload() }.disabled(model.loading)
                    .focusable(true)
                    .focused($focused, equals: .summary)
                    .accessibilityIdentifier("network.history.refresh")
                Button("导出预览") { prepareExport() }.disabled(model.result == nil)
                    .accessibilityIdentifier("network.history.export")
            }.id(BackgroundNetworkViewModel.ReturnFocus.summary)
            Picker("历史范围", selection: $model.range) {
                ForEach(BackgroundNetworkViewModel.Range.allCases) { Text($0.title).tag($0) }
            }.pickerStyle(.segmented).accessibilityIdentifier("network.history.range")
            if model.selectedApplication == nil {
                HStack {
                    TextField("搜索历史应用名称、标识或路径", text: $model.search)
                        .textFieldStyle(.roundedBorder).accessibilityIdentifier("network.history.search")
                    if !model.search.isEmpty {
                        Button("清除") { model.search = "" }.accessibilityIdentifier("network.history.search.clear")
                    }
                }
                Text("搜索整个所选范围，包含已退出应用及保留的身份名称。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text("后台状态：" + model.serviceTitle).font(.caption).foregroundStyle(.secondary)
            if model.loading { ProgressView("读取已提交历史…").controlSize(.small) }
            if let issue = model.queryIssue { Text(issue).font(.caption).foregroundStyle(.orange) }
            if let notice = model.navigationNotice { Text(notice).font(.caption).foregroundStyle(.secondary) }
            if let result = model.result {
                Text("所选范围  \(result.range.start.formatted(date: .abbreviated, time: .shortened)) — \(result.range.end.formatted(date: .abbreviated, time: .shortened))")
                    .font(.callout).monospacedDigit().fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("network.history.absoluteRange")
                if model.selectedApplication != nil {
                    if let app = result.applications.first {
                        HStack(spacing: 24) {
                            Label("已观察上传  " + NetworkPresentation.bytes(HistoryCurvePresentation.observedBytes(app.totals, upload: true)), systemImage: "arrow.up")
                                .foregroundStyle(NetworkPresentation.uploadColor)
                            Label("已观察下载  " + NetworkPresentation.bytes(HistoryCurvePresentation.observedBytes(app.totals, upload: false)), systemImage: "arrow.down")
                                .foregroundStyle(NetworkPresentation.downloadColor)
                        }.font(.headline).monospacedDigit()
                    } else { Text(HistoryCurvePresentation.emptyText(result)).font(.callout).foregroundStyle(.secondary) }
                    if let notice = HistoryCurvePresentation.historyNotice(coverage: result.coverage, range: result.range) {
                        Text(notice).font(.caption).foregroundStyle(.secondary)
                            .accessibilityIdentifier("network.history.recordingStart")
                    }
                    HistoryCurveView(buckets: result.curve, range: result.range)
                        .id(result.contract?.context.id)
                    Text(HistoryCurvePresentation.trafficScope).font(.caption).foregroundStyle(.secondary)
                } else {
                    if let notice = HistoryCurvePresentation.historyNotice(coverage: result.coverage, range: result.range) {
                        Text(notice).font(.caption).foregroundStyle(.secondary)
                    }
                    Text("按已观察上传排序").font(.caption).foregroundStyle(.secondary)
                    ForEach(result.applications) { app in
                        Button { model.openApplication(app) } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(app.identity.name).lineLimit(1)
                                    if app.identityOrder == .legacyUnverified {
                                        Text("旧数据：身份顺序未验证").font(.caption2).foregroundStyle(.secondary)
                                    }
                                    if !app.totals.quality.subtracting(.minuteBoundary).isEmpty { Text("包含质量提示，详见应用记录").font(.caption2).foregroundStyle(.secondary) }
                                }.frame(maxWidth: .infinity, alignment: .leading)
                                Text("↑ \(NetworkPresentation.bytes(app.totals.upload))").foregroundStyle(NetworkPresentation.uploadColor)
                                Text("↓ \(NetworkPresentation.bytes(app.totals.download))").foregroundStyle(NetworkPresentation.downloadColor)
                            }.font(.caption).monospacedDigit().padding(.vertical, 5).contentShape(Rectangle())
                        }.buttonStyle(.plain)
                            .id(BackgroundNetworkViewModel.ReturnFocus.application(app.id))
                            .focusable(true).focused($focused, equals: .application(app.id))
                            .accessibilityIdentifier("network.history.row.\(app.id)")
                            .onAppear { restoreFocus(for: .application(app.id)) }
                    }
                    if result.applications.isEmpty { Text(HistoryCurvePresentation.emptyText(result)).font(.callout).foregroundStyle(.secondary).padding(.vertical, 18) }
                }
                DisclosureGroup("采集诊断") {
                    Text(HistoryCurvePresentation.diagnosticsScope).font(.caption).foregroundStyle(.secondary)
                    coverage(result)
                    if model.selectedApplication != nil, let app = result.applications.first {
                        Text(app.identityOrder == .observed
                             ? "所选应用在范围内含 \(app.identitySnapshotCount) 份身份快照；显示最近观察到的名称。"
                             : "所选应用含 \(app.identitySnapshotCount) 份旧身份快照；观察顺序未记录，名称不代表最近身份。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }.accessibilityIdentifier("network.history.diagnostics")
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
                    Button { model.openEvent(event) } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("\(event.name) · \(event.kind == "large" ? "大量上传" : "持续上传")").font(.caption.weight(.medium))
                        Text("\(event.start.formatted(date: .abbreviated, time: .standard)) — \(event.end.formatted(date: .abbreviated, time: .standard))")
                        Text("整段观察 ↑ \(NetworkPresentation.bytes(event.bytes)) · 采样峰值 \(NetworkPresentation.rate(event.peak)) · \(Int(event.observedSeconds)) 秒")
                        Text(event.kind == "large" ? "当时阈值：连续段 ≥ \(NetworkPresentation.bytes(event.rule.largeBytes))" :
                            HistoryUploadRuleFields.sustainedThreshold(event.rule))
                        if let reason = event.endReason { Text("分段原因：\(reason)") }
                    }.font(.caption2).foregroundStyle(.secondary).padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading).background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 6))
                    }.buttonStyle(.plain).disabled(model.selectedApplication != nil)
                        .id(BackgroundNetworkViewModel.ReturnFocus.event(event.id))
                        .focusable(model.selectedApplication == nil).focused($focused, equals: .event(event.id))
                        .accessibilityIdentifier("network.history.event.\(event.id)")
                        .accessibilityHint("查看此活动所属应用的历史")
                        .onAppear { restoreFocus(for: .event(event.id)) }
                }
                if result.events.isEmpty { Text("此页没有符合采集时阈值的上传活动；不代表没有上传或未采时段没有流量。").font(.caption).foregroundStyle(.secondary) }
                HStack {
                    Button("上一页") { model.previousPage() }.disabled(model.page == 0 || model.loading)
                    Text("第 \(model.page + 1) 页 · 每页最多 64 条").font(.caption2)
                    Spacer()
                    Button("下一页") { model.nextPage() }
                        .disabled(model.loading || model.page >= 1023 || (model.page + 1) * 64 >= max(result.totalApplications, result.contract?.totalEvents ?? 0))
                }
            }
        }
        .background {
            if model.selectedApplication == nil {
                ProcessListKeyboard { key in
                    guard [UInt16(36), 49, 76].contains(key), !showingPreview, !saving, exportError == nil else { return false }
                    switch focused {
                    case let .application(id):
                        guard let app = model.result?.applications.first(where: { $0.id == id }) else { return false }
                        model.openApplication(app); return true
                    case let .event(id):
                        guard let event = model.result?.events.first(where: { $0.id == id }) else { return false }
                        model.openEvent(event); return true
                    case .summary:
                        guard !model.loading else { return false }
                        model.reload(); return true
                    default: return false
                    }
                }
            }
        }
        .onAppear { if model.result == nil { model.reload() } }
        .onChange(of: model.returnFocus) { target in
            if let target { restoreFocus(for: target) }
        }
        .sheet(isPresented: $showingPreview) {
            VStack(alignment: .leading, spacing: 12) {
                Text("历史 JSON 导出预览").font(.headline)
                Text("冻结当前范围、应用选择、活动筛选、搜索生效状态及当前页；日汇总覆盖整个匹配范围，不随页码或活动类型缩小。默认别名化，不含搜索原文、名称、路径、PID 或目标；别名化不等于匿名。").font(.caption)
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
    private func restoreFocus(for target: BackgroundNetworkViewModel.ReturnFocus) {
        guard model.returnFocus == target else { return }
        // Wait for the restored row to attach, and recheck navigation so a
        // delayed attachment cannot steal focus after another user action.
        DispatchQueue.main.async {
            if model.selectedApplication == nil, model.returnFocus == target { focused = target }
        }
    }
    @ViewBuilder private func coverage(_ result: HistoryQueryResult) -> some View {
        let c = result.coverage
        VStack(alignment: .leading, spacing: 4) {
            if let date = c.lastCommittedAt { Text("最近已保存：\(date.formatted(date: .abbreviated, time: .standard))") }
            if let date = c.firstCollectedAt { Text("首次开始记录时的系统时间：\(date.formatted(date: .abbreviated, time: .standard)) · 默认保留 14 天") }
            Text("全局源样本 \(c.sourceSamples) 次 · 不完整采样 \(c.sourcePartialSamples) 次 · 无法归属记录 \(c.unattributedSamples) 次")
            Text("停止、休眠和来源缺口留空；分钟内只观察到部分时间时，不记作完整一分钟。")
            if c.retentionTrimmed { Text("较早记录已按保留期限清理；被清理时段不表示零流量。") }
            if c.eventsTruncated { Text("活动列表已触及容量限制；基础分钟记录仍独立保存。") }
            if c.recoveredUncleanSession { Text("上次服务未正常关闭：最后确认提交之后尚未保存的记录可能缺失。正常目标约每5秒提交，调度停顿可能延长；停机期间为未观察。") }
            if c.conservativeAge { Text("跨启动的离线时长无法核实，部分记录会保守多保留。") }
        }.font(.caption).foregroundStyle(.secondary)
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

struct HistoryCurveReadout: View {
    let point: HistoryCurveBucket
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("\(point.start.formatted(date: .abbreviated, time: .standard)) — \(point.end.formatted(date: .abbreviated, time: .standard)) · 时段跨度 \(HistoryCurvePresentation.span(point))")
                .font(.callout.weight(.medium)).monospacedDigit()
            HStack(alignment: .top, spacing: 16) {
                directionReadout(point, upload: true)
                directionReadout(point, upload: false)
            }
            if point.totals.quality.contains(.minuteBoundary) {
                Text("含跨分钟计数：不可拆分的计数归入当前时段；此标记本身不表示丢样，也不证明时段间连续。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
            .background(.background, in: RoundedRectangle(cornerRadius: 6))
            .accessibilityIdentifier("network.history.inspection")
    }

    private func directionReadout(_ point: HistoryCurveBucket, upload: Bool) -> some View {
        let bytes = HistoryCurvePresentation.observedBytes(point.totals, upload: upload)
        return VStack(alignment: .leading, spacing: 3) {
            Text((upload ? "↑ 上传均速  " : "↓ 下载均速  ") + NetworkPresentation.rate(HistoryCurvePresentation.average(point, upload: upload)))
                .font(.callout.weight(.medium))
            Text("已观察字节：" + (bytes.map { "\($0) 字节（\(NetworkPresentation.bytes($0))）" } ?? "未知"))
            Text("实际观察 \(HistoryCurvePresentation.observedSeconds(point, upload: upload).formatted(.number.precision(.fractionLength(0...3)))) 秒 · \(HistoryCurvePresentation.observation(point, upload: upload))")
            Text("采样峰值：" + NetworkPresentation.rate(HistoryCurvePresentation.peak(point.totals, upload: upload)))
        }.font(.caption).monospacedDigit().frame(maxWidth: .infinity, alignment: .leading)
    }

}

struct HistoryCurveView: View {
    let buckets: [HistoryCurveBucket]
    let range: HistoryRange
    @State private var interaction = HistoryCurveInteraction()
    @FocusState private var focused: HistoryChartDirection?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("已观察时段的平均速率").font(.subheadline.weight(.semibold))
            Text(HistoryCurvePresentation.granularity(buckets)).font(.caption).foregroundStyle(.secondary)
            direction(.upload); direction(.download)
            if let inspected = interaction.inspected {
                if let point = HistoryCurvePresentation.bucket(at: inspected, in: buckets) {
                    HistoryCurveReadout(point: point)
                } else {
                    Text("\(inspected.formatted(date: .abbreviated, time: .standard)) · 该时段无可用记录")
                        .font(.callout).accessibilityIdentifier("network.history.inspection.gap")
                }
            } else {
                Text("悬停查看双向读数；点击固定，左右键移动，Escape 释放。").font(.caption).foregroundStyle(.secondary)
            }
            Text("上下行独立缩放，等高不代表等速。彩色基线＝已观察为零；留白＝无可用记录；浅色柱＝部分记录。")
                .font(.caption).foregroundStyle(.secondary)
            Text("均速＝该时段已观察字节 ÷ 该方向实际观察时长；不代表整段连续采集。采样峰值使用单次读数口径，不是图的纵轴上限。")
                .font(.caption).foregroundStyle(.secondary)
        }.padding(12).background(.quaternary.opacity(0.2), in: RoundedRectangle(cornerRadius: 8))
        .onChange(of: range) { _ in reset() }
        .onChange(of: buckets) { _ in reset() }
        .onChange(of: focused) { interaction.focused = $0 }
    }

    private func direction(_ direction: HistoryChartDirection) -> some View {
        let upload = direction == .upload
        let color = upload ? NetworkPresentation.uploadColor : NetworkPresentation.downloadColor
        let peak = buckets.compactMap { HistoryCurvePresentation.peak($0.totals, upload: upload) }.max()
        let upper = max(1, buckets.compactMap { HistoryCurvePresentation.average($0, upload: upload) }.max() ?? 1)
        let coordinates = NetworkChartCoordinates(now: range.end, window: range.end.timeIntervalSince(range.start), upperBound: upper)
        return VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(upload ? "上传均速" : "下载均速").foregroundStyle(color).fontWeight(.medium)
                Spacer()
                Text("范围内采样峰值 " + NetworkPresentation.rate(peak)).foregroundStyle(.secondary)
            }.font(.callout)
            Chart {
                ForEach(buckets) { point in
                    if let rate = HistoryCurvePresentation.average(point, upload: upload) {
                        if rate == 0 {
                            RuleMark(xStart: .value("开始", coordinates.x(at: point.start)), xEnd: .value("结束", coordinates.x(at: point.end)), y: .value("已观察为零", 0.0))
                                .foregroundStyle(color.opacity(HistoryCurvePresentation.isPartial(point, upload: upload) ? 0.45 : 0.85)).lineStyle(.init(lineWidth: 2))
                        }
                        if rate > 0 {
                            RectangleMark(xStart: .value("开始", coordinates.x(at: point.start)), xEnd: .value("结束", coordinates.x(at: point.end)),
                                          yStart: .value("零基线", 0.0), yEnd: .value("观察均速", coordinates.y(for: rate)))
                                .foregroundStyle(color.opacity(HistoryCurvePresentation.isPartial(point, upload: upload) ? 0.45 : 0.85))
                        }
                    }
                }
                if let inspected = interaction.inspected {
                    RuleMark(x: .value("查看时间", coordinates.x(at: inspected))).foregroundStyle(.secondary).lineStyle(.init(lineWidth: 1, dash: [3]))
                }
            }
            .chartXScale(domain: 0.0...1.0, range: .plotDimension(padding: 0)).chartYScale(domain: 0.0...1.0)
            .chartYAxis { AxisMarks(position: .leading, values: NetworkChartCoordinates.ticks) { value in
                AxisGridLine()
                AxisValueLabel { if let value = value.as(Double.self) { Text(NetworkPresentation.rate(coordinates.rate(atY: value))).font(.caption2) } }
            } }
            // Fixed normalized tick IDs remain in Charts. End labels are laid
            // out below the plot so Charts cannot cull the right endpoint.
            .chartXAxis { AxisMarks(values: NetworkChartCoordinates.ticks) { _ in AxisGridLine(); AxisTick() } }
            .chartOverlay { proxy in
                GeometryReader { geometry in
                    Rectangle().fill(.clear).contentShape(Rectangle())
                        .onContinuousHover { phase in
                            let plot = geometry[proxy.plotAreaFrame]
                            switch phase {
                            case let .active(location): interaction.hover(at: location, plot: plot, range: range)
                            case .ended: interaction.hover(at: nil, plot: plot, range: range)
                            }
                        }
                        .gesture(SpatialTapGesture().onEnded { value in
                            interaction.tap(at: value.location, plot: geometry[proxy.plotAreaFrame], range: range, direction: direction)
                            focused = interaction.focused
                        })
                }
            }.frame(height: 116).focusable().focused($focused, equals: direction)
                .onMoveCommand { move in
                    guard focused == direction else { return }
                    if move == .left || move == .right { interaction.step(move == .right ? 1 : -1, buckets: buckets) }
                }
                .onExitCommand { reset() }
                .accessibilityIdentifier(upload ? "network.history.chart.upload" : "network.history.chart.download")
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(upload ? "历史上传已观察均速" : "历史下载已观察均速")
                .accessibilityChildren {
                    ForEach(buckets) { point in
                        Rectangle().accessibilityElement()
                            .accessibilityLabel("\(point.start.formatted(date: .abbreviated, time: .shortened)) 至 \(point.end.formatted(date: .abbreviated, time: .shortened))")
                            .accessibilityValue(NetworkPresentation.rate(HistoryCurvePresentation.average(point, upload: upload)) + " · " + HistoryCurvePresentation.observation(point, upload: upload))
                    }
                }
                .accessibilityChartDescriptor(HistoryChartAccessibility(buckets: buckets, upload: upload, range: range, upper: upper))
            HStack(alignment: .top) {
                endpoint(range.start, prefix: "起", alignment: .leading)
                Spacer(minLength: 12)
                endpoint(range.end, prefix: "止", alignment: .trailing)
            }.accessibilityIdentifier(upload ? "network.history.axis.upload" : "network.history.axis.download")
        }
    }

    private func endpoint(_ date: Date, prefix: String, alignment: HorizontalAlignment) -> some View {
        VStack(alignment: alignment, spacing: 1) {
            Text(prefix + " " + date.formatted(date: .abbreviated, time: .omitted))
            Text(date.formatted(date: .omitted, time: .shortened))
        }.font(.caption).monospacedDigit().fixedSize()
    }
    private func reset() { interaction.reset(); focused = nil }
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
            guard let bytes = HistoryCurvePresentation.observedBytes(point.totals, upload: upload), micros > 0 else { return nil }
            return AXDataPoint(x: point.start.timeIntervalSince1970, y: Double(bytes) / (Double(micros) / 1e6))
        }
        return AXChartDescriptor(title: upload ? "历史上传已观察均速" : "历史下载已观察均速", summary: "各时段独立，缺口不连接；不是分钟内连续性证据。",
            xAxis: x, yAxis: y, series: [AXDataSeriesDescriptor(name: "已观察时段", isContinuous: false, dataPoints: points)])
    }
}
