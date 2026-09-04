import Foundation
import UsageButlerDomain

/// A metric-level exhaustion observation derived only from a committed
/// provider snapshot. Labels stay source-faithful: the evaluator never
/// fabricates a business label a provider did not report.
public struct QuotaExhaustionFinding: Equatable, Sendable {
    public let providerID: ProviderID
    /// Length-prefixed stable identity, same encoding as the projection
    /// mapper's metric IDs so markers survive mapper refactors.
    public let metricKey: String
    public let productLabel: String
    public let windowLabel: String?
    public let usageSummary: String
    /// Identifies the cycle instance the exhaustion belongs to. A changed
    /// cycle key (reset happened) re-arms the alert.
    public let cycleKey: String
    public let resetAt: Date?

    public init(
        providerID: ProviderID,
        metricKey: String,
        productLabel: String,
        windowLabel: String?,
        usageSummary: String,
        cycleKey: String,
        resetAt: Date?
    ) {
        self.providerID = providerID
        self.metricKey = metricKey
        self.productLabel = productLabel
        self.windowLabel = windowLabel
        self.usageSummary = usageSummary
        self.cycleKey = cycleKey
        self.resetAt = resetAt
    }
}

/// A metric-level quota observation derived only from a committed provider
/// snapshot, carrying the metric's CURRENT state (exhausted or recovered)
/// plus the labels needed to render either alert direction. Labels stay
/// source-faithful: the evaluator never fabricates a business label a
/// provider did not report.
public struct QuotaMetricStatus: Equatable, Sendable {
    public let providerID: ProviderID
    /// Length-prefixed stable identity, same encoding as the projection
    /// mapper's metric IDs so markers survive mapper refactors.
    public let metricKey: String
    public let productLabel: String
    public let windowLabel: String?
    /// Faithful usage summary for the CURRENT state; valid whether the metric
    /// is exhausted or recovered.
    public let usageSummary: String
    /// Identifies the cycle instance the observation belongs to. A changed
    /// cycle key (reset happened) re-arms the alert.
    public let cycleKey: String
    public let resetAt: Date?
    public let isExhausted: Bool

    public init(
        providerID: ProviderID,
        metricKey: String,
        productLabel: String,
        windowLabel: String?,
        usageSummary: String,
        cycleKey: String,
        resetAt: Date?,
        isExhausted: Bool
    ) {
        self.providerID = providerID
        self.metricKey = metricKey
        self.productLabel = productLabel
        self.windowLabel = windowLabel
        self.usageSummary = usageSummary
        self.cycleKey = cycleKey
        self.resetAt = resetAt
        self.isExhausted = isExhausted
    }

    public var exhaustedFinding: QuotaExhaustionFinding {
        QuotaExhaustionFinding(
            providerID: providerID,
            metricKey: metricKey,
            productLabel: productLabel,
            windowLabel: windowLabel,
            usageSummary: usageSummary,
            cycleKey: cycleKey,
            resetAt: resetAt
        )
    }
}

/// Exhaustion semantics: a metric is exhausted when the cycle ran full
/// (used-side percent reaching 100 / used reaching total) or the remaining
/// side reached zero. Neutral, unlimited, absolute, and unavailable values
/// carry no exhaustion contract and never trigger.
public enum QuotaExhaustionEvaluator {
    /// One status per fresh metric, entitlement, and balance. Stale/unknown
    /// nodes and `.unavailable` values provide no evidence of exhaustion or
    /// recovery. Inspect each node, not aggregate freshness: a partial snapshot
    /// can retain stale siblings alongside current, actionable values.
    public static func statuses(in data: ProviderQuotaData) -> [QuotaMetricStatus] {
        var statuses: [QuotaMetricStatus] = []

        for product in data.products {
            for metric in product.metrics {
                guard case .fresh = metric.state.freshness,
                      let state = usageState(for: metric.value) else { continue }
                statuses.append(
                    QuotaMetricStatus(
                        providerID: data.providerID,
                        metricKey: stableMetricKey(for: metric.id.sourceIdentity),
                        productLabel: productLabel(
                            for: product,
                            fallback: metric.sourceLabel
                        ),
                        windowLabel: windowLabel(for: metric),
                        usageSummary: state.summary,
                        cycleKey: cycleKey(for: metric.window),
                        resetAt: metric.window?.timeEvent?.occursAt,
                        isExhausted: state.isExhausted
                    )
                )
            }
        }

        for entitlement in data.resetEntitlements {
            guard case .fresh = entitlement.state.freshness else { continue }
            let expiry = earliestExpiry(of: entitlement.details)
            statuses.append(
                QuotaMetricStatus(
                    providerID: data.providerID,
                    metricKey: stableMetricKey(
                        for: entitlement.provenance.sourceIdentity,
                        prefix: "entitlement"
                    ),
                    productLabel: entitlement.details?.first?.title
                        ?? nonEmpty(entitlement.provenance.sourceIdentity.sourceProductID)
                        ?? "重置权益",
                    windowLabel: nil,
                    usageSummary: "重置权益可用 \(formatted(entitlement.availableCount)) 次",
                    cycleKey: expiry.map { "expiry:\($0.timeIntervalSince1970)" } ?? "unknown",
                    resetAt: expiry,
                    isExhausted: entitlement.availableCount <= 0
                )
            )
        }

        for balance in data.balances {
            guard case .fresh = balance.state.freshness else { continue }
            statuses.append(
                QuotaMetricStatus(
                    providerID: data.providerID,
                    metricKey: stableBalanceKey(
                        providerID: data.providerID,
                        sourceBalanceID: balance.sourceBalanceID
                    ),
                    productLabel: "余额",
                    windowLabel: nil,
                    usageSummary: "余额 \(formatted(balance.amount))\(unitSuffix(balance.unit))",
                    // Balances are not cycle-scoped; recovery above zero
                    // re-arms the marker instead of a reset event.
                    cycleKey: "unknown",
                    resetAt: nil,
                    isExhausted: balance.amount <= 0
                )
            )
        }

        return statuses
    }

