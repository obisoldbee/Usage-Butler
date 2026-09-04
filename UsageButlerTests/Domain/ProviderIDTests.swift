import XCTest
@testable import UsageButlerDomain

final class ProviderIDTests: XCTestCase {
    func testCanonicalProviderOrderIsStable() {
        XCTAssertEqual(
            ProviderID.allCases.sorted { $0.canonicalOrder < $1.canonicalOrder },
            [.openAI, .miniMax, .ark]
        )
    }
}

