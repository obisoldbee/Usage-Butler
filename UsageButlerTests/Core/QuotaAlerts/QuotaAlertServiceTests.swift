import XCTest
import UsageButlerCore
import UsageButlerDomain

final class QuotaAlertServiceTests: XCTestCase {
    private var systemNotifier: FakeQuotaAlertNotifier {
        FakeQuotaAlertNotifier(id: "system")
    }

    private func makeService(
        channels: [QuotaAlertChannel],
        markerStore: any QuotaAlertMarkerStore = FakeQuotaAlertMarkerStore(),
        isAlertsEnabled: @escaping @Sendable () -> Bool = { true }
    ) -> QuotaAlertService {
        QuotaAlertService(
            channels: channels,
            markerStore: markerStore,
            isAlertsEnabled: isAlertsEnabled
        )
    }

    private func exhaustedProjection(
        fetchedAt: Date = QuotaAlertFixture.date,
        metrics: [QuotaMetric]? = nil,
        isEnabled: Bool = true,
        revision: UInt64 = 1
    ) -> ProviderProjection {
        QuotaAlertFixture.projection(
            lastGood: QuotaAlertFixture.quotaData(
                products: [
                    QuotaAlertFixture.product(metrics: metrics ?? [QuotaAlertFixture.exhaustedPercentMetric()])
                ],
                fetchedAt: fetchedAt
            ),
            isEnabled: isEnabled,
            revision: revision
        )
    }

    /// A healthy weekly snapshot in the NEXT cycle: same metric identity,
    /// window shape preserved, reset event moved forward.
    private func recoveredProjection(fetchedAt: Date) -> ProviderProjection {
        QuotaAlertFixture.projection(
            lastGood: QuotaAlertFixture.quotaData(
                products: [
                    QuotaAlertFixture.product(metrics: [
                        QuotaAlertFixture.metric(
                            window: QuotaAlertFixture.window(
                                kind: .weekly,
                                timeEvent: QuotaTimeEvent(
                                    kind: .reset,
                                    occursAt: QuotaAlertFixture.resetDate.addingTimeInterval(7 * 24 * 3_600)
                                )
                            ),
                            value: .percent(
                                DirectedPercent(sourceValue: 42, sourceDirection: .used)
                            )
                        )
                    ])
                ],
                fetchedAt: fetchedAt
            )
        )
    }

    private func openAIWeeklyProjection(
        remainingPercent: Decimal,
        fetchedAt: Date,
        resetAt: Date?
    ) -> ProviderProjection {
        QuotaAlertFixture.projection(
            lastGood: QuotaAlertFixture.openAIWeeklyQuotaData(
                remainingPercent: remainingPercent,
                fetchedAt: fetchedAt,
                resetAt: resetAt
            )
        )
    }

    func testFirstExhaustedSnapshotDispatchesOneAggregatedPayloadPerChannel() async {
        let system = systemNotifier
        let lark = FakeQuotaAlertNotifier(id: "lark")
        let store = FakeQuotaAlertMarkerStore()
        let service = makeService(
            channels: [
                QuotaAlertChannel(id: "system", notifier: system),
                QuotaAlertChannel(id: "lark", notifier: lark)
            ],
            markerStore: store
        )

        await service.receive(exhaustedProjection())

        let systemPayloads = await system.payloads
        let larkPayloads = await lark.payloads
        XCTAssertEqual(systemPayloads.count, 1)
        XCTAssertEqual(larkPayloads.count, 1)
        XCTAssertEqual(systemPayloads, larkPayloads, "Both channels must receive the identical payload")

        let payload = systemPayloads[0]
        XCTAssertEqual(payload.title, "额度已用完")
        XCTAssertEqual(payload.bodyLines.count, 1)
        XCTAssertTrue(
            payload.bodyLines[0].hasPrefix("火山方舟 · prod-1 · 每周：已用 100%（"),
            "body line should carry provider, product, window, and usage, got: \(payload.bodyLines[0])"
        )
        XCTAssertTrue(payload.bodyLines[0].hasSuffix(" 重置）"))

        let stored = await store.stored
        XCTAssertEqual(
            stored,
            ["metric|3:ark|6:prod-1|0:|3:m-1": "reset:\(QuotaAlertFixture.resetDate.timeIntervalSince1970)"]
        )
    }

