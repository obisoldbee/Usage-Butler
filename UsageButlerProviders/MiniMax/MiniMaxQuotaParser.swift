import Foundation

public enum ParsedMiniMaxParsingFailureCode: Equatable, Sendable {
    case emptyInput
    case missingRequiredField
    case invalidFieldType
    case invalidJSON
}

public struct ParsedMiniMaxParsingFailure: Error, Equatable, Sendable {
    public let code: ParsedMiniMaxParsingFailureCode
    public let codingPath: String

    public init(code: ParsedMiniMaxParsingFailureCode, codingPath: String) {
        self.code = code
        self.codingPath = codingPath
    }
}

public enum MiniMaxQuotaParser {
    public static func parse(
        _ data: Data,
        context: ParsedMiniMaxParsingContext
    ) throws -> ParsedMiniMaxQuotaSnapshot {
        guard !data.isEmpty else {
            throw ParsedMiniMaxParsingFailure(code: .emptyInput, codingPath: "$")
        }

        let envelope: MiniMaxEnvelopeDTO
        do {
            envelope = try JSONDecoder().decode(MiniMaxEnvelopeDTO.self, from: data)
        } catch {
            throw mapDecodingError(error)
        }

        let models = envelope.modelRemains.compactMap(\.value).map(\.parsed)
        let droppedRowCount = envelope.modelRemains.count - models.count
        let groupedCounts = Dictionary(grouping: models, by: \.modelName).values.map(\.count)
        let duplicateRowCount = groupedCounts.reduce(into: 0) { result, count in
            if count > 1 {
                result += count - 1
            }
        }

        return ParsedMiniMaxQuotaSnapshot(
            baseStatusCode: envelope.baseResponse.statusCode,
            models: models,
            droppedRowCount: droppedRowCount,
            parsingFailures: envelope.modelRemains.compactMap(\.failure),
            duplicateRowCount: duplicateRowCount,
            context: context
        )
    }

    static func mapDecodingError(_ error: Error) -> ParsedMiniMaxParsingFailure {
        switch error {
        case let DecodingError.keyNotFound(key, context):
            return ParsedMiniMaxParsingFailure(
                code: .missingRequiredField,
                codingPath: path(context.codingPath + [key])
            )
        case let DecodingError.typeMismatch(_, context),
             let DecodingError.valueNotFound(_, context):
            return ParsedMiniMaxParsingFailure(
                code: .invalidFieldType,
                codingPath: path(context.codingPath)
            )
        case let DecodingError.dataCorrupted(context):
            return ParsedMiniMaxParsingFailure(
                code: .invalidJSON,
                codingPath: path(context.codingPath)
            )
        default:
            return ParsedMiniMaxParsingFailure(code: .invalidJSON, codingPath: "$")
        }
    }

    private static func path(_ codingPath: [any CodingKey]) -> String {
        guard !codingPath.isEmpty else { return "$" }
        return "$." + codingPath.map(\.stringValue).joined(separator: ".")
    }
}

private struct MiniMaxEnvelopeDTO: Decodable {
    let baseResponse: MiniMaxBaseResponseDTO
    let modelRemains: [MiniMaxRowAttempt]

    enum CodingKeys: String, CodingKey {
        case baseResponse = "base_resp"
        case modelRemains = "model_remains"
    }
}

private struct MiniMaxBaseResponseDTO: Decodable {
    let statusCode: Int

    enum CodingKeys: String, CodingKey {
        case statusCode = "status_code"
    }
}

private struct MiniMaxRowAttempt: Decodable {
    let value: MiniMaxModelRemainDTO?
    let failure: ParsedMiniMaxParsingFailure?

    init(from decoder: any Decoder) throws {
        do { value = try MiniMaxModelRemainDTO(from: decoder); failure = nil }
        catch { value = nil; failure = MiniMaxQuotaParser.mapDecodingError(error) }
    }
}

private struct MiniMaxModelRemainDTO: Decodable {
    let modelName: String
    let startTime: Int64
    let endTime: Int64
    let remainsTime: Int64
    let currentIntervalTotalCount: Decimal
    let currentIntervalUsageCount: Decimal
    let currentIntervalRemainingPercent: Decimal
    let currentIntervalStatus: Int
    let weeklyStartTime: Int64
    let weeklyEndTime: Int64
    let weeklyRemainsTime: Int64
    let currentWeeklyTotalCount: Decimal
    let currentWeeklyUsageCount: Decimal
    let currentWeeklyRemainingPercent: Decimal
    let currentWeeklyStatus: Int
    let weeklyBoostPermille: Decimal?

    enum CodingKeys: String, CodingKey {
        case modelName = "model_name"
        case startTime = "start_time"
        case endTime = "end_time"
        case remainsTime = "remains_time"
        case currentIntervalTotalCount = "current_interval_total_count"
        case currentIntervalUsageCount = "current_interval_usage_count"
        case currentIntervalRemainingPercent = "current_interval_remaining_percent"
        case currentIntervalStatus = "current_interval_status"
        case weeklyStartTime = "weekly_start_time"
        case weeklyEndTime = "weekly_end_time"
        case weeklyRemainsTime = "weekly_remains_time"
        case currentWeeklyTotalCount = "current_weekly_total_count"
        case currentWeeklyUsageCount = "current_weekly_usage_count"
        case currentWeeklyRemainingPercent = "current_weekly_remaining_percent"
        case currentWeeklyStatus = "current_weekly_status"
        case weeklyBoostPermille = "weekly_boost_permille"
    }

    var parsed: ParsedMiniMaxModelQuota {
        ParsedMiniMaxModelQuota(
            modelName: modelName,
            current: ParsedMiniMaxQuotaWindow(
                startTimeMilliseconds: startTime,
                endTimeMilliseconds: endTime,
                remainsTimeMilliseconds: remainsTime,
                totalCount: currentIntervalTotalCount,
                usageCount: currentIntervalUsageCount,
                remainingPercent: currentIntervalRemainingPercent,
                status: currentIntervalStatus
            ),
            weekly: ParsedMiniMaxQuotaWindow(
                startTimeMilliseconds: weeklyStartTime,
                endTimeMilliseconds: weeklyEndTime,
                remainsTimeMilliseconds: weeklyRemainsTime,
                totalCount: currentWeeklyTotalCount,
                usageCount: currentWeeklyUsageCount,
                remainingPercent: currentWeeklyRemainingPercent,
                status: currentWeeklyStatus
            ),
            weeklyBoostPermille: weeklyBoostPermille
        )
    }
}
