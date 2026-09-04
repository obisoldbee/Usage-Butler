import Foundation
import UsageButlerDomain

/// Pure projection from sampled runtime memory state into the existing Stage 3
/// presentation DTO. The caller supplies `now`; this mapper performs no I/O and
/// never reads wall-clock time itself.
public enum LiveMemoryProjectionMapper {
    private static let orderedFieldIDs: [MemoryFieldID] = [
        .physical,
        .used,
        .cachedFiles,
        .swapUsed,
        .appMemory,
        .wired,
        .compressed
    ]

    public static func map(
        _ state: MemorySamplingState,
        now: Date
    ) -> Stage3MemoryProjection? {
        guard let latest = state.latest else { return nil }
        return map(latest, history: state.history, now: now)
    }

    public static func map(
        _ snapshot: MemorySamplingSnapshot,
        history: [MemoryHistoryPoint],
        now: Date
    ) -> Stage3MemoryProjection {
        let fields = orderedFieldIDs.compactMap { id in
            snapshot.fields.first { $0.id == id }
        }
        let cutoff = now.addingTimeInterval(
            -MemorySampleHistory.twoHourRetention
        )
        let visibleHistory = history
            .filter { point in
                point.timestamp.timeIntervalSinceReferenceDate.isFinite
                    && point.timestamp >= cutoff
                    && point.timestamp <= now
            }
            .sorted { $0.timestamp < $1.timestamp }

        return Stage3MemoryProjection(
            pressure: snapshot.pressure,
            fields: fields,
            history: visibleHistory.enumerated().map { index, point in
                MemoryTrendPoint(
                    id: index,
                    timestamp: point.timestamp,
                    loadRatio: point.estimatedUsedRatio,
                    pressureRatio: point.pressureRatio,
                    pressure: point.pressure
                )
            },
            historyWindowEnd: now,
            capturedAt: snapshot.timestamp,
            origin: .runtime
        )
    }
}