    func testSameSnapshotReprojectionDoesNotRedispatch() async {
        let system = systemNotifier
        let service = makeService(
            channels: [QuotaAlertChannel(id: "system", notifier: system)]
        )

        await service.receive(exhaustedProjection(revision: 1))
        await service.receive(exhaustedProjection(revision: 2))

        let payloads = await system.payloads
        XCTAssertEqual(payloads.count, 1)
    }

    func testConcurrentFirstSnapshotsShareLoadAndPreserveBothProvidersMarkers() async {
        let notifier = systemNotifier
        let store = ControlledQuotaAlertMarkerStore(holdsLoads: true)
        let service = makeService(
            channels: [QuotaAlertChannel(id: "memory-only", notifier: notifier)],
            markerStore: store
        )
        let date = QuotaAlertFixture.date
        let resetAt = QuotaAlertFixture.resetDate
        let firstProjection = exhaustedProjection()
        let first = Task { await service.receive(firstProjection) }
        await store.waitUntilLoadIsBlocked()

        let second = await startReceive(
            openAIWeeklyProjection(remainingPercent: 0, fetchedAt: date, resetAt: resetAt),
            on: service
        )
        await store.releaseFirstLoad()
        await first.value
        // A buggy second load holds the old map until the first provider has
        // saved. The fixed service has only one load to release.
        await store.releaseRemainingLoads()
        await second.value

        let loadCount = await store.loadCount
        let stored = await store.stored
        XCTAssertEqual(loadCount, 1)
        XCTAssertEqual(stored.count, 3, "Both exhaustions and the OpenAI weekly baseline survive")
        XCTAssertNotNil(stored["metric|3:ark|6:prod-1|0:|3:m-1"])
        XCTAssertEqual(stored.keys.filter { $0.hasPrefix("openai-weekly-reset-observation|") }.count, 1)

        await service.receive(exhaustedProjection(fetchedAt: date.addingTimeInterval(60)))
        await service.receive(openAIWeeklyProjection(
            remainingPercent: 0, fetchedAt: date.addingTimeInterval(60), resetAt: resetAt
        ))
        let exhaustedPayloads = await notifier.payloads
        XCTAssertEqual(exhaustedPayloads.map(\.title), ["额度已用完", "额度已用完"])

        await service.receive(recoveredProjection(fetchedAt: resetAt))
        await service.receive(openAIWeeklyProjection(
            remainingPercent: 99,
            fetchedAt: resetAt,
            resetAt: resetAt.addingTimeInterval(7 * 24 * 3_600)
        ))
        await service.receive(recoveredProjection(fetchedAt: resetAt.addingTimeInterval(60)))
        await service.receive(openAIWeeklyProjection(
            remainingPercent: 99,
            fetchedAt: resetAt.addingTimeInterval(60),
            resetAt: resetAt.addingTimeInterval(7 * 24 * 3_600)
        ))
        let payloads = await notifier.payloads
        XCTAssertEqual(payloads.map(\.title), ["额度已用完", "额度已用完", "额度已重置", "额度已重置"])
        XCTAssertEqual(payloads.last?.bodyLines.count, 1)
        XCTAssertTrue(payloads.last?.bodyLines.first?.contains("剩余 99%") == true)
    }

    func testStartedReplacementWindowDispatchesResetPayloadToEveryChannel() async {
        let system = systemNotifier
        let lark = FakeQuotaAlertNotifier(id: "lark")
        let service = makeService(channels: [
            QuotaAlertChannel(id: "system", notifier: system),
            QuotaAlertChannel(id: "lark", notifier: lark)
        ])
        let initialSample = QuotaAlertFixture.date
        let staleBoundary = initialSample.addingTimeInterval(2 * 24 * 60 * 60)
        await service.receive(openAIWeeklyProjection(
            remainingPercent: 20,
            fetchedAt: initialSample,
            resetAt: staleBoundary
        ))
        let replacementSample = initialSample.addingTimeInterval(10 * 60)

        await service.receive(openAIWeeklyProjection(
            remainingPercent: 89,
            fetchedAt: replacementSample,
            resetAt: replacementSample.addingTimeInterval(7 * 24 * 60 * 60)
        ))

        let systemPayloads = await system.payloads
        let larkPayloads = await lark.payloads
        XCTAssertEqual(systemPayloads, larkPayloads)
        XCTAssertEqual(systemPayloads.map(\.title), ["额度已重置"])
        XCTAssertEqual(systemPayloads.first?.bodyLines.count, 1)
        XCTAssertTrue(
            systemPayloads.first?.bodyLines.first?.contains("剩余 89%") == true
        )
    }

