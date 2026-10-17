import Foundation
import XCTest
import UsageButlerCore
import UsageButlerDomain
@testable import UsageButlerProviders
@testable import UsageButlerInfrastructure

final class OpenAICreditsSemanticsTests: XCTestCase {
    private func mapping(_ credits: String) throws -> ProviderQuotaData {
        let account = OpenAIQuotaProjector.projectAccount(try OpenAIAppServerDecoder.decodeAccountRead(from: Data(#"{"account":{"type":"chatgpt"},"requiresOpenaiAuth":false}"#.utf8)))
        let raw = "{\"rateLimitsByLimitId\":{\"codex\":{\"limitId\":\"codex\",\"primary\":{\"usedPercent\":25,\"windowDurationMins\":10080,\"resetsAt\":1792022400},\"credits\":" + credits + "}}}"
        let limits = try OpenAIQuotaProjector.projectRateLimits(OpenAIAppServerDecoder.decodeRateLimitsRead(from: Data(raw.utf8)))
        let source = ProviderSourceIdentity(providerID:.openAI,adapterID:"openai.codex-app-server",executableIdentity:"FAKE_CLI",cliVersion:"fixture",schemaVersion:"account-rate-limits-v1",contractVersion:"usage-butler-provider-contract-v0.8")
        return try OpenAIQuotaDomainMapper.map(account:account,rateLimits:limits,source:source,fetchedAt:Date(timeIntervalSince1970:1_792_022_400)).data
    }
    private func projection(_ data: ProviderQuotaData) -> Stage3ProviderProjection {
        let state = ProviderReducer.reduce(state:ProviderBootstrap.initialState(id:.openAI,capabilities:.init(contractVersion:"fixture",loginMethod:nil,hasOfficialDocumentation:false,allowsExecutableSelection:false),now:data.fetchedAt),event:.refreshSucceeded(data),now:data.fetchedAt)
        return LiveProviderProjectionMapper.map(state,now:data.fetchedAt)
    }
    func testDecimalStringBalancePreservesPrecisionAndAppearsOnQuotaCard() throws {
        let value = "0.1234567890123456789012345678"
        let data = try mapping("{\"hasCredits\":true,\"unlimited\":false,\"balance\":\"" + value + "\"}")
        XCTAssertEqual(data.balances.first?.amount,Decimal(string:value))
        XCTAssertEqual(projection(data).products[0].metrics.last?.value,.balance(amount:Decimal(string:value),unlimited:false))
    }
    func testMalformedNumericSuffixCannotBeParsedAsPartialBalance() throws {
        XCTAssertTrue(try mapping(#"{"balance":"12not-real"}"#).balances.isEmpty)
    }
    func testNullAndHasCreditsCannotBecomeNumericBalance() throws {
        let data = try mapping(#"{"hasCredits":true,"unlimited":false,"balance":null}"#)
        XCTAssertNil(data.balances.first?.amount)
        XCTAssertEqual(data.balances.first?.hasCredits,true)
        XCTAssertEqual(projection(data).products[0].metrics.last?.value,.balance(amount:nil,unlimited:false))
        XCTAssertTrue(QuotaExhaustionEvaluator.statuses(in:data).allSatisfy { !$0.metricKey.contains("credits.balance") })
    }
    func testExplicitZeroIsKnownEvenWhenHasCreditsFalse() throws {
        let data = try mapping(#"{"hasCredits":false,"unlimited":false,"balance":"0"}"#)
        XCTAssertEqual(data.balances.first?.amount,0)
        XCTAssertEqual(projection(data).products[0].metrics.last?.value,.balance(amount:0,unlimited:false))
    }
    func testUnlimitedIsSeparateFromZeroAndDoesNotTriggerExhaustion() throws {
        let data = try mapping(#"{"hasCredits":true,"unlimited":true,"balance":"0"}"#)
        XCTAssertEqual(data.balances.first?.unlimited,true)
        XCTAssertEqual(projection(data).products[0].metrics.last?.value,.balance(amount:0,unlimited:true))
        XCTAssertTrue(QuotaExhaustionEvaluator.statuses(in:data).allSatisfy { !$0.metricKey.contains("credits.balance") })
    }
    func testAdditiveCacheFieldsRoundTripUnknownAndUnlimited() throws {
        for credits in [#"{"balance":null,"unlimited":true}"#,#"{"balance":null,"hasCredits":false}"#,#"{"balance":"0.0000000000000001"}"#] {
            let data = try mapping(credits)
            let encoded = try JSONEncoder().encode(ProviderQuotaCacheEnvelopeDTO(domain:data))
            let read = try JSONDecoder().decode(ProviderQuotaCacheEnvelopeDTO.self,from:encoded).domain(requestedProviderID:.openAI)
            XCTAssertEqual(read.balances.map(\.amount),data.balances.map(\.amount))
            XCTAssertEqual(read.balances.map(\.unlimited),data.balances.map(\.unlimited))
        }
    }
    func testOldV1CLICacheDecodesWhenNewFieldsAbsent() throws {
        let data = try mapping(#"{"balance":"12.5"}"#)
        let encoded = try JSONEncoder().encode(ProviderQuotaCacheEnvelopeDTO(domain:data))
        func old(_ object:Any) -> Any {
            if let array = object as? [Any] { return array.map(old) }
            if let object = object as? [String:Any] { return object.filter { !["transport","sessionScope","unlimited","hasCredits"].contains($0.key) }.mapValues(old) }
            return object
        }
        let legacy = try JSONSerialization.data(withJSONObject:old(JSONSerialization.jsonObject(with:encoded)))
        let read = try JSONDecoder().decode(ProviderQuotaCacheEnvelopeDTO.self,from:legacy).domain(requestedProviderID:.openAI)
        XCTAssertEqual(read.source.transport,.cli); XCTAssertEqual(read.balances.first?.amount,Decimal(string:"12.5")); XCTAssertEqual(read.balances.first?.unlimited,false)
    }
    func testGrokAccountScopedDataCannotEnterDiskCache() throws {
        let data = try GrokBotQuotaMapper.map(Data(#"{"usagePercent":25}"#.utf8),fetchedAt:Date(),sessionScope:"fixture")
        XCTAssertThrowsError(try ProviderQuotaCacheEnvelopeDTO(domain:data))
    }
}