    public static func findings(in data: ProviderQuotaData) -> [QuotaExhaustionFinding] {
        statuses(in: data).filter(\.isExhausted).map(\.exhaustedFinding)
    }

    private static func usageState(
        for value: QuotaMetricValue
    ) -> (summary: String, isExhausted: Bool)? {
        switch value {
        case let .percent(percent):
            switch percent.sourceDirection {
            case .used:
                let summary = "已用 \(formatted(percent.sourceValue))%"
                return (summary, percent.sourceValue >= 100)
            case .remaining:
                if percent.sourceValue <= 0 {
                    return ("剩余 0%", true)
                }
                return ("剩余 \(formatted(percent.sourceValue))%", false)
            case .neutral:
                return ("\(formatted(percent.sourceValue))%", false)
            }

        case let .count(count):
            switch count.sourceDirection {
            case .remaining:
                if count.sourceValue <= 0 {
                    return ("剩余 0\(unitSuffix(count.unit))", true)
                }
                return ("剩余 \(formatted(count.sourceValue))\(unitSuffix(count.unit))", false)
            case .used:
                if let total = count.total, total > 0 {
                    let summary = "已用 \(formatted(count.sourceValue))/\(formatted(total))\(unitSuffix(count.unit))"
                    return (summary, count.sourceValue >= total)
                }
                return ("已用 \(formatted(count.sourceValue))\(unitSuffix(count.unit))", false)
            case .neutral:
                return ("\(formatted(count.sourceValue))\(unitSuffix(count.unit))", false)
            }

        case let .usedTotal(amount):
            if amount.total > 0 {
                let summary = "已用 \(formatted(amount.used))/\(formatted(amount.total))\(unitSuffix(amount.unit))"
                return (summary, amount.used >= amount.total)
            }
            return ("已用 \(formatted(amount.used))\(unitSuffix(amount.unit))", false)

        case .unlimited:
            return ("无上限", false)

        case let .absolute(value, unit, direction):
            switch direction {
            case .used:
                return ("已用 \(formatted(value))\(unitSuffix(unit))", false)
            case .remaining:
                return ("剩余 \(formatted(value))\(unitSuffix(unit))", false)
            case .neutral:
                return ("\(formatted(value))\(unitSuffix(unit))", false)
            }

        case .unavailable:
            return nil
        }
    }

    private static func productLabel(
        for product: QuotaProductData,
        fallback: String?
    ) -> String {
        nonEmpty(product.sourceProductID) ?? nonEmpty(fallback) ?? "其他额度"
    }

    private static func windowLabel(for metric: QuotaMetric) -> String? {
        guard let kind = metric.window?.kind else { return nil }
        switch kind {
        case .session: return "当前会话"
        case .shortCycle: return "短周期"
        case .weekly: return "每周"
        case .monthly: return "每月"
        case .providerDefined:
            // No business label was reported; the source label is the only
            // faithful option, and absence stays absence.
            return nonEmpty(metric.sourceLabel)
        }
    }

    static func cycleKey(for window: QuotaWindow?) -> String {
        guard let window else { return "unknown" }
        if let occursAt = window.timeEvent?.occursAt {
            return "reset:\(occursAt.timeIntervalSince1970)"
        }
        if let startsAt = window.startsAt {
            return "start:\(startsAt.timeIntervalSince1970)"
        }
        return "unknown"
    }

    private static func earliestExpiry(
        of details: [ResetEntitlementDetail]?
    ) -> Date? {
        details?.compactMap(\.expiresAt).min()
    }

    static func stableMetricKey(
        for identity: MetricSourceIdentity,
        prefix: String = "metric"
    ) -> String {
        let encoded = [
            identity.providerID.rawValue,
            identity.sourceProductID,
            identity.sourceBucketID ?? "",
            identity.sourceMetricID
        ].map { "\($0.utf8.count):\($0)" }.joined(separator: "|")
        return "\(prefix)|\(encoded)"
    }

    private static func stableBalanceKey(
        providerID: ProviderID,
        sourceBalanceID: String
    ) -> String {
        let encoded = [
            providerID.rawValue,
            sourceBalanceID
        ].map { "\($0.utf8.count):\($0)" }.joined(separator: "|")
        return "balance|\(encoded)"
    }

    private static func formatted(_ value: Decimal) -> String {
        value.description
    }

    private static func unitSuffix(_ unit: String) -> String {
        guard let unit = nonEmpty(unit) else { return "" }
        return " \(unit)"
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }
}
