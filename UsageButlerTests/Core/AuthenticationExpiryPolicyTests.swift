import Foundation
import XCTest
@testable import UsageButlerCore
import UsageButlerDomain

final class AuthenticationExpiryPolicyTests: XCTestCase {
    func testClockTickEntersWarningThenExpiredWithoutAnotherQuotaRead() {
        let now = Date(timeIntervalSince1970: 1_788_000_000)
        let evidence = AuthenticationEvidence(
            authority: .providerReport(sourceField: "identity_store.refresh_token.exp", contractVersion: "test"),
            observedAt: now, expiresAt: now.addingTimeInterval(86_401)
        )
        var state = ControllerFixture.initialState()
        state.authentication = .healthy(evidence)
        state = ProviderReducer.reduce(state: state, event: .ageTick(staleAfter: 300), now: now.addingTimeInterval(1))
        XCTAssertEqual(state.authentication, .warning(evidence))
        state = ProviderReducer.reduce(state: state, event: .ageTick(staleAfter: 300), now: now.addingTimeInterval(86_401))
        guard case .expired = state.authentication else { return XCTFail("deadline must expire without quota I/O") }
    }

    func testNewAuthorizationDeadlineClearsOldWarningAndOldDeadlineCannotReappear() {
        let now = Date(timeIntervalSince1970: 1_788_000_000)
        let authority = AuthenticationEvidence.Authority.providerReport(sourceField: "test", contractVersion: "test")
        var state = ControllerFixture.initialState()
        state.authentication = .warning(.init(authority: authority, observedAt: now, expiresAt: now.addingTimeInterval(60)))
        let renewed = AuthenticationState.healthy(.init(authority: authority, observedAt: now, expiresAt: now.addingTimeInterval(172_800)))
        state = ProviderReducer.reduce(state: state, event: .authenticationObserved(renewed), now: now)
        state = ProviderReducer.reduce(state: state, event: .ageTick(staleAfter: 300), now: now.addingTimeInterval(61))
        XCTAssertEqual(state.authentication, renewed)
    }
}
