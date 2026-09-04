import XCTest
@testable import UsageButlerCore
@testable import UsageButlerDomain

/// Static OSLog privacy gate (tech spec §12.13 item 13). These tests lock the
/// two telemetry event names, their exact field sequences, the per-field value
/// domains, and the banned-content token set. Any new log field, enum value,
/// or free-text segment must update `ProviderRefreshTelemetryContract` and
/// these expectations together, or the build fails.
final class ProviderRefreshTelemetryContractTests: XCTestCase {
    private let contract = ProviderRefreshTelemetryContract.self

    private func assertStructuredMessage(
        _ message: String,
        eventName: String,
        fields: [String],
        domains: [String: Set<String>],
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let parts = message.split(separator: " ").map(String.init)
        XCTAssertEqual(parts.first, eventName, file: file, line: line)
        let pairs = parts.dropFirst()
        XCTAssertEqual(pairs.count, fields.count, file: file, line: line)

        for (index, pair) in pairs.enumerated() {
            let key = String(pair.split(separator: "=", maxSplits: 1).first ?? "")
            XCTAssertEqual(key, fields[index], file: file, line: line)
        }
        for segment in pairs {
            let components = segment.split(separator: "=", maxSplits: 1)
            guard components.count == 2 else {
                return XCTFail(
                    "Segment \(segment) is not key=value",
                    file: file,
                    line: line
                )
            }
            let key = String(components[0])
            let value = String(components[1])
            XCTAssertTrue(
                domains[key]?.contains(value) ?? false,
                "Value \(value) for field \(key) is outside the contract domain",
                file: file,
                line: line
            )
        }
    }

    func testProviderStateMessageUsesExactlyTheContractFields() {
        let state = ProviderRuntimeTelemetryState(
            provider: "ark",
            phase: "running",
            connection: "connected",
            activity: "refreshing",
            freshness: "stale",
            gate: "backoff",
            failure: "schemaMismatch",
            retry: "backoff"
        )
        assertStructuredMessage(
            ProviderRefreshTelemetry.providerStateMessage(state),
            eventName: contract.providerStateEventName,
            fields: contract.providerStateFields,
            domains: contract.providerStateValueDomains
        )
    }

    func testLifecycleRefreshMessageUsesExactlyTheContractFields() {
        for provider in ProviderID.allCases {
            for reason in ProviderLifecycleRefreshReason.allCases {
                for outcome in ProviderIntentOutcome.allCases {
                    assertStructuredMessage(
                        ProviderRefreshTelemetry.lifecycleRefreshMessage(
                            provider: provider,
                            reason: reason,
                            outcome: outcome
                        ),
                        eventName: contract.lifecycleRefreshEventName,
                        fields: contract.lifecycleRefreshFields,
                        domains: contract.lifecycleRefreshValueDomains
                    )
                }
            }
        }
    }

    func testContractDomainsAreLockedLiterals() {
        XCTAssertEqual(
            contract.providerStateValueDomains["phase"],
            ["idle", "starting", "running", "shutting_down", "stopped"]
        )
        XCTAssertEqual(
            contract.providerStateValueDomains["connection"],
            ["disabled", "detecting", "connected", "requires_login", "unavailable"]
        )
        XCTAssertEqual(
            contract.providerStateValueDomains["activity"],
            ["idle", "detecting", "refreshing", "logging_in", "shutting_down"]
        )
        XCTAssertEqual(
            contract.providerStateValueDomains["freshness"],
            ["unknown", "fresh", "stale"]
        )
        XCTAssertEqual(
            contract.providerStateValueDomains["gate"],
            ["open", "cooldown", "backoff", "suspended"]
        )
        XCTAssertEqual(
            contract.lifecycleRefreshValueDomains["reason"],
            ["panel_presented", "system_wake"]
        )
        XCTAssertEqual(
            contract.lifecycleRefreshValueDomains["outcome"],
            ["completed", "joined", "deferred", "rejected", "cancelled", "shutdown"]
        )
    }

    func testDomainsStayClosedUnderEnumMappings() {
        for phase in ProviderControllerPhase.allCases {
            XCTAssertTrue(
                contract.providerStateValueDomains["phase"]?.contains(phase.telemetryValue) == true
            )
        }
        for code in FailureCode.allCases {
            XCTAssertTrue(
                contract.providerStateValueDomains["failure"]?.contains(code.rawValue) == true,
                "FailureCode \(code.rawValue) is not in the failure domain"
            )
        }
        for retryClass in RetryClass.allCases {
            XCTAssertTrue(
                contract.providerStateValueDomains["retry"]?.contains(retryClass.telemetryValue) == true
            )
        }
        for provider in ProviderID.allCases {
            XCTAssertTrue(
                contract.providerStateValueDomains["provider"]?.contains(provider.rawValue) == true
            )
            XCTAssertTrue(
                contract.lifecycleRefreshValueDomains["provider"]?.contains(provider.rawValue) == true
            )
        }
        XCTAssertTrue(
            contract.providerStateValueDomains["failure"]?.contains("none") == true
        )
        XCTAssertTrue(
            contract.providerStateValueDomains["retry"]?.contains("none") == true
        )
    }

    func testFieldNamesNeverCarryBannedContentCategories() {
        XCTAssertFalse(contract.forbiddenFieldTokens.isEmpty)
        for field in contract.providerStateFields + contract.lifecycleRefreshFields {
            for token in contract.forbiddenFieldTokens where field.contains(token) {
                XCTFail("Field \(field) carries banned token \(token)")
            }
        }
        for token in ["raw", "payload", "token", "account", "email", "proxy", "path", "diagnostic"] {
            XCTAssertTrue(
                contract.forbiddenFieldTokens.contains(token),
                "The forbidden set must keep banning \(token)"
            )
        }
    }

    func testMessagesCarryOnlyStructuredEnumSegments() {
        let state = ProviderRuntimeTelemetryState(
            provider: "miniMax",
            phase: "running",
            connection: "requires_login",
            activity: "logging_in",
            freshness: "unknown",
            gate: "suspended",
            failure: "authenticationExpired",
            retry: "after_recovery"
        )
        let structuredPattern = /^[a-z_]+( [a-zA-Z_]+=[a-zA-Z0-9_]+)+$/
        for message in [
            ProviderRefreshTelemetry.providerStateMessage(state),
            ProviderRefreshTelemetry.lifecycleRefreshMessage(
                provider: .openAI,
                reason: .panelPresented,
                outcome: .deferred(.suspend(.operationInProgress))
            )
        ] {
            XCTAssertTrue(
                message.wholeMatch(of: structuredPattern) != nil,
                "Message must stay key=value enum segments without free text: \(message)"
            )
            XCTAssertFalse(message.contains("/"))
            XCTAssertFalse(message.contains("@"))
        }
    }
}
