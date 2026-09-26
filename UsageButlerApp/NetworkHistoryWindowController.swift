import AppKit
import SwiftUI
import UsageButlerUI

/// macOS 13 bridge: the window is created only by the explicit history action,
/// and released on close. SwiftUI owns all query/selection state.
@MainActor
final class NetworkHistoryWindowController: NSObject, NSWindowDelegate {
    private let model: BackgroundNetworkViewModel
    private var window: NSWindow?
    init(model: BackgroundNetworkViewModel) { self.model = model }
    func show() {
        if let window { window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); return }
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1000, height: 800)
        let size = NSSize(width: min(900, screen.width * 0.9), height: min(760, screen.height * 0.9))
        let created = NSWindow(contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        created.title = "应用网络历史 — 额度管家"; created.identifier = .init("UsageButlerNetworkHistory")
        created.contentMinSize = NSSize(width: 560, height: 420)
        created.isReleasedWhenClosed = false; created.delegate = self
        created.contentView = NSHostingView(rootView: NetworkHistoryWindowRootView(model: model))
        created.center(); window = created; created.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }
    func windowWillClose(_ notification: Notification) {
        model.closeHistory(); window?.contentView = nil; window?.delegate = nil; window = nil
    }
    func close() { window?.close(); model.closeHistory() }
}
