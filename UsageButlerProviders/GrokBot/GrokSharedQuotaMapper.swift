import Foundation
import UsageButlerDomain

/// Verified 2026-10-16 with the same native Cursor session as /api/auth/me.
/// The Cursor-origin endpoint avoids forwarding Cursor credentials to Grok.
public enum GrokSharedQuotaMapper {
    public static let contractEvidence = "official-cursor-native-usage-status-20261016-v1"
    public static let contractVersion = "cursor-shared-weekly-v1"
    public static func source(sessionScope: String? = nil) -> ProviderSourceIdentity {
        .init(providerID: .grokBot, adapterID: "cursor-grok-shared", executableIdentity: "", cliVersion: "",
              schemaVersion: "cursor-shared-usage-status-2", contractVersion: contractVersion,
              transport: .https(origin: "https://cursor.com", adapterVersion: "1", contractEvidence: contractEvidence), sessionScope: sessionScope)
    }
    public static func map(_ bytes: Data, fetchedAt: Date, sessionScope: String) throws -> ProviderQuotaData {
        let dto: Response
        do { dto = try JSONDecoder().decode(Response.self, from: bytes) } catch { throw GrokBotReadError.schema }
        guard dto.availability != nil || dto.weeklyIncludedStatus != nil || dto.weeklyIncludedUsage != nil || dto.monthlyUsage != nil else { throw GrokBotReadError.schema }
        let availability: GrokSharedUsageObservation.Availability
        switch dto.availability {
        case "available": availability = .available
        case "identity_unlinked": availability = .identityUnlinked
        case "missing_team_id": availability = .missingTeamID
        default: availability = .unknown
        }
        let status: GrokSharedUsageObservation.WeeklyStatus
        switch dto.weeklyIncludedStatus?.status {
        case "metered": status = .metered
        case "not_applicable": status = .notApplicable
        case "unavailable": status = .unavailable
        default: status = .unknown
        }
        let week = dto.weeklyIncludedUsage, month = dto.monthlyUsage
        let shared = GrokSharedUsageObservation(availability: availability, weeklyStatus: status,
            usedCents: week?.usedCents, budgetCents: week?.budgetCents, resetCounter: week?.resetCounter,
            periodStart: try date(week?.periodStart), resetsAt: try date(week?.resetsAt), monthlyUsedCents: month?.usedCents,
            monthlyLimit: month?.limit ?? .notReported, monthlyCreditsUsedCents: month?.creditsUsedCents,
            monthlyPeriodStart: try date(month?.periodStart), monthlyResetsAt: try date(month?.resetsAt))
        return map(shared, fetchedAt: fetchedAt, sessionScope: sessionScope)
    }
    /// Also accepts an already normalized, identity-free capture for offline UI verification.
    public static func map(_ shared: GrokSharedUsageObservation, fetchedAt: Date, sessionScope: String) -> ProviderQuotaData {
        let observation = GrokBotUsageObservation(meteringSystem: .xShared, usagePercent: shared.usagePercent,
            hasAvailableUsage: nil, hasNonZeroIncludedLimit: nil, includedLimitZero: nil,
            currentPeriodStart: shared.periodStart, nextResetAt: shared.resetsAt, trialExpiresAt: nil, shared: shared)
        let source = source(sessionScope: sessionScope), node = QuotaNodeState.authoritativeData(asOf: fetchedAt)
        let identity = MetricSourceIdentity(providerID: .grokBot, sourceProductID: "x-shared", sourceBucketID: "weekly", sourceMetricID: "weeklyIncludedUsage")
        let value: QuotaMetricValue
        switch shared.weeklyValueState {
        case .available:
            value = .usedTotal(.init(used: shared.usedCents!, total: shared.budgetCents!, unit: "source-cents",
                                     sourcePercent: .init(sourceValue: shared.usagePercent!, sourceDirection: .used)))
        case .notReported: value = .unavailable(reason: .notReported)
        case .zeroBudget: value = .unavailable(reason: .invalidSourceValue(field: "weeklyIncludedUsage.budgetCents.zero"))
        case .invalid: value = .unavailable(reason: .invalidSourceValue(field: "weeklyIncludedUsage"))
        case .overBudget: value = .unavailable(reason: .invalidSourceValue(field: "weeklyIncludedUsage.overBudget"))
        case .unavailable: value = .unavailable(reason: .unsupportedSemantics(sourceKind: "shared-weekly-unavailable"))
        }
        let metric = QuotaMetric(id: .init(sourceIdentity: identity), sourceMetricID: identity.sourceMetricID, sourceLabel: "Grok / Cursor",
            window: .init(kind: .weekly, duration: nil, startsAt: shared.periodStart, endsAt: shared.resetsAt,
                timeEvent: shared.resetsAt.map { .init(kind: .reset, occursAt: $0) }), value: value, sourceStatus: nil,
            provenance: .init(sourceIdentity: identity, providerSource: source, fetchedAt: fetchedAt), state: node)
        return .init(providerID: .grokBot, source: source, fetchedAt: fetchedAt, grokBotUsage: observation,
            products: [.init(id: .init(providerID: .grokBot, sourceProductID: "x-shared"), sourceProductID: "x-shared",
                titleKey: "product.grok-shared", canonicalOrder: 0, planLevel: nil, state: node, metrics: [metric])], balances: [], resetEntitlements: [])
    }
    private static func date(_ value: String?) throws -> Date? {
        guard let value else { return nil }
        let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let result = formatter.date(from: value) { return result }
        formatter.formatOptions = [.withInternetDateTime]
        guard let result = formatter.date(from: value) else { throw GrokBotReadError.schema }
        return result
    }
    private struct Response: Decodable {
        let availability: String?
        let weeklyIncludedStatus: Status?
        let weeklyIncludedUsage: Week?
        let monthlyUsage: Month?
    }
    private struct Status: Decodable { let status: String? }
    private struct Week: Decodable {
        let usedCents: Decimal?, budgetCents: Decimal?, resetCounter: Decimal?
        let periodStart: String?, resetsAt: String?
    }
    private struct Month: Decodable {
        let usedCents: Decimal?, creditsUsedCents: Decimal?
        let periodStart: String?, resetsAt: String?
        let limit: GrokSharedUsageObservation.MonthlyLimit
        private enum CodingKeys: String, CodingKey { case usedCents, limitCents, creditsUsedCents, periodStart, resetsAt }
        init(from decoder: any Decoder) throws {
            let fields = try decoder.container(keyedBy: CodingKeys.self)
            usedCents = try fields.decodeIfPresent(Decimal.self, forKey: .usedCents)
            creditsUsedCents = try fields.decodeIfPresent(Decimal.self, forKey: .creditsUsedCents)
            periodStart = try fields.decodeIfPresent(String.self, forKey: .periodStart)
            resetsAt = try fields.decodeIfPresent(String.self, forKey: .resetsAt)
            if !fields.contains(.limitCents) { limit = .notReported }
            else if try fields.decodeNil(forKey: .limitCents) { limit = .unset }
            else { limit = .amount(try fields.decode(Decimal.self, forKey: .limitCents)) }
        }
    }
}
