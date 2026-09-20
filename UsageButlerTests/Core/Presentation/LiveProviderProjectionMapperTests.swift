import Foundation
import UsageButlerDomain
import XCTest
@testable import UsageButlerCore

final class LiveProviderProjectionMapperTests: XCTestCase {
    private let fixedNow = Date(timeIntervalSince1970: 1_786_400_000)
    private let fetchedAt = Date(timeIntervalSince1970: 1_786_300_000)

    func testRuntimeOriginIsNotFixtureAndDisabledProviderIsFiltered() throws {
        let state = providerState(providerID: .openAI, quota: nil)
        let enabled = ProviderProjection(
            revision: 7,
            isEnabled: true,
            phase: .running,
            state: state
        )

        let runtime = try XCTUnwrap(
            LiveProviderProjectionMapper.map(enabled, now: fixedNow)
        )
        XCTAssertEqual(runtime.origin, .runtime)
        XCTAssertFalse(runtime.origin.isFixture)
        XCTAssertEqual(runtime.capturedAt, fixedNow)

        let disabled = ProviderProjection(
            revision: 8,
            isEnabled: false,
            phase: .running,
            state: state
        )
        XCTAssertNil(LiveProviderProjectionMapper.map(disabled, now: fixedNow))
    }

    func testOpenAIComplementsRawUsedAndSparkPresenceComesOnlyFromActualBucket() throws {
        let pro = reportedPlan("pro", field: "account/read.account.planType")
        let codex = product(
            providerID: .openAI,
            sourceProductID: "codex",
            titleKey: "provider.openai.product.codex",
            canonicalOrder: 0,
            plan: pro,
            metrics: [
                metric(
                    providerID: .openAI,
                    productID: "codex",
                    bucketID: "codex",
                    sourceMetricID: "primary.used_percent",
                    sourceLabel: "Codex",
                    windowKind: .weekly,
                    value: .percent(
                        DirectedPercent(sourceValue: 40, sourceDirection: .used)
                    ),
                    eventKind: .reset
                )
            ]
        )
        let futureBucket = product(
            providerID: .openAI,
            sourceProductID: "future-bucket",
            titleKey: "provider.openai.product.provider-defined",
            canonicalOrder: 100,
            metrics: [
                metric(
                    providerID: .openAI,
                    productID: "future-bucket",
                    bucketID: "future-bucket",
                    sourceMetricID: "secondary.used_percent",
                    sourceLabel: "Future Bucket",
                    windowKind: .providerDefined("openai.duration.90m"),
                    duration: 90 * 60,
                    value: .percent(
                        DirectedPercent(sourceValue: 25, sourceDirection: .used)
                    ),
                    eventKind: .reset
                )
            ]
        )

        let withoutSpark = LiveProviderProjectionMapper.map(
            providerState(
                providerID: .openAI,
                quota: quota(providerID: .openAI, products: [codex, futureBucket])
            ),
            now: fixedNow
        )
        XCTAssertEqual(
            withoutSpark.planLevel,
            Stage3PlanBadge(
                value: "Pro",
                origin: .reported(sourceField: "account/read.account.planType")
            )
        )
        let withoutSparkMetrics = withoutSpark.products.flatMap(\.metrics)
        XCTAssertEqual(withoutSparkMetrics.map(\.title), ["Codex", "Future Bucket"])
        XCTAssertFalse(withoutSparkMetrics.contains { $0.title == "Codex Spark" })
        XCTAssertEqual(withoutSparkMetrics[1].windowBadge, "90 分钟")
        guard case let .percent(codexRemaining, codexDirection) = withoutSparkMetrics[0].value,
              case let .percent(futureRemaining, futureDirection) = withoutSparkMetrics[1].value else {
            return XCTFail("OpenAI finite buckets must project remaining percentages")
        }
        XCTAssertEqual(codexRemaining, 60)
        XCTAssertEqual(codexDirection, .remaining)
        XCTAssertEqual(futureRemaining, 75)
        XCTAssertEqual(futureDirection, .remaining)

        let spark = product(
            providerID: .openAI,
            sourceProductID: "codex_bengalfox",
            titleKey: "provider.openai.product.spark",
            canonicalOrder: 1,
            metrics: [
                metric(
                    providerID: .openAI,
                    productID: "codex_bengalfox",
                    bucketID: "codex_bengalfox",
                    sourceMetricID: "primary.used_percent",
                    sourceLabel: "GPT-Codex-Spark",
                    windowKind: .weekly,
                    value: .percent(
                        DirectedPercent(sourceValue: 1, sourceDirection: .used)
                    ),
                    eventKind: .reset
                )
            ]
        )
        let withSpark = LiveProviderProjectionMapper.map(
            providerState(
                providerID: .openAI,
                quota: quota(providerID: .openAI, products: [codex, spark])
            ),
            now: fixedNow
        )
        XCTAssertEqual(
            withSpark.products.flatMap(\.metrics).filter { $0.title == "Codex Spark" }.count,
            1
        )
    }

