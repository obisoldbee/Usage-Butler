import Foundation
import UsageButlerCore
import UsageButlerDomain
import UsageButlerInfrastructure

/// Runs the shipping source and settlement against one explicitly selected
/// controlled process. No production Provider/runtime/preferences are loaded.
@main struct ProcessNetworkProbe {
    static func emit(_ object: [String: Any]) {
        let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        FileHandle.standardOutput.write(data + Data([10]))
    }
    static func main() async {
        let pid = Int32(CommandLine.arguments[1])!
        let limit = Int(CommandLine.arguments[2])!
        for cycle in 1...2 {
            let session = CaptureSessionID(rawValue: "controlled-source-\(cycle)")
            let source = NettopProcessSource(sessionID: session)
            var aggregator = ProcessNetworkAggregator(sessionID: session)
            var count = 0
            for await frame in source.events() {
                count += 1; aggregator.apply(frame)
                let snapshot = aggregator.snapshot()
                let match = frame.processes.first { $0.identity.pid == pid }
                let app = match.flatMap { snapshot.applications[$0.identity.application.key] }
                let none = NSNull()
                emit(["cycle": cycle, "sequence": String(frame.envelope.sequence),
                      "monotonic": String(frame.envelope.monotonicOccurredAt.nanoseconds),
                      "receivedMonotonic": String(DispatchTime.now().uptimeNanoseconds),
                      "complete": frame.complete, "issue": frame.issue ?? (none as Any),
                      "targetPID": pid, "matched": match != nil,
                      "verifiedStart": match?.identity.instanceID != nil,
                      "application": match?.identity.application.name ?? (none as Any),
                      "evidence": match?.identity.application.evidence.rawValue ?? (none as Any),
                      "upload": match?.bytes.upload.map(String.init) ?? (none as Any),
                      "download": match?.bytes.download.map(String.init) ?? (none as Any),
                      "settledUpload": app?.total.upload.bytes.map(String.init) ?? (none as Any),
                      "settledDownload": app?.total.download.bytes.map(String.init) ?? (none as Any),
                      "uploadRate": app?.rate?.uploadBytesPerSecond ?? (none as Any),
                      "applications": snapshot.applications.count, "historyPoints": snapshot.historyPointCount])
                if count >= (cycle == 1 ? limit : 3) { break }
            }
            let start = DispatchTime.now().uptimeNanoseconds
            await source.stop()
            emit(["cycle": cycle, "stopped": true, "stopMilliseconds": Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6])
        }
    }
}
