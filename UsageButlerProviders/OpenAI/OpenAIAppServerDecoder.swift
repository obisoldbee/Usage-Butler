import Foundation

enum OpenAIAppServerDecodeError: Error, Equatable, Sendable {
    case malformedAccountRead
    case malformedRateLimitsRead
}

enum OpenAIAppServerDecoder {
    static func decodeAccountRead(from data: Data) throws -> OpenAIAccountReadResponseDTO {
        do {
            return try JSONDecoder().decode(OpenAIAccountReadResponseDTO.self, from: data)
        } catch {
            throw OpenAIAppServerDecodeError.malformedAccountRead
        }
    }

    static func decodeRateLimitsRead(from data: Data) throws -> OpenAIRateLimitsReadResponseDTO {
        do {
            return try JSONDecoder().decode(OpenAIRateLimitsReadResponseDTO.self, from: data)
        } catch {
            throw OpenAIAppServerDecodeError.malformedRateLimitsRead
        }
    }
}
