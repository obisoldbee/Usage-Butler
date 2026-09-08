import Foundation
import UsageButlerDomain
import XCTest
@testable import UsageButlerCore
@testable import UsageButlerUI

final class ProviderProductVisibilityTests: XCTestCase {
    private let fixedNow = Date(timeIntervalSince1970: 1_786_400_000)

    func testLiveProviderProjectionMapperFiltersDisabledProducts() throws {
        let agentPlan = QuotaProductData(
            id: ProductID(providerID: .ark, sourceProductID: "agent-plan"),
            sourceProductID: "agent-plan",
            titleKey: "provider.ark.product.agent-plan",
            canonicalOrder: 0,
            planLevel: PlanLevelObservation(
                value: "Medium",
                origin: .reported(sourceField: "items[].tier"),
                contractVersion: "test",
                fetchedAt: fixedNow
            ),
            state: nodeState(presence: authoritativePresence(.entitled, providerID: .ark, operationID: "test.agent-plan")),
            metrics: [metric(product: "agent-plan", label: "5h")]
        )
        let codingPlan = QuotaProductData(
            id: ProductID(providerID: .ark, sourceProductID: "coding-plan"),
            sourceProductID: "coding-plan",
            titleKey: "provider.ark.product.coding-plan",
            canonicalOrder: 1,
            planLevel: PlanLevelObservation(
                value: "Pro",
                origin: .reported(sourceField: "items[].tier"),
                contractVersion: "test",
                fetchedAt: fixedNow
            ),
            state: nodeState(presence: authoritativePresence(.entitled, providerID: .ark, operationID: "test.coding-plan")),
            metrics: [metric(product: "coding-plan", label: "weekly")]
        )

        let quota = ProviderQuotaData(
            providerID: .ark,
            source: source(.ark),
            fetchedAt: fixedNow,
            products: [agentPlan, codingPlan],
            balances: [],
            resetEntitlements: []
        )
        let state = providerState(providerID: .ark, quota: quota)
        let projection = ProviderProjection(
            revision: 1,
            isEnabled: true,
            phase: .running,
            state: state
        )

        // 1. When all products are enabled
        let allEnabled = try XCTUnwrap(
            LiveProviderProjectionMapper.map(
                projection,
                now: fixedNow,
                isProductEnabled: { _, _ in true }
            )
        )
        XCTAssertEqual(allEnabled.products.count, 2)
        XCTAssertEqual(allEnabled.products.map(\.title), ["Agent Plan", "Coding Plan"])

        // 2. When agent-plan is disabled
        let agentDisabled = try XCTUnwrap(
            LiveProviderProjectionMapper.map(
                projection,
                now: fixedNow,
                isProductEnabled: { providerID, productID in
                    !(providerID == .ark && productID == "agent-plan")
                }
            )
        )
        XCTAssertEqual(agentDisabled.products.count, 1)
        XCTAssertEqual(agentDisabled.products.first?.title, "Coding Plan")

        // 3. When both are disabled
        let bothDisabled = try XCTUnwrap(
            LiveProviderProjectionMapper.map(
                projection,
                now: fixedNow,
                isProductEnabled: { _, _ in false }
            )
        )
        XCTAssertEqual(bothDisabled.products.count, 0)
    }

    @MainActor
    func testMenuPanelViewModelSetProductEnabledTogglesVisibility() throws {
        let agentPlan = Stage3QuotaProductProjection(
            id: "ark.agent-plan",
            sourceProductID: "agent-plan",
            title: "Agent Plan",
            planLevel: Stage3PlanBadge(value: "Medium", origin: .reported(sourceField: "tier")),
            metrics: []
        )
        let codingPlan = Stage3QuotaProductProjection(
            id: "ark.coding-plan",
            sourceProductID: "coding-plan",
            title: "Coding Plan",
            planLevel: Stage3PlanBadge(value: "Pro", origin: .reported(sourceField: "tier")),
            metrics: []
        )

        let arkProvider = Stage3ProviderProjection(
            id: .ark,
            rowState: .connected,
            dataState: .fresh(asOf: fixedNow),
            activity: .idle,
            products: [agentPlan, codingPlan],
            capturedAt: fixedNow,
            origin: .runtime
        )

        let appProjection = Stage3AppProjection(
            providers: [arkProvider],
            memory: Stage3MemoryProjection(
                pressure: .normal,
                fields: [],
                history: [],
                capturedAt: fixedNow,
                origin: .runtime
            )
        )

        let model = MenuPanelViewModel(
            snapshot: appProjection,
            settingsProviders: [arkProvider]
        )

        // Initial state: both visible (default enabled)
        XCTAssertEqual(model.snapshot.providers.first?.products.count, 2)

        // Disable agent-plan
        model.setProductEnabled(.ark, productID: "agent-plan", enabled: false)
        XCTAssertEqual(model.snapshot.providers.first?.products.count, 1)
        XCTAssertEqual(model.snapshot.providers.first?.products.first?.sourceProductID, "coding-plan")

        // Re-enable agent-plan
        model.setProductEnabled(.ark, productID: "agent-plan", enabled: true)
        XCTAssertEqual(model.snapshot.providers.first?.products.count, 2)
    }

