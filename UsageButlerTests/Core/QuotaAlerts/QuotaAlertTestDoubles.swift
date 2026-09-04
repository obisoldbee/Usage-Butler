import Foundation
import UsageButlerCore
import UsageButlerDomain

enum QuotaAlertFixture {
    static let provider = ProviderID.ark
    static let date = Date(timeIntervalSince1970: 1_786_300_000)
    static let resetDate = date.addingTimeInterval(3_600)

    static var capabilities: ProviderCapabilities {
        ProviderCapabilities(
            contractVersion: "provider-contract-v0.8",
            loginMethod: nil,
            hasOfficialDocumentation: true,
            allowsExecutableSelection: false
        )
    }

    static func source() -> ProviderSourceIdentity {
        ProviderSourceIdentity(
            providerID: provider,
            adapterID: "fake.alert-adapter",
            executableIdentity: "fake-selected-v1",
            cliVersion: "1.0.0",
            schemaVersion: "fake-v1",
            contractVersion: "provider-contract-v0.8"
        )
    }

    static func provenance(
        productID: String = "prod-1",
        metricID: String = "m-1",
        fetchedAt: Date = date
    ) -> MetricProvenance {
        MetricProvenance(
            sourceIdentity: MetricSourceIdentity(
                providerID: provider,
                sourceProductID: productID,
                sourceBucketID: nil,
                sourceMetricID: metricID
            ),
            providerSource: source(),
            fetchedAt: fetchedAt
        )
    }

    static func window(
        kind: QuotaWindowKind = .weekly,
        startsAt: Date? = nil,
        timeEvent: QuotaTimeEvent? = nil
    ) -> QuotaWindow {
        QuotaWindow(
            kind: kind,
            duration: nil,
            startsAt: startsAt,
            endsAt: nil,
            timeEvent: timeEvent
        )
    }

    static func metric(
        productID: String = "prod-1",
        metricID: String = "m-1",
        sourceLabel: String? = nil,
        window: QuotaWindow? = nil,
        value: QuotaMetricValue
    ) -> QuotaMetric {
        let provenance = Self.provenance(productID: productID, metricID: metricID)
        return QuotaMetric(
            id: MetricID(sourceIdentity: provenance.sourceIdentity),
            sourceMetricID: metricID,
            sourceLabel: sourceLabel,
            window: window,
            value: value,
            sourceStatus: nil,
            provenance: provenance,
            state: .authoritativeData(asOf: date)
        )
    }

    static func product(
        sourceProductID: String = "prod-1",
        metrics: [QuotaMetric]
    ) -> QuotaProductData {
        QuotaProductData(
            id: ProductID(providerID: provider, sourceProductID: sourceProductID),
            sourceProductID: sourceProductID,
            titleKey: "fake.title",
            canonicalOrder: 0,
            planLevel: nil,
            state: .authoritativeData(asOf: date),
            metrics: metrics
        )
    }

    static func balance(
        sourceBalanceID: String = "bal-1",
        amount: Decimal,
        unit: String = "美元"
    ) -> QuotaBalance {
        QuotaBalance(
            sourceBalanceID: sourceBalanceID,
            amount: amount,
            unit: unit,
            provenance: provenance(productID: "prod-1", metricID: sourceBalanceID),
            state: .authoritativeData(asOf: date)
        )
    }

    static func entitlement(
        availableCount: Decimal,
        title: String? = "每日重置包",
        expiresAt: Date? = resetDate
    ) -> ResetEntitlementSummary {
        ResetEntitlementSummary(
            availableCount: availableCount,
            details: [
                ResetEntitlementDetail(
                    sourceID: "ent-detail-1",
                    status: "unused",
                    grantedAt: nil,
                    expiresAt: expiresAt,
                    title: title
                )
            ],
            provenance: provenance(productID: "prod-1", metricID: "ent-1")
        )
    }

