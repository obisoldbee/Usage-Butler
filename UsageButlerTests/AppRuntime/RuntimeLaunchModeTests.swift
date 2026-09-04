import XCTest
@testable import UsageButlerUI

#if USAGE_BUTLER_FIXTURES
final class RuntimeLaunchModeTests: XCTestCase {
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
