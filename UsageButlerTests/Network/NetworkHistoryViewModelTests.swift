import XCTest
@testable import UsageButlerUI
import UsageButlerDomain
import UsageButlerCore
@testable import UsageButlerInfrastructure

func historyTestContract(_ request: HistoryQueryRequest, totalEvents: Int = 0) -> HistoryQueryContract {
    .init(scope: request.scope, context: request.context ?? .init(id: UUID().uuidString, generation: UUID().uuidString,
        fingerprint: String(repeating: "a", count: 64), createdNanoseconds: 1), totalEvents: totalEvents)
}

@MainActor final class NetworkHistoryViewModelTests: XCTestCase {
    private func result(_ request: HistoryQueryRequest) -> HistoryQueryResult {
        .init(range: request.scope.range, applications: [], totalApplications: 0, page: request.page, curve: [], days: [], events: [], coverage: .init(), contract: historyTestContract(request))
    }
    func testLateErrorCannotReplaceNewRangeAndCloseReleasesResult() async {
        let model = BackgroundNetworkViewModel()
        let started = expectation(description: "old query entered")
        var old: CheckedContinuation<HistoryQueryResult, Error>?
        var calls = 0
        model.onQuery = { request in
            calls += 1
            if calls == 1 { return try await withCheckedThrowingContinuation { old = $0; started.fulfill() } }
            return self.result(request)
        }
        model.reload(); let first = model.currentQueryTask
        await fulfillment(of: [started], timeout: 2)
        model.range = .hour; await model.currentQueryTask?.value
        let expected = model.result
        XCTAssertEqual(expected?.range.end.timeIntervalSince(expected!.range.start), 3600)
        old?.resume(throwing: BackgroundNetworkWire.Failure.disconnected); await first?.value
        XCTAssertEqual(model.result, expected); XCTAssertNil(model.queryIssue)
        model.closeHistory(); XCTAssertNil(model.result); XCTAssertFalse(model.loading)
    }
    func testCloseRejectsUncancelledLateSuccess() async {
        let model = BackgroundNetworkViewModel(), started = expectation(description: "query entered")
        var pending: CheckedContinuation<HistoryQueryResult, Error>?
        var request: HistoryQueryRequest?
        model.onQuery = { r in request = r; return try await withCheckedThrowingContinuation { pending = $0; started.fulfill() } }
        model.reload(); let task = model.currentQueryTask
        await fulfillment(of: [started], timeout: 2)
        model.closeHistory(); pending?.resume(returning: result(request!)); await task?.value
        XCTAssertNil(model.result); XCTAssertNil(model.queryIssue); XCTAssertFalse(model.loading)
    }
    func testFailureIsVisibleWhenUnregisteredAndApprovalIsPreserved() {
        let model = BackgroundNetworkViewModel(); model.serviceIssue = "history.signature-error"
        XCTAssertTrue(model.serviceTitle.contains("history.signature-error"))
        model.registration = "requiresApproval"; XCTAssertTrue(model.serviceTitle.contains("等待系统"))
        model.serviceIssue = nil; model.registration = "notRegistered"; XCTAssertTrue(model.serviceTitle.contains("保留"))
    }
    func testWireMeasuresActualBytesAndRejectsArbitraryPathShape() throws {
        XCTAssertThrowsError(try BackgroundNetworkWire.encode(.init(error: String(repeating: "界", count: 2_000_000))))
        var request = BackgroundNetworkRequest(.query); request.range = .recent(days: 7)
        request.selectedKey = String(repeating: "a", count: 8_193); XCTAssertFalse(request.isValid)
        request.selectedKey = "known"; request.applicationID = 1; XCTAssertFalse(request.isValid)
        request.applicationID = nil; request.page = 1024; XCTAssertFalse(request.isValid)
    }
    func testStoppedReadDoesNotCreateMissingDatabaseOrDirectory() async throws {
        let parent = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent(".build/background-history-0.5.0/test-databases/missing-" + UUID().uuidString)
        let reader = UsageButlerInfrastructure.NetworkHistoryQuery(databaseURL: parent.appendingPathComponent("history-v1.sqlite"))
        do { _ = try await reader.query(range: .recent(days: 7)); XCTFail("missing database must not be zero history") } catch {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: parent.path))
    }
}

