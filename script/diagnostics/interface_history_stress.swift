import Darwin
import Foundation
import UsageButlerCore
import UsageButlerDomain

/// Full retained-history workload through the shipping batch aggregator.
/// Synthetic source data; measures aggregation/publication, not rendering.
@main struct InterfaceHistoryStress {
    static func main() {
        let id = CaptureSessionID(rawValue: "synthetic-interface-stress")
        func source(_ name: String, _ tick: UInt64) -> InterfaceCounters {
            .init(name: name, kind: .physical, counters: .init(bytes: .init(upload: tick * 100, download: tick * 200),
                semantics: .cumulativeSinceEpoch, epoch: .init(rawValue: 1)),
                asOf: Date(timeIntervalSince1970: Double(tick)), monotonicAsOf: .init(nanoseconds: tick * 1_000_000_000), samplingInterval: 1)
        }
        var histories: [String: [NetworkRateSample]] = [:]
        var interfaces: [String: InterfaceCounters] = [:]
        for index in 0..<64 {
            let name = "synthetic-\(index)"
            interfaces[name] = source(name, 7_200)
            histories[name] = (1...7_200).map { tick in
                .init(captureSessionID: id, counterEpoch: .init(rawValue: 1),
                    sampledAt: Date(timeIntervalSince1970: Double(tick)),
                    sampledMonotonic: .init(nanoseconds: UInt64(tick) * 1_000_000_000),
                    uploadBytesPerSecond: 100, downloadBytesPerSecond: 200,
                    interfaceName: name, samplingInterval: 1)
            }
        }
        var aggregator = NetworkAggregator(sessionID: id, retainedInterfaces: interfaces, retainedHistory: histories)
        histories.removeAll(); interfaces.removeAll()
        var durations: [Double] = []
        for sequence in 1...1_000 {
            let start = DispatchTime.now().uptimeNanoseconds, tick = UInt64(7_200 + sequence)
            let envelope = NetworkEventEnvelope(sessionID: id, sequence: UInt64(sequence), occurredAt: Date(timeIntervalSince1970: Double(tick)),
                monotonicOccurredAt: .init(nanoseconds: tick * 1_000_000_000))
            aggregator.apply(.init(envelope: envelope, payload: .interfaceEnumeration(.complete((0..<64).map { source("synthetic-\($0)", tick) }))))
            let snapshot = aggregator.snapshot(asOf: envelope.occurredAt, monotonicAsOf: envelope.monotonicOccurredAt, collectionState: .active)
            let count = snapshot.rateHistory?.values.reduce(0) { $0 + $1.count } ?? 0
            precondition(count <= 64 * 7_200 && count > 400_000)
            durations.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6)
            if sequence % 100 == 0 {
                var info = task_vm_info_data_t()
                var size = mach_msg_type_number_t(MemoryLayout.size(ofValue: info) / MemoryLayout<integer_t>.size)
                let result = withUnsafeMutablePointer(to: &info) {
                    $0.withMemoryRebound(to: integer_t.self, capacity: Int(size)) {
                        task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &size)
                    }
                }
                let sorted = durations.sorted()
                let record: [String: Any] = ["tick": sequence, "interfaces": 64, "historyPoints": count,
                    "footprint": String(info.phys_footprint), "resident": String(info.resident_size), "taskInfoResult": result,
                    "p50Milliseconds": sorted[sorted.count / 2], "p95Milliseconds": sorted[Int(Double(sorted.count - 1) * 0.95)],
                    "maxMilliseconds": sorted.last!, "synthetic": true, "measurement": "full source batch and snapshot; not rendering"]
                FileHandle.standardOutput.write(try! JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]) + Data([10]))
            }
        }
        precondition(aggregator.expireHistory(at: .init(nanoseconds: 15_401_000_000_000)))
        let stopped = aggregator.snapshot(asOf: Date(), monotonicAsOf: .init(nanoseconds: 15_401_000_000_000), collectionState: .stopped)
        precondition(stopped.rateHistory?.values.allSatisfy(\.isEmpty) == true)
    }
}
