import Foundation
import UsageButlerDomain

/// New, independent schema. Legacy flow/interface snapshots remain v1/v2 and
/// are never upgraded into live process evidence by decoding an old file.
public enum ProcessNetworkExport {
    public enum Failure: Error { case oversized }
    public static func encode(snapshot: ProcessNetworkSnapshot, keys: [String],
                              now: Date, window: TimeInterval, includeHistory: Bool,
                              monotonicNow: MonotonicInstant = .init(nanoseconds: DispatchTime.now().uptimeNanoseconds)) throws -> Data {
        let formatter = ISO8601DateFormatter()
        // Existing v1 date fields use stable UTC millisecond precision.
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let none = NSNull()
        var sessionAliases: [CaptureSessionID: String] = [snapshot.sessionID: "session-1"]
        func sessionAlias(_ id: CaptureSessionID) -> String {
            if let alias = sessionAliases[id] { return alias }
            let alias = "session-\(sessionAliases.count + 1)"
            sessionAliases[id] = alias
            return alias
        }
        func date(_ value: Date?) -> Any { value.map { formatter.string(from: $0) } ?? (none as Any) }
        func integer(_ value: UInt64?) -> Any { value.map(String.init) ?? (none as Any) }
        func segment(_ s: DirectionByteTotal) -> [String: Any] {
            ["bytes": integer(s.bytes), "since": date(s.since), "sinceMonotonicNanoseconds": integer(s.sinceMonotonic?.nanoseconds),
             "breakReason": s.breakReason ?? (none as Any)]
        }
        let unique = Array(Set(keys)).sorted()
        let appObjects: [[String: Any]] = unique.enumerated().compactMap { index, key in
            guard let app = snapshot.applications[key] else { return nil }
            let history = includeHistory ? app.history.filter { $0.sampledAt >= now.addingTimeInterval(-window) && $0.sampledAt <= now } : []
            let points: [[String: Any]] = history.map { sample in
                ["at": date(sample.sampledAt), "monotonicNanoseconds": integer(sample.sampledMonotonic.nanoseconds),
                 "session": sessionAlias(sample.captureSessionID),
                 "samplingIntervalSeconds": sample.samplingInterval ?? (none as Any),
                 "uploadBytesPerSecond": sample.uploadBytesPerSecond ?? (none as Any),
                 "downloadBytesPerSecond": sample.downloadBytesPerSecond ?? (none as Any),
                 "uploadContinuity": sample.uploadContinuityID ?? (none as Any),
                 "downloadContinuity": sample.downloadContinuityID ?? (none as Any)]
            }
            let fresh = ProcessNetworkFreshness.isFresh(app, state: snapshot.state, now: monotonicNow)
            return ["application": "application-\(index + 1)", "identityEvidence": app.identity.evidence.rawValue,
                    "presence": app.presence.rawValue, "sampledAt": date(app.sampledAt),
                    "observedProcessCount": String(app.processes.count), "connectionCount": none,
                    "targets": none, "protocols": none, "signingIdentity": none,
                    "uploadBytesPerSecond": fresh ? (app.rate?.uploadBytesPerSecond ?? (none as Any)) : none,
                    "downloadBytesPerSecond": fresh ? (app.rate?.downloadBytesPerSecond ?? (none as Any)) : none,
                    "uploadSegment": segment(app.total.upload), "downloadSegment": segment(app.total.download),
                    "historyTruncated": app.historyTruncated, "history": points]
        }
        let object: [String: Any] = [
            "schema": "usagebutler.network.process-export", "version": 1, "fixture": false,
            "source": ProcessNetworkSnapshot.sourceID, "session": sessionAlias(snapshot.sessionID),
            "sequence": String(snapshot.sequence), "state": snapshot.state.rawValue,
            "sourceIssue": snapshot.issue ?? (none as Any), "exportedAt": date(now),
            "sourceSampledAt": date(snapshot.sampledAt), "sourceMonotonicNanoseconds": integer(snapshot.sampledMonotonic?.nanoseconds),
            "timestampMethod": "PTY-header-receipt; frame completed by next header; not kernel event time",
            "coverage": "system-visible process socket counters; loopback/proxy legs may be included; incomplete short-lived process coverage",
            "windowSeconds": window, "historyIncluded": includeHistory,
            "truncated": snapshot.truncated, "lostFrames": String(snapshot.lostFrames),
            "redaction": "per-export aliases; no names, executable paths, PIDs or endpoints",
            "applications": appObjects]
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        guard data.count <= 8 * 1_024 * 1_024 else { throw Failure.oversized }
        return data
    }
}