    func testOpenAIResetEntitlementUsesEarliestAvailableExpiryAndZeroIsHidden() throws {
        let winnerExpiry = fetchedAt.addingTimeInterval(200)
        let reset = resetEntitlement(
            availableCount: 3,
            details: [
                ResetEntitlementDetail(
                    sourceID: "later",
                    status: "available",
                    grantedAt: fetchedAt.addingTimeInterval(1),
                    expiresAt: fetchedAt.addingTimeInterval(300),
                    title: "Later reset"
                ),
                ResetEntitlementDetail(
                    sourceID: "consumed",
                    status: "consumed",
                    grantedAt: nil,
                    expiresAt: fetchedAt.addingTimeInterval(10),
                    title: "Consumed"
                ),
                ResetEntitlementDetail(
                    sourceID: "winner",
                    status: "AVAILABLE",
                    grantedAt: fetchedAt.addingTimeInterval(2),
                    expiresAt: winnerExpiry,
                    title: "Full reset"
                )
            ]
        )
        let projection = LiveProviderProjectionMapper.map(
            providerState(
                providerID: .openAI,
                quota: quota(
                    providerID: .openAI,
                    products: [],
                    resetEntitlements: [reset]
                )
            ),
            now: fixedNow
        )
        let metric = try XCTUnwrap(projection.products.first?.metrics.first)
        XCTAssertEqual(metric.title, "Full reset")
        XCTAssertEqual(metric.value, .entitlement(availableCount: 3))
        XCTAssertEqual(
            metric.event,
            Stage3TimeEvent(
                kind: .entitlementExpiry,
                occursAt: winnerExpiry,
                style: .absoluteDateTime
            )
        )
        XCTAssertEqual(
            metric.resetEntitlements,
            [
                Stage3ResetEntitlementItem(
                    id: "winner",
                    title: "Full reset",
                    expiresAt: winnerExpiry
                ),
                Stage3ResetEntitlementItem(
                    id: "later",
                    title: "Later reset",
                    expiresAt: fetchedAt.addingTimeInterval(300)
                )
            ]
        )

        let noDetailsProjection = LiveProviderProjectionMapper.map(
            providerState(
                providerID: .openAI,
                quota: quota(
                    providerID: .openAI,
                    products: [],
                    resetEntitlements: [resetEntitlement(availableCount: 2, details: nil)]
                )
            ),
            now: fixedNow
        )
        XCTAssertNil(noDetailsProjection.products.first?.metrics.first?.resetEntitlements)

        let zeroProjection = LiveProviderProjectionMapper.map(
            providerState(
                providerID: .openAI,
                quota: quota(
                    providerID: .openAI,
                    products: [],
                    resetEntitlements: [resetEntitlement(availableCount: 0, details: nil)]
                )
            ),
            now: fixedNow
        )
        XCTAssertTrue(zeroProjection.products.isEmpty)
    }

    func testFullFailureRetainedSnapshotRemainsAllStaleWithoutPartialProjection() throws {
        let stale = FreshnessState.stale(asOf: fetchedAt, evaluatedAt: fixedNow)
        let codex = product(
            providerID: .openAI,
            sourceProductID: "codex",
            titleKey: "provider.openai.product.codex",
            canonicalOrder: 0,
            metrics: [
                metric(
                    providerID: .openAI,
                    productID: "codex",
                    bucketID: "codex",
                    sourceMetricID: "primary.used_percent",
                    sourceLabel: "Codex",
                    windowKind: .weekly,
                    value: .percent(
                        DirectedPercent(sourceValue: 40, sourceDirection: .used)
                    ),
                    eventKind: .reset,
                    freshness: stale
                )
            ],
            freshness: stale
        )
        let reset = resetEntitlement(
            availableCount: 1,
            details: nil,
            freshness: stale
        )
        let state = providerState(
            providerID: .openAI,
            quota: quota(
                providerID: .openAI,
                products: [codex],
                resetEntitlements: [reset]
            ),
            freshness: stale,
            failure: ProviderFailure(
                code: .networkUnavailable,
                retryClass: .backoff,
                userMessageKey: "provider.failure.network-unavailable",
                diagnosticCode: "fixture.network",
                recovery: .retry
            )
        )

        let projection = LiveProviderProjectionMapper.map(state, now: fixedNow)
        XCTAssertEqual(projection.dataState, .stale(asOf: fetchedAt))
        XCTAssertNil(projection.partialDataState)
        XCTAssertEqual(projection.failureCode, .networkUnavailable)
        let metricStates = projection.products.flatMap(\.metrics).compactMap(\.dataState)
        XCTAssertFalse(metricStates.isEmpty)
        XCTAssertTrue(metricStates.allSatisfy { $0 == .stale(asOf: fetchedAt) })
    }

