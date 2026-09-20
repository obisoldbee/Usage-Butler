import Foundation
import UsageButlerDomain

public actor ProviderController {
    /// Ark CLI 1.0.22+ applies a fifteen-minute authentication rate-limit
    /// cooldown. A shorter provider quota cadence must not turn a logged-out
    /// state into repeated token refresh attempts.
    private static let arkAuthenticationProbeFloor = RefreshDuration.seconds(15 * 60)

    private struct ActiveDiscovery {
        let generation: UInt64
        let task: Task<DiscoveryResult, Never>
    }

    private struct ActiveRead {
        let generation: UInt64
        let scope: ProviderScope
        let task: Task<ProviderReadResult, Never>
    }

    private struct ActiveLogin {
        let generation: UInt64
        let task: Task<LoginResult, Never>?
    }

    private enum DiscoveryExecution {
        case success(SuccessfulProviderDiscovery, generation: UInt64)
        case failure
        case cancelled
    }

    private let adapter: any ProviderAdapter
    private let cache: any ProviderQuotaCache
    private let clock: any ClockPort
    private let scheduler: RefreshScheduler
    private var policy: RefreshPolicy

    private var state: ProviderState
    private var isEnabled: Bool
    private var phase: ProviderControllerPhase = .idle
    private var revision: UInt64 = 0
    private var operationGeneration: UInt64 = 0
    private var cacheLoadCompleted = false
    private var discovery: ActiveDiscovery?
    private var read: ActiveRead?
    private var login: ActiveLogin?
    private var loginCancellationInFlight = false
    private var cacheClearIsRunning = false
    private var retryAttempts: [RefreshScheduleKey: Int] = [:]
    private var refreshPolicyGeneration: UInt64 = 0
    /// Persists the Ark authorization-recovery cadence even while a failed
    /// probe temporarily changes the public connection state to unavailable.
    private var authenticationProbeFloorActive = false
    private var projectionContinuations: [UUID: AsyncStream<ProviderProjection>.Continuation] = [:]

    public init(
        initialState: ProviderState,
        initiallyEnabled: Bool,
        adapter: any ProviderAdapter,
        cache: any ProviderQuotaCache,
        clock: any ClockPort,
        scheduler: RefreshScheduler,
        policy: RefreshPolicy = .standard
    ) throws {
        guard initialState.id == adapter.id else {
            throw ProviderControllerInitializationError.adapterIdentityMismatch(
                expected: initialState.id,
                actual: adapter.id
            )
        }
        guard initialState.capabilities == adapter.capabilities else {
            throw ProviderControllerInitializationError.adapterCapabilitiesMismatch
        }

        self.state = initialState
        self.isEnabled = initiallyEnabled
        self.adapter = adapter
        self.cache = cache
        self.clock = clock
        self.scheduler = scheduler
        self.policy = policy
    }

    public func projection() -> ProviderProjection {
        currentProjection()
    }

    public func projections() -> AsyncStream<ProviderProjection> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<ProviderProjection>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        projectionContinuations[id] = continuation
        continuation.yield(currentProjection())
        continuation.onTermination = { [weak self] _ in
            Task {
                await self?.removeProjectionContinuation(id: id)
            }
        }
        return stream
    }

    @discardableResult
    public func send(_ intent: ProviderIntent) async -> ProviderIntentOutcome {
        switch phase {
        case .shuttingDown:
            return .rejected(.shuttingDown)
        case .stopped:
            return .rejected(.stopped)
        case .idle, .starting, .running:
            break
        }

        if cacheClearIsRunning {
            switch intent {
            case .shutdown, .setRefreshPolicy:
                break
            case .clearCache:
                return .joined(generation: operationGeneration)
            default:
                return .deferred(.suspend(.operationInProgress))
            }
        }

        switch intent {
        case .start:
            return await start()

        case let .refresh(refreshIntent):
            guard phase == .running else { return .rejected(.notStarted) }
            if refreshIntent.trigger.initiator == .manual, isEnabled {
                await adapter.invalidateAuthenticationCache()
                guard phase == .running, isEnabled else {
                    return isEnabled ? .cancelled : .rejected(.disabled)
                }
            }
            if needsDiscoveryBeforeRefresh, state.refresh.activity == .idle {
                return await redetectThenRefresh(
                    initiatedBy: refreshIntent.trigger.initiator
                )
            }
            return await requestRefresh(trigger: refreshIntent.trigger)

        case let .setRefreshPolicy(updatedPolicy):
            return await setRefreshPolicy(updatedPolicy)

        case .redetect:
            guard phase == .running else { return .rejected(.notStarted) }
            guard isEnabled else { return .rejected(.disabled) }
            await adapter.invalidateAuthenticationCache()
            guard phase == .running, isEnabled else { return .cancelled }
            return await redetectThenRefresh(initiatedBy: .manual)

        case .login:
            guard phase == .running else { return .rejected(.notStarted) }
            guard isEnabled else { return .rejected(.disabled) }
            if let login {
                return .joined(generation: login.generation)
            }
            if loginCancellationInFlight {
                return .joined(generation: operationGeneration)
            }
            return await performLoginRecovery()

        case .cancelLogin:
            guard phase == .running else { return .rejected(.notStarted) }
            return await cancelActiveLogin()

        case let .setEnabled(enabled):
            return await setEnabled(enabled)

        case .clearCache:
            guard phase == .running else { return .rejected(.notStarted) }
            return await clearCache()

        case let .ageTick(staleAfter):
            guard phase == .running else { return .rejected(.notStarted) }
            let reading = await clock.reading()
            apply(.ageTick(staleAfter: staleAfter), now: reading.wallTime)
            return .completed

        case .shutdown:
            return await shutDown()
        }
    }

    private func start() async -> ProviderIntentOutcome {
        guard phase == .idle else { return .rejected(.alreadyStarted) }
        phase = .starting
        publish()

        let loadResult = await cache.load(providerID: state.id)
        guard phase != .shuttingDown, phase != .stopped else {
            return .cancelled
        }

        let reading = await clock.reading()
        cacheLoadCompleted = true
        phase = .running
        switch loadResult {
        case let .hit(data):
            apply(.cacheLoaded(data), now: reading.wallTime)
        case .miss:
            apply(
                .persistenceChanged(
                    .healthy(
                        lastReadAt: reading.wallTime,
                        lastWriteAt: lastWriteAt(from: state.persistence)
                    )
                ),
                now: reading.wallTime
            )
        case let .failure(failure):
            apply(.cacheLoadFailed(failure), now: reading.wallTime)
        }

        guard isEnabled else {
            apply(
                [
                    .disabled,
                    .gateChanged(.suspended(diagnosticCode: "provider.disabled"))
                ],
                now: reading.wallTime
            )
            return .completed
        }

        return await redetectThenRefresh(initiatedBy: .startup)
    }

    private func setEnabled(_ enabled: Bool) async -> ProviderIntentOutcome {
        guard enabled != isEnabled else { return .completed }
        isEnabled = enabled

        if !enabled {
            invalidateOperations()
            let generation = operationGeneration
            await scheduler.cancel(providerID: state.id)
            retryAttempts.removeAll()
            let reading = await clock.reading()
            guard isCurrentOperation(generation), !isEnabled else {
                return .cancelled
            }
            apply(
                [
                    .disabled,
                    .gateChanged(.suspended(diagnosticCode: "provider.disabled"))
                ],
                now: reading.wallTime
            )
            return .completed
        }

        let reading = await clock.reading()
        guard isEnabled else { return .cancelled }
        apply(.gateReset, now: reading.wallTime)
        // This publication is the retained stale ON projection. Detection begins only
        // after subscribers have been offered this state.
        guard phase == .running, cacheLoadCompleted else {
            return .completed
        }
        await adapter.invalidateAuthenticationCache()
        guard phase == .running, isEnabled else { return .cancelled }
        return await redetectThenRefresh(initiatedBy: .toggleOn)
    }

    private func setRefreshPolicy(
        _ updatedPolicy: RefreshPolicy
    ) async -> ProviderIntentOutcome {
        guard updatedPolicy != policy else { return .completed }

        policy = updatedPolicy
        let policyGeneration = nextRefreshPolicyGeneration()
        await scheduler.cancel(providerID: state.id)
        retryAttempts.removeAll()

        guard refreshPolicyGeneration == policyGeneration,
              phase == .running,
              isEnabled else {
            return .completed
        }

        if case .backoff = state.refresh.gate {
            let reading = await clock.reading()
            guard refreshPolicyGeneration == policyGeneration,
                  phase == .running,
                  isEnabled else {
                return .completed
            }
            apply(.gateReset, now: reading.wallTime)
        }

        guard !cacheClearIsRunning, state.refresh.activity == .idle else {
            return .completed
        }

        await scheduleAutomaticRefresh(
            scope: .provider,
            expectedOperationGeneration: operationGeneration
        )
        return .completed
    }

    private func clearCache() async -> ProviderIntentOutcome {
        cacheClearIsRunning = true
        defer { cacheClearIsRunning = false }
        let loginTask = login?.task
        invalidateOperations()
        let generation = operationGeneration
        await scheduler.cancel(providerID: state.id)
        retryAttempts.removeAll()
        // Keep the clear transaction exclusive until the cancelled login exits.
        // Its late result is invalid, but its process may still be winding down.
        if let loginTask {
            _ = await loginTask.value
        }
        guard isCurrentOperation(generation), phase == .running else {
            return .cancelled
        }

        let result = await cache.clear(providerID: state.id)
        guard isCurrentOperation(generation), phase == .running else {
            return .cancelled
        }

        let reading = await clock.reading()
        guard isCurrentOperation(generation), phase == .running else {
            return .cancelled
        }
        var events: [ProviderEvent] = [.operationsCancelled]
        if isEnabled { events.append(.gateReset) }
        switch result {
        case .success:
            events.append(.cacheCleared)
            apply(events, now: reading.wallTime)
        case let .failure(failure):
            events.append(.persistenceChanged(.degraded(failure)))
            apply(events, now: reading.wallTime)
            if isEnabled {
                await scheduleAutomaticRefresh(
                    scope: .provider,
                    expectedOperationGeneration: generation
                )
            }
            return .completed
        }

        guard isEnabled, case .automatic = policy.cadence else {
            return .completed
        }
        if needsDiscoveryBeforeRefresh {
            return await redetectThenRefresh(initiatedBy: .scheduled)
        }
        return await requestRefresh(trigger: .scheduled(scope: .provider))
    }

    private func redetectThenRefresh(
        initiatedBy initiator: RefreshInitiator,
        preservingActiveLogin: Bool = false
    ) async -> ProviderIntentOutcome {
        let discoveryResult = await performDiscovery(
            initiatedBy: initiator,
            preservingActiveLogin: preservingActiveLogin
        )
        switch discoveryResult {
        case .cancelled:
            return .cancelled
        case .failure:
            return .completed
        case let .success(success, generation):
            guard isCurrentOperation(generation), isEnabled, phase == .running else {
                return .cancelled
            }
            guard case .connected = success.connection else {
                await retainRequiresLoginAndScheduleRedetection(
                    success,
                    initiatedBy: initiator,
                    generation: generation
                )
                return .completed
            }
            authenticationProbeFloorActive = false

            let trigger: RefreshTrigger
            switch initiator {
            case .startup:
                trigger = .startup(scope: .provider)
            case .manual:
                trigger = .manual(scope: .provider)
            case .scheduled:
                trigger = .scheduled(scope: .provider)
            case .toggleOn:
                trigger = .toggleOn(scope: .provider)
            case .recovery:
                trigger = .recovery(scope: .provider)
            }
            return await requestRefresh(
                trigger: trigger,
                continuingFrom: success
            )
        }
    }

    private func retainRequiresLoginAndScheduleRedetection(
        _ success: SuccessfulProviderDiscovery,
        initiatedBy initiator: RefreshInitiator,
        generation: UInt64
    ) async {
        authenticationProbeFloorActive = state.id == .ark
        let reading = await clock.reading()
        guard isCurrentOperation(generation), isEnabled, phase == .running else {
            return
        }

        guard case let .automatic(interval) = policy.cadence else {
            apply(
                [
                    .discovery(.succeeded(success)),
                    .gateChanged(
                        .suspended(
                            diagnosticCode: "provider.discovery.requires_login"
                        )
                    )
                ],
                now: reading.wallTime
            )
            return
        }

        let probeDelay = authenticationProbeDelay(for: interval)
        let deadline = RefreshDecisionEngine.adding(
            probeDelay,
            to: reading.monotonicTime
        )
        apply(
            [
                .discovery(.succeeded(success)),
                .gateChanged(.backoff(until: deadline, attempt: 1))
            ],
            now: reading.wallTime
        )
        let token = await schedule(
            key: scheduleKey(scope: .provider),
            delay: probeDelay,
            reason: .discoveryRetry(attempt: 1, initiatedBy: initiator),
            expectedOperationGeneration: generation,
            expectedRefreshPolicyGeneration: refreshPolicyGeneration
        )
        guard isCurrentOperation(generation), isEnabled, phase == .running,
              let token, token.deadline != deadline else {
            return
        }
        let updatedAt = await clock.reading()
        guard isCurrentOperation(generation), isEnabled, phase == .running else {
            return
        }
        apply(
            .gateChanged(.backoff(until: token.deadline, attempt: 1)),
            now: updatedAt.wallTime
        )
    }

    private func performDiscovery(
        initiatedBy initiator: RefreshInitiator,
        preservingActiveLogin: Bool = false
    ) async -> DiscoveryExecution {
        invalidateOperations(preservingActiveLogin: preservingActiveLogin)
        let generation = operationGeneration
        await scheduler.cancel(providerID: state.id)
        guard isCurrentOperation(generation), isEnabled, phase == .running else {
            return .cancelled
        }
        let reading = await clock.reading()
        guard isCurrentOperation(generation), isEnabled, phase == .running else {
            return .cancelled
        }
        apply(.redetect(.started(generation: generation)), now: reading.wallTime)

        let adapter = self.adapter
        let task = Task { await adapter.discover() }
        discovery = ActiveDiscovery(generation: generation, task: task)
        let result = await task.value

        guard isCurrentOperation(generation),
              isEnabled,
              phase == .running,
              discovery?.generation == generation else {
            return .cancelled
        }
        discovery = nil
        let completedAt = await clock.reading()
        guard isCurrentOperation(generation), isEnabled, phase == .running else {
            return .cancelled
        }

        switch result {
        case let .success(success):
            retryAttempts.removeValue(forKey: scheduleKey(scope: .provider))
            return .success(success, generation: generation)

        case let .failure(failure):
            await recordDiscoveryFailure(
                failure,
                initiatedBy: initiator,
                generation: generation,
                reading: completedAt
            )
            return .failure
        }
    }

    private func requestRefresh(
        trigger: RefreshTrigger,
        continuingFrom discoverySuccess: SuccessfulProviderDiscovery? = nil
    ) async -> ProviderIntentOutcome {
        let expectedOperationGeneration = operationGeneration
        let reading = await clock.reading()
        guard operationGeneration == expectedOperationGeneration,
              isEnabled,
              phase == .running else {
            return .cancelled
        }
        let decision = RefreshDecisionEngine.decide(
            state: RefreshDecisionState(
                activity: discoverySuccess == nil ? state.refresh.activity : .idle,
                gate: discoverySuccess == nil ? state.refresh.gate : .open,
                isEnabled: isEnabled,
                acceptsIntents: phase == .running
            ),
            trigger: trigger,
            now: reading.monotonicTime,
            policy: policy
        )

        switch decision {
        case .run:
            break
        case let .join(generation):
            applyDeferredDiscoverySuccessIfNeeded(
                discoverySuccess,
                now: reading.wallTime
            )
            return .joined(generation: generation)
        case .cooldown, .backoff, .suspend:
            applyDeferredDiscoverySuccessIfNeeded(
                discoverySuccess,
                now: reading.wallTime
            )
            return .deferred(decision)
        }

        let key = scheduleKey(scope: trigger.scope)
        let generation = nextOperationGeneration()
        await scheduler.cancel(key: key)
        guard isCurrentOperation(generation), isEnabled, phase == .running else {
            return .cancelled
        }
        var startEvents: [ProviderEvent] = []
        if let discoverySuccess {
            startEvents.append(.discovery(.succeeded(discoverySuccess)))
        }
        if discoverySuccess != nil || state.refresh.gate != .open {
            startEvents.append(.gateChanged(.open))
        }
        startEvents.append(
            .refreshStarted(scope: trigger.scope, generation: generation)
        )
        apply(startEvents, now: reading.wallTime)

        let adapter = self.adapter
        let scope = trigger.scope
        let task = Task { await adapter.read(scope: scope) }
        read = ActiveRead(generation: generation, scope: scope, task: task)
        let result = await task.value

        guard isCurrentOperation(generation),
              isEnabled,
              phase == .running,
              read?.generation == generation else {
            return .cancelled
        }
        let authentication = await adapter.authenticationAfterRead()
        guard isCurrentOperation(generation), isEnabled, phase == .running,
              read?.generation == generation else { return .cancelled }
        read = nil
        let completedAt = await clock.reading()
        guard isCurrentOperation(generation), isEnabled, phase == .running else {
            return .cancelled
        }

        if let authentication {
            apply(.authenticationObserved(authentication), now: completedAt.wallTime)
            switch authentication {
            case .healthy, .warning:
                authenticationProbeFloorActive = false
            case .unknown, .expired:
                break
            }
        }

        switch result {
        case let .success(data):
            retryAttempts.removeValue(forKey: key)
            let completionGate: RefreshGateState
            if trigger.initiator == .manual {
                completionGate = .cooldown(
                    until: RefreshDecisionEngine.adding(
                        policy.manualCooldown,
                        to: completedAt.monotonicTime
                    )
                )
            } else {
                completionGate = .open
            }
            apply(
                [
                    .refreshSucceeded(data),
                    .gateChanged(completionGate)
                ],
                now: completedAt.wallTime
            )
            await scheduleAutomaticRefresh(
                scope: trigger.scope,
                expectedOperationGeneration: generation
            )
            await saveCommittedData(data, operationGeneration: generation)
            return .completed

        case let .successPatch(patch):
            retryAttempts.removeValue(forKey: key)
            let completionGate: RefreshGateState
            if trigger.initiator == .manual {
                completionGate = .cooldown(
                    until: RefreshDecisionEngine.adding(
                        policy.manualCooldown,
                        to: completedAt.monotonicTime
                    )
                )
            } else {
                completionGate = .open
            }
            apply(
                [
                    .refreshPatchSucceeded(patch),
                    .gateChanged(completionGate)
                ],
                now: completedAt.wallTime
            )
            await scheduleAutomaticRefresh(
                scope: trigger.scope,
                expectedOperationGeneration: generation
            )
            if let committed = state.lastGood {
                await saveCommittedData(committed, operationGeneration: generation)
            }
            return .completed

        case let .partial(patch, failure):
            await recordReadFailure(
                event: .refreshPartiallySucceeded(patch, failure),
                failure: failure,
                trigger: trigger,
                generation: generation,
                reading: completedAt
            )
            if let committed = state.lastGood {
                await saveCommittedData(committed, operationGeneration: generation)
            }
            return .completed

        case let .failure(failure):
            await recordReadFailure(
                event: .refreshFailed(failure),
                failure: failure,
                trigger: trigger,
                generation: generation,
                reading: completedAt
            )
            return .completed
        }
    }

    private func applyDeferredDiscoverySuccessIfNeeded(
        _ discoverySuccess: SuccessfulProviderDiscovery?,
        now: Date
    ) {
        guard let discoverySuccess else { return }
        apply(
            [
                .discovery(.succeeded(discoverySuccess)),
                .gateChanged(.open)
            ],
            now: now
        )
    }

    private func performLoginRecovery() async -> ProviderIntentOutcome {
        guard let method = state.capabilities.loginMethod else {
            return .rejected(.unsupportedLogin)
        }

        invalidateOperations()
        let generation = operationGeneration
        login = ActiveLogin(generation: generation, task: nil)
        defer {
            if login?.generation == generation {
                login = nil
            }
        }
        await scheduler.cancel(providerID: state.id)
        retryAttempts.removeAll()
        guard isCurrentOperation(generation),
              isEnabled,
              phase == .running,
              login?.generation == generation else {
            return .cancelled
        }
        let reading = await clock.reading()
        guard isCurrentOperation(generation),
              isEnabled,
              phase == .running,
              login?.generation == generation else {
            return .cancelled
        }
        apply(
            .login(.started(method: method, generation: generation)),
            now: reading.wallTime
        )

        let adapter = self.adapter
        let task = Task { await adapter.login(method: method) }
        login = ActiveLogin(generation: generation, task: task)
        let result = await task.value

        guard isCurrentOperation(generation),
              isEnabled,
              phase == .running,
              login?.generation == generation else {
            return .cancelled
        }
        let completedAt = await clock.reading()
        guard isCurrentOperation(generation), isEnabled, phase == .running,
              login?.generation == generation else {
            return .cancelled
        }

        switch result {
        case .success:
            apply(.login(.recoverySucceeded), now: completedAt.wallTime)
            return await redetectThenRefresh(
                initiatedBy: .recovery,
                preservingActiveLogin: true
            )
        case .cancelled:
            apply(.login(.cancelled), now: completedAt.wallTime)
            await scheduleAutomaticRefresh(
                scope: .provider,
                expectedOperationGeneration: generation
            )
            return .cancelled
        case let .failure(failure):
            await recordLoginFailure(
                failure,
                generation: generation,
                reading: completedAt
            )
            return .completed
        }
    }

    /// A failed user-started login must never schedule another login. Under an
    /// automatic policy, a usable connection keeps its ordinary quota cadence;
    /// otherwise a typed discovery probe remains armed for external recovery.
    private func recordLoginFailure(
        _ failure: ProviderFailure,
        generation: UInt64,
        reading: ClockReading
    ) async {
        let key = scheduleKey(scope: .provider)
        retryAttempts.removeValue(forKey: key)
        let preservesUsableConnection: Bool
        if case .connected = state.connection,
           !authenticationProbeFloorActive,
           !isExpiredAuthentication(state.authentication),
           !hasAuthenticationRecoveryFailure {
            preservesUsableConnection = true
        } else {
            preservesUsableConnection = false
        }
        if isAuthenticationRecoveryFailure(failure)
            || (failure.code == .rateLimited && !preservesUsableConnection) {
            authenticationProbeFloorActive = state.id == .ark
        }
        guard case let .automatic(interval) = policy.cadence else {
            apply(
                [
                    .login(.failed(failure)),
                    .gateChanged(
                        preservesUsableConnection
                            ? .open
                            : suspendedGate(for: failure)
                    )
                ],
                now: reading.wallTime
            )
            return
        }

        if preservesUsableConnection {
            apply(
                [
                    .login(.failed(failure)),
                    .gateChanged(.open)
                ],
                now: reading.wallTime
            )
            await scheduleAutomaticRefresh(
                scope: .provider,
                expectedOperationGeneration: generation
            )
            return
        }

        let probeDelay = authenticationProbeFloorActive
            ? authenticationProbeDelay(for: interval)
            : interval
        let baseDeadline = RefreshDecisionEngine.adding(
            probeDelay,
            to: reading.monotonicTime
        )
        apply(
            [
                .login(.failed(failure)),
                .gateChanged(.backoff(until: baseDeadline, attempt: 1))
            ],
            now: reading.wallTime
        )
        await scheduleAuthenticationProbeBackoff(
            key: key,
            delay: probeDelay,
            baseDeadline: baseDeadline,
            initiatedBy: .recovery,
            generation: generation
        )
    }

    private func authenticationProbeDelay(
        for configuredInterval: RefreshDuration
    ) -> RefreshDuration {
        guard state.id == .ark else { return configuredInterval }
        return max(configuredInterval, Self.arkAuthenticationProbeFloor)
    }

    /// Arms a typed discovery probe at the base backoff deadline. When the
    /// scheduler clamps the deadline, the gate is re-applied so state matches
    /// the timer that will actually fire.
    private func scheduleAuthenticationProbeBackoff(
        key: RefreshScheduleKey,
        delay: RefreshDuration,
        baseDeadline: MonotonicInstant,
        initiatedBy: RefreshInitiator,
        generation: UInt64
    ) async {
        let token = await schedule(
            key: key,
            delay: delay,
            reason: .discoveryRetry(attempt: 1, initiatedBy: initiatedBy),
            expectedOperationGeneration: generation,
            expectedRefreshPolicyGeneration: refreshPolicyGeneration
        )
        guard isCurrentOperation(generation), isEnabled, phase == .running,
              let token, token.deadline != baseDeadline else {
            return
        }
        let updatedAt = await clock.reading()
        guard isCurrentOperation(generation), isEnabled, phase == .running else {
            return
        }
        apply(
            .gateChanged(.backoff(until: token.deadline, attempt: 1)),
            now: updatedAt.wallTime
        )
    }

    private func cancelActiveLogin() async -> ProviderIntentOutcome {
        guard !loginCancellationInFlight else {
            return .joined(generation: operationGeneration)
        }
        guard let activeLogin = login,
              case .loggingIn = state.refresh.activity else {
            return .completed
        }

        loginCancellationInFlight = true
        activeLogin.task?.cancel()
        let generation = nextOperationGeneration()
        if let task = activeLogin.task {
            _ = await task.value
        }
        if login?.generation == activeLogin.generation {
            login = nil
        }
        loginCancellationInFlight = false
        let reading = await clock.reading()
        guard isCurrentOperation(generation), login == nil,
              isEnabled, phase == .running else {
            return .cancelled
        }
        apply(.login(.cancelled), now: reading.wallTime)
        await scheduleAutomaticRefresh(
            scope: .provider,
            expectedOperationGeneration: generation
        )
        return .completed
    }

    private func recordReadFailure(
        event: ProviderEvent,
        failure: ProviderFailure,
        trigger: RefreshTrigger,
        generation: UInt64,
        reading: ClockReading
    ) async {
        let key = scheduleKey(scope: trigger.scope)
        if isAuthenticationRecoveryFailure(failure) {
            authenticationProbeFloorActive = true
            retryAttempts.removeValue(forKey: key)
            guard case let .automatic(interval) = policy.cadence else {
                await scheduler.cancel(key: key)
                guard isCurrentOperation(generation), isEnabled, phase == .running else {
                    return
                }
                apply(
                    [event, .gateChanged(suspendedGate(for: failure))],
                    now: reading.wallTime
                )
                return
            }
            let delay = authenticationProbeDelay(for: interval)
            let deadline = RefreshDecisionEngine.adding(delay, to: reading.monotonicTime)
            apply(
                [event, .gateChanged(.backoff(until: deadline, attempt: 1))],
                now: reading.wallTime
            )
            await scheduleAuthenticationProbeBackoff(
                key: key,
                delay: delay,
                baseDeadline: deadline,
                initiatedBy: trigger.initiator,
                generation: generation
            )
            return
        }
        switch failure.retryClass {
        case .immediate, .backoff:
            let attempt = nextRetryAttempt(for: key, priorAttempt: trigger.retryAttempt)
            let delay = failure.retryClass == .immediate
                ? RefreshDuration(nanoseconds: 0)
                : policy.retryDelay(attempt: attempt)
            let baseDeadline = RefreshDecisionEngine.adding(
                delay,
                to: reading.monotonicTime
            )
            apply(
                [
                    event,
                    .gateChanged(
                        .backoff(until: baseDeadline, attempt: attempt)
                    )
                ],
                now: reading.wallTime
            )
            guard case .automatic = policy.cadence else { return }
            let token = await schedule(
                key: key,
                delay: delay,
                reason: .refreshRetry(
                    attempt: attempt,
                    initiatedBy: trigger.initiator
                ),
                expectedOperationGeneration: generation,
                expectedRefreshPolicyGeneration: refreshPolicyGeneration
            )
            guard isCurrentOperation(generation), isEnabled, phase == .running else {
                return
            }
            if let token, token.deadline != baseDeadline {
                let updatedAt = await clock.reading()
                guard isCurrentOperation(generation), isEnabled, phase == .running else {
                    return
                }
                apply(
                    .gateChanged(
                        .backoff(until: token.deadline, attempt: attempt)
                    ),
                    now: updatedAt.wallTime
                )
            }

        case .never, .afterRecovery:
            retryAttempts.removeValue(forKey: key)
            // A one-shot parse or environment glitch must not freeze the
            // provider until a manual redetect: under the automatic cadence
            // keep presenting the failure, then probe again at the cadence
            // interval so transient CLI hiccups self-heal.
            guard case let .automatic(interval) = policy.cadence else {
                await scheduler.cancel(key: key)
                guard isCurrentOperation(generation), isEnabled, phase == .running else {
                    return
                }
                apply(
                    [event, .gateChanged(suspendedGate(for: failure))],
                    now: reading.wallTime
                )
                return
            }
            let probeDeadline = RefreshDecisionEngine.adding(
                interval,
                to: reading.monotonicTime
            )
            apply(
                [
                    event,
                    .gateChanged(.backoff(until: probeDeadline, attempt: 1))
                ],
                now: reading.wallTime
            )
            let token = await schedule(
                key: key,
                delay: interval,
                reason: .automatic,
                expectedOperationGeneration: generation,
                expectedRefreshPolicyGeneration: refreshPolicyGeneration
            )
            guard isCurrentOperation(generation), isEnabled, phase == .running else {
                return
            }
            if let token, token.deadline != probeDeadline {
                let updatedAt = await clock.reading()
                guard isCurrentOperation(generation), isEnabled, phase == .running else {
                    return
                }
                apply(
                    .gateChanged(.backoff(until: token.deadline, attempt: 1)),
                    now: updatedAt.wallTime
                )
            }
        }
    }

    private func recordDiscoveryFailure(
        _ failure: ProviderFailure,
        initiatedBy initiator: RefreshInitiator,
        generation: UInt64,
        reading: ClockReading
    ) async {
        let key = scheduleKey(scope: .provider)
        switch failure.retryClass {
        case .immediate, .backoff:
            let attempt = nextRetryAttempt(for: key, priorAttempt: nil)
            let retryDelay = failure.retryClass == .immediate
                ? RefreshDuration(nanoseconds: 0)
                : policy.retryDelay(attempt: attempt)
            let delay = authenticationProbeFloorActive
                ? authenticationProbeDelay(for: retryDelay)
                : retryDelay
            let baseDeadline = RefreshDecisionEngine.adding(
                delay,
                to: reading.monotonicTime
            )
            apply(
                [
                    .discovery(.failed(failure)),
                    .gateChanged(
                        .backoff(until: baseDeadline, attempt: attempt)
                    )
                ],
                now: reading.wallTime
            )
            guard case .automatic = policy.cadence else { return }
            let token = await schedule(
                key: key,
                delay: delay,
                reason: .discoveryRetry(attempt: attempt, initiatedBy: initiator),
                expectedOperationGeneration: generation,
                expectedRefreshPolicyGeneration: refreshPolicyGeneration
            )
            guard isCurrentOperation(generation), isEnabled, phase == .running else {
                return
            }
            if let token, token.deadline != baseDeadline {
                let updatedAt = await clock.reading()
                guard isCurrentOperation(generation), isEnabled, phase == .running else {
                    return
                }
                apply(
                    .gateChanged(
                        .backoff(until: token.deadline, attempt: attempt)
                    ),
                    now: updatedAt.wallTime
                )
            }

        case .never, .afterRecovery:
            retryAttempts.removeValue(forKey: key)
            // Same cadence-probe policy as read failures: a terminal-looking
            // discovery failure re-runs detection at the cadence interval
            // instead of freezing the provider until a manual redetect.
            guard case let .automatic(interval) = policy.cadence else {
                await scheduler.cancel(key: key)
                guard isCurrentOperation(generation), isEnabled, phase == .running else {
                    return
                }
                apply(
                    [
                        .discovery(.failed(failure)),
                        .gateChanged(suspendedGate(for: failure))
                    ],
                    now: reading.wallTime
                )
                return
            }
            let probeDelay = authenticationProbeFloorActive
                ? authenticationProbeDelay(for: interval)
                : interval
            let probeDeadline = RefreshDecisionEngine.adding(
                probeDelay,
                to: reading.monotonicTime
            )
            apply(
                [
                    .discovery(.failed(failure)),
                    .gateChanged(.backoff(until: probeDeadline, attempt: 1))
                ],
                now: reading.wallTime
            )
            let token = await schedule(
                key: key,
                delay: probeDelay,
                reason: .discoveryRetry(attempt: 1, initiatedBy: initiator),
                expectedOperationGeneration: generation,
                expectedRefreshPolicyGeneration: refreshPolicyGeneration
            )
            guard isCurrentOperation(generation), isEnabled, phase == .running else {
                return
            }
            if let token, token.deadline != probeDeadline {
                let updatedAt = await clock.reading()
                guard isCurrentOperation(generation), isEnabled, phase == .running else {
                    return
                }
                apply(
                    .gateChanged(.backoff(until: token.deadline, attempt: 1)),
                    now: updatedAt.wallTime
                )
            }
        }
    }

    private func scheduleAutomaticRefresh(
        scope: ProviderScope,
        expectedOperationGeneration: UInt64
    ) async {
        guard case let .automatic(interval) = policy.cadence else { return }
        let policyGeneration = refreshPolicyGeneration
        let needsDiscovery = needsDiscoveryBeforeRefresh
        let delay: RefreshDuration
        if authenticationProbeFloorActive {
            delay = authenticationProbeDelay(for: interval)
        } else if case .requiresLogin = state.connection {
            delay = authenticationProbeDelay(for: interval)
        } else {
            delay = interval
        }
        let token = await schedule(
            key: scheduleKey(scope: scope),
            delay: delay,
            reason: needsDiscovery
                ? .discoveryRetry(attempt: 1, initiatedBy: .scheduled) : .automatic,
            expectedOperationGeneration: expectedOperationGeneration,
            expectedRefreshPolicyGeneration: policyGeneration
        )
        guard needsDiscovery, let token else { return }
        let reading = await clock.reading()
        guard isCurrentOperation(expectedOperationGeneration),
              refreshPolicyGeneration == policyGeneration,
              isEnabled, phase == .running else { return }
        apply(
            .gateChanged(.backoff(until: token.deadline, attempt: 1)),
            now: reading.wallTime
        )
    }

    private var needsDiscoveryBeforeRefresh: Bool {
        if authenticationProbeFloorActive { return true }
        return switch state.connection {
        case .connected, .disabled:
            false
        case .detecting, .requiresLogin, .unavailable:
            true
        }
    }

    private func isAuthenticationRecoveryFailure(_ failure: ProviderFailure) -> Bool {
        guard state.id == .ark else { return false }
        return failure.code == .authenticationRequired
            || failure.code == .authenticationExpired
    }

    private func isExpiredAuthentication(_ authentication: AuthenticationState) -> Bool {
        if case .expired = authentication { return true }
        return false
    }

    private var hasAuthenticationRecoveryFailure: Bool {
        state.scopedFailures.entries.contains {
            $0.failure.code == .authenticationRequired
                || $0.failure.code == .authenticationExpired
        }
    }

    private func schedule(
        key: RefreshScheduleKey,
        delay: RefreshDuration,
        reason: ScheduledRefreshReason,
        expectedOperationGeneration: UInt64,
        expectedRefreshPolicyGeneration: UInt64
    ) async -> RefreshScheduleToken? {
        guard isCurrentOperation(expectedOperationGeneration),
              refreshPolicyGeneration == expectedRefreshPolicyGeneration,
              isEnabled, phase == .running else { return nil }
        let token = await scheduler.schedule(
            key: key,
            after: delay,
            reason: reason
        ) { [weak self] token in
            await self?.handleScheduledWake(
                token,
                expectedOperationGeneration: expectedOperationGeneration,
                expectedRefreshPolicyGeneration: expectedRefreshPolicyGeneration
            )
        }
        guard operationGeneration == expectedOperationGeneration,
              expectedRefreshPolicyGeneration == refreshPolicyGeneration,
              phase == .running,
              isEnabled else {
            if let token {
                await scheduler.cancel(token: token)
            }
            return nil
        }
        return token
    }

    private func handleScheduledWake(
        _ token: RefreshScheduleToken,
        expectedOperationGeneration: UInt64,
        expectedRefreshPolicyGeneration: UInt64
    ) async {
        guard phase == .running,
              isEnabled,
              operationGeneration == expectedOperationGeneration,
              refreshPolicyGeneration == expectedRefreshPolicyGeneration else {
            return
        }

        switch token.reason {
        case .automatic:
            _ = await requestRefresh(trigger: .scheduled(scope: token.key.scope))
        case let .refreshRetry(attempt, initiatedBy):
            _ = await requestRefresh(
                trigger: .retry(
                    scope: token.key.scope,
                    attempt: attempt,
                    initiatedBy: initiatedBy
                )
            )
        case let .discoveryRetry(_, initiatedBy):
            _ = await redetectThenRefresh(initiatedBy: initiatedBy)
        }
    }

    private func saveCommittedData(
        _ data: ProviderQuotaData,
        operationGeneration generation: UInt64
    ) async {
        guard isCurrentOperation(generation), isEnabled, phase == .running else { return }
        let result = await cache.save(data)
        guard isCurrentOperation(generation), phase == .running else { return }
        let reading = await clock.reading()
        guard isCurrentOperation(generation), phase == .running else { return }
        switch result {
        case let .success(writtenAt):
            apply(
                .persistenceChanged(
                    .healthy(
                        lastReadAt: lastReadAt(from: state.persistence),
                        lastWriteAt: writtenAt
                    )
                ),
                now: reading.wallTime
            )
        case let .failure(failure):
            apply(
                .persistenceChanged(.degraded(failure)),
                now: reading.wallTime
            )
        }
    }

    private func shutDown() async -> ProviderIntentOutcome {
        phase = .shuttingDown
        invalidateOperations()
        await scheduler.cancel(providerID: state.id)
        retryAttempts.removeAll()
        let reading = await clock.reading()
        apply(
            [
                .shutdown,
                .gateChanged(.suspended(diagnosticCode: "provider.shutdown"))
            ],
            now: reading.wallTime
        )

        let latch = ShutdownCompletionLatch()
        let adapter = self.adapter
        let cache = self.cache
        let clock = self.clock
        let deadline = RefreshDecisionEngine.adding(
            policy.shutdownGrace,
            to: reading.monotonicTime
        )

        let adapterTask = Task { await adapter.shutdown() }
        let cacheTask = Task { await cache.shutdown() }
        let completionTask = Task {
            _ = await (adapterTask.value, cacheTask.value)
            await latch.signal(completedWithinGrace: true)
        }
        let timeoutTask = Task {
            do {
                try await clock.sleep(until: deadline)
                await latch.signal(completedWithinGrace: false)
            } catch {
                // The completion path cancels this timeout task.
            }
        }

        let completedWithinGrace = await latch.wait()
        if completedWithinGrace {
            timeoutTask.cancel()
        } else {
            adapterTask.cancel()
            cacheTask.cancel()
            completionTask.cancel()
        }

        let completedAt = await clock.reading()
        apply(.shutdownCompleted, now: completedAt.wallTime)
        phase = .stopped
        publish()
        finishProjectionStreams()
        return .shutdown(completedWithinGrace: completedWithinGrace)
    }

    private func suspendedGate(for failure: ProviderFailure) -> RefreshGateState {
        .suspended(diagnosticCode: failure.diagnosticCode)
    }

    private func scheduleKey(scope: ProviderScope) -> RefreshScheduleKey {
        RefreshScheduleKey(providerID: state.id, scope: scope)
    }

    private func nextRetryAttempt(
        for key: RefreshScheduleKey,
        priorAttempt: Int?
    ) -> Int {
        let current = max(retryAttempts[key] ?? 0, priorAttempt ?? 0)
        let next = current == .max ? current : current + 1
        retryAttempts[key] = next
        return next
    }

    private func invalidateOperations(preservingActiveLogin: Bool = false) {
        discovery?.task.cancel()
        read?.task.cancel()
        discovery = nil
        read = nil
        if !preservingActiveLogin {
            login?.task?.cancel()
            login = nil
        }
        _ = nextOperationGeneration()
    }

    private func nextOperationGeneration() -> UInt64 {
        operationGeneration = operationGeneration == .max ? 1 : operationGeneration + 1
        return operationGeneration
    }

    private func nextRefreshPolicyGeneration() -> UInt64 {
        refreshPolicyGeneration = refreshPolicyGeneration == .max
            ? 1
            : refreshPolicyGeneration + 1
        return refreshPolicyGeneration
    }

    private func isCurrentOperation(_ generation: UInt64) -> Bool {
        operationGeneration == generation
    }

    private func apply(_ event: ProviderEvent, now: Date) {
        apply([event], now: now)
    }

    private func apply(_ events: [ProviderEvent], now: Date) {
        for event in events {
            state = ProviderReducer.reduce(state: state, event: event, now: now)
        }
        publish()
    }

    private func currentProjection() -> ProviderProjection {
        ProviderProjection(
            revision: revision,
            isEnabled: isEnabled,
            phase: phase,
            state: state,
            automaticRefresh: { if case .automatic = policy.cadence { return true }; return false }()
        )
    }

    private func publish() {
        revision = revision == .max ? 1 : revision + 1
        let projection = currentProjection()
        for continuation in projectionContinuations.values {
            continuation.yield(projection)
        }
    }

    private func removeProjectionContinuation(id: UUID) {
        projectionContinuations.removeValue(forKey: id)
    }

    private func finishProjectionStreams() {
        let continuations = projectionContinuations.values
        projectionContinuations.removeAll()
        for continuation in continuations {
            continuation.finish()
        }
    }

    private func lastReadAt(from health: PersistenceHealth) -> Date? {
        guard case let .healthy(lastReadAt, _) = health else { return nil }
        return lastReadAt
    }

    private func lastWriteAt(from health: PersistenceHealth) -> Date? {
        guard case let .healthy(_, lastWriteAt) = health else { return nil }
        return lastWriteAt
    }
}

private actor ShutdownCompletionLatch {
    private var result: Bool?
    private var waiters: [CheckedContinuation<Bool, Never>] = []

    func signal(completedWithinGrace: Bool) {
        guard result == nil else { return }
        result = completedWithinGrace
        let pendingWaiters = waiters
        waiters.removeAll()
        for waiter in pendingWaiters {
            waiter.resume(returning: completedWithinGrace)
        }
    }

    func wait() async -> Bool {
        if let result {
            return result
        }
        return await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }
}
