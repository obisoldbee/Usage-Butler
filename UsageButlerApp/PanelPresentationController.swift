import AppKit
import Carbon.HIToolbox
import Combine
import SwiftUI
import UsageButlerCore
import UsageButlerDomain
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
    private var memoryObservation: AnyCancellable?
    private var appearanceObservation: NSKeyValueObservation?
    private var memoryExpiryTask: Task<Void, Never>?
    private var displayedPressure: MemoryPressureState = .unknown
    private var renderedPressure: MemoryPressureState?
    private var renderedDark: Bool?

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

        statusItem.button?.imageScaling = .scaleProportionallyUpOrDown
        statusItem.button?.target = self
        statusItem.button?.action = #selector(togglePanel)
        observeMemoryStatus()

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

    // Reuse the runtime stream: no new memory reader or polling loop.
    private func observeMemoryStatus() {
        memoryObservation = runtime.menuModel.$snapshot
            .map(\.memory)
            .removeDuplicates { lhs, rhs in
                lhs.capturedAt == rhs.capturedAt && lhs.pressure == rhs.pressure
            }
            .sink { [weak self] snapshot in
                self?.receiveMemory(snapshot)
            }
        appearanceObservation = statusItem.button?.observe(
            \.effectiveAppearance, options: [.new]
        ) { [weak self] _, _ in
            Task { @MainActor [weak self] in self?.renderMemoryStatus() }
        }
    }

    private func receiveMemory(_ snapshot: Stage3MemoryProjection) {
        memoryExpiryTask?.cancel()
        let now = Date()
        displayedPressure = MemoryStatusIcon.pressure(for: snapshot, now: now)
        renderMemoryStatus()
        guard displayedPressure != .unknown else { return }
        let remaining = snapshot.capturedAt.addingTimeInterval(
            MemoryStatusIcon.maximumAge
        ).timeIntervalSince(now)
        memoryExpiryTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .seconds(remaining)) }
            catch { return }
            guard !Task.isCancelled else { return }
            self?.displayedPressure = .unknown
            self?.renderMemoryStatus()
        }
    }

    private func renderMemoryStatus() {
        guard let button = statusItem.button else { return }
        let dark = button.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        guard renderedPressure != displayedPressure || renderedDark != dark else { return }
        renderedPressure = displayedPressure
        renderedDark = dark
        button.image = MemoryStatusIcon.image(for: displayedPressure, dark: dark)
        let label = MemoryStatusIcon.label(for: displayedPressure)
        button.toolTip = label
        button.setAccessibilityLabel("额度管家，\(label)")
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
