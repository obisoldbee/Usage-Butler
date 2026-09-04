import Foundation

public enum ParsedArkReadCompleteness: Equatable, Sendable {
    case completeSuccess
    case partial
    case failed
}

public struct ParsedArkParsingContext: Equatable, Sendable {
    public let completeness: ParsedArkReadCompleteness
    public let authoritativeDiscovery: Bool
    public let sourceVersion: String
    public let fetchedAt: Date

    public init(
        completeness: ParsedArkReadCompleteness,
        authoritativeDiscovery: Bool,
        sourceVersion: String,
        fetchedAt: Date
    ) {
        self.completeness = completeness
        self.authoritativeDiscovery = authoritativeDiscovery
        self.sourceVersion = sourceVersion
        self.fetchedAt = fetchedAt
    }
}

public enum ParsedArkProductID: Hashable, Sendable {
    case agentPlan
    case codingPlan
    case other(String)

    public init(sourceValue: String) {
        switch sourceValue {
        case "agent-plan": self = .agentPlan
        case "coding-plan": self = .codingPlan
        default: self = .other(sourceValue)
        }
    }

    public var sourceValue: String {
        switch self {
        case .agentPlan: "agent-plan"
        case .codingPlan: "coding-plan"
        case let .other(value): value
        }
    }

    public var isSupportedProduct: Bool {
        switch self {
        case .agentPlan, .codingPlan:
            true
        case .other:
            false
        }
    }
}

public enum ParsedArkResetAt: Equatable, Sendable {
    case absent
    case parsed(rawValue: String, date: Date)
    case unparsed(rawValue: String)
}

public enum ParsedArkUpdatedAt: Equatable, Sendable {
    case unixSeconds(Decimal)
    case text(String)
}

public enum ParsedArkPeriodsFieldState: Equatable, Sendable {
    case array
    case missing
    case null
    case invalidType
}

public enum ParsedArkPeriodContractIssue: Equatable, Sendable {
    case missingRequiredField(String)
    case invalidFieldType(String)
    case invalidSourceValue(String)
}

public struct ParsedArkPeriod: Equatable, Sendable {
    public let label: String
    public let used: Decimal?
    public let total: Decimal?
    public let percent: Decimal?
    public let resetAt: ParsedArkResetAt
    public let decodingIssue: ParsedArkPeriodContractIssue?

    public init(
        label: String,
        used: Decimal?,
        total: Decimal?,
        percent: Decimal?,
        resetAt: ParsedArkResetAt,
        decodingIssue: ParsedArkPeriodContractIssue? = nil
    ) {
        self.label = label
        self.used = used
        self.total = total
        self.percent = percent
        self.resetAt = resetAt
        self.decodingIssue = decodingIssue
    }

    public var contractIssue: ParsedArkPeriodContractIssue? {
        if let decodingIssue { return decodingIssue }
        guard let percent else {
            return .missingRequiredField("percent")
        }
        guard percent >= 0, percent <= 100 else {
            return .invalidSourceValue("percent")
        }
        if let used, used < 0 {
            return .invalidSourceValue("used")
        }
        if let total, total < 0 {
            return .invalidSourceValue("total")
        }
        if let used, let total, used > total {
            return .invalidSourceValue("used_total_pair")
        }
        if case .unparsed = resetAt {
            return .invalidSourceValue("reset_at")
        }
        return nil
    }
}

public struct ParsedArkUsageItem: Equatable, Sendable {
    public let productID: ParsedArkProductID
    public let sourceProduct: String
    public let edition: String?
    public let tier: String?
    public let subscribed: Bool?
    public let periods: [ParsedArkPeriod]
    public let periodsFieldState: ParsedArkPeriodsFieldState
    public let droppedPeriodCount: Int
    public let seatID: String?
    public let updatedAt: ParsedArkUpdatedAt?
    public let updatedAtISO8601: String?
    public let sourceErrorPresent: Bool

