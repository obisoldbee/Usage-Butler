import Foundation
import UsageButlerCore

extension ParsedMiniMaxModelQuota {
    /// Sufficient numeric evidence to replay the existing window contract offline.
    var diagnosticValues: [String: Double] {
        var values: [String: Double] = [
            "start_time": Double(current.startTimeMilliseconds), "end_time": Double(current.endTimeMilliseconds),
            "remains_time": Double(current.remainsTimeMilliseconds),
            "current_interval_status": Double(current.status),
            "current_interval_remaining_percent": NSDecimalNumber(decimal: current.remainingPercent).doubleValue,
            "current_interval_total_count": NSDecimalNumber(decimal: current.totalCount).doubleValue,
            "current_interval_usage_count": NSDecimalNumber(decimal: current.usageCount).doubleValue,
            "weekly_start_time": Double(weekly.startTimeMilliseconds), "weekly_end_time": Double(weekly.endTimeMilliseconds),
            "weekly_remains_time": Double(weekly.remainsTimeMilliseconds),
            "current_weekly_status": Double(weekly.status),
            "current_weekly_remaining_percent": NSDecimalNumber(decimal: weekly.remainingPercent).doubleValue,
            "current_weekly_total_count": NSDecimalNumber(decimal: weekly.totalCount).doubleValue,
            "current_weekly_usage_count": NSDecimalNumber(decimal: weekly.usageCount).doubleValue
        ]
        if let boost = weeklyBoostPermille { values["weekly_boost_permille"] = NSDecimalNumber(decimal: boost).doubleValue }
        return values
    }
}
