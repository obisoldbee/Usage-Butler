import Foundation

struct OpenAIAccountReadResponseDTO: Decodable, Equatable, Sendable {
    struct Account: Decodable, Equatable, Sendable {
        let type: String
        let planType: String?
    }

    let account: Account?
    let requiresOpenAIAuth: Bool

    private enum CodingKeys: String, CodingKey {
        case account
        case requiresOpenAIAuth = "requiresOpenaiAuth"
    }
}

struct OpenAIRateLimitWindowDTO: Decodable, Equatable, Sendable {
    let usedPercent: Double?
    let windowDurationMins: Int?
    let resetsAt: Int64?
}

enum OpenAICreditBalanceDTO: Decodable, Equatable, Sendable {
    case string(String)
    case number(Double)
    case boolean(Bool)

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode(Bool.self) {
            self = .boolean(value)
        } else {
            self = .number(try container.decode(Double.self))
        }
    }
}

struct OpenAICreditsDTO: Decodable, Equatable, Sendable {
    let hasCredits: Bool?
    let unlimited: Bool?
    let balance: OpenAICreditBalanceDTO?
}

struct OpenAIRateLimitBucketDTO: Decodable, Equatable, Sendable {
    let limitID: String?
    let limitName: String?
    let primary: OpenAIRateLimitWindowDTO?
    let secondary: OpenAIRateLimitWindowDTO?
    let planType: String?
    let credits: OpenAICreditsDTO?
    let invalidCredits: Bool
    let rateLimitReachedType: String?

    private enum CodingKeys: String, CodingKey {
        case limitID = "limitId"
        case limitName
        case primary
        case secondary
        case planType
        case credits
        case rateLimitReachedType
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        limitID = try container.decodeIfPresent(String.self, forKey: .limitID)
        limitName = try container.decodeIfPresent(String.self, forKey: .limitName)
        primary = try container.decodeIfPresent(OpenAIRateLimitWindowDTO.self, forKey: .primary)
        secondary = try container.decodeIfPresent(OpenAIRateLimitWindowDTO.self, forKey: .secondary)
        planType = try container.decodeIfPresent(String.self, forKey: .planType)
        if container.contains(.credits), try !container.decodeNil(forKey: .credits) {
            do {
                credits = try container.decode(OpenAICreditsDTO.self, forKey: .credits)
                invalidCredits = false
            } catch {
                credits = nil
                invalidCredits = true
            }
        } else {
            credits = nil
            invalidCredits = false
        }
        rateLimitReachedType = try container.decodeIfPresent(String.self, forKey: .rateLimitReachedType)
    }
}

struct OpenAIRateLimitResetCreditDetailDTO: Decodable, Equatable, Sendable {
    let id: String?
    let resetType: String?
    let status: String?
    let grantedAt: Int64?
    let expiresAt: Int64?
    let title: String?
    let description: String?
}

struct OpenAIRateLimitResetCreditsDTO: Decodable, Equatable, Sendable {
    let availableCount: Int
    let details: [OpenAIRateLimitResetCreditDetailDTO]?
    let invalidDetailCount: Int
    let invalidDetailContainer: Bool

    private enum CodingKeys: String, CodingKey {
        case availableCount
        case credits
        case details
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        availableCount = try container.decode(Int.self, forKey: .availableCount)

        if container.contains(.credits), try !container.decodeNil(forKey: .credits) {
            do {
                let lossy = try container.decode(
                    OpenAILossyArray<OpenAIRateLimitResetCreditDetailDTO>.self,
                    forKey: .credits
                )
                details = lossy.values
                invalidDetailCount = lossy.invalidCount
                invalidDetailContainer = false
            } catch {
                details = nil
                invalidDetailCount = 1
                invalidDetailContainer = true
            }
        } else if container.contains(.details), try !container.decodeNil(forKey: .details) {
            do {
                let lossy = try container.decode(
                    OpenAILossyArray<OpenAIRateLimitResetCreditDetailDTO>.self,
                    forKey: .details
                )
                details = lossy.values
                invalidDetailCount = lossy.invalidCount
                invalidDetailContainer = false
            } catch {
                details = nil
                invalidDetailCount = 1
                invalidDetailContainer = true
            }
        } else {
            details = nil
            invalidDetailCount = 0
            invalidDetailContainer = false
        }
    }
}

