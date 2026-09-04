import Foundation

struct ParsedOpenAIAccount: Equatable, Sendable {
    let accountType: String?
    let planType: String?
    let requiresOpenAIAuth: Bool
}

enum ParsedOpenAIRateLimitSource: Equatable, Sendable {
    case multiBucket
    case legacyFallback
}

enum ParsedOpenAIRateLimitWindowSlot: String, Equatable, Sendable {
    case primary
    case secondary
}

enum ParsedOpenAIBucketKind: Equatable, Sendable {
    case codex
    case spark
    case providerDefined
}

struct ParsedOpenAIBucketIdentity: Equatable, Sendable {
    let dictionaryKey: String?
    let limitID: String?
    let limitName: String?
}

struct ParsedOpenAIRateLimitWindow: Equatable, Sendable {
    let sourceSlot: ParsedOpenAIRateLimitWindowSlot
    let usedPercent: Double
    let windowDurationMins: Int?
    let resetsAt: Int64?
}

enum ParsedOpenAICreditBalance: Equatable, Sendable {
    case string(String)
    case number(Double)
    case boolean(Bool)
}

struct ParsedOpenAICredits: Equatable, Sendable {
    let hasCredits: Bool?
    let unlimited: Bool?
    let balance: ParsedOpenAICreditBalance?
}

struct ParsedOpenAIRateLimitBucket: Equatable, Sendable {
    let identity: ParsedOpenAIBucketIdentity
    let kind: ParsedOpenAIBucketKind
    let planType: String?
    let credits: ParsedOpenAICredits?
    let rateLimitReachedType: String?
    let windows: [ParsedOpenAIRateLimitWindow]
}

struct ParsedOpenAIResetCreditDetail: Equatable, Sendable {
    let sourceID: String?
    let resetType: String?
    let status: String?
    let grantedAt: Int64?
    let expiresAt: Int64?
    let title: String?
    let description: String?
}

enum ParsedOpenAIResetCreditDisplay: Equatable, Sendable {
    case hidden
    case countOnly
    case detail(ParsedOpenAIResetCreditDetail)
    case invalid
}

struct ParsedOpenAIResetCredits: Equatable, Sendable {
    let availableCount: Int
    let details: [ParsedOpenAIResetCreditDetail]?
    let display: ParsedOpenAIResetCreditDisplay
}

struct ParsedOpenAIQuotaDiagnostics: Equatable, Sendable {
    let invalidBucketSourceKeys: [String]
    let invalidWindowSourceIDs: [String]
    let invalidCreditSourceIDs: [String]
    let invalidResetCreditDetailCount: Int
    let invalidResetCreditSummaryCount: Int
    let invalidLegacyRateLimits: Bool
}

struct ParsedOpenAIRateLimits: Equatable, Sendable {
    let source: ParsedOpenAIRateLimitSource
    let buckets: [ParsedOpenAIRateLimitBucket]
    let resetCredits: ParsedOpenAIResetCredits?
    let diagnostics: ParsedOpenAIQuotaDiagnostics

    var validIndependentSparkBucket: ParsedOpenAIRateLimitBucket? {
        guard source == .multiBucket else { return nil }
        return buckets.first { $0.kind == .spark }
    }
}

enum OpenAIQuotaProjectionError: Error, Equatable, Sendable {
    case missingRateLimitSurface
}

enum OpenAIQuotaProjector {
    static func projectAccount(_ response: OpenAIAccountReadResponseDTO) -> ParsedOpenAIAccount {
        ParsedOpenAIAccount(
            accountType: response.account?.type,
            planType: response.account?.planType,
            requiresOpenAIAuth: response.requiresOpenAIAuth
        )
    }

