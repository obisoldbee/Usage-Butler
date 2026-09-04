import Foundation
import XCTest
@testable import UsageButlerCore
@testable import UsageButlerDomain

#if USAGE_BUTLER_FIXTURES
final class Stage3FixtureCatalogTests: XCTestCase {
    private let fixedNow = Date(timeIntervalSince1970: 1_786_300_000)

    func testAllProvidersAreEnabledByDefault() {
        XCTAssertEqual(ProviderDefaults.initiallyEnabled, Set(ProviderID.allCases))
    }

    func testFirstRunFixtureStartsAllProvidersInDetectingWithoutQuota() {
        let projection = Stage3FixtureCatalog.projection(
            scenario: .firstRunDetecting,
            now: fixedNow
        )

        XCTAssertEqual(projection.providers.map(\.id), [.openAI, .miniMax, .ark])
        XCTAssertTrue(projection.providers.allSatisfy { $0.rowState == .detecting })
        XCTAssertTrue(projection.providers.allSatisfy { $0.products.isEmpty })
    }

    func testAcceptedFixturePreservesProviderSpecificDirections() throws {
        let projection = Stage3FixtureCatalog.projection(
            scenario: .acceptedVisualFresh,
            now: fixedNow
        )

        let openAI = try XCTUnwrap(projection.providers.first { $0.id == .openAI })
        let miniMax = try XCTUnwrap(projection.providers.first { $0.id == .miniMax })
        let ark = try XCTUnwrap(projection.providers.first { $0.id == .ark })

        guard case let .percent(_, openAIDirection) = try XCTUnwrap(openAI.products.first?.metrics.first).value,
              case let .percent(_, miniMaxDirection) = try XCTUnwrap(miniMax.products.first?.metrics.first).value,
              case let .percent(_, arkDirection) = try XCTUnwrap(ark.products.first?.metrics.first).value else {
            return XCTFail("Expected finite percentage fixtures")
        }

        XCTAssertEqual(openAIDirection, .remaining)
        XCTAssertEqual(miniMaxDirection, .used)
        XCTAssertEqual(arkDirection, .used)
    }

    func testArkExpiredFixtureDoesNotChangeSiblingStateOrRemoveLastGoodRows() throws {
        let projection = Stage3FixtureCatalog.projection(
            scenario: .arkExpiredStale,
            now: fixedNow
        )

        let openAI = try XCTUnwrap(projection.providers.first { $0.id == .openAI })
        let miniMax = try XCTUnwrap(projection.providers.first { $0.id == .miniMax })
        let ark = try XCTUnwrap(projection.providers.first { $0.id == .ark })

        XCTAssertEqual(openAI.rowState, .connected)
        XCTAssertEqual(miniMax.rowState, .connected)
        guard case .expired = ark.rowState else {
            return XCTFail("Ark should be the only expired provider")
        }
        XCTAssertEqual(ark.products.count, 2)
        XCTAssertEqual(ark.products.flatMap(\.metrics).count, 6)
    }

    func testArkWarningFixtureKeepsFreshQuotaAndHealthySiblings() throws {
        let projection = Stage3FixtureCatalog.projection(
            scenario: .arkWarningFresh,
            now: fixedNow
        )
        let fresh = Stage3FixtureCatalog.projection(
            scenario: .acceptedVisualFresh,
            now: fixedNow
        )
        let ark = try XCTUnwrap(projection.providers.first { $0.id == .ark })

        XCTAssertEqual(ark.rowState, .authenticationWarning)
        XCTAssertEqual(ark.dataState, .fresh(asOf: fixedNow))
        XCTAssertEqual(ark.products, fresh.providers.first { $0.id == .ark }?.products)
        XCTAssertNil(ark.failureCode)
        XCTAssertTrue(projection.providers.filter { $0.id != .ark }.allSatisfy {
            $0.rowState == .connected
        })
        XCTAssertEqual(
            ark.origin,
            .fixture(scenarioID: Stage3FixtureScenario.arkWarningFresh.rawValue, fixedNow: fixedNow)
        )
    }

    func testMemoryFixtureContainsExactlySevenActivityMonitorNamedFields() {
        let projection = Stage3FixtureCatalog.projection(now: fixedNow)
        XCTAssertEqual(projection.memory.fields.map(\.id), MemoryFieldID.allCases)
    }
}
#endif