    public init(
        productID: ParsedArkProductID,
        sourceProduct: String,
        edition: String?,
        tier: String?,
        subscribed: Bool?,
        periods: [ParsedArkPeriod],
        periodsFieldState: ParsedArkPeriodsFieldState,
        droppedPeriodCount: Int,
        seatID: String?,
        updatedAt: ParsedArkUpdatedAt?,
        updatedAtISO8601: String?,
        sourceErrorPresent: Bool
    ) {
        self.productID = productID
        self.sourceProduct = sourceProduct
        self.edition = edition
        self.tier = tier
        self.subscribed = subscribed
        self.periods = periods
        self.periodsFieldState = periodsFieldState
        self.droppedPeriodCount = droppedPeriodCount
        self.seatID = seatID
        self.updatedAt = updatedAt
        self.updatedAtISO8601 = updatedAtISO8601
        self.sourceErrorPresent = sourceErrorPresent
    }

    public var periodsFieldPresent: Bool {
        periodsFieldState != .missing
    }

    public var hasCompletePeriodsContract: Bool {
        guard periodsFieldState == .array, droppedPeriodCount == 0 else {
            return false
        }
        let counts = Dictionary(grouping: periods, by: \.label).mapValues(\.count)
        return !counts.values.contains(where: { $0 > 1 })
            && periods.allSatisfy { $0.contractIssue == nil }
    }
}

public struct ParsedArkPresenceEvidence: Equatable, Sendable {
    public let authority: String
    public let observedAt: Date
}

public enum ParsedArkPresenceUnknownReason: Equatable, Sendable {
    case missingFromResponse
    case duplicateItems
    case itemError
    case missingSubscriptionFlag
    case incompleteDiscovery
}

public enum ParsedArkPresence: Equatable, Sendable {
    case entitled
    case notEntitled(ParsedArkPresenceEvidence)
    case unknown(ParsedArkPresenceUnknownReason)
}

public struct ParsedArkProductResolution: Equatable, Sendable {
    public let productID: ParsedArkProductID
    public let presence: ParsedArkPresence
    public let sourceItems: [ParsedArkUsageItem]

    public var uniqueItem: ParsedArkUsageItem? {
        sourceItems.count == 1 ? sourceItems[0] : nil
    }
}

public struct ParsedArkEnvelopeDiagnostics: Equatable, Sendable {
    public let supportedItemCount: Int
    public let unsupportedItemCount: Int
    public let droppedAgentPlanItemCount: Int
    public let droppedCodingPlanItemCount: Int
    public let droppedUnsupportedItemCount: Int
    public let droppedUnclassifiedItemCount: Int

    public init(
        supportedItemCount: Int,
        unsupportedItemCount: Int,
        droppedAgentPlanItemCount: Int,
        droppedCodingPlanItemCount: Int,
        droppedUnsupportedItemCount: Int,
        droppedUnclassifiedItemCount: Int
    ) {
        self.supportedItemCount = supportedItemCount
        self.unsupportedItemCount = unsupportedItemCount
        self.droppedAgentPlanItemCount = droppedAgentPlanItemCount
        self.droppedCodingPlanItemCount = droppedCodingPlanItemCount
        self.droppedUnsupportedItemCount = droppedUnsupportedItemCount
        self.droppedUnclassifiedItemCount = droppedUnclassifiedItemCount
    }

    public static let empty = ParsedArkEnvelopeDiagnostics(
        supportedItemCount: 0,
        unsupportedItemCount: 0,
        droppedAgentPlanItemCount: 0,
        droppedCodingPlanItemCount: 0,
        droppedUnsupportedItemCount: 0,
        droppedUnclassifiedItemCount: 0
    )

    public var droppedSupportedItemCount: Int {
        droppedAgentPlanItemCount + droppedCodingPlanItemCount
    }

    public var droppedItemCount: Int {
        droppedSupportedItemCount
            + droppedUnsupportedItemCount
            + droppedUnclassifiedItemCount
    }

    public func droppedItemCount(for productID: ParsedArkProductID) -> Int {
        switch productID {
        case .agentPlan:
            droppedAgentPlanItemCount
        case .codingPlan:
            droppedCodingPlanItemCount
        case .other:
            droppedUnsupportedItemCount
        }
    }
}

public struct ParsedArkUsageSnapshot: Equatable, Sendable {
    public let viewerWasPresent: Bool
    public let items: [ParsedArkUsageItem]
    public let envelopeDiagnostics: ParsedArkEnvelopeDiagnostics
    public let context: ParsedArkParsingContext