    func testConcurrentSavesPersistLatestMarkersAcrossRelaunch() async {
        let notifier = systemNotifier
        let store = ControlledQuotaAlertMarkerStore(holdsFirstSave: true)
        let service = makeService(
            channels: [QuotaAlertChannel(id: "memory-only", notifier: notifier)],
            markerStore: store
        )
        let firstProjection = exhaustedProjection()
        let first = Task { await service.receive(firstProjection) }
        await store.waitUntilSaveIsBlocked()

        let secondProjection = openAIWeeklyProjection(
            remainingPercent: 0,
            fetchedAt: QuotaAlertFixture.date,
            resetAt: QuotaAlertFixture.resetDate
        )
        let second = await startReceive(secondProjection, on: service)
        // This same-actor barrier runs after the second receive has advanced
        // its markers and suspended at persistence.
        await service.receive(secondProjection)
        await store.releaseFirstSave()
        await first.value
        await second.value

        let maximumConcurrentSaves = await store.maximumConcurrentSaves
        let stored = await store.stored
        XCTAssertEqual(maximumConcurrentSaves, 1)
        XCTAssertEqual(stored.count, 3)
        await service.shutdown()

        let relaunchedNotifier = systemNotifier
        let relaunched = makeService(
            channels: [QuotaAlertChannel(id: "memory-only", notifier: relaunchedNotifier)],
            markerStore: store
        )
        await relaunched.receive(firstProjection)
        await relaunched.receive(secondProjection)
        let payloads = await relaunchedNotifier.payloads
        XCTAssertTrue(payloads.isEmpty, "A late old save must not re-arm either provider after relaunch")
    }

    func testShutdownDuringInitialLoadDoesNotPersistOrDispatch() async {
        let notifier = systemNotifier
        let store = ControlledQuotaAlertMarkerStore(holdsLoads: true)
        let service = makeService(
            channels: [QuotaAlertChannel(id: "memory-only", notifier: notifier)],
            markerStore: store
        )
        let projection = exhaustedProjection()
        let receive = Task { await service.receive(projection) }
        await store.waitUntilLoadIsBlocked()
        await service.shutdown()
        await store.releaseRemainingLoads()
        await receive.value
        await service.receive(projection)

        let payloads = await notifier.payloads
        let saveCount = await store.saveCount
        let loadCount = await store.loadCount
        XCTAssertTrue(payloads.isEmpty)
        XCTAssertEqual(saveCount, 0)
        XCTAssertEqual(loadCount, 1)
    }

    func testShutdownDuringSaveFinishesPersistenceWithoutDispatch() async {
        let notifier = systemNotifier
        let store = ControlledQuotaAlertMarkerStore(holdsFirstSave: true)
        let service = makeService(
            channels: [QuotaAlertChannel(id: "memory-only", notifier: notifier)],
            markerStore: store
        )
        let projection = exhaustedProjection()
        let receive = Task { await service.receive(projection) }
        await store.waitUntilSaveIsBlocked()
        await service.shutdown()
        await store.releaseFirstSave()
        await receive.value
        await service.receive(projection)

        let payloads = await notifier.payloads
        let stored = await store.stored
        XCTAssertTrue(payloads.isEmpty)
        XCTAssertEqual(stored.count, 1, "The already committed marker still finishes saving")
    }

    func testStaleExhaustedCacheDoesNotAlertBeforeFreshHealthyRead() async {
        let notifier = systemNotifier
        let store = FakeQuotaAlertMarkerStore()
        let service = makeService(
            channels: [QuotaAlertChannel(id: "memory-only", notifier: notifier)],
            markerStore: store
        )
        let now = QuotaAlertFixture.date.addingTimeInterval(7 * 24 * 3_600)
        let cached = allKindsSnapshot(exhausted: true, fetchedAt: QuotaAlertFixture.date)
        await service.receive(cachedProjection(cached, now: now))
        let beforeLiveRead = await notifier.payloads
        XCTAssertTrue(beforeLiveRead.isEmpty)

        await service.receive(QuotaAlertFixture.projection(
            lastGood: allKindsSnapshot(exhausted: false, fetchedAt: now)
        ))
        let payloads = await notifier.payloads
        let saveCount = await store.saveCount
        XCTAssertTrue(payloads.isEmpty, "Old exhaustion must not invent a later recovery edge")
        XCTAssertEqual(saveCount, 0)
    }

