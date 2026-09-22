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
    /// The user's most recent explicit word about collection, which outranks
    /// whatever copy `start()` happened to load.
    private var collectionIntent: Bool?

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
        guard !started else { return }
        started = true
        if case let .success(loaded) = await settingsStore.load() {
            settings = loaded
        }
        if collectionIntent ?? settings.collectionEnabled {
            restartSession()
        }
        startPublishLoop()
        await publishNow(force: true)
    }

    /// Stops both loops and finishes the update stream.
    public func stop() {
        started = false
        tearDownSession()
        publishTask?.cancel()
        publishTask = nil
        continuation?.finish()
        continuation = nil
    }

    /// Persists and applies the user preference. Persistence is best-effort:
    /// a failed save loses the preference across relaunch but never blocks
    /// the runtime change the user just asked for.
    public func setCollectionEnabled(_ enabled: Bool) async {
        let changed = enabled != settings.collectionEnabled
        collectionIntent = enabled
        settings.collectionEnabled = enabled
        if changed { _ = await settingsStore.save(settings) }
        if enabled {
            if changed { restartSession() }
        } else {
            // Applied even when the cached preference already read false: an
            // explicit stop must not be dropped because a copy looked
            // satisfied. `start()` can be in flight with a preference it read
            // before this call landed, and the user's word outranks it.
            tearDownSession()
        }
        await publishNow(force: true)
    }

    /// Adopts a new publish cadence by restarting the publish loop.
    public func updatePolicy(_ policy: NetworkPublishPolicy) {
        guard policy != self.policy else { return }
        self.policy = policy
        publishTask?.cancel()
        startPublishLoop()
    }

    /// Publishes immediately. When the source disconnected, performs one
    /// bounded reconnect — a brand-new session, never a merge with the old
    /// one — before publishing.
    public func refreshNow() async {
        if case .disconnected = collectionState, settings.collectionEnabled {
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

    public func currentSnapshot() async -> NetworkSnapshot {
        let reading = await clock.reading()
        return buildSnapshot(asOf: reading)
    }

    /// Single-consumer snapshot stream. Subscribing seeds the current
    /// snapshot so a fresh panel never renders empty while waiting for the
    /// next publish tick.
    public func updates() -> AsyncStream<NetworkSnapshot> {
        let (stream, continuation) = AsyncStream<NetworkSnapshot>.makeStream()
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

    private func restartSession() {
        consumeTask?.cancel()
        sessionCounter &+= 1
        let sessionID = CaptureSessionID(rawValue: "network-\(sessionCounter)")
        let source = makeSource(sessionID)
        self.source = source
        aggregator = NetworkAggregator(sessionID: sessionID)
        collectionState = .starting
        consumeTask = Task { await self.consume(source: source, sessionID: sessionID) }
    }

    private func tearDownSession() {
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
        guard event.envelope.sessionID == aggregator?.sessionID else { return }
        if case let .heartbeat(observed) = event.payload {
            capabilities = observed
        }
        guard var aggregator else { return }
        let applied = aggregator.apply(event)
        self.aggregator = aggregator
        // A heartbeat alone does not prove live sampling; the first applied
        // non-heartbeat event flips starting to active.
        if applied, case .starting = collectionState {
            if case .heartbeat = event.payload {
                // keep starting
            } else {
                collectionState = .active
            }
        }
    }

    private func streamFinished(sessionID: CaptureSessionID) {
        // A retired session's stream ending must not disturb the current one.
        guard aggregator?.sessionID == sessionID,
              settings.collectionEnabled,
              collectionState != .stopped
        else { return }
        collectionState = .disconnected(since: Date())
    }

    // MARK: - Publication

    private func startPublishLoop() {
        publishTask = Task { await self.runPublishLoop() }
    }

    private func runPublishLoop() async {
        while !Task.isCancelled {
            let reading = await clock.reading()
            publishSnapshot(asOf: reading, force: false)
            let deadline = MonotonicInstant(
                nanoseconds: reading.monotonicTime.nanoseconds &+ Self.nanoseconds(for: policy.minimumInterval)
            )
            try? await clock.sleep(until: deadline)
        }
    }

    private func publishNow(force: Bool) async {
        let reading = await clock.reading()
        publishSnapshot(asOf: reading, force: force)
    }

    /// Emits only when the observable key changed (or forced), so a quiet
    /// source does not redraw the panel on every tick.
    private func publishSnapshot(asOf reading: ClockReading, force: Bool) {
        let key = PublishKey(
            appliedSequence: aggregator?.appliedSequence ?? 0,
            collectionState: collectionState,
            capabilities: capabilities
        )
        guard force || key != lastPublishedKey else { return }
        lastPublishedKey = key
        continuation?.yield(buildSnapshot(asOf: reading))
    }

    private func buildSnapshot(asOf reading: ClockReading) -> NetworkSnapshot {
        if var aggregator {
            let raw = aggregator.snapshot(
                asOf: reading.wallTime,
                monotonicAsOf: reading.monotonicTime,
                collectionState: collectionState
            )
            self.aggregator = aggregator
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
            interfaces: [:],
            apps: [:],
            interfaceRates: [:]
        )
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
