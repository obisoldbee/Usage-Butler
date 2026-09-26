import Darwin
import Foundation
import UsageButlerDomain

public final class HistoryXPCServer: NSObject, NSXPCListenerDelegate, @unchecked Sendable {
    private let listener: NSXPCListener
    private let engine: BackgroundNetworkEngine?
    private let startupFailure: String?
    private let stopped: @Sendable () -> Void
    private let lock = NSLock()
    private var connections: [ObjectIdentifier: NSXPCConnection] = [:]
    public init(name: String, peerRequirement: String, engine: BackgroundNetworkEngine?, startupFailure: String? = nil, stopped: @escaping @Sendable () -> Void) throws {
        try HistoryCodeIdentity.validate(peerRequirement)
        listener = .init(machServiceName: name); self.engine = engine; self.stopped = stopped; self.startupFailure = startupFailure
        super.init(); listener.delegate = self
        listener.setConnectionCodeSigningRequirement(peerRequirement)
    }
    public func start() { listener.resume() }
    public func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        guard connection.effectiveUserIdentifier == getuid() else { return false }
        lock.lock()
        guard connections.count < 4 else { lock.unlock(); return false }
        let id = ObjectIdentifier(connection); connections[id] = connection; lock.unlock()
        let session = HistoryXPCSession(engine: engine, startupFailure: startupFailure, stopped: stopped)
        connection.exportedInterface = NSXPCInterface(with: HistoryXPCProtocol.self)
        connection.exportedObject = session
        connection.invalidationHandler = { [weak self, weak session] in
            session?.cancel(); self?.remove(id)
        }
        connection.resume(); return true
    }
    private func remove(_ id: ObjectIdentifier) { lock.lock(); connections.removeValue(forKey: id); lock.unlock() }
}

private final class HistoryXPCSession: NSObject, HistoryXPCProtocol, @unchecked Sendable {
    private let engine: BackgroundNetworkEngine?
    private let startupFailure: String?
    private let stopped: @Sendable () -> Void
    private let lock = NSLock()
    private var tasks: [UUID: Task<Void, Never>] = [:]
    private var closed = false
    init(engine: BackgroundNetworkEngine?, startupFailure: String?, stopped: @escaping @Sendable () -> Void) {
        self.engine = engine; self.stopped = stopped; self.startupFailure = startupFailure
    }
    func exchange(_ data: Data, withReply reply: @escaping @Sendable (Data) -> Void) {
        guard data.count <= BackgroundNetworkWire.maximumRequestBytes,
              let request = try? JSONDecoder().decode(BackgroundNetworkRequest.self, from: data), request.isValid else {
            reply(Self.failure("history.invalid-request")); return
        }
        lock.lock()
        guard !closed, tasks.count < 2 else { lock.unlock(); reply(Self.failure("history.request-busy")); return }
        let id = UUID()
        // Holding the lock through insertion ensures even a fast completion
        // cannot race insertion and leave a dead entry in the bounded table.
        tasks[id] = Task {
            let response = await engine?.handle(request) ?? .init(error: startupFailure ?? "history.unavailable")
            let bytes = (try? BackgroundNetworkWire.encode(response)) ?? Self.failure("history.response-too-large")
            reply(bytes); self.finished(id)
            if request.operation == .stop { stopped() }
        }
        lock.unlock()
    }
    private func finished(_ id: UUID) { lock.lock(); tasks.removeValue(forKey: id); lock.unlock() }
    func cancel() {
        lock.lock(); closed = true; let active = Array(tasks.values); tasks.removeAll(); lock.unlock()
        active.forEach { $0.cancel() }
    }
    private static func failure(_ code: String) -> Data {
        // Fixed ASCII codes only. This packet is always smaller than the cap.
        (try? JSONEncoder().encode(BackgroundNetworkResponse(error: code))) ?? Data()
    }
}