    func testStaleHealthyCacheRetainsMarkersUntilFreshRecovery() async {
        let exhausted = allKindsSnapshot(exhausted: true, fetchedAt: QuotaAlertFixture.date)
        let markers = Dictionary(uniqueKeysWithValues:
            QuotaExhaustionEvaluator.findings(in: exhausted).map { ($0.metricKey, $0.cycleKey) }
        )
        XCTAssertEqual(markers.count, 3)
        let notifier = systemNotifier
        let store = FakeQuotaAlertMarkerStore(stored: markers)
        let service = makeService(
            channels: [QuotaAlertChannel(id: "memory-only", notifier: notifier)],
            markerStore: store
        )
        let now = QuotaAlertFixture.date.addingTimeInterval(7 * 24 * 3_600)
        await service.receive(cachedProjection(
            allKindsSnapshot(exhausted: false, fetchedAt: QuotaAlertFixture.date),
            now: now
        ))
        let afterCache = await store.stored
        let cachePayloads = await notifier.payloads
        XCTAssertEqual(afterCache, markers)
        XCTAssertTrue(cachePayloads.isEmpty)

        await service.receive(QuotaAlertFixture.projection(
            lastGood: allKindsSnapshot(exhausted: true, fetchedAt: now)
        ))
        let repeatedExhaustionPayloads = await notifier.payloads
        XCTAssertTrue(repeatedExhaustionPayloads.isEmpty)

        for offset in [60.0, 120.0] {
            await service.receive(QuotaAlertFixture.projection(
                lastGood: allKindsSnapshot(exhausted: false, fetchedAt: now.addingTimeInterval(offset))
            ))
        }
        let payloads = await notifier.payloads
        let recoveredMarkers = await store.stored
        XCTAssertEqual(payloads.map(\.title), ["额度已重置"])
        XCTAssertEqual(payloads.first?.bodyLines.count, 3)
        XCTAssertTrue(recoveredMarkers.isEmpty)
    }

    func testFreshPartialMetricAlertsAndRecoversWhileRetainedNodesStaySilent() async {
        let notifier = systemNotifier
        let service = makeService(channels: [QuotaAlertChannel(id: "memory-only", notifier: notifier)])
        let date = QuotaAlertFixture.date
        let cached = allKindsSnapshot(exhausted: true, fetchedAt: date)
        var state = cachedProjection(cached, now: date.addingTimeInterval(60)).state
        let failure = ProviderFailure(
            code: .networkUnavailable, retryClass: .backoff, userMessageKey: "test.partial",
            diagnosticCode: "test.partial", recovery: .retry
        )
        for (index, exhausted) in [true, false, false].enumerated() {
            let fetchedAt = date.addingTimeInterval(Double(index + 1) * 60)
            let fresh = allKindsSnapshot(exhausted: exhausted, fetchedAt: fetchedAt)
            let patch = ProviderQuotaPatch(
                providerID: fresh.providerID,
                source: fresh.source,
                fetchedAt: fetchedAt,
                productCollectionMutation: .replaceAll(fresh.products),
                balanceMutation: .retain,
                resetEntitlementMutation: .retain
            )
            state = ProviderReducer.reduce(
                state: state,
                event: .refreshPartiallySucceeded(patch, failure),
                now: fetchedAt
            )
            guard case .stale = state.freshness else {
                return XCTFail("The fixture must retain the stale balance/entitlement branches")
            }
            await service.receive(ProviderProjection(
                revision: UInt64(index + 1), isEnabled: true, phase: .running, state: state
            ))
        }

        let payloads = await notifier.payloads
        XCTAssertEqual(payloads.map(\.title), ["额度已用完", "额度已重置"])
        XCTAssertTrue(payloads.allSatisfy { $0.bodyLines.count == 1 })
        XCTAssertTrue(payloads.allSatisfy { $0.bodyLines.first?.contains("prod-1 · 每周") == true })
    }

