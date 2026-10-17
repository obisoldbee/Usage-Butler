import Foundation

/// Keep raw OSStatus available in the help text without crowding the setting.
enum ShortcutErrorCopy {
    static func displayText(_ issue: String) -> String {
        issue.replacingOccurrences(of: "（[^（）]*OSStatus -?[0-9]+）", with: "", options: .regularExpression)
    }
}
