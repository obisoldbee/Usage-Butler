import AppKit

/// Decides whether a bare Tab belongs to the focused control or to page
/// cycling.
///
/// PRD 0.20 §13.3 requires search fields, rule inputs and dialogs to keep
/// standard Tab focus traversal, while the panel's own shortcut must keep
/// working when nothing is being edited. The SwiftUI host view is deliberately
/// not treated as a control: it holds focus for the whole panel, so counting it
/// would disable page cycling entirely.
public enum PanelTabRouting {
    public static func belongsToFocusedControl(in window: NSWindow?) -> Bool {
        guard let window else { return false }
        let responder = window.firstResponder
        if responder == nil || responder === window || responder === window.contentView {
            return false
        }
        if responder is NSTextView || responder is NSControl || responder is NSCell {
            return true
        }
        guard let view = responder as? NSView else { return false }
        return isHosting(view) ? false : view.acceptsFirstResponder
    }

    /// NSHostingView is generic, so a specific specialization cannot be named;
    /// walk the class chain by name instead.
    private static func isHosting(_ view: NSView) -> Bool {
        var cursor: AnyClass? = type(of: view)
        while let current = cursor {
            if String(cString: class_getName(current)).contains("Hosting") { return true }
            cursor = class_getSuperclass(current)
        }
        return false
    }
}
