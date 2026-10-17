import Foundation
import XCTest
import UsageButlerCore
import UsageButlerDomain
@testable import UsageButlerProviders

private actor InterleavedCursorReader: CursorSessionReading {
    private var loads = 0
    private var oldLoad: CheckedContinuation<CursorReadOnlySession?, Error>?
    private var arrived: CheckedContinuation<Void, Never>?
    private var firstIsBlocked = false
    func load() async throws -> CursorReadOnlySession? {
        loads += 1
        if loads == 1 {
            return try await withCheckedThrowingContinuation { continuation in
                oldLoad = continuation; firstIsBlocked = true; arrived?.resume(); arrived = nil
            }
        }
        let payload = try JSONSerialization.data(withJSONObject: ["sub":"auth0|user_RACE_FAKE_B","exp":2_000_000_000])
        let token = "e30." + payload.base64EncodedString().replacingOccurrences(of:"+",with:"-").replacingOccurrences(of:"/",with:"_").replacingOccurrences(of:"=",with:"") + ".FAKE_SIGNATURE"
        return try .init(token:token,now:Date(timeIntervalSince1970:1_792_022_400))
    }
    func waitForOldLoad() async { if firstIsBlocked { return }; await withCheckedContinuation { arrived = $0 } }
    func failOldLoad() { oldLoad?.resume(throwing:GrokBotReadError.databaseUnavailable); oldLoad = nil }
}
private actor RaceSandHTTP: GrokBotHTTPTransport {
    private var requests = 0
    private var hold = false
    private var entered = false
    private var blocked: CheckedContinuation<Void,Never>?
    private var arrival: CheckedContinuation<Void,Never>?
    func blockSand() { hold = true }
    func waitForSand() async { if entered { return }; await withCheckedContinuation { arrival = $0 } }
    func resumeSand() { blocked?.resume(); blocked = nil }
    func count() -> Int { requests }
    func send(_ request:URLRequest) async throws -> (Data,HTTPURLResponse) {
        requests += 1
        if hold, request.url!.path != "/api/auth/me" {
            hold = false
            await withCheckedContinuation { continuation in
                blocked = continuation; entered = true; arrival?.resume(); arrival = nil
            }
        }
        let raw = request.url!.path == "/api/auth/me" ? #"{"sub":"user_RACE_FAKE_B"}"# : #"{"availability":"available","weeklyIncludedStatus":{"status":"metered"},"weeklyIncludedUsage":{"usedCents":25,"budgetCents":100}}"#
        return (Data(raw.utf8),HTTPURLResponse(url:request.url!,statusCode:200,httpVersion:"HTTP/1.1",headerFields:nil)!)
    }
}
@MainActor final class GrokBotPreparationRaceTests:XCTestCase {
    func testLateFailedPreparationCannotPoisonNewConsentGenerationOrPreparedSession() async throws {
        let reader = InterleavedCursorReader(), http = RaceSandHTTP()
        let adapter = GrokBotProviderAdapter(reader:reader,client:.init(transport:http),now:{ Date(timeIntervalSince1970:1_792_022_400) })
        await adapter.setAccessEnabled(true)
        let old = Task { await adapter.prepareForRead(retaining:nil) }
        await reader.waitForOldLoad()
        await adapter.setAccessEnabled(false); await adapter.setAccessEnabled(true)
        _ = await adapter.prepareForRead(retaining:nil)
        await reader.failOldLoad(); _ = await old.value
        let result = await adapter.read(scope:.provider)
        guard case .success = result else { return XCTFail("Old load error overwrote the prepared session for the new consent generation: \(result)") }
        let requests = await http.count(), retained = await adapter.mayRetainLastGoodAfterRead()
        XCTAssertEqual(requests,2)
        XCTAssertTrue(retained)
    }
    func testLateFailedPreparationCannotInvalidateNewReadAlreadyInFlight() async throws {
        let reader = InterleavedCursorReader(), http = RaceSandHTTP()
        let adapter = GrokBotProviderAdapter(reader:reader,client:.init(transport:http),now:{ Date(timeIntervalSince1970:1_792_022_400) })
        await adapter.setAccessEnabled(true)
        let old = Task { await adapter.prepareForRead(retaining:nil) }
        await reader.waitForOldLoad()
        await adapter.setAccessEnabled(false); await adapter.setAccessEnabled(true)
        _ = await adapter.prepareForRead(retaining:nil)
        await http.blockSand()
        let live = Task { await adapter.read(scope:.provider) }
        await http.waitForSand()
        await reader.failOldLoad(); _ = await old.value
        await http.resumeSand()
        let result = await live.value, retained = await adapter.mayRetainLastGoodAfterRead()
        guard case .success = result else { return XCTFail("Old preparation corrupted a new in-flight read") }
        XCTAssertTrue(retained)
        let authentication = await adapter.authenticationAfterRead()
        guard case .healthy = authentication else { return XCTFail("Current server authentication must survive") }
    }

}
