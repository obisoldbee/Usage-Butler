import Foundation
import UsageButlerDomain

/// Bounds for in-memory aggregation. Overflow is surfaced as truncation in
/// coverage, never as silently dropped data.
public struct NetworkAggregationBounds: Equatable, Sendable {
    public let maxApps: Int
    public let maxFlowsPerApp: Int
    public let maxInterfaces: Int

    public init(maxApps: Int = 500, maxFlowsPerApp: Int = 200, maxInterfaces: Int = 64) {
        self.maxApps = max(1, maxApps)
        self.maxFlowsPerApp = max(1, maxFlowsPerApp)
        self.maxInterfaces = max(1, maxInterfaces)
    }
}

/// Pure, deterministic aggregator: consumes ordered source events and emits
/// complete replacement snapshots. It owns no clock and no I/O; all timing
/// comes from event envelopes and explicit snapshot timestamps, so tests
/// replay exact byte and time values without sleeping.
public struct NetworkAggregator: Sendable {
    public private(set) var sessionID: CaptureSessionID
    private let bounds: NetworkAggregationBounds

    private var lastSequence: UInt64 = 0
    private var lostEventCount: UInt64 = 0
    private var duplicateEventCount: UInt64 = 0
    private var outOfOrderEventCount: UInt64 = 0
    private var foreignSessionDrops: UInt64 = 0
    private var orphanedEventCount: UInt64 = 0
    private var counterResetCount: UInt64 = 0

    private struct DirectionState: Equatable, Sendable {
        var epoch = CounterEpoch(rawValue: 0)
        /// Cumulative totals since `epoch`. `nil` when the direction was
        /// never observed or a same-epoch reset invalidated it.
        var cumulative: UInt64?
        /// Bytes settled inside this capture session. Summing consecutive
        /// non-negative reading deltas makes this independent of how high the
        /// underlying source counter already was when observation began.
        /// `nil` once a same-epoch reset proves the accounting cannot be
        /// bounded — unknown, not zero.
        var settled: UInt64?
        /// True after a same-epoch reset. A flow total describes a subject, and
        /// the bytes around the gap cannot be recovered, so it stays unknown
        /// instead of restarting at a figure that would look like a fresh flow.
        /// Interfaces clear this deliberately when they start a new span.
        var settlementBroken = false
        var ended = false
    }

    private struct FlowState: Equatable, Sendable {
        var identity: FlowIdentity
        var upload = DirectionState()
        var download = DirectionState()
        var firstSeenAt: Date
        var lastSeenAt: Date
        var finalReportApplied = false
    }

    private struct ProcessState: Equatable, Sendable {
        var identity: ProcessIdentity
        var app: AppIdentity?
        var exited = false
    }

    private enum SettledDirection: CaseIterable {
        case upload
        case download

        func value(of bytes: DirectionalBytes) -> UInt64? {
            switch self {
            case .upload: bytes.upload
            case .download: bytes.download
            }
        }
    }

    private struct InterfaceSettlement: Equatable, Sendable {
        var upload = DirectionState()
        var download = DirectionState()
        /// Start of the span these totals can honestly speak for.
        var since: Date
        var sinceMonotonic: MonotonicInstant
        var breakReason: String?

        subscript(_ direction: SettledDirection) -> DirectionState {
            get { direction == .upload ? upload : download }
            set {
                switch direction {
                case .upload: upload = newValue
                case .download: download = newValue
                }
            }
        }

        var value: SessionByteTotal {
            SessionByteTotal(
                bytes: DirectionalBytes(upload: upload.settled, download: download.settled),
                since: since,
                sinceMonotonic: sinceMonotonic,
                breakReason: breakReason
            )
        }
    }

    private struct InterfaceState: Equatable, Sendable {
        var latest: InterfaceCounters
        var previous: InterfaceCounters?
        var settlement: InterfaceSettlement?
    }

    private struct TotalsSample: Equatable, Sendable {
        var upload: UInt64
        var download: UInt64
        var at: MonotonicInstant
    }

    private var flows: [FlowID: FlowState] = [:]
    private var flowAppKeys: [FlowID: String] = [:]
    private var processes: [ProcessIdentity: ProcessState] = [:]
    private var interfaces: [String: InterfaceState] = [:]
    private var appIdentities: [String: AppIdentity] = [:]
    private var truncatedCollections: Set<String> = []
    private var capabilities: NetworkCapabilities = .unavailable
    private var hasLiveSample = false
    private var lastAppTotals: [String: TotalsSample] = [:]

    public init(sessionID: CaptureSessionID, bounds: NetworkAggregationBounds = .init()) {
        self.sessionID = sessionID
        self.bounds = bounds
    }

