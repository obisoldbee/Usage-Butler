import XCTest
@testable import UsageButlerCore

final class GlobalShortcutTests: XCTestCase {
    func testSerializationRoundTrips() {
        let shortcut = GlobalShortcut(
            keyCode: 32,
            modifiers: [.command, .option]
        )
        let restored = GlobalShortcut(serialized: shortcut.serialized)
        XCTAssertEqual(restored, shortcut)

        XCTAssertNil(GlobalShortcut(serialized: ""))
        XCTAssertNil(GlobalShortcut(serialized: "garbage"))
        XCTAssertNil(GlobalShortcut(serialized: "v2:32:1048576"))
        XCTAssertNil(GlobalShortcut(serialized: "v1:abc:12"))
    }

    func testDisplayTextUsesModifierGlyphsAndKeyGlyph() {
        XCTAssertEqual(
            GlobalShortcut(keyCode: 12, modifiers: [.command, .option]).displayText,
            "⌥⌘Q"
        )
        XCTAssertEqual(
            GlobalShortcut(keyCode: 0, modifiers: [.control]).displayText,
            "⌃A"
        )
        XCTAssertEqual(
            GlobalShortcut(keyCode: 49, modifiers: [.control, .shift]).displayText,
            "⌃⇧空格"
        )
        XCTAssertEqual(GlobalShortcut(keyCode: 123, modifiers: [.option]).displayText, "⌥←")
    }

    func testHotkeyModifierPolicy() {
        XCTAssertTrue(ShortcutModifiers([.command]).hasHotkeyModifier)
        XCTAssertTrue(ShortcutModifiers([.control]).hasHotkeyModifier)
        XCTAssertTrue(ShortcutModifiers([.option]).hasHotkeyModifier)
        XCTAssertFalse(ShortcutModifiers([.shift]).hasHotkeyModifier)
        XCTAssertFalse(ShortcutModifiers().hasHotkeyModifier)
    }

    func testCarbonModifierMaskMapsEachFlag() {
        XCTAssertEqual(
            GlobalShortcut(keyCode: 1, modifiers: [.command]).carbonModifiers,
            0x0100
        )
        XCTAssertEqual(
            GlobalShortcut(keyCode: 1, modifiers: [.option]).carbonModifiers,
            0x0800
        )
        XCTAssertEqual(
            GlobalShortcut(keyCode: 1, modifiers: [.control]).carbonModifiers,
            0x1000
        )
        XCTAssertEqual(
            GlobalShortcut(keyCode: 1, modifiers: [.shift]).carbonModifiers,
            0x0200
        )
    }
}
