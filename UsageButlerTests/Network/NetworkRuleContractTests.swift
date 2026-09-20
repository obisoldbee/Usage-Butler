import Foundation
import XCTest
@testable import UsageButlerCore
import UsageButlerDomain

final class NetworkRuleContractTests: XCTestCase {
    // MARK: - Target validation: accepted input

    func testExactDomainsAreAcceptedAndNormalized() throws {
        XCTAssertEqual(try NetworkRuleTarget(validating: "example.com"), .exactDomain("example.com"))
        // Case and surrounding whitespace are normalized.
        XCTAssertEqual(try NetworkRuleTarget(validating: "  Example.COM\t"), .exactDomain("example.com"))
        XCTAssertEqual(try NetworkRuleTarget(validating: "a-b.example-site.org"), .exactDomain("a-b.example-site.org"))
        XCTAssertEqual(try NetworkRuleTarget(validating: "a.b.c.d.example.co"), .exactDomain("a.b.c.d.example.co"))

        let label63 = String(repeating: "a", count: 63)
        XCTAssertEqual(try NetworkRuleTarget(validating: "\(label63).com"), .exactDomain("\(label63).com"))
        // 253 characters total is the DNS limit and stays valid.
        let label61 = String(repeating: "b", count: 61)
        let maxDomain = "\(label63).\(label63).\(label63).\(label61)"
        XCTAssertEqual(maxDomain.count, 253)
        XCTAssertEqual(try NetworkRuleTarget(validating: maxDomain), .exactDomain(maxDomain))
    }

    func testExactIPv4AddressesAreAccepted() throws {
        XCTAssertEqual(try NetworkRuleTarget(validating: "192.168.1.1"), .exactIPv4("192.168.1.1"))
        XCTAssertEqual(try NetworkRuleTarget(validating: "0.0.0.0"), .exactIPv4("0.0.0.0"))
        XCTAssertEqual(try NetworkRuleTarget(validating: "255.255.255.255"), .exactIPv4("255.255.255.255"))
        XCTAssertEqual(try NetworkRuleTarget(validating: " 8.8.8.8 "), .exactIPv4("8.8.8.8"))
    }

    // MARK: - Target validation: rejected input

    private func assertRejected(
        _ raw: String,
        as expected: NetworkRuleTarget.ValidationFailure,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(try NetworkRuleTarget(validating: raw), file: file, line: line) { error in
            XCTAssertEqual(error as? NetworkRuleTarget.ValidationFailure, expected, file: file, line: line)
        }
    }

    func testEmptyTargetsAreRejected() {
        assertRejected("", as: .empty)
        assertRejected("   \n", as: .empty)
    }

    func testURLsAndPathsAreRejected() {
        assertRejected("https://example.com", as: .containsURLSchemeOrPath)
        assertRejected("example.com/path", as: .containsURLSchemeOrPath)
        assertRejected("example.com/", as: .containsURLSchemeOrPath)
    }

    func testCIDRIsRejectedWithItsOwnDiagnostic() {
        // CIDR contains "/", but users deserve the precise reason.
        assertRejected("10.0.0.0/8", as: .cidrUnsupported)
        assertRejected("192.168.0.0/16", as: .cidrUnsupported)
    }

    func testWildcardsAreRejected() {
        assertRejected("*.example.com", as: .wildcardUnsupported)
        assertRejected("example.*", as: .wildcardUnsupported)
    }

    func testIPv6RuleInputIsRejected() {
        // IPv6 observation is supported elsewhere; rule input excludes it.
        assertRejected("::1", as: .ipv6Unsupported)
        assertRejected("fe80::1", as: .ipv6Unsupported)
    }

    func testMalformedIPv4IsRejected() {
        assertRejected("1.2.3", as: .invalidIPv4)
        assertRejected("1.2.3.4.5", as: .invalidIPv4)
        assertRejected("256.0.0.1", as: .invalidIPv4)
        assertRejected("01.2.3.4", as: .invalidIPv4) // leading zero
        assertRejected("1.2.3.", as: .invalidIPv4)
    }