    func testLaterSnapshotStillExhaustedInSameCycleStaysSilent() async {
        let system = systemNotifier
        let store = FakeQuotaAlertMarkerStore()
        let service = makeService(
            channels: [QuotaAlertChannel(id: "system", notifier: system)],
            markerStore: store
        )

        await service.receive(exhaustedProjection())
        let saveCountAfterFirst = await store.saveCount
        await service.receive(
            exhaustedProjection(fetchedAt: QuotaAlertFixture.date.addingTimeInterval(120))
        )

        let payloads = await system.payloads
        XCTAssertEqual(payloads.count, 1)
        let saveCountAfterSecond = await store.saveCount
        XCTAssertEqual(
            saveCountAfterFirst, saveCountAfterSecond,
            "Unchanged markers must not be re-persisted"
        )
    }

    func testRecoveryThenReExhaustionInTheSameCycleDispatchesAgain() async {
        let system = systemNotifier
        let service = makeService(
            channels: [QuotaAlertChannel(id: "system", notifier: system)]
        )
        let date = QuotaAlertFixture.date

        await service.receive(exhaustedProjection(fetchedAt: date))
        await service.receive(recoveredProjection(fetchedAt: date.addingTimeInterval(60)))
        await service.receive(
            exhaustedProjection(fetchedAt: date.addingTimeInterval(120))
        )

        let payloads = await system.payloads
        XCTAssertEqual(
            payloads.map(\.title),
            ["额度已用完", "额度已重置", "额度已用完"],
            "Exhaustion, its recovery, and the re-exhaustion each notify once"
        )
    }

    func testRecoveryDispatchesResetPayloadToEveryChannelAndClearsMarker() async {
        let system = systemNotifier
        let lark = FakeQuotaAlertNotifier(id: "lark")
        let store = FakeQuotaAlertMarkerStore()
        let service = makeService(
            channels: [
                QuotaAlertChannel(id: "system", notifier: system),
                QuotaAlertChannel(id: "lark", notifier: lark)
            ],
            markerStore: store
        )
        let date = QuotaAlertFixture.date

        await service.receive(exhaustedProjection(fetchedAt: date))
        await service.receive(recoveredProjection(fetchedAt: date.addingTimeInterval(60)))

        let systemPayloads = await system.payloads
        let larkPayloads = await lark.payloads
        XCTAssertEqual(systemPayloads.count, 2)
        XCTAssertEqual(systemPayloads, larkPayloads, "Both channels must receive the identical payloads")

        let reset = systemPayloads[1]
        XCTAssertEqual(reset.title, "额度已重置")
        XCTAssertEqual(reset.bodyLines.count, 1)
        XCTAssertTrue(
            reset.bodyLines[0].hasPrefix("火山方舟 · prod-1 · 每周：已重置，已用 42%（"),
            "reset line should carry provider, product, window, and current usage, got: \(reset.bodyLines[0])"
        )
        XCTAssertTrue(reset.bodyLines[0].hasSuffix(" 重置）"))

        let stored = await store.stored
        XCTAssertTrue(stored.isEmpty, "The recovery edge must consume the persisted marker")
    }

    func testOpenAICodexWeeklyResetDoesNotRequirePriorExhaustion() async {
        let system = systemNotifier
        let lark = FakeQuotaAlertNotifier(id: "lark")
        let store = FakeQuotaAlertMarkerStore()
        let service = makeService(
            channels: [
                QuotaAlertChannel(id: "system", notifier: system),
                QuotaAlertChannel(id: "lark", notifier: lark)
            ],
            markerStore: store
        )
        let date = QuotaAlertFixture.date
        let week = 7 * 24 * 60 * 60.0
        let resetAt = date.addingTimeInterval(5 * 60)

        await service.receive(
            openAIWeeklyProjection(
                remainingPercent: 65,
                fetchedAt: date,
                resetAt: resetAt
            )
        )
        await service.receive(
            openAIWeeklyProjection(
                remainingPercent: 99,
                fetchedAt: resetAt,
                resetAt: resetAt.addingTimeInterval(week)
            )
        )

        let systemPayloads = await system.payloads
        let larkPayloads = await lark.payloads
        XCTAssertEqual(systemPayloads, larkPayloads)
        XCTAssertEqual(systemPayloads.count, 1)
        XCTAssertEqual(systemPayloads[0].title, "额度已重置")
        XCTAssertTrue(
            systemPayloads[0].bodyLines[0].hasPrefix(
                "OpenAI · Codex · 每周：已重置，剩余 99%"
            )
        )

        let stored = await store.stored
        XCTAssertFalse(
            stored.keys.contains {
                $0.hasPrefix("metric|6:openAI|5:codex|")
            },
            "The reset notification must not depend on an exhaustion marker"
        )
    }

