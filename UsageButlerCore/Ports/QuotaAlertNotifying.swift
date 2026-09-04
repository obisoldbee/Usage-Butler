import Foundation
import UsageButlerDomain

public struct QuotaAlertPayload: Equatable, Sendable {
    public let title: String
    public let bodyLines: [String]

    public init(title: String, bodyLines: [String]) {
        self.title = title
        self.bodyLines = bodyLines
    }
}

/// A delivery channel for quota exhaustion and reset alerts. Implementations own their
/// transport; a typed failure is reported per channel and must never affect
/// sibling channels.
public protocol QuotaAlertNotifier: Actor {
    /// One-time channel setup (e.g. system authorization). Failures are the
    /// channel's own concern and surface through `send`.
    func prepare() async

    func send(_ payload: QuotaAlertPayload) async -> Result<Void, ProviderFailure>
}

/// Persists quota alert state across launches. Plain stable metric keys store
/// exhaustion cycle markers; private namespaced keys may store versioned reset
/// observations used for edge detection and deduplication.
public protocol QuotaAlertMarkerStore: Actor {
    func loadMarkers() async -> [String: String]
    func saveMarkers(_ markers: [String: String]) async
}
