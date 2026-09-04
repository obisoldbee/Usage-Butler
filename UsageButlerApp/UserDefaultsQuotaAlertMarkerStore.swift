import Foundation
import UsageButlerCore

/// UserDefaults is documented thread-safe but not annotated Sendable; boxing
/// it lets the single instance cross actor and @Sendable boundaries.
struct SendableUserDefaults: @unchecked Sendable {
    let defaults: UserDefaults
}

/// Persists quota alert cycle markers and namespaced reset observations in
/// UserDefaults so edge detection and deduplication survive relaunches.
///
/// Best-effort by design: a decode or encode failure degrades to a possible
/// duplicate alert later, never to a lost quota read.
actor UserDefaultsQuotaAlertMarkerStore: QuotaAlertMarkerStore {
    private let boxed: SendableUserDefaults

    init(boxed: SendableUserDefaults) {
        self.boxed = boxed
    }

    func loadMarkers() async -> [String: String] {
        guard let data = boxed.defaults.data(
            forKey: ProviderPreferenceKey.quotaAlertNotifiedCycles
        ) else {
            return [:]
        }
        return (try? JSONDecoder().decode([String: String].self, from: data)) ?? [:]
    }

    func saveMarkers(_ markers: [String: String]) async {
        guard let data = try? JSONEncoder().encode(markers) else { return }
        boxed.defaults.set(data, forKey: ProviderPreferenceKey.quotaAlertNotifiedCycles)
    }
}
