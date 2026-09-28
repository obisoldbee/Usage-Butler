import AppKit
import SwiftUI

@MainActor
protocol SettingsWindowPresenting: AnyObject {
    var hasSettingsContent: Bool { get }
    func bringSettingsForward()
}

extension NSWindow: SettingsWindowPresenting {
    var hasSettingsContent: Bool { contentView != nil }
    func bringSettingsForward() {
        if isMiniaturized { deminiaturize(nil) }
        makeKeyAndOrderFront(nil)
    }
}

/// The action comes from the application scene graph at startup, not from the
/// lazily-created Settings content. No polling or synthesized keyboard events.
@MainActor
final class SettingsPresentationBridge {
    enum RequestResult: Equatable { case scheduled, coalesced, waitingForScene }
    private let activate: () -> Void
    private let enqueue: (@escaping @MainActor () -> Void) -> Void
    private let report: (String?) -> Void
    private var openScene: (() -> Bool)?
    private weak var window: (any SettingsWindowPresenting)?
    private var requested = false
    private var scheduled = false
    private var generation = 0

    init(activate: @escaping () -> Void = { NSApp.activate(ignoringOtherApps: true) },
         enqueue: @escaping (@escaping @MainActor () -> Void) -> Void = { action in DispatchQueue.main.async { action() } },
         report: @escaping (String?) -> Void) {
        self.activate = activate; self.enqueue = enqueue; self.report = report
    }

    func install(_ action: @escaping () -> Bool) {
        // Assignment does not publish view state or open a window during body
        // evaluation. An early hotkey request is drained on the next main turn.
        openScene = action
        if requested { scheduleIfReady() }
    }

    func track(_ window: any SettingsWindowPresenting) { self.window = window }

    @discardableResult
    func requestOpen() -> RequestResult {
        let wasPending = requested
        requested = true
        guard openScene != nil || window?.hasSettingsContent == true else {
            report("设置入口尚未就绪，已保留打开请求；场景就绪后执行。")
            return .waitingForScene
        }
        scheduleIfReady()
        return wasPending ? .coalesced : .scheduled
    }

    func invalidate() { generation += 1; requested = false; scheduled = false; openScene = nil; window = nil }

    private func scheduleIfReady() {
        guard !scheduled else { return }
        scheduled = true
        let token = generation
        enqueue { [weak self] in
            guard let self, self.generation == token else { return }
            self.scheduled = false
            guard self.requested else { return }
            self.requested = false
            self.activate()
            if let window = self.window, window.hasSettingsContent {
                window.bringSettingsForward(); self.report(nil)
            } else if self.openScene?() == true {
                // This is an opening request, not a claim of native visibility.
                self.report(nil)
            } else { self.report("无法打开设置：设置场景动作当前不可用。") }
        }
    }
}

/// Tracks the actual Settings Scene's window solely for idempotent foregrounding.
/// This view does not provide the initial openSettings action.
struct SettingsWindowRegistration: NSViewRepresentable {
    let bridge: SettingsPresentationBridge
    func makeNSView(context: Context) -> RegistrationView { RegistrationView(bridge: bridge) }
    func updateNSView(_ view: RegistrationView, context: Context) {}

    final class RegistrationView: NSView {
        let bridge: SettingsPresentationBridge
        init(bridge: SettingsPresentationBridge) { self.bridge = bridge; super.init(frame: .zero) }
        required init?(coder: NSCoder) { nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window {
                window.identifier = NSUserInterfaceItemIdentifier("io.github.obisoldbee.UsageButler.settings")
                bridge.track(window)
            }
        }
    }
}