    func testMiniMaxUsesFiniteRemainingComplementShowsUsedVideoAndHidesWeeklyVideo() throws {
        let plan = PlanLevelObservation(
            value: "Max",
            origin: .inferred(
                ruleID: "minimax-video-daily-v1",
                catalogID: "catalog-v1",
                sourceVersion: "1.0.19",
                evidenceFields: ["video.current.total"]
            ),
            contractVersion: "minimax-plan-inference-v1",
            fetchedAt: fetchedAt
        )
        let tokenPlan = product(
            providerID: .miniMax,
            sourceProductID: "token-plan",
            titleKey: "provider.minimax.product.token-plan",
            canonicalOrder: 0,
            plan: plan,
            metrics: [
                metric(
                    providerID: .miniMax,
                    productID: "token-plan",
                    bucketID: "general.current_interval",
                    sourceMetricID: "remaining_percent",
                    sourceLabel: "general",
                    windowKind: .providerDefined("current_interval"),
                    duration: 5 * 60 * 60,
                    value: .percent(
                        DirectedPercent(sourceValue: 96, sourceDirection: .remaining)
                    ),
                    eventKind: .reset
                ),
                metric(
                    providerID: .miniMax,
                    productID: "token-plan",
                    bucketID: "general.weekly",
                    sourceMetricID: "remaining_percent",
                    sourceLabel: "general",
                    windowKind: .weekly,
                    value: .unlimited,
                    eventKind: .reset
                ),
                metric(
                    providerID: .miniMax,
                    productID: "token-plan",
                    bucketID: "video.current_interval",
                    sourceMetricID: "usage_count",
                    sourceLabel: "video",
                    windowKind: .providerDefined("current_interval"),
                    value: .count(
                        DirectedCount(
                            sourceValue: 1,
                            total: 3,
                            sourceDirection: .used,
                            unit: "count"
                        )
                    ),
                    eventKind: .reset
                ),
                metric(
                    providerID: .miniMax,
                    productID: "token-plan",
                    bucketID: "video.weekly",
                    sourceMetricID: "usage_count",
                    sourceLabel: "video",
                    windowKind: .weekly,
                    value: .count(
                        DirectedCount(
                            sourceValue: 7,
                            total: 21,
                            sourceDirection: .used,
                            unit: "count"
                        )
                    ),
                    eventKind: .reset
                )
            ]
        )

        let projection = LiveProviderProjectionMapper.map(
            providerState(
                providerID: .miniMax,
                quota: quota(providerID: .miniMax, products: [tokenPlan])
            ),
            now: fixedNow
        )
        XCTAssertEqual(
            projection.planLevel,
            Stage3PlanBadge(
                value: "Max",
                origin: .inferred(ruleID: "minimax-video-daily-v1")
            )
        )
        let metrics = try XCTUnwrap(projection.products.first).metrics
        XCTAssertEqual(metrics.count, 3)
        XCTAssertFalse(metrics.contains { $0.id.contains("video.weekly") })

        guard case let .percent(used, direction) = metrics[0].value else {
            return XCTFail("Finite MiniMax remaining must project a used complement")
        }
        XCTAssertEqual(used, 4)
        XCTAssertEqual(direction, .used)
        XCTAssertNil(metrics[0].windowBadge, "Duration alone must not invent a 5-hour label")
        XCTAssertEqual(metrics[1].value, .unlimited)
        XCTAssertNil(metrics[1].value.progressFraction)
        XCTAssertEqual(
            metrics[2].value,
            .usedCount(used: 1, total: 3, unit: "次")
        )
        XCTAssertEqual(metrics[2].windowBadge, "当日")
    }

