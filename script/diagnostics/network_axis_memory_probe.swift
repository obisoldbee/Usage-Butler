// Offline, standalone Swift Charts regression probe. No app runtime, settings,
// collectors, credentials or provider calls. Compile with swiftc -O -parse-as-library.
// Usage: probe date|normalized [updates=3000] [interval=0.02]
import AppKit
import Charts
import SwiftUI
import Darwin

@MainActor
private final class ProbeModel: ObservableObject {
    @Published var tick = 0
    var renders = 0
    let normalized: Bool
    let origin = Date(timeIntervalSince1970: 1_800_000_000)
    init(normalized: Bool) { self.normalized = normalized }
    var now: Date { origin.addingTimeInterval(Double(tick)) }
}

private struct ProbeChart: View {
    @ObservedObject var model: ProbeModel
    let color: Color
    var body: some View {
        let _ = { model.renders += 1 }()
        let now = model.now
        Chart {
            ForEach(0..<60) { i in
                if model.normalized {
                    LineMark(x: .value("Time", Double(i) / 60), y: .value("Rate", Double(i % 9)))
                        .foregroundStyle(color)
                } else {
                    LineMark(x: .value("Time", now.addingTimeInterval(Double(i) - 60)), y: .value("Rate", Double(i % 9)))
                        .foregroundStyle(color)
                }
            }
        }
        .chartYScale(domain: 0...10)
        .chartYAxis {
            AxisMarks(position: .leading, values: [0.0, 5, 10]) { v in
                AxisGridLine()
                AxisValueLabel { Text("\(Int(v.as(Double.self) ?? 0)) B/s").font(.system(size: 9)).frame(width: 74) }
            }
        }
        .modifier(TimeAxis(now: now, normalized: model.normalized))
        .chartLegend(.hidden)
        .frame(height: 140)
        .transaction { $0.animation = nil; $0.disablesAnimations = true }
    }
}

private struct TimeAxis: ViewModifier {
    let now: Date
    let normalized: Bool
    @ViewBuilder func body(content: Content) -> some View {
        if normalized {
            content.chartXScale(domain: 0.0...1.0)
                .chartXAxis {
                    AxisMarks(values: [0.0, 0.5, 1.0]) { value in
                        AxisGridLine()
                        AxisValueLabel {
                            let date = now.addingTimeInterval(((value.as(Double.self) ?? 0) - 1) * 60)
                            Text(date, format: .dateTime.hour().minute())
                        }
                    }
                }
        } else {
            content.chartXScale(domain: now.addingTimeInterval(-60)...now)
                .chartXAxis {
                    AxisMarks(values: [now.addingTimeInterval(-60), now.addingTimeInterval(-30), now]) {
                        AxisGridLine()
                        AxisValueLabel(format: .dateTime.hour().minute(), centered: false)
                    }
                }
        }
    }
}

@main
@MainActor
private final class Probe: NSObject, NSApplicationDelegate {
    static func main() {
        let app = NSApplication.shared
        let delegate = Probe()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) { app.run() }
    }
    private var window: NSWindow!
    private var model: ProbeModel!
    private var timer: Timer?
    private var started = Date()
    func applicationDidFinishLaunching(_ notification: Notification) {
        let args = CommandLine.arguments
        let mode = args.count > 1 ? args[1] : "date"
        let count = args.count > 2 ? Int(args[2]) ?? 3000 : 3000
        let interval = args.count > 3 ? Double(args[3]) ?? 0.02 : 0.02
        model = ProbeModel(normalized: mode == "normalized")
        window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 540, height: 340),
                          styleMask: [.titled], backing: .buffered, defer: false)
        window.title = "Offline axis memory probe — \(mode)"
        window.contentView = NSHostingView(rootView: VStack {
            ProbeChart(model: model, color: .red)
            ProbeChart(model: model, color: .blue)
        }.padding())
        window.orderFrontRegardless()
        report(event: "start")
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self else { timer.invalidate(); return }
                self.model.tick += 1
                self.window.contentView?.layoutSubtreeIfNeeded()
                self.window.displayIfNeeded()
                if self.model.tick % 500 == 0 { self.report(event: "sample") }
                if self.model.tick >= count {
                    timer.invalidate()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) { self.report(event: "complete") }
                }
            }
        }
    }
    private func report(event: String) {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout.size(ofValue: info) / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        let record: [String: Any] = ["event": event, "pid": getpid(), "tick": model.tick,
            "renders": model.renders, "normalized": model.normalized,
            "elapsed_seconds": Date().timeIntervalSince(started), "task_info_result": result,
            "footprint_bytes": info.phys_footprint, "resident_bytes": info.resident_size]
        let data = try! JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])
        FileHandle.standardOutput.write(data + Data([10]))
    }
}
