import Foundation
import UsageButlerCore
import UsageButlerDomain

@objc public protocol HistoryXPCProtocol {
    func exchange(_ request: Data, withReply reply: @escaping @Sendable (Data) -> Void)
}

public actor HistoryXPCClient: BackgroundNetworkClient {
    private final class Connection: @unchecked Sendable {
        let value: NSXPCConnection
        init(_ name: String, requirement: String?) {
            value = NSXPCConnection(machServiceName: name)
            value.remoteObjectInterface = NSXPCInterface(with: HistoryXPCProtocol.self)
            if let requirement { value.setCodeSigningRequirement(requirement) }
            value.resume()
        }
        deinit { value.invalidate() }
    }
    private let name: String
    private let requirement: String?
    private var connection: Connection?
    private var generation: UInt64 = 0
    private var outstanding = 0
    public init(serviceName: String, peerRequirement: String? = nil) throws {
        if let peerRequirement { try HistoryCodeIdentity.validate(peerRequirement) }
        name = serviceName; requirement = peerRequirement
    }
    public func disconnect() { connection?.value.invalidate(); connection = nil; generation &+= 1 }
    public func request(_ request: BackgroundNetworkRequest) async throws -> BackgroundNetworkResponse {
        guard request.isValid, outstanding < 4 else { throw BackgroundNetworkWire.Failure.invalidRequest }
        let data = try JSONEncoder().encode(request)
        guard data.count <= BackgroundNetworkWire.maximumRequestBytes else { throw BackgroundNetworkWire.Failure.invalidRequest }
        if connection == nil { connection = Connection(name, requirement: requirement) }
        guard let connection else { throw BackgroundNetworkWire.Failure.disconnected }
        let token = generation
        outstanding += 1; defer { outstanding -= 1 }
        do {
            let result: Data = try await withCheckedThrowingContinuation { continuation in
                let reply = HistoryXPCReply(continuation)
                let timer = Task {
                    do { try await Task.sleep(for: .seconds(4)) } catch { return }
                    reply.finish(.failure(BackgroundNetworkWire.Failure.timeout))
                }
                reply.setTimer(timer)
                guard let proxy = connection.value.remoteObjectProxyWithErrorHandler({ _ in
                    reply.finish(.failure(BackgroundNetworkWire.Failure.disconnected))
                }) as? HistoryXPCProtocol else {
                    reply.finish(.failure(BackgroundNetworkWire.Failure.disconnected)); return
                }
                proxy.exchange(data) { value in reply.finish(.success(value)) }
            }
            guard result.count <= BackgroundNetworkWire.maximumResponseBytes else { throw BackgroundNetworkWire.Failure.invalidResponse }
            let value = try JSONDecoder().decode(BackgroundNetworkResponse.self, from: result)
            guard token == generation, value.protocolVersion == 1 else { throw BackgroundNetworkWire.Failure.invalidResponse }
            if let error = value.error { throw BackgroundNetworkWire.Failure.remote(error) }
            return value
        } catch {
            if token == generation { disconnect() }
            throw error
        }
    }
}

private final class HistoryXPCReply: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Data, Error>?
    private var timer: Task<Void, Never>?
    init(_ continuation: CheckedContinuation<Data, Error>) { self.continuation = continuation }
    func setTimer(_ timer: Task<Void, Never>) {
        lock.lock(); defer { lock.unlock() }
        if continuation == nil { timer.cancel() } else { self.timer = timer }
    }
    func finish(_ result: Result<Data, Error>) {
        lock.lock(); let pending = continuation; continuation = nil
        let timeout = timer; timer = nil; lock.unlock()
        timeout?.cancel(); pending?.resume(with: result)
    }
}
