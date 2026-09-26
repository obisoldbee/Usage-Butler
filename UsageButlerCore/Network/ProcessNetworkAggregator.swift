import Foundation
import UsageButlerDomain

public struct ProcessNetworkBudget: Equatable, Sendable {
    public let processes: Int
    public let applications: Int
    public let historyPerApplication: Int
    public let totalHistory: Int
    public init(processes: Int = 2_048, applications: Int = 256,
                historyPerApplication: Int = 7_200, totalHistory: Int = 65_536) {
        self.processes = max(1, processes); self.applications = max(1, applications)
        self.historyPerApplication = max(1, min(7_200, historyPerApplication))
        self.totalHistory = max(self.applications, totalHistory)
    }
}

/// Settlement is performed exactly once at a source frame boundary. Reading
/// or publishing a snapshot has no accounting side effects.
public struct ProcessNetworkAggregator: Sendable {
    private enum Delta { case value(UInt64), discontinuity(String) }
    private struct Direction: Sendable {
        var total: UInt64?
        var since: Date?
        var mono: MonotonicInstant?
        var reason: String?
        var continuity: String?
        var projection: DirectionByteTotal {
            .init(bytes: total, since: since, sinceMonotonic: mono, breakReason: reason)
        }
        mutating func reset(_ frame: ProcessNetworkFrame, reason: String) {
            total = nil; since = frame.envelope.occurredAt
            mono = frame.envelope.monotonicOccurredAt; self.reason = reason
            continuity = nil
        }
        mutating func settle(_ delta: UInt64, frame: ProcessNetworkFrame) -> Bool {
            let sum = (total ?? 0).addingReportingOverflow(delta)
            guard !sum.overflow else { reset(frame, reason: "overflow"); return false }
            total = sum.partialValue
            if continuity == nil { continuity = String(frame.envelope.sequence) }
            return true
        }
    }
    private struct State: Sendable {
        var identity: ProcessNetworkApplicationIdentity
        var processes: [ProcessNetworkCounter] = []
        var presence: NetworkInterfacePresence = .unknown
        var up = Direction(), down = Direction()
        var rate: NetworkRate?
        var history: [NetworkRateSample] = []
        var date: Date
        var mono: MonotonicInstant
        var truncated = false
    }
    public let sessionID: CaptureSessionID
    public let budget: ProcessNetworkBudget
    public private(set) var sequence: UInt64 = 0
    public private(set) var lastSettlement: ProcessNetworkSettlement?
    private var previous: [String: ProcessNetworkCounter] = [:]
    private var previousGroups: [String: Set<String>] = [:]
    private var states: [String: State] = [:]
    private var envelope: NetworkEventEnvelope?
    private var previousComplete = false
    private var previousCadence: TimeInterval?
    private var sourceState: ProcessNetworkState = .starting
    private var issue: String?
    private var truncated = false
    private var lostFrames: UInt64 = 0
    public var state: ProcessNetworkState { sourceState }
    public var currentIssue: String? { issue }
    @discardableResult public mutating func expire(at now: MonotonicInstant) -> Bool {
        guard now.nanoseconds > 7_200_000_000_000,
              envelope.map({ now >= $0.monotonicOccurredAt }) ?? true else { return false }
        let cutoff = now.nanoseconds - 7_200_000_000_000
        var changed = false
        for key in states.keys {
            guard var state = states.removeValue(forKey: key) else { continue }
            // Same-process monotonic domain; future retained points do not
            // establish a valid age after a clock rollback.
            if state.history.allSatisfy({ now >= $0.sampledMonotonic }) {
                let before = state.history.count
                state.history.removeAll { $0.sampledMonotonic.nanoseconds < cutoff }
                if before != state.history.count { changed = true; state.truncated = true }
            }
            states[key] = state
        }
        truncated = truncated || changed
        return changed
    }
    public init(sessionID: CaptureSessionID, budget: ProcessNetworkBudget = .init(),
                retained: ProcessNetworkSnapshot? = nil) {
        self.sessionID = sessionID; self.budget = budget
        if let retained {
            truncated = retained.truncated
            for (key, app) in retained.applications.sorted(by: { $0.key < $1.key }).prefix(budget.applications)
                where app.identity.evidence != .unknown {
                var state = State(identity: app.identity, date: app.sampledAt, mono: app.sampledMonotonic)
                state.processes = app.processes; state.presence = .unknown
                state.history = Array(app.history.suffix(budget.historyPerApplication))
                state.truncated = app.historyTruncated
                state.up = .init(total: app.total.upload.bytes, since: app.total.upload.since,
                    mono: app.total.upload.sinceMonotonic, reason: app.total.upload.breakReason)
                state.down = .init(total: app.total.download.bytes, since: app.total.download.since,
                    mono: app.total.download.sinceMonotonic, reason: app.total.download.breakReason)
                states[key] = state
            }
            let perApp = min(budget.historyPerApplication, budget.totalHistory / max(1, states.count))
            for key in states.keys where (states[key]?.history.count ?? 0) > perApp {
                guard var state = states.removeValue(forKey: key) else { continue }
                state.history = Array(state.history.suffix(perApp))
                state.truncated = true; states[key] = state; truncated = true
            }
        }
    }
    @discardableResult public mutating func apply(_ frame: ProcessNetworkFrame) -> Bool {
        lastSettlement = nil
        let e = frame.envelope
        guard e.sessionID == sessionID, e.sequence > sequence,
              envelope.map({ e.monotonicOccurredAt > $0.monotonicOccurredAt }) ?? true else { return false }
        let gap = sequence > 0 && e.sequence - sequence > 1
        if gap {
            let sum = lostFrames.addingReportingOverflow(e.sequence - sequence - 1)
            lostFrames = sum.overflow ? UInt64.max : sum.partialValue
        }
        let dt = envelope.map { Double(e.monotonicOccurredAt.nanoseconds - $0.monotonicOccurredAt.nanoseconds) / 1e9 }
        let validCadence = frame.samplingInterval.isFinite && frame.samplingInterval > 0
        let timely = dt.map { validCadence && $0 > 0 && $0 <= NetworkChartSamplingContract().threshold(
            earlierCadence: previousCadence, laterCadence: frame.samplingInterval) } ?? false
        sequence = e.sequence
        var seenPIDs = Set<Int32>()
        let duplicate = frame.processes.contains { !seenPIDs.insert($0.identity.pid).inserted }
        let complete = frame.complete && !duplicate && frame.processes.count <= budget.processes && validCadence
        issue = duplicate ? "duplicate-process" : frame.issue
        sourceState = complete ? .active : .partial
        if !complete { issue = issue ?? "incomplete-frame" }
        if frame.processes.count > budget.processes { truncated = true }
        // Without start identity even PID continuity is unproven. A fresh
        // per-frame group prevents PID reuse from carrying history or watch.
        states = states.filter { $0.value.identity.evidence != .unknown }
        let rows = frame.processes.prefix(budget.processes).map { row -> ProcessNetworkCounter in
            guard row.identity.instanceID == nil else { return row }
            let identity = row.identity
            return .init(identity: .init(pid: identity.pid, instanceID: nil, name: identity.name,
                executablePath: nil, application: .init(key: "unknown-\(sessionID.rawValue)-\(e.sequence)-\(identity.pid)",
                    name: identity.name, evidence: .unknown)), bytes: row.bytes)
        }
        var groups = Dictionary(grouping: rows, by: { $0.identity.application.key })
        let admissionTruncated = groups.count > budget.applications || frame.processes.count > budget.processes
        if groups.count > budget.applications {
            truncated = true; sourceState = .partial; issue = "application-limit"
            // Deterministic bounded admission. Existing observed groups first.
            let keys = groups.keys.sorted { (states[$0] == nil ? 1 : 0, $0) < (states[$1] == nil ? 1 : 0, $1) }
            let admitted = Set(keys.prefix(budget.applications))
            groups = groups.filter { admitted.contains($0.key) }
        }
        // Evict absent oldest groups first; retained history never grows past
        // the application budget, including selected/watched applications.
        let newCount = groups.keys.filter { states[$0] == nil }.count
        let removeCount = max(0, states.count + newCount - budget.applications)
        let victims = states.keys.filter { groups[$0] == nil }.sorted {
            let l = states[$0]!.mono, r = states[$1]!.mono
            return l == r ? $0 < $1 : l < r
        }
        for key in victims.prefix(removeCount) { states.removeValue(forKey: key); truncated = true }
        var nextPrevious: [String: ProcessNetworkCounter] = [:]
        var nextGroups: [String: Set<String>] = [:]
        var settled: [ProcessNetworkSettlement.Application] = []
        for key in states.keys where groups[key] == nil {
            states[key]?.presence = complete ? .missing : .unknown
            states[key]?.rate = nil
            // Retain bounded history, not a previous generation of process
            // rows for every absent app. All current rows share one budget.
            states[key]?.processes = []
        }
        for (key, members) in groups {
            guard let first = members.first else { continue }
            var s = states[key] ?? State(identity: first.identity.application, date: e.occurredAt, mono: e.monotonicOccurredAt)
            let ids = Set(members.compactMap { $0.identity.instanceID })
            let identitiesKnown = ids.count == members.count
            let stableMembers = identitiesKnown && previousGroups[key] == ids
            let canSettle = complete && previousComplete && !gap && timely && stableMembers
            let reason = !complete || !previousComplete ? "incomplete-frame" : gap || !timely ? "sampling-gap" : "members-changed"
            func delta(upload: Bool) -> Delta {
                guard canSettle else { return .discontinuity(reason) }
                var total: UInt64 = 0
                for row in members {
                    guard let id = row.identity.instanceID, let old = previous[id],
                          let a = upload ? row.bytes.upload : row.bytes.download,
                          let b = upload ? old.bytes.upload : old.bytes.download, a >= b else {
                        return .discontinuity("counter-unavailable-or-reset")
                    }
                    let sum = total.addingReportingOverflow(a - b)
                    guard !sum.overflow else { return .discontinuity("overflow") }
                    total = sum.partialValue
                }
                return .value(total)
            }
            func settle(_ delta: Delta, direction: inout Direction) -> Double? {
                switch delta {
                case let .value(bytes):
                    // settle records cumulative overflow itself. Do not replace
                    // that known cause with a generic missing-counter reset.
                    guard let dt, direction.settle(bytes, frame: frame) else { return nil }
                    return Double(bytes) / dt
                case let .discontinuity(reason):
                    direction.reset(frame, reason: reason); return nil
                }
            }
            let uploadDelta = delta(upload: true), downloadDelta = delta(upload: false)
            let upRate = settle(uploadDelta, direction: &s.up)
            let downRate = settle(downloadDelta, direction: &s.down)
            func exact(_ delta: Delta, rate: Double?) -> UInt64? {
                if rate != nil, case let .value(bytes) = delta { return bytes }
                return nil
            }
            settled.append(.init(identity: first.identity.application,
                upload: exact(uploadDelta, rate: upRate), download: exact(downloadDelta, rate: downRate),
                uploadIssue: upRate == nil ? s.up.reason : nil,
                downloadIssue: downRate == nil ? s.down.reason : nil))
            s.identity = first.identity.application; s.processes = members
            s.presence = complete ? .present : .unknown; s.date = e.occurredAt; s.mono = e.monotonicOccurredAt
            s.rate = .init(uploadBytesPerSecond: upRate, downloadBytesPerSecond: downRate,
                           asOf: e.occurredAt, window: .seconds(dt ?? 0))
            s.history.append(.init(captureSessionID: sessionID, counterEpoch: .init(rawValue: 0),
                sampledAt: e.occurredAt, sampledMonotonic: e.monotonicOccurredAt,
                uploadBytesPerSecond: upRate, downloadBytesPerSecond: downRate,
                sourceID: ProcessNetworkSnapshot.sourceID, interfaceName: key,
                samplingInterval: validCadence ? frame.samplingInterval : nil,
                uploadContinuityID: s.up.continuity, downloadContinuityID: s.down.continuity))
            states[key] = s
            nextGroups[key] = ids
            for row in members { if let id = row.identity.instanceID { nextPrevious[id] = row } }
        }
        previous = nextPrevious; previousGroups = nextGroups; previousComplete = complete
        previousCadence = validCadence ? frame.samplingInterval : nil
        lastSettlement = .init(session: sessionID.rawValue, sequence: e.sequence,
            start: envelope?.occurredAt, end: e.occurredAt, monotonicEnd: e.monotonicOccurredAt.nanoseconds,
            durationNanoseconds: envelope.map { e.monotonicOccurredAt.nanoseconds - $0.monotonicOccurredAt.nanoseconds } ?? 0,
            complete: sourceState == .active, lostFrames: gap ? e.sequence - (envelope?.sequence ?? e.sequence) - 1 : 0,
            admissionTruncated: admissionTruncated, issue: issue,
            applications: settled)
        envelope = e
        let perApp = min(budget.historyPerApplication, budget.totalHistory / max(1, states.count))
        let cutoff = e.monotonicOccurredAt.nanoseconds > 7_200_000_000_000 ? e.monotonicOccurredAt.nanoseconds - 7_200_000_000_000 : 0
        for key in states.keys {
            guard var s = states.removeValue(forKey: key) else { continue }
            let oldCount = s.history.count
            var low = 0, high = s.history.count
            while low < high {
                let mid = (low + high) / 2
                if s.history[mid].sampledMonotonic.nanoseconds < cutoff { low = mid + 1 } else { high = mid }
            }
            let removal = max(low, s.history.count - perApp)
            if removal > 0 { s.history.removeFirst(removal) }
            if s.history.count < oldCount { s.truncated = true; truncated = true }
            states[key] = s
        }
        return true
    }
    public mutating func mark(_ state: ProcessNetworkState, issue: String? = nil) {
        sourceState = state; self.issue = issue
        if state != .active { previousComplete = false }
    }
    public func snapshot() -> ProcessNetworkSnapshot {
        .init(sessionID: sessionID, sequence: sequence, state: sourceState, issue: issue,
              applications: states.mapValues { s in
            .init(identity: s.identity, processes: s.processes,
                  presence: sourceState == .stopped ? .notObserved : sourceState == .unavailable ? .unknown : s.presence,
                  rate: sourceState == .stopped || sourceState == .unavailable ? nil : s.rate,
                  total: .init(upload: s.up.projection, download: s.down.projection), history: s.history,
                  sampledAt: s.date, sampledMonotonic: s.mono, historyTruncated: s.truncated)
        }, sampledAt: envelope?.occurredAt, sampledMonotonic: envelope?.monotonicOccurredAt,
              truncated: truncated, lostFrames: lostFrames)
    }
}
