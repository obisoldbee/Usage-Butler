#if DEBUG
import AppKit
import SwiftUI
import UsageButlerCore
import UsageButlerUI

/// Opt-in, offline-only regression harness for the actual NetworkPlotView.
/// --validate-network-memory=<existing-output-directory> produces JSONL and a
/// final rendering; it leaves the process alive for a heap summary.
@MainActor
final class NetworkMemoryValidation: ObservableObject {
    private static var active: NetworkMemoryValidation?
    @Published private var tick = 0
    private var renders = 0
    private var window: NSWindow!
    private var timer: Timer?
    private let output: URL
    private let started = Date()
    private let base = Date(timeIntervalSince1970: 1_800_000_000)
    private let updates = 10_000

    private init(output: URL) { self.output = output }

    static func startIfRequested(offline: Bool) -> Bool {
        let prefix = "--validate-network-memory="
        guard let argument = CommandLine.arguments.first(where: { $0.hasPrefix(prefix) }) else { return false }
        guard offline else { return false }
        let output = URL(fileURLWithPath: String(argument.dropFirst(prefix.count)), isDirectory: true)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: output.path, isDirectory: &isDirectory), isDirectory.boolValue else { return false }
        let harness = NetworkMemoryValidation(output: output)
        active = harness
        harness.start()
        return true
    }

    private var duration: TimeInterval { [60.0, 300, 900, 3_600, 7_200][(tick / 1_000) % 5] }
    private var now: Date { base.addingTimeInterval(Double(tick)) }
    private var bound: Double { [1_000.0, 2_000, 5_000][(tick / 250) % 3] }
    private var points: [NetworkChartPoint] {
        NetworkChartDirection.allCases.flatMap { direction in
            (0..<60).compactMap { index in
                // Stable identities for retained source points, new identities
                // for entering points, a real gap, and a visible isolated dot.
                let sequence = tick + index
                let phase = sequence % 60
                guard !(20..<25).contains(phase), !(45..<50).contains(phase) else { return nil }
                let isolated = phase == 44
                let run = sequence / 60 * 4 + (phase < 20 ? 0 : phase < 44 ? 1 : phase == 44 ? 2 : 3)
                return NetworkChartPoint(seriesKey: "\(direction.rawValue)-\(run)", direction: direction,
                    at: now.addingTimeInterval(Double(index - 59) / 60 * duration),
                    value: Double(phase % 11) / 12 * bound * (direction == .upload ? 1 : 100),
                    isIsolated: isolated, sampleID: "probe-\(sequence)")
            }
        }
    }

    private struct Content: View {
        @ObservedObject var harness: NetworkMemoryValidation
        var body: some View {
            VStack(alignment: .leading) {
                Text("离线内存回归 · 演示数据").font(.headline)
                Text("\(harness.tick) 次更新 · \(Int(harness.duration)) 秒范围")
                NetworkPlotMemoryProbeView(now: harness.now, window: harness.duration,
                    points: harness.points, upperBound: harness.bound) { harness.renders += 1 }
            }.padding(20).background(Color(nsColor: .windowBackgroundColor))
        }
    }

    private func start() {
        window = NSWindow(contentRect: NSRect(x: 120, y: 120, width: 540, height: 410),
                          styleMask: [.titled], backing: .buffered, defer: false)
        window.title = "Usage-Butler offline memory regression"
        window.contentView = NSHostingView(rootView: Content(harness: self))
        window.orderFrontRegardless()
        report("start")
        timer = Timer.scheduledTimer(withTimeInterval: 0.02, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.tick += 1
                self.window.contentView?.layoutSubtreeIfNeeded()
                self.window.displayIfNeeded()
                if self.tick % 1_000 == 0 { self.report("sample") }
                if self.tick == self.updates {
                    self.timer?.invalidate()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                        self.capture()
                        self.report("complete")
                    }
                }
            }
        }
    }

    private func report(_ event: String) {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout.size(ofValue: info) / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        let record: [String: Any] = ["event": event, "pid": getpid(), "tick": tick, "renders": renders,
            "elapsed_seconds": Date().timeIntervalSince(started), "task_info_result": result,
            "footprint_bytes": info.phys_footprint, "resident_bytes": info.resident_size,
            "window_seconds": duration, "offline": true]
        let data = try! JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])
        FileHandle.standardOutput.write(data + Data([10]))
    }

    private func capture() {
        guard let view = window.contentView,
              let image = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: image)
        try? image.representation(using: .png, properties: [:])?.write(to: output.appendingPathComponent("native-plot.png"), options: .withoutOverwriting)
    }
}
#endif