    func testArkKeepsProductPresencePlanOriginsUsedDirectionAndProductTimeCopy() throws {
        let agent = product(
            providerID: .ark,
            sourceProductID: "agent-plan",
            titleKey: "provider.ark.product.agent-plan",
            canonicalOrder: 0,
            plan: reportedPlan("medium", field: "items[].tier"),
            metrics: [
                metric(
                    providerID: .ark,
                    productID: "agent-plan",
                    bucketID: "5h",
                    sourceMetricID: "usage",
                    sourceLabel: "5h",
                    windowKind: .shortCycle,
                    duration: 5 * 60 * 60,
                    value: .usedTotal(
                        UsedTotalAmount(
                            used: 400,
                            total: 10_000,
                            unit: "AFP",
                            sourcePercent: DirectedPercent(
                                sourceValue: 4.25,
                                sourceDirection: .used
                            )
                        )
                    ),
                    eventKind: .reset
                ),
                metric(
                    providerID: .ark,
                    productID: "agent-plan",
                    bucketID: "weekly",
                    sourceMetricID: "usage",
                    sourceLabel: "weekly",
                    windowKind: .weekly,
                    value: .usedTotal(
                        UsedTotalAmount(
                            used: 25,
                            total: 100,
                            unit: "AFP",
                            sourcePercent: nil
                        )
                    ),
                    eventKind: .reset
                )
            ]
        )
        let coding = product(
            providerID: .ark,
            sourceProductID: "coding-plan",
            titleKey: "provider.ark.product.coding-plan",
            canonicalOrder: 1,
            plan: reportedPlan("pro", field: "plans.get.tier"),
            metrics: [
                metric(
                    providerID: .ark,
                    productID: "coding-plan",
                    bucketID: "weekly",
                    sourceMetricID: "usage",
                    sourceLabel: "weekly",
                    windowKind: .weekly,
                    value: .percent(
                        DirectedPercent(sourceValue: 15, sourceDirection: .used)
                    ),
                    eventKind: .refresh
                )
            ]
        )
        let absent = product(
            providerID: .ark,
            sourceProductID: "retired-plan",
            titleKey: "provider.ark.product.other",
            canonicalOrder: 2,
            presence: authoritativePresence(
                .notEntitled,
                providerID: .ark,
                operationID: "ark.usage.plan.retired-plan"
            ),
            metrics: []
        )
        let originalQuota = quota(providerID: .ark, products: [agent, coding, absent])
        let projection = LiveProviderProjectionMapper.map(
            providerState(providerID: .ark, quota: originalQuota),
            now: fixedNow
        )

        XCTAssertEqual(projection.products.map(\.title), ["Agent Plan", "Coding Plan"])
        XCTAssertEqual(
            projection.products[0].planLevel,
            Stage3PlanBadge(
                value: "Medium",
                origin: .reported(sourceField: "items[].tier")
            )
        )
        XCTAssertEqual(
            projection.products[1].planLevel,
            Stage3PlanBadge(
                value: "Pro",
                origin: .reported(sourceField: "plans.get.tier")
            )
        )

        let agentMetrics = projection.products[0].metrics
        guard case let .percent(reported, reportedDirection) = agentMetrics[0].value,
              case let .percent(derived, derivedDirection) = agentMetrics[1].value else {
            return XCTFail("Ark usedTotal values must project as used percentages")
        }
        XCTAssertEqual(reported, 4.25, "Reported sourcePercent takes precedence over used/total")
        XCTAssertEqual(reportedDirection, .used)
        XCTAssertEqual(derived, 25, "Missing sourcePercent derives used/total without mutating Domain")
        XCTAssertEqual(derivedDirection, .used)
        XCTAssertEqual(agentMetrics[0].event?.kind, .reset)
        XCTAssertEqual(projection.products[1].metrics[0].event?.kind, .refresh)
        XCTAssertEqual(
            originalQuota.products[0].metrics[1].value,
            agent.metrics[1].value,
            "The pure fallback projection must leave the sourcePercent omission intact"
        )
        XCTAssertEqual(
            originalQuota.products[0].metrics[1].provenance,
            agent.metrics[1].provenance,
            "used/total fallback is presentation-only and must not replace Domain provenance"
        )
    }

    func testUnknownProductRetainsHistoricalRowsWhileAuthoritativeNotEntitledHides() throws {
        let historicalMetric = metric(
            providerID: .ark,
            productID: "coding-plan",
            bucketID: "weekly",
            sourceMetricID: "usage",
            sourceLabel: "weekly",
            windowKind: .weekly,
            value: .percent(DirectedPercent(sourceValue: 17, sourceDirection: .used)),
            eventKind: .refresh,
            freshness: .stale(asOf: fetchedAt, evaluatedAt: fixedNow)
        )
        let unknownHistorical = product(
            providerID: .ark,
            sourceProductID: "coding-plan",
            titleKey: "provider.ark.product.coding-plan",
            canonicalOrder: 1,
            presence: .unknown,
            metrics: [historicalMetric],
            freshness: .stale(asOf: fetchedAt, evaluatedAt: fixedNow)
        )
        let absent = product(
            providerID: .ark,
            sourceProductID: "agent-plan",
            titleKey: "provider.ark.product.agent-plan",
            canonicalOrder: 0,
            presence: authoritativePresence(
                .notEntitled,
                providerID: .ark,
                operationID: "ark.usage.plan.agent-plan"
            ),
            metrics: []
        )

        let projection = LiveProviderProjectionMapper.map(
            providerState(
                providerID: .ark,
                quota: quota(providerID: .ark, products: [absent, unknownHistorical]),
                freshness: .stale(asOf: fetchedAt, evaluatedAt: fixedNow)
            ),
            now: fixedNow
        )
        XCTAssertEqual(projection.products.map(\.title), ["Coding Plan"])
        XCTAssertEqual(projection.products[0].metrics.count, 1)
        XCTAssertEqual(projection.capturedAt, fetchedAt)
    }