    public init(
        viewerWasPresent: Bool,
        items: [ParsedArkUsageItem],
        envelopeDiagnostics: ParsedArkEnvelopeDiagnostics,
        context: ParsedArkParsingContext
    ) {
        self.viewerWasPresent = viewerWasPresent
        self.items = items
        self.envelopeDiagnostics = envelopeDiagnostics
        self.context = context
    }

    public var droppedItemCount: Int {
        envelopeDiagnostics.droppedItemCount
    }

    public var effectiveCompleteness: ParsedArkReadCompleteness {
        guard context.completeness == .completeSuccess else {
            return context.completeness
        }
        let supportedItems = items.filter(\.productID.isSupportedProduct)
        return envelopeDiagnostics.droppedSupportedItemCount == 0
            && envelopeDiagnostics.droppedUnclassifiedItemCount == 0
            && supportedItems.allSatisfy(\.hasCompletePeriodsContract)
            ? .completeSuccess
            : .partial
    }

    public func resolution(for productID: ParsedArkProductID) -> ParsedArkProductResolution {
        let matches = items.filter { $0.productID == productID }
        guard matches.count == 1, let item = matches.first else {
            return ParsedArkProductResolution(
                productID: productID,
                presence: .unknown(matches.isEmpty ? .missingFromResponse : .duplicateItems),
                sourceItems: matches
            )
        }

        let presence: ParsedArkPresence
        if item.sourceErrorPresent {
            presence = .unknown(.itemError)
        } else {
            switch item.subscribed {
            case true:
                presence = .entitled
            case false:
                if context.completeness == .completeSuccess,
                   context.authoritativeDiscovery,
                   envelopeDiagnostics.droppedItemCount(for: productID) == 0,
                   envelopeDiagnostics.droppedUnclassifiedItemCount == 0,
                   item.hasCompletePeriodsContract {
                    presence = .notEntitled(
                        ParsedArkPresenceEvidence(
                            authority: "ark.usage-plan.subscribed",
                            observedAt: context.fetchedAt
                        )
                    )
                } else {
                    presence = .unknown(.incompleteDiscovery)
                }
            case nil:
                presence = .unknown(.missingSubscriptionFlag)
            }
        }

        return ParsedArkProductResolution(
            productID: productID,
            presence: presence,
            sourceItems: matches
        )
    }

    public var agentPlan: ParsedArkProductResolution {
        resolution(for: .agentPlan)
    }

    public var codingPlan: ParsedArkProductResolution {
        resolution(for: .codingPlan)
    }
}

public struct ParsedArkPlanTierObservation: Equatable, Sendable {
    public let productID: ParsedArkProductID
    public let tier: String
    public let fetchedAt: Date

    public init(
        productID: ParsedArkProductID,
        tier: String,
        fetchedAt: Date
    ) {
        self.productID = productID
        self.tier = tier
        self.fetchedAt = fetchedAt
    }
}

public struct ParsedArkPlanMetadataSnapshot: Equatable, Sendable {
    public let tiers: [ParsedArkProductID: ParsedArkPlanTierObservation]

    public init(tiers: [ParsedArkProductID: ParsedArkPlanTierObservation]) {
        self.tiers = tiers
    }
}

public enum ParsedArkParsingFailureCode: String, Equatable, Sendable {
    case emptyInput
    case missingRequiredField
    case invalidFieldType
    case invalidJSON
}

public struct ParsedArkParsingFailure: Error, Equatable, Sendable {
    public let code: ParsedArkParsingFailureCode
    public let codingPath: String

    public init(code: ParsedArkParsingFailureCode, codingPath: String) {
        self.code = code
        self.codingPath = codingPath
    }
}