    /// Integrity counters, surfaced for diagnostics and tests.
    public var integrity: (
        lost: UInt64, duplicates: UInt64, outOfOrder: UInt64, foreignSession: UInt64,
        orphaned: UInt64, counterResets: UInt64
    ) {
        (lostEventCount, duplicateEventCount, outOfOrderEventCount, foreignSessionDrops,
         orphanedEventCount, counterResetCount)
    }

    /// The most specific reason byte coverage is incomplete, if any.
    private var lossReasonForBytes: String? {
        if counterResetCount > 0 { return "counter-reset" }
        if outOfOrderEventCount > 0 { return "out-of-order-events" }
        if lostEventCount > 0 { return "lost-events" }
        return nil
    }

    /// Baseline epoch for the session-settled app totals. Unlike a source
    /// counter epoch it is owned by this aggregator: it starts at zero with
    /// the capture session and only advances if the session's own accounting
    /// is rebased, so pairing it with `cumulativeWithinSession` states exactly
    /// what the number covers instead of borrowing a source epoch.
    public private(set) var sessionSettlementEpoch = CounterEpoch(rawValue: 0)

    /// Highest applied sequence; lets collectors detect progress without
    /// building a snapshot (snapshotting mutates rate baselines).
    public var appliedSequence: UInt64 { lastSequence }

    /// Applies one event. Returns false when the event was dropped as foreign
    /// session, replay/duplicate or orphaned — the caller can log the drop.
    @discardableResult
    public mutating func apply(_ event: NetworkSourceEvent) -> Bool {
        let envelope = event.envelope
        guard envelope.sessionID == sessionID else {
            foreignSessionDrops &+= 1
            return false
        }
        if envelope.sequence < lastSequence {
            // A real event that arrived late. It cannot be applied to a
            // globally ordered stream, but calling it a replay would hide the
            // bytes that were never settled, so it gets its own counter and
            // degrades byte coverage.
            outOfOrderEventCount &+= 1
            return false
        }
        guard envelope.sequence > lastSequence else {
            duplicateEventCount &+= 1
            return false
        }
        if envelope.sequence > lastSequence &+ 1 {
            lostEventCount &+= envelope.sequence - lastSequence - 1
        }
        lastSequence = envelope.sequence

        switch event.payload {
        case let .heartbeat(newCapabilities):
            capabilities = newCapabilities
        case let .interfaceCounters(sample):
            hasLiveSample = true
            return applyInterface(sample)
        case let .flowStarted(identity):
            hasLiveSample = true
            return applyFlowStarted(identity, envelope: envelope)
        case let .flowCounters(flowID, counters, isFinal):
            hasLiveSample = true
            return applyFlowCounters(flowID, counters: counters, isFinal: isFinal, envelope: envelope)
        case let .flowTargetResolved(flowID, remoteEndpoint, remoteHostname, targetSource):
            return applyFlowTarget(flowID, remoteEndpoint: remoteEndpoint, remoteHostname: remoteHostname, targetSource: targetSource)
        case let .flowEnded(flowID):
            return applyFlowEnded(flowID)
        case let .processExited(identity):
            return applyProcessExited(identity)
        }
        return true
    }

    // MARK: - Event handlers

    private mutating func applyInterface(_ sample: InterfaceCounters) -> Bool {
        if interfaces[sample.name] == nil, interfaces.count >= bounds.maxInterfaces {
            truncatedCollections.insert("interfaces")
            return false
        }
        let existing = interfaces[sample.name]
        var upload = sample.counters.bytes.upload
        var download = sample.counters.bytes.download
        var sanitized = sample

        if let existing,
           existing.latest.counters.semantics == .cumulativeSinceEpoch,
           sample.counters.semantics == .cumulativeSinceEpoch,
           existing.latest.counters.epoch == sample.counters.epoch {
            // Same-epoch decrease: counter reset without an epoch bump. Keep
            // the direction but mark its value unknown; never merge.
            var invalidated = false
            if let previous = existing.latest.counters.bytes.upload, let next = upload, next < previous {
                upload = nil
                invalidated = true
            }
            if let previous = existing.latest.counters.bytes.download, let next = download, next < previous {
                download = nil
                invalidated = true
            }
            if invalidated {
                counterResetCount &+= 1
                sanitized = sample.replacing(bytes: DirectionalBytes(upload: upload, download: download))
            }
        }

        var settlement = existing?.settlement
            ?? InterfaceSettlement(since: sample.asOf, sinceMonotonic: sample.monotonicAsOf)
        settle(&settlement, sample: sample, isFirstSample: existing == nil)
        sanitized = sanitized.replacing(sessionTotal: settlement.value)
        interfaces[sample.name] = InterfaceState(
            latest: sanitized,
            previous: existing?.latest,
            settlement: settlement
        )
        return true
    }

