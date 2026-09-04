#if USAGE_BUTLER_FIXTURES
import Foundation
import UsageButlerDomain

public enum Stage3FixtureCatalog {
    public static func projection(
        scenario: Stage3FixtureScenario = .acceptedVisualFresh,
        now: Date = Date()
    ) -> Stage3AppProjection {
        Stage3AppProjection(
            scenario: scenario,
            providers: providerProjections(scenario: scenario, now: now),
            memory: memoryProjection(now: now, scenario: scenario)
        )
    }

    public static func providerProjections(
        scenario: Stage3FixtureScenario,
        now: Date
    ) -> [Stage3ProviderProjection] {
        let origin = Stage3DataOrigin.fixture(scenarioID: scenario.rawValue, fixedNow: now)
        let defaultState: Stage3ProviderRowState = scenario == .firstRunDetecting ? .detecting : .connected
        let hideQuota = scenario == .firstRunDetecting

        return [
            Stage3ProviderProjection(
                id: .openAI,
                rowState: defaultState,
                planLevel: hideQuota ? nil : Stage3PlanBadge(
                    value: "Pro",
                    origin: .reported(sourceField: "account.planType")
                ),
                products: hideQuota ? [] : [
                    Stage3QuotaProductProjection(
                        id: "openai-codex",
                        metrics: [
                            Stage3QuotaMetricProjection(
                                id: "openai-codex-weekly",
                                title: "Codex",
                                windowBadge: "每周",
                                value: .percent(value: 60, direction: .remaining),
                                event: Stage3TimeEvent(kind: .reset, occursAt: now.addingTimeInterval(6 * 86_400 + 600), style: .absoluteDateTime)
                            ),
                            Stage3QuotaMetricProjection(
                                id: "openai-spark-weekly",
                                title: "Codex Spark",
                                windowBadge: "每周",
                                value: .percent(value: 99, direction: .remaining),
                                event: Stage3TimeEvent(kind: .reset, occursAt: now.addingTimeInterval(6 * 86_400 + 9 * 3_600 + 36 * 60), style: .absoluteDateTime)
                            ),
                            Stage3QuotaMetricProjection(
                                id: "openai-reset-credit",
                                title: "Full reset",
                                windowBadge: "重置权益",
                                value: .entitlement(availableCount: 1),
                                event: Stage3TimeEvent(kind: .entitlementExpiry, occursAt: now.addingTimeInterval(3 * 86_400), style: .absoluteDateTime)
                            )
                        ]
                    )
                ],
                capturedAt: now,
                origin: origin
            ),
            Stage3ProviderProjection(
                id: .miniMax,
                rowState: defaultState,
                planLevel: hideQuota ? nil : Stage3PlanBadge(
                    value: "Max",
                    origin: .inferred(ruleID: "mmx-1.0.19-video-daily-total-3")
                ),
                products: hideQuota ? [] : [
                    Stage3QuotaProductProjection(
                        id: "minimax-token-plan",
                        metrics: [
                            Stage3QuotaMetricProjection(
                                id: "minimax-short",
                                title: "短周期",
                                windowBadge: "5 小时",
                                value: .percent(value: 4, direction: .used),
                                event: Stage3TimeEvent(kind: .reset, occursAt: now.addingTimeInterval(2 * 3_600 + 18 * 60), style: .relativeCountdown)
                            ),
                            Stage3QuotaMetricProjection(
                                id: "minimax-weekly",
                                title: "每周",
                                value: .unlimited
                            ),
                            Stage3QuotaMetricProjection(
                                id: "minimax-video-daily",
                                title: "视频赠送",
                                windowBadge: "当日",
                                value: .usedCount(used: 0, total: 3, unit: "次"),
                                event: Stage3TimeEvent(kind: .reset, occursAt: now.addingTimeInterval(16 * 3_600 + 18 * 60), style: .relativeCountdown)
                            )
                        ]
                    )
                ],
                capturedAt: now,
                origin: origin
            ),
            Stage3ProviderProjection(
                id: .ark,
                rowState: arkState(scenario: scenario, now: now),
                dataState: scenario == .arkWarningFresh ? .fresh(asOf: now) : .unknown,
                loginMethod: .sso,
                products: hideQuota ? [] : arkProducts(now: now),
                capturedAt: now,
                origin: origin
            )
        ]
    }