final class HistoryUploadRuleEditingTests: XCTestCase {
    func testFractionalRuleSurvivesSettingsReloadAndUneditedResave() throws {
        let original = HistoryUploadRule(sustainedSeconds: 5.5, sustainedBytesPerSecond: 1_536)
        let fields = HistoryUploadRuleFields(original)
        XCTAssertEqual(fields.sustainedSeconds, "5.5")
        XCTAssertEqual(fields.sustainedKiB, "1.5")
        let saved = try XCTUnwrap(fields.parsedRule)
        XCTAssertTrue(saved.isValid)
        XCTAssertEqual(saved, original)
        XCTAssertEqual(HistoryUploadRuleFields(saved).parsedRule, original)
    }

    func testIntegerDefaultsRemainPlainAndValidBoundariesRoundTripExactly() throws {
        let defaults = HistoryUploadRuleFields(.init())
        XCTAssertEqual(defaults.largeMiB, "100")
        XCTAssertEqual(defaults.sustainedSeconds, "60")
        XCTAssertEqual(defaults.sustainedKiB, "100")
        let rules = [
            HistoryUploadRule(largeBytes: 1_048_576, sustainedSeconds: 5, sustainedBytesPerSecond: 1_024),
            HistoryUploadRule(sustainedSeconds: 5.1, sustainedBytesPerSecond: 1_536.5),
            HistoryUploadRule(sustainedSeconds: Double(5).nextUp, sustainedBytesPerSecond: Double(1_024).nextUp),
            HistoryUploadRule(sustainedSeconds: Double(86_400).nextDown, sustainedBytesPerSecond: Double(107_374_182_400).nextDown),
            HistoryUploadRule(largeBytes: 1_125_899_906_842_624, sustainedSeconds: 86_400, sustainedBytesPerSecond: 107_374_182_400)
        ]
        for rule in rules {
            XCTAssertTrue(rule.isValid)
            let restored = try XCTUnwrap(HistoryUploadRuleFields(rule).parsedRule)
            XCTAssertTrue(restored.isValid)
            XCTAssertEqual(restored.largeBytes, rule.largeBytes)
            XCTAssertEqual(restored.sustainedSeconds.bitPattern, rule.sustainedSeconds.bitPattern)
            XCTAssertEqual(restored.sustainedBytesPerSecond.bitPattern, rule.sustainedBytesPerSecond.bitPattern)
        }
    }

    func testInvalidNonfiniteAndOutOfBoundsFieldsCannotProduceValidRules() {
        for text in ["", "not-a-number", "nan", "inf", "-inf", "-1", "0", "4.999", "86400.00001"] {
            var fields = HistoryUploadRuleFields(.init()); fields.sustainedSeconds = text
            XCTAssertNotEqual(fields.parsedRule?.isValid, true, text)
        }
        for text in ["", "not-a-number", "nan", "inf", "-inf", "-1", "0", "0.999", "104857600.001"] {
            var fields = HistoryUploadRuleFields(.init()); fields.sustainedKiB = text
            XCTAssertNotEqual(fields.parsedRule?.isValid, true, text)
        }
        for text in ["", "nan", "inf", "-1", "0", "1.5", "1073741825", "18446744073709551615"] {
            var fields = HistoryUploadRuleFields(.init()); fields.largeMiB = text
            XCTAssertNil(fields.parsedRule, text)
        }
    }

    func testHistoricalThresholdTextUsesTheRecordedFractionalRule() {
        XCTAssertEqual(HistoryUploadRuleFields.sustainedThreshold(.init(sustainedSeconds: 5.5, sustainedBytesPerSecond: 1_536)),
            "当时阈值：连续 ≥ 5.5 秒，每次读数 ≥ 1.5 KiB/s")
        XCTAssertEqual(HistoryUploadRuleFields.sustainedThreshold(.init(sustainedSeconds: 5.1, sustainedBytesPerSecond: 1_536.5)),
            "当时阈值：连续 ≥ 5.1 秒，每次读数 ≥ 1.50048828125 KiB/s")
        XCTAssertEqual(HistoryUploadRuleFields.sustainedThreshold(.init()),
            "当时阈值：连续 ≥ 60 秒，每次读数 ≥ 100 KiB/s")
    }
}