    /// Accumulates the bytes this session can prove it saw, per direction.
    ///
    /// An interface counter is a boot total of unverifiable start point and,
    /// for getifaddrs, 32-bit width — so it is only ever used as the baseline
    /// for consecutive same-epoch differences. A decrease ends the span: the
    /// bytes around it cannot be attributed, so the segment restarts and
    /// carries the reason instead of resuming as if nothing had happened.
    private mutating func settle(
        _ state: inout InterfaceSettlement,
        sample: InterfaceCounters,
        isFirstSample: Bool
    ) {
        for direction in SettledDirection.allCases {
            if isFirstSample {
                // Record the baseline and stop. Whether the source's epoch
                // happens to equal `DirectionState`'s default must not decide
                // if a single reading is treated as traffic.
                var baseline = DirectionState()
                baseline.epoch = sample.counters.epoch
                baseline.cumulative = direction.value(of: sample.counters.bytes)
                state[direction] = baseline
                continue
            }
            let (next, didReset) = settling(
                state[direction],
                value: direction.value(of: sample.counters.bytes),
                epoch: sample.counters.epoch,
                semantics: sample.counters.semantics
            )
            state[direction] = next
            if didReset {
                // An interface total describes a time span, so a new span
                // legitimately starts at the reset — with the reason attached.
                state[direction].settled = 0
                state[direction].settlementBroken = false
                state.since = sample.asOf
                state.sinceMonotonic = sample.monotonicAsOf
                state.breakReason = "counter-reset"
            }
        }
    }

    /// The per-direction settlement rule, shared by flows and interfaces.
    /// Pure: whether a reset is *reported* is the caller's decision, because
    /// the two surfaces count it in different places.
    private func settling(
        _ state: DirectionState,
        value: UInt64?,
        epoch: CounterEpoch,
        semantics: CounterSemantics
    ) -> (next: DirectionState, didReset: Bool) {
        guard let value else { return (state, false) }
        var next = state
        if epoch != next.epoch {
            // New epoch: adopt as a fresh baseline; never merge across epochs.
            // Whatever this direction already settled stays settled — it was
            // earned from visible deltas, not from this counter's magnitude.
            next.epoch = epoch
            next.cumulative = value
            return (next, false)
        }
        switch semantics {
        case .cumulativeSinceEpoch, .cumulativeWithinSession:
            if let current = next.cumulative {
                if value < current {
                    // Same-epoch decrease: a wrap or a reset, and the reading
                    // alone cannot tell which. Re-baseline at the lower value;
                    // whether the span restarts or stays unknown is decided by
                    // the caller, so the total never resumes as if nothing was
                    // lost.
                    next.cumulative = value
                    next.settled = nil
                    next.settlementBroken = true
                    return (next, true)
                }
                if !next.settlementBroken {
                    next.settled = (next.settled ?? 0) &+ (value - current)
                }
                next.cumulative = value
            } else {
                // First reading of this epoch is a baseline: it proves the
                // subject exists, not that it moved this much traffic.
                next.cumulative = value
                if next.settled == nil && !next.settlementBroken { next.settled = 0 }
            }
        case .intervalDelta:
            next.cumulative = (next.cumulative ?? 0) &+ value
            next.settled = (next.settled ?? 0) &+ value
        }
        return (next, false)
    }

    private mutating func applyFlowStarted(_ identity: FlowIdentity, envelope: NetworkEventEnvelope) -> Bool {
        guard flows[identity.flowID] == nil else { return false }
        if processes[identity.process] == nil {
            processes[identity.process] = ProcessState(identity: identity.process, app: identity.app)
        }
        let appKey: String
        if let app = identity.app, identity.attribution == .confirmed || identity.attribution == .likely {
            appKey = app.stableKey
            if appIdentities[appKey] == nil { appIdentities[appKey] = app }
        } else {
            appKey = "unidentified"
            if appIdentities[appKey] == nil { appIdentities[appKey] = AppIdentity() }
        }
        if flows.count(where: { flowAppKeys[$0.key] == appKey }) >= bounds.maxFlowsPerApp {
            truncatedCollections.insert("flows.\(appKey)")
            return false
        }
        if appIdentities.count > bounds.maxApps {
            truncatedCollections.insert("apps")
            return false
        }
        flows[identity.flowID] = FlowState(
            identity: identity,
            firstSeenAt: envelope.occurredAt,
            lastSeenAt: envelope.occurredAt
        )
        flowAppKeys[identity.flowID] = appKey
        return true
    }

