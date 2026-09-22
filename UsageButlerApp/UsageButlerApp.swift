import AppKit
import SwiftUI
import UsageButlerUI

@MainActor
final class UsageButlerAppDelegate: NSObject, NSApplicationDelegate {
    weak var runtime: AppRuntime?
    private var terminationDeadline: DispatchWorkItem?
    private var hasRepliedToTermination = false
    private var panelController: PanelPresentationController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        #if DEBUG
        if CommandLine.arguments.contains("--show-panel-for-validation") {
            NSLog("panel_validation app_did_finish runtime=%d", runtime != nil ? 1 : 0)
        }
        #endif
        guard let runtime else { return }
        let controller = PanelPresentationController(runtime: runtime)
        runtime.panelController = controller
        panelController = controller
        #if DEBUG
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
        NetworkCurveValidation.startIfRequested(runtime: runtime, panel: controller)
        #endif
    }

    func applicationShouldTerminate(
        _ sender: NSApplication
    ) -> NSApplication.TerminateReply {
        guard let runtime else { return .terminateNow }
        guard !runtime.shutdownComplete else { return .terminateNow }
        guard !hasRepliedToTermination else { return .terminateNow }
        guard terminationDeadline == nil else { return .terminateLater }

        runtime.prepareForTermination { [weak self, weak sender] in
            guard let self, let sender else { return }
            replyToTerminationOnce(sender)
        }
        // A dispatch item rather than a Task. `terminate:` can be reached from
        // inside a main-actor task that has not returned yet; AppKit then spins
        // a nested event loop that keeps running the main queue but never
        // resumes that task, and the deadline — the only guarantee that a reply
        // is ever sent — would sit behind the thing it is meant to escape.
        let deadline = DispatchWorkItem { [weak self, weak sender] in
            MainActor.assumeIsolated {
                guard let self, let sender else { return }
                self.replyToTerminationOnce(sender)
            }
        }
        terminationDeadline = deadline
        DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: deadline)
        return .terminateLater
    }

    private func replyToTerminationOnce(_ sender: NSApplication) {
        guard !hasRepliedToTermination else { return }
        hasRepliedToTermination = true
        terminationDeadline?.cancel()
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
        Settings {
            SettingsRootView(
                model: runtime.menuModel,
                onQuit: runtime.quit
            )
        }
        .commands {
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
                Button("退出额度管家") {
                    runtime.quit()
                }
                .keyboardShortcut("q", modifiers: .command)
            }
        }
    }
}
