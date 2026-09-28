import Foundation
import UsageButlerCore
import UsageButlerDomain

enum HistoryChartDirection: Hashable { case upload, download }

/// Shared by the real chart gestures and keyboard commands. Coordinates are
/// plot-local, not window-local, and never inherit a previous hover position.
struct HistoryCurveInteraction: Equatable {
    private(set) var inspected: Date?
    private(set) var pinned = false
    var focused: HistoryChartDirection?

    static func time(at location: CGPoint, plot: CGRect, range: HistoryRange) -> Date? {
        guard plot.width > 0, plot.height > 0, location.x.isFinite, location.y.isFinite,
              location.x >= plot.minX, location.x < plot.maxX,
              location.y >= plot.minY, location.y <= plot.maxY else { return nil }
        let coordinates = NetworkChartCoordinates(now: range.end,
            window: range.end.timeIntervalSince(range.start), upperBound: 1)
        return coordinates.date(atX: (location.x - plot.minX) / plot.width)
    }

    mutating func tap(at location: CGPoint, plot: CGRect, range: HistoryRange, direction: HistoryChartDirection) {
        guard let time = Self.time(at: location, plot: plot, range: range) else { reset(); return }
        inspected = time; pinned = true; focused = direction
    }

    mutating func hover(at location: CGPoint?, plot: CGRect, range: HistoryRange) {
        guard !pinned else { return }
        inspected = location.flatMap { Self.time(at: $0, plot: plot, range: range) }
    }

    mutating func step(_ offset: Int, buckets: [HistoryCurveBucket]) {
        guard focused != nil, !buckets.isEmpty, offset == -1 || offset == 1 else { return }
        let index: Int
        if let date = inspected {
            if let current = buckets.firstIndex(where: { date >= $0.start && date < $0.end }) {
                index = min(buckets.count - 1, max(0, current + offset))
            } else if offset > 0 {
                index = buckets.firstIndex(where: { $0.start > date }) ?? buckets.count - 1
            } else {
                index = buckets.lastIndex(where: { $0.end <= date }) ?? 0
            }
        } else { index = offset > 0 ? 0 : buckets.count - 1 }
        inspected = buckets[index].start; pinned = true
    }

    mutating func reset() { inspected = nil; pinned = false; focused = nil }
}

enum HistoryCurvePresentation {
    static func observedBytes(_ totals: HistoryTotals, upload: Bool) -> UInt64? {
        guard (upload ? totals.uploadObservedMicroseconds : totals.downloadObservedMicroseconds) > 0 else { return nil }
        return upload ? totals.upload : totals.download
    }

    static func bucket(at time: Date?, in buckets: [HistoryCurveBucket]) -> HistoryCurveBucket? {
        guard let time else { return nil }
        return buckets.first { time >= $0.start && time < $0.end }
    }

    static func average(_ point: HistoryCurveBucket, upload: Bool) -> Double? {
        let bytes = upload ? point.totals.upload : point.totals.download
        let seconds = observedSeconds(point, upload: upload)
        guard let bytes, seconds > 0 else { return nil }
        return Double(bytes) / seconds
    }

    static func observedSeconds(_ point: HistoryCurveBucket, upload: Bool) -> Double {
        Double(upload ? point.totals.uploadObservedMicroseconds : point.totals.downloadObservedMicroseconds) / 1e6
    }

    static func peak(_ totals: HistoryTotals, upload: Bool) -> Double? {
        guard (upload ? totals.uploadSamples : totals.downloadSamples) > 0 else { return nil }
        return upload ? totals.peakUpload : totals.peakDownload
    }

    static func isPartial(_ point: HistoryCurveBucket, upload: Bool) -> Bool {
        let otherDirection: HistoryQuality = upload ? [.downloadGap, .downloadOverflow] : [.uploadGap, .uploadOverflow]
        // Retention age and whole-frame minute assignment say nothing about
        // missing samples in this direction. Keep the original quality bits.
        return !point.totals.quality.subtracting(otherDirection.union([.minuteBoundary, .conservativeAge])).isEmpty
            || observedSeconds(point, upload: upload) + 0.000001 < point.end.timeIntervalSince(point.start)
    }

    static func observation(_ point: HistoryCurveBucket, upload: Bool) -> String {
        guard let rate = average(point, upload: upload) else { return "无可用记录" }
        let status = isPartial(point, upload: upload) ? "部分记录" : "已记录"
        return rate == 0 ? "已观察为零 · " + status : status
    }

    static func span(_ point: HistoryCurveBucket) -> String {
        let seconds = point.end.timeIntervalSince(point.start)
        if seconds.truncatingRemainder(dividingBy: 60) == 0 { return "\(Int(seconds / 60)) 分钟" }
        return "\(seconds.formatted(.number.precision(.fractionLength(0...1)))) 秒"
    }

    static func granularity(_ buckets: [HistoryCurveBucket]) -> String {
        let spans = Set(buckets.map { $0.end.timeIntervalSince($0.start) }).sorted()
        guard !spans.isEmpty else { return "暂无可用时段" }
        return "每柱代表：" + spans.map { "\(Int($0 / 60)) 分钟" }.joined(separator: " / ") + "；选择后查看实际时段起止。"
    }

    static func historyNotice(coverage: HistoryCoverage, range: HistoryRange) -> String? {
        guard let first = coverage.firstCollectedAt else { return nil }
        let date = first.formatted(date: .abbreviated, time: .standard)
        let notice = "首次开始记录时的系统时间：\(date)"
        // The first frame's wall time is not an absence boundary: valid records
        // may precede it after a clock change, or just by minute bucketing.
        if range.start < first {
            return notice + "；更早时段以已保存的记录为准。"
        }
        return notice
    }

    static func emptyText(_ result: HistoryQueryResult) -> String {
        if result.totalApplications > 0 { return "本页已无更多应用；范围内共有 \(result.totalApplications) 个应用，可继续查看下方活动或返回上一页。" }
        if result.contract?.scope.search.isEmpty == false { return "没有符合搜索的应用，可清除搜索后查看此范围的历史。" }
        if result.coverage.retentionTrimmed, let oldest = result.coverage.oldestRetainedAt, result.range.end <= oldest { return "此范围的记录已超出保留期限。" }
        if result.coverage.unattributedSamples > 0 { return "此范围有源采样，但没有可归属应用的历史。" }
        return "此范围没有已保存的应用观察；未知时段不能当作零流量。"
    }

    static let diagnosticsScope = "整个采集来源的诊断，未按当前应用或搜索筛选。无法归属计数是重复采样中的记录次数，不是此应用的连接数、流量或不同程序数。"
    static let trafficScope = "包含来源计入的本机回环、代理流量；不能当作外网上传量。未记录历史目的地和接口，不能据此判断传输内容。"
}
