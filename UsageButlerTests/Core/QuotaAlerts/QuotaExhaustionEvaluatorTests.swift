import XCTest
import UsageButlerCore
import UsageButlerDomain

final class QuotaExhaustionEvaluatorTests: XCTestCase {
    // MARK: - percent

    func testPercentUsedAtHundredIsExhausted() {
        let findings = evaluate(
            .percent(DirectedPercent(sourceValue: 100, sourceDirection: .used))
        )
        XCTAssertEqual(findings.count, 1)
        XCTAssertEqual(findings[0].usageSummary, "已用 100%")
    }

    func testPercentUsedAboveHundredIsExhausted() {
        let findings = evaluate(
            .percent(DirectedPercent(sourceValue: 120, sourceDirection: .used))
        )
        XCTAssertEqual(findings.count, 1)
        XCTAssertEqual(findings[0].usageSummary, "已用 120%")
    }

    func testPercentUsedBelowHundredIsNotExhausted() {
        XCTAssertTrue(evaluate(.percent(DirectedPercent(sourceValue: 99.9, sourceDirection: .used))).isEmpty)
    }

    func testPercentRemainingAtZeroIsExhausted() {
        let findings = evaluate(
            .percent(DirectedPercent(sourceValue: 0, sourceDirection: .remaining))
        )
        XCTAssertEqual(findings.count, 1)
        XCTAssertEqual(findings[0].usageSummary, "剩余 0%")
    }

    func testPercentRemainingAboveZeroIsNotExhausted() {
        XCTAssertTrue(evaluate(.percent(DirectedPercent(sourceValue: 5, sourceDirection: .remaining))).isEmpty)
    }

    func testPercentNeutralIsNeverExhausted() {
        XCTAssertTrue(evaluate(.percent(DirectedPercent(sourceValue: 100, sourceDirection: .neutral))).isEmpty)
        XCTAssertTrue(evaluate(.percent(DirectedPercent(sourceValue: 0, sourceDirection: .neutral))).isEmpty)
    }

    // MARK: - count

    func testCountRemainingAtZeroIsExhausted() {
        let findings = evaluate(
            .count(DirectedCount(sourceValue: 0, total: 10, sourceDirection: .remaining, unit: "次"))
        )
        XCTAssertEqual(findings.count, 1)
        XCTAssertEqual(findings[0].usageSummary, "剩余 0 次")
    }

    func testCountRemainingAboveZeroIsNotExhausted() {
        XCTAssertTrue(evaluate(.count(DirectedCount(sourceValue: 1, total: 10, sourceDirection: .remaining, unit: "次"))).isEmpty)
    }

    func testCountUsedReachingTotalIsExhausted() {
        let findings = evaluate(
            .count(DirectedCount(sourceValue: 10, total: 10, sourceDirection: .used, unit: "次"))
        )
        XCTAssertEqual(findings.count, 1)
        XCTAssertEqual(findings[0].usageSummary, "已用 10/10 次")
    }

    func testCountUsedWithoutTotalIsNotExhausted() {
        XCTAssertTrue(evaluate(.count(DirectedCount(sourceValue: 10, total: nil, sourceDirection: .used, unit: "次"))).isEmpty)
    }

    func testCountUsedBelowTotalIsNotExhausted() {
        XCTAssertTrue(evaluate(.count(DirectedCount(sourceValue: 9, total: 10, sourceDirection: .used, unit: "次"))).isEmpty)
    }

    // MARK: - usedTotal

    func testUsedTotalAtTotalIsExhausted() {
        let findings = evaluate(
            .usedTotal(UsedTotalAmount(used: 5, total: 5, unit: "美元", sourcePercent: nil))
        )
        XCTAssertEqual(findings.count, 1)
        XCTAssertEqual(findings[0].usageSummary, "已用 5/5 美元")
    }

    func testUsedTotalBelowTotalIsNotExhausted() {
        XCTAssertTrue(evaluate(.usedTotal(UsedTotalAmount(used: 4, total: 5, unit: "美元", sourcePercent: nil))).isEmpty)
    }

