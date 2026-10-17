import Foundation
import XCTest
import UsageButlerCore
import UsageButlerDomain
@testable import UsageButlerProviders
final class OpenAICreditsCardRegressionTests: XCTestCase {
 func testReportedBalanceAppearsOnQuotaCard() throws {
  let account=OpenAIQuotaProjector.projectAccount(try OpenAIAppServerDecoder.decodeAccountRead(from:Data(#"{"account":{"type":"chatgpt"},"requiresOpenaiAuth":false}"#.utf8)))
  let limits=try OpenAIQuotaProjector.projectRateLimits(OpenAIAppServerDecoder.decodeRateLimitsRead(from:Data(#"{"rateLimitsByLimitId":{"codex":{"limitId":"codex","primary":{"usedPercent":25,"windowDurationMins":10080,"resetsAt":1792022400},"credits":{"hasCredits":true,"unlimited":false,"balance":"12.5"}}}}"#.utf8)))
  let source=ProviderSourceIdentity(providerID:.openAI,adapterID:"fixture",executableIdentity:"FAKE_CLI",cliVersion:"fixture",schemaVersion:"fixture",contractVersion:"fixture")
  let now=Date(timeIntervalSince1970:1792022400)
  let data=try OpenAIQuotaDomainMapper.map(account:account,rateLimits:limits,source:source,fetchedAt:now).data
  XCTAssertEqual(data.balances.first?.amount,Decimal(string:"12.5"))
  let state=ProviderReducer.reduce(state:ProviderBootstrap.initialState(id:.openAI,capabilities:.init(contractVersion:"fixture",loginMethod:nil,hasOfficialDocumentation:false,allowsExecutableSelection:false),now:now),event:.refreshSucceeded(data),now:now)
  let visible=LiveProviderProjectionMapper.map(state,now:now)
  XCTAssertTrue(visible.products.flatMap(\.metrics).contains { $0.title == "Credits" },"Source balance must be visible on the quota card")
 }
}
