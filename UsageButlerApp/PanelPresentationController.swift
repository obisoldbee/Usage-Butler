import AppKit
import Carbon.HIToolbox
import SwiftUI
import UsageButlerCore
import UsageButlerUI

/// Owns the menu-bar presence: the status item, the popover panel, the
/// recorded global hotkey, and the in-panel Tab page cycling. Replaces the
/// former `MenuBarExtra` shell, which could not be opened programmatically.
@MainActor
final class PanelPresentationController: NSObject, NSPopoverDelegate {
    private let runtime: AppRuntime
    private let statusItem: NSStatusItem
    private let popover = NSPopover()
    private var hotKeyRef: EventHotKeyRef?
    private var carbonEventHandler: EventHandlerRef?
    private var keyDownMonitor: Any?

    private static let hotKeySignature = OSType(0x5542_686B) // "UBhk"
    private static let hotKeyID: UInt32 = 1

    private final class HotkeyBox: @unchecked Sendable {
        var onTrigger: (@Sendable () -> Void)?
    }

    private static let hotkeyBox = HotkeyBox()

    init(runtime: AppRuntime) {
        self.runtime = runtime
        statusItem = NSStatusBar.system.statusItem(
            withLength: NSStatusItem.squareLength
        )
        super.init()

        let icon = NSImage(named: "MenuBarIcon")
        icon?.isTemplate = true
        statusItem.button?.image = icon
        statusItem.button?.imageScaling = .scaleProportionallyUpOrDown
        statusItem.button?.target = self
        statusItem.button?.action = #selector(togglePanel)

        popover.behavior = .transient
        popover.contentSize = NSSize(width: 540, height: 760)
        popover.contentViewController = NSHostingController(
            rootView: PanelRootView(runtime: runtime)
        )
        popover.delegate = self

        let monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) {
            [weak self] event in
            self?.handlePanelKeyDown(event) ?? event
        }
        keyDownMonitor = monitor

        registerStoredShortcut()
    }

    // MARK: - Panel

    @objc func togglePanel() {
        if popover.isShown {
            popover.performClose(nil)
        } else if let button = statusItem.button {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    func popoverDidClose(_ notification: Notification) {
        runtime.setPanelVisible(false)
    }

    func popoverDidShow(_ notification: Notification) {
        runtime.setPanelVisible(true)
    }

    /// Tab (no modifiers) cycles 额度/内存 while the panel window is key.
    private nonisolated func handlePanelKeyDown(_ event: NSEvent) -> NSEvent? {
        guard event.keyCode == 48,
              event.modifierFlags
                  .intersection(.deviceIndependentFlagsMask)
                  .subtracting(.capsLock)
                  .isEmpty,
              event.window === panelWindowRef
        else {
            return event
        }
        Task { @MainActor in
            runtime.menuModel.cyclePage()
        }
        return nil
    }

    private nonisolated var panelWindowRef: NSWindow? {
        MainActor.assumeIsolated {
            popover.contentViewController?.view.window
        }
    }

    // MARK: - Global hotkey

    func applyShortcut(_ shortcut: GlobalShortcut?) {
        unregisterHotkey()
        guard let shortcut else {
            Self.hotkeyBox.onTrigger = nil
            return
        }

        installCarbonHandlerIfNeeded()
        Self.hotkeyBox.onTrigger = { [weak self] in
            Task { @MainActor in
                self?.togglePanel()
            }
        }

        var reference: EventHotKeyRef?
        let status = RegisterEventHotKey(
            shortcut.keyCode,
            shortcut.carbonModifiers,
            EventHotKeyID(
                signature: Self.hotKeySignature,
                id: Self.hotKeyID
            ),
            GetApplicationEventTarget(),
            0,
            &reference
        )
        if status == noErr {
            hotKeyRef = reference
        }
    }

    private func registerStoredShortcut() {
        let stored = UserDefaults.standard.string(
            forKey: ProviderPreferenceKey.globalShortcut
        )
        applyShortcut(stored.flatMap(GlobalShortcut.init(serialized:)))
    }

    private func unregisterHotkey() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
        }
        hotKeyRef = nil
    }

    private func installCarbonHandlerIfNeeded() {
        guard carbonEventHandler == nil else { return }

        var eventSpec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, _, userData in
                guard let userData else { return noErr }
                let box = Unmanaged<HotkeyBox>.fromOpaque(userData)
                    .takeUnretainedValue()
                box.onTrigger?()
                return noErr
            },
            1,
            &eventSpec,
            Unmanaged.passUnretained(Self.hotkeyBox).toOpaque(),
            &carbonEventHandler
        )
    }
}

private struct PanelRootView: View {
    @ObservedObject var runtime: AppRuntime

    var body: some View {
        MenuPanelRootView(
            model: runtime.menuModel,
            activityMonitorState: runtime.activityMonitorState,
            onOpenActivityMonitor: runtime.openActivityMonitor,
            onOpenSettingsFallback: runtime.openSettingsFallback
        )
    }
}
