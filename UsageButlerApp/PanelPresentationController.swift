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
    #if DEBUG
    private var validationAnchor: NSWindow?
    private var validationWindow: NSWindow?
    #endif
    private let panelSizing = MenuPanelSizing()
    private var sizeObservation: AnyCancellable?
    private var screenObservation: AnyCancellable?
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
        #if DEBUG
        if CommandLine.arguments.contains("--show-panel-for-validation") {
            popover.behavior = .applicationDefined
        }
        #endif
        popover.animates = false
        popover.contentSize = NSSize(width: 540, height: panelSizing.height)
        popover.contentViewController = NSHostingController(
            rootView: PanelRootView(runtime: runtime, sizing: panelSizing)
        )
        popover.delegate = self
        sizeObservation = panelSizing.$height.removeDuplicates().sink { [weak self] height in
            self?.popover.contentSize = NSSize(width: 540, height: height)
            #if DEBUG
            self?.validationWindow?.setContentSize(NSSize(width: 540, height: height))
            if CommandLine.arguments.contains("--show-panel-for-validation") {
                NSLog("panel_validation content_width=540 content_height=%.0f", Double(height))
            }
            #endif
        }
        screenObservation = NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .sink { [weak self] _ in self?.updateAvailableHeight() }
        updateAvailableHeight()

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

    #if DEBUG
    /// The live panel view, for the Debug acceptance harness that renders what
    /// the user would see. Screen recording of another process is not always
    /// available, and a design mock is not evidence about this window.
    var validationContentView: NSView? { validationWindow?.contentView ?? popover.contentViewController?.view }
    var validationIsShown: Bool { validationWindow?.isVisible ?? popover.isShown }
    #endif

    @objc func togglePanel() {
        #if DEBUG
        if CommandLine.arguments.contains("--network-v2-window"), runtime.launchMode == .offlineFixture {
            if validationWindow == nil {
                let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 540, height: panelSizing.height),
                    styleMask: [.titled, .closable], backing: .buffered, defer: false)
                window.title = "Usage-Butler Network Validation"
                window.isReleasedWhenClosed = false
                window.contentViewController = NSHostingController(rootView: PanelRootView(runtime: runtime, sizing: panelSizing))
                window.center()
                validationWindow = window
            }
            validationWindow?.makeKeyAndOrderFront(nil)
            runtime.setPanelVisible(true)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        if CommandLine.arguments.contains("--show-panel-for-validation") {
            NSLog("panel_validation toggle shown=%d button=%d window=%d", popover.isShown ? 1 : 0, statusItem.button != nil ? 1 : 0, statusItem.button?.window != nil ? 1 : 0)
        }
        #endif
        if popover.isShown {
            popover.performClose(nil)
        } else if let button = statusItem.button {
            updateAvailableHeight()
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            #if DEBUG
            if CommandLine.arguments.contains("--show-panel-for-validation"), !popover.isShown,
               let screen = button.window?.screen ?? NSScreen.main {
                // A crowded menu bar can hide the status-item anchor. Keep the same
                // popover/content measurement but supply a visible test-only anchor.
                let anchor = NSWindow(contentRect: NSRect(x: screen.visibleFrame.maxX - 600,
                    y: screen.visibleFrame.maxY - 40, width: 80, height: 24),
                    styleMask: [.borderless], backing: .buffered, defer: false)
                anchor.title = "Usage-Butler Layout Validation"
                anchor.orderFrontRegardless()
                validationAnchor = anchor
                if let view = anchor.contentView {
                    popover.show(relativeTo: view.bounds, of: view, preferredEdge: .minY)
                }
                NSLog("panel_validation alternate_anchor shown=%d", popover.isShown ? 1 : 0)
            }
            #endif
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    private func updateAvailableHeight() {
        guard let screen = statusItem.button?.window?.screen ?? NSScreen.main else { return }
        panelSizing.setMaximumHeight(max(80, screen.visibleFrame.height - 24))
    }

    func popoverDidClose(_ notification: Notification) {
        runtime.setPanelVisible(false)
    }

    func popoverDidShow(_ notification: Notification) {
        #if DEBUG
        if CommandLine.arguments.contains("--show-panel-for-validation") {
            NSLog("panel_validation shown width=%.0f height=%.0f", popover.contentSize.width, popover.contentSize.height)
        }
        #endif
        runtime.setPanelVisible(true)
    }

    /// Tab (no modifiers) cycles the panel pages while the panel window is key.
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
        if MainActor.assumeIsolated({ runtime.menuModel.selectedPage == .network }) { return event }
        // Inside a text field or menu the key belongs to focus traversal.
        if PanelTabRouting.belongsToFocusedControl(in: event.window) {
            return event
        }
        Task { @MainActor in
            runtime.menuModel.cyclePage()
        }
        return nil
    }

    private nonisolated var panelWindowRef: NSWindow? {
        MainActor.assumeIsolated {
            #if DEBUG
            if let validationWindow { return validationWindow }
            #endif
            return popover.contentViewController?.view.window
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
    let sizing: MenuPanelSizing

    var body: some View {
        MenuPanelRootView(
            model: runtime.menuModel,
            activityMonitorState: runtime.activityMonitorState,
            onOpenActivityMonitor: runtime.openActivityMonitor,
            onOpenSettingsFallback: runtime.openSettingsFallback,
            sizing: sizing
        )
    }
}
