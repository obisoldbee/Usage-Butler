import Foundation
import UsageButlerDomain

/// Independent owner/session: interface heartbeats cannot overwrite process
/// state or capabilities. All reconfiguration is generation guarded.
public actor ProcessNetworkCollector {
    private let makeSource: @Sendable (CaptureSessionID) -> any ProcessNetworkSource
    private let budget: ProcessNetworkBudget
    private var source: (any ProcessNetworkSource)?
    private var consumer: Task<Void, Never>?
    private var retiring: Task<Void, Never>?
    private var retentionTask: Task<Void, Never>?
    private var generation: UInt64 = 0
    private var enabled = false, closed = false
    private var suspended = false
    private var externalIntentRevision: UInt64 = 0
    private var powerIntentRevision: UInt64 = 0
    public func applyPowerIntent(suspended: Bool, revision: UInt64) async {
        guard !closed, revision > powerIntentRevision else { return }
        powerIntentRevision = revision
        if suspended { await suspend() } else { await resume() }
    }
    private var aggregator = ProcessNetworkAggregator(sessionID: .init(rawValue: "process-inactive"))
    private var continuation: AsyncStream<ProcessNetworkSnapshot>.Continuation?
    private var subscription: UInt64 = 0
    private var policy: NetworkPublishPolicy = .background
    private var lastPublish: UInt64?
    private var retryCount = 0
    public init(budget: ProcessNetworkBudget = .init(),
                makeSource: @escaping @Sendable (CaptureSessionID) -> any ProcessNetworkSource) {
        self.budget = budget; self.makeSource = makeSource
        aggregator.mark(.stopped)
    }
    public func updates() -> AsyncStream<ProcessNetworkSnapshot> {
        guard !closed else { return AsyncStream { $0.finish() } }
        let pair = AsyncStream<ProcessNetworkSnapshot>.makeStream(bufferingPolicy: .bufferingNewest(1))
        subscription &+= 1
        let token = subscription
        let old = continuation; continuation = pair.continuation
        pair.continuation.onTermination = { [weak self] _ in Task { await self?.unsubscribe(token) } }
        old?.finish(); pair.continuation.yield(aggregator.snapshot())
        if retentionTask == nil {
            retentionTask = Task { [weak self] in
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .seconds(5)) } catch { return }
                    await self?.expireRetainedHistory()
                }
            }
        }
        return pair.stream
    }
    private func unsubscribe(_ token: UInt64) { if token == subscription { continuation = nil } }
    public func applyCollectionIntent(_ enabled: Bool, revision: UInt64) async {
        guard revision >= externalIntentRevision else { return }
        externalIntentRevision = revision
        await setEnabled(enabled)
    }
    public func setEnabled(_ value: Bool) async {
        guard !closed, value != enabled else { return }
        enabled = value; generation &+= 1
        let g = generation
        consumer?.cancel(); consumer = nil
        let old = source; source = nil
        let previous = retiring
        let drain = Task { await previous?.value; await old?.stop() }
        retiring = drain
        aggregator.mark(value ? .starting : .stopped); publish(force: true)
        await drain.value
        guard g == generation, enabled, !closed, !suspended, !Task.isCancelled else { return }
        retryCount = 0; begin(g)
    }
    private func begin(_ g: UInt64) {
        guard g == generation, enabled, !closed, !suspended else { return }
        let id = CaptureSessionID(rawValue: "process-" + UUID().uuidString)
        let created = makeSource(id); source = created
        aggregator = .init(sessionID: id, budget: budget, retained: aggregator.snapshot()); lastPublish = nil
        publish(force: true)
        consumer = Task {
            for await frame in created.events() {
                guard !Task.isCancelled else { break }
                self.receive(frame, generation: g)
            }
            await self.ended(created, generation: g)
        }
    }
    private func receive(_ frame: ProcessNetworkFrame, generation g: UInt64) {
        guard g == generation, enabled, !closed else { return }
        let oldState = aggregator.state
        if aggregator.apply(frame) { publish(force: oldState != aggregator.state) }
    }
    private func ended(_ ended: any ProcessNetworkSource, generation g: UInt64) async {
        await ended.stop()
        guard g == generation, enabled, !closed, !Task.isCancelled else { return }
        source = nil; aggregator.mark(.unavailable, issue: aggregator.currentIssue ?? "source-ended")
        publish(force: true)
        // A finite automatic recovery budget; explicit refresh may retry again.
        guard retryCount < 3 else { return }
        retryCount += 1
        do { try await Task.sleep(for: .seconds(retryCount * 2)) } catch { return }
        guard g == generation, enabled, !closed, !Task.isCancelled else { return }
        begin(g)
    }
    public func refresh() async {
        if enabled, aggregator.state == .unavailable {
            generation &+= 1
            let g = generation
            consumer?.cancel(); consumer = nil
            let old = source; source = nil
            let previous = retiring
            let drain = Task { await previous?.value; await old?.stop() }
            retiring = drain
            aggregator.mark(.starting); publish(force: true)
            await drain.value
            guard g == generation, enabled, !closed, !Task.isCancelled else { return }
            retryCount = 0; begin(g)
        } else { publish(force: true) }
    }
    public func updatePolicy(_ value: NetworkPublishPolicy) { policy = value; publish(force: true) }
    /// Explicit power boundary: uptime need not include suspended time.
    /// Preserve preference, discard all baselines, and reject every old frame.
    public func suspend() async {
        guard !closed, !suspended else { return }
        suspended = true; generation &+= 1; consumer?.cancel(); consumer = nil
        let old = source; source = nil
        let previous = retiring
        let drain = Task { await previous?.value; await old?.stop() }
        retiring = drain
        aggregator.mark(enabled ? .unavailable : .stopped, issue: enabled ? "system-sleep" : nil)
        publish(force: true)
        await drain.value
    }
    public func resume() async {
        guard !closed, suspended else { return }
        suspended = false; generation &+= 1
        let g = generation
        if enabled { aggregator.mark(.starting); publish(force: true) }
        await retiring?.value
        guard g == generation, enabled, !closed, !suspended, !Task.isCancelled else { return }
        retryCount = 0; begin(g)
    }
    public func currentSnapshot() -> ProcessNetworkSnapshot { aggregator.snapshot() }
    private func expireRetainedHistory() {
        guard !closed else { return }
        if aggregator.expire(at: .init(nanoseconds: DispatchTime.now().uptimeNanoseconds)) { publish(force: true) }
    }
    public func shutdown() async {
        if closed { await retiring?.value; return }
        closed = true; enabled = false; generation &+= 1; consumer?.cancel(); consumer = nil
        retentionTask?.cancel(); retentionTask = nil
        let old = source; source = nil
        let previous = retiring
        let drain = Task { await previous?.value; await old?.stop() }
        retiring = drain
        aggregator.mark(.stopped); publish(force: true)
        continuation?.finish(); continuation = nil
        await drain.value
    }
    private func publish(force: Bool) {
        let now = DispatchTime.now().uptimeNanoseconds
        let seconds = Double(policy.minimumInterval.components.seconds)
        if !force, let lastPublish, Double(now - lastPublish) / 1e9 < seconds { return }
        lastPublish = now; continuation?.yield(aggregator.snapshot())
    }
}
