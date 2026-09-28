import AppKit
import SwiftUI
import UsageButlerUI
#if USAGE_BUTLER_FIXTURES
import UsageButlerCore
#endif

@MainActor
final class UsageButlerAppDelegate: NSObject, NSApplicationDelegate {
    weak var runtime: AppRuntime?
    private var terminationDeadline: Timer?
    private var hasRepliedToTermination = false
    private var panelController: PanelPresentationController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        #if DEBUG
        if CommandLine.arguments.contains("--show-panel-for-validation") {
            NSLog("panel_validation app_did_finish runtime=%d", runtime != nil ? 1 : 0)
        }
        #endif
        guard let runtime else { return }
        runtime.prepareLegacySettingsOpening()
        let controller = PanelPresentationController(runtime: runtime)
        runtime.panelController = controller
        panelController = controller
        #if DEBUG
        if NetworkMemoryValidation.startIfRequested(offline: runtime.launchMode == .offlineFixture) { return }
        if CommandLine.arguments.contains("--show-panel-for-validation") {
            DispatchQueue.main.async { controller.togglePanel() }
        }
        if CommandLine.arguments.contains("--network-v2-preview"), runtime.launchMode == .offlineFixture {
            runtime.menuModel.selectedPage = .network
            runtime.menuModel.networkTrendRange = .oneMinute
            if CommandLine.arguments.contains("--network-v2-dark") {
                NSApp.appearance = NSAppearance(named: .darkAqua)
            }
        }
        #if USAGE_BUTLER_FIXTURES
        if CommandLine.arguments.contains("--network-zero-preview"), runtime.launchMode == .offlineFixture {
            runtime.menuModel.applyNetworkSnapshot(NetworkFixtureCatalog.snapshot(zeroRates: true))
            runtime.menuModel.networkObservationSelection = "en0"
        }
        #endif
        NetworkCurveValidation.startIfRequested(runtime: runtime, panel: controller)
        ProcessNetworkValidationRecorder.start(runtime: runtime, panel: controller)
        BackgroundHistoryValidation.start(runtime: runtime)
        #endif
    }

    func applicationWillTerminate(_ notification: Notification) {
        panelController?.stopShortcuts()
        runtime?.settingsPresentation.invalidate()
    }

    func applicationShouldTerminate(
        _ sender: NSApplication
    ) -> NSApplication.TerminateReply {
        guard let runtime else { return .terminateNow }
        guard !runtime.shutdownComplete, !runtime.terminationDrainTimedOut else { return .terminateNow }
        guard !hasRepliedToTermination else { return .terminateNow }
        guard terminationDeadline == nil else { return .terminateLater }

        runtime.prepareForTermination { [weak self, weak sender] in
            guard let self, let sender else { return }
            replyToTerminationOnce(sender)
        }
        // Run-loop timer also fires inside AppKit's nested termination loop;
        // the main dispatch queue itself cannot be re-entered from that loop.
        let deadline = Timer(timeInterval: 2, repeats: false) { [weak self, weak sender] _ in
            MainActor.assumeIsolated {
                guard let self, let sender else { return }
                self.replyToTerminationOnce(sender)
            }
        }
        terminationDeadline = deadline
        RunLoop.main.add(deadline, forMode: .common)
        return .terminateLater
    }

    private func replyToTerminationOnce(_ sender: NSApplication) {
        guard !hasRepliedToTermination else { return }
        hasRepliedToTermination = true
        terminationDeadline?.invalidate()
        terminationDeadline = nil
        sender.reply(toApplicationShouldTerminate: true)
    }
}

@main
struct UsageButlerApp: App {
    @NSApplicationDelegateAdaptor(UsageButlerAppDelegate.self)
    private var appDelegate
    @StateObject private var runtime: AppRuntime

    init() {
        let runtime = AppRuntime()
        _runtime = StateObject(wrappedValue: runtime)
        appDelegate.runtime = runtime
    }

    var body: some Scene {
        UsageButlerSettingsScene(runtime: runtime)
    }
}

/// Capture the action when the application scene graph is built, independently
/// of the lazily-created Settings content and the never-yet-opened panel.
private struct UsageButlerSettingsScene: Scene {
    @Environment(\.self) private var environment
    let runtime: AppRuntime

    private func prepareSettingsOpening() {
        if #available(macOS 14.0, *) {
            let action = environment.openSettings
            runtime.settingsPresentation.install { action(); return true }
        }
    }

    var body: some Scene {
        let _ = prepareSettingsOpening()
        Settings {
            SettingsRootView(
                model: runtime.menuModel,
                onQuit: runtime.quit
            )
            .background(SettingsWindowRegistration(bridge: runtime.settingsPresentation))
        }
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button("打开设置…") { runtime.openSettingsFallback() }
                    .keyboardShortcut(",", modifiers: [.command, .shift])
            }
            CommandMenu("额度管家") {
                Button("刷新") {
                    runtime.menuModel.requestManualRefresh()
                }
                .keyboardShortcut("r", modifiers: .command)

                Button("显示面板") {
                    runtime.panelController?.togglePanel()
                }
                .keyboardShortcut("p", modifiers: [.command, .shift])
            }

            CommandGroup(replacing: .appTermination) {
                Button("退出主程序（后台按设置继续）") {
                    runtime.quit()
                }
                .keyboardShortcut("q", modifiers: .command)
            }
        }
    }
}
