#if USAGE_BUTLER_FIXTURES
import Charts
import SwiftUI
import UniformTypeIdentifiers

/// Entirely compiled out of Release. These synthesized identities never enter
/// NetworkCollector, live capabilities, notifications or enforcement.
struct NetworkDemoApplicationsView: View {
    private struct DemoApp: Identifiable {
        let id: String
        let name: String
        let target: String
        let upload: Double
        let download: Double
    }
    private static let apps = (1...8).map { index in
        DemoApp(id: "demo-\(index)", name: ["示例编辑器", "示例浏览器", "示例输入工具", "示例同步工具", "示例终端", "示例播放器", "示例邮件", "示例远程工具"][index - 1],
                target: "service\(index).example.invalid", upload: Double(9 - index) * 12_000, download: Double(index) * 8_000)
    }
    @State private var search = ""
    @State private var sort = "近一分钟上传"
    @State private var watched: Set<String> = []
    @State private var onlyWatched = false
    @State private var selected: String?
    @State private var returnAnchor: String?
    @State private var tab = "趋势"
    @State private var actions: [String: String] = [:]
    @State private var targets: [String: String] = [:]
    @State private var savedActions: [String: String] = [:]
    @State private var savedTargets: [String: String] = [:]
    @State private var feedback = ""
    @State private var exportPreview = false
    @State private var exportAsOf = Date()
    @State private var redacted = true
    @State private var exporting = false
    @State private var exportDocument: DemoJSONDocument?
    @State private var exportError: String?
    @FocusState private var focusedApp: String?
    @FocusState private var backFocused: Bool
    private let tabs = ["趋势", "连接", "域名/IP", "进程", "规则"]

