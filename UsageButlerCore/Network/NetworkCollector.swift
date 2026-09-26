import Foundation
import UsageButlerDomain

/// Publish cadence for snapshot consumers. A visible panel gets at most 1 Hz;
/// a hidden one drops to 0.2 Hz because nobody is watching. The source keeps
/// sampling at its own rate regardless — this gates publication only.
public struct NetworkPublishPolicy: Equatable, Sendable {
    public let minimumInterval: Duration

    public init(minimumInterval: Duration) {
        self.minimumInterval = minimumInterval
    }

    public static let panelVisible = NetworkPublishPolicy(minimumInterval: .seconds(1))
    public static let background = NetworkPublishPolicy(minimumInterval: .seconds(5))
}

/// Drives one observation source into the aggregator and publishes complete
/// replacement snapshots. Enabling collection always starts a fresh capture
/// session (new source + aggregator); events from a retired session are
/// dropped by the aggregator's session guard, never merged.
public actor NetworkCollector {
    private struct PublishKey: Equatable {
        var appliedSequence: UInt64
        var collectionState: NetworkCollectionState
        var capabilities: NetworkCapabilities
    }

    private let clock: any ClockPort
    private let settingsStore: any NetworkSettingsStore
    private let coverageProfile: NetworkCoverageProfile
    /// Capabilities reported while no source is running; still honest about
    /// what enabling could do, so the UI never greys out a working toggle.
    private let idleCapabilities: NetworkCapabilities
    private let makeSource: @Sendable (CaptureSessionID) -> any NetworkObservationSource

    private var settings: NetworkSettings = .default
    private var aggregator: NetworkAggregator?
    private var retainedInterfaces: [String: InterfaceCounters] = [:]
    private var retainedHistory: [String: [NetworkRateSample]] = [:]
    private var retainedHistoryExpiry: MonotonicInstant?
    private var source: (any NetworkObservationSource)?
    private var collectionState: NetworkCollectionState = .stopped
    private var capabilities: NetworkCapabilities
    private var sessionCounter: UInt64 = 0

    private var consumeTask: Task<Void, Never>?
    private var publishTask: Task<Void, Never>?
    private var policy: NetworkPublishPolicy = .background
    private var lastPublishedKey: PublishKey?
    private var continuation: AsyncStream<NetworkSnapshot>.Continuation?
    /// Identifies the current subscriber. A continuation is not comparable, so
    /// termination callbacks carry this token instead.
    private var subscriptionToken: UInt64 = 0
    private var started = false
    private var isShutdown = false
    private var suspended = false
    private var lifecycleGeneration: UInt64 = 0
    private var publicationGeneration: UInt64 = 0
    /// Accepted preference writes outlive stop, but cannot reorder on disk.
    private var settingsSaveTask: Task<Void, Never>?
    /// The user's most recent explicit word about collection, which outranks
    /// whatever copy `start()` happened to load.
    private var collectionIntent: Bool?
    private var externalIntentRevision: UInt64 = 0
    private var powerIntentRevision: UInt64 = 0
    public func applyPowerIntent(suspended: Bool, revision: UInt64) async {
        guard !isShutdown, revision > powerIntentRevision else { return }
        powerIntentRevision = revision
        if suspended { await suspend() } else { await resume() }
    }
    public func applyCollectionIntent(_ enabled: Bool, revision: UInt64) async {
        guard revision >= externalIntentRevision else { return }
        externalIntentRevision = revision
        await setCollectionEnabled(enabled)
    }

    public init(
        clock: any ClockPort,
        settingsStore: any NetworkSettingsStore,
        coverageProfile: NetworkCoverageProfile,
        idleCapabilities: NetworkCapabilities,
        makeSource: @escaping @Sendable (CaptureSessionID) -> any NetworkObservationSource
    ) {
        self.clock = clock
        self.settingsStore = settingsStore
        self.coverageProfile = coverageProfile
        self.idleCapabilities = idleCapabilities
        self.makeSource = makeSource
        capabilities = idleCapabilities
    }

    /// Loads persisted settings and starts the publish loop. A corrupt or
    /// unreadable store falls back to defaults; collection then follows the
    /// default (disabled) preference.
    public func start() async {
        guard !started, !isShutdown else { return }
        started = true
        lifecycleGeneration &+= 1
        let generation = lifecycleGeneration
        let loaded = await settingsStore.load()
        guard started, generation == lifecycleGeneration, !Task.isCancelled else { return }
        if case let .success(value) = loaded { settings = value }
        if let collectionIntent { settings.collectionEnabled = collectionIntent }
        if settings.collectionEnabled, source == nil, !suspended { restartSession() }
        startPublishLoop()
        await publishNow(force: true)
    }

    /// Runtime stop is synchronous within the actor. Already accepted saves
    /// remain ordered; shutdown may drain them via flushSettings().
    public func stop() {
        started = false
        lifecycleGeneration &+= 1
        publicationGeneration &+= 1
        tearDownSession()
        publishTask?.cancel()
        publishTask = nil
        continuation?.finish()
        continuation = nil
        lastPublishedKey = nil
    }

    public func setCollectionEnabled(_ enabled: Bool) async {
        guard !isShutdown else { return }
        collectionIntent = enabled
        settings.collectionEnabled = enabled
        // Queue before any await: later intents must always land after this
        // write, even if a store ignores cancellation or temporarily fails.
        let previousSave = settingsSaveTask
        let value = settings
        let store = settingsStore
        let save = Task {
            await previousSave?.value
            _ = await store.save(value)
        }
        settingsSaveTask = save
        if enabled {
            if started, source == nil, !suspended { restartSession() }
        } else {
            tearDownSession()
        }
        await publishNow(force: true)
        await save.value
        // No runtime work after persistence. The intent may now be obsolete.
    }

    /// Final process boundary, unlike the restartable stop(). Late UI/start
    /// tasks cannot accept more work after shutdown starts.
    public func shutdown() async {
        isShutdown = true
        stop()
        await flushSettings()
    }

    public func flushSettings() async {
        await settingsSaveTask?.value
    }

    /// Adopts a new publish cadence by restarting the publish loop.
    public func updatePolicy(_ policy: NetworkPublishPolicy) {
        guard policy != self.policy else { return }
        self.policy = policy
        publishTask?.cancel()
        if started { startPublishLoop() }
    }

    /// Publishes immediately. When the source disconnected, performs one
    /// bounded reconnect — a brand-new session, never a merge with the old
    /// one — before publishing.
    public func refreshNow() async {
        guard started else { return }
        if case .disconnected = collectionState, settings.collectionEnabled, !suspended {
            restartSession()
        }
        await publishNow(force: true)
    }

    /// The current projection, built on demand with a fresh clock reading.
    /// Applied source sequence without building a snapshot. `snapshot()`
    /// advances rate baselines, so polling it to detect progress changes the
    /// thing being watched.
    public func appliedSequence() -> UInt64 {
        aggregator?.appliedSequence ?? 0
    }

    /// The collector's own state, for observers that must not perturb totals.
    public func collectionStateNow() -> NetworkCollectionState {
        collectionState
    }

    public func collectionIsEnabled() -> Bool { settings.collectionEnabled }

    public func currentSnapshot() async -> NetworkSnapshot {
        let reading = await clock.reading()
        return buildSnapshot(asOf: reading)
    }

    /// Single-consumer snapshot stream. Subscribing seeds the current
    /// snapshot so a fresh panel never renders empty while waiting for the
    /// next publish tick.
    public func updates() -> AsyncStream<NetworkSnapshot> {
        guard !isShutdown else { return AsyncStream { $0.finish() } }
        let (stream, continuation) = AsyncStream<NetworkSnapshot>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let superseded = self.continuation
        subscriptionToken &+= 1
        let token = subscriptionToken
        self.continuation = continuation
        continuation.onTermination = { [weak self] _ in
            // Identity matters: the superseded stream terminates
            // asynchronously, and clearing unconditionally would drop the
            // subscriber that just replaced it and leave it starved forever.
            Task { await self?.continuationTerminated(token) }
        }
        superseded?.finish()
        Task { await self.publishNow(force: true) }
        return stream
    }

    // MARK: - Session lifecycle

    public func suspend() async {
        guard !isShutdown, !suspended else { return }
        suspended = true
        // An in-flight initial settings read still belongs to this runtime.
        // Let it restore preference while suspended; it cannot start a source
        // until resume. Only stop/shutdown invalidate startup itself.
        tearDownSession()
        if settings.collectionEnabled { collectionState = .disconnected(since: Date()) }
        await publishNow(force: true)
    }

    public func resume() async {
        guard suspended, !isShutdown else { return }
        suspended = false
        if started, settings.collectionEnabled { restartSession() }
        await publishNow(force: true)
    }

    private func restartSession() {
        consumeTask?.cancel()
        sessionCounter &+= 1
        let sessionID = CaptureSessionID(rawValue: "network-\(sessionCounter)")
        let source = makeSource(sessionID)
        self.source = source
        if let observation = aggregator?.retainedObservation {
            retainedInterfaces = observation.interfaces; retainedHistory = observation.history
            retainedHistoryExpiry = nil
        }
        aggregator = NetworkAggregator(sessionID: sessionID, retainedInterfaces: retainedInterfaces, retainedHistory: retainedHistory)
        // These are the stopped-state fallback. The active aggregator now owns
        // the retained observation; keeping another copy pins an old history
        // until the next stop even after its samples have expired.
        retainedInterfaces = [:]
        retainedHistory = [:]
        retainedHistoryExpiry = nil
        collectionState = .starting
        consumeTask = Task { await self.consume(source: source, sessionID: sessionID) }
    }

    private func tearDownSession() {
        if let observation = aggregator?.retainedObservation {
            retainedInterfaces = observation.interfaces; retainedHistory = observation.history
            retainedHistoryExpiry = nil
        }
        consumeTask?.cancel()
        consumeTask = nil
        source = nil
        aggregator = nil
        collectionState = .stopped
    }

    private func consume(source: any NetworkObservationSource, sessionID: CaptureSessionID) async {
        for await event in source.events() {
            if Task.isCancelled { break }
            handle(event)
        }
        streamFinished(sessionID: sessionID)
    }

    private func handle(_ event: NetworkSourceEvent) {
        guard started, settings.collectionEnabled, event.envelope.sessionID == aggregator?.sessionID else { return }
        guard aggregator?.apply(event) == true else { return }
        switch event.payload {
        case let .heartbeat(observed): capabilities = observed
        case .interfaceEnumeration(.failed): collectionState = .partial(reason: "interface-enumeration-failed")
        case .interfaceEnumeration(.complete): collectionState = .active
        default:
            if case .starting = collectionState { collectionState = .active }
        }
    }

    private func streamFinished(sessionID: CaptureSessionID) {
        // A retired session's stream ending must not disturb the current one.
        guard started, aggregator?.sessionID == sessionID,
              settings.collectionEnabled,
              collectionState != .stopped
        else { return }
        collectionState = .disconnected(since: Date())
    }

    // MARK: - Publication

    private func startPublishLoop() {
        guard started else { return }
        publishTask?.cancel()
        publicationGeneration &+= 1
        let generation = publicationGeneration
        publishTask = Task { await self.runPublishLoop(generation: generation) }
    }

    private func runPublishLoop(generation: UInt64) async {
        while started, generation == publicationGeneration, !Task.isCancelled {
            let reading = await clock.reading()
            guard started, generation == publicationGeneration, !Task.isCancelled else { return }
            publishSnapshot(asOf: reading, force: false)
            let deadline = MonotonicInstant(
                nanoseconds: reading.monotonicTime.nanoseconds &+ Self.nanoseconds(for: policy.minimumInterval)
            )
            do { try await clock.sleep(until: deadline) } catch { return }
        }
    }

    private func publishNow(force: Bool) async {
        guard started else { return }
        let generation = lifecycleGeneration
        let reading = await clock.reading()
        guard started, generation == lifecycleGeneration, !Task.isCancelled else { return }
        publishSnapshot(asOf: reading, force: force)
    }

    /// Emits only when the observable key changed (or forced), so a quiet
    /// source does not redraw the panel on every tick.
    private func publishSnapshot(asOf reading: ClockReading, force: Bool) {
        let expired = expireHistory(at: reading.monotonicTime)
        let key = PublishKey(
            appliedSequence: aggregator?.appliedSequence ?? 0,
            collectionState: collectionState,
            capabilities: capabilities
        )
        guard force || expired || key != lastPublishedKey else { return }
        lastPublishedKey = key
        continuation?.yield(buildSnapshot(asOf: reading))
    }

    private func buildSnapshot(asOf reading: ClockReading) -> NetworkSnapshot {
        _ = expireHistory(at: reading.monotonicTime)
        if let raw = aggregator?.snapshot(
                asOf: reading.wallTime,
                monotonicAsOf: reading.monotonicTime,
                collectionState: collectionState
            ) {
            return raw.applyingCoverageProfile(coverageProfile)
        }
        return NetworkSnapshot(
            sessionID: CaptureSessionID(rawValue: "inactive"),
            appliedSequence: 0,
            asOf: reading.wallTime,
            monotonicAsOf: reading.monotonicTime,
            collectionState: collectionState,
            coverage: NetworkCoverageProfile.stopped.idleCoverage(),
            capabilities: idleCapabilities,
            interfaces: retainedInterfaces,
            apps: [:],
            interfaceRates: [:],
            rateHistory: retainedHistory
        )
    }

    @discardableResult private func expireHistory(at time: MonotonicInstant) -> Bool {
        if let expired = aggregator?.expireHistory(at: time) { return expired }
        guard retainedHistoryExpiry.map({ time > $0 }) ?? true else { return false }
        // Same-process uptime. Do not subtract across a rollback/unknown domain.
        guard retainedHistory.values.allSatisfy({ $0.allSatisfy { $0.sampledMonotonic <= time } }) else { return false }
        retainedHistoryExpiry = time
        guard time.nanoseconds > 7_200_000_000_000 else { return false }
        let cutoff = time.nanoseconds - 7_200_000_000_000
        var changed = false
        for key in retainedHistory.keys {
            guard retainedHistory[key]?.contains(where: { $0.sampledMonotonic.nanoseconds < cutoff }) == true,
                  var series = retainedHistory.removeValue(forKey: key) else { continue }
            series.removeAll { $0.sampledMonotonic.nanoseconds < cutoff }
            retainedHistory[key] = series; changed = true
        }
        return changed
    }

    private func continuationTerminated(_ terminatedToken: UInt64) {
        guard terminatedToken == subscriptionToken else { return }
        continuation = nil
    }

    private static func nanoseconds(for duration: Duration) -> UInt64 {
        let components = duration.components
        let seconds = UInt64(clamping: components.seconds)
        let attoseconds = UInt64(clamping: components.attoseconds)
        return seconds &* 1_000_000_000 &+ attoseconds / 1_000_000_000
    }
}