    private mutating func applyFlowCounters(
        _ flowID: FlowID,
        counters: NetworkByteCounters,
        isFinal: Bool,
        envelope: NetworkEventEnvelope
    ) -> Bool {
        guard var flow = flows[flowID] else {
            orphanedEventCount &+= 1
            return false
        }
        // A final report settles the flow; later reports are duplicates.
        guard !flow.finalReportApplied else { return false }
        applyDirection(counters.bytes.upload, epoch: counters.epoch, semantics: counters.semantics, to: &flow.upload)
        applyDirection(counters.bytes.download, epoch: counters.epoch, semantics: counters.semantics, to: &flow.download)
        flow.lastSeenAt = envelope.occurredAt
        if isFinal {
            flow.finalReportApplied = true
            flow.upload.ended = true
            flow.download.ended = true
        }
        flows[flowID] = flow
        return true
    }

    /// Flow settlement. A reset leaves the direction *unknown* rather than
    /// restarting at zero: a flow's total describes that subject, and bytes
    /// observed before the gap cannot be recovered. An interface settles the
    /// other way round (see `settle`), because its total describes a time span
    /// and a new span legitimately starts at the reset.
    private mutating func applyDirection(
        _ value: UInt64?,
        epoch: CounterEpoch,
        semantics: CounterSemantics,
        to state: inout DirectionState
    ) {
        let (next, didReset) = settling(state, value: value, epoch: epoch, semantics: semantics)
        if didReset { counterResetCount &+= 1 }
        state = next
    }

    private mutating func applyFlowTarget(
        _ flowID: FlowID,
        remoteEndpoint: NetworkEndpoint?,
        remoteHostname: String?,
        targetSource: NetworkTargetSource
    ) -> Bool {
        guard var flow = flows[flowID] else {
            orphanedEventCount &+= 1
            return false
        }
        flow.identity = flow.identity.backfilling(
            remoteEndpoint: remoteEndpoint,
            remoteHostname: remoteHostname,
            targetSource: targetSource
        )
        flows[flowID] = flow
        return true
    }

    private mutating func applyFlowEnded(_ flowID: FlowID) -> Bool {
        guard var flow = flows[flowID] else {
            orphanedEventCount &+= 1
            return false
        }
        flow.upload.ended = true
        flow.download.ended = true
        flows[flowID] = flow
        return true
    }

    private mutating func applyProcessExited(_ identity: ProcessIdentity) -> Bool {
        guard var process = processes[identity] else {
            orphanedEventCount &+= 1
            return false
        }
        process.exited = true
        processes[identity] = process
        // An exited process cannot keep sockets open: end its flows. Byte
        // history is retained and never migrated to a reused PID.
        for (flowID, flow) in flows where flow.identity.process == identity {
            var ended = flow
            ended.upload.ended = true
            ended.download.ended = true
            flows[flowID] = ended
        }
        return true
    }

    // MARK: - Snapshot

    /// Builds the complete replacement projection. Callers replace their
    /// previous snapshot wholesale; nothing accumulates across snapshots.
    /// Mutating: emitting a snapshot advances the per-app rate baselines, so
    /// app rates are computed over the window since the previous snapshot.
    public mutating func snapshot(
        asOf: Date,
        monotonicAsOf: MonotonicInstant,
        collectionState: NetworkCollectionState
    ) -> NetworkSnapshot {
        let apps = appCounters(monotonicAsOf: monotonicAsOf)
        return NetworkSnapshot(
            sessionID: sessionID,
            appliedSequence: lastSequence,
            asOf: asOf,
            monotonicAsOf: monotonicAsOf,
            collectionState: collectionState,
            coverage: coverage(),
            capabilities: capabilities,
            interfaces: interfaces.mapValues(\.latest),
            apps: apps,
            interfaceRates: interfaceRates()
        )
    }

    /// Evidence, not aspiration. A source that never emitted flow events cannot
    /// be reported as fully covering identity, targets or protocols just
    /// because the aggregator has no complaint about them; `NetworkCoverageProfile`
    /// remains the explicit override for a source that does declare them.
    private func coverage() -> NetworkCoverage {
        let observedFlows = flowAppKeys.isEmpty == false || flows.isEmpty == false
        let dimensions: CoverageLevel = observedFlows
            ? .full
            : .unavailable(reason: "no-flow-events-observed")
        return NetworkCoverage(
            identity: dimensions,
            bytes: lossReasonForBytes.map { .partial(reason: $0) } ?? .full,
            targets: dimensions,
            protocols: dimensions,
            lostEventCount: lostEventCount,
            counterResetCount: counterResetCount,
            truncatedCollections: truncatedCollections.sorted(),
            hasLiveSample: hasLiveSample
        )
    }