    static func quotaData(
        products: [QuotaProductData] = [],
        balances: [QuotaBalance] = [],
        resetEntitlements: [ResetEntitlementSummary] = [],
        fetchedAt: Date = date
    ) -> ProviderQuotaData {
        ProviderQuotaData(
            providerID: provider,
            source: source(),
            fetchedAt: fetchedAt,
            products: products,
            balances: balances,
            resetEntitlements: resetEntitlements
        )
    }

    static func openAIWeeklyQuotaData(
        remainingPercent: Decimal,
        fetchedAt: Date,
        resetAt: Date?,
        productID: String = "codex",
        windowKind: QuotaWindowKind = .weekly,
        isFresh: Bool = true
    ) -> ProviderQuotaData {
        let providerID = ProviderID.openAI
        let source = ProviderSourceIdentity(
            providerID: providerID,
            adapterID: "fake.openai-alert-adapter",
            executableIdentity: "fake-codex-v1",
            cliVersion: "1.0.0",
            schemaVersion: "fake-openai-v1",
            contractVersion: "provider-contract-v0.8"
        )
        let identity = MetricSourceIdentity(
            providerID: providerID,
            sourceProductID: productID,
            sourceBucketID: productID,
            sourceMetricID: "primary.used_percent"
        )
        let provenance = MetricProvenance(
            sourceIdentity: identity,
            providerSource: source,
            fetchedAt: fetchedAt
        )
        var nodeState = QuotaNodeState.authoritativeData(asOf: fetchedAt)
        if !isFresh {
            nodeState.freshness = .stale(
                asOf: fetchedAt,
                evaluatedAt: fetchedAt.addingTimeInterval(60)
            )
        }
        let metric = QuotaMetric(
            id: MetricID(sourceIdentity: identity),
            sourceMetricID: identity.sourceMetricID,
            sourceLabel: nil,
            window: QuotaWindow(
                kind: windowKind,
                duration: windowKind == .weekly ? 7 * 24 * 60 * 60 : nil,
                startsAt: nil,
                endsAt: resetAt,
                timeEvent: resetAt.map {
                    QuotaTimeEvent(kind: .reset, occursAt: $0)
                }
            ),
            value: .percent(
                DirectedPercent(
                    sourceValue: 100 - remainingPercent,
                    sourceDirection: .used
                )
            ),
            sourceStatus: nil,
            provenance: provenance,
            state: nodeState
        )
        let product = QuotaProductData(
            id: ProductID(providerID: providerID, sourceProductID: productID),
            sourceProductID: productID,
            titleKey: "provider.openai.product.codex",
            canonicalOrder: 0,
            planLevel: nil,
            state: nodeState,
            metrics: [metric]
        )
        return ProviderQuotaData(
            providerID: providerID,
            source: source,
            fetchedAt: fetchedAt,
            products: [product],
            balances: [],
            resetEntitlements: []
        )
    }

    /// A weekly metric already run to 100% used with a reset event one hour
    /// after the fixed fetch date.
    static func exhaustedPercentMetric(
        productID: String = "prod-1",
        metricID: String = "m-1"
    ) -> QuotaMetric {
        metric(
            productID: productID,
            metricID: metricID,
            window: window(
                kind: .weekly,
                timeEvent: QuotaTimeEvent(kind: .reset, occursAt: resetDate)
            ),
            value: .percent(DirectedPercent(sourceValue: 100, sourceDirection: .used))
        )
    }

    static func projection(
        lastGood: ProviderQuotaData?,
        isEnabled: Bool = true,
        revision: UInt64 = 1
    ) -> ProviderProjection {
        let providerID = lastGood?.providerID ?? provider
        let observedAt = lastGood?.fetchedAt ?? date
        let state = ProviderState(
            id: providerID,
            capabilities: capabilities,
            connection: .connected(observedAt: observedAt),
            presence: .unknown,
            authentication: .unknown(
                AuthenticationEvidence(authority: .initialDetection, observedAt: observedAt)
            ),
            refresh: RefreshState(
                activity: .idle,
                gate: .open,
                lastAttemptAt: observedAt,
                lastSuccessAt: observedAt
            ),
            lastGood: lastGood,
            freshness: .fresh(asOf: observedAt),
            discovery: .notStarted,
            persistence: .unknown,
            failure: nil
        )
        return ProviderProjection(
            revision: revision,
            isEnabled: isEnabled,
            phase: .running,
            state: state
        )
    }
}

