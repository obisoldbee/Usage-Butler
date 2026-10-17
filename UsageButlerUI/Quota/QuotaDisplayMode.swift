import Foundation
import UsageButlerCore

/// A local presentation preference. It never changes the source projection.
public enum QuotaDisplayMode: String, CaseIterable, Identifiable, Sendable {
    case source
    case used
    case remaining

    public static let preferenceKey = "usageButler.settings.v1.quotaDisplayMode"

    public var id: String { rawValue }

    public static func validated(storedValue: String) -> Self {
        Self(rawValue: storedValue) ?? .source
    }

    public var title: String {
        switch self {
        case .source: String(localized: "跟随来源")
        case .used: String(localized: "统一已用")
        case .remaining: String(localized: "统一剩余")
        }
    }
}

/// The text, bar and accessibility value share one conversion. Availability
/// colors deliberately continue to use `metric.value`, never this result.
struct QuotaMetricPresentation {
    let valueText: String
    let progressFraction: Double?
    let detailText: String?

    init(metric: Stage3QuotaMetricProjection, mode: QuotaDisplayMode) {
        guard case let .percent(raw, sourceDirection) = metric.value else {
            valueText = metric.displayValueText ?? Self.nonPercentText(metric.value)
            progressFraction = nil
            detailText = metric.detailText
            return
        }
        guard raw.isFinite, (0...100).contains(raw) else {
            valueText = String(localized: "额度数值无效")
            progressFraction = nil
            detailText = metric.detailText
            return
        }

        let direction: Stage3QuotaDirection
        switch mode {
        case .source: direction = sourceDirection
        case .used: direction = .used
        case .remaining: direction = .remaining
        }
        let value = direction == sourceDirection ? raw : 100 - raw
        progressFraction = value / 100
        if mode == .source {
            valueText = metric.displayValueText ?? Self.percentText(raw, direction: direction)
        } else {
            // Convert the unrounded source first, then floor in either direction.
            // Positive values below one percent remain visible as 1%.
            let displayed = value > 0 && value < 1 ? 1 : value.rounded(.down)
            valueText = Self.percentText(displayed, direction: direction)
        }
        let source = String(localized: "来源读数") + " "
            + Self.directionText(sourceDirection) + " " + Self.preciseText(raw) + "%"
        detailText = ([source] + [metric.detailText].compactMap { $0 }).joined(separator: "\n")
    }

    private static func directionText(_ direction: Stage3QuotaDirection) -> String {
        direction == .remaining ? String(localized: "剩余") : String(localized: "已用")
    }

    private static func percentText(_ value: Double, direction: Stage3QuotaDirection) -> String {
        let number = value.rounded() == value
            ? String(Int(value)) : String(format: "%.2f", value)
        return directionText(direction) + " " + number + "%"
    }

    private static func preciseText(_ value: Double) -> String {
        value.rounded() == value ? String(Int(value)) : String(value)
    }

    private static func nonPercentText(_ value: Stage3QuotaValue) -> String {
        switch value {
        case .percent: String(localized: "额度数值无效")
        case .unlimited: String(localized: "∞ 无限制")
        case let .usedCount(used, total, unit): String(localized: "已用 \(used) / \(total) \(unit)")
        case let .entitlement(availableCount): String(localized: "可用 \(availableCount) 次")
        case let .balance(amount, unlimited):
            unlimited ? String(localized: "∞ 无限制")
                : amount.map { String(localized: "余额") + " " + NSDecimalNumber(decimal: $0).stringValue }
                    ?? String(localized: "余额未提供")
        case .unavailable: String(localized: "— 暂时无法读取")
        }
    }
}
