import Foundation

/// Normalized source fields only; no account identifier or server response text.
public struct GrokSharedUsageObservation: Codable, Equatable, Sendable {
    public enum Availability: String, Codable, Sendable { case available, identityUnlinked, missingTeamID, unknown }
    public enum WeeklyStatus: String, Codable, Sendable { case metered, notApplicable, unavailable, unknown }
    public enum WeeklyValueState: Equatable, Sendable { case available, notReported, zeroBudget, invalid, overBudget, unavailable }
    public enum MonthlyLimit: Codable, Equatable, Sendable { case notReported, unset, amount(Decimal) }

    public let availability: Availability
    public let weeklyStatus: WeeklyStatus
    public let usedCents: Decimal?
    public let budgetCents: Decimal?
    /// Meaning is unverified. Never a reset entitlement or a remaining count.
    public let resetCounter: Decimal?
    public let periodStart: Date?
    public let resetsAt: Date?
    public let monthlyUsedCents: Decimal?
    public let monthlyLimit: MonthlyLimit
    public let monthlyCreditsUsedCents: Decimal?
    public let monthlyPeriodStart: Date?
    public let monthlyResetsAt: Date?

    public init(availability: Availability, weeklyStatus: WeeklyStatus, usedCents: Decimal?, budgetCents: Decimal?,
                resetCounter: Decimal?, periodStart: Date?, resetsAt: Date?, monthlyUsedCents: Decimal?,
                monthlyLimit: MonthlyLimit, monthlyCreditsUsedCents: Decimal?, monthlyPeriodStart: Date?, monthlyResetsAt: Date?) {
        self.availability = availability; self.weeklyStatus = weeklyStatus
        self.usedCents = usedCents; self.budgetCents = budgetCents; self.resetCounter = resetCounter
        self.periodStart = periodStart; self.resetsAt = resetsAt
        self.monthlyUsedCents = monthlyUsedCents; self.monthlyLimit = monthlyLimit
        self.monthlyCreditsUsedCents = monthlyCreditsUsedCents
        self.monthlyPeriodStart = monthlyPeriodStart; self.monthlyResetsAt = monthlyResetsAt
    }

    public var weeklyValueState: WeeklyValueState {
        guard availability == .available, weeklyStatus == .metered else { return .unavailable }
        guard let usedCents, let budgetCents else { return .notReported }
        guard Self.nonnegative(usedCents), Self.nonnegative(budgetCents) else { return .invalid }
        guard budgetCents > 0 else { return .zeroBudget }
        guard let percent = usagePercent, !percent.isNaN else { return .invalid }
        return usedCents > budgetCents ? .overBudget : .available
    }
    /// Full Decimal precision, including observed overage. Display geometry is separate.
    public var usagePercent: Decimal? {
        guard availability == .available, weeklyStatus == .metered,
              let usedCents, let budgetCents, Self.nonnegative(usedCents), Self.nonnegative(budgetCents), budgetCents > 0 else { return nil }
        let result = usedCents / budgetCents * 100
        return result.isNaN ? nil : result
    }
    public var remainingCents: Decimal? {
        guard weeklyValueState == .available, let budgetCents, let usedCents else { return nil }
        return budgetCents - usedCents
    }
    public var remainingPercent: Decimal? {
        guard weeklyValueState == .available, let usagePercent else { return nil }
        return 100 - usagePercent
    }
    /// Official UsageMeter: floor, with a minimum display of 1 for 0 < usage < 1.
    public var officialDisplayPercent: Int? {
        guard weeklyValueState == .available, var percent = usagePercent else { return nil }
        if percent > 0 && percent < 1 { return 1 }
        var rounded = Decimal()
        NSDecimalRound(&rounded, &percent, 0, .down)
        return NSDecimalNumber(decimal: rounded).intValue
    }
    public static func nonnegative(_ amount: Decimal) -> Bool { !amount.isNaN && amount >= 0 }
}
