import Foundation

public enum GrokBotMeteringSystem: String, Codable, Equatable, Sendable {
    case legacyCursor, xShared, unknown
}

/// Safe source fields only. Fetch time belongs to provenance; these are server events.
public struct GrokBotUsageObservation: Codable, Equatable, Sendable {
    public let meteringSystem: GrokBotMeteringSystem
    public let usagePercent: Decimal?
    public let hasAvailableUsage: Bool?
    public let hasNonZeroIncludedLimit: Bool?
    public let includedLimitZero: Bool?
    public let currentPeriodStart: Date?
    public let nextResetAt: Date?
    public let trialExpiresAt: Date?
    public let shared: GrokSharedUsageObservation?

    public init(meteringSystem: GrokBotMeteringSystem = .unknown, usagePercent: Decimal?,
                hasAvailableUsage: Bool?, hasNonZeroIncludedLimit: Bool?, includedLimitZero: Bool?,
                currentPeriodStart: Date?, nextResetAt: Date?, trialExpiresAt: Date?, shared: GrokSharedUsageObservation? = nil) {
        self.meteringSystem = meteringSystem; self.usagePercent = usagePercent
        self.hasAvailableUsage = hasAvailableUsage; self.hasNonZeroIncludedLimit = hasNonZeroIncludedLimit
        self.includedLimitZero = includedLimitZero; self.currentPeriodStart = currentPeriodStart
        self.nextResetAt = nextResetAt; self.trialExpiresAt = trialExpiresAt
        self.shared = shared
    }
    public var hasIncludedLimit: Bool? { includedLimitZero.map { !$0 } ?? hasNonZeroIncludedLimit }
}