    func testUnavailableMetricIsNeverFabricatedAsZero() throws {
        let unavailable = metric(
            providerID: .ark,
            productID: "coding-plan",
            bucketID: "monthly",
            sourceMetricID: "usage",
            sourceLabel: "monthly",
            windowKind: .monthly,
            value: .unavailable(reason: .missingRequiredField("periods[].percent")),
            eventKind: nil
        )
        let coding = product(
            providerID: .ark,
            sourceProductID: "coding-plan",
            titleKey: "provider.ark.product.coding-plan",
            canonicalOrder: 1,
            metrics: [unavailable]
        )
        let projection = LiveProviderProjectionMapper.map(
            providerState(
                providerID: .ark,
                quota: quota(providerID: .ark, products: [coding])
            ),
            now: fixedNow
        )

        XCTAssertEqual(projection.products.count, 1)
        XCTAssertTrue(projection.products[0].metrics.isEmpty)
    }

    func testDetectingRequiresLoginExpiredAndUnavailableRowsRetainLastGood() throws {
        let codex = product(
            providerID: .openAI,
            sourceProductID: "codex",
            titleKey: "provider.openai.product.codex",
            canonicalOrder: 0,
            metrics: [
                metric(
                    providerID: .openAI,
                    productID: "codex",
                    bucketID: "codex",
                    sourceMetricID: "primary.used_percent",
                    sourceLabel: "Codex",
                    windowKind: .weekly,
                    value: .percent(DirectedPercent(sourceValue: 40, sourceDirection: .used)),
                    eventKind: .reset,
                    freshness: .stale(asOf: fetchedAt, evaluatedAt: fixedNow)
                )
            ],
            freshness: .stale(asOf: fetchedAt, evaluatedAt: fixedNow)
        )
        let lastGood = quota(providerID: .openAI, products: [codex])
        let unknownEvidence = authenticationEvidence(providerID: .openAI)

        let detecting = LiveProviderProjectionMapper.map(
            providerState(
                providerID: .openAI,
                quota: lastGood,
                connection: .detecting(startedAt: fixedNow),
                freshness: .stale(asOf: fetchedAt, evaluatedAt: fixedNow)
            ),
            now: fixedNow
        )
        XCTAssertEqual(detecting.rowState, .detecting)
        XCTAssertEqual(detecting.dataState, .stale(asOf: fetchedAt))
        XCTAssertEqual(detecting.products.flatMap(\.metrics).count, 1)

        let requiresLogin = LiveProviderProjectionMapper.map(
            providerState(
                providerID: .openAI,
                quota: lastGood,
                connection: .requiresLogin(unknownEvidence),
                freshness: .stale(asOf: fetchedAt, evaluatedAt: fixedNow)
            ),
            now: fixedNow
        )
        XCTAssertEqual(requiresLogin.rowState, .requiresLogin)
        XCTAssertEqual(requiresLogin.loginMethod, .oauth)
        XCTAssertTrue(requiresLogin.hasOfficialDocumentation)
        XCTAssertTrue(requiresLogin.allowsExecutableSelection)
        XCTAssertEqual(requiresLogin.products.flatMap(\.metrics).count, 1)

        let expiredAt = fixedNow.addingTimeInterval(-60)
        let expired = LiveProviderProjectionMapper.map(
            providerState(
                providerID: .openAI,
                quota: lastGood,
                connection: .requiresLogin(unknownEvidence),
                authentication: .expired(
                    AuthenticationExpiryEvidence(
                        authority: .explicitExpiration(
                            sourceField: "account.auth.expiresAt",
                            contractVersion: "openai-v1"
                        ),
                        observedAt: expiredAt
                    )
                ),
                freshness: .stale(asOf: fetchedAt, evaluatedAt: fixedNow),
                lastSuccessAt: fetchedAt
            ),
            now: fixedNow
        )
        XCTAssertEqual(expired.rowState, .expired(lastSuccessAt: fetchedAt))
        XCTAssertEqual(expired.products.flatMap(\.metrics).count, 1)

        let unavailable = LiveProviderProjectionMapper.map(
            providerState(
                providerID: .openAI,
                quota: lastGood,
                connection: .unavailable(observedAt: fixedNow),
                freshness: .stale(asOf: fetchedAt, evaluatedAt: fixedNow)
            ),
            now: fixedNow
        )
        XCTAssertEqual(unavailable.rowState, .unavailable)
        XCTAssertEqual(unavailable.products.flatMap(\.metrics).count, 1)

        let missingExecutable = LiveProviderProjectionMapper.map(
            providerState(
                providerID: .openAI,
                quota: lastGood,
                connection: .unavailable(observedAt: fixedNow),
                freshness: .stale(asOf: fetchedAt, evaluatedAt: fixedNow),
                failure: ProviderFailure(
                    code: .missingExecutable,
                    retryClass: .afterRecovery,
                    userMessageKey: "provider.failure.missing-executable",
                    diagnosticCode: "fixture.executable.missing",
                    recovery: .selectExecutable
                )
            ),
            now: fixedNow
        )
        XCTAssertEqual(missingExecutable.failureCode, .missingExecutable)
        XCTAssertEqual(missingExecutable.dataState, .stale(asOf: fetchedAt))
    }