    public static func memoryProjection(
        now: Date,
        scenario: Stage3FixtureScenario
    ) -> Stage3MemoryProjection {
        let gib = 1_073_741_824.0
        let fields: [MemorySummaryField] = [
            MemorySummaryField(id: .physical, availability: .available(bytes: UInt64(16.00 * gib)), provenance: .directSystemValue),
            MemorySummaryField(id: .used, availability: .available(bytes: UInt64(14.10 * gib)), provenance: .derivedSystemEstimate(formulaID: "hostvm-summary-v1.used")),
            MemorySummaryField(id: .cachedFiles, availability: .available(bytes: UInt64(1.84 * gib)), provenance: .derivedSystemEstimate(formulaID: "hostvm-summary-v1.cached")),
            MemorySummaryField(id: .swapUsed, availability: .available(bytes: UInt64(17.27 * gib)), provenance: .directSystemValue),
            MemorySummaryField(id: .appMemory, availability: .available(bytes: UInt64(3.36 * gib)), provenance: .derivedSystemEstimate(formulaID: "hostvm-summary-v1.app")),
            MemorySummaryField(id: .wired, availability: .available(bytes: UInt64(4.24 * gib)), provenance: .directSystemValue),
            MemorySummaryField(id: .compressed, availability: .available(bytes: UInt64(5.76 * gib)), provenance: .directSystemValue)
        ]

        let pointCount = 72
        let history = (0..<pointCount).map { index -> MemoryTrendPoint in
            let progress = Double(index) / Double(pointCount - 1)
            let wave = sin(progress * .pi * 5) * 0.012 + sin(progress * .pi * 17) * 0.004
            let drift = 0.60 - progress * 0.025
            let pressureRatio = min(max(drift + wave, 0), 1)
            return MemoryTrendPoint(
                id: index,
                timestamp: now.addingTimeInterval(-30 * 60 + Double(index) * (30 * 60 / Double(pointCount - 1))),
                loadRatio: nil,
                pressureRatio: pressureRatio,
                pressure: .warning
            )
        }

        return Stage3MemoryProjection(
            pressure: .warning,
            fields: fields,
            history: history,
            capturedAt: now,
            origin: .fixture(scenarioID: scenario.rawValue, fixedNow: now)
        )
    }

    private static func arkState(
        scenario: Stage3FixtureScenario,
        now: Date
    ) -> Stage3ProviderRowState {
        switch scenario {
        case .firstRunDetecting: .detecting
        case .acceptedVisualFresh: .connected
        case .arkWarningFresh: .authenticationWarning
        case .arkExpiredStale: .expired(lastSuccessAt: now.addingTimeInterval(-2 * 3_600))
        }
    }

    private static func arkProducts(now: Date) -> [Stage3QuotaProductProjection] {
        [
            Stage3QuotaProductProjection(
                id: "ark-agent",
                title: "Agent Plan",
                planLevel: Stage3PlanBadge(value: "Medium", origin: .reported(sourceField: "tier")),
                metrics: [
                    arkPercent(id: "ark-agent-short", title: "短周期", badge: "5 小时", value: 46, seconds: 4 * 3_600 + 32 * 60, now: now, kind: .reset),
                    arkPercent(id: "ark-agent-weekly", title: "每周", value: 13, seconds: 6 * 86_400 + 16 * 3_600 + 42 * 60, now: now, kind: .reset),
                    arkPercent(id: "ark-agent-monthly", title: "每月", value: 39, seconds: 25 * 86_400 + 16 * 3_600 + 42 * 60, now: now, kind: .reset)
                ]
            ),
            Stage3QuotaProductProjection(
                id: "ark-coding",
                title: "Coding Plan",
                planLevel: Stage3PlanBadge(value: "Pro", origin: .reported(sourceField: "plans.get.tier")),
                metrics: [
                    arkPercent(id: "ark-coding-session", title: "短周期", badge: "当前会话", value: 0, seconds: nil, now: now, kind: .refresh),
                    arkPercent(id: "ark-coding-weekly", title: "每周", value: 0, seconds: 6 * 86_400 + 16 * 3_600 + 42 * 60, now: now, kind: .refresh),
                    arkPercent(id: "ark-coding-monthly", title: "每月", value: 13.03, seconds: 8 * 86_400 + 16 * 3_600 + 42 * 60, now: now, kind: .refresh)
                ]
            )
        ]
    }

    private static func arkPercent(
        id: String,
        title: String,
        badge: String? = nil,
        value: Double,
        seconds: TimeInterval?,
        now: Date,
        kind: Stage3TimeEventKind
    ) -> Stage3QuotaMetricProjection {
        Stage3QuotaMetricProjection(
            id: id,
            title: title,
            windowBadge: badge,
            value: .percent(value: value, direction: .used),
            event: seconds.map { Stage3TimeEvent(kind: kind, occursAt: now.addingTimeInterval($0), style: .relativeCountdown) }
        )
    }
}
#endif
