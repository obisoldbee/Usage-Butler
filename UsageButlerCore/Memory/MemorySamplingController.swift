import Foundation
import UsageButlerDomain

public actor MemorySamplingController {
    private let clock: any MemorySamplingClock
    private let sleeper: any MemorySamplingSleeper
    private let pressureSource: any MemoryPressureSource
    private let statsReader: any MemoryStatsReader

    private var policy: MemorySamplingPolicy
    private var pressure: MemoryPressureState = .unknown
    private var latest: MemorySamplingSnapshot?
    private var history: MemorySampleHistory
    private var isRunning = false
    private var generation: UInt64 = 0
    private var samplingTask: Task<Void, Never>?
    private var pressureTask: Task<Void, Never>?
    private var updateContinuations: [
        UUID: AsyncStream<MemorySamplingState>.Continuation
    ] = [:]

    public init(
        clock: any MemorySamplingClock,
        sleeper: any MemorySamplingSleeper,
        pressureSource: any MemoryPressureSource,
        statsReader: any MemoryStatsReader,
        initialPolicy: MemorySamplingPolicy = .other,
        historyRetention: TimeInterval = MemorySampleHistory.twoHourRetention
    ) {
        self.clock = clock
        self.sleeper = sleeper
        self.pressureSource = pressureSource
        self.statsReader = statsReader
        self.policy = initialPolicy
        self.history = MemorySampleHistory(retention: historyRetention)
    }

    deinit {
        samplingTask?.cancel()
        pressureTask?.cancel()
        for continuation in updateContinuations.values {
            continuation.finish()
        }
    }

    public func start() {
        guard !isRunning else { return }
        isRunning = true
        startPressureSubscription()
        rescheduleSampling()
        emitState()
    }

    public func stop() {
        guard isRunning else { return }
        isRunning = false
        generation &+= 1
        samplingTask?.cancel()
        pressureTask?.cancel()
        samplingTask = nil
        pressureTask = nil
        emitState()
    }

    public func updatePolicy(_ newPolicy: MemorySamplingPolicy) {
        policy = newPolicy
        guard isRunning else {
            emitState()
            return
        }

        // Replacing the task cancels either the active read or its sleep. The
        // generation check also rejects a reader that ignores cancellation.
        rescheduleSampling()
        emitState()
    }

    public func currentState() -> MemorySamplingState {
        makeState()
    }

    public func downsampledHistory(
        targetPointCount: Int
    ) -> [MemoryHistoryPoint] {
        MemoryHistoryDownsampler.downsample(
            history.points,
            targetPointCount: targetPointCount
        )
    }

    public func updates() -> AsyncStream<MemorySamplingState> {
        let id = UUID()
        let pair = AsyncStream.makeStream(
            of: MemorySamplingState.self,
            bufferingPolicy: .bufferingNewest(1)
        )
        updateContinuations[id] = pair.continuation
        pair.continuation.yield(makeState())
        pair.continuation.onTermination = { [weak self] _ in
            Task { await self?.removeUpdateContinuation(id: id) }
        }
        return pair.stream
    }

    private func startPressureSubscription() {
        pressureTask?.cancel()
        let pressureSource = self.pressureSource
        pressureTask = Task { [weak self] in
            let events = await pressureSource.events()
            for await pressure in events {
                guard !Task.isCancelled else { return }
                await self?.receivePressure(pressure)
            }
        }
    }

    private func receivePressure(_ newPressure: MemoryPressureState) {
        guard isRunning, pressure != newPressure else { return }
        pressure = newPressure

        // Capture the pressure transition with a fresh numeric read. The
        // controller owns the one timestamp applied to both parts.
        rescheduleSampling()
    }

    private func rescheduleSampling() {
        generation &+= 1
        samplingTask?.cancel()
        let scheduledGeneration = generation
        samplingTask = Task { [weak self] in
            await self?.runSamplingLoop(generation: scheduledGeneration)
        }
    }

    private func runSamplingLoop(generation scheduledGeneration: UInt64) async {
        while ownsSamplingGeneration(scheduledGeneration) {
            let timestamp = await clock.now()
            guard ownsSamplingGeneration(scheduledGeneration) else { return }

            let sampledPressure = pressure
            let readback = await statsReader.read(capturedAt: timestamp)
            guard ownsSamplingGeneration(scheduledGeneration) else { return }
            let resolvedPressure = readback.pressureState ?? sampledPressure
            pressure = resolvedPressure

            let snapshot = MemorySamplingSnapshot(
                timestamp: timestamp,
                fields: readback.fields,
                pressureRatio: readback.pressureRatio,
                pressure: resolvedPressure
            )
            latest = snapshot
            history.append(snapshot.historyPoint)
            emitState()

            do {
                try await sleeper.sleep(for: policy.interval)
            } catch {
                return
            }
        }
    }

    private func ownsSamplingGeneration(_ scheduledGeneration: UInt64) -> Bool {
        isRunning
            && generation == scheduledGeneration
            && !Task.isCancelled
    }

    private func makeState() -> MemorySamplingState {
        MemorySamplingState(
            latest: latest,
            history: history.points,
            policy: policy,
            isRunning: isRunning
        )
    }

    private func emitState() {
        let state = makeState()
        for continuation in updateContinuations.values {
            continuation.yield(state)
        }
    }

    private func removeUpdateContinuation(id: UUID) {
        updateContinuations[id] = nil
    }
}
