import Foundation

/// A rule target. First version accepts exact domains and exact IPv4 only:
/// no URLs, paths, wildcards, CIDR or IPv6. IPv6 *observation* is supported
/// elsewhere; only rule input excludes it for now.
public enum NetworkRuleTarget: Equatable, Hashable, Sendable {
    case exactDomain(String)
    case exactIPv4(String)

    public enum ValidationFailure: Error, Equatable, Sendable {
        case empty
        case containsURLSchemeOrPath
        case wildcardUnsupported
        case cidrUnsupported
        case ipv6Unsupported
        case invalidDomain
        case invalidIPv4
    }

    public init(validating raw: String) throws {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ValidationFailure.empty }
        if trimmed.contains("://") { throw ValidationFailure.containsURLSchemeOrPath }
        if let slash = trimmed.firstIndex(of: "/") {
            let address = trimmed[..<slash]
            let prefix = trimmed[trimmed.index(after: slash)...]
            let looksLikeCIDR = !address.isEmpty
                && address.allSatisfy({ $0.isNumber || $0 == "." })
                && !prefix.isEmpty
                && prefix.allSatisfy(\.isNumber)
            throw looksLikeCIDR ? ValidationFailure.cidrUnsupported : ValidationFailure.containsURLSchemeOrPath
        }
        if trimmed.contains("*") { throw ValidationFailure.wildcardUnsupported }
        if trimmed.contains(":") { throw ValidationFailure.ipv6Unsupported }
        if trimmed.allSatisfy({ $0.isNumber || $0 == "." }) {
            guard Self.isValidIPv4(trimmed) else { throw ValidationFailure.invalidIPv4 }
            self = .exactIPv4(trimmed)
        } else {
            guard Self.isValidDomain(trimmed) else { throw ValidationFailure.invalidDomain }
            self = .exactDomain(trimmed.lowercased())
        }
    }

    private static func isValidIPv4(_ value: String) -> Bool {
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return false }
        return parts.allSatisfy { part in
            !part.isEmpty && part.count <= 3 &&
                part.allSatisfy(\.isNumber) &&
                UInt8(part) != nil &&
                !(part.count > 1 && part.hasPrefix("0"))
        }
    }

    private static func isValidDomain(_ value: String) -> Bool {
        guard value.count <= 253 else { return false }
        let labels = value.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 2 else { return false }
        return labels.allSatisfy { label in
            !label.isEmpty && label.count <= 63 &&
                !label.hasPrefix("-") && !label.hasSuffix("-") &&
                label.allSatisfy(isASCIILetterOrDigitOrHyphen)
        }
    }

    /// ASCII-only: raw Unicode (IDN) input is rejected; users enter punycode.
    private static func isASCIILetterOrDigitOrHyphen(_ character: Character) -> Bool {
        character == "-" || character.isNumber ||
            ("a"..."z").contains(character) || ("A"..."Z").contains(character)
    }
}

public enum NetworkRuleAction: Equatable, Sendable {
    case allow
    case block
    /// Only the listed targets are allowed; anything else — including an
    /// unknown target — is denied while this rule is enforced.
    case allowlist([NetworkRuleTarget])
    /// Pause new matching connections and ask the user; the ask timeout is a
    /// policy of the enforcement layer, not of this value type.
    case ask

    public static let maxAllowlistEntries = 50
}

/// What the user is editing. A draft is never an effective rule and must
/// survive snapshot refreshes untouched.
public struct NetworkRuleDraft: Equatable, Sendable {
    public let appKey: String
    public let action: NetworkRuleAction

    public init(appKey: String, action: NetworkRuleAction) {
        self.appKey = appKey
        self.action = action
    }
}

/// A saved configuration: draft + revision. Saving is only `configured`;
/// enforcement requires an executor receipt for this exact revision.
public struct NetworkRuleConfiguration: Equatable, Sendable {
    public let draft: NetworkRuleDraft
    public let revision: UInt64
    public let savedAt: Date

    public init(draft: NetworkRuleDraft, revision: UInt64, savedAt: Date) {
        self.draft = draft
        self.revision = revision
        self.savedAt = savedAt
    }
}

/// Executor-side state of a configuration application.
public enum RuleExecutionState: Equatable, Sendable {
    case pending
    case configured
    case enforcing
    case enforced(revision: UInt64, confirmedAt: Date)
    case failed(revision: UInt64, reason: String)
    /// IPC disconnected or executor restarted: validity cannot be confirmed.
    case unknown

    /// Whether new-connection enforcement of `revision` is confirmed active.
    public func isEnforced(revision: UInt64) -> Bool {
        guard case let .enforced(confirmed, _) = self else { return false }
        return confirmed == revision
    }
}

/// Result of one idempotent apply operation. Reusing an `operationId` returns
/// the original outcome instead of re-executing.
public enum RuleApplyResult: Equatable, Sendable {
    case acknowledged(operationID: UUID, revision: UInt64)
    case conflict(operationID: UUID, currentRevision: UInt64)
    case failed(operationID: UUID, reason: String)
}

/// Aggregate rule record kept per app: the live draft, the persisted
/// configuration and the last confirmed execution state are stored
/// separately, so a failed apply never discards the previously enforced rule.
public struct NetworkRuleRecord: Equatable, Sendable {
    public let appKey: String
    public let draft: NetworkRuleDraft?
    public let configuration: NetworkRuleConfiguration?
    public let execution: RuleExecutionState

    public init(
        appKey: String,
        draft: NetworkRuleDraft? = nil,
        configuration: NetworkRuleConfiguration? = nil,
        execution: RuleExecutionState = .pending
    ) {
        self.appKey = appKey
        self.draft = draft
        self.configuration = configuration
        self.execution = execution
    }
}

/// Outcome of a terminate-existing-connections request. Requested count never
/// equals confirmed count; unknowns are reported, not silently zeroed.
public struct DisconnectExistingResult: Equatable, Sendable {
    public let operationID: UUID
    public let requestedCount: UInt64
    public let confirmedClosed: UInt64
    public let failedCount: UInt64
    public let unknownCount: UInt64

    public init(
        operationID: UUID,
        requestedCount: UInt64,
        confirmedClosed: UInt64,
        failedCount: UInt64,
        unknownCount: UInt64
    ) {
        self.operationID = operationID
        self.requestedCount = requestedCount
        self.confirmedClosed = confirmedClosed
        self.failedCount = failedCount
        self.unknownCount = unknownCount
    }
}