@MainActor final class HistorySummaryNavigationTests: XCTestCase {
    @MainActor private final class QueryFixture {
        var now = Date(timeIntervalSince1970: 1_800_000_021)
        var requests: [HistoryQueryRequest] = []
        var applications: [HistoryApplicationSummary] = (1...130).map {
            .init(id: Int64($0), identity: .init(key: "app-\($0)", name: "Application \($0)", evidence: .executable), totals: .init())
        }
        func result(_ request: HistoryQueryRequest) -> HistoryQueryResult {
            let range = request.scope.range, application = request.scope.applicationKey, page = request.page, kind = request.scope.eventKind
            requests.append(request)
            let rows = application.map { key in applications.filter { $0.identity.key == key } }
                ?? Array(applications.dropFirst(page * 64).prefix(64))
            let events = (1...130).compactMap { index -> HistoryUploadEvent? in
                let eventKind = index.isMultiple(of: 2) ? "large" : "sustained"
                guard kind == nil || kind == eventKind else { return nil }
                return .init(id: Int64(index), applicationID: rows.first?.id ?? 1, applicationKey: application ?? "app-1",
                    name: "Application", kind: eventKind, start: range.start, end: range.end, bytes: 1_048_576,
                    peak: 1_048_576, observedSeconds: 5.5, rule: .init(), endReason: nil)
            }
            return .init(range: range, applications: rows, totalApplications: application == nil ? applications.count : rows.count,
                page: page, curve: [], days: [], events: Array(events.dropFirst(page * 64).prefix(64)), coverage: .init(), contract: historyTestContract(request, totalEvents: events.count))
        }
        func model() -> BackgroundNetworkViewModel {
            let model = BackgroundNetworkViewModel(now: { self.now })
            model.onQuery = { self.result($0) }
            return model
        }
    }
    private func thirdPage(_ model: BackgroundNetworkViewModel) async {
        model.reload(); await model.currentQueryTask?.value
        model.nextPage(); await model.currentQueryTask?.value
        model.nextPage(); await model.currentQueryTask?.value
    }

    func testDetailFilterAndPaginationRestoreSummaryPageRangeAndFilter() async throws {
        let fixture = QueryFixture(), model = fixture.model()
        model.eventKind = "large"; await model.currentQueryTask?.value
        model.nextPage(); await model.currentQueryTask?.value
        model.nextPage(); await model.currentQueryTask?.value
        let original = try XCTUnwrap(model.result?.range)
        model.selectedApplication = "app-129"; await model.currentQueryTask?.value
        fixture.now.addTimeInterval(7_200)
        model.eventKind = "sustained"; await model.currentQueryTask?.value
        model.nextPage(); await model.currentQueryTask?.value
        XCTAssertEqual(model.page, 1)
        XCTAssertEqual(model.result?.range, original)
        model.selectedApplication = nil; await model.currentQueryTask?.value
        XCTAssertEqual(model.page, 2)
        XCTAssertEqual(model.eventKind, "large")
        XCTAssertEqual(model.result?.range, original)
        XCTAssertEqual(model.result?.applications.map(\.id), [129, 130])
        XCTAssertEqual(model.returnFocus, .application(129))
        XCTAssertNil(model.navigationNotice)
        XCTAssertTrue(fixture.requests.allSatisfy { $0.scope.range == original })
    }

    func testExplicitRangeChangeAndRefreshDiscardOldSummaryContext() async throws {
        for changeRange in [true, false] {
            let fixture = QueryFixture(), model = fixture.model()
            await thirdPage(model)
            let original = try XCTUnwrap(model.result?.range)
            model.selectedApplication = "app-129"; await model.currentQueryTask?.value
            fixture.now.addTimeInterval(7_200)
            if changeRange { model.range = .day } else { model.reload() }
            await model.currentQueryTask?.value
            let renewed = try XCTUnwrap(model.result?.range)
            XCTAssertNotEqual(renewed.end, original.end)
            XCTAssertEqual(renewed.end.timeIntervalSince(renewed.start), (changeRange ? 1 : 7) * 86_400)
            model.selectedApplication = nil; await model.currentQueryTask?.value
            XCTAssertEqual(model.page, 0)
            XCTAssertEqual(model.result?.range, renewed)
            XCTAssertNil(model.returnFocus)
        }
    }

