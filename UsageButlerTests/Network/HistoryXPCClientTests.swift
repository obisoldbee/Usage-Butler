import Foundation
import XCTest
import UsageButlerDomain
@testable import UsageButlerInfrastructure

private func xpcStatus() -> BackgroundNetworkResponse {
    .init(status: .init(version: BackgroundNetworkWire.version, pid: 1, executableSHA256: "synthetic",
        sqliteVersion: "fixture", sqliteSourceID: "fixture", startedAt: Date(timeIntervalSince1970: 0),
        sourceState: .active, sourceIssue: nil, coverage: .init(), rule: .init()))
}
private final class GatedHistoryTransport: HistoryXPCTransport, @unchecked Sendable {
    private let lock = NSLock()
    let requests = AsyncStream<BackgroundNetworkRequest>.makeStream()
    private var pending: [@Sendable (Result<Data, Error>) -> Void] = []
    private var invalidations = 0
    private var sent = 0
    private var usable = true
    private var loss: (@Sendable () -> Void)?
    var isUsable: Bool { lock.lock(); defer { lock.unlock() }; return usable }
    func activate(disconnected: @escaping @Sendable () -> Void) {
        lock.lock(); usable = true; loss = disconnected; lock.unlock()
    }
    func interruptBeforeActorNotification() -> (@Sendable () -> Void)? {
        lock.lock(); defer { lock.unlock() }; usable = false; return loss
    }
    var invalidationCount: Int { lock.lock(); defer { lock.unlock() }; return invalidations }
    var requestCount: Int { lock.lock(); defer { lock.unlock() }; return sent }
    func exchange(_ data: Data, reply: @escaping @Sendable (Result<Data, Error>) -> Void) {
        do {
            let request = try JSONDecoder().decode(BackgroundNetworkRequest.self, from: data)
            lock.lock(); pending.append(reply); sent += 1; lock.unlock()
            requests.continuation.yield(request)
        } catch { reply(.failure(error)) }
    }
    func respond(_ index: Int, _ response: BackgroundNetworkResponse) throws {
        try respondBytes(index, JSONEncoder().encode(response))
    }
    func respondBytes(_ index: Int, _ data: Data) {
        lock.lock(); let reply = pending[index]; lock.unlock(); reply(.success(data))
    }
    func invalidate() { lock.lock(); invalidations += 1; usable = false; lock.unlock() }
}

private final class HistoryTransportFactory: @unchecked Sendable {
    private let lock = NSLock()
    private var transports: [GatedHistoryTransport]
    init(_ transports: [GatedHistoryTransport]) { self.transports = transports }
    func make() -> any HistoryXPCTransport { lock.lock(); defer { lock.unlock() }; return transports.removeFirst() }
}

private actor HistoryTimeoutGate {
    let entered = AsyncStream<Int>.makeStream()
    private var waits: [Int: CheckedContinuation<Void, Never>] = [:]
    private var next = 0
    func wait() async {
        let index = next; next += 1
        await withCheckedContinuation { waits[index] = $0; entered.continuation.yield(index) }
    }
    func release(_ index: Int) { waits.removeValue(forKey: index)?.resume() }
}