    // MARK: - never-exhausted value kinds

    func testUnlimitedAbsoluteAndUnavailableAreNeverExhausted() {
        let data = QuotaAlertFixture.quotaData(
            products: [
                QuotaAlertFixture.product(metrics: [
                    QuotaAlertFixture.metric(metricID: "u1", value: .unlimited),
                    QuotaAlertFixture.metric(metricID: "a1", value: .absolute(value: 0, unit: "美元", direction: .remaining)),
                    QuotaAlertFixture.metric(
                        metricID: "n1",
                        value: .unavailable(reason: .notReported)
                    )
                ])
            ]
        )
        XCTAssertTrue(QuotaExhaustionEvaluator.findings(in: data).isEmpty)
    }

    // MARK: - reset entitlements

    func testZeroResetEntitlementIsExhausted() {
        let data = QuotaAlertFixture.quotaData(
            resetEntitlements: [QuotaAlertFixture.entitlement(availableCount: 0)]
        )
        let findings = QuotaExhaustionEvaluator.findings(in: data)
        XCTAssertEqual(findings.count, 1)
        XCTAssertEqual(findings[0].usageSummary, "重置权益可用 0 次")
        XCTAssertEqual(findings[0].productLabel, "每日重置包")
        XCTAssertEqual(findings[0].cycleKey, "expiry:\(QuotaAlertFixture.resetDate.timeIntervalSince1970)")
        XCTAssertEqual(findings[0].resetAt, QuotaAlertFixture.resetDate)
    }

    func testNonZeroResetEntitlementIsNotExhausted() {
        let data = QuotaAlertFixture.quotaData(
            resetEntitlements: [QuotaAlertFixture.entitlement(availableCount: 1)]
        )
        XCTAssertTrue(QuotaExhaustionEvaluator.findings(in: data).isEmpty)
    }

    // MARK: - balances

    func testZeroBalanceIsExhausted() {
        let data = QuotaAlertFixture.quotaData(
            balances: [QuotaAlertFixture.balance(amount: 0)]
        )
        let findings = QuotaExhaustionEvaluator.findings(in: data)
        XCTAssertEqual(findings.count, 1)
        XCTAssertEqual(findings[0].usageSummary, "余额 0 美元")
        XCTAssertEqual(findings[0].productLabel, "余额")
        XCTAssertEqual(findings[0].cycleKey, "unknown")
    }

    func testPositiveBalanceIsNotExhausted() {
        let data = QuotaAlertFixture.quotaData(
            balances: [QuotaAlertFixture.balance(amount: 12.5)]
        )
        XCTAssertTrue(QuotaExhaustionEvaluator.findings(in: data).isEmpty)
    }

    // MARK: - statuses (recovery direction)

    func testHealthyStatusesCarryCurrentUsageSummaries() {
        let data = QuotaAlertFixture.quotaData(
            products: [
                QuotaAlertFixture.product(metrics: [
                    QuotaAlertFixture.metric(metricID: "p1", value: .percent(DirectedPercent(sourceValue: 42, sourceDirection: .used))),
                    QuotaAlertFixture.metric(metricID: "p2", value: .percent(DirectedPercent(sourceValue: 30, sourceDirection: .remaining))),
                    QuotaAlertFixture.metric(metricID: "c1", value: .count(DirectedCount(sourceValue: 5, total: 10, sourceDirection: .remaining, unit: "次"))),
                    QuotaAlertFixture.metric(metricID: "c2", value: .count(DirectedCount(sourceValue: 3, total: 10, sourceDirection: .used, unit: "次"))),
                    QuotaAlertFixture.metric(metricID: "t1", value: .usedTotal(UsedTotalAmount(used: 4, total: 5, unit: "美元", sourcePercent: nil)))
                ])
            ]
        )
        let summaries = summariesByKey(data)
        XCTAssertEqual(summaries["p1"], "已用 42%")
        XCTAssertEqual(summaries["p2"], "剩余 30%")
        XCTAssertEqual(summaries["c1"], "剩余 5 次")
        XCTAssertEqual(summaries["c2"], "已用 3/10 次")
        XCTAssertEqual(summaries["t1"], "已用 4/5 美元")
        XCTAssertTrue(QuotaExhaustionEvaluator.statuses(in: data).allSatisfy { !$0.isExhausted })
    }

