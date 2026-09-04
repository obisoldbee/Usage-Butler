import Foundation

public enum MemoryHistoryDownsampler {
    /// Runtime sampling is at most ten seconds apart while the panel is not on
    /// the memory page. Three slow-cadence intervals are the fail-closed limit:
    /// a wider interval is an unavailable time gap, not a continuous trend.
    public static let maximumContinuousInterval: TimeInterval = 30

    private struct CandidateSpan {
        let leftIndex: Int
        let rightIndex: Int
        let duration: TimeInterval
    }

    private struct CandidateSpanHeap {
        private var storage: [CandidateSpan] = []

        var maximum: CandidateSpan? { storage.first }

        mutating func insert(_ span: CandidateSpan) {
            storage.append(span)
            var index = storage.count - 1
            while index > 0 {
                let parent = (index - 1) / 2
                guard Self.isHigherPriority(storage[index], than: storage[parent]) else {
                    return
                }
                storage.swapAt(index, parent)
                index = parent
            }
        }

        mutating func removeMaximum() -> CandidateSpan? {
            guard !storage.isEmpty else { return nil }
            if storage.count == 1 { return storage.removeLast() }

            let maximum = storage[0]
            storage[0] = storage.removeLast()
            var index = 0

            while true {
                let left = (index * 2) + 1
                guard left < storage.count else { break }
                let right = left + 1
                let child: Int
                if right < storage.count,
                   Self.isHigherPriority(storage[right], than: storage[left]) {
                    child = right
                } else {
                    child = left
                }
                guard Self.isHigherPriority(storage[child], than: storage[index]) else {
                    break
                }
                storage.swapAt(index, child)
                index = child
            }

            return maximum
        }

        private static func isHigherPriority(
            _ lhs: CandidateSpan,
            than rhs: CandidateSpan
        ) -> Bool {
            if lhs.duration != rhs.duration {
                return lhs.duration > rhs.duration
            }
            if lhs.leftIndex != rhs.leftIndex {
                return lhs.leftIndex < rhs.leftIndex
            }
            return lhs.rightIndex < rhs.rightIndex
        }
    }

    public static func downsample(
        _ input: [MemoryHistoryPoint],
        targetPointCount: Int,
        preserveRecentInterval: TimeInterval = 0
    ) -> [MemoryHistoryPoint] {
        guard targetPointCount > 0, !input.isEmpty else { return [] }

        let points = input.sorted { $0.timestamp < $1.timestamp }
        guard points.count > targetPointCount else { return points }

        var requiredIndices: Set<Int> = [0, points.count - 1]
        for index in 1..<points.count {
            let previous = points[index - 1]
            let current = points[index]
            if previous.isPressureRatioUnavailable
                != current.isPressureRatioUnavailable
                || previous.isLoadRatioUnavailable
                    != current.isLoadRatioUnavailable
                || previous.pressure != current.pressure
                || current.timestamp.timeIntervalSince(previous.timestamp)
                    > maximumContinuousInterval {
                requiredIndices.insert(index - 1)
                requiredIndices.insert(index)
            }
        }

        if preserveRecentInterval.isFinite,
           preserveRecentInterval > 0,
           let latestTimestamp = points.last?.timestamp {
            let recentCutoff = latestTimestamp.addingTimeInterval(
                -preserveRecentInterval
            )
            for index in points.indices where points[index].timestamp >= recentCutoff {
                requiredIndices.insert(index)
            }
        }

        // The target is soft when preserving pressure-ratio availability,
        // legacy load-ratio availability, pressure state, and real time-gap
        // boundaries requires more points.
        let desiredCount = max(targetPointCount, requiredIndices.count)

        // Split the widest remaining time span at its temporal midpoint. This
        // distributes points by timestamp instead of array density, so a
        // preceding 1-second cadence cannot starve a later 10-second cadence.
        var candidateSpans = makeCandidateSpans(
            in: points,
            selectedIndices: requiredIndices
        )
        while requiredIndices.count < desiredCount,
              let span = candidateSpans.removeMaximum() {
            insertMidpoint(
                of: span,
                in: points,
                selectedIndices: &requiredIndices,
                candidateSpans: &candidateSpans
            )
        }

        // Boundary preservation can consume the nominal budget in one part of
        // the window. Keep the target soft and add only the points needed to
        // prevent downsampling from manufacturing a chart gap. A real gap is
        // already bracketed by adjacent required source indices, so it is never
        // bridged here.
        while let span = candidateSpans.maximum,
              span.duration > maximumContinuousInterval {
            _ = candidateSpans.removeMaximum()
            insertMidpoint(
                of: span,
                in: points,
                selectedIndices: &requiredIndices,
                candidateSpans: &candidateSpans
            )
        }

        return requiredIndices.sorted().map { points[$0] }
    }

    private static func makeCandidateSpans(
        in points: [MemoryHistoryPoint],
        selectedIndices: Set<Int>
    ) -> CandidateSpanHeap {
        var heap = CandidateSpanHeap()
        let selected = selectedIndices.sorted()
        for (leftIndex, rightIndex) in zip(selected, selected.dropFirst()) {
            if let span = candidateSpan(
                leftIndex: leftIndex,
                rightIndex: rightIndex,
                points: points
            ) {
                heap.insert(span)
            }
        }
        return heap
    }

    private static func insertMidpoint(
        of span: CandidateSpan,
        in points: [MemoryHistoryPoint],
        selectedIndices: inout Set<Int>,
        candidateSpans: inout CandidateSpanHeap
    ) {
        let candidate = midpointIndex(of: span, in: points)
        selectedIndices.insert(candidate)

        if let left = candidateSpan(
            leftIndex: span.leftIndex,
            rightIndex: candidate,
            points: points
        ) {
            candidateSpans.insert(left)
        }
        if let right = candidateSpan(
            leftIndex: candidate,
            rightIndex: span.rightIndex,
            points: points
        ) {
            candidateSpans.insert(right)
        }
    }

    private static func candidateSpan(
        leftIndex: Int,
        rightIndex: Int,
        points: [MemoryHistoryPoint]
    ) -> CandidateSpan? {
        guard rightIndex - leftIndex > 1 else { return nil }
        return CandidateSpan(
            leftIndex: leftIndex,
            rightIndex: rightIndex,
            duration: points[rightIndex].timestamp.timeIntervalSince(
                points[leftIndex].timestamp
            )
        )
    }

    private static func midpointIndex(
        of span: CandidateSpan,
        in points: [MemoryHistoryPoint]
    ) -> Int {
        let leftTime = points[span.leftIndex].timestamp.timeIntervalSinceReferenceDate
        let rightTime = points[span.rightIndex].timestamp.timeIntervalSinceReferenceDate
        let midpoint = leftTime + ((rightTime - leftTime) / 2)

        var lowerBound = span.leftIndex + 1
        var upperBound = span.rightIndex - 1
        while lowerBound < upperBound {
            let index = lowerBound + ((upperBound - lowerBound) / 2)
            if points[index].timestamp.timeIntervalSinceReferenceDate < midpoint {
                lowerBound = index + 1
            } else {
                upperBound = index
            }
        }

        let laterIndex = lowerBound
        let earlierIndex = max(span.leftIndex + 1, laterIndex - 1)
        let earlierDistance = abs(
            points[earlierIndex].timestamp.timeIntervalSinceReferenceDate - midpoint
        )
        let laterDistance = abs(
            points[laterIndex].timestamp.timeIntervalSinceReferenceDate - midpoint
        )

        return earlierDistance <= laterDistance ? earlierIndex : laterIndex
    }
}
