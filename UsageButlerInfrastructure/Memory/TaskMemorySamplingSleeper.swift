import Foundation
import UsageButlerCore

public struct TaskMemorySamplingSleeper: MemorySamplingSleeper {
    public init() {}

    public func sleep(for interval: Duration) async throws {
        try await Task.sleep(for: interval)
    }
}
