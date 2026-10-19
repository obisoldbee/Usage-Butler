import AppKit
import SwiftUI
import UniformTypeIdentifiers
import UsageButlerCore
import UsageButlerDomain

struct ProcessNetworkApplicationsView: View {
    @ObservedObject var model: ProcessNetworkViewModel
    let now: Date
    @ObservedObject private var notes: ApplicationNoteStore
    @State private var editingNote: ApplicationNoteTarget?
    init(model: ProcessNetworkViewModel, now: Date) {
        self.model = model; self.now = now; notes = model.applicationNotes
    }
    @FocusState private var focusedApp: String?
    @State private var preview: ProcessJSONDocument?
    @State private var showPreview = false
    @State private var saving = false
    @State private var exportError: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let key = model.selected {
                if let app = model.snapshot?.applications[key] { detail(app) }
                else {
                    Button("返回应用列表") { model.back() }
                    Text("这条记录已不可用，请返回应用列表。")
                }
            } else { list }
        }
        .sheet(item: $editingNote) { target in
            ApplicationNoteEditor(identity: target.identity, notes: notes)
        }
        .sheet(isPresented: $showPreview) {
            VStack(alignment: .leading, spacing: 12) {
                Text("本地 JSON 导出预览").font(.headline)
                Text(model.selected == nil ? "导出当前列表。应用使用编号，文件不含名称、路径、PID或连接目标。" : "导出当前应用。文件不含名称、路径、PID或连接目标。")
                    .font(.caption).foregroundStyle(.secondary)
                Text("仅包含当前可用的最近60秒数据；更早记录请从历史窗口导出。用量和时间仍可能帮助识别来源。")
                    .font(.caption2).foregroundStyle(.secondary)
                ScrollView { Text(preview?.text ?? "").font(.system(.caption, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                HStack {
                    Button("取消") { showPreview = false; preview = nil }.keyboardShortcut(.cancelAction)
                        .accessibilityIdentifier("network.apps.export.cancel")
                    Spacer()
                    Button("保存到文件…") { showPreview = false; saving = true }.keyboardShortcut(.defaultAction)
                        .accessibilityIdentifier("network.apps.export.save")
                }
            }.padding(20).frame(width: 480, height: 430)
        }
        .fileExporter(isPresented: $saving, document: preview, contentType: .json, defaultFilename: "application-network") { result in
            if case .failure = result { exportError = "无法保存所选文件，请选择可写的位置。" }
            preview = nil
        }
        .alert("导出失败", isPresented: Binding(get: { exportError != nil }, set: { if !$0 { exportError = nil } })) {
            Button("好") { exportError = nil }
        } message: { Text(exportError ?? "") }
    }
    private var list: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("应用活动").font(.headline)
                Spacer()
                Button("导出预览") { prepareExport(detail: nil) }.disabled(model.rows.isEmpty)
                    .accessibilityIdentifier("network.apps.export")
            }
            Text("应用流量包含本机通信和代理转发").font(.caption).foregroundStyle(.secondary)
            status
            HStack {
                TextField("搜索应用或进程", text: $model.search)
                    .textFieldStyle(.roundedBorder).accessibilityIdentifier("network.apps.search")
                Picker("排序", selection: $model.sort) {
                    Text("上传").tag(ProcessNetworkViewModel.Sort.upload)
                    Text("下载").tag(ProcessNetworkViewModel.Sort.download)
                    Text("名称").tag(ProcessNetworkViewModel.Sort.name)
                }.frame(width: 124).accessibilityIdentifier("network.apps.sort")
            }
            Toggle("仅看关注", isOn: $model.onlyWatched).toggleStyle(.checkbox)
                .accessibilityIdentifier("network.apps.watchedOnly")
            HStack(spacing: 5) {
                HStack(spacing: 8) {
                    Text("应用 / 进程").frame(maxWidth: .infinity, alignment: .leading)
                    Text("当前上传").frame(width: 92, alignment: .trailing)
                        .accessibilityIdentifier("network.apps.column.upload")
                    Text("当前下载").frame(width: 92, alignment: .trailing)
                        .accessibilityIdentifier("network.apps.column.download")
                    Color.clear.frame(width: 8, height: 1)
                }.padding(.horizontal, 8)
                Color.clear.frame(width: 20, height: 1)
            }.font(.caption).foregroundStyle(.secondary)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(model.rows, id: \.identity.key) { app in
                            HStack(spacing: 5) {
                            Button { model.open(app.identity.key) } label: { row(app) }
                                .buttonStyle(.plain).id(app.identity.key)
                                .focusable(true)
                                .focused($focusedApp, equals: app.identity.key)
                                .accessibilityIdentifier("network.apps.row.\(app.identity.key)")
                                .onAppear {
                                    guard model.returnAnchor == app.identity.key else { return }
                                    // After the lazy row is attached, restore its
                                    // focus rather than the recreated search field.
                                    DispatchQueue.main.async {
                                        if model.selected == nil, model.returnAnchor == app.identity.key {
                                            focusedApp = app.identity.key
                                        }
                                    }
                                }
                            noteButton(app.identity)
                            }
                        }
                        if model.rows.isEmpty {
                            Text(model.search.isEmpty ? "当前没有应用流量记录。" : "没有匹配的应用或进程。")
                                .font(.callout).foregroundStyle(.secondary).padding(.vertical, 30)
                        }
                    }
                }.frame(height: 290)
                .onAppear {
                    if let anchor = model.returnAnchor {
                        proxy.scrollTo(anchor, anchor: .center)
                    }
                }
            }
            .background(ProcessListKeyboard { key in
                guard [UInt16(36), 49].contains(key), editingNote == nil, !showPreview, !saving, exportError == nil, let app = focusedApp,
                      model.rows.contains(where: { $0.identity.key == app }) else { return false }
                model.open(app); return true
            })
            Text("可筛选查看关注的应用；关注仅本次运行有效，不发送提醒。")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }
    @ViewBuilder private var status: some View {
        if model.currentState != .active {
            Text(model.observationTitle)
                .font(.caption).foregroundStyle(.secondary).accessibilityIdentifier("network.apps.status")
            if let sampledAt = model.snapshot?.sampledAt {
                Text("上次记录  \(sampledAt.formatted(date: .abbreviated, time: .standard))，当前速率不可用")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
        if model.snapshot?.truncated == true {
            Text("记录数量达到上限，部分较早样本或应用未保留。")
                .font(.caption2).foregroundStyle(.secondary).accessibilityIdentifier("network.apps.truncated")
        }
    }
    private func row(_ app: ProcessNetworkApplication) -> some View {
        let fresh = model.fresh(app, now: now)
        return HStack(spacing: 8) {
            Image(systemName: model.watched.contains(app.identity.key) ? "star.fill" : app.identity.bundleID == nil ? "terminal" : "app")
                .foregroundStyle(model.watched.contains(app.identity.key) ? Color.orange : .secondary)
            VStack(alignment: .leading, spacing: 3) {
                ApplicationNameView(identity: app.identity, notes: notes).font(.callout.weight(.medium))
                Text(presence(app)).font(.caption2).foregroundStyle(.secondary)
                Text("本段 ↑ \(NetworkPresentation.bytes(app.total.upload.bytes)) · ↓ \(NetworkPresentation.bytes(app.total.download.bytes))")
                    .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }.frame(maxWidth: .infinity, alignment: .leading)
            Text(NetworkPresentation.rate(fresh ? app.rate?.uploadBytesPerSecond : nil))
                .foregroundStyle(NetworkPresentation.uploadColor).frame(width: 92, alignment: .trailing)
                .accessibilityIdentifier("network.apps.upload.\(app.identity.key)")
            Text(NetworkPresentation.rate(fresh ? app.rate?.downloadBytesPerSecond : nil))
                .foregroundStyle(NetworkPresentation.downloadColor).frame(width: 92, alignment: .trailing)
                .accessibilityIdentifier("network.apps.download.\(app.identity.key)")
            Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.secondary).frame(width: 8)
        }.font(.caption).monospacedDigit().padding(.horizontal, 8).padding(.vertical, 9)
            .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 7)).contentShape(Rectangle())
    }
    private func presence(_ app: ProcessNetworkApplication) -> String {
        switch app.presence {
        case .present: return app.identity.evidence == .unknown ? "暂无法确认这个进程所属的应用" : "\(app.processes.count) 个已观察进程"
        case .missing: return "最近采样未发现，保留已有记录"
        case .unknown: return "暂无法确认是否仍在运行"
        case .notObserved: return "未观察 · 保留历史"
        }
    }
    private func detail(_ app: ProcessNetworkApplication) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Button { model.back() } label: { Label("应用列表", systemImage: "chevron.left") }
                    .accessibilityIdentifier("network.apps.back")
                Spacer()
                Button(model.watched.contains(app.identity.key) ? "取消关注" : "关注") { model.toggleWatch(app.identity.key) }
                    .disabled(app.identity.evidence == .unknown)
                    .accessibilityIdentifier("network.apps.watch")
                Button("导出预览") { prepareExport(detail: app.identity.key) }
                    .accessibilityIdentifier("network.apps.detailExport")
            }
            HStack {
                ApplicationNameView(identity: app.identity, notes: notes).font(.headline)
                Spacer()
                noteButton(app.identity)
            }
            Text(presence(app)).font(.caption).foregroundStyle(.secondary)
            status
            Text(NetworkStatusRules.applicationSegmentText(app.total.upload, direction: String(localized: "上传累计")))
                .font(.caption2).foregroundStyle(.secondary).accessibilityIdentifier("network.apps.segment.upload")
            Text(NetworkStatusRules.applicationSegmentText(app.total.download, direction: String(localized: "下载累计")))
                .font(.caption2).foregroundStyle(.secondary).accessibilityIdentifier("network.apps.segment.download")
            if model.onLongHistory == nil || model.range == .oneMinute {
                NetworkTrendView(range: $model.range, frame: model.frame(for: app, now: now),
                    total: app.total, rate: app.rate, stale: !model.fresh(app, now: now), interface: app.identity.key)
            } else {
                NetworkRangeSelector(range: $model.range)
                Text(model.longHistoryLoading ? "读取\(model.range.title)历史…" : " ").font(.caption2).foregroundStyle(.secondary).frame(height: 14)
                if let history = model.longHistory { HistoryCurveView(buckets: history.curve, range: history.range, drawsLine: true) }
                else if !model.longHistoryLoading { Text(model.longHistoryIssue ?? "此范围尚无分钟历史。").font(.caption).foregroundStyle(.secondary) }
            }
            Text("进程与归属").font(.subheadline.weight(.semibold))
            Text(identityText(app)).font(.caption).foregroundStyle(.secondary)
            ForEach(Array(app.processes.prefix(32).enumerated()), id: \.offset) { _, process in
                VStack(alignment: .leading, spacing: 3) {
                    Text("\(process.identity.name) · PID \(process.identity.pid)").font(.caption)
                    Text(process.identity.instanceID == nil ? "开始时间未知" : "开始时间已确认")
                        .font(.caption2).foregroundStyle(.secondary)
                    if let path = process.identity.executablePath { Text(path).font(.caption2).textSelection(.enabled).lineLimit(2) }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            if app.processes.count > 32 { Text("仅显示前 32 个进程；总计 \(app.processes.count) 个。").font(.caption2) }
            DisclosureGroup("技术信息") {
                Text("来源为系统nettop，未记录连接目标、协议或连接数；未验证应用签名。")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
    }
    private func identityText(_ app: ProcessNetworkApplication) -> String {
        switch app.identity.evidence {
        case .executableBundle: "按可执行文件路径归入此应用"
        case .nestedBundle: "应用内的辅助进程，按安装路径归属"
        case .executable: "独立进程，应用归属尚未确认"
        case .unknown: "进程身份尚未确认"
        }
    }
    private func noteButton(_ identity: ProcessNetworkApplicationIdentity) -> some View {
        Button { editingNote = .init(identity: identity) } label: {
            Image(systemName: "square.and.pencil")
        }.buttonStyle(.borderless).frame(width: 20).accessibilityLabel("备注：" + identity.name)
            .accessibilityIdentifier("network.apps.note.\(identity.key)")
            .help("设置本机备注")
    }
    private func prepareExport(detail: String?) {
        guard let snapshot = model.snapshotForExport else { return }
        do {
            let data = try ProcessNetworkExport.encode(snapshot: snapshot,
                keys: detail.map { [$0] } ?? model.rows.map { $0.identity.key }, now: now,
                window: model.range.duration, includeHistory: detail != nil)
            preview = ProcessJSONDocument(data: data); showPreview = true
        } catch ProcessNetworkExport.Failure.oversized { exportError = "导出数据过多，请从应用详情导出单个应用。" }
        catch { exportError = "暂时无法生成导出，请重试。" }
    }
}

/// Activation for the explicitly focused row, including when macOS keyboard
/// navigation is disabled. Never consumes a key from the search field or a
/// different window, and detaches with the list.
struct ProcessListKeyboard: NSViewRepresentable {
    var onKey: (UInt16) -> Bool
    func makeNSView(context: Context) -> KeyView {
        let view = KeyView()
        view.monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak view] event in
            let consumed = MainActor.assumeIsolated {
                guard let view, let window = view.window, event.window === window,
                      !(window.firstResponder is NSTextView),
                      event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty,
                      view.onKey?(event.keyCode) == true else { return false }
                return true
            }
            return consumed ? nil : event
        }
        return view
    }
    func updateNSView(_ view: KeyView, context: Context) { view.onKey = onKey }
    static func dismantleNSView(_ view: KeyView, coordinator: ()) {
        if let monitor = view.monitor { NSEvent.removeMonitor(monitor) }
        view.monitor = nil; view.onKey = nil
    }
    final class KeyView: NSView {
        var onKey: ((UInt16) -> Bool)?
        var monitor: Any?
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}

struct ProcessJSONDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    var data: Data
    var text: String { String(decoding: data, as: UTF8.self) }
    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws { data = configuration.file.regularFileContents ?? Data() }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}