    func testUnavailableYieldsNoStatusAtAll() {
        let data = QuotaAlertFixture.quotaData(
            products: [
                QuotaAlertFixture.product(metrics: [
                    QuotaAlertFixture.metric(metricID: "n1", value: .unavailable(reason: .notReported))
                ])
            ]
        )
        XCTAssertTrue(QuotaExhaustionEvaluator.statuses(in: data).isEmpty)
    }

    func testUnlimitedAndAbsoluteAreHealthyStatuses() {
        let data = QuotaAlertFixture.quotaData(
            products: [
                QuotaAlertFixture.product(metrics: [
                    QuotaAlertFixture.metric(metricID: "u1", value: .unlimited),
                    QuotaAlertFixture.metric(metricID: "a1", value: .absolute(value: 0, unit: "美元", direction: .remaining))
                ])
            ]
        )
        let summaries = summariesByKey(data)
        XCTAssertEqual(summaries["u1"], "无上限")
        XCTAssertEqual(summaries["a1"], "剩余 0 美元")
        XCTAssertTrue(QuotaExhaustionEvaluator.statuses(in: data).allSatisfy { !$0.isExhausted })
    }

    func testHealthyEntitlementAndBalanceStatuses() {
        let data = QuotaAlertFixture.quotaData(
            balances: [QuotaAlertFixture.balance(amount: 12.5)],
            resetEntitlements: [QuotaAlertFixture.entitlement(availableCount: 1)]
        )
        let statuses = QuotaExhaustionEvaluator.statuses(in: data)
        XCTAssertEqual(statuses.count, 2)
        XCTAssertTrue(statuses.allSatisfy { !$0.isExhausted })
        let byKey = Dictionary(uniqueKeysWithValues: statuses.map { ($0.metricKey, $0.usageSummary) })
        XCTAssertEqual(byKey["balance|3:ark|5:bal-1"], "余额 12.5 美元")
        XCTAssertEqual(byKey["entitlement|3:ark|6:prod-1|0:|5:ent-1"], "重置权益可用 1 次")
    }

    func testStaleAndUnknownNodesYieldNeitherExhaustionNorRecoveryStatuses() {
        let freshnessStates: [FreshnessState] = [
            .unknown,
            .stale(asOf: QuotaAlertFixture.date, evaluatedAt: QuotaAlertFixture.resetDate)
        ]
        for freshness in freshnessStates {
            for exhausted in [true, false] {
                var metric = QuotaAlertFixture.metric(
                    value: .percent(DirectedPercent(sourceValue: exhausted ? 100 : 42, sourceDirection: .used))
                )
                var balance = QuotaAlertFixture.balance(amount: exhausted ? 0 : 12)
                var entitlement = QuotaAlertFixture.entitlement(availableCount: exhausted ? 0 : 1)
                metric.state.freshness = freshness
                balance.state.freshness = freshness
                entitlement.state.freshness = freshness
                let data = QuotaAlertFixture.quotaData(
                    products: [QuotaAlertFixture.product(metrics: [metric])],
                    balances: [balance],
                    resetEntitlements: [entitlement]
                )

                XCTAssertTrue(
                    QuotaExhaustionEvaluator.statuses(in: data).isEmpty,
                    "Non-fresh values are evidence of neither edge: \(freshness), exhausted=\(exhausted)"
                )
            }
        }
    }

