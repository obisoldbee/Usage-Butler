public enum RuntimeLaunchMode: Equatable, Sendable {
    #if USAGE_BUTLER_FIXTURES
    public static let offlineFixtureEnvironmentKey = "USAGE_BUTLER_OFFLINE_FIXTURE"
    #endif

    case production
    #if USAGE_BUTLER_FIXTURES
    case offlineFixture
    case networkValidation
    #endif

    public static func resolve(environment: [String: String], bundleIdentifier: String? = nil) -> RuntimeLaunchMode {
        #if USAGE_BUTLER_FIXTURES
        // LaunchServices or an accessibility tool may reopen a validation App
        // without the original environment. Its isolated identity must never
        // silently construct production providers in a fixture-capable build.
        if bundleIdentifier?.hasPrefix("io.github.obisoldbee.UsageButler.Validation.History") == true {
            return .networkValidation
        }
        if environment["USAGE_BUTLER_NETWORK_VALIDATION"] == "1" { return .networkValidation }
        return environment[offlineFixtureEnvironmentKey] == "1"
            ? .offlineFixture
            : .production
        #else
        .production
        #endif
    }
}