    func testMalformedDomainsAreRejected() {
        assertRejected("example", as: .invalidDomain) // single label
        assertRejected("example..com", as: .invalidDomain) // empty label
        assertRejected("-example.com", as: .invalidDomain) // leading hyphen
        assertRejected("example-.com", as: .invalidDomain) // trailing hyphen
        assertRejected("exam ple.com", as: .invalidDomain) // interior space
        assertRejected("exämple.com", as: .invalidDomain) // no IDN/punycode input

        let label64 = String(repeating: "a", count: 64)
        assertRejected("\(label64).com", as: .invalidDomain)
        let label63 = String(repeating: "a", count: 63)
        let label62 = String(repeating: "b", count: 62)
        let tooLong = "\(label63).\(label63).\(label63).\(label62)"
        XCTAssertEqual(tooLong.count, 254)
        assertRejected(tooLong, as: .invalidDomain)
    }

    // MARK: - Execution state

    func testIsEnforcedOnlyMatchesConfirmedRevision() {
        let confirmedAt = Date(timeIntervalSince1970: 1_700_000_000)
        XCTAssertTrue(RuleExecutionState.enforced(revision: 3, confirmedAt: confirmedAt).isEnforced(revision: 3))
        XCTAssertFalse(RuleExecutionState.enforced(revision: 3, confirmedAt: confirmedAt).isEnforced(revision: 2))
        XCTAssertFalse(RuleExecutionState.configured.isEnforced(revision: 3))
        XCTAssertFalse(RuleExecutionState.pending.isEnforced(revision: 3))
        XCTAssertFalse(RuleExecutionState.enforcing.isEnforced(revision: 3))
        XCTAssertFalse(RuleExecutionState.failed(revision: 3, reason: "x").isEnforced(revision: 3))
        XCTAssertFalse(RuleExecutionState.unknown.isEnforced(revision: 3))
    }

    // MARK: - Settings contract

    func testAlertThresholdIsClampedToContractRange() {
        XCTAssertEqual(NetworkSettings(uploadAlertThresholdBytes: 0).uploadAlertThresholdBytes, 1_000_000)
        XCTAssertEqual(NetworkSettings(uploadAlertThresholdBytes: 999_999).uploadAlertThresholdBytes, 1_000_000)
        XCTAssertEqual(NetworkSettings(uploadAlertThresholdBytes: 1_000_000).uploadAlertThresholdBytes, 1_000_000)
        XCTAssertEqual(NetworkSettings(uploadAlertThresholdBytes: 10_000_000_000).uploadAlertThresholdBytes, 10_000_000_000)
        XCTAssertEqual(NetworkSettings(uploadAlertThresholdBytes: 10_000_000_001).uploadAlertThresholdBytes, 10_000_000_000)
        XCTAssertEqual(NetworkSettings(uploadAlertThresholdBytes: .max).uploadAlertThresholdBytes, 10_000_000_000)
        XCTAssertEqual(NetworkSettings(uploadAlertThresholdBytes: 50_000_000).uploadAlertThresholdBytes, 50_000_000)
    }

    func testDefaultsKeepCollectionAndNotificationsOff() {
        let settings = NetworkSettings.default
        XCTAssertFalse(settings.collectionEnabled)
        XCTAssertFalse(settings.notificationsEnabled)
        XCTAssertEqual(settings.retention, .hours24)
        XCTAssertEqual(settings.uploadAlertThresholdBytes, 10_000_000)
    }

    func testRetentionDurationsMatchContract() {
        XCTAssertEqual(NetworkHistoryRetention.hours1.duration, .seconds(3_600))
        XCTAssertEqual(NetworkHistoryRetention.hours24.duration, .seconds(86_400))
        XCTAssertEqual(NetworkHistoryRetention.days7.duration, .seconds(604_800))
    }

    // MARK: - Identity keys used by rules

    func testStableKeyOnlyUsesPresentIdentityFields() {
        XCTAssertEqual(AppIdentity().stableKey, "unidentified")
        XCTAssertEqual(AppIdentity(bundleID: "a.b").stableKey, "b:a.b")
        XCTAssertEqual(AppIdentity(teamID: "T").stableKey, "t:T")
        XCTAssertEqual(AppIdentity(bundleID: "a.b", teamID: "T").stableKey, "b:a.b|t:T")
        XCTAssertEqual(
            AppIdentity(bundleID: "a.b", signingIdentity: "s", teamID: "T").stableKey,
            "b:a.b|s:s|t:T"
        )
        // Display-only fields never enter the key.
        XCTAssertEqual(
            AppIdentity(bundleID: "a.b", version: "1", displayName: "Nice").stableKey,
            "b:a.b"
        )
    }
}