public enum ArkUsagePlanParser {
    public static func parse(
        _ data: Data,
        context: ParsedArkParsingContext
    ) throws -> ParsedArkUsageSnapshot {
        guard !data.isEmpty else {
            throw ParsedArkParsingFailure(code: .emptyInput, codingPath: "$")
        }

        let envelope: ArkEnvelopeDTO
        do {
            envelope = try JSONDecoder().decode(ArkEnvelopeDTO.self, from: data)
        } catch {
            throw mapDecodingError(error)
        }

        let items = envelope.items.compactMap(\.value).map(\.parsed)
        let diagnostics = ParsedArkEnvelopeDiagnostics(
            supportedItemCount: items.filter(\.productID.isSupportedProduct).count,
            unsupportedItemCount: items.filter { !$0.productID.isSupportedProduct }.count,
            droppedAgentPlanItemCount: envelope.items.filter {
                $0.value == nil && $0.classification == .supported(.agentPlan)
            }.count,
            droppedCodingPlanItemCount: envelope.items.filter {
                $0.value == nil && $0.classification == .supported(.codingPlan)
            }.count,
            droppedUnsupportedItemCount: envelope.items.filter {
                $0.value == nil && $0.classification == .unsupported
            }.count,
            droppedUnclassifiedItemCount: envelope.items.filter {
                $0.value == nil && $0.classification == .unclassified
            }.count
        )
        return ParsedArkUsageSnapshot(
            viewerWasPresent: envelope.viewerWasPresent,
            items: items,
            envelopeDiagnostics: diagnostics,
            context: context
        )
    }

    private static func mapDecodingError(_ error: Error) -> ParsedArkParsingFailure {
        switch error {
        case let DecodingError.keyNotFound(key, context):
            return ParsedArkParsingFailure(
                code: .missingRequiredField,
                codingPath: path(context.codingPath + [key])
            )
        case let DecodingError.typeMismatch(_, context),
             let DecodingError.valueNotFound(_, context):
            return ParsedArkParsingFailure(
                code: .invalidFieldType,
                codingPath: path(context.codingPath)
            )
        case let DecodingError.dataCorrupted(context):
            return ParsedArkParsingFailure(
                code: .invalidJSON,
                codingPath: path(context.codingPath)
            )
        default:
            return ParsedArkParsingFailure(code: .invalidJSON, codingPath: "$")
        }
    }

    private static func path(_ codingPath: [any CodingKey]) -> String {
        guard !codingPath.isEmpty else { return "$" }
        return "$." + codingPath.map(\.stringValue).joined(separator: ".")
    }
}

public enum ArkPlanMetadataParser {
    public static func parse(
        _ data: Data,
        fetchedAt: Date
    ) throws -> ParsedArkPlanMetadataSnapshot {
        guard !data.isEmpty else {
            throw ParsedArkParsingFailure(code: .emptyInput, codingPath: "$")
        }

        let envelope: ArkPlansMetadataEnvelopeDTO
        do {
            envelope = try JSONDecoder().decode(ArkPlansMetadataEnvelopeDTO.self, from: data)
        } catch let DecodingError.keyNotFound(key, context) {
            throw ParsedArkParsingFailure(
                code: .missingRequiredField,
                codingPath: metadataPath(context.codingPath + [key])
            )
        } catch let DecodingError.typeMismatch(_, context) {
            throw ParsedArkParsingFailure(
                code: .invalidFieldType,
                codingPath: metadataPath(context.codingPath)
            )
        } catch let DecodingError.valueNotFound(_, context) {
            throw ParsedArkParsingFailure(
                code: .invalidFieldType,
                codingPath: metadataPath(context.codingPath)
            )
        } catch let DecodingError.dataCorrupted(context) {
            throw ParsedArkParsingFailure(
                code: .invalidJSON,
                codingPath: metadataPath(context.codingPath)
            )
        } catch {
            throw ParsedArkParsingFailure(code: .invalidJSON, codingPath: "$")
        }

        let observations = envelope.plans.compactMap(\.value).compactMap { plan in
            observation(plan, fetchedAt: fetchedAt)
        }
        let unique = Dictionary(grouping: observations, by: \.productID)
            .compactMapValues { matches in
                matches.count == 1 ? matches[0] : nil
            }
        return ParsedArkPlanMetadataSnapshot(tiers: unique)
    }

    private static func observation(
        _ plan: ArkPlanMetadataDTO,
        fetchedAt: Date
    ) -> ParsedArkPlanTierObservation? {
        guard plan.scope.lowercased() == "personal" else { return nil }
        let productID = ParsedArkProductID(sourceValue: plan.key)
        let tier = plan.tier.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        let allowedTiers: Set<String>
        switch productID {
        case .agentPlan:
            allowedTiers = ["medium"]
        case .codingPlan:
            allowedTiers = ["lite", "pro"]
        case .other:
            return nil
        }
        guard allowedTiers.contains(tier) else { return nil }

        return ParsedArkPlanTierObservation(
            productID: productID,
            tier: tier,
            fetchedAt: fetchedAt
        )
    }