    private func nodeState(presence: PresenceState) -> QuotaNodeState {
        QuotaNodeState(
            presence: presence,
            freshness: .fresh(asOf: fixedNow),
            refresh: RefreshState(
                activity: .idle,
                gate: .open,
                lastAttemptAt: fixedNow,
                lastSuccessAt: fixedNow
            ),
            lastAttemptAt: fixedNow,
            lastSuccessAt: fixedNow,
            failure: nil
        )
    }

    private func metric(product: String, label: String) -> QuotaMetric {
        let sourceIdentity = MetricSourceIdentity(
            providerID: .ark,
            sourceProductID: product,
            sourceBucketID: label,
            sourceMetricID: "usage"
        )
        return QuotaMetric(
            id: MetricID(sourceIdentity: sourceIdentity),
            sourceMetricID: "usage",
            sourceLabel: label,
            window: QuotaWindow(
                kind: .weekly,
                duration: 604_800,
                startsAt: nil,
                endsAt: nil,
                timeEvent: QuotaTimeEvent(
                    kind: .reset,
                    occursAt: fixedNow.addingTimeInterval(86_400)
                )
            ),
            value: .percent(DirectedPercent(sourceValue: 10, sourceDirection: .used)),
            sourceStatus: nil,
            provenance: MetricProvenance(
                sourceIdentity: sourceIdentity,
                providerSource: source(.ark),
                fetchedAt: fixedNow
            ),
            state: nodeState(presence: authoritativePresence(.entitled, providerID: .ark, operationID: "test.\(product)"))
        )
    }

    private func authoritativePresence(
        _ decision: DiscoveryPresenceDecision,
        providerID: ProviderID,
        operationID: String
    ) -> PresenceState {
        let evidence = authenticationEvidence(providerID: providerID)
        let discovery = SuccessfulProviderDiscovery(
            providerID: providerID,
            authority: DiscoveryAuthority(
                source: source(providerID),
                operationID: operationID
            ),
            observedAt: fixedNow,
            connection: .connected,
            authentication: .healthy(evidence),
            presence: decision
        )
        return discovery.resolvedPresence ?? .unknown
    }

    private func authenticationEvidence(providerID: ProviderID) -> AuthenticationEvidence {
        AuthenticationEvidence(
            authority: .providerReport(
                sourceField: "test.auth",
                contractVersion: "\(providerID.rawValue)-v1"
            ),
            observedAt: fixedNow
        )
    }

    private func source(_ providerID: ProviderID) -> ProviderSourceIdentity {
        ProviderSourceIdentity(
            providerID: providerID,
            adapterID: "test.\(providerID.rawValue)",
            executableIdentity: "test-executable",
            cliVersion: "1.0.0",
            schemaVersion: "test-schema-v1",
            contractVersion: "\(providerID.rawValue)-v1"
        )
    }

    private func providerState(
        providerID: ProviderID,
        quota: ProviderQuotaData?
    ) -> ProviderState {
        let evidence = authenticationEvidence(providerID: providerID)
        return ProviderState(
            id: providerID,
            capabilities: ProviderCapabilities(
                contractVersion: "\(providerID.rawValue)-v1",
                loginMethod: providerID == .ark ? .sso : .oauth,
                hasOfficialDocumentation: true,
                allowsExecutableSelection: true
            ),
            connection: .connected(observedAt: fixedNow),
            presence: .unknown,
            authentication: .healthy(evidence),
            refresh: RefreshState(
                activity: .idle,
                gate: .open,
                lastAttemptAt: fixedNow,
                lastSuccessAt: quota?.fetchedAt
            ),
            lastGood: quota,
            freshness: quota.map { .fresh(asOf: $0.fetchedAt) } ?? .unknown,
            discovery: .notStarted,
            persistence: .unknown,
            failure: nil
        )
    }
}
