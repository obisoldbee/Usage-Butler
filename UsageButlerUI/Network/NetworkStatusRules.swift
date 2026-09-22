import Foundation
import UsageButlerDomain

/// Display rules that decide how trustworthy the numbers on the network page
/// are. Extracted from the view model so the clock is an argument: a snapshot
/// either earns the green light or it does not, and that must be assertable
/// without waiting for time to pass.
public enum NetworkStatusRules {
    /// How long a retained reading may still be presented as live.
    public static let freshnessHorizon: TimeInterval = 12

    /// Green means the data is good, not merely that collection is switched
    /// on: degraded coverage or a missing live sample has to cost it, or green
    /// teaches the user that green only means "the app is open".
    public static func isHealthy(_ snapshot: NetworkSnapshot?) -> Bool {
        guard let snapshot else { return false }
        guard snapshot.collectionState == .active else { return false }
        guard case .full = snapshot.coverage.bytes else { return false }
        return snapshot.coverage.hasLiveSample
    }

    /// A rate is current only while the collector is delivering it and the
    /// newest reading is inside the horizon. Anything else is last-good
    /// evidence and must be labelled as such.
    public static func ratesAreStale(
        _ snapshot: NetworkSnapshot?,
        now: Date,
        horizon: TimeInterval = freshnessHorizon
    ) -> Bool {
        guard let snapshot else { return true }
        switch snapshot.collectionState {
        case .active, .partial:
            break
        default:
            return true
        }
        guard let newest = snapshot.interfaces.values.map(\.asOf).max(by: { $0 < $1 }) else {
            return true
        }
        return now.timeIntervalSince(newest) > horizon
    }

    public static func ratesAreStale(_ snapshot: NetworkSnapshot?, interface: String?, now: Date) -> Bool {
        guard let snapshot, let interface, let source = snapshot.interfaces[interface],
              let rate = snapshot.interfaceRates[interface] else { return true }
        switch snapshot.collectionState { case .active, .partial: break; default: return true }
        let age = now.timeIntervalSince(source.asOf)
        let rateAge = now.timeIntervalSince(rate.asOf)
        return age < -1 || age > freshnessHorizon || rateAge < -1 || rateAge > freshnessHorizon
    }

    public static func currentHealth(_ snapshot: NetworkSnapshot?, interface: String?, now: Date) -> (title: String, healthy: Bool) {
        guard let snapshot else { return ("尚未获取网络快照", false) }
        switch snapshot.collectionState {
        case .stopped: return ("未采集", false)
        case .starting: return ("正在启动采集", false)
        case .waitingAuthorization: return ("等待系统授权", false)
        case .denied: return ("系统权限被拒绝", false)
        case .disconnected: return ("采集已断开", false)
        case .active, .partial: break
        }
        guard !ratesAreStale(snapshot, interface: interface, now: now), let interface,
              let rate = snapshot.interfaceRates[interface] else { return ("当前接口暂无新鲜速率", false) }
        guard rate.uploadBytesPerSecond != nil, rate.downloadBytesPerSecond != nil else { return ("采集中 · 当前方向部分可用", false) }
        return ("采集中", true)
    }

    /// Why the reading is not fully trustworthy, or nil when there is nothing
    /// to disclose. Built from coverage so the page cannot drift away from what
    /// the collector actually reported.
    public static func coverageNotice(_ snapshot: NetworkSnapshot?) -> String? {
        guard let coverage = snapshot?.coverage else { return nil }
        var parts: [String] = []
        switch coverage.bytes {
        case .full:
            break
        case let .partial(reason):
            switch reason {
            case "counter-reset": parts.append(String(localized: "接口计数器发生重置，历史已不完整"))
            case "out-of-order-events": parts.append(String(localized: "存在乱序到达的采样，部分字节未结算"))
            case "lost-events": parts.append(String(localized: "有采样丢失，累计可能偏小"))
            default: parts.append(String(localized: "字节覆盖不完整（\(reason)）"))
            }
        case let .unavailable(reason):
            parts.append(String(localized: "字节数据不可用（\(reason)）"))
        }
        if coverage.counterResetCount > 0 {
            parts.append(String(localized: "计数器重置 \(coverage.counterResetCount) 次"))
        }
        if coverage.lostEventCount > 0 {
            parts.append(String(localized: "丢失事件 \(coverage.lostEventCount) 个"))
        }
        if !coverage.truncatedCollections.isEmpty {
            parts.append(String(localized: "已截断：\(coverage.truncatedCollections.sorted().joined(separator: "、"))"))
        }
        return parts.isEmpty ? nil : parts.joined(separator: "；")
    }

    /// Why a session total restarted mid-span. Phrased to attach to a "自 时点"
    /// label, so it stays a clause rather than a sentence.
    public static func sessionTotalReasonText(_ reason: String?) -> String {
        switch reason {
        case "interface-missing": String(localized: "接口重新出现后重新起算")
        case "interface-identity-changed": String(localized: "系统接口身份变化后重新起算")
        case "enumeration-failed": String(localized: "接口读取失败后重新起算")
        case "capture-restarted": String(localized: "重新启用采集后重新起算")
        case "counter-reset": String(localized: "计数器重置后重新起算，之前的字节无法归因")
        case "sampling-gap": String(localized: "采样中断后重新起算")
        case "missing-counter": String(localized: "缺失计数恢复后重新起算")
        case "epoch-changed": String(localized: "计数周期变化后重新起算")
        case "counter-overflow": String(localized: "累计超出可表示范围后重新起算")
        case "legacy-unverified": String(localized: "旧记录的累计起点未验证")
        case nil: String(localized: "连续")
        case let reason?: String(localized: "因 \(reason) 重新起算")
        }
    }

    /// The segment keeps its historical reason for diagnostics, but an old
    /// restart is not an error in a newer viewing window. Startup's empty
    /// leading edge is expected; require an earlier observed rate in-range.
    public static func historyRestartNotice(
        _ total: SessionByteTotal?, samples: [NetworkRateSample], now: Date, window: TimeInterval
    ) -> String? {
        guard let total, window.isFinite, window > 0 else { return nil }
        let cutoff = now.addingTimeInterval(-window)
        func restarted(_ segment: DirectionByteTotal, rate: KeyPath<NetworkRateSample, Double?>) -> Bool {
            guard let reason = segment.breakReason, reason != "legacy-unverified",
                  let since = segment.since, since > cutoff, since <= now else { return false }
            return samples.contains { sample in
                sample.sampledAt > cutoff && sample.sampledAt < since && sample[keyPath: rate] != nil
            }
        }
        switch (restarted(total.upload, rate: \.uploadBytesPerSecond),
                restarted(total.download, rate: \.downloadBytesPerSecond)) {
        case (true, true): return String(localized: "所选范围内上传、下载统计曾重新起算 · 详见网络设置")
        case (true, false): return String(localized: "所选范围内上传统计曾重新起算 · 详见网络设置")
        case (false, true): return String(localized: "所选范围内下载统计曾重新起算 · 详见网络设置")
        case (false, false): return nil
        }
    }

    /// PRD §13.2 requires this disclosure on the network page: observing bytes
    /// is not the same product promise as blocking them, and a page that only
    /// shows traffic numbers invites the opposite reading.
    public static let monitoringOnlyNotice = String(
        localized: "仅监控 / 防护未开启"
    )
}
