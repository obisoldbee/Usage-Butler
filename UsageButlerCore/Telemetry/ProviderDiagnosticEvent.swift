import Foundation
import UsageButlerDomain

/// Persistable evidence has no free-form response, stderr, account or path fields.
public struct ProviderDiagnosticEvent: Codable, Equatable, Identifiable, Sendable {
    public enum Stage: String, Codable, Sendable { case execution, json, quota, runtime, recovery }
    public enum RetryGate: String, Codable, Sendable {
        case open, cooldown, backoff, suspended
        public init(_ gate: RefreshGateState) {
            switch gate {
            case .open: self = .open
            case .cooldown: self = .cooldown
            case .backoff: self = .backoff
            case .suspended: self = .suspended
            }
        }
    }
    public enum Reason: String, Codable, Sendable {
        case processFailure, emptyOutput, invalidJSON, missingField, invalidType
        case unsupportedStatus, unsupportedModel, invalidPercent, invalidCount, unsupportedBoost
        case partialRows, baseStatus, providerFailure, recovered
    }
    public let id: UUID
    public let attemptID: UUID
    public let timestamp: Date
    public let provider: String
    public let stage: Stage
    public let reason: Reason
    public let failureCode: String?
    public let retryAt: Date?
    public let retryGate: RetryGate?
    public let automaticRetry: Bool?
    public let cliVersion: String?
    public let executableSHA256: String?
    public let exitCode: Int32?
    public let durationMilliseconds: Int?
    public let stdoutBytes: Int?
    public let stderrBytes: Int?
    public let fieldPath: String?
    public let model: String?
    public let window: String?
    public let values: [String: Double]

    public static let numericFields: Set<String> = [
        "start_time", "end_time", "remains_time", "current_interval_total_count",
        "current_interval_usage_count", "current_interval_remaining_percent", "current_interval_status",
        "weekly_start_time", "weekly_end_time", "weekly_remains_time", "current_weekly_total_count",
        "current_weekly_usage_count", "current_weekly_remaining_percent", "current_weekly_status",
        "weekly_boost_permille", "status_code", "dropped_rows", "duplicate_rows"
    ]

    public init(providerID: ProviderID, stage: Stage, reason: Reason,
                attemptID: UUID = UUID(), timestamp: Date = Date(), failureCode: FailureCode? = nil,
                retryAt: Date? = nil, retryGate: RetryGate? = nil, automaticRetry: Bool? = nil, cliVersion: String? = nil, executableSHA256: String? = nil,
                exitCode: Int32? = nil, durationMilliseconds: Int? = nil,
                stdoutBytes: Int? = nil, stderrBytes: Int? = nil, fieldPath: String? = nil,
                model: String? = nil, window: String? = nil, values: [String: Double] = [:]) {
        id = UUID(); self.attemptID = attemptID; self.timestamp = timestamp
        provider = providerID.rawValue; self.stage = stage; self.reason = reason
        self.failureCode = failureCode?.rawValue; self.retryAt = retryAt
        self.retryGate = retryGate; self.automaticRetry = automaticRetry
        self.cliVersion = cliVersion.flatMap { $0.range(of: #"^\d{1,5}\.\d{1,5}\.\d{1,5}$"#, options: .regularExpression) != nil ? $0 : nil }
        self.executableSHA256 = executableSHA256.flatMap { $0.range(of: #"^[a-f0-9]{64}$"#, options: .regularExpression) != nil ? $0 : nil }
        self.exitCode = exitCode
        self.durationMilliseconds = durationMilliseconds.map { max(0, min($0, 86_400_000)) }
        self.stdoutBytes = stdoutBytes.map { max(0, $0) }; self.stderrBytes = stderrBytes.map { max(0, $0) }
        self.fieldPath = fieldPath.map(Self.safeFieldPath)
        self.model = model.map { ["general", "video"].contains($0) ? $0 : "unknown" }
        self.window = window.map { ["current", "weekly"].contains($0) ? $0 : "unknown" }
        self.values = values.filter { Self.numericFields.contains($0.key) && $0.value.isFinite }
    }

    /// Enforce the same closed fields when reading an on-disk event.
    public var isSafe: Bool {
        ["openAI", "miniMax", "ark"].contains(provider)
            && timestamp.timeIntervalSince1970.isFinite
            && (failureCode == nil || FailureCode(rawValue: failureCode!) != nil)
            && (cliVersion == nil || cliVersion!.range(of: #"^\d{1,5}\.\d{1,5}\.\d{1,5}$"#, options: .regularExpression) != nil)
            && (executableSHA256 == nil || executableSHA256!.range(of: #"^[a-f0-9]{64}$"#, options: .regularExpression) != nil)
            && (fieldPath == nil || fieldPath == Self.safeFieldPath(fieldPath!))
            && (model == nil || ["general", "video", "unknown"].contains(model!))
            && (window == nil || ["current", "weekly", "unknown"].contains(window!))
            && values.allSatisfy { Self.numericFields.contains($0.key) && $0.value.isFinite }
    }

    public static func safeFieldPath(_ path: String) -> String {
        let allowed = numericFields.union(["$", "base_resp", "model_remains", "model_name", "row"])
        return path.split(separator: ".").prefix(6).map { part in
            let value = String(part)
            if allowed.contains(value) { return value }
            if Int(value) != nil || value.hasPrefix("Index ") { return "row" }
            return "unknown"
        }.joined(separator: ".")
    }
}

public protocol ProviderDiagnosticRecording: Sendable {
    func record(_ event: ProviderDiagnosticEvent) async
}