    func testLateDetailResponseCannotReplaceRestoredSummary() async throws {
        let fixture = QueryFixture(), model = fixture.model()
        await thirdPage(model)
        let started = expectation(description: "detail query entered")
        var pending: CheckedContinuation<HistoryQueryResult, Error>?
        var detail: HistoryQueryResult?
        model.onQuery = { request in
            let application = request.scope.applicationKey, page = request.page
            let result = fixture.result(request)
            if application != nil {
                detail = result
                return try await withCheckedThrowingContinuation { pending = $0; started.fulfill() }
            }
            return result
        }
        model.selectedApplication = "app-129"; let old = model.currentQueryTask
        await fulfillment(of: [started], timeout: 2)
        model.selectedApplication = nil; await model.currentQueryTask?.value
        let restored = model.result
        pending?.resume(returning: try XCTUnwrap(detail)); await old?.value
        XCTAssertEqual(model.result, restored)
        XCTAssertEqual(model.page, 2)
        XCTAssertEqual(model.returnFocus, .application(129))
    }

    func testReturnUsesStableIdentityWhenRepresentativeChanges() async {
        let fixture = QueryFixture(), model = fixture.model()
        await thirdPage(model)
        model.selectedApplication = "app-129"; await model.currentQueryTask?.value
        fixture.applications[128] = .init(id: 1_129, identity: .init(key: "app-129", name: "Renamed", evidence: .executable), totals: .init())
        model.selectedApplication = nil; await model.currentQueryTask?.value
        XCTAssertEqual(model.page, 2)
        XCTAssertEqual(model.returnFocus, .application(1_129))
        XCTAssertNil(model.navigationNotice)
    }

    func testMissingOrResortedApplicationDoesNotFocusAnUnrelatedRow() async {
        for removed in [true, false] {
            let fixture = QueryFixture(), model = fixture.model()
            await thirdPage(model)
            model.selectedApplication = "app-129"; await model.currentQueryTask?.value
            let app = fixture.applications.remove(at: 128)
            if !removed { fixture.applications.insert(app, at: 0) }
            model.selectedApplication = nil; await model.currentQueryTask?.value
            XCTAssertEqual(model.page, 2)
            XCTAssertEqual(model.returnFocus, .summary)
            XCTAssertNotNil(model.navigationNotice)
            XCTAssertFalse(model.result!.applications.contains { $0.identity.key == "app-129" })
        }
    }

    func testLateReturnCannotOverrideAnExplicitRefresh() async throws {
        let fixture = QueryFixture(), model = fixture.model()
        await thirdPage(model)
        model.selectedApplication = "app-129"; await model.currentQueryTask?.value
        let started = expectation(description: "return query entered")
        var pending: CheckedContinuation<HistoryQueryResult, Error>?
        var oldResult: HistoryQueryResult?
        model.onQuery = { request in
            let application = request.scope.applicationKey, page = request.page
            let result = fixture.result(request)
            if application == nil, page == 2 {
                oldResult = result
                return try await withCheckedThrowingContinuation { pending = $0; started.fulfill() }
            }
            return result
        }
        model.selectedApplication = nil; let old = model.currentQueryTask
        await fulfillment(of: [started], timeout: 2)
        fixture.now.addTimeInterval(7_200); model.reload(); await model.currentQueryTask?.value
        let fresh = model.result
        pending?.resume(returning: try XCTUnwrap(oldResult)); await old?.value
        XCTAssertEqual(model.result, fresh)
        XCTAssertEqual(model.page, 0)
        XCTAssertNil(model.returnFocus)
        XCTAssertNil(model.navigationNotice)
    }
}


