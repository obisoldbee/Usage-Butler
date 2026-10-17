import CryptoKit
import Foundation

/// Ephemeral authorization material. Never Codable, logged, or written to disk.
public struct GrokBotCacheAssociation: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public let key: SymmetricKey
    public let sessionScope: String
    public let generation: UInt64
    public let expiresAt: Date

    public init(key: SymmetricKey, sessionScope: String, generation: UInt64, expiresAt: Date) {
        self.key = key; self.sessionScope = sessionScope; self.generation = generation; self.expiresAt = expiresAt
    }
    public var description: String { "[redacted Grok cache authorization]" }
    public var debugDescription: String { description }
    public func matches(_ other: Self) -> Bool {
        generation == other.generation && sessionScope == other.sessionScope && key == other.key && expiresAt == other.expiresAt
    }
}