    private static func metadataPath(_ codingPath: [any CodingKey]) -> String {
        guard !codingPath.isEmpty else { return "$" }
        return "$." + codingPath.map(\.stringValue).joined(separator: ".")
    }
}

private struct ArkEnvelopeDTO: Decodable {
    let viewerWasPresent: Bool
    let items: [ArkItemAttempt]

    enum CodingKeys: String, CodingKey {
        case viewer
        case items
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if container.contains(.viewer), try !container.decodeNil(forKey: .viewer) {
            _ = try container.decode(IgnoredJSON.self, forKey: .viewer)
            viewerWasPresent = true
        } else {
            viewerWasPresent = false
        }
        items = try container.decode([ArkItemAttempt].self, forKey: .items)
    }
}

private struct ArkItemAttempt: Decodable {
    enum Classification: Equatable {
        case supported(ParsedArkProductID)
        case unsupported
        case unclassified
    }

    let value: ArkItemDTO?
    let classification: Classification

    private enum CodingKeys: String, CodingKey {
        case product
    }

    init(from decoder: any Decoder) throws {
        if let container = try? decoder.container(keyedBy: CodingKeys.self),
           let product = try? container.decode(String.self, forKey: .product) {
            let productID = ParsedArkProductID(sourceValue: product)
            classification = productID.isSupportedProduct
                ? .supported(productID)
                : .unsupported
        } else {
            classification = .unclassified
        }
        value = try? ArkItemDTO(from: decoder)
    }
}

private struct ArkItemDTO: Decodable {
    let product: String
    let edition: String?
    let tier: String?
    let subscribed: Bool?
    let periods: [ArkPeriodAttempt]
    let periodsFieldState: ParsedArkPeriodsFieldState
    let seatID: String?
    let updatedAt: ParsedArkUpdatedAt?
    let updatedAtISO8601: String?
    let errorPresent: Bool

    enum CodingKeys: String, CodingKey {
        case product
        case edition
        case tier
        case subscribed
        case periods
        case seatID = "seat_id"
        case updatedAt = "updated_at"
        case updatedAtISO8601 = "updated_at_iso8601"
        case error
        case sanitizedErrorPresent = "error_present"
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        product = try container.decode(String.self, forKey: .product)
        // These fields enrich presentation or source receipts; none is quota
        // authority. A type drift must therefore omit only that metadata rather
        // than discard an otherwise valid Product and its periods.
        edition = try? container.decode(String.self, forKey: .edition)
        tier = try? container.decode(String.self, forKey: .tier)
        subscribed = try container.decodeIfPresent(Bool.self, forKey: .subscribed)
        if !container.contains(.periods) {
            periods = []
            periodsFieldState = .missing
        } else if try container.decodeNil(forKey: .periods) {
            periods = []
            periodsFieldState = .null
        } else {
            do {
                periods = try container.decode([ArkPeriodAttempt].self, forKey: .periods)
                periodsFieldState = .array
            } catch {
                periods = []
                periodsFieldState = .invalidType
            }
        }
        seatID = try? container.decode(String.self, forKey: .seatID)
        updatedAt = try? container.decode(ArkUpdatedAtDTO.self, forKey: .updatedAt).parsed
        updatedAtISO8601 = try? container.decode(String.self, forKey: .updatedAtISO8601)

        var rawErrorPresent = false
        if container.contains(.error), try !container.decodeNil(forKey: .error) {
            _ = try container.decode(IgnoredJSON.self, forKey: .error)
            rawErrorPresent = true
        }
        let sanitizedErrorPresent = try container.decodeIfPresent(
            Bool.self,
            forKey: .sanitizedErrorPresent
        ) ?? false
        errorPresent = rawErrorPresent || sanitizedErrorPresent
    }

    var parsed: ParsedArkUsageItem {
        let parsedPeriods = periods.compactMap(\.value).map(\.parsed)
        return ParsedArkUsageItem(
            productID: ParsedArkProductID(sourceValue: product),
            sourceProduct: product,
            edition: edition,
            tier: tier,
            subscribed: subscribed,
            periods: parsedPeriods,
            periodsFieldState: periodsFieldState,
            droppedPeriodCount: periods.count - parsedPeriods.count,
            seatID: seatID,
            updatedAt: updatedAt,
            updatedAtISO8601: updatedAtISO8601,
            sourceErrorPresent: errorPresent
        )
    }
}

