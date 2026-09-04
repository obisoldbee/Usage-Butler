import Foundation

/// Modifier flags for a global panel shortcut, stored with the same raw bit
/// values AppKit reports for `NSEvent.ModifierFlags` so the persistence layer
/// stays AppKit-free and unit-testable.
public struct ShortcutModifiers: OptionSet, Hashable, Sendable {
    public let rawValue: UInt

    public init(rawValue: UInt) {
        self.rawValue = rawValue
    }

    public static let shift = ShortcutModifiers(rawValue: 1 << 17)
    public static let control = ShortcutModifiers(rawValue: 1 << 18)
    public static let option = ShortcutModifiers(rawValue: 1 << 19)
    public static let command = ShortcutModifiers(rawValue: 1 << 20)

    public var hasHotkeyModifier: Bool {
        !intersection([.command, .control, .option]).isEmpty
    }
}

/// A persisted global shortcut: key code plus modifiers, with lossless string
/// serialization and a display form. Values come from recorded keyboard
/// events; nothing here performs event interception itself.
public struct GlobalShortcut: Equatable, Hashable, Sendable {
    public let keyCode: UInt32
    public let modifiers: ShortcutModifiers

    public init(keyCode: UInt32, modifiers: ShortcutModifiers) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    public init?(serialized: String) {
        let parts = serialized.split(separator: ":")
        guard parts.count == 3,
              parts[0] == "v1",
              let keyCode = UInt32(parts[1]),
              let rawModifiers = UInt(parts[2]) else {
            return nil
        }
        self.keyCode = keyCode
        self.modifiers = ShortcutModifiers(rawValue: rawModifiers)
    }

    public var serialized: String {
        "v1:\(keyCode):\(modifiers.rawValue)"
    }

    public var displayText: String {
        var modifierText = ""
        if modifiers.contains(.control) { modifierText += "⌃" }
        if modifiers.contains(.option) { modifierText += "⌥" }
        if modifiers.contains(.shift) { modifierText += "⇧" }
        if modifiers.contains(.command) { modifierText += "⌘" }
        return modifierText + Self.keyGlyph(for: keyCode)
    }

    /// Carbon modifier mask for `RegisterEventHotKey`.
    public var carbonModifiers: UInt32 {
        var mask: UInt32 = 0
        if modifiers.contains(.command) { mask |= 0x0100 }
        if modifiers.contains(.option) { mask |= 0x0800 }
        if modifiers.contains(.control) { mask |= 0x1000 }
        if modifiers.contains(.shift) { mask |= 0x0200 }
        return mask
    }

    /// ANSI virtual key codes as reported by AppKit; used only for display,
    /// never for matching. The letter/digit order follows the actual ANSI
    /// layout (A S D F H G Z X C V B Q W E R Y T …), not the alphabet.
    private static func keyGlyph(for keyCode: UInt32) -> String {
        switch keyCode {
        case 0: "A"
        case 1: "S"
        case 2: "D"
        case 3: "F"
        case 4: "H"
        case 5: "G"
        case 6: "Z"
        case 7: "X"
        case 8: "C"
        case 9: "V"
        case 11: "B"
        case 12: "Q"
        case 13: "W"
        case 14: "E"
        case 15: "R"
        case 16: "Y"
        case 17: "T"
        case 18: "1"
        case 19: "2"
        case 20: "3"
        case 21: "4"
        case 22: "6"
        case 23: "5"
        case 24: "="
        case 25: "9"
        case 26: "7"
        case 27: "-"
        case 28: "8"
        case 29: "0"
        case 30: "]"
        case 31: "O"
        case 32: "U"
        case 33: "["
        case 34: "I"
        case 35: "P"
        case 36: "↩"
        case 37: "L"
        case 38: "J"
        case 39: "'"
        case 40: "K"
        case 41: ";"
        case 42: "\\"
        case 43: ","
        case 44: "/"
        case 45: "N"
        case 46: "M"
        case 47: "."
        case 48: "⇥"
        case 49: "空格"
        case 50: "`"
        case 51: "⌫"
        case 53: "esc"
        case 122: "F1"
        case 120: "F2"
        case 99: "F3"
        case 118: "F4"
        case 96: "F5"
        case 97: "F6"
        case 98: "F7"
        case 100: "F8"
        case 101: "F9"
        case 109: "F10"
        case 103: "F11"
        case 111: "F12"
        case 123: "←"
        case 124: "→"
        case 125: "↓"
        case 126: "↑"
        default: "键 \(keyCode)"
        }
    }
}