    func testFreshNodesRemainEligibleInsideMixedStaleProduct() {
        for exhausted in [true, false] {
            let freshMetric = QuotaAlertFixture.metric(
                value: .percent(DirectedPercent(sourceValue: exhausted ? 100 : 42, sourceDirection: .used))
            )
            var staleMetric = QuotaAlertFixture.exhaustedPercentMetric(metricID: "stale")
            staleMetric.state.freshness = .stale(
                asOf: QuotaAlertFixture.date,
                evaluatedAt: QuotaAlertFixture.resetDate
            )
            var product = QuotaAlertFixture.product(metrics: [freshMetric, staleMetric])
            product.state.freshness = staleMetric.state.freshness
            var unknownBalance = QuotaAlertFixture.balance(sourceBalanceID: "unknown", amount: 0)
            unknownBalance.state.freshness = .unknown
            let data = QuotaAlertFixture.quotaData(
                products: [product],
                balances: [unknownBalance, QuotaAlertFixture.balance(amount: exhausted ? 0 : 12)],
                resetEntitlements: [QuotaAlertFixture.entitlement(availableCount: exhausted ? 0 : 1)]
            )

            let statuses = QuotaExhaustionEvaluator.statuses(in: data)
            XCTAssertEqual(Set(statuses.map(\.metricKey)), [
                "metric|3:ark|6:prod-1|0:|3:m-1",
                "balance|3:ark|5:bal-1",
                "entitlement|3:ark|6:prod-1|0:|5:ent-1"
            ])
            XCTAssertTrue(statuses.allSatisfy { $0.isExhausted == exhausted })
        }
    }

    func testFindingsAreTheExhaustedSubsetOfStatuses() {
        let data = QuotaAlertFixture.quotaData(
            products: [
                QuotaAlertFixture.product(metrics: [
                    QuotaAlertFixture.metric(metricID: "m-1", value: .percent(DirectedPercent(sourceValue: 100, sourceDirection: .used))),
                    QuotaAlertFixture.metric(metricID: "m-2", value: .percent(DirectedPercent(sourceValue: 50, sourceDirection: .used)))
                ])
            ],
            balances: [QuotaAlertFixture.balance(amount: 0)]
        )
        let statuses = QuotaExhaustionEvaluator.statuses(in: data)
        let findings = QuotaExhaustionEvaluator.findings(in: data)
        XCTAssertEqual(
            Set(findings.map(\.metricKey)),
            Set(statuses.filter(\.isExhausted).map(\.metricKey))
        )
        XCTAssertEqual(findings.map(\.metricKey).sorted(), [
            "balance|3:ark|5:bal-1",
            "metric|3:ark|6:prod-1|0:|3:m-1"
        ].sorted())
    }

    // MARK: - identity and cycle keys

    func testMetricKeyUsesLengthPrefixedStableIdentity() {
        let findings = evaluate(
            .percent(DirectedPercent(sourceValue: 100, sourceDirection: .used))
        )
        XCTAssertEqual(findings[0].metricKey, "metric|3:ark|6:prod-1|0:|3:m-1")
    }

    func testEntitlementAndBalanceKeysUseOwnPrefixes() {
        let data = QuotaAlertFixture.quotaData(
            balances: [QuotaAlertFixture.balance(sourceBalanceID: "bal-1", amount: 0)],
            resetEntitlements: [QuotaAlertFixture.entitlement(availableCount: 0)]
        )
        let keys = Set(QuotaExhaustionEvaluator.findings(in: data).map(\.metricKey))
        XCTAssertEqual(keys, ["entitlement|3:ark|6:prod-1|0:|5:ent-1", "balance|3:ark|5:bal-1"])
    }

    func testWindowLabelMapping() {
        XCTAssertEqual(windowLabel(kind: .session), "当前会话")
        XCTAssertEqual(windowLabel(kind: .shortCycle), "短周期")
        XCTAssertEqual(windowLabel(kind: .weekly), "每周")
        XCTAssertEqual(windowLabel(kind: .monthly), "每月")
        // The providerDefined payload is a source slot identifier (e.g.
        // "current_interval"), never a user label; only the metric's source
        // label may surface, mirroring the UI badge rule.
        XCTAssertNil(windowLabel(kind: .providerDefined("current_interval")))
        XCTAssertEqual(
            windowLabel(kind: .providerDefined("current_interval"), sourceLabel: "自定义周期"),
            "自定义周期"
        )
        XCTAssertNil(windowLabel(kind: nil))
    }

