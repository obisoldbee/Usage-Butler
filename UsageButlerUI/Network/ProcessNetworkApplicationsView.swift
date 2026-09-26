import AppKit
import SwiftUI
import UniformTypeIdentifiers
import UsageButlerCore
import UsageButlerDomain

struct ProcessNetworkApplicationsView: View {
    @ObservedObject var model: ProcessNetworkViewModel
    let now: Date
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
                    Text("此观察已结束，或历史未被保留。")
                }
            } else { list }
        }
        .sheet(isPresented: $showPreview) {
            VStack(alignment: .leading, spacing: 12) {
                Text("本地 JSON 导出预览").font(.headline)
                Text("固定当前快照并使用应用别名；不含名称、路径、PID 或目标。别名化不等于匿名。")
                    .font(.caption).foregroundStyle(.secondary)
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
            Text("系统可见进程的收发字节 · 含回环与代理进程").font(.caption).foregroundStyle(.secondary)
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
            HStack {
                Text("应用 / 进程").frame(maxWidth: .infinity, alignment: .leading)
                Text("当前上传").frame(width: 92, alignment: .trailing)
                Text("当前下载").frame(width: 92, alignment: .trailing)
            }.font(.caption).foregroundStyle(.secondary).padding(.trailing, 22)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(model.rows, id: \.identity.key) { app in
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
                        }
                        if model.rows.isEmpty {
                            Text(model.search.isEmpty ? "当前没有可显示的应用观察。" : "没有匹配的应用或进程。")
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
                guard [UInt16(36), 49].contains(key), let app = focusedApp,
                      model.rows.contains(where: { $0.identity.key == app }) else { return false }
                model.open(app); return true
            })
            Text("关注仅在本次运行保留；不发送提醒。累计与趋势从实际观测起点开始。")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }
    @ViewBuilder private var status: some View {
        let state = model.snapshot?.state ?? .stopped
        if state != .active {
            Text(state == .stopped ? "应用采集已停止 · 可在设置 → 网络中开启" :
                state == .starting ? "正在建立应用采样基线…" :
                state == .partial ? "应用采样不完整 · 当前速率未知" : "应用来源暂不可用 · 接口统计独立运行")
                .font(.caption).foregroundStyle(.secondary).accessibilityIdentifier("network.apps.status")
        }
        if model.snapshot?.truncated == true {
            Text("历史受资源预算限制，部分早期样本或应用未保留。")
                .font(.caption2).foregroundStyle(.secondary).accessibilityIdentifier("network.apps.truncated")
        }
    }
    private func row(_ app: ProcessNetworkApplication) -> some View {
        let fresh = model.fresh(app, now: now)
        return HStack(spacing: 8) {
            Image(systemName: model.watched.contains(app.identity.key) ? "star.fill" : app.identity.bundleID == nil ? "terminal" : "app")
                .foregroundStyle(model.watched.contains(app.identity.key) ? Color.orange : .secondary)
            VStack(alignment: .leading, spacing: 3) {
                Text(app.identity.name).font(.callout.weight(.medium)).lineLimit(1)
                Text(presence(app)).font(.caption2).foregroundStyle(.secondary)
                Text("本段 ↑ \(NetworkPresentation.bytes(app.total.upload.bytes)) · ↓ \(NetworkPresentation.bytes(app.total.download.bytes))")
                    .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }.frame(maxWidth: .infinity, alignment: .leading)
            Text(NetworkPresentation.rate(fresh ? app.rate?.uploadBytesPerSecond : nil))
                .foregroundStyle(NetworkPresentation.uploadColor).frame(width: 92, alignment: .trailing)
            Text(NetworkPresentation.rate(fresh ? app.rate?.downloadBytesPerSecond : nil))
                .foregroundStyle(NetworkPresentation.downloadColor).frame(width: 92, alignment: .trailing)
            Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.secondary)
        }.font(.caption).monospacedDigit().padding(.horizontal, 8).padding(.vertical, 9)
            .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 7)).contentShape(Rectangle())
    }
    private func presence(_ app: ProcessNetworkApplication) -> String {
        switch app.presence {
        case .present: return app.identity.evidence == .unknown ? "身份未确认 · 不跨样本结算" : "\(app.processes.count) 个已观察进程"
        case .missing: return "当前源中未出现 · 保留历史"
        case .unknown: return "当前存在状态未知"
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
            Text(app.identity.name).font(.headline).textSelection(.enabled)
            Text(presence(app)).font(.caption).foregroundStyle(.secondary)
            status
            if let notice = NetworkStatusRules.historyRestartNotice(app.total, samples: app.history,
                now: now, window: model.range.duration) {
                Text(notice).font(.caption2).foregroundStyle(.orange)
                    .accessibilityIdentifier("network.apps.historyRestart")
            }
            NetworkTrendView(range: $model.range, frame: model.frame(for: app, now: now),
                total: app.total, rate: app.rate, stale: !model.fresh(app, now: now), interface: app.identity.key)
            Text("进程与归属").font(.subheadline.weight(.semibold))
            Text(identityText(app)).font(.caption).foregroundStyle(.secondary)
            ForEach(Array(app.processes.prefix(32).enumerated()), id: \.offset) { _, process in
                VStack(alignment: .leading, spacing: 3) {
                    Text("\(process.identity.name) · PID \(process.identity.pid)").font(.caption)
                    Text(process.identity.instanceID == nil ? "启动身份未知" : "已核对系统启动身份")
                        .font(.caption2).foregroundStyle(.secondary)
                    if let path = process.identity.executablePath { Text(path).font(.caption2).textSelection(.enabled).lineLimit(2) }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            if app.processes.count > 32 { Text("仅显示前 32 个进程；总计 \(app.processes.count) 个。").font(.caption2) }
            Text("来源：系统 nettop 进程计数。连接数、协议、目标与防护未采集；签名未验证。")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }
    private func identityText(_ app: ProcessNetworkApplication) -> String {
        switch app.identity.evidence {
        case .executableBundle: "可执行文件与应用 Bundle 路径匹配"
        case .nestedBundle: "应用 Bundle 内的辅助进程；按实际安装路径归属"
        case .executable: "独立可执行文件；没有已核验的应用 Bundle 归属"
        case .unknown: "系统启动身份未确认；保持独立的未知进程"
        }
    }
    private func prepareExport(detail: String?) {
        guard let snapshot = model.snapshot else { return }
        do {
            let data = try ProcessNetworkExport.encode(snapshot: snapshot,
                keys: detail.map { [$0] } ?? model.rows.map { $0.identity.key }, now: now,
                window: model.range.duration, includeHistory: detail != nil)
            preview = ProcessJSONDocument(data: data); showPreview = true
        } catch { exportError = "导出超过大小上限或无法编码，请缩小时间范围后重试。" }
    }
}

/// Activation for the explicitly focused row, including when macOS keyboard
/// navigation is disabled. Never consumes a key from the search field or a
/// different window, and detaches with the list.
private struct ProcessListKeyboard: NSViewRepresentable {
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

private struct ProcessJSONDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    var data: Data
    var text: String { String(decoding: data, as: UTF8.self) }
    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws { data = configuration.file.regularFileContents ?? Data() }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}