    static func projectRateLimits(
        _ response: OpenAIRateLimitsReadResponseDTO
    ) throws -> ParsedOpenAIRateLimits {
        let source: ParsedOpenAIRateLimitSource
        let sourceBuckets: [(dictionaryKey: String?, bucket: OpenAIRateLimitBucketDTO)]

        if let multiBucket = response.rateLimitsByLimitID {
            source = .multiBucket
            sourceBuckets = multiBucket
                .sorted { $0.key < $1.key }
                .map { (dictionaryKey: $0.key, bucket: $0.value) }
        } else if let legacy = response.rateLimits {
            source = .legacyFallback
            sourceBuckets = [(dictionaryKey: nil, bucket: legacy)]
        } else {
            throw OpenAIQuotaProjectionError.missingRateLimitSurface
        }

        var buckets: [ParsedOpenAIRateLimitBucket] = []
        var invalidBucketSourceKeys = response.invalidLimitIDs
        var invalidWindowSourceIDs: [String] = []
        var invalidCreditSourceIDs: [String] = []

        for sourceBucket in sourceBuckets {
            let projection = projectBucket(
                sourceBucket.bucket,
                dictionaryKey: sourceBucket.dictionaryKey,
                source: source
            )
            invalidWindowSourceIDs.append(contentsOf: projection.invalidWindowSourceIDs)
            if sourceBucket.bucket.invalidCredits {
                invalidCreditSourceIDs.append(
                    sourceBucket.dictionaryKey
                        ?? sourceBucket.bucket.limitID
                        ?? "legacy.rateLimits"
                )
            }

            if let bucket = projection.bucket {
                buckets.append(bucket)
            } else {
                invalidBucketSourceKeys.append(
                    sourceBucket.dictionaryKey
                        ?? sourceBucket.bucket.limitID
                        ?? "legacy.rateLimits"
                )
            }
        }

        return ParsedOpenAIRateLimits(
            source: source,
            buckets: buckets,
            resetCredits: response.rateLimitResetCredits.map(projectResetCredits),
            diagnostics: ParsedOpenAIQuotaDiagnostics(
                invalidBucketSourceKeys: Array(Set(invalidBucketSourceKeys)).sorted(),
                invalidWindowSourceIDs: Array(Set(invalidWindowSourceIDs)).sorted(),
                invalidCreditSourceIDs: Array(Set(invalidCreditSourceIDs)).sorted(),
                invalidResetCreditDetailCount: response.rateLimitResetCredits?.invalidDetailCount ?? 0,
                invalidResetCreditSummaryCount: response.invalidRateLimitResetCredits ? 1 : 0,
                invalidLegacyRateLimits: response.invalidLegacyRateLimits
            )
        )
    }

    private static func projectBucket(
        _ bucket: OpenAIRateLimitBucketDTO,
        dictionaryKey: String?,
        source: ParsedOpenAIRateLimitSource
    ) -> (bucket: ParsedOpenAIRateLimitBucket?, invalidWindowSourceIDs: [String]) {
        let identity = ParsedOpenAIBucketIdentity(
            dictionaryKey: dictionaryKey,
            limitID: bucket.limitID,
            limitName: bucket.limitName
        )
        var windows: [ParsedOpenAIRateLimitWindow] = []
        var invalidWindowSourceIDs: [String] = []

        for (slot, window) in [
            (ParsedOpenAIRateLimitWindowSlot.primary, bucket.primary),
            (ParsedOpenAIRateLimitWindowSlot.secondary, bucket.secondary)
        ] {
            guard let window else { continue }
            guard isValid(window), let usedPercent = window.usedPercent else {
                invalidWindowSourceIDs.append(windowSourceID(identity: identity, slot: slot))
                continue
            }
            windows.append(
                ParsedOpenAIRateLimitWindow(
                    sourceSlot: slot,
                    usedPercent: usedPercent,
                    windowDurationMins: window.windowDurationMins,
                    resetsAt: window.resetsAt
                )
            )
        }

        guard !windows.isEmpty else {
            return (nil, invalidWindowSourceIDs)
        }

        return (
            ParsedOpenAIRateLimitBucket(
                identity: identity,
                kind: bucketKind(identity: identity, source: source),
                planType: bucket.planType,
                credits: bucket.credits.map(projectCredits),
                rateLimitReachedType: bucket.rateLimitReachedType,
                windows: windows
            ),
            invalidWindowSourceIDs
        )
    }