private struct ArkPeriodAttempt: Decodable {
    let value: ArkPeriodDTO?

    init(from decoder: any Decoder) throws {
        value = try? ArkPeriodDTO(from: decoder)
    }
}

private struct ArkPeriodDTO: Decodable {
    let label: String
    let used: Decimal?
    let total: Decimal?
    let percent: Decimal?
    let resetAt: String?
    let decodingIssue: ParsedArkPeriodContractIssue?

    enum CodingKeys: String, CodingKey {
        case label
        case used
        case total
        case percent
        case resetAt = "reset_at"
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        label = try container.decode(String.self, forKey: .label)

        var firstIssue: ParsedArkPeriodContractIssue?
        func record(_ issue: ParsedArkPeriodContractIssue) {
            if firstIssue == nil { firstIssue = issue }
        }

        if container.contains(.used), try !container.decodeNil(forKey: .used) {
            do {
                used = try container.decode(Decimal.self, forKey: .used)
            } catch {
                used = nil
                record(.invalidFieldType("used"))
            }
        } else {
            used = nil
        }

        if container.contains(.total), try !container.decodeNil(forKey: .total) {
            do {
                total = try container.decode(Decimal.self, forKey: .total)
            } catch {
                total = nil
                record(.invalidFieldType("total"))
            }
        } else {
            total = nil
        }

        if !container.contains(.percent) {
            percent = nil
            record(.missingRequiredField("percent"))
        } else if try container.decodeNil(forKey: .percent) {
            percent = nil
            record(.missingRequiredField("percent"))
        } else {
            do {
                percent = try container.decode(Decimal.self, forKey: .percent)
            } catch {
                percent = nil
                record(.invalidFieldType("percent"))
            }
        }

        if container.contains(.resetAt), try !container.decodeNil(forKey: .resetAt) {
            do {
                resetAt = try container.decode(String.self, forKey: .resetAt)
            } catch {
                resetAt = nil
                record(.invalidFieldType("reset_at"))
            }
        } else {
            resetAt = nil
        }
        decodingIssue = firstIssue
    }

    var parsed: ParsedArkPeriod {
        let parsedReset: ParsedArkResetAt
        if let resetAt {
            if let date = Self.parseRFC3339(resetAt) {
                parsedReset = .parsed(rawValue: resetAt, date: date)
            } else {
                parsedReset = .unparsed(rawValue: resetAt)
            }
        } else {
            parsedReset = .absent
        }

        return ParsedArkPeriod(
            label: label,
            used: used,
            total: total,
            percent: percent,
            resetAt: parsedReset,
            decodingIssue: decodingIssue
        )
    }

    private static func parseRFC3339(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }
}

private struct ArkUpdatedAtDTO: Decodable {
    let parsed: ParsedArkUpdatedAt

    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let number = try? container.decode(Decimal.self) {
            parsed = .unixSeconds(number)
        } else if let text = try? container.decode(String.self) {
            parsed = .text(text)
        } else {
            throw DecodingError.typeMismatch(
                ParsedArkUpdatedAt.self,
                DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription: "Expected a numeric or textual updated_at value"
                )
            )
        }
    }
}

private struct ArkPlansMetadataEnvelopeDTO: Decodable {
    let plans: [ArkPlanMetadataAttempt]
}

private struct ArkPlanMetadataAttempt: Decodable {
    let value: ArkPlanMetadataDTO?

    init(from decoder: any Decoder) throws {
        value = try? ArkPlanMetadataDTO(from: decoder)
    }
}

private struct ArkPlanMetadataDTO: Decodable {
    let key: String
    let scope: String
    let tier: String

    enum CodingKeys: String, CodingKey {
        case key
        case scope
        case tier
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        key = try container.decode(String.self, forKey: .key)
        scope = try container.decode(String.self, forKey: .scope)
        tier = try container.decode(String.self, forKey: .tier)
    }
}

/// Decodes and intentionally discards an opaque value. It is used only to preserve
/// the structural fact that a viewer or error payload was present.
private struct IgnoredJSON: Decodable {
    init(from decoder: any Decoder) throws {}
}