    private mutating func appCounters(monotonicAsOf: MonotonicInstant) -> [String: AppNetworkCounters] {
        struct Acc {
            var upload: UInt64? = 0
            var download: UInt64? = 0
            var active: UInt64 = 0
            var lastActivity: Date?
        }
        var totals: [String: Acc] = [:]
        for (flowID, flow) in flows {
            guard let appKey = flowAppKeys[flowID] else { continue }
            var entry = totals[appKey] ?? Acc()
            // A direction with any unknown contribution is unknown overall.
            // Contributions are session-settled deltas, never raw source
            // counters: summing two flows that each belong to a different
            // source epoch is only meaningful that way.
            entry.upload = entry.upload.flatMap { partial in
                flow.upload.settled.map { partial &+ $0 }
            }
            entry.download = entry.download.flatMap { partial in
                flow.download.settled.map { partial &+ $0 }
            }
            if !(flow.upload.ended && flow.download.ended) {
                entry.active &+= 1
            }
            if let current = entry.lastActivity {
                entry.lastActivity = max(current, flow.lastSeenAt)
            } else {
                entry.lastActivity = flow.lastSeenAt
            }
            totals[appKey] = entry
        }
        var result: [String: AppNetworkCounters] = [:]
        for (key, entry) in totals {
            let identity = appIdentities[key] ?? AppIdentity()
            let rate: NetworkRate?
            if let upload = entry.upload, let download = entry.download {
                if let previous = lastAppTotals[key] {
                    rate = Self.rate(
                        previousUpload: previous.upload, previousDownload: previous.download,
                        previousMonotonic: previous.at,
                        nextUpload: upload, nextDownload: download,
                        nextMonotonic: monotonicAsOf,
                        asOf: entry.lastActivity ?? Date(timeIntervalSince1970: 0)
                    )
                } else {
                    rate = nil
                }
                lastAppTotals[key] = TotalsSample(upload: upload, download: download, at: monotonicAsOf)
            } else {
                rate = nil
                lastAppTotals[key] = nil
            }
            result[key] = AppNetworkCounters(
                identity: identity,
                counters: NetworkByteCounters(
                    bytes: DirectionalBytes(upload: entry.upload, download: entry.download),
                    semantics: .cumulativeWithinSession,
                    epoch: sessionSettlementEpoch
                ),
                // Lost flow events make the count untrustworthy: report
                // unknown rather than a possibly-wrong number.
                activeConnectionCount: lostEventCount > 0 ? nil : entry.active,
                rate: rate,
                lastActivity: entry.lastActivity
            )
        }
        return result
    }

    private func interfaceRates() -> [String: NetworkRate] {
        var result: [String: NetworkRate] = [:]
        for (name, state) in interfaces {
            guard let previous = state.previous else { continue }
            result[name] = Self.rate(
                previousUpload: previous.counters.bytes.upload,
                previousDownload: previous.counters.bytes.download,
                previousMonotonic: previous.monotonicAsOf,
                nextUpload: state.latest.counters.bytes.upload,
                nextDownload: state.latest.counters.bytes.download,
                nextMonotonic: state.latest.monotonicAsOf,
                asOf: state.latest.asOf
            )
        }
        return result
    }

    /// Returns `nil` when the monotonic clock did not advance: without elapsed
    /// time there is no rate, and emitting a zero-window placeholder produced
    /// payloads the codec itself refused to read back.
    private static func rate(
        previousUpload: UInt64?,
        previousDownload: UInt64?,
        previousMonotonic: MonotonicInstant,
        nextUpload: UInt64?,
        nextDownload: UInt64?,
        nextMonotonic: MonotonicInstant,
        asOf: Date
    ) -> NetworkRate? {
        guard nextMonotonic > previousMonotonic else { return nil }
        let nanos = nextMonotonic.nanoseconds - previousMonotonic.nanoseconds
        let seconds = Double(nanos) / 1_000_000_000
        func perSecond(_ earlier: UInt64?, _ later: UInt64?) -> Double? {
            guard let earlier, let later, later >= earlier else { return nil }
            let value = Double(later - earlier) / seconds
            return value.isFinite ? value : nil
        }
        return NetworkRate(
            uploadBytesPerSecond: perSecond(previousUpload, nextUpload),
            downloadBytesPerSecond: perSecond(previousDownload, nextDownload),
            asOf: asOf,
            window: .nanoseconds(Int64(clamping: nanos))
        )
    }
}
