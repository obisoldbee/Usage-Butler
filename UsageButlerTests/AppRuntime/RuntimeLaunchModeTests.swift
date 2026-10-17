import XCTest
@testable import UsageButlerUI

#if USAGE_BUTLER_FIXTURES
final class RuntimeLaunchModeTests: XCTestCase {
    func testGrokBotPreviewIdentityRemainsOfflineWithoutArguments() {
        #if USAGE_BUTLER_FIXTURES
        XCTAssertEqual(RuntimeLaunchMode.resolve(environment: [:], bundleIdentifier: "io.github.obisoldbee.UsageButler.Preview.Copy.GrokBot"), .offlineFixture)
        #endif
    }

    func testHistoryValidationIdentityRemainsIsolatedWithoutLaunchEnvironment() {
        for identifier in ["io.github.obisoldbee.UsageButler.Validation.History20260926",
                           "io.github.obisoldbee.UsageButler.Validation.HistoryDev20260926"] {
            XCTAssertEqual(RuntimeLaunchMode.resolve(environment: [:], bundleIdentifier: identifier), .networkValidation)
        }
    }

    func testCopyPreviewIdentityCannotEnableCollectorsThroughEnvironmentOrReopening() {
        for identifier in ["io.github.obisoldbee.UsageButler.Preview.Copy.Before",
                           "io.github.obisoldbee.UsageButler.Preview.Copy.After"] {
            for environment in [[:], ["USAGE_BUTLER_NETWORK_VALIDATION": "1"],
                                [RuntimeLaunchMode.offlineFixtureEnvironmentKey: "0"]] {
                XCTAssertEqual(RuntimeLaunchMode.resolve(environment: environment, bundleIdentifier: identifier), .offlineFixture)
            }
        }
        XCTAssertEqual(RuntimeLaunchMode.resolve(environment: [:], bundleIdentifier: "io.github.obisoldbee.UsageButler.Preview.Copy.AfterOther"), .production)
    }

    func testProductionIdentityIsNotChangedByValidationIdentityGuard() {
        XCTAssertEqual(RuntimeLaunchMode.resolve(environment: [:], bundleIdentifier: "io.github.obisoldbee.UsageButler"), .production)
        XCTAssertEqual(RuntimeLaunchMode.resolve(environment: [:], bundleIdentifier: "example.History"), .production)
    }

    func testExplicitOneSelectsOfflineFixtureMode() {
        XCTAssertEqual(
            RuntimeLaunchMode.resolve(environment: [
                RuntimeLaunchMode.offlineFixtureEnvironmentKey: "1",
                "PATH": "/fixture/bin"
            ]),
            .offlineFixture
        )
    }

    func testMissingOrNonExactValueSelectsProductionMode() {
        XCTAssertEqual(
            RuntimeLaunchMode.resolve(environment: [:]),
            .production
        )
        XCTAssertEqual(
            RuntimeLaunchMode.resolve(environment: [
                RuntimeLaunchMode.offlineFixtureEnvironmentKey: "true"
            ]),
            .production
        )
        XCTAssertEqual(
            RuntimeLaunchMode.resolve(environment: [
                RuntimeLaunchMode.offlineFixtureEnvironmentKey: "0"
            ]),
            .production
        )
    }
}
#endif
