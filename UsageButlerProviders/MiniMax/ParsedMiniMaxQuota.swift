import Foundation

public enum ParsedMiniMaxReadCompleteness: Equatable, Sendable {
    case completeSuccess
    case partial
    case failed
}

public struct ParsedMiniMaxParsingContext: Equatable, Sendable {
    public let completeness: ParsedMiniMaxReadCompleteness
    public let sourceVersion: String
    public let region: String
    public let catalogID: String
    public let contractVersion: String
    public let fetchedAt: Date

    public init(
        completeness: ParsedMiniMaxReadCompleteness,
        sourceVersion: String,
        region: String,
        catalogID: String,
        contractVersion: String,
        fetchedAt: Date
    ) {
        self.completeness = completeness
        self.sourceVersion = sourceVersion
        self.region = region
        self.catalogID = catalogID
        self.contractVersion = contractVersion
        self.fetchedAt = fetchedAt
    }
}

/// A lossless representation of one MiniMax quota window's known contract fields.
/// Percent and count directions remain exactly as supplied by `mmx quota show`.
public struct ParsedMiniMaxQuotaWindow: Equatable, Sendable {
    public let startTimeMilliseconds: Int64
    public let endTimeMilliseconds: Int64
    public let remainsTimeMilliseconds: Int64
    public let totalCount: Decimal
    public let usageCount: Decimal
    public let remainingPercent: Decimal
    public let status: Int

    public init(
        startTimeMilliseconds: Int64,
        endTimeMilliseconds: Int64,
        remainsTimeMilliseconds: Int64,
        totalCount: Decimal,
        usageCount: Decimal,
        remainingPercent: Decimal,
        status: Int
    ) {
        self.startTimeMilliseconds = startTimeMilliseconds
        self.endTimeMilliseconds = endTimeMilliseconds
        self.remainsTimeMilliseconds = remainsTimeMilliseconds
        self.totalCount = totalCount
        self.usageCount = usageCount
        self.remainingPercent = remainingPercent
        self.status = status
    }
}

public struct ParsedMiniMaxModelQuota: Equatable, Sendable {
    public let modelName: String
    public let current: ParsedMiniMaxQuotaWindow
    public let weekly: ParsedMiniMaxQuotaWindow
    public let weeklyBoostPermille: Decimal?

    public init(
        modelName: String,
        current: ParsedMiniMaxQuotaWindow,
        weekly: ParsedMiniMaxQuotaWindow,
        weeklyBoostPermille: Decimal?
    ) {
        self.modelName = modelName
        self.current = current
        self.weekly = weekly
        self.weeklyBoostPermille = weeklyBoostPermille
    }

    func contractIssue(for window: ParsedMiniMaxQuotaWindow, isWeekly: Bool) -> MiniMaxQuotaContractIssue? {
        guard modelName == "general" || modelName == "video" else {
            return .unsupportedSemantics("minimax.model")
        }
        // Unlimited is an explicit capability, not a finite count/percent tuple.
        if window.status == 3 { return nil }
        guard window.status == 1 else {
            return .unsupportedSemantics("minimax.window.status")
        }
        if isWeekly, let boost = weeklyBoostPermille,
           !NSDecimalNumber(decimal: boost).doubleValue.isFinite || boost < 0 {
            return .invalidSourceValue("weekly_boost_permille")
        }
        guard NSDecimalNumber(decimal: window.remainingPercent).doubleValue.isFinite,
              window.remainingPercent >= 0 else {
            return .invalidSourceValue("remaining_percent")
        }
        if window.remainingPercent > 100 {
            if isWeekly, let boost = weeklyBoostPermille, boost > 0 {
                // Raw boost is preserved, but Domain/UI cannot yet express its
                // provenance and presentation. Do not invent a boosted success.
                return .unsupportedSemantics("minimax.weekly.boost")
            }
            return .invalidSourceValue("remaining_percent")
        }
        guard NSDecimalNumber(decimal: window.usageCount).doubleValue.isFinite,
              NSDecimalNumber(decimal: window.totalCount).doubleValue.isFinite,
              window.usageCount >= 0, window.totalCount >= 0,
              window.usageCount <= window.totalCount else {
            return .invalidSourceValue("usage_count")
        }
        return nil
    }
}

enum MiniMaxQuotaContractIssue: Equatable, Sendable {
    case invalidSourceValue(String)
    case unsupportedSemantics(String)
}

public struct ParsedMiniMaxQuotaSnapshot: Equatable, Sendable {
    public let baseStatusCode: Int
    public let models: [ParsedMiniMaxModelQuota]
    public let droppedRowCount: Int
    public let duplicateRowCount: Int
    public let context: ParsedMiniMaxParsingContext

    public init(
        baseStatusCode: Int,
        models: [ParsedMiniMaxModelQuota],
        droppedRowCount: Int,
        duplicateRowCount: Int,
        context: ParsedMiniMaxParsingContext
    ) {
        self.baseStatusCode = baseStatusCode
        self.models = models
        self.droppedRowCount = droppedRowCount
        self.duplicateRowCount = duplicateRowCount
        self.context = context
    }

    public var effectiveCompleteness: ParsedMiniMaxReadCompleteness {
        guard context.completeness == .completeSuccess else {
            return context.completeness
        }
        return droppedRowCount == 0 && duplicateRowCount == 0
            && models.allSatisfy {
                $0.contractIssue(for: $0.current, isWeekly: false) == nil
                    && $0.contractIssue(for: $0.weekly, isWeekly: true) == nil
            } ? .completeSuccess : .partial
    }

    public func uniqueModel(named modelName: String) -> ParsedMiniMaxModelQuota? {
        let matches = models.filter { $0.modelName == modelName }
        return matches.count == 1 ? matches[0] : nil
    }
}
