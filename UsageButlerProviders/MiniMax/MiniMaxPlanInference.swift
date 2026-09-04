import Foundation

public struct ParsedMiniMaxPlanInferenceContract: Equatable, Sendable {
    public let ruleID: String
    public let catalogID: String
    public let sourceVersion: String
    public let region: String
    public let contractVersion: String

    public init(
        ruleID: String,
        catalogID: String,
        sourceVersion: String,
        region: String,
        contractVersion: String
    ) {
        self.ruleID = ruleID
        self.catalogID = catalogID
        self.sourceVersion = sourceVersion
        self.region = region
        self.contractVersion = contractVersion
    }

    public static let approvedV1 = ParsedMiniMaxPlanInferenceContract(
        ruleID: "minimax-video-daily-v1",
        catalogID: "minimax-token-plan-zh-cn-2026-08-10",
        sourceVersion: "1.0.19",
        region: "cn",
        contractVersion: "minimax-plan-inference-v1"
    )
}

public enum MiniMaxPlanInferencePolicy: Equatable, Sendable {
    case requireVerifiedSource(ParsedMiniMaxPlanInferenceContract)
    case approvedEntitlementRule(ParsedMiniMaxPlanInferenceContract)
    case disabled

    public static let verifiedApprovedV1: MiniMaxPlanInferencePolicy =
        .requireVerifiedSource(.approvedV1)
}

public enum ParsedMiniMaxPlanLevel: String, Equatable, Sendable {
    case plus = "Plus"
    case max = "Max"
    case ultra = "Ultra"
}

public struct ParsedMiniMaxPlanObservation: Equatable, Sendable {
    public let level: ParsedMiniMaxPlanLevel
    public let ruleID: String
    public let catalogID: String
    public let sourceVersion: String
    public let contractVersion: String
    public let evidenceFields: [String]
    public let fetchedAt: Date
}

public enum ParsedMiniMaxPlanUnknownReason: Equatable, Sendable {
    case inferenceDisabled
    case incompleteRead
    case baseStatusNotSuccessful(Int)
    case droppedRows(Int)
    case duplicateRows(Int)
    case sourceVersionMismatch
    case regionMismatch
    case catalogMismatch
    case contractVersionMismatch
    case videoRowMissing
    case invalidVideoWindowTuple
    case unsupportedStatus
    case unsupportedEntitlementTuple
}

public enum ParsedMiniMaxPlanResolution: Equatable, Sendable {
    case inferred(ParsedMiniMaxPlanObservation)
    case unknown(ParsedMiniMaxPlanUnknownReason)

    public var observation: ParsedMiniMaxPlanObservation? {
        guard case let .inferred(observation) = self else { return nil }
        return observation
    }
}

public enum MiniMaxPlanInference {
    public static func resolve(
        _ snapshot: ParsedMiniMaxQuotaSnapshot,
        policy: MiniMaxPlanInferencePolicy = .verifiedApprovedV1
    ) -> ParsedMiniMaxPlanResolution {
        let contract: ParsedMiniMaxPlanInferenceContract
        let requiresSourceMatch: Bool
        switch policy {
        case let .requireVerifiedSource(requiredContract):
            contract = requiredContract
            requiresSourceMatch = true
        case let .approvedEntitlementRule(approvedContract):
            contract = approvedContract
            requiresSourceMatch = false
        case .disabled:
            return .unknown(.inferenceDisabled)
        }

        guard snapshot.context.completeness == .completeSuccess else {
            return .unknown(.incompleteRead)
        }
        guard snapshot.baseStatusCode == 0 else {
            return .unknown(.baseStatusNotSuccessful(snapshot.baseStatusCode))
        }
        guard snapshot.droppedRowCount == 0 else {
            return .unknown(.droppedRows(snapshot.droppedRowCount))
        }
        guard snapshot.duplicateRowCount == 0 else {
            return .unknown(.duplicateRows(snapshot.duplicateRowCount))
        }
        if requiresSourceMatch {
            guard snapshot.context.sourceVersion == contract.sourceVersion else {
                return .unknown(.sourceVersionMismatch)
            }
            guard snapshot.context.region == contract.region else {
                return .unknown(.regionMismatch)
            }
            guard snapshot.context.catalogID == contract.catalogID else {
                return .unknown(.catalogMismatch)
            }
            guard snapshot.context.contractVersion == contract.contractVersion else {
                return .unknown(.contractVersionMismatch)
            }
        }
        guard let video = snapshot.uniqueModel(named: "video") else {
            return .unknown(.videoRowMissing)
        }
        guard isValidInferenceWindow(video.current),
              isValidInferenceWindow(video.weekly) else {
            return .unknown(.invalidVideoWindowTuple)
        }

        let knownStatuses = Set([1, 3])
        guard knownStatuses.contains(video.current.status),
              knownStatuses.contains(video.weekly.status) else {
            return .unknown(.unsupportedStatus)
        }
        guard snapshot.effectiveCompleteness == .completeSuccess else {
            return .unknown(.incompleteRead)
        }

        if video.current.status == 1, video.current.totalCount == Decimal(3) {
            return inferred(
                .max,
                snapshot: snapshot,
                contract: contract,
                evidenceFields: ["model_remains[video].current_interval_total_count"]
            )
        }
        if video.current.status == 1, video.current.totalCount == Decimal(5) {
            return inferred(
                .ultra,
                snapshot: snapshot,
                contract: contract,
                evidenceFields: ["model_remains[video].current_interval_total_count"]
            )
        }
        if video.current.totalCount == 0,
           video.weekly.totalCount == 0,
           video.current.status == 3,
           video.weekly.status == 3 {
            return inferred(
                .plus,
                snapshot: snapshot,
                contract: contract,
                evidenceFields: [
                    "model_remains[video].current_interval_total_count",
                    "model_remains[video].current_interval_status",
                    "model_remains[video].current_weekly_total_count",
                    "model_remains[video].current_weekly_status"
                ]
            )
        }

        return .unknown(.unsupportedEntitlementTuple)
    }

    private static func isValidInferenceWindow(_ window: ParsedMiniMaxQuotaWindow) -> Bool {
        guard window.startTimeMilliseconds > 0,
              window.endTimeMilliseconds > window.startTimeMilliseconds,
              window.remainsTimeMilliseconds >= 0 else {
            return false
        }
        let duration = window.endTimeMilliseconds - window.startTimeMilliseconds
        guard window.remainsTimeMilliseconds <= duration,
              window.totalCount >= 0,
              window.usageCount >= 0,
              window.usageCount <= window.totalCount,
              window.remainingPercent >= 0,
              window.remainingPercent <= 100 else {
            return false
        }
        return true
    }

    private static func inferred(
        _ level: ParsedMiniMaxPlanLevel,
        snapshot: ParsedMiniMaxQuotaSnapshot,
        contract: ParsedMiniMaxPlanInferenceContract,
        evidenceFields: [String]
    ) -> ParsedMiniMaxPlanResolution {
        .inferred(
            ParsedMiniMaxPlanObservation(
                level: level,
                ruleID: contract.ruleID,
                catalogID: contract.catalogID,
                sourceVersion: contract.sourceVersion,
                contractVersion: contract.contractVersion,
                evidenceFields: evidenceFields,
                fetchedAt: snapshot.context.fetchedAt
            )
        )
    }
}
