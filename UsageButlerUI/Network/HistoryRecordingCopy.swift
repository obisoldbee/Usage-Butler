import UsageButlerDomain

/// Translate only evidence present in a record. Routine first samples and
/// minute boundaries do not imply data loss or warrant a warning on every row.
enum HistoryRecordingCopy {
    static func notices(_ quality: HistoryQuality) -> [String] {
        var lines: [String] = []
        if quality.contains(.uploadGap) { lines.append("部分时段没有上传读数") }
        if quality.contains(.downloadGap) { lines.append("部分时段没有下载读数") }
        if quality.contains(.sourcePartial) { lines.append("部分采样未完整读取") }
        if quality.contains(.sequenceGap) { lines.append("采样中间有缺口") }
        if quality.contains(.clockChanged) { lines.append("系统时间发生变化") }
        if quality.contains(.membersChanged) { lines.append("应用的进程发生变化") }
        if quality.contains(.counterReset) { lines.append("部分计数无法读取或已重新开始") }
        if quality.contains(.capacity) { lines.append("记录达到数量上限，部分数据未保留") }
        if quality.contains(.uploadOverflow) { lines.append("上传量超出计数范围，无法显示总量") }
        if quality.contains(.downloadOverflow) { lines.append("下载量超出计数范围，无法显示总量") }
        return lines
    }
    static func endReason(_ code: String) -> String {
        switch code {
        case "observed-zero": "上传量为零"
        case "unobserved-interval": "此时段没有可用读数"
        case "below-threshold": "低于记录阈值"
        case "sampling-gap": "采样间隔中断"
        case "application-not-observed": "最近采样未发现此应用"
        case "wall-clock-changed": "系统时间发生变化"
        case "utc-day-boundary": "跨过UTC日期边界"
        case "source-session-changed": "采集会话重新开始"
        case "rule-changed": "筛选阈值发生变化"
        case "collection-stopped": "采集已停止"
        case "retention-boundary": "记录达到保存期限"
        case "byte-overflow": "上传量超出计数范围"
        default: "原因暂未确认"
        }
    }
    static func exportFailure(_ error: Error) -> String {
        if case BackgroundNetworkWire.Failure.responseTooLarge = error {
            return "导出数据过多，请缩小时间范围或从应用详情导出。"
        }
        return "暂时无法生成导出，请重试。"
    }
}
