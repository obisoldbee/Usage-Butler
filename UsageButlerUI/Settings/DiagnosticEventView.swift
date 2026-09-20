import SwiftUI
import UsageButlerCore

struct DiagnosticEventView: View {
    let event: ProviderDiagnosticEvent

    var body: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 4) {
                Text("事件 \(event.id.uuidString) · 读取 \(event.attemptID.uuidString)")
                Text("阶段 \(event.stage.rawValue) · 原因 \(event.reason.rawValue)")
                if let version = event.cliVersion { Text("CLI \(version)") }
                if let digest = event.executableSHA256 { Text("CLI SHA256 \(digest)") }
                if let code = event.exitCode { Text("退出码 \(code)") }
                if let elapsed = event.durationMilliseconds { Text("耗时 \(elapsed) ms") }
                if let size = event.stdoutBytes { Text("标准输出 \(size) 字节") }
                if let size = event.stderrBytes { Text("错误输出 \(size) 字节（脱敏后）") }
                if let path = event.fieldPath { Text("字段 \(path)") }
                if let model = event.model { Text("指标 \(model) / \(event.window ?? "unknown")") }
                if let gate = event.retryGate { Text("重试状态 \(gate.rawValue)") }
                if let automatic = event.automaticRetry {
                    Text(automatic ? String(localized: "自动刷新") : String(localized: "仅手动刷新"))
                }
                if let retryAt = event.retryAt { Text("计划重试 \(retryAt.formatted(date: .omitted, time: .standard))") }
                ForEach(event.values.keys.sorted(), id: \.self) { key in
                    Text("\(key) = \(event.values[key]!.formatted())")
                }
            }
            .font(.caption.monospaced())
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            Text("\(event.timestamp.formatted(date: .abbreviated, time: .standard)) · \(title)")
                .font(.caption)
        }
    }

    private var title: String {
        switch event.reason {
        case .recovered: String(localized: "已恢复")
        case .processFailure: String(localized: "命令执行失败")
        case .invalidJSON, .emptyOutput: String(localized: "输出格式无法识别")
        case .missingField: String(localized: "缺少额度字段")
        case .invalidType: String(localized: "额度字段类型不符")
        case .unsupportedStatus: String(localized: "额度状态尚不支持")
        case .invalidPercent: String(localized: "额度百分比异常")
        case .invalidCount: String(localized: "额度计数异常")
        case .unsupportedModel: String(localized: "额度项目尚不支持")
        case .unsupportedBoost: String(localized: "额度加成尚不支持")
        case .partialRows: String(localized: "部分额度条目异常")
        case .baseStatus: String(localized: "额度服务返回失败状态")
        case .providerFailure: event.failureCode ?? String(localized: "额度刷新失败")
        }
    }
}