    func testOpenAICodexRecoveryAndObservedResetProduceOneResetLine() async {
        let system = systemNotifier
        let service = makeService(
            channels: [QuotaAlertChannel(id: "system", notifier: system)]
        )
        let date = QuotaAlertFixture.date
        let week = 7 * 24 * 60 * 60.0
        let resetAt = date.addingTimeInterval(5 * 60)

        await service.receive(
            openAIWeeklyProjection(
                remainingPercent: 0,
                fetchedAt: date,
                resetAt: resetAt
            )
        )
        await service.receive(
            openAIWeeklyProjection(
                remainingPercent: 99,
                fetchedAt: resetAt,
                resetAt: resetAt.addingTimeInterval(week)
            )
        )

        let payloads = await system.payloads
        XCTAssertEqual(payloads.map(\.title), ["额度已用完", "额度已重置"])
        XCTAssertEqual(
            payloads[1].bodyLines,
            [
                "OpenAI · Codex · 每周：已重置，剩余 99%（\(resetAt.addingTimeInterval(week).formatted(date: .abbreviated, time: .shortened)) 重置）"
            ],
            "The proactive reset status should replace the duplicate exhaustion recovery line"
        )
    }

    func testOpenAIObservedResetWhileDisabledIsNotReplayedAfterRelaunch() async {
        let store = FakeQuotaAlertMarkerStore()
        let disabledNotifier = systemNotifier
        let disabledService = makeService(
            channels: [
                QuotaAlertChannel(id: "system", notifier: disabledNotifier)
            ],
            markerStore: store,
            isAlertsEnabled: { false }
        )
        let date = QuotaAlertFixture.date
        let week = 7 * 24 * 60 * 60.0
        let resetAt = date.addingTimeInterval(5 * 60)

        await disabledService.receive(
            openAIWeeklyProjection(
                remainingPercent: 65,
                fetchedAt: date,
                resetAt: resetAt
            )
        )
        await disabledService.receive(
            openAIWeeklyProjection(
                remainingPercent: 99,
                fetchedAt: resetAt,
                resetAt: resetAt.addingTimeInterval(week)
            )
        )
        let disabledPayloads = await disabledNotifier.payloads
        XCTAssertTrue(disabledPayloads.isEmpty)

        let enabledNotifier = systemNotifier
        let relaunchedService = makeService(
            channels: [
                QuotaAlertChannel(id: "system", notifier: enabledNotifier)
            ],
            markerStore: store
        )
        await relaunchedService.receive(
            openAIWeeklyProjection(
                remainingPercent: 100,
                fetchedAt: date.addingTimeInterval(6 * 60),
                resetAt: resetAt.addingTimeInterval(week)
            )
        )

        let enabledPayloads = await enabledNotifier.payloads
        XCTAssertTrue(
            enabledPayloads.isEmpty,
            "A disabled reset edge must stay consumed after relaunch"
        )
    }

    func testOpenAINewWindowStillAtZeroDoesNotDispatchResetPayload() async {
        let system = systemNotifier
        let service = makeService(
            channels: [QuotaAlertChannel(id: "system", notifier: system)]
        )
        let date = QuotaAlertFixture.date
        let week = 7 * 24 * 60 * 60.0
        let boundary = date.addingTimeInterval(5 * 60)

        await service.receive(
            openAIWeeklyProjection(
                remainingPercent: 0,
                fetchedAt: date,
                resetAt: boundary
            )
        )
        await service.receive(
            openAIWeeklyProjection(
                remainingPercent: 0,
                fetchedAt: boundary,
                resetAt: boundary.addingTimeInterval(week)
            )
        )

        let payloads = await system.payloads
        XCTAssertEqual(payloads.map(\.title), ["额度已用完", "额度已用完"])
        XCTAssertFalse(payloads.contains { $0.title == "额度已重置" })
    }

