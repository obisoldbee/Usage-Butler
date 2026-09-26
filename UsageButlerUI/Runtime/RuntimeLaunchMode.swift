public enum RuntimeLaunchMode: Equatable, Sendable {
    #if USAGE_BUTLER_FIXTURES
    public static let offlineFixtureEnvironmentKey = "USAGE_BUTLER_OFFLINE_FIXTURE"
    #endif

    case production
    #if USAGE_BUTLER_FIXTURES
    case offlineFixture
    case networkValidation
    #endif

    public static func resolve(environment: [String: String]) -> RuntimeLaunchMode {
        #if USAGE_BUTLER_FIXTURES
        if environment["USAGE_BUTLER_NETWORK_VALIDATION"] == "1" { return .networkValidation }
        return environment[offlineFixtureEnvironmentKey] == "1"
            ? .offlineFixture
            : .production
        #else
        .production
        #endif
    }
}
