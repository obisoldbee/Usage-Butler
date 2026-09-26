import Darwin
import Foundation
import UsageButlerCore
import UsageButlerDomain

@main struct ProcessNetworkStress {
    static func main() {
        let count = Int(CommandLine.arguments.dropFirst().first ?? "10000")!
        let id = CaptureSessionID(rawValue: "synthetic-resource-stress")
        var collector = ProcessNetworkAggregator(sessionID: id)
        var durations: [Double] = []
        for tick in 1...count {
            let start = DispatchTime.now().uptimeNanoseconds
            let rows = (0..<256).map { index -> ProcessNetworkCounter in
                let app = ProcessNetworkApplicationIdentity(key: "app-\(index)", name: "Synthetic \(index)", evidence: .executable)
                return .init(identity: .init(pid: Int32(index + 1), instanceID: "\(index):\(tick / 400)",
                    name: "Synthetic", executablePath: nil, application: app),
                    bytes: .init(upload: tick % 37 == 0 ? nil : UInt64(tick * 100 + index),
                                 download: UInt64(tick * 200 + index)))
            }
            collector.apply(.init(envelope: .init(sessionID: id, sequence: UInt64(tick),
                occurredAt: Date(timeIntervalSince1970: 1_700_000_000 + Double(tick)),
                monotonicOccurredAt: .init(nanoseconds: UInt64(tick) * 1_000_000_000)),
                processes: rows, complete: tick % 97 != 0))
            let snapshot = collector.snapshot()
            precondition(snapshot.applications.count <= 256 && snapshot.historyPointCount <= 65_536)
            durations.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6)
            if tick % 500 == 0 || tick == count {
                var info = task_vm_info_data_t()
                var size = mach_msg_type_number_t(MemoryLayout.size(ofValue: info) / MemoryLayout<integer_t>.size)
                let result = withUnsafeMutablePointer(to: &info) {
                    $0.withMemoryRebound(to: integer_t.self, capacity: Int(size)) {
                        task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &size)
                    }
                }
                let sorted = durations.sorted()
                let data = try! JSONSerialization.data(withJSONObject: [
                    "tick": tick, "apps": snapshot.applications.count, "historyPoints": snapshot.historyPointCount,
                    "footprint": String(info.phys_footprint), "resident": String(info.resident_size),
                    "taskInfoResult": result, "p50Milliseconds": sorted[sorted.count / 2],
                    "p95Milliseconds": sorted[Int(Double(sorted.count - 1) * 0.95)],
                    "maxMilliseconds": sorted.last!, "synthetic": true,
                    "measurement": "source settlement and snapshot only; not system rendering"], options: [.sortedKeys])
                FileHandle.standardOutput.write(data + Data([10]))
            }
        }
    }
}
