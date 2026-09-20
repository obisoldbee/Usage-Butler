import Foundation
import UsageButlerCore
import UsageButlerDomain

/// UserDefaults-backed network settings. Missing keys fall back to
/// `NetworkSettings.default`; a stored value of the wrong shape fails the
/// whole load as `.corrupt` rather than being silently reinterpreted.
/// Values round-trip through the `NetworkSettings` initializer so its
/// clamping always applies.
public struct UserDefaultsNetworkSettingsStore: NetworkSettingsStore {
    /// Alias to the single source of truth in Core.
    public typealias Key = NetworkPreferenceKey

    /// UserDefaults is documented thread-safe but not annotated Sendable.
    private struct Box: @unchecked Sendable {
        let defaults: UserDefaults
    }

    private let box: Box

    public init(defaults: UserDefaults) {
        box = Box(defaults: defaults)
    }

    public func load() async -> Result<NetworkSettings, NetworkStoreFailure> {
        let defaults = box.defaults
        let fallback = NetworkSettings.default

        let collectionEnabled = defaults.object(forKey: Key.collectionEnabled) == nil
            ? fallback.collectionEnabled
            : defaults.bool(forKey: Key.collectionEnabled)

        let retention: NetworkHistoryRetention
        if let raw = defaults.string(forKey: Key.retention) {
            guard let parsed = NetworkHistoryRetention(rawValue: raw) else {
                return .failure(.corrupt)
            }
            retention = parsed
        } else {
            retention = fallback.retention
        }

        let threshold: UInt64
        if let stored = defaults.object(forKey: Key.uploadAlertThresholdBytes) {
            guard let number = stored as? NSNumber, number.int64Value >= 0 else {
                return .failure(.corrupt)
            }
            threshold = UInt64(number.int64Value)
        } else {
            threshold = fallback.uploadAlertThresholdBytes
        }

        let notificationsEnabled = defaults.object(forKey: Key.notificationsEnabled) == nil
            ? fallback.notificationsEnabled
            : defaults.bool(forKey: Key.notificationsEnabled)

        return .success(NetworkSettings(
            collectionEnabled: collectionEnabled,
            retention: retention,
            uploadAlertThresholdBytes: threshold,
            notificationsEnabled: notificationsEnabled
        ))
    }

    public func save(_ settings: NetworkSettings) async -> Result<Void, NetworkStoreFailure> {
        let defaults = box.defaults
        defaults.set(settings.collectionEnabled, forKey: Key.collectionEnabled)
        defaults.set(settings.retention.rawValue, forKey: Key.retention)
        defaults.set(NSNumber(value: settings.uploadAlertThresholdBytes), forKey: Key.uploadAlertThresholdBytes)
        defaults.set(settings.notificationsEnabled, forKey: Key.notificationsEnabled)
        return .success(())
    }
}