    func testConnectedAuthenticationWarningPreservesQuotaAndIndependentFreshness() {
        for freshness in [
            FreshnessState.fresh(asOf: fetchedAt),
            .stale(asOf: fetchedAt, evaluatedAt: fixedNow)
        ] {
            let coding = product(
                providerID: .ark,
                sourceProductID: "coding-plan",
                titleKey: "provider.ark.coding-plan",
                canonicalOrder: 0,
                metrics: [
                    metric(
                        providerID: .ark,
                        productID: "coding-plan",
                        bucketID: "weekly",
                        sourceMetricID: "percent",
                        sourceLabel: "weekly",
                        windowKind: .weekly,
                        value: .percent(DirectedPercent(sourceValue: 40, sourceDirection: .used)),
                        eventKind: .refresh,
                        freshness: freshness
                    )
                ],
                freshness: freshness
            )
            var state = providerState(
                providerID: .ark,
                quota: quota(providerID: .ark, products: [coding]),
                freshness: freshness
            )
            let healthy = LiveProviderProjectionMapper.map(state, now: fixedNow)
            state.authentication = .warning(authenticationEvidence(providerID: .ark))

            let warning = LiveProviderProjectionMapper.map(state, now: fixedNow)

            XCTAssertEqual(warning.rowState, .authenticationWarning)
            XCTAssertEqual(warning.dataState, healthy.dataState)
            XCTAssertEqual(warning.products, healthy.products)
            XCTAssertEqual(warning.products.flatMap(\.metrics).count, 1)
            XCTAssertNil(warning.failureCode)
            XCTAssertEqual(warning.loginMethod, .sso)
        }
    }

    func testOpenAIRequiresLoginTakesPriorityOverAuthenticationWarning() {
        let evidence = authenticationEvidence(providerID: .openAI)
        let projection = LiveProviderProjectionMapper.map(
            providerState(
                providerID: .openAI,
                quota: nil,
                connection: .requiresLogin(evidence),
                authentication: .warning(evidence)
            ),
            now: fixedNow
        )

        XCTAssertEqual(projection.rowState, .requiresLogin)
        XCTAssertEqual(projection.dataState, .unknown)
    }

    func testAuthenticationFailuresTakePriorityOverWarning() {
        let cases: [(FailureCode, Stage3ProviderRowState)] = [
            (.authenticationRequired, .requiresLogin),
            (.authenticationExpired, .expired(lastSuccessAt: fetchedAt))
        ]
        for (code, expected) in cases {
            let projection = LiveProviderProjectionMapper.map(
                providerState(
                    providerID: .ark,
                    quota: quota(providerID: .ark, products: []),
                    authentication: .warning(authenticationEvidence(providerID: .ark)),
                    failure: ProviderFailure(
                        code: code,
                        retryClass: .afterRecovery,
                        userMessageKey: "test.authentication",
                        diagnosticCode: "test.authentication",
                        recovery: .login(.sso)
                    )
                ),
                now: fixedNow
            )

            XCTAssertEqual(projection.rowState, expected)
            XCTAssertNil(projection.failureCode)
        }
    }