    func testRecoveryWithAlertsDisabledDropsMarkerWithoutDispatch() async {
        let system = systemNotifier
        let store = FakeQuotaAlertMarkerStore(
            stored: [
                "metric|3:ark|6:prod-1|0:|3:m-1":
                    "reset:\(QuotaAlertFixture.resetDate.timeIntervalSince1970)"
            ]
        )
        let service = makeService(
            channels: [QuotaAlertChannel(id: "system", notifier: system)],
            markerStore: store,
            isAlertsEnabled: { false }
        )

        await service.receive(recoveredProjection(fetchedAt: QuotaAlertFixture.date))

        let payloads = await system.payloads
        XCTAssertTrue(payloads.isEmpty)
        let stored = await store.stored
        XCTAssertTrue(
            stored.isEmpty,
            "Markers stay maintained while disabled, so re-enabling later does not replay old edges"
        )
    }

    func testStartupWithMarkerFromPreviousRunDispatchesResetOnce() async {
        let system = systemNotifier
        let store = FakeQuotaAlertMarkerStore(
            stored: [
                "metric|3:ark|6:prod-1|0:|3:m-1":
                    "reset:\(QuotaAlertFixture.resetDate.timeIntervalSince1970)"
            ]
        )
        let service = makeService(
            channels: [QuotaAlertChannel(id: "system", notifier: system)],
            markerStore: store
        )
        let date = QuotaAlertFixture.date

        // The app was closed across the reset; the first healthy snapshot
        // still tells the user the quota is usable again ("back to work").
        await service.receive(recoveredProjection(fetchedAt: date))
        await service.receive(recoveredProjection(fetchedAt: date.addingTimeInterval(120)))

        let payloads = await system.payloads
        XCTAssertEqual(payloads.count, 1)
        XCTAssertEqual(payloads[0].title, "额度已重置")
    }

    func testDisabledSwitchSuppressesDispatchButStillPersistsMarkers() async {
        let system = systemNotifier
        let store = FakeQuotaAlertMarkerStore()
        let service = makeService(
            channels: [QuotaAlertChannel(id: "system", notifier: system)],
            markerStore: store,
            isAlertsEnabled: { false }
        )

        await service.receive(exhaustedProjection())

        let payloads = await system.payloads
        XCTAssertTrue(payloads.isEmpty)
        let stored = await store.stored
        XCTAssertEqual(Array(stored.keys), ["metric|3:ark|6:prod-1|0:|3:m-1"])
    }

    func testMarkerFromPreviousRunSilencesStartupSnapshot() async {
        let system = systemNotifier
        let store = FakeQuotaAlertMarkerStore(
            stored: [
                "metric|3:ark|6:prod-1|0:|3:m-1":
                    "reset:\(QuotaAlertFixture.resetDate.timeIntervalSince1970)"
            ]
        )
        let service = makeService(
            channels: [QuotaAlertChannel(id: "system", notifier: system)],
            markerStore: store
        )

        await service.receive(exhaustedProjection())

        let payloads = await system.payloads
        XCTAssertTrue(payloads.isEmpty)
        let saveCount = await store.saveCount
        XCTAssertEqual(saveCount, 0, "Nothing changed, so nothing should be persisted")
    }

    func testDisabledProviderProjectionIsIgnored() async {
        let system = systemNotifier
        let service = makeService(
            channels: [QuotaAlertChannel(id: "system", notifier: system)]
        )

        await service.receive(exhaustedProjection(isEnabled: false))
        // The ignored projection must not poison the fetchedAt dedupe for a
        // later enabled projection of the same snapshot.
        await service.receive(exhaustedProjection())

        let payloads = await system.payloads
        XCTAssertEqual(payloads.count, 1)
    }

    func testChannelFailureDoesNotSuppressSiblingChannels() async {
        let failing = FakeQuotaAlertNotifier(id: "failing")
        await failing.setResult(
            .failure(
                ProviderFailure(
                    code: .processFailed,
                    retryClass: .backoff,
                    userMessageKey: "test.channel",
                    diagnosticCode: "test.channel_failed",
                    recovery: .retry
                )
            )
        )
        let healthy = systemNotifier
        let service = makeService(
            channels: [
                QuotaAlertChannel(id: "failing", notifier: failing),
                QuotaAlertChannel(id: "healthy", notifier: healthy)
            ]
        )

        await service.receive(exhaustedProjection())

        let healthyPayloads = await healthy.payloads
        XCTAssertEqual(healthyPayloads.count, 1)
    }

