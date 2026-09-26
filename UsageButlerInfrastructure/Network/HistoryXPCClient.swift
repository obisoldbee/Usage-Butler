import Foundation
import UsageButlerCore
import UsageButlerDomain

@objc public protocol HistoryXPCProtocol {
    func exchange(_ request: Data, withReply reply: @escaping @Sendable (Data) -> Void)
}

public actor HistoryXPCClient: BackgroundNetworkClient {
    private let makeConnection: @Sendable () -> any HistoryXPCTransport
    private let timeout: @Sendable () async throws -> Void
    private let onRequestAdmitted: (@Sendable () -> Void)?
    private var connection: (any HistoryXPCTransport)?
    private var generation: UInt64 = 0
    private var verifiedGeneration: UInt64?
    private var handshake: Task<BackgroundNetworkResponse, Error>?
    private var outstanding = 0
    public init(serviceName: String, peerRequirement: String? = nil) throws {
        if let peerRequirement { try HistoryCodeIdentity.validate(peerRequirement) }
        makeConnection = { HistoryXPCConnection(serviceName, requirement: peerRequirement) }
        timeout = { try await Task.sleep(for: .seconds(4)) }
        onRequestAdmitted = nil
    }
    init(makeConnection: @escaping @Sendable () -> any HistoryXPCTransport,
         timeout: @escaping @Sendable () async throws -> Void = { try await Task.sleep(for: .seconds(4)) },
         onRequestAdmitted: (@Sendable () -> Void)? = nil) {
        self.makeConnection = makeConnection; self.timeout = timeout; self.onRequestAdmitted = onRequestAdmitted
    }
    public func disconnect() {
        generation &+= 1; verifiedGeneration = nil
        handshake?.cancel(); handshake = nil
        let old = connection; connection = nil; old?.invalidate()
    }
    private func lostConnection(_ token: UInt64) {
        guard token == generation else { return }; disconnect()
    }
    public func request(_ request: BackgroundNetworkRequest) async throws -> BackgroundNetworkResponse {
        try Task.checkCancellation()
        guard request.isValid, outstanding < 4 else { throw BackgroundNetworkWire.Failure.invalidRequest }
        let data = try JSONEncoder().encode(request)
        guard data.count <= BackgroundNetworkWire.maximumRequestBytes else { throw BackgroundNetworkWire.Failure.invalidRequest }
        // The native callback seals its transport synchronously. Consult that
        // seal before actor-delivered invalidation, so NSXPC automatic reconnect
        // cannot inherit the previous peer's handshake.
        if let connection, !connection.isUsable { disconnect() }
        let token = generation
        if connection == nil {
            let created = makeConnection(); connection = created
            created.activate { [weak self] in Task { await self?.lostConnection(token) } }
        }
        guard let connection else { throw BackgroundNetworkWire.Failure.disconnected }
        outstanding += 1; defer { outstanding -= 1 }
        onRequestAdmitted?()
        do {
            if verifiedGeneration != token {
                let status = try await authenticate(connection, token: token)
                // Canceling a waiter never cancels the shared bounded handshake.
                try Task.checkCancellation()
                if request.operation == .status, request.selectedKey == nil, request.range == nil,
                   request.applicationID == nil, request.page == 0, request.eventKind == nil, request.rule == nil { return status }
            }
            try Task.checkCancellation()
            return try await exchange(data, connection: connection, token: token)
        } catch {
            // Valid business failures and individual timeout/cancellation leave
            // other requests and authenticated connection state intact.
            if !Self.requestLocal(error), token == generation { disconnect() }
            throw error
        }
    }
    private func authenticate(_ connection: any HistoryXPCTransport, token: UInt64) async throws -> BackgroundNetworkResponse {
        let task: Task<BackgroundNetworkResponse, Error>
        if let handshake { task = handshake }
        else {
            let data = try JSONEncoder().encode(BackgroundNetworkRequest(.status))
            task = Task { try await self.exchange(data, connection: connection, token: token) }
            handshake = task
        }
        do {
            let response = try await task.value
            guard token == generation, connection.isUsable, response.status != nil else { throw BackgroundNetworkWire.Failure.invalidResponse }
            verifiedGeneration = token; handshake = nil
            return response
        } catch {
            // A missing/failed status never opens the sensitive-payload gate.
            if token == generation { disconnect() }; throw error
        }
    }
    private func exchange(_ data: Data, connection: any HistoryXPCTransport, token: UInt64) async throws -> BackgroundNetworkResponse {
        guard token == generation, connection.isUsable else { throw BackgroundNetworkWire.Failure.disconnected }
        let reply = HistoryXPCReply()
        let result: Data = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                reply.install(continuation)
                let timer = Task { [timeout] in
                    do { try await timeout() } catch { return }
                    reply.finish(.failure(BackgroundNetworkWire.Failure.timeout))
                }
                reply.setTimer(timer)
                if !reply.finished { connection.exchange(data) { reply.finish($0) } }
            }
        } onCancel: { reply.finish(.failure(CancellationError())) }
        guard token == generation, connection.isUsable, result.count <= BackgroundNetworkWire.maximumResponseBytes,
              let value = try? JSONDecoder().decode(BackgroundNetworkResponse.self, from: result),
              value.protocolVersion == 1 else { throw BackgroundNetworkWire.Failure.invalidResponse }
        if let error = value.error {
            guard Self.recognizedBusinessError(error) else { throw BackgroundNetworkWire.Failure.invalidResponse }
            throw BackgroundNetworkWire.Failure.remote(error)
        }
        return value
    }
    private static func requestLocal(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        switch error {
        case BackgroundNetworkWire.Failure.timeout: return true
        case let BackgroundNetworkWire.Failure.remote(code): return recognizedBusinessError(code)
        default: return false
        }
    }
    private static func recognizedBusinessError(_ code: String) -> Bool {
        let codes: Set<String> = ["history.query-busy", "history.request-busy", "history.query-timeout", "history.invalid-request",
            "history.already-running", "history.unsafe-path", "history.closed", "history.unsupported-schema", "history.corrupt",
            "history.capacity", "history.stopped", "history.unavailable", "history.operation-failed", "history.response-too-large",
            "history.stop-persistence-failed", "history.close-unconfirmed"]
        if codes.contains(code) { return true }
        if code.hasPrefix("history.sqlite."), let number = Int32(code.dropFirst("history.sqlite.".count)), number >= 0 { return true }
        return false
    }
}