    private var filtered: [DemoApp] {
        Self.apps.filter { (!onlyWatched || watched.contains($0.id)) &&
            (search.isEmpty || ($0.name + $0.target + "192.0.2.\($0.id.suffix(1))").localizedCaseInsensitiveContains(search))
        }.sorted {
            switch sort {
            case "名称": return $0.name < $1.name
            case "当前下载": return $0.download > $1.download
            default: return $0.upload > $1.upload
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("演示数据 · 未连接真实应用采集", systemImage: "testtube.2")
                .font(.caption.weight(.semibold)).foregroundStyle(.orange)
            if let app = Self.apps.first(where: { $0.id == selected }) {
                detail(app)
            } else { appList }
            HStack {
                Text("关注和规则草稿仅在本次演示会话保存").font(.caption2).foregroundStyle(.secondary)
                Spacer()
                Button("导出预览") { redacted = true; exportAsOf = Date(); exportPreview = true }
                    .accessibilityIdentifier("network.demo.export")
            }
        }.padding(12).background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 12))
        .sheet(isPresented: $exportPreview) { preview }
        .fileExporter(isPresented: $exporting, document: exportDocument, contentType: .json, defaultFilename: "network-demo") { result in
            if case let .failure(error) = result { exportError = error.localizedDescription }
        }
        .alert("导出失败", isPresented: Binding(get: { exportError != nil }, set: { if !$0 { exportError = nil } })) {
            Button("好") { exportError = nil }
        } message: { Text(exportError ?? "") }
    }

    private var appList: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("搜索应用、域名或 IP", text: $search).textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("network.demo.search")
            HStack {
                Picker("排序", selection: $sort) {
                    ForEach(["近一分钟上传", "当前下载", "名称"], id: \.self) { Text($0) }
                }
                Toggle("仅关注", isOn: $onlyWatched).toggleStyle(.checkbox)
            }.font(.caption)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        if filtered.isEmpty { Text("无匹配应用 · 可清除搜索或关注筛选").font(.caption).padding() }
                        ForEach(filtered) { app in
                            HStack {
                                Button { if watched.contains(app.id) { watched.remove(app.id) } else { watched.insert(app.id) } } label: {
                                    Image(systemName: watched.contains(app.id) ? "star.fill" : "star")
                                }.buttonStyle(.borderless).accessibilityLabel("关注 \(app.name)")
                                Button {
                                    returnAnchor = app.id; selected = app.id; tab = "趋势"; feedback = ""; backFocused = true
                                } label: {
                                    HStack {
                                        VStack(alignment: .leading) { Text(app.name); Text(app.target).font(.caption2).foregroundStyle(.secondary) }
                                        Spacer()
                                        Text("↑ \(NetworkPresentation.bytes(UInt64(app.upload))) / 分钟").font(.caption).monospacedDigit()
                                        Image(systemName: "chevron.right")
                                    }.contentShape(Rectangle())
                                }.buttonStyle(.plain).focused($focusedApp, equals: app.id).accessibilityIdentifier("network.demo.app.\(app.id)")
                            }.padding(.vertical, 9).id(app.id)
                            Divider()
                        }
                    }
                }.frame(height: 210)
                .onAppear {
                    if let returnAnchor { proxy.scrollTo(returnAnchor, anchor: .center); focusedApp = returnAnchor }
                }
            }
        }
    }

    private func detail(_ app: DemoApp) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Button("返回应用列表") { selected = nil; focusedApp = returnAnchor }.focused($backFocused)
                    .accessibilityIdentifier("network.demo.back")
                Spacer()
                Text(app.name).font(.subheadline.weight(.semibold))
            }
            Picker("详情", selection: $tab) { ForEach(tabs, id: \.self) { Text($0) } }
                .pickerStyle(.segmented).accessibilityIdentifier("network.demo.tabs")
            Group {
                switch tab {
                case "趋势":
                    VStack(alignment: .leading) {
                        Text("合成的近一分钟应用上传趋势 · 与接口口径独立").font(.caption)
                        Chart(0..<12, id: \.self) { point in
                            LineMark(x: .value("秒", point * 5), y: .value("B/s", app.upload / 60 * (1 + Double(point % 3) * 0.25)))
                                .foregroundStyle(NetworkPresentation.uploadColor)
                        }.frame(height: 130)
                        Text("当前下载 \(NetworkPresentation.rate(app.download))").font(.caption)
                    }
                case "连接":
                    Text("TCP · 192.0.2.\(app.id.suffix(1)):443\n状态：演示中的已连接\n连接数量：1（合成数据）")
                case "域名/IP":
                    Text("\(app.target)\n192.0.2.\(app.id.suffix(1))\n域名来源：合成样例；不代表反向 DNS 或本机访问记录")
                case "进程":
                    Text("PID：\(4_000 + Int(app.id.suffix(1))!)（演示）\n路径：/Applications/Demo.app\n签名、进程归属：合成示例，不是系统验证")
                default:
                    VStack(alignment: .leading) {
                        Text("规则草稿 · 不执行网络操作").font(.caption.weight(.semibold))
                        Picker("意图", selection: Binding(get: { actions[app.id] ?? "允许" }, set: { actions[app.id] = $0; feedback = "" })) {
                            ForEach(["允许", "询问", "阻止"], id: \.self) { Text($0) }
                        }
                        TextField("目标草稿（可选）", text: Binding(get: { targets[app.id] ?? "" }, set: { targets[app.id] = $0; feedback = "" }))
                            .textFieldStyle(.roundedBorder)
                        HStack {
                            Button("保存草稿") {
                                savedActions[app.id] = actions[app.id] ?? "允许"; savedTargets[app.id] = targets[app.id] ?? ""
                                feedback = "草稿已保存于演示会话；系统未应用"
                            }
                            Button("撤销编辑") {
                                actions[app.id] = savedActions[app.id] ?? "允许"; targets[app.id] = savedTargets[app.id] ?? ""
                                feedback = "已恢复上次草稿"
                            }
                        }
                        Text(feedback).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }.frame(maxWidth: .infinity, minHeight: 170, alignment: .topLeading).font(.callout).textSelection(.enabled)
        }
    }

    private var preview: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("演示 JSON 导出预览").font(.headline)
            Text("仅导出当前筛选应用或所选应用；时间和流量会保留。别名化并非匿名化，不包含规则草稿、路径或 PID。").font(.caption)
            Toggle("脱敏应用与目标（默认）", isOn: $redacted)
            ScrollView { Text(exportText).font(.system(.caption, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                .frame(height: 260)
            HStack {
                Button("取消") { exportPreview = false }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("选择本地保存位置…") {
                    exportDocument = DemoJSONDocument(text: exportText); exportPreview = false; exporting = true
                }.keyboardShortcut(.defaultAction)
            }
        }.padding(20).frame(width: 460)
    }

    private var exportText: String {
        let apps = selected.map { id in Self.apps.filter { $0.id == id } } ?? filtered
        let rows: [[String: Any]] = apps.enumerated().map { index, app in
            ["app": redacted ? "application-\(index + 1)" : app.name,
             "target": redacted ? "target-\(index + 1)" : app.target,
             "uploadLastMinuteBytes": String(UInt64(app.upload)), "downloadBytesPerSecond": app.download]
        }
        let object: [String: Any] = ["schema": "usagebutler.network.demo-export.v1", "fixture": true,
            "asOf": ISO8601DateFormatter().string(from: exportAsOf), "windowSeconds": 60,
            "applicationInterfaceFilterApplied": false, "scope": "synthetic-one-minute",
            "redacted": redacted, "apps": rows]
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]), let text = String(data: data, encoding: .utf8) else { return "{}" }
        return text
    }
}

private struct DemoJSONDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    var text: String
    init(text: String) { self.text = text }
    init(configuration: ReadConfiguration) throws { text = String(decoding: configuration.file.regularFileContents ?? Data(), as: UTF8.self) }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: Data(text.utf8)) }
}
#endif
