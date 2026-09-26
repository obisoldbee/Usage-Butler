#if DEBUG
import AppKit
import UsageButlerDomain

/// Same signed App peer exercises production IPC. Only a uniquely identified
/// validation bundle in its own directory can emit these scalar-only receipts.
@MainActor enum BackgroundHistoryValidation {
    static func start(runtime: AppRuntime) {
        func argument(_ name: String) -> String? {
            CommandLine.arguments.first { $0.hasPrefix(name + "=") }.map { String($0.dropFirst(name.count + 1)) }
        }
        guard runtime.launchMode == .networkValidation,
              Bundle.main.bundleIdentifier?.hasPrefix("io.github.obisoldbee.UsageButler.Validation.") == true,
              let tag = argument("--history-probe"), (1...80).contains(tag.count),
              tag.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }) else { return }
        let action = argument("--history-action") ?? "status"
        guard ["status", "enable", "stop", "query", "refresh", "show"].contains(action) else { return }
        let seconds = min(1_200, max(0, Int(argument("--history-delay") ?? "2") ?? 2))
        Task {
            await runtime.debugBackgroundReady()
            if action == "enable" { await runtime.menuModel.backgroundNetwork.onEnabled?(true) }
            if action == "stop" { await runtime.menuModel.backgroundNetwork.onEnabled?(false) }
            if action == "refresh" { await runtime.debugBackgroundRefresh() }
            if action == "show" { runtime.menuModel.backgroundNetwork.onOpenHistory?() }
            try? await Task.sleep(for: .seconds(seconds))
            var result: [String: Any] = ["tag": tag, "action": action, "appPID": getpid(),
                "bundle": Bundle.main.bundleURL.path, "at": ISO8601DateFormatter().string(from: Date())]
            let model = runtime.menuModel.backgroundNetwork
            result["registration"] = model.registration; result["desired"] = model.desired
            result["serviceIssue"] = model.serviceIssue ?? ""
            if let status = model.status, let data = try? JSONEncoder().encode(status),
               let object = try? JSONSerialization.jsonObject(with: data) { result["status"] = object }
            if action == "query", let query = model.onQuery {
                do {
                    let start = ContinuousClock.now
                    let history = try await query(.recent(days: 14), nil, 0, nil)
                    result["querySeconds"] = Double(start.duration(to: .now).components.attoseconds) / 1e18 + Double(start.duration(to: .now).components.seconds)
                    result["applicationCount"] = history.totalApplications
                    result["sourceSamples"] = String(history.coverage.sourceSamples)
                    result["lastCommittedAt"] = history.coverage.lastCommittedAt?.timeIntervalSince1970
                    result["events"] = history.events.count
                    if let traffic = history.applications.first(where: { $0.identity.name == "UBHistoryTraffic" }) {
                        result["trafficUpload"] = traffic.totals.upload.map(String.init) ?? "unknown"
                        result["trafficDownload"] = traffic.totals.download.map(String.init) ?? "unknown"
                    }
                } catch { result["queryError"] = String(describing: type(of: error)) }
            }
            let dir = Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent("ProbeReceipts")
            do {
                if !FileManager.default.fileExists(atPath: dir.path) {
                    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
                }
                let data = try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys, .prettyPrinted])
                try data.write(to: dir.appendingPathComponent(tag + ".json"), options: .withoutOverwriting)
            } catch { /* Validation receipt failure is never production success. */ }
            if CommandLine.arguments.contains("--history-quit") { DispatchQueue.main.async { runtime.quit() } }
        }
    }
}
#endif
