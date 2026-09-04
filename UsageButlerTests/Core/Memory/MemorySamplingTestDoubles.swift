import Foundation
import UsageButlerCore
import UsageButlerDomain

actor TestMemorySamplingClock: MemorySamplingClock {
    private var timestamps: [Date]
    private var fallback: Date

    init(timestamps: [Date]) {
        self.timestamps = timestamps
        self.fallback = timestamps.last ?? Date(timeIntervalSince1970: 0)
    }

    func now() async -> Date {
        guard !timestamps.isEmpty else { return fallback }
        let timestamp = timestamps.removeFirst()
        fallback = timestamp
        return timestamp
    }
}

actor TestMemoryPressureSource: MemoryPressureSource {
    private let stream: AsyncStream<MemoryPressureState>
    private let continuation: AsyncStream<MemoryPressureState>.Continuation

    init() {
        let pair = AsyncStream.makeStream(
            of: MemoryPressureState.self,
            bufferingPolicy: .unbounded
        )
        stream = pair.stream
        continuation = pair.continuation
    }

    func events() async -> AsyncStream<MemoryPressureState> {
        stream
    }

    func send(_ pressure: MemoryPressureState) {
        continuation.yield(pressure)
    }

    func finish() {
        continuation.finish()
    }
}

actor ControlledMemoryStatsReader: MemoryStatsReader {
    struct Request: Equatable, Sendable {
        let id: Int
        let capturedAt: Date
    }

    private struct PendingRequest {
        let request: Request
        let continuation: CheckedContinuation<MemoryStatsReadback, Never>
    }

    private var nextID = 0
    private var pending: [PendingRequest] = []
    private var cancellationObservations: [Int: Bool] = [:]

    func read(capturedAt: Date) async -> MemoryStatsReadback {
        let id = nextID
        nextID += 1
        let request = Request(id: id, capturedAt: capturedAt)
        let result = await withCheckedContinuation { continuation in
            pending.append(PendingRequest(
                request: request,
                continuation: continuation
            ))
        }
        cancellationObservations[id] = Task.isCancelled
        return result
    }

    func pendingRequests() -> [Request] {
        pending.map(\.request)
    }

    @discardableResult
    func complete(
        id: Int,
        fields: [MemorySummaryField],
        pressureRatio: Double? = nil,
        pressureState: MemoryPressureState? = nil,
        returnedTimestamp: Date? = nil
    ) -> Bool {
        guard let index = pending.firstIndex(where: { $0.request.id == id }) else {
            return false
        }
        let request = pending.remove(at: index)
        request.continuation.resume(returning: MemoryStatsReadback(
            capturedAt: returnedTimestamp ?? request.request.capturedAt,
            fields: fields,
            pressureRatio: pressureRatio,
            pressureState: pressureState
        ))
        return true
    }

    func observedCancellation(id: Int) -> Bool? {
        cancellationObservations[id]
    }
}

actor ControlledMemorySamplingSleeper: MemorySamplingSleeper {
    struct Request: Equatable, Sendable {
        let id: Int
        let interval: Duration
    }

    private struct PendingRequest {
        let request: Request
        let continuation: CheckedContinuation<Void, Error>
    }

    private var nextID = 0
    private var allRequests: [Request] = []
    private var pending: [PendingRequest] = []
    private var cancelled: [Request] = []

    func sleep(for interval: Duration) async throws {
        let id = nextID
        nextID += 1
        let request = Request(id: id, interval: interval)
        allRequests.append(request)

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                pending.append(PendingRequest(
                    request: request,
                    continuation: continuation
                ))
            }
        } onCancel: {
            Task { await self.cancel(id: id) }
        }
    }

    func requests() -> [Request] {
        allRequests
    }

    func cancelledRequests() -> [Request] {
        cancelled
    }

    @discardableResult
    func resume(id: Int) -> Bool {
        guard let index = pending.firstIndex(where: { $0.request.id == id }) else {
            return false
        }
        let request = pending.remove(at: index)
        request.continuation.resume(returning: ())
        return true
    }

    private func cancel(id: Int) {
        guard let index = pending.firstIndex(where: { $0.request.id == id }) else {
            return
        }
        let request = pending.remove(at: index)
        cancelled.append(request.request)
        request.continuation.resume(throwing: CancellationError())
    }
}

func memoryFields(
    physicalBytes: UInt64 = 100,
    usedBytes: UInt64? = 50
) -> [MemorySummaryField] {
    let physical = MemorySummaryField(
        id: .physical,
        availability: .available(bytes: physicalBytes),
        provenance: .directSystemValue
    )
    let used = MemorySummaryField(
        id: .used,
        availability: usedBytes.map(MemoryFieldAvailability.available)
            ?? .unavailable(.sourceReadFailed(.hostVMInfo64)),
        provenance: .derivedSystemEstimate(formulaID: "test.used")
    )
    return [physical, used]
}

func eventually(
    iterations: Int = 10_000,
    _ condition: @escaping @Sendable () async -> Bool
) async -> Bool {
    for _ in 0..<iterations {
        if await condition() { return true }
        await Task.yield()
    }
    return false
}
