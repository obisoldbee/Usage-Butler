public enum RuntimeLaunchMode: Equatable, Sendable {
    #if USAGE_BUTLER_FIXTURES
    public static let offlineFixtureEnvironmentKey = "USAGE_BUTLER_OFFLINE_FIXTURE"
    #endif

    case production
    #if USAGE_BUTLER_FIXTURES
    case offlineFixture
    #endif

    public static func resolve(environment: [String: String]) -> RuntimeLaunchMode {
        #if USAGE_BUTLER_FIXTURES
        environment[offlineFixtureEnvironmentKey] == "1"
            ? .offlineFixture
            : .production
        #else
        .production
        #endif
    }
}
