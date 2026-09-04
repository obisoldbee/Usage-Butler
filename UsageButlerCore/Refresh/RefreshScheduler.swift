import Foundation
import UsageButlerDomain

public struct RefreshScheduleKey: Equatable, Hashable, Sendable {
    public let providerID: ProviderID
    public let scope: ProviderScope

    public init(providerID: ProviderID, scope: ProviderScope) {
        self.providerID = providerID
        self.scope = scope
    }
}

public enum ScheduledRefreshReason: Equatable, Sendable {
    case automatic
    case refreshRetry(attempt: Int, initiatedBy: RefreshInitiator)
    case discoveryRetry(attempt: Int, initiatedBy: RefreshInitiator)

    fileprivate var jitterAttempt: Int? {
        switch self {
        case .automatic:
            nil
        case let .refreshRetry(attempt, _),
             let .discoveryRetry(attempt, _):
            attempt
        }
    }
}

public struct RefreshScheduleToken: Equatable, Sendable {
    public let key: RefreshScheduleKey
    public let generation: UInt64
    public let deadline: MonotonicInstant
    public let reason: ScheduledRefreshReason

    public init(
        key: RefreshScheduleKey,
        generation: UInt64,
        deadline: MonotonicInstant,
        reason: ScheduledRefreshReason
    ) {
        self.key = key
        self.generation = generation
        self.deadline = deadline
        self.reason = reason
    }
}

public protocol RefreshJitterSource: Sendable {
    func offsetNanoseconds(for key: RefreshScheduleKey, attempt: Int) -> UInt64
}

public struct ZeroRefreshJitter: RefreshJitterSource {
    public init() {}

    public func offsetNanoseconds(
        for key: RefreshScheduleKey,
        attempt: Int
    ) -> UInt64 {
        0
    }
}

public struct FixedRefreshJitter: RefreshJitterSource {
    public let offset: RefreshDuration

    public init(offset: RefreshDuration) {
        self.offset = offset
    }

    public func offsetNanoseconds(
        for key: RefreshScheduleKey,
        attempt: Int
    ) -> UInt64 {
        offset.nanoseconds
    }
}

public actor RefreshScheduler {
    public typealias Handler = @Sendable (RefreshScheduleToken) async -> Void

    private struct PendingSchedule {
        let token: RefreshScheduleToken
        let task: Task<Void, Never>
    }

    private let clock: any ClockPort
    private let jitter: any RefreshJitterSource
    private var generations: [RefreshScheduleKey: UInt64] = [:]
    private var pending: [RefreshScheduleKey: PendingSchedule] = [:]
    private var acceptsSchedules = true

    public init(
        clock: any ClockPort,
        jitter: any RefreshJitterSource = ZeroRefreshJitter()
    ) {
        self.clock = clock
        self.jitter = jitter
    }

    @discardableResult
    public func schedule(
        key: RefreshScheduleKey,
        after delay: RefreshDuration,
        reason: ScheduledRefreshReason,
        handler: @escaping Handler
    ) async -> RefreshScheduleToken? {
        guard acceptsSchedules else { return nil }

        pending.removeValue(forKey: key)?.task.cancel()
        let generation = advanceGeneration(for: key)
        let reading = await clock.reading()
        guard acceptsSchedules, generations[key] == generation else { return nil }

        let baseDeadline = RefreshDecisionEngine.adding(delay, to: reading.monotonicTime)
        let deadline: MonotonicInstant
        if let attempt = reason.jitterAttempt {
            deadline = RefreshDecisionEngine.adding(
                RefreshDuration(
                    nanoseconds: jitter.offsetNanoseconds(for: key, attempt: attempt)
                ),
                to: baseDeadline
            )
        } else {
            deadline = baseDeadline
        }

        let token = RefreshScheduleToken(
            key: key,
            generation: generation,
            deadline: deadline,
            reason: reason
        )
        let clock = self.clock
        let task = Task { [weak self, clock] in
            do {
                try await clock.sleep(until: deadline)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            await self?.fireIfCurrent(token: token, handler: handler)
        }
        pending[key] = PendingSchedule(token: token, task: task)
        return token
    }

    public func cancel(key: RefreshScheduleKey) {
        pending.removeValue(forKey: key)?.task.cancel()
        _ = advanceGeneration(for: key)
    }

    public func cancel(token: RefreshScheduleToken) {
        guard let current = pending[token.key], current.token == token else { return }
        pending.removeValue(forKey: token.key)?.task.cancel()
        _ = advanceGeneration(for: token.key)
    }

    public func cancel(providerID: ProviderID) {
        let keys = Set(pending.keys.filter { $0.providerID == providerID })
            .union(generations.keys.filter { $0.providerID == providerID })
        for key in keys {
            pending.removeValue(forKey: key)?.task.cancel()
            _ = advanceGeneration(for: key)
        }
    }

    public func scheduledToken(for key: RefreshScheduleKey) -> RefreshScheduleToken? {
        pending[key]?.token
    }

    public func scheduledTokens(providerID: ProviderID) -> [RefreshScheduleToken] {
        pending.values
            .map(\.token)
            .filter { $0.key.providerID == providerID }
            .sorted { lhs, rhs in
                if lhs.deadline != rhs.deadline {
                    return lhs.deadline < rhs.deadline
                }
                return lhs.generation < rhs.generation
            }
    }

    public func shutdown() {
        guard acceptsSchedules else { return }
        acceptsSchedules = false
        for schedule in pending.values {
            schedule.task.cancel()
        }
        pending.removeAll()
        for key in Array(generations.keys) {
            _ = advanceGeneration(for: key)
        }
    }

    private func fireIfCurrent(
        token: RefreshScheduleToken,
        handler: @escaping Handler
    ) async {
        guard acceptsSchedules,
              let current = pending[token.key],
              current.token == token else {
            return
        }
        pending.removeValue(forKey: token.key)
        await handler(token)
    }

    private func advanceGeneration(for key: RefreshScheduleKey) -> UInt64 {
        let current = generations[key] ?? 0
        let next = current == .max ? 1 : current + 1
        generations[key] = next
        return next
    }
}