extension NetworkHistoryViewModelTests {
    func testContextFailureAndLegacyResponseAreVisibleAndNeverMixPages() async {
        for failure in [HistoryQueryFailure.changed, .expired, .incompatible] {
            let model = BackgroundNetworkViewModel()
            model.onQuery = { request in
                if request.page > 0 { throw failure }
                return self.result(request)
            }
            model.reload(); await model.currentQueryTask?.value
            let original = model.result
            model.nextPage(); await model.currentQueryTask?.value
            XCTAssertNil(model.result); XCTAssertNotNil(model.queryIssue); XCTAssertFalse(model.loading)
            XCTAssertTrue(model.queryIssue!.contains(failure == .incompatible ? "更新后台" : "刷新"))
            model.reload(); await model.currentQueryTask?.value
            XCTAssertEqual(model.page, 0); XCTAssertNotNil(model.result); XCTAssertNil(model.queryIssue)
            XCTAssertNotEqual(model.result?.contract?.context.id, original?.contract?.context.id)
        }
        let legacy = BackgroundNetworkViewModel()
        legacy.onQuery = { request in .init(range: request.scope.range, applications: [], totalApplications: 0,
            page: request.page, curve: [], days: [], events: [], coverage: .init()) }
        legacy.reload(); await legacy.currentQueryTask?.value
        XCTAssertNil(legacy.result); XCTAssertTrue(legacy.queryIssue?.contains("重新连接") == true)
    }
    func testSearchStartsNewContextKeepsAbsoluteRangeAndRejectsLateSuccess() async throws {
        let model = BackgroundNetworkViewModel(), entered = expectation(description: "old search entered")
        var pending: CheckedContinuation<HistoryQueryResult, Error>?, stale: HistoryQueryResult?
        model.onQuery = { request in
            let value = self.result(request)
            if request.scope.search == "old" {
                stale = value
                return try await withCheckedThrowingContinuation { pending = $0; entered.fulfill() }
            }
            return value
        }
        model.reload(); await model.currentQueryTask?.value
        let range = try XCTUnwrap(model.result?.range), context = model.result?.contract?.context
        model.nextPage(); await model.currentQueryTask?.value
        XCTAssertEqual(model.result?.contract?.context, context)
        model.search = "old"; let old = model.currentQueryTask
        await fulfillment(of: [entered], timeout: 2)
        model.search = "new"; await model.currentQueryTask?.value
        let fresh = try XCTUnwrap(model.result)
        XCTAssertEqual(fresh.range, range); XCTAssertEqual(fresh.page, 0)
        XCTAssertEqual(fresh.contract?.scope.search, "new"); XCTAssertNotEqual(fresh.contract?.context, context)
        pending?.resume(returning: try XCTUnwrap(stale)); await old?.value
        XCTAssertEqual(model.result, fresh)
        model.search = ""; await model.currentQueryTask?.value
        XCTAssertEqual(model.result?.range, range); XCTAssertEqual(model.result?.contract?.scope.search, "")
        XCTAssertNotEqual(model.result?.contract?.context, fresh.contract?.context)
        model.search = String(repeating: "界", count: 86); await model.currentQueryTask?.value
        XCTAssertNil(model.result); XCTAssertTrue(model.queryIssue?.contains("过长") == true)
    }
}

extension HistorySummaryNavigationTests {
    func testActivityDrillReturnsOriginalEventSearchPageAndContext() async throws {
        let fixture = QueryFixture(), model = fixture.model()
        model.search = "Application"; await model.currentQueryTask?.value
        model.nextPage(); await model.currentQueryTask?.value
        model.nextPage(); await model.currentQueryTask?.value
        let summary = try XCTUnwrap(model.result), event = try XCTUnwrap(summary.events.first)
        model.openEvent(event); await model.currentQueryTask?.value
        XCTAssertEqual(model.selectedApplication, event.applicationKey)
        XCTAssertEqual(model.result?.contract?.scope.applicationKey, event.applicationKey)
        model.eventKind = "large"; await model.currentQueryTask?.value
        model.search = "Application 1"; await model.currentQueryTask?.value
        model.selectedApplication = nil; await model.currentQueryTask?.value
        XCTAssertEqual(model.search, "Application"); XCTAssertNil(model.eventKind); XCTAssertEqual(model.page, 2)
        XCTAssertEqual(model.result?.contract?.context, summary.contract?.context)
        XCTAssertEqual(model.result?.range, summary.range); XCTAssertEqual(model.returnFocus, .event(event.id))
    }
}


@MainActor private final class HistoryPauseControl {
    struct Wait {
        let duration: Duration
        let continuation: CheckedContinuation<Void, Error>
        func release() { continuation.resume() }
    }
    let pair = AsyncStream<Wait>.makeStream()
    func pause(_ duration: Duration) async throws {
        try await withCheckedThrowingContinuation { pair.continuation.yield(.init(duration: duration, continuation: $0)) }
    }
}

