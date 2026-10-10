import Combine
import Foundation
import UsageButlerDomain

/// A local presentation overlay. Never changes collector identities or history/export data.
@MainActor
public final class ApplicationNoteStore: ObservableObject {
    public static let preferenceKey = "network.applicationNotes.v1"
    public static let maximumLength = 60
    @Published public private(set) var notes: [String: String]
    private let defaults: UserDefaults?

    /// In-memory by default so fixtures and tests cannot write production preferences.
    public init(defaults: UserDefaults? = nil) {
        self.defaults = defaults
        notes = (defaults?.dictionary(forKey: Self.preferenceKey) as? [String: String] ?? [:])
            .filter { !$0.key.isEmpty && Self.validationMessage($0.value) == nil && !$0.value.isEmpty }
    }
    public func note(for identity: ProcessNetworkApplicationIdentity) -> String? { notes[identity.key] }
    public func displayName(for identity: ProcessNetworkApplicationIdentity) -> String {
        note(for: identity) ?? identity.name
    }
    public static func validationMessage(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count > maximumLength { return "备注最多 60 个字符。" }
        if trimmed.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) || CharacterSet.newlines.contains($0) }) {
            return "备注请使用单行文字。"
        }
        return nil
    }
    @discardableResult
    public func save(_ text: String, for identity: ProcessNetworkApplicationIdentity) -> Bool {
        guard !identity.key.isEmpty, Self.validationMessage(text) == nil else { return false }
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.isEmpty { notes.removeValue(forKey: identity.key) }
        else { notes[identity.key] = value }
        defaults?.set(notes, forKey: Self.preferenceKey)
        return true
    }
}
