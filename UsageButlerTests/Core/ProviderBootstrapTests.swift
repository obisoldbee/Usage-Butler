import Foundation
import XCTest
@testable import UsageButlerCore
@testable import UsageButlerDomain

final class ProviderBootstrapTests: XCTestCase {
    private let fixedNow = Date(timeIntervalSince1970: 1_786_300_000)

    func testAllThreeProvidersDefaultOnAndStartDetectingWithUnknownAuthentication() throws {
        let capabilities = Dictionary(
            uniqueKeysWithValues: ProviderID.allCases.map { id in
                (
                    id,
                    ProviderCapabilities(
                        contractVersion: "provider-contract-v0.8",
                        loginMethod: id == .ark ? .sso : .oauth,
                        hasOfficialDocumentation: true,
                        allowsExecutableSelection: true
                    )
                )
            }
        )

        let states = try ProviderBootstrap.initialStates(
            capabilitiesByProvider: capabilities,
            now: fixedNow
        )

        XCTAssertEqual(ProviderDefaults.initiallyEnabled, Set(ProviderID.allCases))
        XCTAssertEqual(states.map(\.id), [.openAI, .miniMax, .ark])

        for state in states {
            XCTAssertEqual(state.connection, .detecting(startedAt: fixedNow))
            XCTAssertEqual(state.presence, .unknown)
            XCTAssertEqual(state.freshness, .unknown)
            XCTAssertNil(state.lastGood)
            XCTAssertNil(state.refresh.lastAttemptAt)
            XCTAssertNil(state.refresh.lastSuccessAt)
            XCTAssertNil(state.failure)

            guard case let .unknown(evidence) = state.authentication else {
                return XCTFail("\(state.id) must start with unknown authentication")
            }
            XCTAssertEqual(evidence.authority, .initialDetection)
            XCTAssertEqual(evidence.observedAt, fixedNow)
        }
    }

    func testBootstrapRejectsMissingRequiredCapabilities() {
        XCTAssertThrowsError(
            try ProviderBootstrap.initialStates(
                capabilitiesByProvider: [
                    .openAI: ProviderCapabilities(
                        contractVersion: "provider-contract-v0.8",
                        loginMethod: .oauth,
                        hasOfficialDocumentation: true,
                        allowsExecutableSelection: true
                    )
                ],
                now: fixedNow
            )
        ) { error in
            XCTAssertEqual(error as? ProviderBootstrapError, .missingCapabilities(.miniMax))
        }
    }
}
