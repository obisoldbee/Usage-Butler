import AppKit
import SwiftUI
import UsageButlerUI

@MainActor
final class UsageButlerAppDelegate: NSObject, NSApplicationDelegate {
    weak var runtime: AppRuntime?
    private var terminationDeadlineTask: Task<Void, Never>?
    private var hasRepliedToTermination = false
    private var panelController: PanelPresentationController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard let runtime else { return }
        let controller = PanelPresentationController(runtime: runtime)
        runtime.panelController = controller
        panelController = controller
    }

    func applicationShouldTerminate(
        _ sender: NSApplication
    ) -> NSApplication.TerminateReply {
        guard let runtime else { return .terminateNow }
        guard !runtime.shutdownComplete else { return .terminateNow }
        guard !hasRepliedToTermination else { return .terminateNow }
        guard terminationDeadlineTask == nil else { return .terminateLater }

        runtime.prepareForTermination { [weak self, weak sender] in
            guard let self, let sender else { return }
            replyToTerminationOnce(sender)
        }
        terminationDeadlineTask = Task { @MainActor [weak self, weak sender] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled, let self, let sender else { return }
            replyToTerminationOnce(sender)
        }
        return .terminateLater
    }

    private func replyToTerminationOnce(_ sender: NSApplication) {
        guard !hasRepliedToTermination else { return }
        hasRepliedToTermination = true
        terminationDeadlineTask?.cancel()
        terminationDeadlineTask = nil
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