    func testMultipleExhaustedMetricsAggregateIntoOnePayload() async {
        let system = systemNotifier
        let service = makeService(
            channels: [QuotaAlertChannel(id: "system", notifier: system)]
        )
        let secondMetric = QuotaAlertFixture.metric(
            metricID: "m-2",
            window: QuotaAlertFixture.window(
                kind: .monthly,
                timeEvent: QuotaTimeEvent(kind: .reset, occursAt: QuotaAlertFixture.resetDate)
            ),
            value: .percent(DirectedPercent(sourceValue: 100, sourceDirection: .used))
        )

        await service.receive(
            exhaustedProjection(metrics: [
                QuotaAlertFixture.exhaustedPercentMetric(),
                secondMetric
            ])
        )

        let payloads = await system.payloads
        XCTAssertEqual(payloads.count, 1)
        XCTAssertEqual(payloads[0].bodyLines.count, 2)
        XCTAssertTrue(payloads[0].bodyLines[0].contains("prod-1 · 每周"))
        XCTAssertTrue(payloads[0].bodyLines[1].contains("prod-1 · 每月"))
    }

    func testProjectionWithoutSnapshotIsIgnored() async {
        let system = systemNotifier
        let service = makeService(
            channels: [QuotaAlertChannel(id: "system", notifier: system)]
        )

        await service.receive(QuotaAlertFixture.projection(lastGood: nil))

        let payloads = await system.payloads
        XCTAssertTrue(payloads.isEmpty)
    }

    func testPrepareReachesEveryChannelOnce() async {
        let system = systemNotifier
        let lark = FakeQuotaAlertNotifier(id: "lark")
        let service = makeService(
            channels: [
                QuotaAlertChannel(id: "system", notifier: system),
                QuotaAlertChannel(id: "lark", notifier: lark)
            ]
        )

        await service.prepare()

        let systemPrepareCount = await system.prepareCount
        let larkPrepareCount = await lark.prepareCount
        XCTAssertEqual(systemPrepareCount, 1)
        XCTAssertEqual(larkPrepareCount, 1)
    }

    private func allKindsSnapshot(exhausted: Bool, fetchedAt: Date) -> ProviderQuotaData {
        QuotaAlertFixture.quotaData(
            products: [QuotaAlertFixture.product(metrics: [QuotaAlertFixture.metric(
                window: QuotaAlertFixture.window(
                    timeEvent: QuotaTimeEvent(kind: .reset, occursAt: QuotaAlertFixture.resetDate)
                ),
                value: .percent(DirectedPercent(sourceValue: exhausted ? 100 : 42, sourceDirection: .used))
            )])],
            balances: [QuotaAlertFixture.balance(amount: exhausted ? 0 : 12)],
            resetEntitlements: [QuotaAlertFixture.entitlement(availableCount: exhausted ? 0 : 1)],
            fetchedAt: fetchedAt
        )
    }

    private func cachedProjection(_ data: ProviderQuotaData, now: Date) -> ProviderProjection {
        let state = ProviderReducer.reduce(
            state: QuotaAlertFixture.projection(lastGood: nil).state,
            event: .cacheLoaded(data),
            now: now
        )
        return ProviderProjection(revision: 1, isEnabled: true, phase: .running, state: state)
    }

    private func startReceive(
        _ projection: ProviderProjection,
        on service: QuotaAlertService
    ) async -> Task<Void, Never> {
        let (started, continuation) = AsyncStream<Void>.makeStream()
        let task = Task { @Sendable in
            await QuotaAlertServiceTests.receive(projection, on: service, started: continuation)
        }
        for await _ in started { break }
        return task
    }

    private static func receive(
        _ projection: ProviderProjection,
        on service: isolated QuotaAlertService,
        started: AsyncStream<Void>.Continuation
    ) async {
        // Signal while owning the service executor. The pending first receive
        // cannot resume on this actor before this receive reaches its await.
        started.yield(())
        started.finish()
        await service.receive(projection)
    }
}

private extension FakeQuotaAlertNotifier {
    func setResult(_ result: Result<Void, ProviderFailure>) async {
        self.result = result
    }
}
