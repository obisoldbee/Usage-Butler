import Foundation
import XCTest
@testable import UsageButlerCore
@testable import UsageButlerDomain
@testable import UsageButlerInfrastructure

final class UserDefaultsNetworkSettingsStoreTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "UsageButlerTests.NetworkSettings.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    private func makeStore() -> UserDefaultsNetworkSettingsStore {
        UserDefaultsNetworkSettingsStore(defaults: defaults)
    }

    func testLoadWithMissingKeysReturnsDefault() async {
        let result = await makeStore().load()
        guard case let .success(settings) = result else {
            return XCTFail("expected success, got \(result)")
        }
        XCTAssertEqual(settings, .default)
        XCTAssertFalse(settings.collectionEnabled)
    }

    func testSaveThenLoadRoundTrips() async {
        let store = makeStore()
        let settings = NetworkSettings(
            collectionEnabled: true,
            retention: .days7,
            uploadAlertThresholdBytes: 5_000_000,
            notificationsEnabled: true
        )
        guard case .success = await store.save(settings) else {
            return XCTFail("expected save to succeed")
        }
        let result = await store.load()
        guard case let .success(loaded) = result else {
            return XCTFail("expected success, got \(result)")
        }
        XCTAssertEqual(loaded, settings)
    }

    func testLoadWithUnknownRetentionRawValueFailsCorrupt() async {
        defaults.set("bogus", forKey: NetworkPreferenceKey.retention)
        let result = await makeStore().load()
        XCTAssertEqual(result, .failure(.corrupt))
    }

    func testLoadWithNegativeThresholdFailsCorrupt() async {
        defaults.set(NSNumber(value: -1), forKey: NetworkPreferenceKey.uploadAlertThresholdBytes)
        let result = await makeStore().load()
        XCTAssertEqual(result, .failure(.corrupt))
    }

    func testLoadClampsOutOfRangeThresholdThroughSettingsInit() async {
        defaults.set(NSNumber(value: 0), forKey: NetworkPreferenceKey.uploadAlertThresholdBytes)
        let result = await makeStore().load()
        guard case let .success(settings) = result else {
            return XCTFail("expected success, got \(result)")
        }
        XCTAssertEqual(settings.uploadAlertThresholdBytes, 1_000_000)
    }

    func testLoadReadsStoredCollectionEnabled() async {
        defaults.set(true, forKey: NetworkPreferenceKey.collectionEnabled)
        let result = await makeStore().load()
        guard case let .success(settings) = result else {
            return XCTFail("expected success, got \(result)")
        }
        XCTAssertTrue(settings.collectionEnabled)
    }
}
