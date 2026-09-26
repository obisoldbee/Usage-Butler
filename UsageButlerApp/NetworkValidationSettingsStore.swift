#if DEBUG
import UsageButlerCore

/// The explicit network-only harness never reads or writes production
/// preferences, instantiates Provider adapters or sends notifications.
actor NetworkValidationSettingsStore: NetworkSettingsStore {
    private var value = NetworkSettings(collectionEnabled: true)
    func load() async -> Result<NetworkSettings, NetworkStoreFailure> { .success(value) }
    func save(_ settings: NetworkSettings) async -> Result<Void, NetworkStoreFailure> {
        value = settings; return .success(())
    }
}
#endif
