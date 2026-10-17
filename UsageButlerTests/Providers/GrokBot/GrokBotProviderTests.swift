import Foundation
import SQLite3
import XCTest
import UsageButlerCore
import UsageButlerDomain
@testable import UsageButlerProviders
@testable import UsageButlerInfrastructure

private let grokNow = Date(timeIntervalSince1970: 1_792_022_400)
private func fakeJWT(_ subject: String = "user_FAKE_A", expiration: Any = grokNow.addingTimeInterval(3600).timeIntervalSince1970) -> String {
    let payload = try! JSONSerialization.data(withJSONObject: ["sub": "auth0|" + subject, "exp": expiration])
    return "e30." + payload.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "") + ".FAKE_SIGNATURE"
}
private actor FakeCursorReader: CursorSessionReading {
    var token: String? = fakeJWT()
    var count = 0
    func load() throws -> CursorReadOnlySession? { count += 1; return try token.map { try .init(token: $0, now: grokNow) } }
    func set(_ value: String?) { token = value }
}
private actor FakeSandHTTP: GrokBotHTTPTransport {
    var subject = "user_FAKE_A"
    var status = 200
    var usageStatus: Int?
    var raw = Data(#"{"availability":"available","weeklyIncludedStatus":{"status":"metered"},"weeklyIncludedUsage":{"usedCents":25,"budgetCents":100,"resetsAt":"2026-10-22T00:00:00Z"}}"#.utf8)
    var requests: [URLRequest] = []
    var failure: URLError?
    var block = false
    var pending: CheckedContinuation<Void, Never>?
    var arrival: CheckedContinuation<Void, Never>?
    var hasArrived = false
    func configure(subject: String = "user_FAKE_A", status: Int = 200, body: Data? = nil, failure: URLError? = nil) {
        self.subject = subject; self.status = status; if let body { raw = body }; self.failure = failure
    }
    func failUsageOnly(_ status: Int) { usageStatus = status }
    func blockSand() { block = true; hasArrived = false }
    func waitForSand() async { if hasArrived { return }; await withCheckedContinuation { arrival = $0 } }
    func resume() { pending?.resume(); pending = nil; block = false }
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        try GrokBotHTTPClient.validate(request)
        requests.append(request)
        if let failure { throw failure }
        let isSand = request.url!.path == GrokBotHTTPClient.Endpoint.shared.rawValue
        let body = isSand ? raw : try JSONSerialization.data(withJSONObject: ["sub": subject, "email": "fake@example.invalid"])
        let response = HTTPURLResponse(url: request.url!, statusCode: isSand ? (usageStatus ?? status) : status, httpVersion: "HTTP/1.1", headerFields: nil)!
        if isSand && block {
            block = false
            hasArrived = true; arrival?.resume(); arrival = nil
            await withCheckedContinuation { pending = $0 }
        }
        return (body, response)
    }
}
private actor GrokMemoryCache: ProviderQuotaCache {
    var data: ProviderQuotaData?
    func load(providerID: ProviderID) -> ProviderQuotaCacheLoadResult { data.map(ProviderQuotaCacheLoadResult.hit) ?? .miss }
    func save(_ data: ProviderQuotaData) -> ProviderQuotaCacheWriteResult { self.data = data; return .success(writtenAt: grokNow) }
    func clear(providerID: ProviderID) -> ProviderQuotaCacheClearResult { let exists = data != nil; data = nil; return .success(clearedAt: grokNow, removedEntry: exists) }
    func shutdown() {}
}
private struct GrokClock: ClockPort {
    func reading() async -> ClockReading { .init(wallTime: grokNow, monotonicTime: .init(nanoseconds: 0)) }
    func sleep(until deadline: MonotonicInstant) async throws { throw CancellationError() }
}

