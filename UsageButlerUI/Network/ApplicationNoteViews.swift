import SwiftUI
import UsageButlerDomain

struct ApplicationNoteTarget: Identifiable {
    let identity: ProcessNetworkApplicationIdentity
    var id: String { identity.key }
}

struct ApplicationNameView: View {
    let identity: ProcessNetworkApplicationIdentity
    @ObservedObject var notes: ApplicationNoteStore
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(notes.displayName(for: identity)).lineLimit(1)
                .help(notes.displayName(for: identity))
            if notes.note(for: identity) != nil {
                Text("原名：" + identity.name).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
        }
    }
}

struct ApplicationNoteEditor: View {
    let identity: ProcessNetworkApplicationIdentity
    @ObservedObject var notes: ApplicationNoteStore
    @Environment(\.dismiss) private var dismiss
    @State private var text: String
    @FocusState private var editing: Bool
    init(identity: ProcessNetworkApplicationIdentity, notes: ApplicationNoteStore) {
        self.identity = identity; self.notes = notes
        _text = State(initialValue: notes.note(for: identity) ?? "")
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("应用备注").font(.headline)
            VStack(alignment: .leading, spacing: 5) {
                Text("原名：" + identity.name)
                Text("标识：" + (identity.bundleID ?? "无 Bundle 标识"))
                Text("路径：" + (identity.installationPath ?? "未记录"))
                    .fixedSize(horizontal: false, vertical: true)
            }.font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            TextField("备注名（最多 60 个字符）", text: $text)
                .textFieldStyle(.roundedBorder).focused($editing)
                .accessibilityIdentifier("network.note.text")
            Text("仅在本机显示；原始名称、统计、搜索和导出保持不变。留空保存可清除备注。")
                .font(.caption).foregroundStyle(.secondary)
            if let issue = ApplicationNoteStore.validationMessage(text) {
                Text(issue).font(.caption).foregroundStyle(.red)
            }
            HStack {
                Button("清除备注") { text = "" }
                    .disabled(text.isEmpty).accessibilityIdentifier("network.note.clear")
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("network.note.cancel")
                Button("保存") { if notes.save(text, for: identity) { dismiss() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(ApplicationNoteStore.validationMessage(text) != nil)
                    .accessibilityIdentifier("network.note.save")
            }
        }.padding(22).frame(width: 440).onAppear { editing = true }
    }
}