extension NetworkHistoryViewModelTests {
    func testBusySearchRecoversAfterOldQueryCompletesAndDropsOldReply() async throws {
        let pauses = HistoryPauseControl(), entered = expectation(description: "first query running")
        var waits = pauses.pair.stream.makeAsyncIterator()
        let model = BackgroundNetworkViewModel(pause: { try await pauses.pause($0) })
        var first: CheckedContinuation<HistoryQueryResult, Error>?, firstResult: HistoryQueryResult?
        var occupied = true, searches: [String] = []
        model.onQuery = { request in
            searches.append(request.scope.search)
            if request.scope.search == "first" {
                firstResult = self.result(request)
                return try await withCheckedThrowingContinuation { first = $0; entered.fulfill() }
            }
            if occupied { throw BackgroundNetworkWire.Failure.remote("history.query-busy") }
            return self.result(request)
        }
        model.search = "first"; let old = model.currentQueryTask
        let firstDebounce = await waits.next(); XCTAssertEqual(firstDebounce?.duration, .milliseconds(200)); firstDebounce?.release()
        await fulfillment(of: [entered], timeout: 2)
        model.search = "final search"
        let secondDebounce = await waits.next(); secondDebounce?.release()
        let retry = await waits.next(); XCTAssertEqual(retry?.duration, .milliseconds(100))
        XCTAssertTrue(model.loading); XCTAssertNil(model.queryIssue)
        occupied = false; first?.resume(returning: try XCTUnwrap(firstResult)); await old?.value
        XCTAssertNil(model.result, "old successful reply must not replace latest search")
        retry?.release(); await model.currentQueryTask?.value
        XCTAssertEqual(searches, ["first", "final search", "final search"])
        XCTAssertEqual(model.result?.contract?.scope.search, "final search"); XCTAssertNil(model.queryIssue)
    }
    func testRapidSearchCoalescesAndCloseOrScopeChangeInvalidatesWait() async {
        let pauses = HistoryPauseControl(); var waits = pauses.pair.stream.makeAsyncIterator()
        let model = BackgroundNetworkViewModel(pause: { try await pauses.pause($0) })
        var searches: [String] = []
        model.onQuery = { request in searches.append(request.scope.search); return self.result(request) }
        model.search = "n"; let first = model.currentQueryTask; let a = await waits.next()
        model.search = "ne"; let second = model.currentQueryTask; let b = await waits.next()
        model.search = "needle"; let c = await waits.next()
        a?.release(); b?.release(); c?.release(); await first?.value; await second?.value; await model.currentQueryTask?.value
        XCTAssertEqual(searches, ["needle"])
        for action in 0..<5 {
            searches = []
            model.onQuery = { request in searches.append(request.scope.search); throw BackgroundNetworkWire.Failure.remote("history.query-busy") }
            model.reload(); let obsolete = model.currentQueryTask; let busyWait = await waits.next()
            model.onQuery = { request in searches.append(request.scope.search); return self.result(request) }
            switch action {
            case 0: model.closeHistory()
            case 1: model.eventKind = "large"
            case 2: model.range = .hour
            case 3: model.selectedApplication = "app-key"
            default: model.search = "newest"; let debounce = await waits.next(); debounce?.release()
            }
            await model.currentQueryTask?.value
            let count = searches.count
            busyWait?.release(); await obsolete?.value
            XCTAssertEqual(searches.count, count, "old retry cannot issue after action \(action)")
            if action == 0 { XCTAssertNil(model.result); XCTAssertFalse(model.loading) }
        }
    }
    func testPermanentBusyHasFiveAttemptsAndFiniteWaitingBudgetWithRefreshRecovery() async {
        var durations: [Duration] = [], calls = 0
        let model = BackgroundNetworkViewModel(pause: { durations.append($0) })
        model.onQuery = { _ in calls += 1; throw BackgroundNetworkWire.Failure.remote("history.query-busy") }
        model.search = "needle"; await model.currentQueryTask?.value
        XCTAssertEqual(calls, 5)
        XCTAssertEqual(durations, [.milliseconds(200), .milliseconds(100), .milliseconds(200), .milliseconds(400), .milliseconds(800)])
        XCTAssertNil(model.result); XCTAssertFalse(model.loading); XCTAssertTrue(model.queryIssue?.contains("刷新重试") == true)
        model.onQuery = { request in self.result(request) }
        model.reload(); await model.currentQueryTask?.value
        XCTAssertEqual(model.result?.contract?.scope.search, "needle"); XCTAssertNil(model.queryIssue)
    }
}