@MainActor
final class HistoryXPCClientTests: XCTestCase {
    private func query(_ key: String) -> BackgroundNetworkRequest {
        var r = BackgroundNetworkRequest(.query); r.selectedKey = key
        r.range = .init(start: Date(timeIntervalSince1970: 60), end: Date(timeIntervalSince1970: 120)); return r
    }
    func testBusyRequestDoesNotBreakBlockedQueryOrStatusOnSameConnection() async throws {
        let transport = GatedHistoryTransport(), client = HistoryXPCClient(makeConnection: { transport })
        var requests = transport.requests.stream.makeAsyncIterator()
        let warmup = Task { try await client.request(.init(.status)) }
        _ = await requests.next(); try transport.respond(0, xpcStatus()); _ = try await warmup.value
        let a = Task { try await client.request(query("synthetic-A")) }
        _ = await requests.next()
        let b = Task { try await client.request(query("synthetic-B")) }
        _ = await requests.next(); try transport.respond(2, .init(error: "history.query-busy"))
        do { _ = try await b.value; XCTFail("B must report busy") }
        catch { if case BackgroundNetworkWire.Failure.remote("history.query-busy") = error {} else { XCTFail("unexpected error: \(error)") } }
        XCTAssertEqual(transport.invalidationCount, 0)
        let c = Task { try await client.request(.init(.status)) }
        _ = await requests.next(); try transport.respond(3, xpcStatus())
        let status = try await c.value; XCTAssertNotNil(status.status)
        try transport.respond(1, .init())
        do { _ = try await a.value } catch { XCTFail("B must not invalidate A: \(error)") }
        await client.disconnect()
    }
    func testFirstPayloadContainsOnlyMinimalStatusBeforeSelectedQuery() async throws {
        let transport = GatedHistoryTransport(), client = HistoryXPCClient(makeConnection: { transport })
        var requests = transport.requests.stream.makeAsyncIterator()
        let q = Task { try await client.request(query("synthetic-selected-key")) }
        let first = await requests.next()
        XCTAssertEqual(first?.operation, .status)
        XCTAssertNil(first?.selectedKey); XCTAssertNil(first?.range); XCTAssertNil(first?.rule)
        // Invalid first response must fail closed without emitting the query.
        transport.respondBytes(0, Data("not-json".utf8))
        do { _ = try await q.value; XCTFail("malformed response") } catch {}
        XCTAssertEqual(transport.invalidationCount, 1)
    }
    func testConcurrentWaitersShareHandshakeAndCancellationCannotOpenSensitiveGate() async throws {
        let transport = GatedHistoryTransport(), admissions = AsyncStream<Void>.makeStream()
        let client = HistoryXPCClient(makeConnection: { transport }, onRequestAdmitted: { admissions.continuation.yield(()) })
        var admitted = admissions.stream.makeAsyncIterator(), requests = transport.requests.stream.makeAsyncIterator()
        let a = Task { try await client.request(query("canceled-selected-key")) }
        _ = await admitted.next(); let first = await requests.next(); XCTAssertEqual(first?.operation, .status)
        let b = Task { try await client.request(query("allowed-selected-key")) }
        _ = await admitted.next() // Both entered the real actor before status reply.
        XCTAssertEqual(transport.requestCount, 1)
        a.cancel(); try transport.respond(0, xpcStatus())
        let next = await requests.next(); XCTAssertEqual(next?.selectedKey, "allowed-selected-key")
        try transport.respond(1, .init()); _ = try await b.value
        do { _ = try await a.value; XCTFail("canceled waiter") } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(transport.requestCount, 2); XCTAssertEqual(transport.invalidationCount, 0)
        await client.disconnect()
    }
    func testCanceledAuthenticatedRequestAndLateMalformedReplyDoNotBreakStatus() async throws {
        let transport = GatedHistoryTransport(), client = HistoryXPCClient(makeConnection: { transport })
        var requests = transport.requests.stream.makeAsyncIterator()
        let warm = Task { try await client.request(.init(.status)) }
        _ = await requests.next(); try transport.respond(0, xpcStatus()); _ = try await warm.value
        let a = Task { try await client.request(query("cancel")) }
        _ = await requests.next(); a.cancel()
        do { _ = try await a.value; XCTFail("cancel") } catch { XCTAssertTrue(error is CancellationError) }
        transport.respondBytes(1, Data("late-invalid-json".utf8))
        let c = Task { try await client.request(.init(.status)) }
        _ = await requests.next(); try transport.respond(2, xpcStatus()); _ = try await c.value
        XCTAssertEqual(transport.invalidationCount, 0); await client.disconnect()
    }
    func testRequestTimeoutKeepsAuthenticatedConnectionAndOtherRequestAlive() async throws {
        let transport = GatedHistoryTransport(), gate = HistoryTimeoutGate()
        let client = HistoryXPCClient(makeConnection: { transport }, timeout: { await gate.wait() })
        var requests = transport.requests.stream.makeAsyncIterator(), timers = gate.entered.stream.makeAsyncIterator()
        let warm = Task { try await client.request(.init(.status)) }
        _ = await requests.next(); _ = await timers.next()
        try transport.respond(0, xpcStatus()); _ = try await warm.value
        let a = Task { try await client.request(query("timeout")) }
        _ = await requests.next(); _ = await timers.next()
        let c = Task { try await client.request(.init(.status)) }
        _ = await requests.next(); _ = await timers.next()
        await gate.release(1)
        do { _ = try await a.value; XCTFail("timeout") } catch {
            if case BackgroundNetworkWire.Failure.timeout = error {} else { XCTFail("wrong failure") }
        }
        try transport.respond(2, xpcStatus()); _ = try await c.value
        XCTAssertEqual(transport.invalidationCount, 0)
        await gate.release(0); await gate.release(2); await client.disconnect()
    }
    func testOldReplyCannotInvalidateReconnectedGenerationAndHandshakeRepeats() async throws {
        let transport = GatedHistoryTransport(), client = HistoryXPCClient(makeConnection: { transport })
        var requests = transport.requests.stream.makeAsyncIterator()
        let warm = Task { try await client.request(.init(.status)) }
        _ = await requests.next(); try transport.respond(0, xpcStatus()); _ = try await warm.value
        let old = Task { try await client.request(query("old")) }
        _ = await requests.next(); await client.disconnect()
        let new = Task { try await client.request(query("new")) }
        let handshake = await requests.next(); XCTAssertEqual(handshake?.operation, .status); XCTAssertNil(handshake?.selectedKey)
        try transport.respond(2, xpcStatus())
        let selected = await requests.next(); XCTAssertEqual(selected?.selectedKey, "new")
        transport.respondBytes(1, Data("old-malformed".utf8))
        do { _ = try await old.value; XCTFail("old generation") } catch {}
        XCTAssertEqual(transport.invalidationCount, 1)
        try transport.respond(3, .init()); _ = try await new.value
        XCTAssertEqual(transport.invalidationCount, 1); await client.disconnect()
    }
    func testBadProtocolOversizeAndUnknownBusinessErrorsInvalidateConnection() async throws {
        var badProtocol = xpcStatus(); badProtocol.protocolVersion = 99
        for data in [try JSONEncoder().encode(badProtocol), Data(repeating: 0, count: BackgroundNetworkWire.maximumResponseBytes + 1),
                     try JSONEncoder().encode(BackgroundNetworkResponse(error: "not-a-business-code"))] {
            let transport = GatedHistoryTransport(), client = HistoryXPCClient(makeConnection: { transport })
            var requests = transport.requests.stream.makeAsyncIterator()
            let request = Task { try await client.request(query("must-not-send")) }
            _ = await requests.next(); transport.respondBytes(0, data)
            do { _ = try await request.value; XCTFail("invalid response") } catch {}
            XCTAssertEqual(transport.requestCount, 1); XCTAssertEqual(transport.invalidationCount, 1)
        }
    }
    func testTransportInterruptionSealForcesHandshakeBeforeDelayedActorCallback() async throws {
        let old = GatedHistoryTransport(), new = GatedHistoryTransport(), factory = HistoryTransportFactory([old, new])
        let client = HistoryXPCClient(makeConnection: { factory.make() })
        var oldRequests = old.requests.stream.makeAsyncIterator(), newRequests = new.requests.stream.makeAsyncIterator()
        let warm = Task { try await client.request(.init(.status)) }
        _ = await oldRequests.next(); try old.respond(0, xpcStatus()); _ = try await warm.value
        let pending = Task { try await client.request(query("old-pending")) }; _ = await oldRequests.next()
        let delayedNotification = old.interruptBeforeActorNotification()
        let sensitive = Task { try await client.request(query("after-interruption")) }
        let first = await newRequests.next(); XCTAssertEqual(first?.operation, .status); XCTAssertNil(first?.selectedKey)
        try new.respond(0, xpcStatus())
        let second = await newRequests.next(); XCTAssertEqual(second?.selectedKey, "after-interruption")
        delayedNotification?(); old.respondBytes(1, Data("stale-malformed".utf8))
        do { _ = try await pending.value; XCTFail("stale") } catch {}
        try new.respond(1, .init()); _ = try await sensitive.value
        XCTAssertEqual(old.requestCount, 2); XCTAssertEqual(new.requestCount, 2)
        XCTAssertEqual(new.invalidationCount, 0); await client.disconnect()
    }
}
