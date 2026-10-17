import AppKit
import Combine

/// A hotkey opening a transient popover must behave like a menu-bar click.
/// Watches only while visible, without polling or accessibility permissions.
@MainActor
final class TransientPanelDismissal {
    private let panelWindow: () -> NSWindow?
    private let anchorWindow: () -> NSWindow?
    private let close: () -> Void
    private var localMonitor: Any?
    private var globalMonitor: Any?
    private var resignation: AnyCancellable?
    private(set) var watching = false

    init(panelWindow: @escaping () -> NSWindow?, anchorWindow: @escaping () -> NSWindow?, close: @escaping () -> Void) {
        self.panelWindow = panelWindow; self.anchorWindow = anchorWindow; self.close = close
    }
    func start() {
        guard !watching else { return }
        watching = true
        let mask: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            self?.pointerDown(in: event.window)
            return event
        }
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] _ in
            self?.applicationResigned()
        }
        resignation = NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)
            .sink { [weak self] _ in self?.applicationResigned() }
    }
    func stop() {
        watching = false
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        localMonitor = nil; globalMonitor = nil; resignation = nil
    }
    func pointerDown(in window: NSWindow?) {
        guard watching else { return }
        if let window {
            if window === anchorWindow() { return } // status-item toggle owns this click
            if let panel = panelWindow(), window === panel || window.parent === panel || window.sheetParent === panel { return }
        }
        close()
    }
    func applicationResigned() { if watching { close() } }
}
