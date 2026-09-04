import Foundation
import UsageButlerCore

public struct SystemMemorySamplingClock: MemorySamplingClock {
    public init() {}

    public func now() async -> Date {
        Date()
    }
}
