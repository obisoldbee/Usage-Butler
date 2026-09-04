import Foundation
import UsageButlerDomain

public struct MemoryStatsReadback: Equatable, Sendable {
    public let capturedAt: Date
    public let fields: [MemorySummaryField]
    /// Independent continuous pressure signal. `nil` means the system signal
    /// could not be read; callers must not substitute used/physical memory.
    public let pressureRatio: Double?
    /// Same-frame discrete kernel state used to color the sample. `nil`
    /// preserves the event source's last known state; it never implies normal.
    public let pressureState: MemoryPressureState?

    public init(
        capturedAt: Date,
        fields: [MemorySummaryField],
        pressureRatio: Double? = nil,
        pressureState: MemoryPressureState? = nil
    ) {
        self.capturedAt = capturedAt
        self.fields = fields
        if let pressureRatio,
           pressureRatio.isFinite,
           (0...1).contains(pressureRatio) {
            self.pressureRatio = pressureRatio
        } else {
            self.pressureRatio = nil
        }
        self.pressureState = pressureState
    }
}

public protocol MemoryStatsReader: Sendable {
    func read(capturedAt: Date) async -> MemoryStatsReadback
}
