#if DEBUG
import AppKit
import Darwin
import Foundation
import UsageButlerUI

/// Opt-in receipts from the actual live window. Only the dedicated network
/// validation composition can enable this. No synthesis, input injection or
/// production settings. Files remain in the explicitly supplied local run.
@MainActor final class ProcessNetworkValidationRecorder {
    private static var active: ProcessNetworkValidationRecorder?
    private let runtime: AppRuntime
    private let panel: PanelPresentationController
    private let directory: URL
    private let file: FileHandle
    private var timer: Timer?
    private var ticks = 0
    private var captured: [String] = []
    private init(runtime: AppRuntime, panel: PanelPresentationController, directory: URL, file: FileHandle) {
        self.runtime = runtime; self.panel = panel; self.directory = directory; self.file = file
    }
    static func start(runtime: AppRuntime, panel: PanelPresentationController) {
        let prefix = "--network-validation-records="
        guard runtime.launchMode == .networkValidation,
              let argument = CommandLine.arguments.first(where: { $0.hasPrefix(prefix) }) else { return }
        let dir = URL(fileURLWithPath: String(argument.dropFirst(prefix.count)), isDirectory: true)
        let path = dir.appendingPathComponent("native-runtime.jsonl")
        guard FileManager.default.fileExists(atPath: dir.path),
              (try? Data().write(to: path, options: .withoutOverwriting)) != nil,
              let file = try? FileHandle(forWritingTo: path) else { return }
        let recorder = ProcessNetworkValidationRecorder(runtime: runtime, panel: panel, directory: dir, file: file)
        active = recorder
        recorder.timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak recorder] _ in
            MainActor.assumeIsolated { recorder?.sample() }
        }
    }
    private func sample() {
        ticks += 1
        guard ticks <= 1_800 else { timer?.invalidate(); try? file.close(); return }
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout.size(ofValue: info) / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        let snapshot = runtime.menuModel.processNetwork.snapshot
        // No directory enumeration on the main thread. A fixed, bounded
        // cadence captures the actual window without scanning user folders.
        if ticks % 5 == 0, captured.count < 128,
           let view = panel.validationContentView,
           let image = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
            let tag = "capture-\(ticks)"
            view.cacheDisplay(in: view.bounds, to: image)
            if let data = image.representation(using: .png, properties: [:]),
               (try? data.write(to: directory.appendingPathComponent(tag + ".png"), options: .withoutOverwriting)) != nil {
                captured.append(tag)
            }
        }
        let record: [String: Any] = ["pid": getpid(), "bundle": Bundle.main.bundleURL.path,
            "executable": Bundle.main.executableURL?.path ?? "", "at": ISO8601DateFormatter().string(from: Date()),
            "mode": "network-only-live", "tick": ticks, "taskInfoResult": result,
            "footprint": String(info.phys_footprint), "resident": String(info.resident_size),
            "state": snapshot?.state.rawValue ?? "none", "sequence": snapshot.map { String($0.sequence) } ?? "",
            "apps": snapshot?.applications.count ?? 0, "historyPoints": snapshot?.historyPointCount ?? 0,
            "search": runtime.menuModel.processNetwork.search, "sort": runtime.menuModel.processNetwork.sort.rawValue,
            "selected": runtime.menuModel.processNetwork.selected ?? "", "screenshots": captured.sorted()]
        if let data = try? JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]) {
            try? file.write(contentsOf: data + Data([10]))
        }
    }
}
#endif
