import Foundation
import UsageButlerDomain

/// Two explainable local filters. Large segments end at zero/unknown; sustained
/// segments also end below the configured rate. Neither bridges a missing frame.
struct HistoryActivityAccumulator: Sendable {
    struct Activity: Sendable {
        let key: String
        let app: Int64
        let stableKey: String
        let segment: Int64
        let kind: String
        let start: Date
        var end: Date
        var bytes: UInt64
        var peak: Double
        var seconds: Double
        let rule: HistoryUploadRule
        var reason: String?
        var databaseID: Int64?
        var qualified: Bool {
            kind == "large" ? bytes >= rule.largeBytes : seconds >= rule.sustainedSeconds
        }
    }
    private var active: [String: Activity] = [:]
    private var changes: [String: Activity] = [:]
    private var serial: UInt64 = 0

    mutating func accept(app: Int64, stableKey: String? = nil, segment: Int64, upload: UInt64?, end: Date, seconds: Double, rule: HistoryUploadRule) {
        let stableKey = stableKey ?? String(app)
        for kind in ["large", "sustained"] {
            let slot = "\(stableKey):\(kind)"
            guard let upload, upload > 0, seconds > 0, seconds.isFinite else {
                finish(slot, reason: upload == 0 ? "observed-zero" : "unobserved-interval"); continue
            }
            let rate = Double(upload) / seconds
            if kind == "sustained", rate < rule.sustainedBytesPerSecond {
                finish(slot, reason: "below-threshold"); continue
            }
            let start = end.addingTimeInterval(-seconds)
            if let prior = active[slot], abs(start.timeIntervalSince(prior.end)) > 0.25 {
                finish(slot, reason: "sampling-gap")
            }
            if var activity = active[slot] {
                let sum = activity.bytes.addingReportingOverflow(upload)
                guard !sum.overflow else { finish(slot, reason: "byte-overflow"); continue }
                activity.bytes = sum.partialValue; activity.end = end; activity.seconds += seconds
                activity.peak = max(activity.peak, rate); active[slot] = activity
                if activity.qualified { changes[activity.key] = activity }
            } else {
                serial &+= 1
                let activity = Activity(key: "activity-\(serial)", app: app, stableKey: stableKey, segment: segment,
                    kind: kind, start: start, end: end, bytes: upload, peak: rate, seconds: seconds, rule: rule)
                active[slot] = activity
                if activity.qualified { changes[activity.key] = activity }
            }
        }
    }
    private mutating func finish(_ slot: String, reason: String) {
        guard var activity = active.removeValue(forKey: slot), activity.qualified else { return }
        activity.reason = reason; changes[activity.key] = activity
    }
    mutating func finishAll(reason: String) { for slot in Array(active.keys) { finish(slot, reason: reason) } }
    mutating func finishMissing(_ present: Set<String>) {
        for (slot, value) in active where !present.contains(value.stableKey) { finish(slot, reason: "application-not-observed") }
    }
    mutating func drainChanges() -> [Activity] {
        let result = Array(changes.values); changes.removeAll(keepingCapacity: true); return result
    }
    mutating func assign(_ key: String, id: Int64) {
        for slot in active.keys where active[slot]?.key == key { active[slot]?.databaseID = id }
    }
    static func bytes(_ value: UInt64) -> Data {
        var big = value.bigEndian; return withUnsafeBytes(of: &big) { Data($0) }
    }
    static func decodeBytes(_ data: Data) -> UInt64? {
        guard data.count == 8 else { return nil }
        return data.withUnsafeBytes { UInt64(bigEndian: $0.loadUnaligned(as: UInt64.self)) }
    }
}
