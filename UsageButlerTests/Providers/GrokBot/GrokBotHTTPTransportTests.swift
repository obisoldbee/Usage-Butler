import Foundation
import XCTest
@testable import UsageButlerProviders

private final class SandURLProtocol: URLProtocol, @unchecked Sendable {
    struct Behavior: Sendable { var status = 200; var bytes = Data("{}".utf8); var declaredSize: Int?; var failure: URLError? }
    private static let lock = NSLock()
    nonisolated(unsafe) private static var state = Behavior()
    nonisolated(unsafe) private static var starts = 0
    nonisolated(unsafe) private static var stopped = 0
    static func configure(_ behavior: Behavior) { lock.withLock { state = behavior; starts = 0; stopped = 0 } }
    static var requestCount: Int { lock.withLock { starts } }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let behavior = Self.lock.withLock { Self.starts += 1; return Self.state }
        if let error = behavior.failure { client?.urlProtocol(self,didFailWithError:error); return }
        var headers = ["Content-Type":"application/json"]
        if let size = behavior.declaredSize { headers["Content-Length"] = String(size) }
        if behavior.status == 302 { headers["Location"] = "https://evil.test/steal" }
        let response = HTTPURLResponse(url:request.url!,statusCode:behavior.status,httpVersion:"HTTP/1.1",headerFields:headers)!
        if behavior.status == 302 {
            client?.urlProtocol(self, wasRedirectedTo: URLRequest(url: URL(string: "https://evil.test/steal")!), redirectResponse: response)
        }
        client?.urlProtocol(self,didReceive:response,cacheStoragePolicy:.notAllowed)
        client?.urlProtocol(self,didLoad:behavior.bytes)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { Self.lock.withLock { Self.stopped += 1 } }
}

@MainActor final class GrokBotHTTPTransportTests: XCTestCase {
    private func request() -> URLRequest { URLRequest(url:URL(string:"https://cursor.com/api/auth/me")!) }
    private func transport() -> EphemeralGrokBotHTTPTransport { .init(protocolClasses:[SandURLProtocol.self]) }
    func testActualEphemeralTransportReadsBoundedSyntheticResponse() async throws {
        SandURLProtocol.configure(.init(bytes:Data("{}".utf8)))
        let (data,response) = try await transport().send(request())
        XCTAssertEqual(data,Data("{}".utf8)); XCTAssertEqual(response.statusCode,200)
    }
    func testAdvertisedOverlargeResponseIsCancelledBeforeAccumulation() async throws {
        SandURLProtocol.configure(.init(bytes:Data(),declaredSize:65_537))
        do { _ = try await transport().send(request()); XCTFail("Oversize response") }
        catch { XCTAssertEqual(error as? GrokBotReadError,.responseTooLarge) }
    }
    func testChunkedOversizeResponseIsBoundedWithoutContentLength() async throws {
        SandURLProtocol.configure(.init(bytes:Data(repeating:65,count:65_537)))
        do { _ = try await transport().send(request()); XCTFail("Oversize stream") }
        catch { XCTAssertEqual(error as? GrokBotReadError,.responseTooLarge) }
    }
    func testRedirectResponseCannotMakeASecondAuthenticatedRequest() async throws {
        SandURLProtocol.configure(.init(status:302))
        let (_,response) = try await transport().send(request())
        XCTAssertEqual(response.statusCode,302); XCTAssertEqual(SandURLProtocol.requestCount,1)
    }
    func testTransportTimeoutRemainsTyped() async throws {
        SandURLProtocol.configure(.init(failure:URLError(.timedOut)))
        do { _ = try await transport().send(request()); XCTFail("Timeout") }
        catch { XCTAssertEqual((error as? URLError)?.code,.timedOut) }
    }
    func testSharedRequestRedirectCannotForwardCursorCookieToGrok() async throws {
        SandURLProtocol.configure(.init(status:302))
        var request = URLRequest(url:GrokBotHTTPClient.Endpoint.shared.url)
        request.setValue("WorkosCursorSessionToken=SYNTHETIC_ONLY",forHTTPHeaderField:"Cookie")
        let (_,response) = try await transport().send(request)
        XCTAssertEqual(response.statusCode,302); XCTAssertEqual(SandURLProtocol.requestCount,1)
    }
    func testCancelledTaskCannotPublishTransportBytes() async throws {
        SandURLProtocol.configure(.init(bytes:Data("{}".utf8)))
        let task = Task { try Task.checkCancellation(); return try await transport().send(request()) }
        task.cancel()
        do { _ = try await task.value; XCTFail("Cancelled") } catch {}
    }
}
