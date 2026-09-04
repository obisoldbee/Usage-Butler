import Foundation

public struct MemorySampleHistory: Equatable, Sendable {
    public static let twoHourRetention: TimeInterval = 2 * 60 * 60

    public let retention: TimeInterval
    public private(set) var points: [MemoryHistoryPoint]

    public init(
        retention: TimeInterval = MemorySampleHistory.twoHourRetention,
        points: [MemoryHistoryPoint] = []
    ) {
        self.retention = max(0, retention)
        self.points = []
        for point in points {
            append(point)
        }
    }

    public mutating func append(_ point: MemoryHistoryPoint) {
        // Points arrive almost in order at a fixed cadence, so a binary
        // insertion keeps the array sorted without a full re-sort per sample.
        let insertionIndex = firstIndexWhereTimestampIsAtLeast(point.timestamp)
        if insertionIndex < points.endIndex,
           points[insertionIndex].timestamp == point.timestamp {
            points[insertionIndex] = point
        } else {
            points.insert(point, at: insertionIndex)
        }

        prune(referenceTimestamp: points.last?.timestamp ?? point.timestamp)
    }

    private func firstIndexWhereTimestampIsAtLeast(_ timestamp: Date) -> Int {
        var low = 0
        var high = points.count
        while low < high {
            let middle = (low + high) / 2
            if points[middle].timestamp < timestamp {
                low = middle + 1
            } else {
                high = middle
            }
        }
        return low
    }

    public mutating func prune(referenceTimestamp: Date) {
        guard !points.isEmpty else { return }
        let newestTimestamp = max(referenceTimestamp, points.last!.timestamp)
        let cutoff = newestTimestamp.addingTimeInterval(-retention)
        points.removeAll { $0.timestamp < cutoff }
    }
}