    func testCycleKeyPrefersResetEventThenWindowStart() {
        let withReset = cycleKey(
            window: QuotaAlertFixture.window(
                timeEvent: QuotaTimeEvent(kind: .reset, occursAt: QuotaAlertFixture.resetDate)
            )
        )
        XCTAssertEqual(withReset, "reset:\(QuotaAlertFixture.resetDate.timeIntervalSince1970)")

        let withStart = cycleKey(
            window: QuotaAlertFixture.window(startsAt: QuotaAlertFixture.date)
        )
        XCTAssertEqual(withStart, "start:\(QuotaAlertFixture.date.timeIntervalSince1970)")

        XCTAssertEqual(cycleKey(window: nil), "unknown")
    }

    func testMultipleExhaustionsAggregateIntoDistinctFindings() {
        let data = QuotaAlertFixture.quotaData(
            products: [
                QuotaAlertFixture.product(
                    metrics: [QuotaAlertFixture.exhaustedPercentMetric()]
                )
            ],
            balances: [QuotaAlertFixture.balance(amount: 0)],
            resetEntitlements: [QuotaAlertFixture.entitlement(availableCount: 0)]
        )
        XCTAssertEqual(QuotaExhaustionEvaluator.findings(in: data).count, 3)
    }

    // MARK: - helpers

    private func evaluate(_ value: QuotaMetricValue) -> [QuotaExhaustionFinding] {
        let data = QuotaAlertFixture.quotaData(
            products: [
                QuotaAlertFixture.product(metrics: [QuotaAlertFixture.metric(value: value)])
            ]
        )
        return QuotaExhaustionEvaluator.findings(in: data)
    }

    /// Maps the trailing metric-ID component of each status key (with its
    /// `len:` prefix stripped) to its usage summary, so per-metric assertions
    /// stay readable.
    private func summariesByKey(_ data: ProviderQuotaData) -> [String: String] {
        Dictionary(
            uniqueKeysWithValues:
                QuotaExhaustionEvaluator.statuses(in: data)
                .map { status in
                    let tail = status.metricKey.split(separator: "|").last.map(String.init) ?? status.metricKey
                    let metricID = tail.split(separator: ":", maxSplits: 1).last.map(String.init) ?? tail
                    return (metricID, status.usageSummary)
                }
        )
    }

    private func windowLabel(
        kind: QuotaWindowKind?,
        sourceLabel: String? = nil
    ) -> String? {
        let window = kind.map { QuotaAlertFixture.window(kind: $0) }
        let data = QuotaAlertFixture.quotaData(
            products: [
                QuotaAlertFixture.product(
                    metrics: [
                        QuotaAlertFixture.metric(
                            sourceLabel: sourceLabel,
                            window: window,
                            value: .percent(
                                DirectedPercent(sourceValue: 100, sourceDirection: .used)
                            )
                        )
                    ]
                )
            ]
        )
        let findings = QuotaExhaustionEvaluator.findings(in: data)
        XCTAssertEqual(findings.count, 1)
        return findings[0].windowLabel
    }

    private func cycleKey(window: QuotaWindow?) -> String {
        let data = QuotaAlertFixture.quotaData(
            products: [
                QuotaAlertFixture.product(
                    metrics: [
                        QuotaAlertFixture.metric(
                            window: window,
                            value: .percent(
                                DirectedPercent(sourceValue: 100, sourceDirection: .used)
                            )
                        )
                    ]
                )
            ]
        )
        let findings = QuotaExhaustionEvaluator.findings(in: data)
        XCTAssertEqual(findings.count, 1)
        return findings[0].cycleKey
    }
}