@MainActor final class GrokBotProviderTests: XCTestCase {
    private func fixture(enabled: Bool = true) throws -> (ProviderController, GrokBotProviderAdapter, FakeCursorReader, FakeSandHTTP) {
        let reader = FakeCursorReader(), http = FakeSandHTTP()
        let adapter = GrokBotProviderAdapter(reader: reader, client: .init(transport: http), now: { grokNow })
        let state = ProviderBootstrap.initialState(id: .grokBot, capabilities: adapter.capabilities, now: grokNow)
        let clock = GrokClock()
        let controller = try ProviderController(initialState: state, initiallyEnabled: enabled, adapter: adapter,
            cache: GrokMemoryCache(), clock: clock, scheduler: RefreshScheduler(clock: clock),
            policy: .init(cadence: .automatic(interval: .seconds(300)), manualCooldown: .seconds(0), retryBackoff: [.seconds(60)], shutdownGrace: .seconds(1)))
        return (controller, adapter, reader, http)
    }
    func testDefaultOffAndDisabledControllerPerformsZeroSessionReadsAndRequests() async throws {
        XCTAssertFalse(ProviderDefaults.initiallyEnabled.contains(.grokBot))
        let (controller, _, reader, http) = try fixture(enabled: false)
        _ = await controller.send(.start)
        _ = await controller.send(.refresh(.manual(scope: .provider)))
        let reads = await reader.count, requests = await http.requests.count
        XCTAssertEqual(reads, 0); XCTAssertEqual(requests, 0)
        let disabled = await controller.projection()
        XCTAssertNil(LiveProviderProjectionMapper.map(disabled, now: grokNow))
    }
    func testGrantReadsOnlyAfterEnableAndUsesTwoFixedRequests() async throws {
        let (controller, _, reader, http) = try fixture(enabled: false)
        _ = await controller.send(.start); _ = await controller.send(.setEnabled(true))
        let result = await controller.projection(), requests = await http.requests, reads = await reader.count
        XCTAssertEqual(result.state.lastGood?.providerID, .grokBot); XCTAssertEqual(reads, 2)
        XCTAssertEqual(requests.map { $0.url!.path }, ["/api/auth/me", "/api/dashboard/v2/usage-status"])
        XCTAssertEqual(requests.map(\.httpMethod), ["GET", "GET"])
        XCTAssertNil(requests.last?.httpBody)
        XCTAssertEqual(requests.last?.url?.query, "scope=user")
        XCTAssertNil(requests.last?.value(forHTTPHeaderField: "Origin"))
        XCTAssertNil(requests.last?.value(forHTTPHeaderField: "Authorization"))
        XCTAssertEqual(requests.last?.httpShouldHandleCookies, false)
    }
    func testSharedFailureNeverRequestsSandAndRetainsOnlySharedLastGood() async throws {
        let (controller, _, _, http) = try fixture(); _ = await controller.send(.start)
        let original = await controller.projection().state.lastGood
        await http.failUsageOnly(404)
        _ = await controller.send(.refresh(.manual(scope: .provider)))
        let state = await controller.projection().state, requests = await http.requests
        XCTAssertEqual(state.lastGood?.grokBotUsage, original?.grokBotUsage)
        XCTAssertEqual(state.lastGood?.source.adapterID, "cursor-grok-shared")
        XCTAssertEqual(state.failure?.code, .serviceUnavailable)
        XCTAssertEqual(requests.count, 4)
        XCTAssertTrue(requests.allSatisfy { $0.url?.host == "cursor.com" && $0.url?.path != "/api/dashboard/get-sand-usage-status" })
    }
    func testSharedUnavailable200RetainsLastGoodAndOriginalTime() async throws {
        let (controller, _, _, http) = try fixture(); _ = await controller.send(.start)
        let before = await controller.projection().state
        await http.configure(body:Data(#"{"availability":"available","weeklyIncludedStatus":{"status":"unavailable"},"monthlyUsage":{"usedCents":0,"limitCents":null,"creditsUsedCents":0}}"#.utf8))
        _ = await controller.send(.refresh(.manual(scope:.provider)))
        let state = await controller.projection().state
        XCTAssertEqual(state.lastGood?.grokBotUsage,before.lastGood?.grokBotUsage)
        XCTAssertEqual(state.lastGood?.source,before.lastGood?.source)
        XCTAssertEqual(state.lastGood?.fetchedAt,before.lastGood?.fetchedAt)
        XCTAssertEqual(state.lastGood?.products.first?.metrics.first?.value,before.lastGood?.products.first?.metrics.first?.value)
        XCTAssertEqual(state.lastGood?.products.first?.metrics.first?.provenance.fetchedAt,before.lastGood?.products.first?.metrics.first?.provenance.fetchedAt)
        XCTAssertEqual(state.refresh.lastSuccessAt,before.refresh.lastSuccessAt)
        XCTAssertEqual(state.failure?.code,.serviceUnavailable)
        guard case .stale = state.freshness, case let .stale(asOf, _)? = state.lastGood?.products.first?.metrics.first?.state.freshness else { return XCTFail("A temporarily unavailable weekly read must retain stale data") }
        XCTAssertEqual(asOf,before.lastGood?.fetchedAt)
    }
    func testRevokeClearsRetainedDataAndStopsFurtherReads() async throws {
        let (controller, _, reader, http) = try fixture()
        _ = await controller.send(.start); _ = await controller.send(.setEnabled(false))
        let before = await reader.count, requestCount = await http.requests.count
        _ = await controller.send(.refresh(.manual(scope: .provider)))
        let result = await controller.projection(), after = await reader.count, afterRequests = await http.requests.count
        XCTAssertNil(result.state.lastGood); XCTAssertEqual(before, after); XCTAssertEqual(requestCount, afterRequests)
    }
    func testRevokeRejectsLateNonCooperativeHTTPResponse() async throws {
        let (controller, _, _, http) = try fixture()
        await http.blockSand()
        let first = Task { await controller.send(.start) }
        await http.waitForSand(); _ = await controller.send(.setEnabled(false)); await http.resume(); _ = await first.value
        let result = await controller.projection()
        XCTAssertFalse(result.isEnabled); XCTAssertNil(result.state.lastGood)
    }
    func testRegrantNewAccountCannotBeOverwrittenByOldLateResponse() async throws {
        let (controller, _, reader, http) = try fixture()
        await http.blockSand()
        let old = Task { await controller.send(.start) }
        await http.waitForSand()
        _ = await controller.send(.setEnabled(false))
        await reader.set(fakeJWT("user_FAKE_B")); await http.configure(subject: "user_FAKE_B")
        _ = await controller.send(.setEnabled(true))
        let newer = await controller.projection()
        XCTAssertNotNil(newer.state.lastGood)
        await http.resume(); _ = await old.value
        let final = await controller.projection()
        XCTAssertEqual(final.state.lastGood, newer.state.lastGood)
        XCTAssertTrue(final.isEnabled)
    }
    func testAccountSwitchDiscardsAWhileBRequestIsBlocked() async throws {
        let (controller, _, reader, http) = try fixture()
        _ = await controller.send(.start)
        let firstScope = await controller.projection().state.lastGood?.source.sessionScope
        await reader.set(fakeJWT("user_FAKE_B")); await http.configure(subject: "user_FAKE_B"); await http.blockSand()
        let refresh = Task { await controller.send(.refresh(.manual(scope: .provider))) }
        await http.waitForSand()
        let during = await controller.projection(); XCTAssertNil(during.state.lastGood); XCTAssertNil(during.state.refresh.lastSuccessAt)
        await http.resume(); _ = await refresh.value
        let result = await controller.projection()
        XCTAssertNotNil(result.state.lastGood); XCTAssertNotEqual(result.state.lastGood?.source.sessionScope, firstScope)
    }
    func testMidFlightSwitchRejectsAResponseAndClearsLastGood() async throws {
        let (controller, _, reader, http) = try fixture()
        _ = await controller.send(.start); await http.blockSand()
        let refresh = Task { await controller.send(.refresh(.manual(scope: .provider))) }
        await http.waitForSand(); await reader.set(fakeJWT("user_FAKE_B")); await http.resume(); _ = await refresh.value
        let result = await controller.projection(); XCTAssertNil(result.state.lastGood); XCTAssertEqual(result.state.failure?.code, .identityMismatch)
    }
    func testServerAccountMismatchRejectsUsageBeforeSandRequest() async throws {
        let (controller, _, _, http) = try fixture(); await http.configure(subject: "user_FAKE_B")
        _ = await controller.send(.start)
        let result = await controller.projection(), requests = await http.requests
        XCTAssertNil(result.state.lastGood); XCTAssertEqual(result.state.failure?.code, .identityMismatch); XCTAssertEqual(requests.count, 1)
    }
    func testMissingSessionClearsUnattributableLastGoodWithoutNetwork() async throws {
        let (controller, _, reader, http) = try fixture(); _ = await controller.send(.start)
        await reader.set(nil); let count = await http.requests.count
        _ = await controller.send(.refresh(.manual(scope: .provider)))
        let result = await controller.projection(), after = await http.requests.count
        XCTAssertNil(result.state.lastGood); XCTAssertEqual(count, after); XCTAssertEqual(result.state.failure?.code, .authenticationRequired)
    }
    func testSameAccountFailureRetainsOriginalLastSuccessAndMarksStale() async throws {
        let (controller, _, _, http) = try fixture(); _ = await controller.send(.start)
        let first = await controller.projection()
        await http.configure(status: 503); _ = await controller.send(.refresh(.manual(scope: .provider)))
        let result = await controller.projection()
        XCTAssertEqual(result.state.lastGood?.fetchedAt, first.state.lastGood?.fetchedAt)
        XCTAssertEqual(result.state.refresh.lastSuccessAt, first.state.refresh.lastSuccessAt)
        if case .stale = result.state.freshness {} else { XCTFail("Failure must be stale") }
    }
    func testHTTPAuthenticationFailuresDoNotDeclareNotEntitled() async throws {
        for status in [401,403,404,302] {
            let (controller, _, _, http) = try fixture(); await http.configure(status: status); _ = await controller.send(.start)
            let result = await controller.projection()
            XCTAssertNil(result.state.lastGood)
            if case .notEntitled = result.state.presence { XCTFail("HTTP error is not subscription proof") }
            XCTAssertEqual(result.state.failure?.code, status == 401 || status == 403 ? .authenticationRequired : (status == 302 ? .protocolViolation : .serviceUnavailable))
        }
    }
    func testTimeoutIsTypedAndRetainsSameAccountData() async throws {
        let (controller, _, _, http) = try fixture(); _ = await controller.send(.start)
        await http.configure(failure: URLError(.timedOut)); _ = await controller.send(.refresh(.manual(scope: .provider)))
        let result = await controller.projection(); XCTAssertNotNil(result.state.lastGood); XCTAssertEqual(result.state.failure?.code, .timedOut)
    }
    func testMalformedEmptyAndOversized200AreNotZeroOrSubscriptionAbsence() async throws {
        for data in [Data(), Data("{}".utf8), Data("bad".utf8), Data(repeating: 65, count: 65_537)] {
            let (controller, _, _, http) = try fixture(); await http.configure(body: data); _ = await controller.send(.start)
            let result = await controller.projection(); XCTAssertNil(result.state.lastGood); XCTAssertEqual(result.state.failure?.code, .schemaMismatch)
        }
    }
    func testDiagnosticsContainOnlyFixedSafeState() async throws {
        let (_, adapter, _, _) = try fixture()
        await adapter.setAccessEnabled(true)
        let snapshot = await adapter.diagnosticSnapshot()
        XCTAssertEqual(snapshot.safeFields, ["transport":"https", "state":"authorized"])
        XCTAssertFalse(String(describing: snapshot).contains("FAKE_SIGNATURE"))
    }
}

@MainActor final class GrokBotContractTests: XCTestCase {
    private func map(_ raw: String, meter: GrokBotMeteringSystem = .unknown) throws -> ProviderQuotaData {
        try GrokBotQuotaMapper.map(Data(raw.utf8), fetchedAt: grokNow, sessionScope: "fixture-scope", meteringSystem: meter)
    }
    func testJWTValidationRejectsExpiryMissingMalformedBoolAndHeaderInjection() throws {
        XCTAssertThrowsError(try CursorReadOnlySession(token: fakeJWT(expiration: grokNow.timeIntervalSince1970), now: grokNow))
        for token in ["a.b", "e30.e30.FAKE", "", fakeJWT(expiration: true), fakeJWT("evil;cookie=value"), fakeJWT() + "\r\nX: value"] {
            XCTAssertThrowsError(try CursorReadOnlySession(token: token, now: grokNow))
        }
        XCTAssertNoThrow(try CursorReadOnlySession(token: fakeJWT(), now: grokNow))
    }
    func testRequestAllowlistRejectsDomainSchemePathPortQueryAndWrongMethod() throws {
        for url in ["http://cursor.com/api/auth/me", "https://cursor.com.evil.test/api/auth/me", "https://evil.test/api/auth/me",
                    "https://cursor.com:443/api/auth/me", "https://cursor.com/api/auth/me?next=evil", "https://cursor.com/api/usage-summary", "https://user@cursor.com/api/auth/me"] {
            XCTAssertThrowsError(try GrokBotHTTPClient.validate(URLRequest(url: URL(string: url)!)))
        }
        var post = URLRequest(url: URL(string: "https://cursor.com/api/dashboard/get-sand-usage-status")!)
        XCTAssertThrowsError(try GrokBotHTTPClient.validate(post))
        post.httpMethod = "POST"; post.httpBody = Data("{}".utf8); XCTAssertNoThrow(try GrokBotHTTPClient.validate(post))
    }
    func testHTTPSIdentityIsExplicitAndCLIOrForeignOriginCannotMasquerade() throws {
        let data = try map(#"{"usagePercent":0}"#)
        XCTAssertNoThrow(try ProviderQuotaIdentityValidator.validate(data, expectedProviderID: .grokBot))
        XCTAssertEqual(data.source.executableIdentity, ""); XCTAssertEqual(data.source.cliVersion, "")
        XCTAssertThrowsError(try ProviderQuotaIdentityValidator.validateTransport(.init(providerID: .grokBot, adapterID: "fake", executableIdentity: "cli", cliVersion: "1", schemaVersion: "1", contractVersion: "1")))
        XCTAssertThrowsError(try ProviderQuotaIdentityValidator.validateTransport(.init(providerID: .grokBot, adapterID: "cursor-sand", executableIdentity: "", cliVersion: "", schemaVersion: "1", contractVersion: "1", transport: .https(origin: "https://evil.test", adapterVersion: "1", contractEvidence: GrokBotQuotaMapper.contractEvidence))))
    }
    func testMissingZeroAndInvalidPercentStayDistinct() throws {
        let unknown = try map(#"{"hasAvailableUsage":false}"#), zero = try map(#"{"usagePercent":0}"#)
        XCTAssertEqual(unknown.products[0].metrics[0].value, .unavailable(reason: .notReported))
        XCTAssertEqual(zero.products[0].metrics[0].value, .percent(.init(sourceValue: 0, sourceDirection: .used)))
        for raw in [#"{"usagePercent":-1}"#, #"{"usagePercent":101}"#] {
            XCTAssertEqual(try map(raw).products[0].metrics[0].value, .unavailable(reason: .invalidSourceValue(field: "usagePercent")))
        }
        XCTAssertThrowsError(try map(#"{"usagePercent":"0"}"#))
    }
    func testTrialExhaustionRetainsEntitlementAndExpiryIsNotResetOrJWTExpiry() throws {
        let data = try map(#"{"usagePercent":100,"hasAvailableUsage":false,"includedLimitZero":true,"hasNonZeroIncludedLimit":true,"sandTrialExpiresAt":"2026-10-20T00:00:00Z","nextResetTimestampUtc":"2026-10-22T00:00:00Z"}"#)
        XCTAssertEqual(data.grokBotUsage?.hasIncludedLimit, false)
        XCTAssertEqual(data.products[0].metrics.count, 1)
        XCTAssertEqual(data.products[0].metrics[0].window?.timeEvent?.kind, .entitlementExpiry)
        XCTAssertNotEqual(data.grokBotUsage?.nextResetAt, data.grokBotUsage?.trialExpiresAt)
        XCTAssertEqual(data.grokBotUsage?.hasAvailableUsage, false)
    }
    func testPaidAndTrialDoNotDoubleCountAndResetNeverRollsForward() throws {
        let raw = #"{"usagePercent":100,"includedLimitZero":false,"sandTrialExpiresAt":"2026-10-20T00:00:00Z","nextResetTimestampUtc":"2026-10-01T00:00:00Z","currentPeriodStart":"2026-09-24T00:00:00Z"}"#
        let data = try map(raw)
        XCTAssertEqual(data.products[0].metrics.count, 1)
        XCTAssertEqual(data.products[0].metrics[0].window?.timeEvent?.kind, .reset)
        XCTAssertLessThan(data.grokBotUsage!.nextResetAt!, grokNow)
        XCTAssertEqual(data.grokBotUsage?.usagePercent, 100)
    }
    func testUnknownMeteringPreservesSourceNumbersButDoesNotAssertSharedBalance() throws {
        let data = try map(#"{"usagePercent":25,"includedLimitZero":false}"#)
        XCTAssertEqual(data.grokBotUsage?.meteringSystem, .unknown)
        XCTAssertTrue(QuotaExhaustionEvaluator.statuses(in: data).isEmpty)
        var state = ProviderBootstrap.initialState(id: .grokBot, capabilities: .init(contractVersion: "1", loginMethod: nil, hasOfficialDocumentation: true, allowsExecutableSelection: false), now: grokNow)
        state.lastGood = data
        let projection = LiveProviderProjectionMapper.map(state, now: grokNow)
        XCTAssertTrue(projection.sourceNotice!.contains("计量体系未确认"))
        XCTAssertEqual(projection.products[0].metrics[0].value, .percent(value: 25, direction: .used))
    }
    func testXSharedHasNoEffectiveBalanceAndLegacyIsSeparate() throws {
        let shared = try map(#"{"usagePercent":25}"#, meter: .xShared)
        XCTAssertEqual(shared.products[0].metrics[0].value, .unavailable(reason: .unsupportedSemantics(sourceKind: "x-shared-pool")))
        XCTAssertEqual(try map(#"{"usagePercent":25}"#, meter: .legacyCursor).grokBotUsage?.meteringSystem, .legacyCursor)
    }
    func testMalformedDateIsSchemaErrorRatherThanInventedTime() throws {
        XCTAssertThrowsError(try map(#"{"usagePercent":25,"sandTrialExpiresAt":"tomorrow"}"#))
    }
    func testStaleAndAgeReducerPreserveAllSafeSourceFields() throws {
        let data = try map(#"{"usagePercent":25,"hasAvailableUsage":true,"currentPeriodStart":"2026-10-15T00:00:00Z"}"#)
        let capabilities = ProviderCapabilities(contractVersion: "1", loginMethod: nil, hasOfficialDocumentation: false, allowsExecutableSelection: false)
        var state = ProviderBootstrap.initialState(id: .grokBot, capabilities: capabilities, now: grokNow)
        state = ProviderReducer.reduce(state: state, event: .refreshSucceeded(data), now: grokNow)
        state = ProviderReducer.reduce(state: state, event: .ageTick(staleAfter: 1), now: grokNow.addingTimeInterval(10))
        XCTAssertEqual(state.lastGood?.grokBotUsage, data.grokBotUsage)
    }
}
