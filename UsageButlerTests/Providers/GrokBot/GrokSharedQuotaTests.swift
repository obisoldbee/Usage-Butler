import Foundation
import XCTest
import UsageButlerCore
import UsageButlerDomain
@testable import UsageButlerProviders

@MainActor final class GrokSharedQuotaEndpointTests: XCTestCase {
    func testNativeSharedEndpointRequiresExactUserScopeAndGET() throws {
        let request = URLRequest(url: URL(string: "https://cursor.com/api/dashboard/v2/usage-status?scope=user")!)
        XCTAssertNoThrow(try GrokBotHTTPClient.validate(request))
        for suffix in ["", "?scope=team", "?scope=organization", "?scope=User", "?scope=user&userId=1", "?scope=user&scope=team", "?scope=%75ser", "?scope=user#fragment", "?scope=user&", "?scope=user%00"] {
            XCTAssertThrowsError(try GrokBotHTTPClient.validate(URLRequest(url: URL(string: "https://cursor.com/api/dashboard/v2/usage-status" + suffix)!)))
        }
        for url in ["https://grok.com/dashboard/api/dashboard/v2/usage-status?scope=user", "https://cursor.com:443/api/dashboard/v2/usage-status?scope=user",
                    "https://cursor.com/api/dashboard/v2/%75sage-status?scope=user", "https://cursor.com/api/auth/me?scope=user"] {
            XCTAssertThrowsError(try GrokBotHTTPClient.validate(URLRequest(url: URL(string: url)!)))
        }
        var body = request; body.httpBody = Data("{}".utf8)
        XCTAssertThrowsError(try GrokBotHTTPClient.validate(body))
        for method in ["POST", "PUT", "DELETE", "HEAD", "get"] {
            var other = request; other.httpMethod = method
            // Foundation canonicalizes lowercase standard methods before validation.
            if other.httpMethod != "GET" { XCTAssertThrowsError(try GrokBotHTTPClient.validate(other)) }
        }
    }
}

@MainActor final class GrokSharedQuotaMapperTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_792_022_400)
    private func map(_ week: String = #"{"usedCents":30838,"budgetCents":55395,"resetCounter":2,"periodStart":"2026-10-13T15:53:18.651Z","resetsAt":"2026-10-20T15:53:18.651Z"}"#,
                     month: String = #"{"usedCents":0,"limitCents":null,"creditsUsedCents":0,"periodStart":"2026-10-01T00:00:00.000Z","resetsAt":"2026-11-01T00:00:00.000Z"}"#,
                     status: String = "metered", availability: String = "available") throws -> ProviderQuotaData {
        try GrokSharedQuotaMapper.map(Data("{\"availability\":\"\(availability)\",\"weeklyIncludedStatus\":{\"status\":\"\(status)\"},\"weeklyIncludedUsage\":\(week),\"monthlyUsage\":\(month)}".utf8), fetchedAt: now, sessionScope: "SHARED-SYNTHETIC")
    }
    private func project(_ data: ProviderQuotaData) -> Stage3ProviderProjection {
        var state = ProviderBootstrap.initialState(id: .grokBot, capabilities: .init(contractVersion: "test", loginMethod: nil, hasOfficialDocumentation: true, allowsExecutableSelection: false), now: now)
        state = ProviderReducer.reduce(state: state, event: .refreshSucceeded(data), now: now)
        return LiveProviderProjectionMapper.map(state, now: now)
    }
    func testObservedContractUsesPreciseWeeklyRatioAndOfficialFloorRatherThanRounded56() throws {
        let data = try map(), shared = try XCTUnwrap(data.grokBotUsage?.shared)
        XCTAssertEqual(data.grokBotUsage?.meteringSystem, .xShared)
        XCTAssertEqual(shared.usagePercent, Decimal(30838) / Decimal(55395) * 100)
        XCTAssertEqual(shared.officialDisplayPercent, 55)
        XCTAssertEqual(shared.remainingCents, 24557)
        XCTAssertEqual(shared.remainingPercent, 100 - shared.usagePercent!)
        XCTAssertEqual(data.products.count, 1); XCTAssertEqual(data.products[0].metrics.count, 1)
        XCTAssertEqual(data.products[0].metrics[0].window?.kind, .weekly)
        XCTAssertEqual(shared.resetCounter, 2); XCTAssertTrue(data.resetEntitlements.isEmpty); XCTAssertTrue(data.balances.isEmpty)
        XCTAssertNotEqual(shared.resetsAt, shared.monthlyResetsAt)
        XCTAssertEqual(shared.periodStart, data.products[0].metrics[0].window?.startsAt)
        XCTAssertEqual(data.products[0].metrics[0].window?.timeEvent?.occursAt, shared.resetsAt)
        XCTAssertNoThrow(try ProviderQuotaIdentityValidator.validate(data, expectedProviderID: .grokBot))
        let projection = project(data), metric = projection.products[0].metrics[0]
        XCTAssertEqual(projection.products[0].title, "Grok / Cursor 共享周额度")
        XCTAssertEqual(metric.displayValueText, "已用 55%")
        guard case let .percent(value, .used) = metric.value else { return XCTFail("Shared percentage must render") }
        XCTAssertEqual(value, NSDecimalNumber(decimal: shared.usagePercent!).doubleValue)
        XCTAssertTrue(metric.detailText!.contains("本月积分已用 US$0"))
        XCTAssertTrue(metric.detailText!.contains("本月额外用量限额 未设置"))
        XCTAssertTrue(metric.detailText!.contains("额外积分余额未提供"))
        XCTAssertFalse(metric.detailText!.contains("剩余重置"))
        XCTAssertNil(projection.sourceNotice)
    }
    func testSharedExhaustionUsesOneWeeklyPoolAndNoMonthlySpendOrResetCounter() throws {
        let data = try map(#"{"usedCents":100,"budgetCents":100,"resetCounter":2}"#)
        let statuses = QuotaExhaustionEvaluator.statuses(in: data)
        XCTAssertEqual(statuses.count, 1); XCTAssertEqual(statuses.first?.isExhausted, true)
        XCTAssertEqual(statuses.first?.windowLabel, "每周")
        XCTAssertEqual(statuses.first?.productLabel, "Grok / Cursor 共享周额度")
        XCTAssertEqual(QuotaExhaustionEvaluator.statuses(in: try map(#"{"usedCents":0,"budgetCents":100}"#)).first?.isExhausted, false)
        XCTAssertTrue(QuotaExhaustionEvaluator.statuses(in: try map(status: "unavailable")).isEmpty)
    }
    func testValidZeroPositiveUnderOneAndExactBoundary() throws {
        for (used, budget, display) in [(0, 100, 0), (1, 1000, 1), (559, 1000, 55), (560, 1000, 56), (100, 100, 100)] {
            let shared = try XCTUnwrap(map("{\"usedCents\":\(used),\"budgetCents\":\(budget)}").grokBotUsage?.shared)
            XCTAssertEqual(shared.weeklyValueState, .available); XCTAssertEqual(shared.officialDisplayPercent, display)
        }
    }
    func testMissingZeroNegativeOverflowAndOverageRemainDifferent() throws {
        for (raw, expected) in [(#"{"usedCents":0}"#, GrokSharedUsageObservation.WeeklyValueState.notReported),
                                (#"{"budgetCents":100}"#, .notReported), (#"{"usedCents":0,"budgetCents":0}"#, .zeroBudget),
                                (#"{"usedCents":-1,"budgetCents":100}"#, .invalid), (#"{"usedCents":0,"budgetCents":-1}"#, .invalid),
                                (#"{"usedCents":101,"budgetCents":100}"#, .overBudget)] {
            let data = try map(raw), shared = try XCTUnwrap(data.grokBotUsage?.shared)
            XCTAssertEqual(shared.weeklyValueState, expected); XCTAssertNil(shared.remainingCents); XCTAssertNil(shared.officialDisplayPercent)
            XCTAssertEqual(project(data).products[0].metrics[0].value, .unavailable)
            if expected == .overBudget { XCTAssertEqual(shared.usagePercent, 101); XCTAssertEqual(project(data).products[0].metrics[0].displayValueText, "已超出周额度") }
        }
        for raw in [#"{"usedCents":1e999,"budgetCents":100}"#, #"{"usedCents":"NaN","budgetCents":100}"#, #"{"usedCents":true,"budgetCents":100}"#, #"{"usedCents":"0","budgetCents":100}"#] { XCTAssertThrowsError(try map(raw)) }
        let nan = GrokSharedUsageObservation(availability: .available, weeklyStatus: .metered, usedCents: .nan, budgetCents: 100, resetCounter: nil, periodStart: nil, resetsAt: nil, monthlyUsedCents: nil, monthlyLimit: .notReported, monthlyCreditsUsedCents: nil, monthlyPeriodStart: nil, monthlyResetsAt: nil)
        XCTAssertEqual(nan.weeklyValueState, .invalid); XCTAssertNil(nan.usagePercent)
    }
    func testMonthAndWeekDoNotMixAndNullLimitIsUnsetRatherThanZeroOrUnlimited() throws {
        let data = try map(#"{"usedCents":25,"budgetCents":100}"#, month: #"{"usedCents":99999,"limitCents":0,"creditsUsedCents":123.45}"#)
        let shared = try XCTUnwrap(data.grokBotUsage?.shared)
        XCTAssertEqual(shared.usagePercent, 25); XCTAssertEqual(shared.monthlyUsedCents, 99999)
        XCTAssertEqual(shared.monthlyLimit, .amount(0)); XCTAssertEqual(shared.monthlyCreditsUsedCents, Decimal(string: "123.45"))
        XCTAssertEqual(try map(month: "{}").grokBotUsage?.shared?.monthlyLimit, .notReported)
        XCTAssertEqual(try map().grokBotUsage?.shared?.monthlyLimit, .unset)
        XCTAssertFalse(project(data).products[0].metrics[0].detailText!.contains("余额 US$1.2345"))
        XCTAssertTrue(data.balances.isEmpty)
    }
    func testUnknownAvailabilityAndStatusCannotClaimAUsablePoolFromNumbers() throws {
        for availability in ["identity_unlinked", "missing_team_id", "new-unknown"] {
            let data = try map(availability: availability)
            XCTAssertEqual(data.grokBotUsage?.shared?.weeklyValueState, .unavailable)
            XCTAssertNil(data.grokBotUsage?.shared?.usagePercent)
            XCTAssertNotNil(project(data).sourceNotice)
        }
        for status in ["not_applicable", "unavailable", "new-unknown"] {
            let data = try map(status: status)
            XCTAssertEqual(data.grokBotUsage?.shared?.weeklyValueState, .unavailable)
            XCTAssertEqual(project(data).products[0].metrics[0].value, .unavailable)
            if status == "not_applicable" { XCTAssertEqual(project(data).products[0].metrics[0].displayValueText, "共享周额度不适用") }
        }
        XCTAssertThrowsError(try GrokSharedQuotaMapper.map(Data("{}".utf8), fetchedAt: now, sessionScope: "fake"))
        XCTAssertThrowsError(try map(#"{"usedCents":25,"budgetCents":100,"resetsAt":"tomorrow"}"#))
    }
    func testSandFieldsCannotMasqueradeAsSharedOrBecomeFallback() throws {
        XCTAssertThrowsError(try GrokSharedQuotaMapper.map(Data(#"{"usagePercent":55,"nextResetTimestampUtc":"2026-10-20T00:00:00Z"}"#.utf8), fetchedAt: now, sessionScope: "fake"))
        let data = try map()
        let source = GrokBotQuotaMapper.source(sessionScope: data.source.sessionScope)
        let counterfeit = ProviderQuotaData(providerID: .grokBot, source: source, fetchedAt: now, grokBotUsage: data.grokBotUsage, products: data.products, balances: [], resetEntitlements: [])
        XCTAssertThrowsError(try ProviderQuotaIdentityValidator.validate(counterfeit, expectedProviderID: .grokBot))
        var state = ProviderBootstrap.initialState(id: .grokBot, capabilities: .init(contractVersion: "test", loginMethod: nil, hasOfficialDocumentation: true, allowsExecutableSelection: false), now: now)
        state = ProviderReducer.reduce(state: state, event: .refreshSucceeded(data), now: now)
        state = ProviderReducer.reduce(state: state, event: .refreshFailed(.init(code: .timedOut, retryClass: .backoff, userMessageKey: "test", diagnosticCode: "test", recovery: .retry)), now: now.addingTimeInterval(60))
        XCTAssertEqual(state.lastGood?.grokBotUsage, data.grokBotUsage)
        XCTAssertEqual(state.lastGood?.fetchedAt, now)
        guard case let .stale(asOf)? = LiveProviderProjectionMapper.map(state, now: now.addingTimeInterval(60)).products[0].metrics[0].dataState else { return XCTFail("Stale original time must remain visible") }
        XCTAssertEqual(asOf, now)
    }
    func testNewTransportSchemaAndEvidenceAreBoundTogether() throws {
        let source = GrokSharedQuotaMapper.source(sessionScope: "fixture")
        XCTAssertNoThrow(try ProviderQuotaIdentityValidator.validateTransport(source))
        for (schema, evidence) in [("cursor-sand-1", GrokSharedQuotaMapper.contractEvidence), (source.schemaVersion, GrokBotQuotaMapper.contractEvidence)] {
            let foreign = ProviderSourceIdentity(providerID: .grokBot, adapterID: source.adapterID, executableIdentity: "", cliVersion: "", schemaVersion: schema, contractVersion: source.contractVersion,
                transport: .https(origin: "https://cursor.com", adapterVersion: "1", contractEvidence: evidence), sessionScope: "fixture")
            XCTAssertThrowsError(try ProviderQuotaIdentityValidator.validateTransport(foreign))
        }
    }
}