    func testAuthenticationWarningDoesNotOverrideNonConnectedStatesOrShutdown() throws {
        let cases: [(ConnectionState, Stage3ProviderRowState)] = [
            (.detecting(startedAt: fixedNow), .detecting),
            (.unavailable(observedAt: fixedNow), .unavailable),
            (.disabled, .unavailable)
        ]
        for (connection, expected) in cases {
            let state = providerState(
                providerID: .ark,
                quota: nil,
                connection: connection,
                authentication: .warning(authenticationEvidence(providerID: .ark))
            )
            XCTAssertEqual(
                LiveProviderProjectionMapper.map(state, now: fixedNow).rowState,
                expected
            )
        }

        for phase: ProviderControllerPhase in [.shuttingDown, .stopped] {
            let projection = ProviderProjection(
                revision: 1,
                isEnabled: true,
                phase: phase,
                state: providerState(
                    providerID: .ark,
                    quota: nil,
                    authentication: .warning(authenticationEvidence(providerID: .ark))
                )
            )
            XCTAssertEqual(
                try XCTUnwrap(LiveProviderProjectionMapper.map(projection, now: fixedNow)).rowState,
                .unavailable
            )
        }
    }

    func testAuthenticationWarningRetainsIndependentQuotaFailureAndActivity() {
        let projection = LiveProviderProjectionMapper.map(
            providerState(
                providerID: .ark,
                quota: quota(providerID: .ark, products: []),
                authentication: .warning(authenticationEvidence(providerID: .ark)),
                freshness: .stale(asOf: fetchedAt, evaluatedAt: fixedNow),
                failure: ProviderFailure(
                    code: .schemaMismatch,
                    retryClass: .afterRecovery,
                    userMessageKey: "test.schema",
                    diagnosticCode: "test.schema",
                    recovery: .retry
                ),
                refreshActivity: .refreshing(scope: .provider, generation: 7, startedAt: fixedNow)
            ),
            now: fixedNow
        )

        XCTAssertEqual(projection.rowState, .authenticationWarning)
        XCTAssertEqual(projection.dataState, .stale(asOf: fetchedAt))
        XCTAssertEqual(projection.failureCode, .schemaMismatch)
        XCTAssertEqual(projection.activity, .refreshing)
    }

    func testRefreshingActivityProjectsWhileRetainedDataRemainsStale() {
        let stale = FreshnessState.stale(
            asOf: fetchedAt,
            evaluatedAt: fixedNow
        )
        let projection = LiveProviderProjectionMapper.map(
            providerState(
                providerID: .openAI,
                quota: quota(providerID: .openAI, products: []),
                freshness: stale,
                refreshActivity: .refreshing(
                    scope: .provider,
                    generation: 7,
                    startedAt: fixedNow
                )
            ),
            now: fixedNow
        )

        XCTAssertEqual(projection.rowState, .connected)
        XCTAssertEqual(projection.dataState, .stale(asOf: fetchedAt))
        XCTAssertEqual(projection.activity, .refreshing)
    }

    func testPartialQuotaFailureShowsTypedReasonAndRealRetryDeadline() throws {
        let failure = ProviderFailure(code: .schemaMismatch, retryClass: .backoff,
            userMessageKey: "provider.failure.partial-schema", diagnosticCode: "minimax.adapter.response.partial_schema", recovery: .retry)
        var state = providerState(providerID: .miniMax, quota: nil, failure: failure)
        state = ProviderReducer.reduce(state: state,
            event: .gateChanged(.backoff(until: .init(nanoseconds: 160_000_000_000), attempt: 1)), now: fixedNow)
        let automatic = ProviderProjection(revision: 1, isEnabled: true, phase: .running, state: state, automaticRefresh: true)
        let visible = try XCTUnwrap(LiveProviderProjectionMapper.map(automatic, now: fixedNow,
            monotonicNow: .init(nanoseconds: 100_000_000_000)))
        XCTAssertTrue(visible.isQuotaValidationFailure)
        XCTAssertEqual(visible.retryAt, fixedNow.addingTimeInterval(60))
        XCTAssertEqual(visible.withProducts([]).retryAt, visible.retryAt)
        let manual = ProviderProjection(revision: 2, isEnabled: true, phase: .running, state: state, automaticRefresh: false)
        let manualView = try XCTUnwrap(LiveProviderProjectionMapper.map(manual, now: fixedNow,
            monotonicNow: .init(nanoseconds: 100_000_000_000)))
        XCTAssertNil(manualView.retryAt)
        XCTAssertEqual(manualView.automaticRetry, false)
    }

