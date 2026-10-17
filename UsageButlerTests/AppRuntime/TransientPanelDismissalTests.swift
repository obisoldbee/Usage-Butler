import AppKit
import XCTest

@MainActor final class TransientPanelDismissalTests: XCTestCase {
    func testOutsideClickClosesButPanelAnchorAndAttachedSheetDoNot() {
        let panel = NSWindow(), anchor = NSWindow(), sheet = NSWindow(), other = NSWindow()
        panel.addChildWindow(sheet, ordered: .above)
        var closes = 0
        let dismissal = TransientPanelDismissal(panelWindow: { panel }, anchorWindow: { anchor }, close: { closes += 1 })
        dismissal.start()
        dismissal.pointerDown(in: panel); dismissal.pointerDown(in: anchor); dismissal.pointerDown(in: sheet)
        XCTAssertEqual(closes, 0)
        dismissal.pointerDown(in: other)
        XCTAssertEqual(closes, 1)
        dismissal.stop()
        dismissal.pointerDown(in: other); dismissal.applicationResigned()
        XCTAssertEqual(closes, 1)
        panel.removeChildWindow(sheet)
    }
    func testResigningApplicationDismissesAndWatchesOnlyWhileVisible() {
        var closes = 0
        let dismissal = TransientPanelDismissal(panelWindow: { nil }, anchorWindow: { nil }, close: { closes += 1 })
        dismissal.start(); dismissal.start()
        NotificationCenter.default.post(name: NSApplication.didResignActiveNotification, object: NSApp)
        XCTAssertEqual(closes, 1)
        dismissal.stop()
        NotificationCenter.default.post(name: NSApplication.didResignActiveNotification, object: NSApp)
        XCTAssertEqual(closes, 1)
        XCTAssertFalse(dismissal.watching)
    }
}
