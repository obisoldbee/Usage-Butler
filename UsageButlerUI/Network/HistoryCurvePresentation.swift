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
        return !point.totals.quality.subtracting(otherDirection.union(.minuteBoundary)).isEmpty
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

    static func leadingUnrecorded(range: HistoryRange, first: Date?) -> HistoryRange? {
        guard let first, first > range.start else { return nil }
        return .init(start: range.start, end: min(first, range.end))
    }

    static func historyNotice(coverage: HistoryCoverage, range: HistoryRange) -> String? {
        guard let first = coverage.firstCollectedAt else { return nil }
        let date = first.formatted(date: .abbreviated, time: .standard)
        if leadingUnrecorded(range: range, first: first) != nil {
            return "采集历史始于 \(date)；所选范围在此之前尚未记录，不代表零流量。"
        }
        return "采集历史始于 \(date)"
    }

    static let diagnosticsScope = "整个采集来源的诊断，未按当前应用或搜索筛选。无法归属计数是重复采样中的记录次数，不是此应用的连接数、流量或不同程序数。"
    static let trafficScope = "包含来源计入的本机回环、代理流量；不能当作外网上传量。未记录历史目的地和接口，不能据此判断传输内容。"
}
