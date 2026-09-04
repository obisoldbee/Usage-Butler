import Foundation
import UsageButlerDomain

public protocol MemorySamplingClock: Sendable {
    func now() async -> Date
}

public protocol MemorySamplingSleeper: Sendable {
    func sleep(for interval: Duration) async throws
}

public protocol MemoryPressureSource: Sendable {
    func events() async -> AsyncStream<MemoryPressureState>
}
