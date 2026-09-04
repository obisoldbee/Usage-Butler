import Foundation
import UsageButlerDomain

public enum MemorySamplingPolicy: Equatable, Sendable {
    case memoryPageVisible
    case other

    public var interval: Duration {
        switch self {
        case .memoryPageVisible: .seconds(1)
        case .other: .seconds(10)
        }
    }
}

public struct MemoryHistoryPoint: Equatable, Sendable {
    public let timestamp: Date
    public let estimatedUsedRatio: Double?
    public let pressureRatio: Double?
    public let pressure: MemoryPressureState

    public init(
        timestamp: Date,
        estimatedUsedRatio: Double?,
        pressureRatio: Double? = nil,
        pressure: MemoryPressureState
    ) {
        self.timestamp = timestamp
        if let estimatedUsedRatio, estimatedUsedRatio.isFinite {
            self.estimatedUsedRatio = min(max(estimatedUsedRatio, 0), 1)
        } else {
            self.estimatedUsedRatio = nil
        }
        if let pressureRatio,
           pressureRatio.isFinite,
           (0...1).contains(pressureRatio) {
            self.pressureRatio = pressureRatio
        } else {
            self.pressureRatio = nil
        }
        self.pressure = pressure
    }

    public var isLoadRatioUnavailable: Bool { estimatedUsedRatio == nil }
    public var isPressureRatioUnavailable: Bool { pressureRatio == nil }
}

public struct MemorySamplingSnapshot: Equatable, Sendable {
    public let timestamp: Date
    public let fields: [MemorySummaryField]
    public let estimatedUsedRatio: Double?
    public let pressureRatio: Double?
    public let pressure: MemoryPressureState

    public init(
        timestamp: Date,
        fields: [MemorySummaryField],
        pressureRatio: Double? = nil,
        pressure: MemoryPressureState
    ) {
        self.timestamp = timestamp
        self.fields = fields
        self.estimatedUsedRatio = Self.makeEstimatedUsedRatio(fields: fields)
        if let pressureRatio,
           pressureRatio.isFinite,
           (0...1).contains(pressureRatio) {
            self.pressureRatio = pressureRatio
        } else {
            self.pressureRatio = nil
        }
        self.pressure = pressure
    }

    public var historyPoint: MemoryHistoryPoint {
        MemoryHistoryPoint(
            timestamp: timestamp,
            estimatedUsedRatio: estimatedUsedRatio,
            pressureRatio: pressureRatio,
            pressure: pressure
        )
    }

    private static func makeEstimatedUsedRatio(
        fields: [MemorySummaryField]
    ) -> Double? {
        guard
            let physicalBytes = fields.first(where: { $0.id == .physical })?.bytes,
            physicalBytes > 0,
            let usedBytes = fields.first(where: { $0.id == .used })?.bytes
        else {
            return nil
        }

        let ratio = Double(usedBytes) / Double(physicalBytes)
        guard ratio.isFinite else { return nil }
        return min(max(ratio, 0), 1)
    }
}

public struct MemorySamplingState: Equatable, Sendable {
    public let latest: MemorySamplingSnapshot?
    public let history: [MemoryHistoryPoint]
    public let policy: MemorySamplingPolicy
    public let isRunning: Bool

    public init(
        latest: MemorySamplingSnapshot?,
        history: [MemoryHistoryPoint],
        policy: MemorySamplingPolicy,
        isRunning: Bool
    ) {
        self.latest = latest
        self.history = history
        self.policy = policy
        self.isRunning = isRunning
    }
}
