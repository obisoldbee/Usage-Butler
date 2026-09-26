import Darwin
import CryptoKit
import Foundation
import SQLite3
import UsageButlerCore
import UsageButlerDomain

public actor BackgroundNetworkEngine {
    private let store: NetworkHistoryStore
    private let query: NetworkHistoryQuery
    private let collector: ProcessNetworkCollector
    private let startedAt = Date()
    private let executableSHA256: String
    private var timer: Task<Void, Never>?
    private var stopped = false
    private var shutdownTask: Task<Void, Never>?
    private var queryRunning = false
    private var recovery = BackgroundSourceRecovery()
    private var suspended = false
    private var storageFailed = false
    private var shutdownIssue: String?
    public init(directory: URL) throws {
        var path = [CChar](repeating: 0, count: 4096)
        guard proc_pidpath(getpid(), &path, UInt32(path.count)) > 0,
              let executable = try? Data(contentsOf: URL(fileURLWithPath: String(cString: path)), options: .mappedIfSafe) else {
            throw NetworkHistoryError.unsafePath
        }
        executableSHA256 = SHA256.hash(data: executable).map { String(format: "%02x", $0) }.joined()
        let store = try NetworkHistoryStore(directory: directory)
        let supervisor = NettopChildSupervisor(directory: directory)
        // The Store owns the lock before old-child recovery can signal anything.
        try supervisor.recover()
        self.store = store; query = NetworkHistoryQuery(databaseURL: store.databaseURL)
        collector = ProcessNetworkCollector(budget: .init(historyPerApplication: 60, totalHistory: 15_360),
            record: ProcessNetworkLifecycleLog.record, settle: { try await store.accept($0) },
            makeSource: { NettopProcessSource(sessionID: $0, supervisor: supervisor, record: ProcessNetworkLifecycleLog.record) })
    }
    public func start() async {
        guard !stopped else { return }
        await collector.setEnabled(await store.collectionIsDesired())
        guard !stopped else { return }
        timer = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(5)) } catch { return }
                await self?.flushTick()
            }
        }
    }
    private func flushTick() async {
        guard !stopped else { return }
        do { try await store.flush(); try await store.maintain() }
        catch { storageFailed = true; recovery.cancel(); await collector.setEnabled(false) }
        let source = await collector.backgroundRecoverySource()
        guard !stopped else { return }
        if let generation = recovery.observe(source, now: DispatchTime.now().uptimeNanoseconds,
                                             permitted: !suspended && !storageFailed) {
            await collector.retryExhaustedSource(generation: generation)
        }
    }
    public func suspend() async {
        guard !stopped else { return }; suspended = true; recovery.cancel(); await collector.suspend()
        do { try await store.flush() } catch { storageFailed = true; await collector.setEnabled(false) }
    }
    public func resume() async { guard !stopped else { return }; suspended = false; recovery.cancel(); await collector.resume() }
    public func shutdown(disable: Bool) async {
        if let shutdownTask { await shutdownTask.value; return }
        stopped = true; timer?.cancel(); timer = nil; recovery.cancel()
        let task = Task { [self] in
            if disable {
                do { try await store.setCollectionDesired(false) }
                catch { shutdownIssue = "history.stop-persistence-failed" }
            }
            await collector.shutdown()
            do { try await store.close() }
            catch { shutdownIssue = "history.close-unconfirmed" }
        }
        shutdownTask = task; await task.value
    }
    public func status() async -> BackgroundNetworkStatus {
        let snapshot = await collector.currentSnapshot()
        return .init(version: BackgroundNetworkWire.version, pid: getpid(), executableSHA256: executableSHA256, sqliteVersion: String(cString: sqlite3_libversion()),
            sqliteSourceID: String(cString: sqlite3_sourceid()), startedAt: startedAt,
            sourceState: snapshot.state, sourceIssue: shutdownIssue ?? snapshot.issue, coverage: await store.coverage(), rule: await store.uploadRule(),
            recoverySeconds: recovery.secondsRemaining(at: DispatchTime.now().uptimeNanoseconds))
    }
    public func handle(_ request: BackgroundNetworkRequest) async -> BackgroundNetworkResponse {
        guard request.isValid else { return .init(error: "history.invalid-request") }
        guard !stopped || request.operation == .status else { return .init(error: "history.stopped") }
        do {
            switch request.operation {
            case .status: return .init(status: await status())
            case .snapshot:
                let source = await collector.currentSnapshot()
                let lean = ProcessNetworkSnapshot(sessionID: source.sessionID, sequence: source.sequence,
                    state: source.state, issue: source.issue, applications: source.applications.mapValues { app in
                        let selected = request.selectedKey == app.identity.key
                        return .init(identity: app.identity, processes: app.processes, presence: app.presence,
                            rate: app.rate, total: app.total, history: selected ? app.history : [],
                            sampledAt: app.sampledAt, sampledMonotonic: app.sampledMonotonic,
                            historyTruncated: app.historyTruncated || !selected)
                    }, sampledAt: source.sampledAt, sampledMonotonic: source.sampledMonotonic,
                    truncated: source.truncated, lostFrames: source.lostFrames)
                return .init(status: await status(), snapshot: lean)
            case .query:
                guard !queryRunning, let range = request.range else { return .init(error: "history.query-busy") }
                queryRunning = true; defer { queryRunning = false }
                let result = try await query.query(range: range, applicationID: request.applicationID, applicationKey: request.selectedKey,
                    page: request.page, eventKind: request.eventKind)
                return .init(history: result)
            case .updateRule:
                guard let rule = request.rule else { throw NetworkHistoryError.invalidRequest }
                try await store.setUploadRule(rule); return .init(status: await status())
            case .enable:
                guard !storageFailed else { throw NetworkHistoryError.corrupt }
                try await store.setCollectionDesired(true); await collector.setEnabled(true)
                return .init(status: await status())
            case .refresh:
                recovery.cancel()
                await collector.refresh(); return .init(status: await status())
            case .stop:
                await shutdown(disable: true); return .init(status: await status(), error: shutdownIssue)
            }
        } catch { return .init(error: (error as? NetworkHistoryError)?.code ?? "history.operation-failed") }
    }
}