    private func providerState(
        providerID: ProviderID,
        quota: ProviderQuotaData?,
        connection: ConnectionState? = nil,
        authentication: AuthenticationState? = nil,
        freshness: FreshnessState? = nil,
        lastSuccessAt: Date? = nil,
        failure: ProviderFailure? = nil,
        refreshActivity: RefreshActivity = .idle
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
            connection: connection ?? .connected(observedAt: fetchedAt),
            presence: .unknown,
            authentication: authentication ?? .healthy(evidence),
            refresh: RefreshState(
                activity: refreshActivity,
                gate: .open,
                lastAttemptAt: fixedNow,
                lastSuccessAt: lastSuccessAt ?? quota?.fetchedAt
            ),
            lastGood: quota,
            freshness: freshness ?? quota.map { .fresh(asOf: $0.fetchedAt) } ?? .unknown,
            discovery: .notStarted,
            persistence: .unknown,
            failure: failure
        )
    }

    private func quota(
        providerID: ProviderID,
        products: [QuotaProductData],
        resetEntitlements: [ResetEntitlementSummary] = []
    ) -> ProviderQuotaData {
        ProviderQuotaData(
            providerID: providerID,
            source: source(providerID),
            fetchedAt: fetchedAt,
            products: products,
            balances: [],
            resetEntitlements: resetEntitlements
        )
    }

    private func product(
        providerID: ProviderID,
        sourceProductID: String,
        titleKey: String,
        canonicalOrder: Int,
        plan: PlanLevelObservation? = nil,
        presence: PresenceState? = nil,
        metrics: [QuotaMetric],
        freshness: FreshnessState? = nil
    ) -> QuotaProductData {
        QuotaProductData(
            id: ProductID(providerID: providerID, sourceProductID: sourceProductID),
            sourceProductID: sourceProductID,
            titleKey: titleKey,
            canonicalOrder: canonicalOrder,
            planLevel: plan,
            state: nodeState(
                presence: presence ?? authoritativePresence(
                    .entitled,
                    providerID: providerID,
                    operationID: "test.\(sourceProductID)"
                ),
                freshness: freshness ?? .fresh(asOf: fetchedAt)
            ),
            metrics: metrics
        )
    }

    private func metric(
        providerID: ProviderID,
        productID: String,
        bucketID: String,
        sourceMetricID: String,
        sourceLabel: String?,
        windowKind: QuotaWindowKind,
        duration: TimeInterval? = nil,
        value: QuotaMetricValue,
        eventKind: QuotaTimeEvent.Kind?,
        freshness: FreshnessState? = nil
    ) -> QuotaMetric {
        let identity = MetricSourceIdentity(
            providerID: providerID,
            sourceProductID: productID,
            sourceBucketID: bucketID,
            sourceMetricID: sourceMetricID
        )
        return QuotaMetric(
            id: MetricID(sourceIdentity: identity),
            sourceMetricID: sourceMetricID,
            sourceLabel: sourceLabel,
            window: QuotaWindow(
                kind: windowKind,
                duration: duration,
                startsAt: nil,
                endsAt: nil,
                timeEvent: eventKind.map {
                    QuotaTimeEvent(
                        kind: $0,
                        occursAt: fixedNow.addingTimeInterval(3_600)
                    )
                }
            ),
            value: value,
            sourceStatus: nil,
            provenance: MetricProvenance(
                sourceIdentity: identity,
                providerSource: source(providerID),
                fetchedAt: fetchedAt
            ),
            state: nodeState(
                presence: .unknown,
                freshness: freshness ?? .fresh(asOf: fetchedAt)
            )
        )
    }

    private func resetEntitlement(
        availableCount: Decimal,
        details: [ResetEntitlementDetail]?,
        freshness: FreshnessState? = nil
    ) -> ResetEntitlementSummary {
        let identity = MetricSourceIdentity(
            providerID: .openAI,
            sourceProductID: "account",
            sourceBucketID: "rateLimitResetCredits",
            sourceMetricID: "availableCount"
        )
        return ResetEntitlementSummary(
            availableCount: availableCount,
            details: details,
            provenance: MetricProvenance(
                sourceIdentity: identity,
                providerSource: source(.openAI),
                fetchedAt: fetchedAt
            ),
            state: nodeState(
                presence: .unknown,
                freshness: freshness ?? .fresh(asOf: fetchedAt)
            )
        )
    }

    private func nodeState(
        presence: PresenceState,
        freshness: FreshnessState
    ) -> QuotaNodeState {
        QuotaNodeState(
            presence: presence,
            freshness: freshness,
            refresh: RefreshState(
                activity: .idle,
                gate: .open,
                lastAttemptAt: fetchedAt,
                lastSuccessAt: fetchedAt
            ),
            lastAttemptAt: fetchedAt,
            lastSuccessAt: fetchedAt,
            failure: nil
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
            observedAt: fetchedAt,
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
            observedAt: fetchedAt
        )
    }

    private func reportedPlan(_ value: String, field: String) -> PlanLevelObservation {
        PlanLevelObservation(
            value: value,
            origin: .reported(sourceField: field),
            contractVersion: "test-plan-v1",
            fetchedAt: fetchedAt
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
}
