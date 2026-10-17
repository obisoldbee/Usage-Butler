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
    @ObservedObject private var notes: ApplicationNoteStore
    @State private var editingNote: ApplicationNoteTarget?
    init(model: BackgroundNetworkViewModel) {
        self.model = model; notes = model.applicationNotes
    }
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
                Text(model.result?.applications.first.flatMap { model.selectedApplication == nil ? nil : $0.identity }.map { notes.displayName(for: $0) } ?? "应用历史")
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
            HStack {
                DatePicker("截至", selection: Binding(get: { model.currentHistoryEnd }, set: { model.historyEnd = $0 }),
                           in: Date(timeIntervalSince1970: 0)...Date(), displayedComponents: [.date, .hourAndMinute])
                    .accessibilityIdentifier("network.history.endDate")
                Button("现在") { model.historyEnd = nil }.disabled(model.historyEnd == nil)
                    .accessibilityIdentifier("network.history.now")
                Spacer(minLength: 0)
            }
            if model.selectedApplication == nil {
                HStack {
                    TextField("搜索原名、应用标识或路径", text: $model.search)
                        .textFieldStyle(.roundedBorder).accessibilityIdentifier("network.history.search")
                    if !model.search.isEmpty {
                        Button("清除") { model.search = "" }.accessibilityIdentifier("network.history.search.clear")
                    }
                }
            }
            Text(model.serviceTitle).font(.caption).foregroundStyle(.secondary)
            if model.loading { ProgressView("正在读取历史…").controlSize(.small) }
            if let issue = model.queryIssue {
                Text(issue).font(.caption).foregroundStyle(.orange)
                if let code = model.queryDiagnosticCode {
                    DisclosureGroup("诊断信息") { Text(code).font(.caption).textSelection(.enabled) }
                }
            }
            if let notice = model.navigationNotice { Text(notice).font(.caption).foregroundStyle(.secondary) }
            if let result = model.result {
                Text("所选范围  \(result.range.start.formatted(date: .abbreviated, time: .shortened)) — \(result.range.end.formatted(date: .abbreviated, time: .shortened))")
                    .font(.callout).monospacedDigit().fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("network.history.absoluteRange")
                if model.selectedApplication != nil {
                    if let app = result.applications.first {
                        HStack {
                            ApplicationNameView(identity: app.identity, notes: notes)
                            Spacer()
                            noteButton(app.identity)
                        }
                        HStack(spacing: 24) {
                            Label("上传量  " + NetworkPresentation.bytes(HistoryCurvePresentation.observedBytes(app.totals, upload: true)), systemImage: "arrow.up")
                                .foregroundStyle(NetworkPresentation.uploadColor)
                            Label("下载量  " + NetworkPresentation.bytes(HistoryCurvePresentation.observedBytes(app.totals, upload: false)), systemImage: "arrow.down")
                                .foregroundStyle(NetworkPresentation.downloadColor)
                        }.font(.headline).monospacedDigit()
                    } else { Text(HistoryCurvePresentation.emptyText(result)).font(.callout).foregroundStyle(.secondary) }
                    if let notice = HistoryCurvePresentation.historyNotice(coverage: result.coverage, range: result.range) {
                        Text(notice).font(.caption).foregroundStyle(.secondary)
                            .accessibilityIdentifier("network.history.recordingStart")
                    }
                    if let app = result.applications.first {
                        let notices = HistoryRecordingCopy.notices(app.totals.quality)
                        if !notices.isEmpty {
                            DisclosureGroup("记录情况") {
                                ForEach(notices, id: \.self) { Text($0).font(.caption).foregroundStyle(.secondary) }
                            }.accessibilityIdentifier("network.history.recordingConditions")
                        }
                    }
                    HistoryCurveView(buckets: result.curve, range: result.range)
                        .id(result.contract?.context.id)
                    Text(HistoryCurvePresentation.trafficScope).font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("按上传量排序").font(.caption).foregroundStyle(.secondary)
                    ForEach(result.applications) { app in
                        HStack(spacing: 12) {
                        Button { model.openApplication(app) } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 3) {
                                    ApplicationNameView(identity: app.identity, notes: notes)
                                    if app.identityOrder == .legacyUnverified {
                                        Text("旧记录中的应用名称可能与现在不同").font(.caption2).foregroundStyle(.secondary)
                                    }
                                }.frame(maxWidth: .infinity, alignment: .leading)
                                if !HistoryRecordingCopy.notices(app.totals.quality).isEmpty {
                                    Image(systemName: "info.circle")
                                        .foregroundStyle(.secondary)
                                        .help(HistoryRecordingCopy.notices(app.totals.quality).joined(separator: "；"))
                                        .accessibilityLabel("记录情况")
                                        .accessibilityValue(HistoryRecordingCopy.notices(app.totals.quality).joined(separator: "；"))
                                }
                                Text("↑ \(NetworkPresentation.bytes(app.totals.upload))").foregroundStyle(NetworkPresentation.uploadColor)
                                Text("↓ \(NetworkPresentation.bytes(app.totals.download))").foregroundStyle(NetworkPresentation.downloadColor)
                            }.font(.caption).monospacedDigit().padding(.vertical, 5).contentShape(Rectangle())
                        }.buttonStyle(.plain)
                            .id(BackgroundNetworkViewModel.ReturnFocus.application(app.id))
                            .focusable(true).focused($focused, equals: .application(app.id))
                            .accessibilityIdentifier("network.history.row.\(app.id)")
                            .onAppear { restoreFocus(for: .application(app.id)) }
                        noteButton(app.identity)
                        }
                    }
                    if result.applications.isEmpty { Text(HistoryCurvePresentation.emptyText(result)).font(.callout).foregroundStyle(.secondary).padding(.vertical, 18) }
                }
                DisclosureGroup("采集诊断") {
                    Text(HistoryCurvePresentation.diagnosticsScope).font(.caption).foregroundStyle(.secondary)
                    coverage(result)
                    if model.selectedApplication != nil, let app = result.applications.first {
                        Text(app.identityOrder == .observed
                             ? "应用信息记录 \(app.identitySnapshotCount) 份，显示所选范围内最后记录的名称。"
                             : "旧应用信息记录 \(app.identitySnapshotCount) 份，先后顺序未知。")
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
                    }
                }
                Divider()
                Text("上传活动").font(.subheadline.weight(.semibold))
                Picker("活动类型", selection: $model.eventKind) {
                    Text("全部").tag(String?.none)
                    Text("大量上传").tag(String?("large"))
                    Text("持续上传").tag(String?("sustained"))
                }.pickerStyle(.segmented).accessibilityIdentifier("network.history.eventsFilter")
                Text("只记录达到上传阈值的活动；跨出所选时间的活动会显示整段用量。")
                    .font(.caption2).foregroundStyle(.secondary)
                ForEach(result.events) { event in
                    Button { model.openEvent(event) } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("\(event.name) · \(event.kind == "large" ? "大量上传" : "持续上传")").font(.caption.weight(.medium))
                        Text("\(event.start.formatted(date: .abbreviated, time: .standard)) — \(event.end.formatted(date: .abbreviated, time: .standard))")
                        Text("整段上传 ↑ \(NetworkPresentation.bytes(event.bytes)) · 最高采样速率 \(NetworkPresentation.rate(event.peak)) · \(Int(event.observedSeconds)) 秒")
                        Text(event.kind == "large" ? "当时阈值：连续段 ≥ \(NetworkPresentation.bytes(event.rule.largeBytes))" :
                            HistoryUploadRuleFields.sustainedThreshold(event.rule))
                        if let reason = event.endReason { Text("结束原因  " + HistoryRecordingCopy.endReason(reason)).help(reason) }
                    }.font(.caption2).foregroundStyle(.secondary).padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading).background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 6))
                    }.buttonStyle(.plain).disabled(model.selectedApplication != nil)
                        .id(BackgroundNetworkViewModel.ReturnFocus.event(event.id))
                        .focusable(model.selectedApplication == nil).focused($focused, equals: .event(event.id))
                        .accessibilityIdentifier("network.history.event.\(event.id)")
                        .accessibilityHint("查看此活动所属应用的历史")
                        .onAppear { restoreFocus(for: .event(event.id)) }
                }
                if result.events.isEmpty { Text("本页没有达到记录阈值的上传活动").font(.caption).foregroundStyle(.secondary) }
                HStack {
                    Button("上一页") { model.previousPage() }.disabled(model.page == 0 || model.loading)
                    Text("第 \(model.page + 1) 页").font(.caption2)
                    Spacer()
                    Button("下一页") { model.nextPage() }
                        .disabled(model.loading || model.page >= 1023 || (model.page + 1) * 64 >= max(result.totalApplications, result.contract?.totalEvents ?? 0))
                }
            }
        }
        .background {
            if model.selectedApplication == nil {
                ProcessListKeyboard { key in
                    guard [UInt16(36), 49, 76].contains(key), !showingPreview, !saving, exportError == nil, editingNote == nil else { return false }
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
        .sheet(item: $editingNote) { target in
            ApplicationNoteEditor(identity: target.identity, notes: notes)
        }
        .sheet(isPresented: $showingPreview) {
            VStack(alignment: .leading, spacing: 12) {
                Text("历史 JSON 导出预览").font(.headline)
                Text(model.selectedApplication == nil ? "导出当前页的应用和上传活动。" : "导出当前应用和当前页的上传活动。").font(.caption)
                Text("每日汇总包含所选时间内匹配应用的全部记录，不受页码或活动类型影响。").font(.caption)
                Text("应用使用编号，文件不含名称、路径、PID、搜索原文或连接目标。用量和时间仍可能帮助识别来源。").font(.caption).foregroundStyle(.secondary)
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
            if let date = c.firstCollectedAt { Text("首次记录时的系统时间  \(date.formatted(date: .abbreviated, time: .standard))") }
            Text("采样 \(c.sourceSamples) 次")
            Text("未完整读取 \(c.sourcePartialSamples) 次")
            Text("无法对应应用的记录 \(c.unattributedSamples) 次")
            if let code = model.queryDiagnosticCode { Text("历史诊断代码  " + code).textSelection(.enabled) }
            Text("没有记录的时段留空；不足一分钟的采样不计作完整一分钟。")
            if c.retentionTrimmed { Text("较早记录已按保留期限清理；被清理时段不表示零流量。") }
            if c.eventsTruncated { Text("活动列表已触及容量限制；基础分钟记录仍独立保存。") }
            if c.recoveredUncleanSession { Text("上次后台异常退出，最后一批记录可能未保存。") }
            if c.conservativeAge { Text("部分旧记录的保存时间无法核实，已暂时保留。") }
        }.font(.caption).foregroundStyle(.secondary)
    }
    private func noteButton(_ identity: ProcessNetworkApplicationIdentity) -> some View {
        Button { editingNote = .init(identity: identity) } label: {
            Label("备注", systemImage: "square.and.pencil")
        }.buttonStyle(.borderless).font(.caption)
            .accessibilityIdentifier("network.history.note.\(identity.key)")
            .help("为 \(identity.name) 设置本机备注")
    }
    private func prepareExport() {
        guard let result = model.result else { return }
        do { preview = .init(data: try NetworkHistoryExport.encode(result)); showingPreview = true }
        catch { exportError = HistoryRecordingCopy.exportFailure(error) }
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
                Text("部分数据跨越分钟边界，归入同一时段。")
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
            Text("记录流量  " + (bytes.map { "\($0) 字节（\(NetworkPresentation.bytes($0))）" } ?? "未知"))
            Text("有记录的时长 \(HistoryCurvePresentation.observedSeconds(point, upload: upload).formatted(.number.precision(.fractionLength(0...3)))) 秒 · \(HistoryCurvePresentation.observation(point, upload: upload))")
            Text("最高采样速率  " + NetworkPresentation.rate(HistoryCurvePresentation.peak(point.totals, upload: upload)))
        }.font(.caption).monospacedDigit().frame(maxWidth: .infinity, alignment: .leading)
    }

}

struct HistoryCurveView: View {
    let buckets: [HistoryCurveBucket]
    let range: HistoryRange
    var drawsLine = false
    @State private var interaction = HistoryCurveInteraction()
    @FocusState private var focused: HistoryChartDirection?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("平均速率").font(.subheadline.weight(.semibold))
            Text(drawsLine ? HistoryCurvePresentation.granularity(buckets).replacingOccurrences(of: "每柱", with: "每段") : HistoryCurvePresentation.granularity(buckets)).font(.caption).foregroundStyle(.secondary)
            direction(.upload); direction(.download)
            if let inspected = interaction.inspected {
                if let point = HistoryCurvePresentation.bucket(at: inspected, in: buckets) {
                    HistoryCurveReadout(point: point)
                } else {
                    Text("\(inspected.formatted(date: .abbreviated, time: .standard)) · 该时段无可用记录")
                        .font(.callout).accessibilityIdentifier("network.history.inspection.gap")
                }
            } else {
                Text("悬停查看，点击固定；方向键移动，Esc取消固定").font(.caption).foregroundStyle(.secondary)
            }
            Text(drawsLine ? "两张图使用各自的刻度。缺少记录时断开；浅色线表示记录不完整。" : "两张图使用各自的刻度。彩色线表示零流量；留白表示没有记录；浅色柱表示记录不完整。")
                .font(.caption).foregroundStyle(.secondary)
            Text("平均速率按有记录的时长计算；最高采样速率取单次记录的最大值。")
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
                Text("范围内最高采样速率 " + NetworkPresentation.rate(peak)).foregroundStyle(.secondary)
            }.font(.callout)
            Chart {
                if drawsLine {
                    ForEach(HistoryCurvePresentation.linePoints(buckets, upload: upload)) { point in
                        LineMark(x: .value("时间", coordinates.x(at: point.date)), y: .value("观察均速", coordinates.y(for: point.rate)),
                                 series: .value("连续记录", point.series))
                            .foregroundStyle(color.opacity(point.partial ? 0.45 : 0.85))
                            .lineStyle(.init(lineWidth: 2))
                            .interpolationMethod(.linear)
                    }
                }
                ForEach(buckets) { point in
                    if let rate = HistoryCurvePresentation.average(point, upload: upload) {
                        if rate == 0 && !drawsLine {
                            RuleMark(xStart: .value("开始", coordinates.x(at: point.start)), xEnd: .value("结束", coordinates.x(at: point.end)), y: .value("已观察为零", 0.0))
                                .foregroundStyle(color.opacity(HistoryCurvePresentation.isPartial(point, upload: upload) ? 0.45 : 0.85)).lineStyle(.init(lineWidth: 2))
                        }
                        if rate > 0 && !drawsLine {
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
        return AXChartDescriptor(title: upload ? "历史上传已观察均速" : "历史下载已观察均速", summary: "各时段分别显示，记录缺口留空。",
            xAxis: x, yAxis: y, series: [AXDataSeriesDescriptor(name: "已观察时段", isContinuous: false, dataPoints: points)])
    }
}
