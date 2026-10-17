import Foundation
import UsageButlerDomain

/// Fields verified against CodexBar 910dc82e, CursorSandUsage.swift (MIT).
struct CursorSandUsageDTO: Decodable, Sendable {
    let currentPeriodStart: String?
    let nextResetTimestampUtc: String?
    let usagePercent: Decimal?
    let hasAvailableUsage: Bool?
    let hasNonZeroIncludedLimit: Bool?
    let includedLimitZero: Bool?
    let sandTrialExpiresAt: String?
}

public enum GrokBotQuotaMapper {
    public static let contractEvidence = "CodexBar-910dc82e78e212f8904f3725a756ad03fa86c551"
    public static let contractVersion = "cursor-sand-v1"
    public static func source(sessionScope: String? = nil) -> ProviderSourceIdentity {
        ProviderSourceIdentity(providerID: .grokBot, adapterID: "cursor-sand", executableIdentity: "", cliVersion: "",
            schemaVersion: "cursor-sand-1", contractVersion: contractVersion,
            transport: .https(origin: "https://cursor.com", adapterVersion: "1", contractEvidence: contractEvidence), sessionScope: sessionScope)
    }
    public static func map(_ data: Data, fetchedAt: Date, sessionScope: String,
                           meteringSystem: GrokBotMeteringSystem = .unknown) throws -> ProviderQuotaData {
        let dto: CursorSandUsageDTO
        do { dto = try JSONDecoder().decode(CursorSandUsageDTO.self, from: data) }
        catch { throw GrokBotReadError.schema }
        guard dto.usagePercent != nil || dto.hasAvailableUsage != nil || dto.includedLimitZero != nil || dto.hasNonZeroIncludedLimit != nil || dto.sandTrialExpiresAt != nil else {
            throw GrokBotReadError.schema
        }
        func date(_ value: String?) throws -> Date? {
            guard let value else { return nil }
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = formatter.date(from: value) { return date }
            formatter.formatOptions = [.withInternetDateTime]
            guard let date = formatter.date(from: value) else { throw GrokBotReadError.schema }
            return date
        }
        let observation = GrokBotUsageObservation(meteringSystem: meteringSystem, usagePercent: dto.usagePercent,
            hasAvailableUsage: dto.hasAvailableUsage, hasNonZeroIncludedLimit: dto.hasNonZeroIncludedLimit,
            includedLimitZero: dto.includedLimitZero, currentPeriodStart: try date(dto.currentPeriodStart),
            nextResetAt: try date(dto.nextResetTimestampUtc), trialExpiresAt: try date(dto.sandTrialExpiresAt))
        let source = source(sessionScope: sessionScope)
        let node = QuotaNodeState.authoritativeData(asOf: fetchedAt)
        let identity = MetricSourceIdentity(providerID: .grokBot, sourceProductID: "cursor-sand", sourceBucketID: nil, sourceMetricID: "usagePercent")
        let value: QuotaMetricValue
        if meteringSystem == .xShared {
            value = .unavailable(reason: .unsupportedSemantics(sourceKind: "x-shared-pool"))
        } else if let percent = observation.usagePercent {
            value = !percent.isNaN && percent >= 0 && percent <= 100
                ? .percent(.init(sourceValue: percent, sourceDirection: .used))
                : .unavailable(reason: .invalidSourceValue(field: "usagePercent"))
        } else { value = .unavailable(reason: .notReported) }
        let isTrial = observation.hasIncludedLimit != true && observation.trialExpiresAt != nil
        let event = isTrial ? observation.trialExpiresAt.map { QuotaTimeEvent(kind: .entitlementExpiry, occursAt: $0) }
            : observation.nextResetAt.map { QuotaTimeEvent(kind: .reset, occursAt: $0) }
        let metric = QuotaMetric(id: .init(sourceIdentity: identity), sourceMetricID: "usagePercent", sourceLabel: "Grok Bot",
            window: .init(kind: .providerDefined("cursor-sand"), duration: nil, startsAt: observation.currentPeriodStart,
                          endsAt: nil, timeEvent: event), value: value, sourceStatus: nil,
            provenance: .init(sourceIdentity: identity, providerSource: source, fetchedAt: fetchedAt), state: node)
        return ProviderQuotaData(providerID: .grokBot, source: source, fetchedAt: fetchedAt, grokBotUsage: observation,
            products: [.init(id: .init(providerID: .grokBot, sourceProductID: "cursor-sand"), sourceProductID: "cursor-sand",
                titleKey: "product.grokbot", canonicalOrder: 0, planLevel: nil, state: node, metrics: [metric])],
            balances: [], resetEntitlements: [])
    }
}
