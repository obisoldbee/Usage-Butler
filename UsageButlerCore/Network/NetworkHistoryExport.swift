import Foundation
import UsageButlerDomain

/// Separate from process-export v1. Frozen query, whole-minute boundaries,
/// exact decimal byte strings, deterministic aliases; cancellation has no I/O.
public enum NetworkHistoryExport {
    public static func encode(_ result: HistoryQueryResult, now: Date = Date()) throws -> Data {
        let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let none = NSNull()
        func date(_ value: Date?) -> Any { value.map { formatter.string(from: $0) } ?? (none as Any) }
        func integer(_ value: UInt64?) -> Any { value.map(String.init) ?? (none as Any) }
        func totals(_ value: HistoryTotals) -> [String: Any] {
            ["uploadBytes": integer(value.upload), "downloadBytes": integer(value.download),
             "uploadObservedMicroseconds": String(value.uploadObservedMicroseconds),
             "downloadObservedMicroseconds": String(value.downloadObservedMicroseconds),
             "uploadSamples": String(value.uploadSamples), "downloadSamples": String(value.downloadSamples),
             "sampledPeakUploadBytesPerSecond": value.peakUpload, "sampledPeakDownloadBytesPerSecond": value.peakDownload,
             "qualityFlags": value.quality.rawValue]
        }
        let ids = Set(result.applications.map(\.identity.key) + result.events.map(\.applicationKey)).sorted()
        let aliases = Dictionary(uniqueKeysWithValues: ids.enumerated().map { ($0.element, "app-\($0.offset + 1)") })
        let coverage = result.coverage
        let root: [String: Any] = [
            "schema": "application-network-history-v2", "schemaVersion": 2,
            "exportedAt": date(now), "rangeStart": date(result.range.start), "rangeEndExclusive": date(result.range.end),
            "granularity": "minute aggregates; curve buckets may combine minutes; no proration",
            "privacy": "local aliases; not anonymous; no names, paths, PID, bundle IDs or targets",
            "page": result.page, "pageSize": 64, "totalApplications": result.totalApplications,
            "applications": result.applications.map { ["alias": aliases[$0.identity.key]!, "identitySnapshotCount": $0.identitySnapshotCount, "totals": totals($0.totals)] as [String: Any] },
            "curve": result.curve.map { ["start": date($0.start), "endExclusive": date($0.end), "segments": $0.segments, "totals": totals($0.totals)] as [String: Any] },
            "utcDays": result.days.map { ["day": date($0.day), "totals": totals($0.totals)] },
            "events": result.events.map { event in
                ["application": aliases[event.applicationKey]!, "kind": event.kind,
                 "start": date(event.start), "end": date(event.end), "observedUploadBytes": String(event.bytes),
                 "sampledPeakBytesPerSecond": event.peak, "observedSeconds": event.observedSeconds,
                 "endReason": event.endReason ?? (none as Any), "bytesScope": "entire overlapping event, not clipped to selected range",
                 "rule": ["version": 1, "largeBytes": String(event.rule.largeBytes), "sustainedSeconds": event.rule.sustainedSeconds,
                          "sustainedBytesPerSecond": event.rule.sustainedBytesPerSecond]] as [String: Any]
            },
            "coverage": ["firstCollectedAt": date(coverage.firstCollectedAt), "lastCommittedAt": date(coverage.lastCommittedAt),
                         "oldestRetainedAt": date(coverage.oldestRetainedAt), "retentionDays": coverage.retentionDays,
                         "retentionTrimmed": coverage.retentionTrimmed, "eventsTruncated": coverage.eventsTruncated,
                         "conservativeAge": coverage.conservativeAge, "uncleanRestart": coverage.recoveredUncleanSession,
                         "unattributedSamples": String(coverage.unattributedSamples), "sourceSamples": String(coverage.sourceSamples),
                         "sourcePartialSamples": String(coverage.sourcePartialSamples),
                         "sourceObservedMicroseconds": String(coverage.sourceObservedMicroseconds),
                         "issue": coverage.issue ?? (none as Any)]
        ]
        let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
        guard data.count <= BackgroundNetworkWire.maximumResponseBytes else { throw BackgroundNetworkWire.Failure.responseTooLarge }
        return data
    }
}