    private static func isValid(_ window: OpenAIRateLimitWindowDTO) -> Bool {
        guard let usedPercent = window.usedPercent,
              usedPercent.isFinite,
              (0...100).contains(usedPercent) else {
            return false
        }
        if let duration = window.windowDurationMins, duration <= 0 {
            return false
        }
        if let resetsAt = window.resetsAt, resetsAt <= 0 {
            return false
        }
        return true
    }

    private static func bucketKind(
        identity: ParsedOpenAIBucketIdentity,
        source: ParsedOpenAIRateLimitSource
    ) -> ParsedOpenAIBucketKind {
        let identifiers = [identity.dictionaryKey, identity.limitID]
            .compactMap(normalizedIdentifier)
        let normalizedName = normalizedIdentifier(identity.limitName)

        if source == .multiBucket,
           identifiers.contains("codex_bengalfox")
            || (normalizedName?.contains("codex") == true
                && normalizedName?.contains("spark") == true) {
            return .spark
        }
        if identifiers.contains("codex") {
            return .codex
        }
        return .providerDefined
    }

    private static func normalizedIdentifier(_ value: String?) -> String? {
        guard let normalized = value?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased(),
              !normalized.isEmpty else {
            return nil
        }
        return normalized
    }

    private static func windowSourceID(
        identity: ParsedOpenAIBucketIdentity,
        slot: ParsedOpenAIRateLimitWindowSlot
    ) -> String {
        let bucketID = identity.limitID ?? identity.dictionaryKey ?? "legacy.rateLimits"
        return "\(bucketID).\(slot.rawValue)"
    }

    private static func projectCredits(_ credits: OpenAICreditsDTO) -> ParsedOpenAICredits {
        ParsedOpenAICredits(
            hasCredits: credits.hasCredits,
            unlimited: credits.unlimited,
            balance: credits.balance.map { balance in
                switch balance {
                case let .string(value): .string(value)
                case let .number(value): .number(value)
                case let .boolean(value): .boolean(value)
                }
            }
        )
    }

    private static func projectResetCredits(
        _ summary: OpenAIRateLimitResetCreditsDTO
    ) -> ParsedOpenAIResetCredits {
        let details = summary.details?.map { detail in
            ParsedOpenAIResetCreditDetail(
                sourceID: detail.id,
                resetType: detail.resetType,
                status: detail.status,
                grantedAt: detail.grantedAt,
                expiresAt: detail.expiresAt,
                title: detail.title,
                description: detail.description
            )
        }

        let display: ParsedOpenAIResetCreditDisplay
        if summary.availableCount < 0 {
            display = .invalid
        } else if summary.availableCount == 0 {
            display = .hidden
        } else if let selected = details?
            .filter(isAvailableExpiringDetail)
            .sorted(by: resetDetailComesBefore)
            .first {
            display = .detail(selected)
        } else {
            display = .countOnly
        }

        return ParsedOpenAIResetCredits(
            availableCount: summary.availableCount,
            details: details,
            display: display
        )
    }

    private static func isAvailableExpiringDetail(_ detail: ParsedOpenAIResetCreditDetail) -> Bool {
        guard detail.status?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .caseInsensitiveCompare("available") == .orderedSame,
              let expiresAt = detail.expiresAt,
              expiresAt > 0 else {
            return false
        }
        return true
    }

    private static func resetDetailComesBefore(
        _ lhs: ParsedOpenAIResetCreditDetail,
        _ rhs: ParsedOpenAIResetCreditDetail
    ) -> Bool {
        let lhsExpiry = lhs.expiresAt ?? .max
        let rhsExpiry = rhs.expiresAt ?? .max
        if lhsExpiry != rhsExpiry { return lhsExpiry < rhsExpiry }

        let lhsGranted = lhs.grantedAt ?? .max
        let rhsGranted = rhs.grantedAt ?? .max
        if lhsGranted != rhsGranted { return lhsGranted < rhsGranted }

        let lhsStableID = [lhs.sourceID, lhs.resetType, lhs.title]
            .compactMap { $0 }
            .joined(separator: "|")
        let rhsStableID = [rhs.sourceID, rhs.resetType, rhs.title]
            .compactMap { $0 }
            .joined(separator: "|")
        return lhsStableID < rhsStableID
    }
}