struct OpenAIRateLimitsReadResponseDTO: Decodable, Equatable, Sendable {
    let rateLimits: OpenAIRateLimitBucketDTO?
    let rateLimitsByLimitID: [String: OpenAIRateLimitBucketDTO]?
    let rateLimitResetCredits: OpenAIRateLimitResetCreditsDTO?
    let invalidRateLimitResetCredits: Bool
    let invalidLimitIDs: [String]
    let invalidLegacyRateLimits: Bool

    private enum CodingKeys: String, CodingKey {
        case rateLimits
        case rateLimitsByLimitID = "rateLimitsByLimitId"
        case rateLimitResetCredits
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        if container.contains(.rateLimits), try !container.decodeNil(forKey: .rateLimits) {
            do {
                rateLimits = try container.decode(OpenAIRateLimitBucketDTO.self, forKey: .rateLimits)
                invalidLegacyRateLimits = false
            } catch {
                rateLimits = nil
                invalidLegacyRateLimits = true
            }
        } else {
            rateLimits = nil
            invalidLegacyRateLimits = false
        }

        if container.contains(.rateLimitsByLimitID),
           try !container.decodeNil(forKey: .rateLimitsByLimitID) {
            let lossy = try container.decode(
                OpenAILossyDictionary<OpenAIRateLimitBucketDTO>.self,
                forKey: .rateLimitsByLimitID
            )
            rateLimitsByLimitID = lossy.values
            invalidLimitIDs = lossy.invalidKeys
        } else {
            rateLimitsByLimitID = nil
            invalidLimitIDs = []
        }

        if container.contains(.rateLimitResetCredits),
           try !container.decodeNil(forKey: .rateLimitResetCredits) {
            do {
                rateLimitResetCredits = try container.decode(
                    OpenAIRateLimitResetCreditsDTO.self,
                    forKey: .rateLimitResetCredits
                )
                invalidRateLimitResetCredits = false
            } catch {
                rateLimitResetCredits = nil
                invalidRateLimitResetCredits = true
            }
        } else {
            rateLimitResetCredits = nil
            invalidRateLimitResetCredits = false
        }
    }
}

private struct OpenAIDynamicCodingKey: CodingKey {
    let stringValue: String
    let intValue: Int? = nil

    init?(stringValue: String) {
        self.stringValue = stringValue
    }

    init?(intValue: Int) {
        return nil
    }
}

private struct OpenAILossyDictionary<Value: Decodable & Sendable>: Decodable, Sendable {
    let values: [String: Value]
    let invalidKeys: [String]

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: OpenAIDynamicCodingKey.self)
        var values: [String: Value] = [:]
        var invalidKeys: [String] = []

        for key in container.allKeys.sorted(by: { $0.stringValue < $1.stringValue }) {
            do {
                values[key.stringValue] = try container.decode(Value.self, forKey: key)
            } catch {
                invalidKeys.append(key.stringValue)
            }
        }

        self.values = values
        self.invalidKeys = invalidKeys
    }
}

private struct OpenAILossyArray<Value: Decodable & Sendable>: Decodable, Sendable {
    let values: [Value]
    let invalidCount: Int

    init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()
        var values: [Value] = []
        var invalidCount = 0

        while !container.isAtEnd {
            do {
                values.append(try container.decode(Value.self))
            } catch {
                invalidCount += 1
                _ = try container.decode(OpenAIDiscardedJSONValue.self)
            }
        }

        self.values = values
        self.invalidCount = invalidCount
    }
}

private indirect enum OpenAIDiscardedJSONValue: Decodable, Sendable {
    case object([String: OpenAIDiscardedJSONValue])
    case array([OpenAIDiscardedJSONValue])
    case string(String)
    case number(Double)
    case boolean(Bool)
    case null

    init(from decoder: Decoder) throws {
        if let container = try? decoder.container(keyedBy: OpenAIDynamicCodingKey.self) {
            var object: [String: OpenAIDiscardedJSONValue] = [:]
            for key in container.allKeys {
                object[key.stringValue] = try container.decode(OpenAIDiscardedJSONValue.self, forKey: key)
            }
            self = .object(object)
            return
        }

        if var container = try? decoder.unkeyedContainer() {
            var array: [OpenAIDiscardedJSONValue] = []
            while !container.isAtEnd {
                array.append(try container.decode(OpenAIDiscardedJSONValue.self))
            }
            self = .array(array)
            return
        }

        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode(Bool.self) {
            self = .boolean(value)
        } else {
            self = .number(try container.decode(Double.self))
        }
    }
}