actor FakeQuotaAlertNotifier: QuotaAlertNotifier {
    let id: String
    private(set) var payloads: [QuotaAlertPayload] = []
    private(set) var prepareCount = 0
    var result: Result<Void, ProviderFailure> = .success(())

    init(id: String) {
        self.id = id
    }

    func prepare() async {
        prepareCount += 1
    }

    func send(_ payload: QuotaAlertPayload) async -> Result<Void, ProviderFailure> {
        payloads.append(payload)
        return result
    }
}

actor FakeQuotaAlertMarkerStore: QuotaAlertMarkerStore {
    private(set) var stored: [String: String]
    private(set) var saveCount = 0

    init(stored: [String: String] = [:]) {
        self.stored = stored
    }

    func loadMarkers() async -> [String: String] {
        stored
    }

    func saveMarkers(_ markers: [String: String]) async {
        stored = markers
        saveCount += 1
    }
}

/// Holds the actual load snapshots and the first save completion so tests can
/// drive actor reentrancy without sleeps or real persistence/notifications.
actor ControlledQuotaAlertMarkerStore: QuotaAlertMarkerStore {
    private(set) var stored: [String: String] = [:]
    private(set) var loadCount = 0
    private(set) var saveCount = 0
    private(set) var maximumConcurrentSaves = 0
    private var activeSaves = 0
    private let holdsLoads: Bool
    private let holdsFirstSave: Bool
    private var loadsReleased = false
    private var pendingLoads: [([String: String], CheckedContinuation<[String: String], Never>)] = []
    private var loadWaiters: [CheckedContinuation<Void, Never>] = []
    private var pendingSave: CheckedContinuation<Void, Never>?
    private var saveWaiters: [CheckedContinuation<Void, Never>] = []

    init(holdsLoads: Bool = false, holdsFirstSave: Bool = false) {
        self.holdsLoads = holdsLoads
        self.holdsFirstSave = holdsFirstSave
    }

    func loadMarkers() async -> [String: String] {
        loadCount += 1
        let snapshot = stored
        guard holdsLoads, !loadsReleased else { return snapshot }
        return await withCheckedContinuation { continuation in
            pendingLoads.append((snapshot, continuation))
            loadWaiters.forEach { $0.resume() }
            loadWaiters = []
        }
    }

    func saveMarkers(_ markers: [String: String]) async {
        saveCount += 1
        activeSaves += 1
        maximumConcurrentSaves = max(maximumConcurrentSaves, activeSaves)
        if holdsFirstSave, saveCount == 1 {
            await withCheckedContinuation { continuation in
                pendingSave = continuation
                saveWaiters.forEach { $0.resume() }
                saveWaiters = []
            }
        }
        stored = markers
        activeSaves -= 1
    }

    func waitUntilLoadIsBlocked() async {
        guard pendingLoads.isEmpty else { return }
        await withCheckedContinuation { loadWaiters.append($0) }
    }

    func releaseFirstLoad() {
        let (snapshot, continuation) = pendingLoads.removeFirst()
        continuation.resume(returning: snapshot)
    }

    func releaseRemainingLoads() {
        loadsReleased = true
        let pending = pendingLoads
        pendingLoads = []
        for (snapshot, continuation) in pending {
            continuation.resume(returning: snapshot)
        }
    }

    func waitUntilSaveIsBlocked() async {
        guard pendingSave == nil else { return }
        await withCheckedContinuation { saveWaiters.append($0) }
    }

    func releaseFirstSave() {
        pendingSave?.resume()
        pendingSave = nil
    }
}