private final class HistoryXPCReply: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Data, Error>?
    private var result: Result<Data, Error>?
    private var timer: Task<Void, Never>?
    var finished: Bool { lock.lock(); defer { lock.unlock() }; return result != nil }
    func install(_ continuation: CheckedContinuation<Data, Error>) {
        lock.lock()
        if let result { lock.unlock(); continuation.resume(with: result) }
        else { self.continuation = continuation; lock.unlock() }
    }
    func setTimer(_ timer: Task<Void, Never>) {
        lock.lock(); defer { lock.unlock() }
        if result != nil { timer.cancel() } else { self.timer = timer }
    }
    func finish(_ result: Result<Data, Error>) {
        lock.lock()
        guard self.result == nil else { lock.unlock(); return }
        self.result = result; let pending = continuation; continuation = nil
        let timeout = timer; timer = nil; lock.unlock()
        timeout?.cancel(); pending?.resume(with: result)
    }
}

protocol HistoryXPCTransport: Sendable {
    var isUsable: Bool { get }
    func activate(disconnected: @escaping @Sendable () -> Void)
    func exchange(_ data: Data, reply: @escaping @Sendable (Result<Data, Error>) -> Void)
    func invalidate()
}
extension HistoryXPCTransport {
    var isUsable: Bool { true }
    func activate(disconnected: @escaping @Sendable () -> Void) {}
}
private final class HistoryXPCConnection: HistoryXPCTransport, @unchecked Sendable {
    let value: NSXPCConnection
    private let lock = NSLock()
    private var usable = true
    private var lost: (@Sendable () -> Void)?
    var isUsable: Bool { lock.lock(); defer { lock.unlock() }; return usable }
    init(_ name: String, requirement: String?) {
        value = NSXPCConnection(machServiceName: name)
        value.remoteObjectInterface = NSXPCInterface(with: HistoryXPCProtocol.self)
        if let requirement { value.setCodeSigningRequirement(requirement) }
    }
    func activate(disconnected: @escaping @Sendable () -> Void) {
        lock.lock(); lost = disconnected; lock.unlock()
        value.interruptionHandler = { [weak self] in self?.seal(notify: true) }
        value.invalidationHandler = { [weak self] in self?.seal(notify: true) }
        value.resume()
    }
    func exchange(_ data: Data, reply: @escaping @Sendable (Result<Data, Error>) -> Void) {
        guard isUsable else { reply(.failure(BackgroundNetworkWire.Failure.disconnected)); return }
        guard let proxy = value.remoteObjectProxyWithErrorHandler({ [weak self] _ in
            self?.seal(notify: true); reply(.failure(BackgroundNetworkWire.Failure.disconnected))
        }) as? HistoryXPCProtocol else {
            reply(.failure(BackgroundNetworkWire.Failure.disconnected)); return
        }
        proxy.exchange(data) { reply(.success($0)) }
    }
    private func seal(notify: Bool) {
        lock.lock(); let wasUsable = usable; usable = false
        let callback = notify ? lost : nil
        if notify { lost = nil }
        lock.unlock()
        // NSXPC may invoke handlers reentrantly: never call it under our lock.
        if wasUsable { value.invalidate() }
        callback?()
    }
    func invalidate() { seal(notify: false) }
    deinit { value.invalidate() }
}
